# frozen_string_literal: true

module FieldStruct
  module Protobuf
    # Converts instances to and from protobuf messages, walking the same nodes
    # as {DescriptorBuilder}.
    #
    # @api private
    class Codec
      # @param serialization [Symbol]
      def initialize(serialization:)
        @serialization = serialization
      end

      # @param struct [FieldStruct::Base]
      # @return [Object] a +Google::Protobuf::AbstractMessage+
      def dump(struct)
        attributes = Introspection.properties(struct.class, serialization: @serialization).filter_map do |property|
          value = struct.public_send(property.field.name)
          [property.key, dump_value(value, property)] unless value.nil?
        end
        Protobuf.message_class(struct.class, serialization: @serialization).new(attributes.to_h)
      end

      # @param klass [Class<FieldStruct::Base>]
      # @param message [Object] a +Google::Protobuf::AbstractMessage+
      # @return [FieldStruct::Base]
      def load(klass, message)
        attributes = Introspection.properties(klass, serialization: @serialization).to_h do |property|
          [property.field.name, load_value(message, property)]
        end
        klass.new(attributes)
      end

      private

      # @param value [Object] not nil
      # @param property [FieldStruct::Introspection::Property]
      # @return [Object]
      def dump_value(value, property)
        node = property.node
        return dump_one(value, node, property) unless node.is_a?(Introspection::ArrayNode)

        value.map do |item|
          raise ArgumentError, "#{property.key}: protobuf repeated fields can't hold nil" if item.nil?

          dump_one(item, node.element, property)
        end
      end

      # @param value [Object]
      # @param node [FieldStruct::Introspection::ScalarNode, FieldStruct::Introspection::StructNode]
      # @param property [FieldStruct::Introspection::Property]
      # @return [Object]
      def dump_one(value, node, property)
        return dump(value) if node.is_a?(Introspection::StructNode)

        case node.type
        when FieldStruct::Types::Binary then value.b
        when FieldStruct::Types::BigDecimal then value.to_s('F')
        when FieldStruct::Types::Date then value.iso8601
        when FieldStruct::Types::Symbol, FieldStruct::Types::String then value.to_s
        when FieldStruct::Types::Time, FieldStruct::Types::DateTime then timestamp(value.to_time)
        when FieldStruct::Types::Value then json_value(value, property)
        else value
        end
      end

      # @param time [::Time]
      # @return [Object] a +Google::Protobuf::Timestamp+
      def timestamp(time)
        Google::Protobuf::Timestamp.new(seconds: time.to_i, nanos: time.nsec)
      end

      # @param value [Object]
      # @param property [FieldStruct::Introspection::Property]
      # @return [Object] a +Google::Protobuf::Value+
      def json_value(value, property)
        Google::Protobuf::Value.from_ruby(value)
      rescue NoMethodError, ArgumentError, Google::Protobuf::TypeError, Google::Protobuf::UnexpectedStructType
        raise ArgumentError, "#{property.key}: a :value field holds JSON values (Hash, Array, String, " \
                             "Numeric, true, false, nil); got #{value.class}"
      end

      # @param message [Object] a +Google::Protobuf::AbstractMessage+
      # @param property [FieldStruct::Introspection::Property]
      # @return [Object]
      def load_value(message, property)
        node = property.node
        if node.is_a?(Introspection::ArrayNode)
          return message[property.key].map { |item| load_one(item, node.element) }
        end
        return nil unless message.public_send(:"has_#{property.key}?")

        load_one(message[property.key], node)
      end

      # @param value [Object]
      # @param node [FieldStruct::Introspection::ScalarNode, FieldStruct::Introspection::StructNode]
      # @return [Object]
      def load_one(value, node)
        return load(node.klass, value) if node.is_a?(Introspection::StructNode)

        case node.type
        when FieldStruct::Types::Time, FieldStruct::Types::DateTime
          rezone(::Time.at(value.seconds, value.nanos, :nsec, in: 'UTC'), node.options[:zone])
        when FieldStruct::Types::Value then value.to_ruby(true)
        else value
        end
      end

      # A Timestamp has no zone; a field with +zone:+ gets the time in its zone
      # again, as it would from a string (the same rule as field_struct-avro).
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
