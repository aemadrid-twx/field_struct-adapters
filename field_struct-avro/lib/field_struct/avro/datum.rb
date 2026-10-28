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

      # @param serialization [Symbol]
      # @param timestamp [Symbol]
      # @param absent [Hash{Class<FieldStruct::Base>=>Array<String>}] the Avro
      #   field names a writer lacked, per struct class; {#load} leaves them
      #   out so field_struct applies its defaults
      def initialize(serialization:, timestamp:, absent: {})
        @serialization = serialization
        @timestamp = timestamp
        @absent = absent
      end

      # @param struct [FieldStruct::Base]
      # @return [Hash{String=>Object}]
      def dump(struct)
        Introspection.properties(struct.class, serialization: @serialization).to_h do |property|
          [property.key, dump_value(struct.public_send(property.field.name), property.node, field_avro(property))]
        end
      end

      # @param klass [Class<FieldStruct::Base>]
      # @param datum [Hash{String=>Object}]
      # @return [FieldStruct::Base]
      def load(klass, datum)
        absent = @absent.fetch(klass, [])
        properties = Introspection.properties(klass, serialization: @serialization).reject { |property| absent.include?(property.key) }
        klass.new(properties.to_h { |property| [property.field.name, load_value(datum[property.key], property.node, field_avro(property))] })
      end

      private

      # @param value [Object]
      # @param node [FieldStruct::Introspection::ScalarNode, FieldStruct::Introspection::ArrayNode,
      #   FieldStruct::Introspection::UnionNode, FieldStruct::Introspection::StructNode]
      # @param avro [Hash{Symbol=>Object}] the +avro:+ options that apply
      # @return [Object]
      def dump_value(value, node, avro)
        return nil if value.nil?
        return raw(value) if override?(node, avro)

        case node
        when Introspection::ArrayNode then value.map { |item| dump_value(item, node.element, nested(avro, node.element)) }
        when Introspection::StructNode then dump(value)
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
        member ? dump_value(value, member, nested(avro, member)) : value
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
        !avro.fetch(:scale) { node.options.fetch(:round) { node.type.class.default_round } }.nil?
      end

      # @param time [::Time]
      # @param avro [Hash{Symbol=>Object}]
      # @return [::Time]
      # @raise [ArgumentError] when the precision would drop part of +time+
      def exact_time(time, avro)
        precision = avro.fetch(:timestamp, @timestamp)
        return time if (time.nsec % NANOS.fetch(precision)).zero?

        raise ArgumentError, "FieldStruct::Avro: #{time.iso8601(9)} has more precision than timestamp-#{precision}; " \
                             'round it, or use timestamp: :nanos'
      end

      # @param property [FieldStruct::Introspection::Property]
      # @return [Hash{Symbol=>Object}] the field's +avro:+ option, whatever
      #   its node (a struct or union node carries no options of its own)
      def field_avro(property)
        options = property.field.options[:avro]
        options.is_a?(::Hash) ? options : {}
      end

      # An array's elements and a union's members take the field's +avro:+
      # options, under any of their own, except +:type+, which replaces only
      # the field it was given on.
      #
      # @param avro [Hash{Symbol=>Object}] the enclosing node's options
      # @param node [Object]
      # @return [Hash{Symbol=>Object}]
      def nested(avro, node)
        avro.except(:type).merge(avro_options(node))
      end

      # @param node [Object]
      # @return [Hash{Symbol=>Object}]
      def avro_options(node)
        options = node.respond_to?(:options) ? node.options[:avro] : nil
        options.is_a?(::Hash) ? options : {}
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
        !(value_node?(node) && (Array(avro[:type]) - ['null']) == ['string'])
      end

      # @param value [Object]
      # @return [Object] +value+, with symbols as strings (Avro has none)
      def raw(value)
        case value
        when ::Symbol then value.to_s
        when FieldStruct::Base then dump(value)
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
        when Introspection::ArrayNode then value.map { |item| load_value(item, node.element, nested(avro, node.element)) }
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
            Introspection.properties(candidate.klass, serialization: @serialization).map(&:key).sort == value.keys.sort
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
