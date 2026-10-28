# frozen_string_literal: true

require 'json'
require 'field_struct'
unless defined?(FieldStruct::Introspection)
  raise LoadError, "field_struct-json_schema needs FieldStruct::Introspection, which field_struct #{FieldStruct::VERSION} doesn't have; " \
                   'use a field_struct with it (develop, until the next release)'
end
require_relative 'json_schema/version'
require_relative 'json_schema/pattern'

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
  #   FieldStruct::JSONSchema.generate(User)   # or User.to_json_schema, with Methods
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
  #   +format:+ also accepts a blank string, which counts as missing there
  #   (for +:binary+, only an empty one).
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
  #   +sensitive: true+ → +x-sensitive+, and no +default+ (+to_json+ still
  #   writes the value).
  # * **Overrides:** a field's +json_schema:+ option, then the type's own
  #   +json_schema+ method (define one on a custom type), replace the derived schema of a present
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

    # The same for a type where only an empty string is missing (+:binary+):
    # a blank one is a value there, and must match.
    # @return [Hash{String=>Object}]
    EMPTY_STRING = {'type' => 'string', 'maxLength' => 0}.freeze

    # Regexp options JSON Schema's +pattern+ can't carry (+/i+ is folded into
    # the pattern instead).
    # @return [Integer]
    UNSUPPORTED_OPTIONS = Regexp::EXTENDED | Regexp::MULTILINE
    private_constant :UNSUPPORTED_OPTIONS

    # Forgets every schema built so far. The cache holds each struct class
    # it has seen, so under code reloading (Rails in development) call this
    # on each reload; the next {.generate} rebuilds what it needs.
    #
    # @return [void]
    def self.clear_cache
      CACHE.clear
    end

    # Generate the JSON Schema for a FieldStruct subclass.
    #
    # @param klass [Class<FieldStruct::Base>]
    # @param serialization [Symbol, String] the +serialize+ format whose external
    #   names become property names (an undeclared format uses the field
    #   names, as its serializer does)
    # @return [Hash{String=>Object}] the schema, with String keys, ready for
    #   +Oj.dump+. It's a fresh copy: changing it doesn't touch the class.
    # @raise [ArgumentError] when +klass+ is not a {FieldStruct::Base}
    #   subclass, +serialization+ is not a Symbol or String, an anonymous
    #   struct nests itself, or a +json_schema:+ option (or a type's
    #   +json_schema+) is neither a Hash nor a boolean
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

      deep_copy(CACHE.schema(klass, serialization))
    end

    # Translate a Regexp to an ECMA-262 +pattern+ string that matches the
    # same strings under the +u+ flag. See {Pattern} for the rules.
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

      Pattern.new(regexp.source, fold_case: regexp.options.anybits?(Regexp::IGNORECASE)).translate
    end

    # @param value [Object] part of a generated schema
    # @return [Object] +value+ with every Hash, Array and String copied, so a
    #   caller can't reach the field options the schema was built from
    # @api private
    def self.deep_copy(value)
      case value
      # A Hash freezes its own copy of a String key, so the keys are already
      # unreachable from the field options and can be shared.
      when ::Hash then value.to_h { |key, item| [key, deep_copy(item)] }
      when ::Array then value.map { |item| deep_copy(item) }
      when ::String then value.dup
      else value
      end
    end

    # The built schema per class and serialization, so {.generate} only
    # copies it. An entry is rebuilt when any class it covers changes its
    # fields, serialization mapping, name or +unknown_attributes+ policy. A
    # schema that asked a type's own +json_schema+ method is never kept:
    # that method may answer differently next time.
    #
    # @api private
    class Cache
      # A cached schema and the stamps it is valid for.
      class Entry
        # @return [Hash{String=>Object}]
        attr_reader :schema
        # @return [Hash{Class<FieldStruct::Base>=>Array<Object>}]
        attr_reader :stamps

        # @param schema [Hash{String=>Object}]
        # @param stamps [Hash{Class<FieldStruct::Base>=>Array<Object>}]
        def initialize(schema, stamps)
          @schema = schema
          @stamps = stamps
          freeze
        end
      end

      def initialize
        @entries = {}
        @lock = Mutex.new
      end

      # Drops every entry, and with them the classes they hold.
      # @return [void]
      def clear
        @lock.synchronize { @entries = {} }
        nil
      end

      # @param klass [Class<FieldStruct::Base>]
      # @param serialization [Symbol]
      # @return [Hash{String=>Object}] frozen when cached, so callers copy
      #   it; a schema that asked a type's +json_schema+ comes back as built
      def schema(klass, serialization)
        key = [klass, serialization]
        entry = @entries[key]
        return entry.schema if entry && fresh?(entry.stamps, serialization)

        builder = Builder.new(klass, serialization)
        built = builder.schema
        return built if builder.hooked?

        # Builder puts field defaults and options (enum:, in:, json_schema:)
        # into the schema as they are; copy before freezing, so the class's
        # own objects stay unfrozen.
        schema = deep_freeze(JSONSchema.deep_copy(built))
        entry = Entry.new(schema, builder.stamps.freeze)
        @lock.synchronize { @entries[key] = entry }
        schema
      end

      # @param klass [Class<FieldStruct::Base>]
      # @param serialization [Symbol]
      # @return [Array<Object>] the fields, mapping, name and unknown_attributes policy
      def self.stamp(klass, serialization)
        meta = klass.metadata
        [meta.to_a.freeze, meta.serialization(serialization), klass.name, klass.unknown_attributes].freeze
      end

      private

      # Only on a miss, so {JSONSchema.deep_copy}, which every
      # {JSONSchema.generate} runs, stays a plain copy.
      #
      # @param value [Object]
      # @return [Object] +value+, frozen all the way down
      def deep_freeze(value)
        case value
        when ::Hash
          value.each do |key, item|
            deep_freeze(key)
            deep_freeze(item)
          end
        when ::Array then value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end

      # @param stamps [Hash{Class<FieldStruct::Base>=>Array<Object>}]
      # @param serialization [Symbol]
      # @return [Boolean]
      def fresh?(stamps, serialization)
        stamps.all? do |klass, (fields, mapping, name, unknown)|
          meta = klass.metadata
          meta.serialization(serialization).equal?(mapping) && klass.name == name &&
            klass.unknown_attributes == unknown && meta.to_a == fields
        end
      end
    end

    # The process-wide cache {.generate} reads.
    #
    # @api private
    # @return [Cache]
    CACHE = Cache.new

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
        @stamps = {}
        @hooked = false
        # The field being described, as Class#field, for error messages.
        @fields = []
      end

      # @return [Boolean] whether a type's own +json_schema+ method was asked
      def hooked?
        @hooked
      end

      # {Cache.stamp} of every class {#schema} described (the root, +$defs+,
      # inlined anonymous ones), taken before the class was read, so a class
      # changed while the schema was built makes the entry stale rather than
      # a stale entry look fresh.
      # @return [Hash{Class<FieldStruct::Base>=>Array<Object>}]
      attr_reader :stamps

      # @return [Hash{String=>Object}]
      def schema
        out = {'$schema' => DRAFT}
        out['title'] = @root.name if Introspection.named?(@root)
        out.merge!(object_schema(@root))
        out['$defs'] = @defs unless @defs.empty?
        out
      end

      private

      # @param klass [Class<FieldStruct::Base>]
      # @return [Hash{String=>Object}]
      def object_schema(klass)
        @stamps[klass] ||= Cache.stamp(klass, @serialization)
        properties = {}
        required = []
        Introspection.properties(klass, serialization: @serialization).each do |property|
          field = property.field
          properties[property.key] = property_schema(property, klass)
          required << property.key if field.required? && field.default.nil?
        end
        out = {'type' => 'object', 'properties' => properties}
        out['required'] = required unless required.empty?
        out['additionalProperties'] = false if klass.unknown_attributes == :raise
        out
      end

      # @param property [FieldStruct::Introspection::Property]
      # @param klass [Class<FieldStruct::Base>] the struct it belongs to, for errors
      # @return [Hash{String=>Object}]
      def property_schema(property, klass)
        field = property.field
        # A field of an anonymous struct chains from the field holding it.
        @fields.push(Introspection.named?(klass) || @fields.empty? ? "#{klass.name || klass.inspect}##{field.name}" : "#{@fields.last}.#{field.name}")
        option = field.options[:json_schema]
        schema = override(option) { "the json_schema: option of #{@fields.last}" } || node_schema(property.node)
        annotations(field).merge(field.required? ? schema : optional(schema, field.type_instance))
      ensure
        @fields.pop
      end

      # An optional field's schema: +null+ too (an override describes a
      # present value, so it gets +null+ like any other), plus the strings
      # the struct treats as missing (a blank one, or for +:binary+ only an
      # empty one) when the field is String-family and its schema would
      # refuse them.
      #
      # @param schema [Hash{String=>Object}]
      # @param type [FieldStruct::Types::Base]
      # @return [Hash{String=>Object}]
      def optional(schema, type)
        schema = nullable(schema)
        return schema unless type.is_a?(FieldStruct::Types::String) && schema.keys.intersect?(%w[enum pattern format])

        if type.missing?(' ') then {'anyOf' => [schema, BLANK_STRING]}
        elsif type.missing?('') then {'anyOf' => [schema, EMPTY_STRING]}
        else schema
        end
      end

      # @param field [FieldStruct::Field]
      # @return [Hash{String=>Object}]
      def annotations(field)
        out = {}
        out['description'] = field.description if field.description
        # A sensitive field's default stays out: schemas go to API docs,
        # registries and LLM tools, and the default may be a placeholder secret.
        default = field.sensitive? ? nil : json_default(field)
        out['default'] = default unless default.nil?
        out['x-sensitive'] = true if field.sensitive?
        out
      end

      # The declared default as +to_json+ writes it, when that's certain
      # without coercing: a literal of the field's own JSON type. Anything
      # else (a callable, a value the setter would convert) is left out.
      #
      # @param field [FieldStruct::Field]
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

      # The node's schema: what its type's own +json_schema+ method returns,
      # when the type defines one, else derived from the node.
      #
      # @param node [FieldStruct::Introspection::ScalarNode, FieldStruct::Introspection::ArrayNode,
      #   FieldStruct::Introspection::UnionNode, FieldStruct::Introspection::StructNode]
      # @return [Hash{String=>Object}]
      def node_schema(node)
        hook = node.type.respond_to?(:json_schema)
        @hooked ||= hook
        override(hook ? hook_schema(node.type) : nil) { "#{hook_name(node.type)} (for #{@fields.last})" } ||
          case node
          when Introspection::ArrayNode then array_schema(node)
          when Introspection::UnionNode then union_schema(node)
          when Introspection::StructNode then ref_for(node.klass)
          else scalar_schema(node.type, node.options)
          end
      end

      # Calls a custom type's +json_schema+ method, naming the type and the
      # field when it raises: the exception is the app's, but the log line
      # should say where it came from.
      #
      # @param type [FieldStruct::Types::Base]
      # @return [Object] what the method returned
      # @raise [ArgumentError] when the method raises, with its error as +cause+
      def hook_schema(type)
        type.json_schema
      rescue StandardError => e
        raise ArgumentError, "FieldStruct::JSONSchema.generate: #{hook_name(type)} raised #{e.class} " \
                             "(for #{@fields.last}): #{e.message}"
      end

      # @param type [FieldStruct::Types::Base]
      # @return [String] like +Money#json_schema+
      def hook_name(type)
        "#{type.class.name || type.class.inspect}#json_schema"
      end

      # @param node [FieldStruct::Introspection::ArrayNode]
      # @return [Hash{String=>Object}]
      def array_schema(node)
        # An array of arrays or of unions carries no element type to describe.
        return {'type' => 'array'} unless node.element

        # Any element may be nil, a nested one too: validation skips nil elements.
        {'type' => 'array', 'items' => nullable(node_schema(node.element))}
      end

      # @param node [FieldStruct::Introspection::UnionNode]
      # @return [Hash{String=>Object}] +{}+ when a member accepts anything
      def union_schema(node)
        members = node.members.map { |member| node_schema(member) }
        return {} if members.include?({})

        {'anyOf' => members.uniq}
      end

      # @param klass [Class<FieldStruct::Base>]
      # @return [Hash{String=>Object}]
      def ref_for(klass)
        return {'$ref' => '#'} if klass.equal?(@root)
        return inline(klass) unless Introspection.named?(klass)

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
        if @inlining.include?(klass)
          raise ArgumentError, "FieldStruct::JSONSchema.generate(#{@root.name || @root.inspect}) cannot describe a recursive " \
                               'anonymous struct; assign it to a constant'
        end

        @inlining.push(klass)
        object_schema(klass)
      ensure
        @inlining.delete(klass)
      end

      # @param type [FieldStruct::Types::Base]
      # @param options [Hash{Symbol=>Object}]
      # @return [Hash{String=>Object}]
      def scalar_schema(type, options)
        case type
        when FieldStruct::Types::Boolean then {'type' => 'boolean'}
        when FieldStruct::Types::Integer then range({'type' => 'integer'}, options[:in])
        when FieldStruct::Types::Float then range({'type' => 'number'}, options[:in])
        when FieldStruct::Types::BigDecimal then {'type' => 'string', 'pattern' => DECIMAL_PATTERN}
        when FieldStruct::Types::Date then temporal('date', options[:format])
        when FieldStruct::Types::Time, FieldStruct::Types::DateTime
          temporal('date-time', options[:format])
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
      # @param type [FieldStruct::Types::String] a String-family type
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
      # @param option [String, Symbol, nil] the field's +format:+; only the
      #   default and +:iso8601+ write the canonical form
      # @return [Hash{String=>Object}]
      def temporal(format, option)
        return {'type' => 'string', 'format' => format} if option.nil? || option == :iso8601

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
        when ::Array then enum(schema, bound)
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

      # @param type [FieldStruct::Types::Base] a type FieldStruct doesn't ship
      # @return [Hash{String=>Object}]
      def custom_schema(type)
        ruby_type = type.ruby_type
        names = Array(ruby_type).map { |klass| klass.name || klass.inspect }
        {'x-ruby-type' => names.join(' | ')}
      end

      # A +json_schema:+ override (field option or the type's +json_schema+)
      # as a Hash: the boolean schemas become their object forms.
      #
      # @param value [Hash{String=>Object}, Boolean, nil]
      # @yieldreturn [String] where +value+ came from, for the error
      # @return [Hash{String=>Object}, nil]
      # @raise [ArgumentError] for anything else
      def override(value)
        case value
        when nil, ::Hash then value
        when true then {}
        when false then {'not' => {}}
        else
          raise ArgumentError, "FieldStruct::JSONSchema.generate: #{yield} must be a Hash or a boolean, got #{value.inspect}"
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

    # Adds +Klass.to_json_schema+ to the classes that include it, so a tool
    # that asks an object for its schema (RubyLLM takes any object that
    # responds to +to_json_schema+) can take the class itself:
    #
    #   class User < FieldStruct::Base
    #     include FieldStruct::JSONSchema::Methods
    #   end
    #   User.to_json_schema  # same as FieldStruct::JSONSchema.generate(User)
    module Methods
      # @param base [Class]
      # @return [void]
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Class methods added by {Methods}.
      module ClassMethods
        # @param serialization [Symbol, String] see {FieldStruct::JSONSchema.generate}
        # @return [Hash{String=>Object}]
        def to_json_schema(serialization: :json) = FieldStruct::JSONSchema.generate(self, serialization: serialization)
      end
    end
  end
end
