# frozen_string_literal: true

module FieldStruct
  module Protobuf
    # Builds the +FileDescriptorProto+ for one FieldStruct class: one file per
    # class, holding one message, importing the files of the structs it
    # refers to.
    #
    # @api private
    class DescriptorBuilder
      # The well-known types the mapping uses, by full name, with their files.
      # @return [Hash{String=>String}]
      WELL_KNOWN = {
        '.google.protobuf.Timestamp' => 'google/protobuf/timestamp.proto',
        '.google.protobuf.Value' => 'google/protobuf/struct.proto'
      }.freeze
      # Field numbers protobuf reserves for its own implementation.
      # @return [Range<Integer>]
      RESERVED_NUMBERS = (19_000..19_999)
      # @return [Integer]
      MAX_NUMBER = 536_870_911
      # @return [Regexp]
      IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      # @param klass [Class<FieldStruct::Base>]
      # @param serialization [Symbol]
      def initialize(klass, serialization:)
        @klass = klass
        @serialization = serialization
        @imports = []
      end

      # @return [Google::Protobuf::FileDescriptorProto]
      # @raise [ArgumentError] when the class can't be described exactly
      def file
        message = Google::Protobuf::DescriptorProto.new(name: Protobuf.message_name(@klass))
        properties = Introspection.properties(@klass, serialization: @serialization)
        check_numbers(properties)
        properties.each { |property| add_field(message, property) }
        Google::Protobuf::FileDescriptorProto.new(
          name: Protobuf.file_name(@klass), package: Protobuf.package(@klass), syntax: 'proto3',
          dependency: @imports.uniq, message_type: [message]
        )
      end

      private

      # @param properties [Array<FieldStruct::Introspection::Property>]
      # @return [void]
      def check_numbers(properties)
        missing = properties.reject { |property| number(property) }.map(&:key)
        unless missing.empty?
          raise ArgumentError, "#{@klass}: give every field a protobuf field number, e.g. " \
                               "`proto: {number: 1}`; missing on #{missing.join(", ")}"
        end
        numbers = properties.map { |property| number(property) }
        duplicates = numbers.tally.select { |_, count| count > 1 }.keys
        raise ArgumentError, "#{@klass}: field numbers #{duplicates.join(", ")} are used twice" unless duplicates.empty?
      end

      # @param property [FieldStruct::Introspection::Property]
      # @return [Integer, nil]
      def number(property)
        value = property.field.options.dig(:proto, :number)
        return nil if value.nil?

        valid = value.is_a?(::Integer) && value.between?(1, MAX_NUMBER) && !RESERVED_NUMBERS.cover?(value)
        raise ArgumentError, "#{@klass}##{property.field.name}: #{value.inspect} isn't a usable protobuf field number" unless valid

        value
      end

      # @param message [Google::Protobuf::DescriptorProto]
      # @param property [FieldStruct::Introspection::Property]
      # @return [void]
      def add_field(message, property)
        unless property.key.match?(IDENTIFIER)
          raise ArgumentError, "#{@klass}: #{property.key.inspect} isn't a protobuf field name; " \
                               'rename it with `serialize :protobuf, field: "name"`'
        end

        node = property.node
        repeated = node.is_a?(Introspection::ArrayNode)
        node = element(node, property) if repeated
        type, type_name = field_type(node, property)
        field = Google::Protobuf::FieldDescriptorProto.new(
          name: property.key, number: number(property), type: type,
          label: repeated ? :LABEL_REPEATED : :LABEL_OPTIONAL
        )
        field.type_name = type_name if type_name
        # A singular scalar gets explicit presence, so an unset field reads
        # back as nil rather than as 0 or "". Messages always have presence.
        explicit_presence(message, field) if !repeated && type != :TYPE_MESSAGE
        message.field << field
      end

      # proto3 +optional+: a synthetic one-field oneof named +_<field>+.
      #
      # @param message [Google::Protobuf::DescriptorProto]
      # @param field [Google::Protobuf::FieldDescriptorProto]
      # @return [void]
      def explicit_presence(message, field)
        field.proto3_optional = true
        field.oneof_index = message.oneof_decl.size
        message.oneof_decl << Google::Protobuf::OneofDescriptorProto.new(name: "_#{field.name}")
      end

      # @param node [FieldStruct::Introspection::ArrayNode]
      # @param property [FieldStruct::Introspection::Property]
      # @return [FieldStruct::Introspection::ScalarNode, FieldStruct::Introspection::StructNode]
      def element(node, property)
        element = node.element
        case element
        when nil then unsupported(property, 'an array of unions')
        when Introspection::ArrayNode then unsupported(property, 'an array of arrays (protobuf has no repeated repeated)')
        else element
        end
      end

      # @param node [FieldStruct::Introspection::ScalarNode, FieldStruct::Introspection::StructNode,
      #   FieldStruct::Introspection::UnionNode]
      # @param property [FieldStruct::Introspection::Property]
      # @return [Array(Symbol, String)] the field type, and the message type name when it's a message
      def field_type(node, property)
        case node
        when Introspection::StructNode then message_type(node.klass, property)
        when Introspection::UnionNode then unsupported(property, 'a union')
        else scalar_type(node.type, property)
        end
      end

      # @param klass [Class<FieldStruct::Base>]
      # @param property [FieldStruct::Introspection::Property]
      # @return [Array(Symbol, String)]
      def message_type(klass, property)
        unsupported(property, 'an anonymous struct (assign it to a constant)') unless Introspection.named?(klass)
        @imports << Protobuf.file_name(klass) unless klass == @klass # a message may refer to itself
        [:TYPE_MESSAGE, Protobuf.full_name(klass)]
      end

      # @param type [FieldStruct::Types::Base]
      # @param property [FieldStruct::Introspection::Property]
      # @return [Array(Symbol, String)]
      def scalar_type(type, property)
        case type
        when FieldStruct::Types::Binary then [:TYPE_BYTES, nil]
        when FieldStruct::Types::String, FieldStruct::Types::Symbol,
             FieldStruct::Types::BigDecimal, FieldStruct::Types::Date then [:TYPE_STRING, nil]
        when FieldStruct::Types::Boolean then [:TYPE_BOOL, nil]
        when FieldStruct::Types::Integer then [:TYPE_INT64, nil]
        when FieldStruct::Types::Float then [:TYPE_DOUBLE, nil]
        when FieldStruct::Types::Time, FieldStruct::Types::DateTime then well_known('.google.protobuf.Timestamp')
        when FieldStruct::Types::Value then well_known('.google.protobuf.Value')
        else unsupported(property, "a #{type.class} (no protobuf mapping)")
        end
      end

      # @param name [String]
      # @return [Array(Symbol, String)]
      def well_known(name)
        @imports << WELL_KNOWN.fetch(name)
        [:TYPE_MESSAGE, name]
      end

      # @param property [FieldStruct::Introspection::Property]
      # @param what [String]
      # @return [void]
      # @raise [ArgumentError]
      def unsupported(property, what)
        raise ArgumentError, "#{@klass}##{property.field.name} is #{what}, which field_struct-protobuf can't map yet"
      end
    end
  end
end
