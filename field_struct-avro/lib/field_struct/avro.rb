# frozen_string_literal: true

require 'bigdecimal'
require 'json'
require 'stringio'
require 'avro'
require 'field_struct'
unless defined?(FieldStruct::Introspection)
  raise LoadError, "field_struct-avro needs FieldStruct::Introspection, which field_struct #{FieldStruct::VERSION} doesn't have; " \
                   'use a field_struct with it (develop, until the next release)'
end
require_relative 'avro/version'
require_relative 'avro/options'
require_relative 'avro/schema_builder'
require_relative 'avro/datum'
require_relative 'avro/resolution'
require_relative 'avro/cache'

module FieldStruct
  # Apache Avro for FieldStruct classes: a record schema per class, and
  # instances to and from Avro datums and binary.
  #
  #   FieldStruct::Avro.schema(Invoice)        # => {"type" => "record", "name" => "Invoice", …}
  #   bytes = FieldStruct::Avro.encode(invoice)
  #   FieldStruct::Avro.decode(Invoice, bytes) == invoice  # => true
  #
  # Every call takes the same options:
  #
  # * +serialization:+ the +serialize+ format whose names become Avro field
  #   names (default +:avro+; an undeclared format keeps the field names).
  # * +timestamp:+ +:micros+ (default), +:nanos+ or +:millis+, the precision
  #   of +:time+ and +:datetime+ fields. Encoding a time with more precision
  #   than that raises rather than drop it.
  #
  # A field's +avro:+ option adjusts its own mapping: +type:+ (the whole Avro
  # type, verbatim), +timestamp:+, +precision:+ / +scale:+ for decimals,
  # +enum: false+ (a string instead of an enum) and +enum_default:+. On an
  # array or union field, all but +type:+ apply to its elements or members.
  module Avro
    # @return [Array<Symbol>]
    TIMESTAMPS = %i[micros nanos millis].freeze

    # The Avro record schema for +klass+, as a Hash with String keys (ready
    # for +JSON.generate+ or a schema registry).
    #
    # @param klass [Class<FieldStruct::Base>]
    # @param serialization [Symbol, String]
    # @param timestamp [Symbol] +:micros+, +:nanos+ or +:millis+
    # @return [Hash{String=>Object}]
    # @raise [ArgumentError] when a field has no Avro mapping, or the schema
    #   isn't valid Avro (say, a typo in an +avro: {type:}+ option)
    def self.schema(klass, serialization: :avro, timestamp: :micros)
      serialization = check(klass, serialization, timestamp)
      # Going through the reader cache makes a bad option fail where the
      # schema is asked for (at boot or registration, not the first encode),
      # and builds the schema once per class; each call gets its own copy.
      Cache.deep_copy(CACHE.reader(klass, serialization, timestamp).schema)
    end

    # @param struct [FieldStruct::Base]
    # @param serialization [Symbol, String]
    # @param timestamp [Symbol]
    # @return [Hash{String=>Object}] the Avro datum for +struct+
    def self.to_datum(struct, serialization: :avro, timestamp: :micros)
      serialization = check(struct.class, serialization, timestamp)
      Datum.new(serialization:, timestamp:).dump(struct)
    end

    # @param klass [Class<FieldStruct::Base>]
    # @param datum [Hash{String=>Object}] as an Avro reader returns it
    # @param serialization [Symbol, String]
    # @return [FieldStruct::Base]
    def self.from_datum(klass, datum, serialization: :avro)
      serialization = check(klass, serialization)
      Datum.new(serialization:).load(klass, datum)
    end

    # @param struct [FieldStruct::Base]
    # @param serialization [Symbol, String]
    # @param timestamp [Symbol]
    # @return [String] the Avro binary encoding, without a container or header
    # @raise [ArgumentError] as {.schema} does, and when a time is too precise
    def self.encode(struct, serialization: :avro, timestamp: :micros)
      serialization = check(struct.class, serialization, timestamp)
      parsed = CACHE.reader(struct.class, serialization, timestamp).parsed
      io = StringIO.new(+'', 'wb')
      ::Avro::IO::DatumWriter.new(parsed).write(to_datum(struct, serialization:, timestamp:), ::Avro::IO::BinaryEncoder.new(io))
      io.string
    end

    # @param klass [Class<FieldStruct::Base>]
    # @param bytes [String] binary from {.encode}
    # @param writer_schema [Hash{String=>Object}, String, Object, nil] the schema the bytes were
    #   written with (a parsed +::Avro::Schema+ works too), when it differs from
    #   +klass+'s (Avro resolves the two)
    # @param serialization [Symbol, String]
    # @param timestamp [Symbol]
    # @return [FieldStruct::Base]
    # @raise [ArgumentError] as {.schema} does, for bytes the avro gem can't
    #   read or a +writer_schema:+ it can't parse, and when the avro gem would
    #   read a field as the wrong value or fail to read it (see {Resolution})
    def self.decode(klass, bytes, writer_schema: nil, serialization: :avro, timestamp: :micros)
      serialization = check(klass, serialization, timestamp)
      entry = CACHE.reader(klass, serialization, timestamp)
      reader = entry.parsed
      # A field the writer lacked takes field_struct's own default, which
      # the Avro default can't always express (a date, a decimal, a proc).
      writer, skip = writer_schema ? CACHE.writer(writer_schema, entry) : [reader, {}]
      datum = read(klass, bytes, writer, reader)
      Datum.new(serialization:, absent: skip).load(klass, datum)
    end

    # The avro gem reads bytes that end early or don't match the writer
    # schema into whatever error its reader trips on (EOFError,
    # NoMethodError, a SchemaMatchException); this names the class instead.
    # The message leaves the avro gem's text out, which can quote values;
    # it stays on the error's +cause+.
    #
    # @param klass [Class<FieldStruct::Base>]
    # @param bytes [String]
    # @param writer [Object] an +::Avro::Schema+
    # @param reader [Object] an +::Avro::Schema+
    # @return [Hash{String=>Object}] the datum
    # @raise [ArgumentError]
    def self.read(klass, bytes, writer, reader)
      ::Avro::IO::DatumReader.new(writer, reader).read(::Avro::IO::BinaryDecoder.new(StringIO.new(bytes)))
    rescue EOFError, NoMethodError, TypeError, RangeError, ::Avro::AvroError => e
      raise ArgumentError, "FieldStruct::Avro can't decode these bytes as #{klass} (#{e.class}): they end early, " \
                           "or weren't written with the writer schema given (pass writer_schema: for bytes from an older one)"
    end
    private_class_method :read

    # @param klass [Object]
    # @param serialization [Object]
    # @param timestamp [Object]
    # @return [Symbol] the serialization, as a Symbol
    # @raise [ArgumentError]
    def self.check(klass, serialization, timestamp = :micros)
      unless klass.is_a?(::Class) && klass < FieldStruct::Base
        raise ArgumentError, "FieldStruct::Avro expects a FieldStruct::Base subclass, got #{klass.inspect}"
      end
      unless TIMESTAMPS.include?(timestamp)
        raise ArgumentError, "FieldStruct::Avro timestamp: must be one of #{TIMESTAMPS.inspect}, got #{timestamp.inspect}"
      end

      # A String works, as in FieldStruct::JSONSchema.generate, and shares the Symbol's cache entries.
      serialization = serialization.to_sym if serialization.is_a?(::String)
      return serialization if serialization.is_a?(::Symbol)

      raise ArgumentError, "FieldStruct::Avro expects serialization: to be a Symbol, got #{serialization.inspect}"
    end
    private_class_method :check

    # Opt-in class and instance methods:
    #
    #   class Invoice < FieldStruct::Base
    #     include FieldStruct::Avro::Methods
    #   end
    #   Invoice.to_avro_schema; invoice.to_avro; Invoice.from_avro(bytes)
    module Methods
      # @param base [Class]
      # @return [void]
      def self.included(base)
        base.extend(ClassMethods)
      end

      # The keyword splats below are named, not anonymous, so sord can type
      # them from their @param (it drops a @param it can't match to a name).
      # rubocop:disable Style/ArgumentsForwarding

      # @param options [Hash{Symbol=>Object}] see {FieldStruct::Avro.encode}
      # @return [String]
      def to_avro(**options) = FieldStruct::Avro.encode(self, **options)

      # Class methods added by {Methods}.
      module ClassMethods
        # @param options [Hash{Symbol=>Object}] see {FieldStruct::Avro.schema}
        # @return [Hash{String=>Object}]
        def to_avro_schema(**options) = FieldStruct::Avro.schema(self, **options)

        # @param bytes [String]
        # @param options [Hash{Symbol=>Object}] see {FieldStruct::Avro.decode}
        # @return [FieldStruct::Base]
        def from_avro(bytes, **options) = FieldStruct::Avro.decode(self, bytes, **options)
      end
      # rubocop:enable Style/ArgumentsForwarding
    end
  end
end
