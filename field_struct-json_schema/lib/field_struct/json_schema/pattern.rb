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

      # Character sets for the ReDoS checks: one bit per ASCII character,
      # and bit 128 for "some non-ASCII character" (all of them count as
      # one, which can only make two sets overlap more).
      # @return [Integer]
      NON_ASCII = 1 << 128
      # @return [Integer]
      ANY = (1 << 129) - 1
      # The retry at every position, as an item (see #polynomial?).
      # @return [Hash{Symbol=>Object}]
      RETRY = {set: ANY, min: 0, max: Float::INFINITY, alternatives: nil}.freeze
      # Single-character escapes in an emitted atom, and what they stand for
      # (+\b+ only in a class: outside one it's unsupported).
      # @return [Hash{String=>String}]
      ESCAPED = {'n' => "\n", 'r' => "\r", 't' => "\t", 'f' => "\f", 'v' => "\v", 'b' => "\b", '0' => "\0"}.freeze

      # @param source [String] a Regexp source
      # @param fold_case [Boolean] whether the Regexp is +/i+
      def initialize(source, fold_case:)
        @source = source
        @fold_case = fold_case
      end

      # @return [String, nil] the ECMA-262 pattern, or +nil+ when there is no
      #   exact translation
      def translate
        unsupported if @fold_case && (@source.match?(MULTI_FOLD) || !@source.ascii_only?)
        @out = +''
        @pos = 0
        @in_class = false
        # [:plain or :lookaround, where it starts in @out, whether it repeats
        # something inside], per open group
        @groups = []
        # Whether the last atom is a group that repeats something inside.
        @repeating_group = false
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
        # What each open group (and the top level) holds, for the ReDoS
        # checks: its alternatives, each a list of items (see #item).
        @frames = [[[]]]
        @sequences = []
        step while @pos < @source.length
        return nil if @in_class || !@groups.empty?

        # A validator tries the pattern at every position, as if it began with
        # [\s\S]*: an alternative not anchored by \A has one more repeat.
        @sequences.concat(@frames.pop.map { |items| [RETRY, *items] })
        unsupported if @sequences.any? { |items| polynomial?(items) }
        @out
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
        when '|'
          # Alternatives can match the same text ((a|aa)), so a group holding
          # one counts as a variable repeat: see #repeats.
          @groups.last[2] = true unless @groups.empty?
          @frames.last << []
          plain_token('|')
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
        @repeating_group = false
        yield
        # A class's set is read once it closes (#close_class).
        @frames.last.last << item(@in_class ? nil : atom_set(@out[@atom_start..]))
        @quantifiable = true
        @quantified = false
      end

      # @param set [Integer, nil] the characters an atom matches
      # @param alternatives [Array<Array<Hash>>, nil] a group's, for a group
      # @return [Hash{Symbol=>Object}] an atom or a group, matched +min+ to
      #   +max+ times
      def item(set, alternatives = nil)
        {set: set, min: 1, max: 1, alternatives: alternatives}
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
        repeats(more_than_once: char != '?', variable: true)
        last = @frames.last.last.last
        last[:min] = char == '+' ? 1 : 0
        last[:max] = char == '?' ? 1 : Float::INFINITY
        @out << char
        @quantified = :lazy_ok
      end

      # A quantifier on the last atom. Repeating a
      # group that holds a variable repeat, like +(a+)++ or +(\w*x){20}+,
      # lets a backtracking engine split one input exponentially many ways:
      # Ruby's memoization hides it, but a JavaScript validator would hang
      # on a crafted input. So those get no pattern, unless the group can
      # split an input only one way ({#unambiguous?}). An exact count over a
      # plain atom (+(\d{3}-){2}+) splits only one way, so it doesn't mark
      # its group. A group holding an alternation counts as varying too, since
      # +(a|aa)+ can split one input many ways.
      #
      # @param more_than_once [Boolean] whether it can repeat the atom
      # @param variable [Boolean] whether the count varies (+?+, +*+, +++,
      #   +{n,m}+), which marks the enclosing group
      # @return [void]
      def repeats(more_than_once:, variable:)
        unsupported if more_than_once && @repeating_group && !unambiguous?(@frames.last.last.last)
        @groups.last[2] = true if variable && !@groups.empty?
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
        low, comma, high = body.delete('}').partition(',')
        most = if comma.empty?
                 low.to_i
               else
                 high.empty? ? Float::INFINITY : high.to_i
               end
        repeats(more_than_once: most > 1, variable: !comma.empty? && most != low.to_i)
        last = @frames.last.last.last
        last[:min] = low.to_i
        last[:max] = most
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
        @groups.push([kind, start, false])
        @frames.push([[]])
        @repeating_group = false
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
        kind, start, repeating = @groups.pop || unsupported
        alternatives = @frames.pop
        @sequences.concat(alternatives)
        @frames.last.last << if kind == :plain
                               item(alternatives.flatten.reduce(0) { |set, inner| set | inner[:set] }, alternatives)
                             else
                               # A lookaround matches no characters, but its repeats run from where
                               # it stands (#lookaround_runs), and one holding a variable repeat
                               # runs again on each iteration of a repeated group around it:
                               # #unambiguous? refuses that.
                               {set: 0, min: 0, max: 0, alternatives: nil, lookaround: repeating, body: alternatives}
                             end
        @out << ')'
        @groups.last[2] = true if repeating && !@groups.empty?
        @quantifiable = kind == :plain
        @atom_start = @quantifiable ? start : nil
        @repeating_group = @quantifiable && repeating
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
        @frames.last.last.last[:set] = atom_set(@out[@atom_start..])
        @repeating_group = false
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
        when 'A'
          plain_token('^')
          # Matching only at the start stops the retry at every position (#polynomial?).
          @frames.last.last << {set: 0, min: 1, max: 1, alternatives: nil} if @groups.empty?
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

      # A repeated group splits one input only one way when its alternatives
      # start with different characters, none can match nothing, and each
      # variable repeat inside is one atom whose characters can't also start
      # what follows it (the next iteration, at the end): +(?:\d{1,3}\.){3}+,
      # +(?:-[a-z0-9]+)*+, +(?:[^"\\]|\\.)*+. Anything else, a group inside
      # included, counts as ambiguous.
      #
      # @param group [Hash] the repeated group's item
      # @return [Boolean]
      def unambiguous?(group)
        alternatives = group[:alternatives]
        return false unless alternatives
        return false if alternatives.any? { |items| items.empty? || items.all? { |inner| nullable?(inner) } }
        return false if alternatives.flatten.any? { |inner| inner[:alternatives] || inner[:lookaround] }

        firsts = alternatives.map { |items| first(items) }
        return false unless firsts.combination(2).all? { |one, other| one.nobits?(other) }

        next_iteration = firsts.reduce(0, :|)
        alternatives.all? do |items|
          items.each_with_index.all? do |inner, index|
            inner[:min] == inner[:max] || inner[:set].nobits?(first(items[(index + 1)..], next_iteration))
          end
        end
      end

      # A polynomial blowup instead: three or more unbounded repeats that can
      # all take the same character, one after another (+\d*\d*\d*x+, also
      # +\d*(?:\d*)\d*x+ and +a*b*a*b*a*x+), can split one input in O(n^k)
      # ways, slow enough on a long one. Two (quadratic) pass.
      #
      # @param items [Array<Hash>] one alternative
      # @return [Boolean]
      def polynomial?(items)
        chars = unbounded(items)
        (0..128).any? { |bit| chars[bit] == 1 && runs(items, 1 << bit)[1] >= 3 }
      end

      # @param items [Array<Hash>]
      # @return [Integer] the characters some unbounded repeat in +items+ takes
      def unbounded(items)
        items.reduce(0) do |chars, inner|
          chars | (inner[:max] == Float::INFINITY ? inner[:set] : 0) |
            (inner[:alternatives] || inner[:body] || []).reduce(0) { |all, nested| all | unbounded(nested) }
        end
      end

      # How many unbounded repeats taking +char+ a split can line up in
      # +items+: at its start, anywhere, and at its end, and whether the
      # whole sequence can pass taking only +char+ (or nothing). Where
      # alternatives differ it takes the largest, which can only refuse more.
      #
      # @param items [Array<Hash>]
      # @param char [Integer] a one-character set
      # @return [Array(Integer, Integer, Integer, Boolean)]
      def runs(items, char)
        items.reduce([0, 0, 0, true]) { |sequence, inner| chain(sequence, item_runs(inner, char)) }
      end

      # @param inner [Hash]
      # @param char [Integer]
      # @return [Array(Integer, Integer, Integer, Boolean)] as {#runs}
      def item_runs(inner, char)
        return lookaround_runs(inner, char) if inner[:body]
        return atom_runs(inner, char) unless inner[:alternatives]

        body = either(inner[:alternatives], char)
        # Three copies are enough to reach three; a bounded count stops sooner.
        result = Array.new([inner[:max], 3].min, body).reduce([0, 0, 0, true]) { |sequence, copy| chain(sequence, copy) }
        # An unbounded group that can take the character counts as one
        # unbounded repeat of it, as a+ does: (?:a)+, and also (?:ab)+, whose
        # iterations line up with the next group's ((?:ab)+(?:ab)+(?:ab)+x).
        result = result[0..2].map { |count| [count, 1].max } + [true] if inner[:max] == Float::INFINITY && inner[:set].anybits?(char)
        result[3] ||= inner[:min].zero?
        result
      end

      # @param alternatives [Array<Array<Hash>>]
      # @param char [Integer]
      # @return [Array(Integer, Integer, Integer, Boolean)] as {#runs}, the
      #   largest of each
      def either(alternatives, char)
        alternatives.map { |items| runs(items, char) }.reduce do |one, other|
          [[one[0], other[0]].max, [one[1], other[1]].max, [one[2], other[2]].max, one[3] || other[3]]
        end
      end

      # A lookaround's repeats run on from the ones before it
      # (+\d*(?=\d*\d*x)+), but it consumes nothing, so none run on after it.
      #
      # @param inner [Hash] a lookaround
      # @param char [Integer]
      # @return [Array(Integer, Integer, Integer, Boolean)] as {#runs}
      def lookaround_runs(inner, char)
        start, best, = either(inner[:body], char)
        [start, best, 0, true]
      end

      # @param inner [Hash] an atom
      # @param char [Integer]
      # @return [Array(Integer, Integer, Integer, Boolean)] as {#runs}
      def atom_runs(inner, char)
        return [1, 1, 1, true] if inner[:max] == Float::INFINITY && inner[:set].anybits?(char)

        [0, 0, 0, inner[:min].zero? || inner[:set].anybits?(char)]
      end

      # @param before [Array(Integer, Integer, Integer, Boolean)] as {#runs}
      # @param after [Array(Integer, Integer, Integer, Boolean)]
      # @return [Array(Integer, Integer, Integer, Boolean)] the two in a row
      def chain(before, after)
        start, best, tail, pass = before
        [pass ? start + after[0] : start, [best, after[1], tail + after[0]].max, after[3] ? tail + after[2] : after[2], pass && after[3]]
      end

      # @param items [Array<Hash>] with no group among them (see #unambiguous?)
      # @param after [Integer] what can start once +items+ all match nothing
      # @return [Integer] the characters the sequence can start with
      def first(items, after = 0)
        set = 0
        items.each do |inner|
          set |= inner[:set]
          return set unless nullable?(inner)
        end
        set | after
      end

      # @param inner [Hash]
      # @return [Boolean]
      def nullable?(inner)
        inner[:min].zero? || inner[:alternatives]&.any? { |items| items.all? { |nested| nullable?(nested) } } || false
      end

      # The characters one emitted ECMA-262 atom matches: a character, an
      # escape, a class or an astral +(?:…)+. Anything unexpected is {ANY}.
      #
      # @param text [String]
      # @return [Integer]
      def atom_set(text)
        return NON_ASCII if text.start_with?('(')
        return class_set(text) if text.start_with?('[')

        chars = scan_member(text, 0)
        chars && chars[1] == text.length ? chars[0] : ANY
      end

      # @param text [String] +[...]+ or +[^...]+
      # @return [Integer]
      def class_set(text)
        negated = text[1] == '^'
        pos = negated ? 2 : 1
        set = 0
        while pos < text.length - 1
          low, pos = scan_member(text, pos) || (return ANY)
          if text[pos] == '-' && pos + 1 < text.length - 1
            high, pos = scan_member(text, pos + 1) || (return ANY)
            set |= span(low, high)
          else
            set |= low
          end
        end
        negated ? (ANY ^ set) | NON_ASCII : set
      end

      # @param low [Integer] a one-character set
      # @param high [Integer] a one-character set
      # @return [Integer] the range between them
      def span(low, high)
        return ANY unless low.positive? && high.positive? && low.nobits?(low - 1) && high.nobits?(high - 1)
        return NON_ASCII if low == NON_ASCII

        top = high == NON_ASCII ? 127 : high.bit_length - 1
        set = (((1 << (top + 1)) - 1) ^ (low - 1))
        high == NON_ASCII ? set | NON_ASCII : set
      end

      # @param text [String]
      # @param pos [Integer]
      # @return [Array(Integer, Integer), nil] the member's set and where
      #   the next one starts
      def scan_member(text, pos)
        char = text[pos] or return nil
        return [char.ord < 128 ? 1 << char.ord : NON_ASCII, pos + 1] unless char == '\\'

        escaped = text[pos + 1] or return nil
        case escaped
        when 'd' then [digits, pos + 2]
        when 'D' then [(ANY ^ digits) | NON_ASCII, pos + 2]
        when 'w' then [word, pos + 2]
        when 'W' then [(ANY ^ word) | NON_ASCII, pos + 2]
        when 's' then [chars("\t\n\v\f\r "), pos + 2]
        when 'S' then [(ANY ^ chars("\t\n\v\f\r ")) | NON_ASCII, pos + 2]
        when 'x' then code(text[pos + 2, 2], pos + 4)
        when 'u' then code(text[pos + 2, 4], pos + 6)
        when 'c' then [1 << (text[pos + 2].ord & 0x1F), pos + 3]
        else [1 << ESCAPED.fetch(escaped, escaped).ord, pos + 2]
        end
      end

      # @param hex [String, nil]
      # @param after [Integer]
      # @return [Array(Integer, Integer), nil]
      def code(hex, after)
        return nil unless hex&.match?(/\A\h+\z/)

        value = hex.to_i(16)
        [value < 128 ? 1 << value : NON_ASCII, after]
      end

      # @return [Integer]
      def digits = chars('0123456789')

      # @return [Integer]
      def word = chars(['0'..'9', 'a'..'z', 'A'..'Z'].flat_map(&:to_a).join << '_')

      # @param list [String]
      # @return [Integer]
      def chars(list) = list.each_char.reduce(0) { |set, char| set | (1 << char.ord) }

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
