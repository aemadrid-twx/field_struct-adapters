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
      def initialize(serialization:, timestamp:)
        @serialization = serialization
        @timestamp = timestamp
      end

      # @param struct [FieldStruct::Base]
      # @return [Hash{String=>Object}]
      def dump(struct)
        Introspection.properties(struct.class, serialization: @serialization).to_h do |property|
          [property.key, dump_value(struct.public_send(property.field.name), property.node)]
        end
      end

      # @param klass [Class<FieldStruct::Base>]
      # @param datum [Hash{String=>Object}]
      # @return [FieldStruct::Base]
      def load(klass, datum)
        attributes = Introspection.properties(klass, serialization: @serialization).to_h do |property|
          [property.field.name, load_value(datum[property.key], property.node)]
        end
        klass.new(attributes)
      end

      private

      # @param value [Object]
      # @param node [FieldStruct::Introspection::ScalarNode, FieldStruct::Introspection::ArrayNode,
      #   FieldStruct::Introspection::UnionNode, FieldStruct::Introspection::StructNode]
      # @return [Object]
      def dump_value(value, node)
        return nil if value.nil?

        case node
        when Introspection::ArrayNode then value.map { |item| dump_value(item, node.element) }
        when Introspection::StructNode then dump(value)
        when Introspection::UnionNode then dump_union(value, node)
        else dump_scalar(value, node)
        end
      end

      # A +:value+ member is tried last: its Ruby type is Object, so it would
      # claim a 5 that an +:integer+ member should write as a long.
      #
      # @param value [Object]
      # @param node [FieldStruct::Introspection::UnionNode]
      # @return [Object]
      def dump_union(value, node)
        ordered = node.members.sort_by.with_index { |candidate, index| [value_node?(candidate) ? 1 : 0, index] }
        member = ordered.find { |candidate| member_of?(value, candidate) }
        member ? dump_value(value, member) : value
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
      # @return [Object]
      def dump_scalar(value, node)
        case node.type
        when FieldStruct::Types::BigDecimal then decimal?(node) ? value : value.to_s('F')
        when FieldStruct::Types::Time then exact_time(value, node)
        when FieldStruct::Types::DateTime then exact_time(value.to_time, node)
        when FieldStruct::Types::Symbol then value.to_s
        when FieldStruct::Types::Value then Oj.dump(value, mode: :compat)
        else value
        end
      end

      # @param node [FieldStruct::Introspection::ScalarNode]
      # @return [Boolean] whether the decimal travels as an Avro decimal
      def decimal?(node)
        avro = avro_options(node)
        !avro.fetch(:scale) { node.options.fetch(:round) { node.type.class.default_round } }.nil?
      end

      # @param time [::Time]
      # @param node [FieldStruct::Introspection::ScalarNode]
      # @return [::Time]
      # @raise [ArgumentError] when the precision would drop part of +time+
      def exact_time(time, node)
        precision = avro_options(node).fetch(:timestamp, @timestamp)
        return time if (time.nsec % NANOS.fetch(precision)).zero?

        raise ArgumentError, "FieldStruct::Avro: #{time.iso8601(9)} has more precision than timestamp-#{precision}; " \
                             'round it, or use timestamp: :nanos'
      end

      # @param node [FieldStruct::Introspection::ScalarNode]
      # @return [Hash{Symbol=>Object}]
      def avro_options(node)
        options = node.options[:avro]
        options.is_a?(::Hash) ? options : {}
      end

      # @param value [Object]
      # @param node [FieldStruct::Introspection::ScalarNode, FieldStruct::Introspection::ArrayNode,
      #   FieldStruct::Introspection::UnionNode, FieldStruct::Introspection::StructNode]
      # @return [Object]
      def load_value(value, node)
        return nil if value.nil?

        case node
        when Introspection::ArrayNode then value.map { |item| load_value(item, node.element) }
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
        return time.getlocal(zone == 'UTC' ? 0 : zone) unless zone.include?('/')

        require 'tzinfo'
        local = ::TZInfo::Timezone.get(zone).to_local(time)
        ::Time.at(local.to_r).getlocal(local.utc_offset)
      end
    end
  end
end
