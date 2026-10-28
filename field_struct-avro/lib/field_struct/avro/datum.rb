# frozen_string_literal: true

module FieldStruct
  module Avro
    # Converts instances to and from the datums the avro gem reads and
    # writes, walking the same nodes as {SchemaBuilder}.
    #
    # @api private
    class Datum
      # Nanoseconds per unit of each timestamp precision.
      # @return [Hash{Symbol=>Integer}]
      NANOS = {nanos: 1, micros: 1_000, millis: 1_000_000}.freeze
      # @return [Hash{Symbol=>Object}]
      JSON_LOAD = {mode: :compat, decimal_class: ::BigDecimal}.freeze

      # An error raised deep in {#dump_value}, before the field is known.
      # Each struct it passes through adds its field to {#path}, and the
      # first named one (or the root) turns it into an ArgumentError naming
      # the field as the schema builder does: Holder#inner.at. Only the error
      # path pays for the label.
      class Located < ArgumentError
        # @return [Array<Symbol>] field names, outermost first
        attr_reader :path
        # @return [Boolean] whether the innermost field is sensitive
        attr_accessor :sensitive

        # @param message [String]
        def initialize(message)
          @path = []
          super
        end

        # @param label [String] the field, like +Holder#inner.at+
        # @return [String]
        def final(label)
          "FieldStruct::Avro (#{label}) #{message}"
        end
      end

      # A time too precise for its field.
      class Imprecise < Located
        # @return [::Time]
        attr_reader :time

        # @param time [::Time]
        # @param precision [Symbol]
        def initialize(time, precision)
          @time = time
          super("more precision than timestamp-#{precision}; round it, or use timestamp: :nanos")
        end

        # @param label [String]
        # @return [String]
        def final(label)
          # A sensitive field's value stays out of the message, which ends up in logs.
          "FieldStruct::Avro: #{label} is #{sensitive ? "a sensitive time" : time.iso8601(9)}, which has #{message}"
        end
      end
      private_constant :Located, :Imprecise

      # @param serialization [Symbol]
      # @param timestamp [Symbol, nil] the precision {#dump} checks times
      #   against; {#load} takes the Times the avro gem already decoded, so
      #   it needs none (a dump without one raises)
      # @param absent [Hash{Class<FieldStruct::Base>=>Array<String>}] the Avro
      #   field names a writer lacked, per struct class; {#load} leaves them
      #   out so field_struct applies its defaults
      def initialize(serialization:, timestamp: nil, absent: {})
        @serialization = serialization
        @timestamp = timestamp
        @absent = absent
      end

      # @param struct [FieldStruct::Base]
      # @return [Hash{String=>Object}]
      # @raise [ArgumentError] naming the field, when a time is too precise
      def dump(struct)
        dump_struct(struct)
      rescue Located => e
        # An anonymous root: nothing named above it.
        raise ArgumentError, e.final("#{struct.class.inspect}##{e.path.join(".")}")
      end

      # @param struct [FieldStruct::Base]
      # @return [Hash{String=>Object}]
      # @raise [ArgumentError] from a named struct, naming the field
      # @raise [Located] from an anonymous one, for the struct holding it
      def dump_struct(struct)
        klass = struct.class
        properties(klass).to_h do |property|
          [property.key, dump_value(struct.public_send(property.field.name), property.node, Options.field(property))]
        rescue Located => e
          e.sensitive = property.field.sensitive? if e.path.empty?
          e.path.unshift(property.field.name)
          raise e unless Introspection.named?(klass)

          raise ArgumentError, e.final("#{klass.name}##{e.path.join(".")}")
        end
      end
      private :dump_struct

      # @param klass [Class<FieldStruct::Base>]
      # @param datum [Hash{String=>Object}]
      # @return [FieldStruct::Base]
      def load(klass, datum)
        absent = @absent.fetch(klass, nil)
        list = properties(klass)
        list = list.reject { |property| absent.include?(property.key) } if absent && !absent.empty?
        klass.new(list.to_h { |property| [property.field.name, load_value(datum[property.key], property.node, Options.field(property))] })
      end

      private

      # @param klass [Class<FieldStruct::Base>]
      # @return [Array<FieldStruct::Introspection::Property>]
      def properties(klass)
        CACHE.properties(klass, @serialization)
      end

      # @param value [Object]
      # @param node [FieldStruct::Introspection::ScalarNode, FieldStruct::Introspection::ArrayNode,
      #   FieldStruct::Introspection::UnionNode, FieldStruct::Introspection::StructNode]
      # @param avro [Hash{Symbol=>Object}] the +avro:+ options that apply
      # @return [Object]
      def dump_value(value, node, avro)
        return nil if value.nil?
        return raw(value) if override?(node, avro)

        case node
        when Introspection::ArrayNode
          element = node.element
          element_avro = Options.nested(avro)
          value.map { |item| dump_value(item, element, element_avro) }
        when Introspection::StructNode then dump_struct(value)
        when Introspection::UnionNode then dump_union(value, node, avro)
        else dump_scalar(value, node, avro)
        end
      end

      # A +:value+ member is tried last: its Ruby type is Object, so it would
      # claim a 5 that an +:integer+ member should write as a long.
      #
      # @param value [Object]
      # @param node [FieldStruct::Introspection::UnionNode]
      # @param avro [Hash{Symbol=>Object}]
      # @return [Object]
      def dump_union(value, node, avro)
        ordered = node.members.sort_by.with_index { |candidate, index| [value_node?(candidate) ? 1 : 0, index] }
        member = ordered.find { |candidate| member_of?(value, candidate) }
        member ? dump_value(value, member, Options.nested(avro)) : value
      end

      # @param node [Object]
      # @return [Boolean]
      def value_node?(node)
        node.is_a?(Introspection::ScalarNode) && node.type.is_a?(FieldStruct::Types::Value)
      end

      # @param value [Object]
      # @param node [FieldStruct::Introspection::ScalarNode, FieldStruct::Introspection::ArrayNode,
      #   FieldStruct::Introspection::UnionNode, FieldStruct::Introspection::StructNode]
      # @return [Boolean]
      def member_of?(value, node)
        case node
        when Introspection::StructNode then value.is_a?(node.klass)
        when Introspection::ArrayNode then value.is_a?(::Array)
        else Array(node.type.ruby_type).any? { |klass| value.is_a?(klass) }
        end
      end

      # @param value [Object]
      # @param node [FieldStruct::Introspection::ScalarNode]
      # @param avro [Hash{Symbol=>Object}]
      # @return [Object]
      def dump_scalar(value, node, avro)
        case node.type
        when FieldStruct::Types::BigDecimal then decimal?(node, avro) ? value : value.to_s('F')
        when FieldStruct::Types::Time then exact_time(value, avro)
        when FieldStruct::Types::DateTime then exact_time(value.to_time, avro)
        when FieldStruct::Types::Symbol then value.to_s
        when FieldStruct::Types::Value then Oj.dump(json_value(value), mode: :compat)
        else value
        end
      end

      # A +:value+ travels as the JSON text field_struct's +to_json+ writes
      # for it: ISO 8601 times, plain decimals. This follows field_struct's
      # private +Base#json_value+ for a field with no +format:+.
      #
      # @param value [Object]
      # @return [Object]
      def json_value(value)
        case value
        when nil, true, false, ::String, ::Integer, ::Float then value
        when ::Symbol then value.to_s
        when ::BigDecimal then value.to_s('F')
        when ::DateTime, ::Date, ::Time then value.iso8601
        when ::Array then value.map { |item| json_value(item) }
        when ::Hash then value.transform_values { |item| json_value(item) }
        else value.respond_to?(:as_json) ? value.as_json : value
        end
      end

      # @param node [FieldStruct::Introspection::ScalarNode]
      # @param avro [Hash{Symbol=>Object}]
      # @return [Boolean] whether the decimal travels as an Avro decimal
      def decimal?(node, avro)
        !Options.scale(avro, node.options, node.type).nil?
      end

      # @param time [::Time]
      # @param avro [Hash{Symbol=>Object}]
      # @return [::Time]
      # @raise [ArgumentError] when the precision would drop part of +time+
      def exact_time(time, avro)
        precision = begin
          Options.timestamp(avro, @timestamp)
        rescue ArgumentError => e
          raise Located, e.message.delete_prefix('FieldStruct::Avro ')
        end
        return time if (time.nsec % NANOS.fetch(precision)).zero?

        raise Imprecise.new(time, precision)
      end

      # A field whose +avro: {type:}+ replaces its mapping: the user chose the
      # Avro type, so the value travels as field_struct holds it.
      #
      # @param node [Object]
      # @param avro [Hash{Symbol=>Object}]
      # @return [Boolean]
      def override?(node, avro)
        return false unless avro.key?(:type)

        # A :value overridden to (nullable) string still holds JSON text.
        !(value_node?(node) && Options.string?(Options.type(avro)))
      end

      # @param value [Object]
      # @return [Object] +value+, with symbols as strings (Avro has none)
      def raw(value)
        case value
        when ::Symbol then value.to_s
        when FieldStruct::Base then dump_struct(value)
        when ::Array then value.map { |item| raw(item) }
        when ::Hash then value.to_h { |key, item| [raw(key), raw(item)] }
        else value
        end
      end

      # The Avro type is the user's, but what {#raw} dumped comes back the
      # same way: structs through their own mappings, a time in its zone:.
      #
      # @param value [Object]
      # @param node [FieldStruct::Introspection::ScalarNode, FieldStruct::Introspection::ArrayNode,
      #   FieldStruct::Introspection::UnionNode, FieldStruct::Introspection::StructNode]
      # @return [Object]
      def load_override(value, node)
        if node.is_a?(Introspection::StructNode) && value.is_a?(::Hash)
          load(node.klass, value)
        elsif node.is_a?(Introspection::ArrayNode) && node.element.is_a?(Introspection::StructNode) && value.is_a?(::Array)
          value.map { |item| item.is_a?(::Hash) ? load(node.element.klass, item) : item }
        elsif value.is_a?(::Time) && node.respond_to?(:options)
          rezone(value, node.options[:zone])
        else
          value
        end
      end

      # @param value [Object]
      # @param node [FieldStruct::Introspection::ScalarNode, FieldStruct::Introspection::ArrayNode,
      #   FieldStruct::Introspection::UnionNode, FieldStruct::Introspection::StructNode]
      # @param avro [Hash{Symbol=>Object}] the +avro:+ options that apply
      # @return [Object]
      def load_value(value, node, avro)
        return nil if value.nil?
        return load_override(value, node) if override?(node, avro)

        case node
        when Introspection::ArrayNode
          element = node.element
          element_avro = Options.nested(avro)
          value.map { |item| load_value(item, element, element_avro) }
        when Introspection::StructNode then load(node.klass, value)
        when Introspection::UnionNode then load_union(value, node)
        else load_scalar(value, node)
        end
      end

      # A record datum carries no branch name, so it loads as the struct
      # member whose keys it has. A string is a +:value+ member's JSON
      # when the union has one: only one member can be Avro +string+ (the
      # schema refuses two). Anything else goes to the union as is.
      #
      # @param value [Object]
      # @param node [FieldStruct::Introspection::UnionNode]
      # @return [Object]
      def load_union(value, node)
        if value.is_a?(::String)
          member = node.members.find { |candidate| value_node?(candidate) }
          return member ? load_scalar(value, member) : value
        end
        return value unless value.is_a?(::Hash)

        member = node.members.find do |candidate|
          candidate.is_a?(Introspection::StructNode) &&
            properties(candidate.klass).map(&:key).sort == value.keys.sort
        end
        member ? load(member.klass, value) : value
      end

      # @param value [Object]
      # @param node [FieldStruct::Introspection::ScalarNode]
      # @return [Object]
      def load_scalar(value, node)
        case node.type
        when FieldStruct::Types::Time, FieldStruct::Types::DateTime then rezone(value, node.options[:zone])
        when FieldStruct::Types::Value then Oj.load(value, JSON_LOAD)
        else value
        end
      end

      # Avro times come back in UTC; a field with +zone:+ gets them in its
      # zone again, as it would from a string.
      #
      # @param time [::Time]
      # @param zone [String, nil]
      # @return [::Time]
      def rezone(time, zone)
        return time unless zone.is_a?(::String)
        return time.utc if zone == 'UTC'
        return time.getlocal(zone) unless zone.include?('/')

        require 'tzinfo'
        local = ::TZInfo::Timezone.get(zone).to_local(time)
        ::Time.at(local.to_r).getlocal(local.utc_offset)
      end
    end
  end
end
