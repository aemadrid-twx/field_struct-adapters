# frozen_string_literal: true

module FieldStruct
  module Avro
    # Builds one root class's record schema. A named nested struct becomes a
    # record named after its class (+Billing::Invoice+ is +Invoice+ in
    # namespace +Billing+), defined at first use and referenced by full name
    # after that, so recursive structs work. An anonymous one is named
    # +<Record>_<field>+.
    #
    # @api private
    class SchemaBuilder
      # Avro's rule for record, enum and field names.
      # @return [Regexp]
      NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
      # Decimal precision when a field doesn't give +avro: {precision:}+.
      # @return [Integer]
      DEFAULT_PRECISION = 38
      # Avro types that may share a union only once each. +string+ and
      # +bytes+ count as one: a binary String fits both, and the writer takes
      # the first branch that fits.
      # @return [Hash{String=>String}]
      UNION_SLOT = {'bytes' => 'string'}.freeze

      # @param root [Class<FieldStruct::Base>]
      # @param serialization [Symbol]
      # @param timestamp [Symbol]
      def initialize(root, serialization:, timestamp:)
        @root = root
        @serialization = serialization
        @timestamp = timestamp
        @defined = {}
        @classes = {}
        @records = Hash.new { |hash, klass| hash[klass] = [] }
        @stamps = {}
        @inlining = []
        # The field being described, as Class#field, for error messages.
        @fields = []
      end

      # Each struct class's {Cache.stamp}, taken before the class was read,
      # so a class changed while {#schema} ran makes the entry stale rather
      # than a stale entry look fresh.
      # @return [Hash{Class<FieldStruct::Base>=>Array<Object>}]
      attr_reader :stamps

      # The Avro full names each struct class was written as, filled in by
      # {#schema}. An anonymous struct used in two fields has two.
      # @return [Hash{Class<FieldStruct::Base>=>Array<String>}]
      attr_reader :records

      # @return [Hash{String=>Object}]
      # @raise [ArgumentError] when the root class is anonymous
      def schema
        raise ArgumentError, 'FieldStruct::Avro needs a named class for the root record; assign it to a constant' unless Introspection.named?(@root)

        record(@root, nil, nil)
      end

      private

      # A class with no module of its own takes the namespace of the record
      # it is first defined in, as Avro would give it, and is written with
      # that namespace and referred to by that full name everywhere after.
      #
      # @param klass [Class<FieldStruct::Base>]
      # @param anonymous_name [String, nil] the name for an anonymous struct
      # @param namespace [String, nil] the enclosing record's namespace
      # @return [Hash{String=>Object}, String] the record, or its full name
      #   when it is already defined
      # @raise [ArgumentError] for a recursive anonymous struct, or a name
      #   Avro can't express
      def record(klass, anonymous_name, namespace)
        @stamps[klass] ||= Cache.stamp(klass, @serialization)
        named = Introspection.named?(klass)
        return reference(klass, namespace) if named && @classes.key?(klass)

        if named
          name, own = split_name(klass.name)
          namespace = own || namespace
        else
          name = anonymous_name
        end
        full_name = [namespace, name].compact.join('.')
        if @inlining.include?(klass)
          raise ArgumentError, "FieldStruct::Avro cannot describe a recursive anonymous struct (at #{@fields.last}); assign it to a constant"
        end
        return full_name unless define(full_name, klass, named ? klass.to_s : 'an anonymous struct', named ? "put #{klass} in a module" : nil)

        @classes[klass] = full_name if named
        @records[klass] << full_name
        @inlining.push(klass)
        out = {'type' => 'record', 'name' => name}
        out['namespace'] = namespace if namespace
        owner = named ? klass.name : @fields.last
        out['fields'] = Introspection.properties(klass, serialization: @serialization).map do |property|
          @fields.push(named ? "#{owner}##{property.field.name}" : "#{owner}.#{property.field.name}")
          field_schema(property, name, namespace)
        ensure
          @fields.pop
        end
        out
      ensure
        @inlining.delete(klass)
      end

      # Claims an Avro full name for a record or an enum. The same owner may
      # come back to it; anything else would silently take the other's type.
      #
      # @param full_name [String]
      # @param owner [Object] what the name stands for: the struct class, or
      #   an enum's symbols and default
      # @param label [String] the owner, for the error
      # @param fix [String, nil] what to do about a clash
      # @return [Boolean] whether the name is new, so its type must be written
      # @raise [ArgumentError] when something else already has the name
      def define(full_name, owner, label, fix = nil)
        taken = @defined[full_name]
        @defined[full_name] = [owner, label] unless taken
        return true unless taken
        return false if taken.first == owner

        raise ArgumentError, "FieldStruct::Avro: #{label} and #{taken.last} both become Avro #{full_name}; " \
                             "#{fix || "rename one of the fields"}"
      end

      # @param klass [Class<FieldStruct::Base>] a class already defined in this schema
      # @param namespace [String, nil] the namespace the reference sits in
      # @return [String] its full name
      # @raise [ArgumentError] when Avro would read the name in the wrong namespace
      def reference(klass, namespace)
        full_name = @classes.fetch(klass)
        return full_name if full_name.include?('.') || namespace.nil?

        # A name without a dot is read in the enclosing namespace, and Avro
        # has no way to name the null namespace from inside another one.
        raise ArgumentError, "FieldStruct::Avro: #{klass} has no namespace and is used inside #{@inlining.last} " \
                             "(Avro namespace #{namespace}), where Avro would read #{full_name} as #{namespace}.#{full_name}; " \
                             "put #{klass} in a module"
      end

      # The field being described, then its Avro name (which tells union
      # members apart, +_0+), so a log line can be traced to the declaration.
      #
      # @param avro_name [String]
      # @return [String] like +Billing::Wide#grand_total (Avro Wide_grandTotal)+
      def where(avro_name)
        "#{@fields.last} (Avro #{avro_name})"
      end

      # @param class_name [String] +"Billing::Invoice"+
      # @return [Array(String, String), Array(String, nil)] +["Invoice", "Billing"]+ (+nil+
      #   namespace for a top-level class)
      def split_name(class_name)
        *path, name = class_name.split('::')
        (path + [name]).each { |part| check_name(part, "class #{class_name}") }
        [name, path.empty? ? nil : path.join('.')]
      end

      # @param property [FieldStruct::Introspection::Property]
      # @param record_name [String]
      # @param namespace [String, nil]
      # @return [Hash{String=>Object}]
      def field_schema(property, record_name, namespace)
        field = property.field
        check_name(property.key, "field #{@fields.last}")
        type = type_for(property.node, Options.field(property), "#{record_name}_#{property.key}", namespace)
        out = {'name' => property.key}
        out['doc'] = field.description if field.description
        default = default_for(field, type)
        if field.required?
          out['type'] = type
          out['default'] = default unless default.nil?
        elsif default.nil?
          out['type'] = nullable(type)
          out['default'] = nil
        else
          # Avro checks a union's default against its first branch.
          out['type'] = [type, 'null']
          out['default'] = default
        end
        out['x-fs-sensitive'] = true if field.sensitive?
        out
      end

      # @param node [FieldStruct::Introspection::ScalarNode, FieldStruct::Introspection::ArrayNode,
      #   FieldStruct::Introspection::UnionNode, FieldStruct::Introspection::StructNode]
      # @param avro [Hash{Symbol=>Object}] the node's +avro:+ option
      # @param name [String] the name for an anonymous record or an enum
      # @param namespace [String, nil]
      # @return [String, Hash{String=>Object}, Array<Object>]
      def type_for(node, avro, name, namespace)
        override = Options.type(avro)
        return override if override

        case node
        when Introspection::ArrayNode then array_type(node, avro, name, namespace)
        when Introspection::UnionNode then union_type(node, avro, name, namespace)
        when Introspection::StructNode then record(node.klass, name, namespace)
        else scalar_type(node.type, node.options, avro, name, namespace)
        end
      end

      # @param node [FieldStruct::Introspection::ArrayNode]
      # @param avro [Hash{Symbol=>Object}]
      # @param name [String]
      # @param namespace [String, nil]
      # @return [Hash{String=>Object}]
      # @raise [ArgumentError] when the array records no element type
      def array_type(node, avro, name, namespace)
        raise ArgumentError, "FieldStruct::Avro can't describe #{where(name)}: an array of arrays or unions records no element type" unless node.element

        # Any element may be nil: validation skips nil elements.
        {'type' => 'array', 'items' => nullable(type_for(node.element, Options.nested(avro), name, namespace))}
      end

      # @param node [FieldStruct::Introspection::UnionNode]
      # @param avro [Hash{Symbol=>Object}]
      # @param name [String]
      # @param namespace [String, nil]
      # @return [Array<Object>]
      # @raise [ArgumentError] when two members land on one Avro type
      def union_type(node, avro, name, namespace)
        members = node.members.each_with_index.map do |member, index|
          type_for(member, Options.nested(avro), "#{name}_#{index}", namespace)
        end
        slots = members.map { |member| union_slot(member) }
        clash = slots.find { |slot| slots.count(slot) > 1 }
        raise ArgumentError, "FieldStruct::Avro can't describe #{where(name)}: two union members both become Avro #{clash}" if clash

        check_struct_members(node, name)

        # The writer takes the first branch that fits, and 5 fits double.
        members.sort_by.with_index { |member, index| [union_slot(member) == 'long' ? 0 : 1, index] }
      end

      # Avro writes a union datum as the first branch it fits, and a record
      # fits any Hash holding its required keys (extra keys are ignored), so
      # an earlier struct member whose required keys a later one also has
      # would swallow it: the later struct is written as the earlier one and
      # loses its other fields. Two members with the same keys also can't be
      # told apart when read back.
      #
      # @param node [FieldStruct::Introspection::UnionNode]
      # @param name [String]
      # @return [void]
      # @raise [ArgumentError]
      def check_struct_members(node, name)
        structs = node.members.grep(Introspection::StructNode).map(&:klass)
        structs.each_with_index do |earlier, index|
          required = struct_keys(earlier, required_only: true)
          later = structs.drop(index + 1).find { |klass| (required - struct_keys(klass)).empty? }
          next unless later

          # Swapping helps only when the earlier one wouldn't then fit the later.
          swap = (struct_keys(later, required_only: true) - struct_keys(earlier)).empty? ? '' : ", or put #{later} first"
          why = required.empty? ? "#{earlier} has no required fields, so any record fits it" : "every required field of #{earlier} is in #{later}"
          raise ArgumentError, "FieldStruct::Avro can't describe #{where(name)}: a #{later} would be written as " \
                               "#{earlier}, which Avro picks by shape (#{why}). Give the structs distinct required fields#{swap}"
        end
      end

      # A required field with an +avro: {type:}+ override may have been made
      # nullable, so it doesn't count as required here.
      #
      # @param klass [Class<FieldStruct::Base>]
      # @param required_only [Boolean]
      # @return [Array<String>] the Avro field names
      def struct_keys(klass, required_only: false)
        properties = Introspection.properties(klass, serialization: @serialization)
        if required_only
          properties = properties.select { |property| property.field.required? && !Options.override?(Options.field(property)) }
        end
        properties.map(&:key)
      end

      # @param type [String, Hash{String=>Object}]
      # @return [String] what Avro allows once per union
      def union_slot(type)
        return UNION_SLOT.fetch(type, type) if type.is_a?(::String) && !type.include?('.')
        return type if type.is_a?(::String) # a record's full name
        return [type['namespace'], type['name']].compact.join('.') if %w[record enum fixed].include?(type['type'])

        UNION_SLOT.fetch(type['type'], type['type'])
      end

      # @param type [FieldStruct::Types::Base]
      # @param options [Hash{Symbol=>Object}]
      # @param avro [Hash{Symbol=>Object}]
      # @param name [String]
      # @param namespace [String, nil]
      # @return [String, Hash{String=>Object}]
      # @raise [ArgumentError] for a custom type without +avro: {type:}+
      def scalar_type(type, options, avro, name, namespace)
        case type
        when FieldStruct::Types::Binary then 'bytes'
        when FieldStruct::Types::UUID
          options.fetch(:format, type.class.default_format) == type.class.default_format ? {'type' => 'string', 'logicalType' => 'uuid'} : 'string'
        when FieldStruct::Types::String, FieldStruct::Types::Value then 'string' # a :value holds JSON text
        when FieldStruct::Types::Boolean then 'boolean'
        when FieldStruct::Types::Integer then 'long'
        when FieldStruct::Types::Float then 'double'
        when FieldStruct::Types::BigDecimal then decimal_type(type, options, avro, name)
        when FieldStruct::Types::Date then {'type' => 'int', 'logicalType' => 'date'}
        when FieldStruct::Types::Time, FieldStruct::Types::DateTime then {'type' => 'long', 'logicalType' => "timestamp-#{Options.timestamp(avro, @timestamp, @fields.last)}"}
        when FieldStruct::Types::Symbol then enum_type(options, avro, name, namespace) || 'string'
        else
          raise ArgumentError, "FieldStruct::Avro has no mapping for #{type.class.name || type.class.inspect} (#{where(name)}); give the field avro: {type: …}"
        end
      end

      # A +round:+ decimal is an Avro decimal with that scale. Without one
      # there is no scale to declare, so the digits travel as a string.
      #
      # @param type [FieldStruct::Types::BigDecimal]
      # @param options [Hash{Symbol=>Object}]
      # @param avro [Hash{Symbol=>Object}]
      # @param name [String]
      # @return [String, Hash{String=>Object}]
      # @raise [ArgumentError] when the scale doesn't fit the precision
      def decimal_type(type, options, avro, name)
        scale = Options.scale(avro, options, type)
        return 'string' if scale.nil?

        precision = avro.fetch(:precision, DEFAULT_PRECISION)
        unless [scale, precision].all?(::Integer)
          raise ArgumentError, "FieldStruct::Avro can't describe #{where(name)}: decimal precision and scale must be integers, " \
                               "got #{precision.inspect} and #{scale.inspect}"
        end

        # A negative round: (to tens, hundreds) leaves no fractional digits.
        scale = [scale, 0].max
        raise ArgumentError, "FieldStruct::Avro can't describe #{where(name)}: precision #{precision} must be at least 1" if precision < 1
        if scale > precision
          raise ArgumentError, "FieldStruct::Avro can't describe #{where(name)}: scale #{scale} is more than precision #{precision}; " \
                               'raise avro: {precision:}'
        end

        {'type' => 'bytes', 'logicalType' => 'decimal', 'precision' => precision, 'scale' => scale}
      end

      # @param options [Hash{Symbol=>Object}]
      # @param avro [Hash{Symbol=>Object}]
      # @param name [String]
      # @param namespace [String, nil]
      # @return [Hash{String=>Object}, nil] +nil+ when the symbols can't be
      #   Avro enum symbols, or +avro: {enum: false}+
      def enum_type(options, avro, name, namespace)
        symbols = options[:enum]&.map(&:to_s)
        return nil if symbols.nil? || avro[:enum] == false || !symbols.all? { |symbol| symbol.match?(NAME) }

        full_name = [namespace, name].compact.join('.')
        return full_name unless define(full_name, [symbols, avro[:enum_default]], 'an enum')

        out = {'type' => 'enum', 'name' => name, 'symbols' => symbols}
        out['default'] = avro[:enum_default].to_s if avro.key?(:enum_default)
        out
      end

      # A literal default of the field's own Avro type; anything else (a
      # callable, a date) is left out.
      #
      # @param field [FieldStruct::Field]
      # @param type [String, Hash{String=>Object}, Array<Object>]
      # @return [Object, nil]
      def default_for(field, type)
        value = field.default
        case type
        when 'boolean' then value if [true, false].include?(value)
        when 'long' then value if value.is_a?(::Integer)
        when 'double' then value.to_f if value.is_a?(::Integer) || (value.is_a?(::Float) && value.finite?)
        when 'string' then string_default(field, value)
        when ::Hash then value.to_s if type['type'] == 'enum' && value.is_a?(::Symbol) && type['symbols'].include?(value.to_s)
        end
      end

      # @param field [FieldStruct::Field]
      # @param value [Object]
      # @return [String, nil]
      def string_default(field, value)
        case field.type_instance
        when FieldStruct::Types::Symbol then value.to_s if value.is_a?(::Symbol)
        when FieldStruct::Types::String then value if value.is_a?(::String) && !field.type_instance.is_a?(FieldStruct::Types::Binary)
        end
      end

      # @param type [String, Hash{String=>Object}, Array<Object>]
      # @return [Array<Object>] +type+ also accepting +null+, first
      def nullable(type)
        return ['null', *type.reject { |member| member == 'null' }] if type.is_a?(::Array)

        ['null', type]
      end

      # @param name [String]
      # @param what [String]
      # @return [void]
      # @raise [ArgumentError] when +name+ breaks Avro's naming rule
      def check_name(name, what)
        return if name.match?(NAME)

        raise ArgumentError, "FieldStruct::Avro: #{what} is named #{name.inspect}, which Avro names can't be ([A-Za-z_][A-Za-z0-9_]*)"
      end
    end
  end
end
