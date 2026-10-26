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
  #   accept +null+, and an array's scalar elements may be +null+ (nested
  #   elements may not, as a +nil+ nested element is invalid).
  # * **Constraints** map where JSON Schema has a keyword: +enum:+ → +enum+,
  #   an +in:+ Range → +minimum+ / +maximum+ / +exclusiveMaximum+, an +in:+
  #   Array → +enum+, a Regexp +format:+ → +pattern+ (translated to ECMA-262:
  #   +\A+ / +\z+ become +^+ / +$+). A Regexp JSON Schema can't express
  #   (flags, possessive quantifiers, atomic groups, +\h+, POSIX brackets)
  #   is kept as +x-ruby-pattern+ instead. +in:+ on dates, times and
  #   decimals has no keyword and is left out.
  # * **Nested structs** go in +$defs+ under their class name and are
  #   referenced with +$ref+; the root class is +#+, so recursive structs
  #   work. An anonymous nested struct is inlined.
  # * **Annotations:** +description:+ → +description+; a literal +default:+
  #   that is a JSON value → +default+ (a callable default is left out);
  #   +sensitive: true+ → +x-sensitive+ (+to_json+ still writes the value).
  # * **Overrides:** a field's +json_schema:+ option, then the type's
  #   {Types::Base#json_schema}, replace the derived schema verbatim. A
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

    # Ruby Regexp syntax with no ECMA-262 equivalent: atomic groups, inline
    # flags, possessive quantifiers, POSIX brackets. Matched against the
    # source with escapes removed.
    # @return [Regexp]
    RUBY_ONLY_SYNTAX = /\(\?>|\(\?[imx-]+[:)]|[*+?}]\+|\[\[:/
    private_constant :RUBY_ONLY_SYNTAX

    # Escapes with no ECMA-262 equivalent (or a different meaning there).
    # @return [Array<String>]
    RUBY_ONLY_ESCAPES = %w[h H G K R X Z].freeze
    private_constant :RUBY_ONLY_ESCAPES

    # Regexp options JSON Schema's +pattern+ can't carry.
    # @return [Integer]
    UNSUPPORTED_OPTIONS = Regexp::IGNORECASE | Regexp::EXTENDED | Regexp::MULTILINE
    private_constant :UNSUPPORTED_OPTIONS

    # Generate the JSON Schema for a FieldStruct subclass.
    #
    # @param klass [Class<FieldStruct::Base>]
    # @param serialization [Symbol] the +serialize+ format whose external
    #   names become property names
    # @return [Hash{String=>Object}] the schema, with String keys, ready for
    #   +Oj.dump+
    # @raise [ArgumentError] when +klass+ is not a {FieldStruct::Base}
    #   subclass
    def self.generate(klass, serialization: :json)
      unless klass.is_a?(::Class) && klass < FieldStruct::Base
        raise ArgumentError,
          "FieldStruct::JSONSchema.generate expects a FieldStruct::Base subclass, got #{klass.inspect}"
      end

      Builder.new(klass, serialization).schema
    end

    # Translate a Regexp to an ECMA-262 +pattern+ string.
    #
    # @param regexp [Regexp]
    # @return [String, nil] the pattern, or +nil+ when JSON Schema can't
    #   express the Regexp
    def self.pattern_for(regexp)
      return nil unless regexp.options.nobits?(UNSUPPORTED_OPTIONS)

      source = regexp.source
      return nil if source.gsub(/\\./m, '').match?(RUBY_ONLY_SYNTAX)

      unsupported = false
      pattern = source.gsub(/\\(.)/m) do |escape|
        case Regexp.last_match(1)
        when 'A' then '^'
        when 'z' then '$'
        when *RUBY_ONLY_ESCAPES then (unsupported = true) && escape
        else escape
        end
      end
      unsupported ? nil : pattern
    end

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
        out['title'] = @root.name if @root.name
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
        override = field.options[:json_schema] || field.type_instance.json_schema
        schema = override || value_schema(field.type_instance, field.options)
        schema = nullable(schema) unless field.required? || override
        annotations(field).merge(schema)
      end

      # @param field [Field]
      # @return [Hash{String=>Object}]
      def annotations(field)
        out = {}
        out['description'] = field.description if field.description
        out['default'] = field.default if json_value?(field.default)
        out['x-sensitive'] = true if field.sensitive?
        out
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
        element = of_type.is_a?(::Class) ? of_type.new : of_type
        items = element.json_schema || value_schema(element, options[:element] || {})
        items = nullable(items) unless element.is_a?(FieldStruct::Types::Nested)
        {'type' => 'array', 'items' => items}
      end

      # @param union [Types::Union]
      # @return [Hash{String=>Object}] +{}+ when a member accepts anything
      def union_schema(union)
        members = union.member_types.map { |member| member.json_schema || value_schema(member, {}) }
        return {} if members.include?({})

        {'anyOf' => members.uniq}
      end

      # @param klass [Class<FieldStruct::Base>]
      # @return [Hash{String=>Object}]
      def ref_for(klass)
        return {'$ref' => '#'} if klass.equal?(@root)
        return inline(klass) unless klass.name

        unless @defs.key?(klass.name)
          @defs[klass.name] = {} # reserve the slot so a cycle refers back to it
          @defs[klass.name] = {'title' => klass.name}.merge(object_schema(klass))
        end
        {'$ref' => "#/$defs/#{klass.name}"}
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

      # @param type [Types::String] a String-family type
      # @param options [Hash{Symbol=>Object}]
      # @return [Hash{String=>Object}]
      def string_schema(type, options)
        out = {'type' => 'string'}
        case type
        when FieldStruct::Types::UUID then out['format'] = 'uuid'
        when FieldStruct::Types::URL then out['format'] = 'uri'
        when FieldStruct::Types::Email then out['format'] = 'email'
        end
        format = options[:format]
        if format.is_a?(::Regexp) && !default_format?(type, format)
          pattern = JSONSchema.pattern_for(format)
          pattern ? out['pattern'] = pattern : out['x-ruby-pattern'] = format.source
        end
        enum(out, options[:enum])
      end

      # @param type [Types::String]
      # @param format [Regexp]
      # @return [Boolean] whether +format+ is the type's own default (UUID,
      #   URL, Email), which its +format+ keyword already describes
      def default_format?(type, format)
        type.class.respond_to?(:default_format) && type.class.default_format == format
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
          out['minimum'] = bound.begin unless bound.begin.nil?
          out[bound.exclude_end? ? 'exclusiveMaximum' : 'maximum'] = bound.end unless bound.end.nil?
          out
        else schema
        end
      end

      # @param type [Types::Base] a type FieldStruct doesn't ship
      # @return [Hash{String=>Object}]
      def custom_schema(type)
        ruby_type = type.ruby_type
        names = Array(ruby_type).map { |klass| klass.name || klass.inspect }
        {'x-ruby-type' => names.join(' | ')}
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
