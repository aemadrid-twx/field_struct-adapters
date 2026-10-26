# frozen_string_literal: true

module FieldStruct
  module JSONSchema
    # Translates a Ruby Regexp source into an ECMA-262 pattern that matches
    # the same strings, valid with and without the +u+ flag (Ajv compiles
    # with +u+), or gives up. A wrong pattern would make a validator reject
    # values the struct accepts, so anything without an exact equivalent
    # returns +nil+ rather than a near miss:
    #
    # * +\A+ / +\z+ become +^+ / +$+; +\Z+, +\G+, +\K+, +\R+, +\X+, +\p{…}+
    #   and other Ruby-only escapes give up.
    # * +.+ becomes +[^\n]+ and +\s+ / +\S+ become Ruby's ASCII whitespace
    #   set: JavaScript's +.+ also stops at +\r+, and its +\s+ also matches
    #   Unicode spaces. +\h+ / +\H+ become hex classes.
    # * An escaped non-syntax character (+\-+, +\ +, +\@+) loses its
    #   backslash outside a class, since +u+ mode rejects it.
    # * Groups other than +(?:+, +(?=+, +(?!+, +(?<=+, +(?<!+ and
    #   +(?<name>+ give up (inline flags, atomic, comments, conditionals,
    #   absence); so do possessive quantifiers, +{,n}+, nested classes
    #   (POSIX brackets, intersections) and +&&+.
    # * Case-insensitive (+/i+): letters outside a class become +[aA]+;
    #   inside one, +b+ becomes +bB+ and an ASCII range +a-f+ becomes
    #   +a-fA-F+.
    #
    # * Bare +^+ and +$+ are line anchors in Ruby and string anchors in
    #   JavaScript, so they become +(?<![^\n])+ and +(?![^\n])+.
    #
    # @api private
    class Pattern
      # Escapes ECMA-262 reads as Ruby does (Ruby's +\d+ / +\w+ / +\b+ are
      # ASCII by default, like JavaScript's).
      # @return [String]
      SHARED_ESCAPES = 'dDwWbBnrtfv0123456789'
      # Characters +u+ mode accepts as an identity escape.
      # @return [String]
      SYNTAX = '^$\\.*+?()[]{}|/'
      # Ruby's +\s+.
      # @return [String]
      SPACE = '\t\n\v\f\r '
      # @return [String]
      HEX = '0-9a-fA-F'

      # @param source [String] a Regexp source
      # @param fold_case [Boolean] whether the Regexp is +/i+
      def initialize(source, fold_case:)
        @source = source
        @fold_case = fold_case
      end

      # @return [String, nil] the ECMA-262 pattern, or +nil+ when there is no
      #   exact translation
      def to_s
        @out = +''
        @pos = 0
        @in_class = false
        @after_quantifier = false
        step while @pos < @source.length
        @in_class ? nil : @out
      rescue Unsupported
        nil
      end

      # Raised internally when the source has no exact translation.
      class Unsupported < StandardError; end

      private

      # @return [void]
      def step
        char = take
        quantifier = false
        if char == '\\' then escape(take || unsupported)
        elsif @in_class then class_char(char)
        else
          quantifier = outside_char(char)
        end
        @after_quantifier = quantifier
      end

      # @param char [String]
      # @return [Boolean] whether +char+ ended a quantifier
      def outside_char(char)
        case char
        when '[' then open_class
        when '(' then group
        when '.' then @out << '[^\n]'
        when '^' then @out << '(?<![^\n])'
        when '$' then @out << '(?![^\n])'
        when '*', '+', '?' then return quantifier(char)
        when '{' then return interval
        when '}', ']' then @out << '\\' << char # literal in Ruby, a syntax error under u
        else @out << fold(char)
        end
        false
      end

      # @param char [String] +*+, +++ or +?+
      # @return [Boolean]
      def quantifier(char)
        unsupported if char == '+' && @after_quantifier # possessive
        @out << char
        if peek == '?' # lazy
          @out << take
          return false
        end
        true
      end

      # @return [Boolean]
      def interval
        body = @source[@pos..][/\A\d*(,\d*)?\}/]
        unless body&.match?(/\A\d/)
          # Ruby reads "{,n}" as {0,n}; JavaScript reads it as literal text.
          unsupported if body
          @out << '\\{' # a literal brace, escaped for u mode
          return false
        end
        @pos += body.length
        @out << '{' << body
        true
      end

      # @return [void]
      def open_class
        @in_class = true
        @out << '['
        @out << take if peek == '^'
      end

      # @param char [String]
      # @return [void]
      def class_char(char)
        case char
        when '[' then unsupported # nested class, POSIX bracket
        when ']' then @in_class = false
        when '&' then unsupported if peek == '&'
        else return @out << fold_class_char(char) if cased?(char)
        end
        @out << char
      end

      # Under +/i+, a letter in a class stands for both cases: +b+ becomes
      # +bB+ and an ASCII range +a-f+ becomes +a-fA-F+. A range ending in a
      # letter but starting elsewhere (+0-z+) has no exact folded form.
      #
      # @param char [String] a cased letter inside a class
      # @return [String]
      def fold_class_char(char)
        unsupported if @out.end_with?('-') && !@out.end_with?('[-', '[^-', '\\-')
        low = char
        high = @source[@pos + 1] if peek == '-'
        return "#{low.downcase}#{low.upcase}" unless high && high != ']'

        unsupported unless "#{low}#{high}".match?(/\A(?:[a-z]{2}|[A-Z]{2})\z/)
        @pos += 2
        "#{low.downcase}-#{high.downcase}#{low.upcase}-#{high.upcase}"
      end

      # @param char [String]
      # @return [Boolean] whether +char+ is a letter +/i+ folds
      def cased?(char)
        @fold_case && char.downcase != char.upcase
      end

      # @return [void]
      def group
        @out << '('
        return unless peek == '?'

        @out << take
        case (kind = take)
        when ':', '=', '!' then @out << kind
        when '<'
          @out << kind
          name = @source[@pos..][/\A(?:[=!]|[A-Za-z_]\w*>)/] || unsupported
          @pos += name.length
          @out << name
        else unsupported
        end
      end

      # @param char [String] the escaped character
      # @return [void]
      def escape(char)
        return class_escape(char) if @in_class

        case char
        when 'A' then @out << '^'
        when 'z' then @out << '$'
        when 's' then @out << "[#{SPACE}]"
        when 'S' then @out << "[^#{SPACE}]"
        when 'h' then @out << "[#{HEX}]"
        when 'H' then @out << "[^#{HEX}]"
        else shared_escape(char) || (char.match?(/[[:alnum:]]/) ? unsupported : @out << char)
        end
      end

      # @param char [String]
      # @return [void]
      def class_escape(char)
        case char
        when 's' then @out << SPACE
        when 'h' then @out << HEX
        when '-' then @out << '\\-'
        else shared_escape(char) || (char.match?(/[[:alnum:]]/) ? unsupported : @out << char)
        end
      end

      # @param char [String]
      # @return [String, nil] the copied escape, or +nil+ when +char+ isn't
      #   one ECMA-262 shares (or a syntax character)
      def shared_escape(char)
        return @out << '\\' << char if SHARED_ESCAPES.include?(char) || SYNTAX.include?(char)

        case char
        when 'x' then copy_escape('x', /\A\h{2}/)
        when 'u' then copy_escape('u', /\A\h{4}/)
        when 'c' then copy_escape('c', /\A[A-Za-z]/)
        when 'k' then copy_escape('k', /\A<[A-Za-z_]\w*>/)
        end
      end

      # @param char [String]
      # @param body [Regexp] what must follow +\char+
      # @return [String]
      def copy_escape(char, body)
        text = @source[@pos..][body] || unsupported
        @pos += text.length
        @out << '\\' << char << text
      end

      # @param char [String]
      # @return [String] +char+, as +[aA]+ under +/i+ when it has case
      def fold(char)
        return char unless cased?(char)

        "[#{char.downcase}#{char.upcase}]"
      end

      # @return [String, nil]
      def take
        char = @source[@pos]
        @pos += 1 if char
        char
      end

      # @return [String, nil]
      def peek = @source[@pos]

      # @raise [Unsupported]
      def unsupported
        raise Unsupported
      end
    end
  end
end
