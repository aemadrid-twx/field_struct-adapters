# frozen_string_literal: true

module FieldStruct
  module Avro
    # A field's +avro:+ option, read the same way by {SchemaBuilder} (the
    # schema) and {Datum} (the bytes), so the two can't disagree.
    #
    # @api private
    module Options
      # @return [Hash{Symbol=>Object}] no +avro:+ options
      NONE = {}.freeze

      module_function

      # @param property [FieldStruct::Introspection::Property]
      # @return [Hash{Symbol=>Object}] the field's +avro:+ option. It is a
      #   field option: struct and union nodes carry no options, and core
      #   refuses +element: {avro: …}+. One that isn't a Hash was refused
      #   by {.check_shape} when the class's fields were first read.
      def field(property)
        options = property.field.options[:avro]
        options.is_a?(::Hash) ? options : NONE
      end

      # @param property [FieldStruct::Introspection::Property]
      # @param label [String] the field, as Class#field
      # @return [void]
      # @raise [ArgumentError] when its +avro:+ option isn't a Hash
      def check_shape(property, label)
        options = property.field.options[:avro]
        return if options.nil? || options.is_a?(::Hash)

        raise ArgumentError, "FieldStruct::Avro (#{label}) avro: takes a Hash of options, like avro: {type: 'string'}, got #{options.inspect}"
      end

      # An array's elements and a union's members take the field's options,
      # except +:type+, which replaces only the field it was given on.
      #
      # @param avro [Hash{Symbol=>Object}]
      # @return [Hash{Symbol=>Object}]
      def nested(avro)
        avro.key?(:type) ? avro.except(:type) : avro
      end

      # +type: nil+ is no override, so the schema and the datum agree on it.
      #
      # @param avro [Hash{Symbol=>Object}]
      # @return [Boolean]
      def override?(avro)
        !avro[:type].nil?
      end

      # @param avro [Hash{Symbol=>Object}]
      # @return [String, Hash{String=>Object}, Array<Object>, nil] the
      #   +type:+ as Avro JSON (symbols as strings), or +nil+ without one
      def type(avro)
        json(avro[:type]) if override?(avro)
      end

      # @param value [Object]
      # @return [Object] +value+ as JSON would carry it: symbols and Hash
      #   keys as strings, the rest as given
      def json(value)
        case value
        when ::Hash then value.to_h { |key, item| [key.to_s, json(item)] }
        when ::Array then value.map { |item| json(item) }
        when ::Symbol then value.to_s
        else value
        end
      end

      # @param type [String, Hash{String=>Object}, Array<Object>, nil] from {.type}
      # @return [Boolean] whether it is Avro +string+, nullable or not, in any
      #   spelling (+"string"+, +{"type" => "string"}+ with no logical type,
      #   inside a union)
      def string?(type)
        branches = Array(type.is_a?(::Hash) ? [type] : type).map do |branch|
          branch.is_a?(::Hash) && !branch.key?('logicalType') ? branch['type'] : branch
        end
        (branches - ['null']) == ['string']
      end

      # @param avro [Hash{Symbol=>Object}]
      # @param default [Symbol] the +timestamp:+ given to the call
      # @param field [String, nil] the field, as Class#field, for the error
      # @param error [Class<ArgumentError>, nil] raised with just the detail
      #   instead, for a caller that names the field itself
      # @return [Symbol]
      # @raise [ArgumentError] for an unknown precision
      def timestamp(avro, default, field = nil, error: nil)
        value = avro.fetch(:timestamp, default)
        return value if TIMESTAMPS.include?(value)

        detail = "avro: {timestamp:} must be one of #{TIMESTAMPS.inspect}, got #{value.inspect}"
        raise error, detail if error

        raise ArgumentError, "FieldStruct::Avro#{" (#{field})" if field} #{detail}"
      end

      # @param avro [Hash{Symbol=>Object}]
      # @param options [Hash{Symbol=>Object}] the field's options
      # @param type [FieldStruct::Types::BigDecimal]
      # @return [Object] the decimal scale, +nil+ when it travels as a string
      def scale(avro, options, type)
        avro.fetch(:scale) { options.fetch(:round) { type.class.default_round } }
      end
    end
  end
end
