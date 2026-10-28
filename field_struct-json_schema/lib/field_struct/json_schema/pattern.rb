# frozen_string_literal: true

module FieldStruct
  module JSONSchema
    # Translates a Ruby Regexp source into an ECMA-262 pattern that matches
    # the same strings under the +u+ flag (what JSON Schema 2020-12 and Ajv
    # use), or gives up. A wrong pattern would make a validator reject values
    # the struct accepts, so anything without an exact equivalent returns
    # +nil+ rather than a near miss:
    #
    # * +\A+ / +\z+ become +^+ / +$+; bare +^+ / +$+ (line anchors in Ruby)
    #   become lookarounds. +.+ becomes +[^\n]+ and +\s+ / +\S+ become Ruby's
    #   ASCII whitespace set; +\h+ / +\H+ become hex classes.
    # * An escaped non-syntax character (+\-+, +\ +, +\@+) loses its
    #   backslash outside a class, since +u+ mode rejects it.
    # * Case-insensitive (+/i+) is spelled out for ASCII letters, with Ruby's
    #   extra folds (+s+ also matches the long s U+017F, +k+ the Kelvin sign
    #   U+212A): +[a-f]+ becomes +[a-fA-F]+.
    # * Gives up on: Ruby-only escapes (+\Z+, +\G+, +\p{…}+, +\e+, …),
    #   backreferences, groups other than +(?:+, +(?=+, +(?!+, +(?<=+,
    #   +(?<!+ and +(?<name>+, possessive or stacked quantifiers, +{n}?+
    #   (optional in Ruby, lazy in JavaScript), a quantified anchor or
    #   lookaround, +{,n}+, nested classes and +&&+, a leading +]+ in a
    #   class, non-ASCII bytes in +\x+, astral characters in a class, +\b+ /
    #   +\B+ outside a class (Unicode-aware in Ruby, ASCII in JavaScript), and
    #   under +/i+: any non-ASCII character, +\x+ / +\u+ escapes, +\W+ / +\D+
    #   in a class, ranges whose ends aren't both letters but which cover
    #   letters, and letters that could pair into one Ruby folds to one
    #   character (+ss+ matches +ß+, +fi+ matches +ﬁ+, and so do +s{2}+ and
    #   +[s]s+).
    #
    # Without the +u+ flag an astral character (outside the BMP) counts as
    # two code units, so +.+ and negated classes differ there. The line
    # anchors use lookbehind, which RE2-based validators (Go, Rust) reject.
    #
    # @api private
    class Pattern
      # Escapes ECMA-262 reads as Ruby does (Ruby's +\d+ / +\w+ are ASCII by
      # default, like JavaScript's; +\b+ / +\B+ are only shared inside a
      # class, as backspace).
      # @return [String]
      SHARED_ESCAPES = 'dDwWbBnrtfv'
      # Characters +u+ mode accepts as an identity escape.
      # @return [String]
      SYNTAX = '^$\\.*+?()[]{}|/'
      # Ruby's +\s+.
      # @return [String]
      SPACE = '\t\n\v\f\r '
      # @return [String]
      HEX = '0-9a-fA-F'
      # Ruby's +^+: the start, or after a newline that isn't the last
      # character.
      # @return [String]
      LINE_START = '(?:^|(?<=\n)(?!$))'
      # Ruby's +$+: before a newline or at the end.
      # @return [String]
      LINE_END = '(?![^\n])'
      # Under +/i+, what each ASCII letter also matches in Ruby beyond its
      # other case.
      # @return [Hash{String=>String}]
      EXTRA_FOLDS = {'s' => "\u017F", 'k' => "\u212A"}.freeze
      # Letter pairs Ruby's +/i+ also matches as one character (+ß+, +ﬀ+,
      # +ﬁ+, +ﬂ+, +ﬅ+).
      # @return [Regexp]
      MULTI_FOLD = /ss|ff|fi|fl|st/i
      # @return [Array<Range<String>>]
      LETTERS = [('A'..'Z'), ('a'..'z')].freeze

      # Raised internally when the source has no exact translation.
      class Unsupported < StandardError; end

      # @param source [String] a Regexp source
      # @param fold_case [Boolean] whether the Regexp is +/i+
      def initialize(source, fold_case:)
        @source = source
        @fold_case = fold_case
      end

      # @return [String, nil] the ECMA-262 pattern, or +nil+ when there is no
      #   exact translation
      def to_s
        unsupported if @fold_case && (@source.match?(MULTI_FOLD) || !@source.ascii_only?)
        @out = +''
        @pos = 0
        @in_class = false
        @groups = [] # [:plain or :lookaround, where it starts in @out], per open group
        # Where the last quantifiable atom starts in @out, and the atom before it.
        @atom_start = nil
        @prev_start = nil
        # Under /i, single-letter atoms (s, [s], [s-s]) by where they start in
        # @out: Ruby can merge those into a string that folds as one character.
        @folded = {}
        @names = []
        # Whether the last token can take a quantifier, and whether it is one
        # (:lazy_ok when a "?" after it would make it lazy).
        @quantifiable = false
        @quantified = false
        step while @pos < @source.length
        @in_class || !@groups.empty? ? nil : @out
      rescue Unsupported
        nil
      end

      private

      # @return [void]
      def step
        char = take
        if char == '\\' then escape(take || unsupported)
        elsif @in_class then class_char(char)
        else outside_char(char)
        end
      end

      # @param char [String]
      # @return [void]
      def outside_char(char)
        case char
        when '*', '+', '?' then quantifier(char)
        when '{' then interval
        when '['
          # "[\s\S]" (anything) is the same set in both, though \s isn't.
          return atom { @out << '[\s\S]' } if @source[@pos, 5] == '\s\S]' && (@pos += 5)

          atom { open_class }
        when '(' then group
        when ')' then close_group
        when '|' then plain_token('|')
        when '.' then atom { @out << '[^\n]' }
        when '^' then plain_token(LINE_START)
        when '$' then plain_token(LINE_END)
        when '}', ']' then atom { @out << '\\' << char } # literal in Ruby, a syntax error under u
        else atom { @out << literal(char) }
        end
      end

      # Emits something a quantifier may follow.
      # @return [void]
      def atom
        @prev_start = @atom_start
        @atom_start = @out.length
        yield
        @quantifiable = true
        @quantified = false
      end

      # Emits something a quantifier may not follow (an anchor, +|+).
      # @param text [String]
      # @return [void]
      def plain_token(text)
        @atom_start = nil
        @out << text
        @quantifiable = false
        @quantified = false
      end

      # @param char [String] +*+, +++ or +?+
      # @return [void]
      def quantifier(char)
        if char == '?' && @quantified == :lazy_ok
          @out << char # lazy: *? +? ?? {n,m}? {n,}?
          @quantified = true
          return
        end
        # Stacked (a**), possessive (a*+) or on an anchor or lookaround.
        unsupported if !@quantifiable || @quantified
        @out << char
        @quantified = :lazy_ok
      end

      # @return [void]
      def interval
        body = @source[@pos..][/\A\d*(,\d*)?\}/]
        unless body&.match?(/\A\d/)
          # Ruby reads "{,n}" as {0,n}; JavaScript reads it as literal text.
          unsupported if body
          atom { @out << '\\{' } # a literal brace, escaped for u mode
          return
        end
        unsupported if !@quantifiable || @quantified
        # Under /i Ruby repeats a one-letter atom into a string: "s{2}" matches "ß".
        unsupported if body.to_i >= 2 && folded_since(@atom_start).intersect?(%w[s f])
        @pos += body.length
        @out << '{' << body
        # "{n}?" is an optional {n} in Ruby but a lazy {n} in JavaScript, so
        # only a range interval may be followed by a lazy "?".
        @quantified = body.include?(',') ? :lazy_ok : true
      end

      # @return [void]
      def group
        start = @out.length
        @atom_start = nil
        @out << '('
        kind = :plain
        if peek == '?'
          @out << take
          case (form = take)
          when ':' then @out << form
          when '=', '!'
            kind = :lookaround
            @out << form
          when '<' then kind = named_or_lookbehind
          else unsupported
          end
        end
        @groups.push([kind, start])
        @quantifiable = false
        @quantified = false
      end

      # @return [Symbol] +:lookaround+ or +:plain+
      def named_or_lookbehind
        @out << '<'
        if %w[= !].include?(peek)
          @out << take
          return :lookaround
        end
        name = @source[@pos..][/\A[A-Za-z_]\w*>/] || unsupported
        unsupported if @names.include?(name) # duplicate names are engine-dependent
        @names << name
        @pos += name.length
        @out << name
        :plain
      end

      # @return [void]
      def close_group
        kind, start = @groups.pop || unsupported
        @out << ')'
        @quantifiable = kind == :plain
        @atom_start = @quantifiable ? start : nil
        @quantified = false
      end

      # @return [void]
      def open_class
        @in_class = true
        @class_start = true
        @range_dash = false
        @low = nil
        @out << '['
        @class_negated = peek == '^'
        @out << take if @class_negated
        @class_source = @pos
        # A leading "]" is a literal in Ruby and closes the class in JavaScript.
        unsupported if peek == ']'
      end

      # @param char [String]
      # @return [void]
      def class_char(char)
        dash = @range_dash
        @range_dash = false
        case char
        when '[' then unsupported # nested class, POSIX bracket
        when ']' then return close_class
        when '-' then @range_dash = !@class_start && peek != ']'
        else
          unsupported if char == '&' && peek == '&'
          return @out << fold_class_char(char, dash) if cased?(char)

          check_folded_range(char) if dash
          @low = char
        end
        @class_start = false
        @out << class_literal(char)
      end

      # @return [void]
      def close_class
        @in_class = false
        letter = @source[@class_source...(@pos - 1)][/\A([A-Za-z])(?:-\1)?\z/, 1]
        @folded[@atom_start] = [letter.downcase] if @fold_case && letter && !@class_negated
        @out << ']'
        @quantifiable = true
        @quantified = false
      end

      # Under +/i+, a letter in a class stands for every character Ruby folds
      # it with: +b+ becomes +bB+, +s+ becomes +sS\u017F+, and an ASCII range
      # +a-f+ becomes +a-fA-F+ (plus +\u017F+ / +K+ when it covers +s+ / +k+). A
      # range with a letter at only one end has no folded form.
      #
      # @param char [String] a cased letter inside a class
      # @param dash [Boolean] whether a range +-+ came right before it
      # @return [String]
      def fold_class_char(char, dash)
        unsupported if dash
        @class_start = false
        @low = nil
        high = @source[@pos + 1] if peek == '-'
        return folds(char) unless high && high != ']'

        unsupported unless "#{char}#{high}".match?(/\A(?:[a-z]{2}|[A-Z]{2})\z/)
        @pos += 2
        low = char.downcase
        top = high.downcase
        extra = EXTRA_FOLDS.select { |letter, _| (low..top).cover?(letter) }.values.join
        "#{low}-#{top}#{low.upcase}-#{top.upcase}#{extra}"
      end

      # Under +/i+, a range between two non-letters (+!-~+) still folds the
      # letters it covers, which a JavaScript class won't.
      #
      # @param high [String] the range's upper end
      # @return [void]
      def check_folded_range(high)
        return unless @fold_case

        unsupported if @low.nil? || LETTERS.any? { |letters| @low <= letters.end && high >= letters.begin }
      end

      # @param char [String] a class member that isn't a cased letter
      # @return [String]
      def class_literal(char)
        unsupported if char.ord > 0xFFFF # astral: two code units without u
        char
      end

      # @param char [String] the escaped character
      # @return [void]
      def escape(char)
        return class_escape(char) if @in_class

        case char
        when 'A' then plain_token('^')
        when 'z' then plain_token('$')
        when 'b', 'B' then unsupported # Ruby's word boundary counts é and ſ as word characters
        when 's' then atom { @out << "[#{SPACE}]" }
        when 'S' then atom { @out << "[^#{SPACE}]" }
        when 'h' then atom { @out << "[#{HEX}]" }
        when 'H' then atom { @out << "[^#{HEX}]" }
        else atom { @out << shared_escape(char) }
        end
      end

      # @param char [String]
      # @return [void]
      def class_escape(char)
        unsupported if @fold_case && @range_dash # an escaped range end can't be checked for letters
        @class_start = false
        @range_dash = false
        @low = nil
        case char
        when 's' then @out << SPACE
        when 'h' then @out << HEX
        when '-' then @out << '\\-'
        when 'B', 'k' then unsupported # a literal in a Ruby class, an error under u
        when 'W', 'D' then @fold_case ? unsupported : @out << shared_escape(char) # /i adds "ss" for ß
        else @out << shared_escape(char)
        end
      end

      # @param char [String]
      # @return [String] the escape as ECMA-262 writes it
      # @raise [Unsupported] when ECMA-262 has no exact equivalent
      def shared_escape(char)
        return "\\#{char}" if SHARED_ESCAPES.include?(char) || SYNTAX.include?(char)

        case char
        when '0'
          unsupported if peek&.match?(/\d/) # octal in Ruby, an error under u
          '\\0'
        when 'x' then hex_escape('x', /\A\h{2}/)
        when 'u' then hex_escape('u', /\A\h{4}/)
        when 'c' then copy_escape('c', /\A[A-Za-z]/)
        else
          # Backreferences (\1, \k<n>) and Ruby-only escapes give up.
          unsupported if char.match?(/[[:alnum:]]/)
          char
        end
      end

      # @param char [String] +x+ or +u+
      # @param body [Regexp] the hex digits that must follow
      # @return [String]
      def hex_escape(char, body)
        unsupported if @fold_case # the escaped character may need folding
        text = copy_escape(char, body)
        unsupported if char == 'x' && text[2..].to_i(16) >= 0x80 # a raw byte in Ruby
        text
      end

      # @param char [String]
      # @param body [Regexp] what must follow +\char+
      # @return [String]
      def copy_escape(char, body)
        text = @source[@pos..][body] || unsupported
        @pos += text.length
        "\\#{char}#{text}"
      end

      # @param char [String] a literal outside a class
      # @return [String]
      def literal(char)
        return "(?:#{char})" if char.ord > 0xFFFF # one atom for a quantifier, with or without u
        return char unless cased?(char)

        # Under /i Ruby merges a letter with the atom before it: "[s]s" matches "ß".
        lower = char.downcase
        unsupported if @prev_start && folded_since(@prev_start).any? { |before| "#{before}#{lower}".match?(MULTI_FOLD) }
        @folded[@atom_start] = [lower]
        "[#{folds(char)}]"
      end

      # @param start [Integer, nil] a position in the output
      # @return [Array<String>] the lowercase letters spelled out as folds
      #   from +start+ on
      def folded_since(start)
        return [] if start.nil?

        @folded.select { |at, _| at >= start }.values.flatten
      end

      # @param char [String] an ASCII letter
      # @return [String] every character Ruby's +/i+ matches it with
      def folds(char)
        lower = char.downcase
        "#{lower}#{lower.upcase}#{EXTRA_FOLDS[lower]}"
      end

      # @param char [String]
      # @return [Boolean] whether +char+ needs folding under +/i+
      # @raise [Unsupported] for a non-ASCII letter under +/i+
      def cased?(char)
        return false unless @fold_case && char.downcase != char.upcase

        unsupported unless char.match?(/\A[A-Za-z]\z/)
        true
      end

      # @return [String, nil]
      def take
        char = @source[@pos]
        @pos += 1 if char
        char
      end

      # @return [String, nil]
      def peek = @source[@pos]

      # @return [void] never returns
      # @raise [Unsupported]
      def unsupported
        raise Unsupported
      end
    end
  end
end
