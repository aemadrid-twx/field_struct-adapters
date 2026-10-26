# frozen_string_literal: true

module FieldStruct
  # Generates a JSON Schema (draft 2020-12) describing the JSON a
  # {FieldStruct::Base} subclass reads and writes: what +to_json+ emits for a
  # valid instance, which +from_json+ reads back. Other tools take it from
  # there: API docs, validators in other languages, LLM tool definitions,
  # TypeScript types.
  #
  #   class User < FieldStruct::Base
  #     required :name, :string
  #     optional :age,  :integer, in: 0..150
  #   end
  #
  #   FieldStruct::JSONSchema.generate(User)
  #   # => {"$schema"=>"https://json-schema.org/draft/2020-12/schema",
  #   #     "title"=>"User", "type"=>"object",
  #   #     "properties"=>{"name"=>{"type"=>"string"},
  #   #                    "age"=>{"type"=>["integer", "null"], "minimum"=>0, "maximum"=>150}},
  #   #     "required"=>["name"]}
  #
  # Design choices:
  #
  # * **The schema describes the canonical JSON, not every input the
  #   setters coerce.** +age: "30"+ is a valid assignment but not valid
  #   against +"type": "integer"+. BigDecimal is a string (as +to_json+
  #   writes it), times are RFC 3339 +date-time+ strings.
  # * **Property names** are the +serialize :json+ external names (see
  #   {Base.serialize}); pass +serialization:+ to describe another format's.
  # * **Required** lists required fields without a +default:+; a required
  #   field with a default may be left out of the input. Optional fields
  #   accept +null+, and so does every array element (validation skips
  #   +nil+ elements). An optional String-family field with +enum:+ or a
  #   +format:+ also accepts a blank string, which counts as missing there.
  # * **Constraints** map where JSON Schema has a keyword: +enum:+ → +enum+,
  #   an +in:+ Range → +minimum+ / +maximum+ / +exclusiveMaximum+ (an
  #   infinite end is left open), an +in:+ Array → +enum+, a Regexp
  #   +format:+ → +pattern+, translated to ECMA-262 by {.pattern_for}. A
  #   Regexp with no exact translation is kept as +x-ruby-pattern+, an
  #   annotation no validator checks; which Regexps translate can grow
  #   between versions. +in:+ on dates, times and decimals has no keyword
  #   and is left out.
  # * **UUID, URL, Email** are described by the Regexp the struct checks:
  #   the default UUID one is +format: uuid+; URL and Email defaults become
  #   patterns, since JSON Schema's +uri+ and +email+ are stricter. An array
  #   of them checks nothing unless +element:+ gives a +format:+.
  # * **Nested structs** go in +$defs+ under their class name and are
  #   referenced with +$ref+; the root class is +#+, so recursive structs
  #   work. An anonymous nested struct is inlined.
  # * **Annotations:** +description:+ → +description+; a +default:+ that is
  #   already a literal of the field's JSON type → +default+ (a callable,
  #   or one the setter would convert, is left out);
  #   +sensitive: true+ → +x-sensitive+ (+to_json+ still writes the value).
  # * **Overrides:** a field's +json_schema:+ option, then the type's
  #   {Types::Base#json_schema}, replace the derived schema of a present
  #   value (an optional field still adds +null+). A
  #   custom type with neither is unconstrained (+{}+) and named with
  #   +x-ruby-type+. +unknown_attributes :raise+ sets
  #   +additionalProperties: false+.
  module JSONSchema
    # The +$schema+ URI every {.generate} result declares.
    # @return [String]
    DRAFT = 'https://json-schema.org/draft/2020-12/schema'

    # What +to_json+ writes for a BigDecimal: plain digits with a fraction.
    # @return [String]
    DECIMAL_PATTERN = '^-?[0-9]+\.[0-9]+$'

    # What an optional String-family field may hold besides a valid value:
    # a blank string is "missing" there (it skips +enum:+ and +format:+), and
    # +to_json+ writes it as is. These are the characters Ruby's +strip+
    # removes.
    # @return [Hash{String=>String}]
    BLANK_STRING = {'type' => 'string', 'pattern' => '^[\x00\t\n\v\f\r ]*$'}.freeze

    # Regexp options JSON Schema's +pattern+ can't carry (+/i+ is folded into
    # the pattern instead).
    # @return [Integer]
    UNSUPPORTED_OPTIONS = Regexp::EXTENDED | Regexp::MULTILINE
    private_constant :UNSUPPORTED_OPTIONS

    # Generate the JSON Schema for a FieldStruct subclass.
    #
    # @param klass [Class<FieldStruct::Base>]
    # @param serialization [Symbol, String] the +serialize+ format whose external
    #   names become property names (an undeclared format uses the field
    #   names, as its serializer does)
    # @return [Hash{String=>Object}] the schema, with String keys, ready for
    #   +Oj.dump+. It's a fresh copy: changing it doesn't touch the class.
    # @raise [ArgumentError] when +klass+ is not a {FieldStruct::Base}
    #   subclass, or +serialization+ is not a Symbol or String
    def self.generate(klass, serialization: :json)
      unless klass.is_a?(::Class) && klass < FieldStruct::Base
        raise ArgumentError,
          "FieldStruct::JSONSchema.generate expects a FieldStruct::Base subclass, got #{klass.inspect}"
      end
      # +serialize 'json', …+ declares the format as a Symbol, so a String names it too.
      serialization = serialization.to_sym if serialization.is_a?(::String)
      unless serialization.is_a?(::Symbol)
        raise ArgumentError,
          "FieldStruct::JSONSchema.generate expects serialization: to be a Symbol, got #{serialization.inspect}"
      end

      deep_copy(Builder.new(klass, serialization).schema)
    end

    # Translate a Regexp to an ECMA-262 +pattern+ string that matches the
    # same strings, with or without the +u+ flag. See {Pattern} for the rules.
    #
    #   FieldStruct::JSONSchema.pattern_for(/\A\d+\.\d+\z/)  # => "^\\d+\\.\\d+$"
    #   FieldStruct::JSONSchema.pattern_for(/\A\h+\z/i)      # => "^[0-9a-fA-F]+$"
    #   FieldStruct::JSONSchema.pattern_for(/\A(?>a+)\z/)    # => nil
    #
    # @param regexp [Regexp]
    # @return [String, nil] the pattern, or +nil+ when there's no exact
    #   ECMA-262 equivalent
    # @raise [ArgumentError] when +regexp+ is not a Regexp
    def self.pattern_for(regexp)
      unless regexp.is_a?(::Regexp)
        raise ArgumentError, "FieldStruct::JSONSchema.pattern_for expects a Regexp, got #{regexp.inspect}"
      end
      return nil unless regexp.options.nobits?(UNSUPPORTED_OPTIONS)

      Pattern.new(regexp.source, fold_case: regexp.options.anybits?(Regexp::IGNORECASE)).to_s
    end

    # @param value [Object] part of a generated schema
    # @return [Object] +value+ with every Hash, Array and String copied, so a
    #   caller can't reach the field options the schema was built from
    def self.deep_copy(value)
      case value
      when ::Hash then value.to_h { |key, item| [deep_copy(key), deep_copy(item)] }
      when ::Array then value.map { |item| deep_copy(item) }
      when ::String then value.dup
      else value
      end
    end
    private_class_method :deep_copy

    # Walks one root class, collecting named nested structs into +$defs+.
    # @api private
    class Builder
      # @param root [Class<FieldStruct::Base>]
      # @param serialization [Symbol]
      def initialize(root, serialization)
        @root = root
        @serialization = serialization
        @defs = {}
        @inlining = []
      end

      # @return [Hash{String=>Object}]
      def schema
        out = {'$schema' => DRAFT}
        out['title'] = @root.name if named?(@root)
        out.merge!(object_schema(@root))
        out['$defs'] = @defs unless @defs.empty?
        out
      end

      private

      # @param klass [Class<FieldStruct::Base>]
      # @return [Hash{String=>Object}]
      def object_schema(klass)
        names = klass.metadata.serialization(@serialization)
        properties = {}
        required = []
        klass.metadata.each do |field|
          key = (names[field.name] || field.name).to_s
          properties[key] = property_schema(field)
          required << key if field.required? && field.default.nil?
        end
        out = {'type' => 'object', 'properties' => properties}
        out['required'] = required unless required.empty?
        out['additionalProperties'] = false if klass.unknown_attributes == :raise
        out
      end

      # @param field [Field]
      # @return [Hash{String=>Object}]
      def property_schema(field)
        override = override(field.options[:json_schema]) || override(field.type_instance.json_schema)
        schema = override || value_schema(field.type_instance, field.options)
        annotations(field).merge(field.required? ? schema : optional(schema, field.type_instance))
      end

      # An optional field's schema: +null+ too (an override describes a
      # present value, so it gets +null+ like any other), plus a blank string
      # when the field is String-family and its schema would refuse one.
      #
      # @param schema [Hash{String=>Object}]
      # @param type [Types::Base]
      # @return [Hash{String=>Object}]
      def optional(schema, type)
        schema = nullable(schema)
        return schema unless type.is_a?(FieldStruct::Types::String) && schema.keys.intersect?(%w[enum pattern format])

        {'anyOf' => [schema, BLANK_STRING]}
      end

      # @param field [Field]
      # @return [Hash{String=>Object}]
      def annotations(field)
        out = {}
        out['description'] = field.description if field.description
        default = json_default(field)
        out['default'] = default unless default.nil?
        out['x-sensitive'] = true if field.sensitive?
        out
      end

      # The declared default as +to_json+ writes it, when that's certain
      # without coercing: a literal of the field's own JSON type. Anything
      # else (a callable, a value the setter would convert) is left out.
      #
      # @param field [Field]
      # @return [Object, nil]
      def json_default(field)
        value = field.default
        case field.type_instance
        when FieldStruct::Types::Boolean then value if [true, false].include?(value)
        when FieldStruct::Types::Integer then value if value.is_a?(::Integer)
        when FieldStruct::Types::Float then value.to_f if value.is_a?(::Integer) || (value.is_a?(::Float) && value.finite?)
        when FieldStruct::Types::Symbol then value.to_s if value.is_a?(::Symbol)
        when FieldStruct::Types::String then value if value.is_a?(::String)
        when FieldStruct::Types::Value then value if json_value?(value)
        end
      end

      # @param value [Object]
      # @return [Boolean] whether +value+ is a non-nil JSON value
      def json_value?(value)
        case value
        when ::String, ::Integer, ::Float, true, false then true
        when ::Array then value.all? { |item| item.nil? || json_value?(item) }
        when ::Hash then value.all? { |key, item| key.is_a?(::String) && (item.nil? || json_value?(item)) }
        else false
        end
      end

      # @param type [Types::Base]
      # @param options [Hash{Symbol=>Object}]
      # @return [Hash{String=>Object}]
      def value_schema(type, options)
        case type
        when FieldStruct::Types::Array then array_schema(options)
        when FieldStruct::Types::Union then union_schema(type)
        when FieldStruct::Types::Nested then ref_for(type.struct_class)
        else scalar_schema(type, options)
        end
      end

      # @param options [Hash{Symbol=>Object}] the array field's options
      # @return [Hash{String=>Object}]
      def array_schema(options)
        of_type = options[:of_type]
        # An array of arrays or of unions carries no element type to describe.
        return {'type' => 'array'} if of_type.nil? || (of_type.is_a?(::Class) && of_type <= FieldStruct::Types::Union)

        element = of_type.is_a?(::Class) ? of_type.new : of_type
        items = override(element.json_schema) || value_schema(element, options[:element] || {})
        # Any element may be nil, a nested one too: validation skips nil elements.
        {'type' => 'array', 'items' => nullable(items)}
      end

      # @param union [Types::Union]
      # @return [Hash{String=>Object}] +{}+ when a member accepts anything
      def union_schema(union)
        members = union.member_types.map { |member| override(member.json_schema) || value_schema(member, {}) }
        return {} if members.include?({})

        {'anyOf' => members.uniq}
      end

      # @param klass [Class<FieldStruct::Base>]
      # @return [Hash{String=>Object}]
      def ref_for(klass)
        return {'$ref' => '#'} if klass.equal?(@root)
        return inline(klass) unless named?(klass)

        unless @defs.key?(klass.name)
          @defs[klass.name] = {} # reserve the slot so a cycle refers back to it
          @defs[klass.name] = {'title' => klass.name}.merge(object_schema(klass))
        end
        {'$ref' => "#/$defs/#{klass.name}"}
      end

      # @param klass [Class<FieldStruct::Base>]
      # @return [Boolean] whether +klass+ has a name usable as a +$defs+ key
      #   and title (one under an anonymous module reads "#<Module:0x…>::Addr")
      def named?(klass)
        !klass.name.nil? && !klass.name.include?('#<')
      end

      # @param klass [Class<FieldStruct::Base>] an anonymous struct
      # @return [Hash{String=>Object}]
      # @raise [ArgumentError] when the anonymous struct nests itself
      def inline(klass)
        raise ArgumentError, 'FieldStruct::JSONSchema cannot describe a recursive anonymous struct; assign it to a constant' if @inlining.include?(klass)

        @inlining.push(klass)
        object_schema(klass)
      ensure
        @inlining.delete(klass)
      end

      # @param type [Types::Base]
      # @param options [Hash{Symbol=>Object}]
      # @return [Hash{String=>Object}]
      def scalar_schema(type, options)
        case type
        when FieldStruct::Types::Boolean then {'type' => 'boolean'}
        when FieldStruct::Types::Integer then range({'type' => 'integer'}, options[:in])
        when FieldStruct::Types::Float then range({'type' => 'number'}, options[:in])
        when FieldStruct::Types::BigDecimal then {'type' => 'string', 'pattern' => DECIMAL_PATTERN}
        when FieldStruct::Types::Date then temporal('date', options[:format], %i[iso8601])
        when FieldStruct::Types::Time, FieldStruct::Types::DateTime
          temporal('date-time', options[:format], %i[iso8601])
        when FieldStruct::Types::Symbol then enum({'type' => 'string'}, options[:enum]&.map(&:to_s))
        when FieldStruct::Types::String then string_schema(type, options)
        when FieldStruct::Types::Value then {}
        else custom_schema(type)
        end
      end

      # The struct checks a String-family value only against the +format:+
      # Regexp in +options+ (UUID, URL and Email fields get their default
      # when none is declared; array elements get one only through
      # +element:+), so that Regexp is the whole constraint. JSON Schema's
      # +email+ and +uri+ formats are stricter than our defaults, so those
      # become patterns; the default UUID Regexp is exactly +format: uuid+.
      #
      # @param type [Types::String] a String-family type
      # @param options [Hash{Symbol=>Object}]
      # @return [Hash{String=>Object}]
      def string_schema(type, options)
        out = {'type' => 'string'}
        format = options[:format]
        if format.is_a?(::Regexp)
          if type.is_a?(FieldStruct::Types::UUID) && format == FieldStruct::Types::UUID.default_format
            out['format'] = 'uuid'
          else
            pattern = JSONSchema.pattern_for(format)
            pattern ? out['pattern'] = pattern : out['x-ruby-pattern'] = format.source
          end
        end
        enum(out, options[:enum])
      end

      # @param format [String] the JSON Schema format of the canonical output
      # @param option [String, Symbol, nil] the field's +format:+
      # @param canonical [Array<Symbol>] presets that write the canonical form
      # @return [Hash{String=>Object}]
      def temporal(format, option, canonical)
        return {'type' => 'string', 'format' => format} if option.nil? || canonical.include?(option)

        {'type' => 'string'}
      end

      # @param schema [Hash{String=>Object}]
      # @param values [Array<Object>, nil]
      # @return [Hash{String=>Object}]
      def enum(schema, values)
        values ? schema.merge('enum' => values) : schema
      end

      # @param schema [Hash{String=>Object}]
      # @param bound [Range<Numeric>, Array<Object>, nil] an +in:+ option
      # @return [Hash{String=>Object}]
      def range(schema, bound)
        case bound
        when ::Array then schema.merge('enum' => bound)
        when ::Range
          out = schema.dup
          low = json_number(bound.begin)
          high = json_number(bound.end)
          out['minimum'] = low unless low.nil?
          out[bound.exclude_end? ? 'exclusiveMaximum' : 'maximum'] = high unless high.nil?
          out
        else schema
        end
      end

      # @param bound [Numeric, nil] a Range end
      # @return [Integer, Float, nil] a JSON number, or +nil+ for an open or
      #   infinite end (JSON has no Infinity)
      def json_number(bound)
        return nil if bound.nil? || (bound.respond_to?(:infinite?) && bound.infinite?)

        bound.is_a?(::Integer) || bound.is_a?(::Float) ? bound : bound.to_f
      end

      # @param type [Types::Base] a type FieldStruct doesn't ship
      # @return [Hash{String=>Object}]
      def custom_schema(type)
        ruby_type = type.ruby_type
        names = Array(ruby_type).map { |klass| klass.name || klass.inspect }
        {'x-ruby-type' => names.join(' | ')}
      end

      # A +json_schema:+ override (field option or {Types::Base#json_schema})
      # as a Hash: the boolean schemas become their object forms.
      #
      # @param value [Hash{String=>Object}, Boolean, nil]
      # @return [Hash{String=>Object}, nil]
      # @raise [ArgumentError] for anything else
      def override(value)
        case value
        when nil, ::Hash then value
        when true then {}
        when false then {'not' => {}}
        else raise ArgumentError, "json_schema: must be a Hash or a boolean, got #{value.inspect}"
        end
      end

      # @param schema [Hash{String=>Object}]
      # @return [Hash{String=>Object}] +schema+ also accepting +null+
      def nullable(schema)
        return schema if schema.empty? || (schema.key?('x-ruby-type') && schema.size == 1)

        type = schema['type']
        if type.is_a?(::String) && !schema.key?('$ref')
          out = schema.merge('type' => [type, 'null'])
          out['enum'] = schema['enum'] + [nil] if schema.key?('enum')
          out
        elsif schema.key?('anyOf')
          schema.merge('anyOf' => schema['anyOf'] + [{'type' => 'null'}])
        else
          {'anyOf' => [schema, {'type' => 'null'}]}
        end
      end
    end
  end
end
