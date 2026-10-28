# frozen_string_literal: true

require 'bigdecimal'
require 'google/protobuf'
require 'google/protobuf/descriptor_pb'
require 'google/protobuf/struct_pb'
require 'google/protobuf/timestamp_pb'
require 'google/protobuf/well_known_types'
require 'field_struct'
unless defined?(FieldStruct::Introspection)
  raise LoadError, "field_struct-protobuf needs FieldStruct::Introspection, which field_struct #{FieldStruct::VERSION} doesn't have; " \
                   'use a field_struct with it (develop, until the next release)'
end
require_relative 'protobuf/version'
require_relative 'protobuf/descriptor_builder'
require_relative 'protobuf/printer'
require_relative 'protobuf/codec'

module FieldStruct
  # Protocol Buffers for FieldStruct classes, built at runtime with no protoc
  # step: a +.proto+ file per class, a message class registered with
  # google-protobuf, and instances to and from protobuf binary.
  #
  #   class Invoice < FieldStruct::Base
  #     required :id,    :uuid,        proto: {number: 1}
  #     required :total, :big_decimal, proto: {number: 2}
  #   end
  #
  #   FieldStruct::Protobuf.proto(Invoice)   # => "syntax = \"proto3\";\n…"
  #   bytes = FieldStruct::Protobuf.encode(invoice)
  #   FieldStruct::Protobuf.decode(Invoice, bytes) == invoice  # => true
  #
  # Every field needs a field number (+proto: {number: n}+): protobuf
  # identifies fields by number on the wire, so a number inferred from
  # declaration order would turn a reordered field into silently corrupted
  # data. +serialization:+ picks the +serialize+ format whose names become
  # protobuf field names (default +:protobuf+).
  #
  # A class's message is built once, the first time it's needed, and
  # registered in google-protobuf's generated pool under the package named
  # after the class's modules (+Billing::Invoice+ is +billing.Invoice+).
  module Protobuf
    @message_classes = {}
    @mutex = Mutex.new

    class << self
      # @param klass [Class<FieldStruct::Base>]
      # @param serialization [Symbol]
      # @return [Google::Protobuf::FileDescriptorProto] the file describing +klass+
      # @raise [ArgumentError] when a field has no exact protobuf mapping
      def file_descriptor(klass, serialization: :protobuf)
        check(klass)
        DescriptorBuilder.new(klass, serialization: serialization).file
      end

      # @param klass [Class<FieldStruct::Base>]
      # @param serialization [Symbol]
      # @return [String] the +.proto+ source of the file describing +klass+
      def proto(klass, serialization: :protobuf)
        Printer.new(file_descriptor(klass, serialization: serialization), klass).to_s
      end

      # The message class for +klass+, built and registered the first time.
      #
      # @param klass [Class<FieldStruct::Base>]
      # @param serialization [Symbol]
      # @return [Class<Google::Protobuf::AbstractMessage>]
      def message_class(klass, serialization: :protobuf)
        @mutex.synchronize { register(klass, serialization) }
      end

      # @param struct [FieldStruct::Base]
      # @param serialization [Symbol]
      # @return [Google::Protobuf::AbstractMessage]
      def to_message(struct, serialization: :protobuf)
        check(struct.class)
        Codec.new(serialization: serialization).dump(struct)
      end

      # @param klass [Class<FieldStruct::Base>]
      # @param message [Google::Protobuf::AbstractMessage]
      # @param serialization [Symbol]
      # @return [FieldStruct::Base]
      def from_message(klass, message, serialization: :protobuf)
        check(klass)
        Codec.new(serialization: serialization).load(klass, message)
      end

      # @param struct [FieldStruct::Base]
      # @param serialization [Symbol]
      # @return [String] the protobuf binary encoding
      def encode(struct, serialization: :protobuf)
        message = to_message(struct, serialization: serialization)
        message.class.encode(message)
      end

      # @param klass [Class<FieldStruct::Base>]
      # @param bytes [String] protobuf binary
      # @param serialization [Symbol]
      # @return [FieldStruct::Base]
      def decode(klass, bytes, serialization: :protobuf)
        message = message_class(klass, serialization: serialization).decode(bytes)
        from_message(klass, message, serialization: serialization)
      end

      # @param klass [Class<FieldStruct::Base>]
      # @return [String] +billing+ for +Billing::Invoice+; empty for a top-level class
      def package(klass)
        klass.name.split('::')[0...-1].map { |part| underscore(part) }.join('.')
      end

      # @param klass [Class<FieldStruct::Base>]
      # @return [String]
      def message_name(klass)
        klass.name.split('::').last
      end

      # @param klass [Class<FieldStruct::Base>]
      # @return [String] +.billing.Invoice+
      def full_name(klass)
        ".#{[package(klass), message_name(klass)].reject(&:empty?).join(".")}"
      end

      # @param klass [Class<FieldStruct::Base>]
      # @return [String] +field_struct/billing/invoice.proto+
      def file_name(klass)
        "field_struct/#{klass.name.split("::").map { |part| underscore(part) }.join("/")}.proto"
      end

      private

      # @param klass [Class<FieldStruct::Base>]
      # @param serialization [Symbol]
      # @param pending [Array<Class>] the classes being registered, outermost first
      # @return [Class<Google::Protobuf::AbstractMessage>]
      def register(klass, serialization, pending = [])
        key = [klass, serialization]
        return @message_classes[key] if @message_classes.key?(key)
        if pending.include?(klass)
          raise ArgumentError, "#{(pending + [klass]).join(" -> ")}: structs that refer to each other would be " \
                               "protobuf files that import each other, which protobuf doesn't allow"
        end

        file = file_descriptor(klass, serialization: serialization)
        # The structs it refers to first: a file's imports must be in the pool.
        Introspection.properties(klass, serialization: serialization).each do |property|
          struct = struct_class(property.node)
          register(struct, serialization, pending + [klass]) if struct && struct != klass
        end
        Google::Protobuf::DescriptorPool.generated_pool.add_serialized_file(Google::Protobuf::FileDescriptorProto.encode(file))
        @message_classes[key] = Google::Protobuf::DescriptorPool.generated_pool.lookup(full_name(klass)[1..]).msgclass
      end

      # @param node [Object]
      # @return [Class<FieldStruct::Base>, nil]
      def struct_class(node)
        node = node.element if node.is_a?(Introspection::ArrayNode)
        node.klass if node.is_a?(Introspection::StructNode)
      end

      # @param name [String]
      # @return [String]
      def underscore(name)
        name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end

      # @param klass [Object]
      # @return [void]
      # @raise [ArgumentError]
      def check(klass)
        unless klass.is_a?(::Class) && klass < FieldStruct::Base
          raise ArgumentError, "FieldStruct::Protobuf expects a FieldStruct::Base subclass, got #{klass.inspect}"
        end
        return if Introspection.named?(klass)

        raise ArgumentError, 'FieldStruct::Protobuf needs a named class (assign it to a constant): ' \
                             'its message and package are named after it'
      end
    end
  end
end
