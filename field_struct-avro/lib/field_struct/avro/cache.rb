# frozen_string_literal: true

module FieldStruct
  module Avro
    # Keeps what {FieldStruct::Avro} would otherwise rebuild on every call:
    # the parsed reader schema of a class and a writer schema parsed and
    # checked against it (for +encode+ and +decode+), and a class's field
    # list (for {Datum}, so +to_datum+ and +from_datum+ too).
    #
    # An entry remembers, for every struct class it covers, the class's Field
    # objects (in order), its serialization mapping and its name, and a hit
    # re-reads them, rebuilding when any changed. So a field added, replaced
    # or renamed after first use, a +serialize+ declared later, or an
    # anonymous struct assigned to a constant (which renames its record) is
    # picked up. Fields are frozen, so comparing the arrays compares each
    # field by identity.
    #
    # @api private
    class Cache
      # A reader entry. (A plain class, not a Struct: sord writes a Struct
      # constant as +::Struct+ without its type parameter, which rbs refuses.)
      class Reader
        # @return [Object] the +::Avro::Schema+ (the avro gem ships no
        #   signatures, so the sig can't name its class)
        attr_reader :parsed
        # @return [Hash{Class<FieldStruct::Base>=>Array<String>}] the Avro
        #   record names each struct class was written as
        attr_reader :records
        # @return [Hash{Class<FieldStruct::Base>=>Array<Object>}]
        attr_reader :stamps
        # @return [Hash{String=>Object}] the schema {FieldStruct::Avro.schema}
        #   copies, deeply frozen
        attr_reader :schema

        # @param parsed [Object]
        # @param records [Hash{Class<FieldStruct::Base>=>Array<String>}]
        # @param stamps [Hash{Class<FieldStruct::Base>=>Array<Object>}]
        # @param schema [Hash{String=>Object}]
        def initialize(parsed, records, stamps, schema)
          @parsed = parsed
          @records = records
          @stamps = stamps
          @schema = schema
          freeze
        end
      end

      # A properties entry: the list and the stamp it is valid for.
      class Properties
        # @return [Array<FieldStruct::Introspection::Property>]
        attr_reader :list
        # @return [Array<Object>] see {Cache.stamp}
        attr_reader :stamp

        # @param list [Array<FieldStruct::Introspection::Property>]
        # @param stamp [Array<Object>]
        def initialize(list, stamp)
          @list = list
          @stamp = stamp
          freeze
        end
      end

      # Bound on writer entries, so a caller passing ever-new writer schemas
      # can't grow the cache without limit.
      # @return [Integer]
      WRITERS_MAX = 512

      def initialize
        @readers = {}
        @writers = {}
        @properties = {}
        @lock = Mutex.new
      end

      # @param klass [Class<FieldStruct::Base>]
      # @param serialization [Symbol]
      # @param timestamp [Symbol]
      # @return [FieldStruct::Avro::Cache::Reader]
      # @raise [ArgumentError] when the schema doesn't parse
      def reader(klass, serialization, timestamp)
        key = [klass, serialization, timestamp]
        entry = @readers[key]
        return entry if entry && fresh?(entry.stamps, serialization)

        builder = SchemaBuilder.new(klass, serialization:, timestamp:)
        schema = builder.schema
        parsed = parse(klass, schema)
        records = builder.records.transform_values(&:freeze).freeze
        entry = Reader.new(parsed, records, builder.stamps.freeze, Cache.deep_freeze(Cache.deep_copy(schema)))
        @lock.synchronize do
          stale = @readers[key]
          @writers.delete_if { |(_, owner), _| owner.equal?(stale) } if stale
          @readers[key] = entry
        end
        entry
      end

      # @param klass [Class<FieldStruct::Base>]
      # @param schema [Hash{String=>Object}]
      # @return [Object] the parsed schema
      # @raise [ArgumentError] naming +klass+, when the avro gem rejects it
      def parse(klass, schema)
        ::Avro::Schema.parse(JSON.generate(schema))
      rescue ::Avro::SchemaParseError => e
        raise ArgumentError, "FieldStruct::Avro: #{klass.name || klass.inspect} doesn't make a valid Avro schema " \
                             "(check the avro: options of its fields and nested structs): #{e.message}"
      end
      private :parse

      # @param writer_schema [Hash{String=>Object}, String, Object] Object being an +::Avro::Schema+
      # @return [String] the schema as JSON text
      # @raise [ArgumentError] for anything else
      def writer_json(writer_schema)
        case writer_schema
        when ::String then writer_schema
        when ::Hash then JSON.generate(writer_schema)
        # Registry clients hand back parsed schemas. Its JSON drops x- properties,
        # which a writer schema doesn't need.
        when ::Avro::Schema then writer_schema.to_s
        else
          raise ArgumentError, 'FieldStruct::Avro.decode: writer_schema: expects a Hash, a JSON String or an Avro::Schema, ' \
                               "got #{writer_schema.class}"
        end
      end
      private :writer_json

      # @param json [String]
      # @return [Object] the parsed writer schema
      # @raise [ArgumentError] when it isn't JSON, or not an Avro schema
      def parse_writer(json)
        ::Avro::Schema.parse(json)
      rescue ::MultiJSON::ParseError, ::Avro::SchemaParseError => e
        raise ArgumentError, "FieldStruct::Avro.decode: writer_schema: isn't a valid Avro schema (#{e.class}: #{e.message})"
      end
      private :parse_writer

      # @param writer_schema [Hash{String=>Object}, String, Object] Object being an +::Avro::Schema+
      # @param reader [FieldStruct::Avro::Cache::Reader]
      # @return [Array(Object, Hash{Class<FieldStruct::Base>=>Array<String>})] the
      #   parsed writer schema, and the Avro field names it lacked per struct
      #   class, which {Datum#load} leaves to field_struct's defaults
      # @raise [ArgumentError] from {Resolution.check}
      def writer(writer_schema, reader)
        # A frozen copy, so a caller changing its String can't strand the entry.
        json = -writer_json(writer_schema)
        key = [json, reader]
        hit = @writers[key]
        return hit if hit

        parsed = parse_writer(json)
        absent = Resolution.check(parsed, reader.parsed)
        # A class written under several record names skips only what all of
        # them lacked, so a value one of them carried is never dropped.
        skip = reader.records.transform_values { |names| names.map { |name| absent.fetch(name, []) }.reduce(:&).freeze }.freeze
        entry = [parsed, skip].freeze
        @lock.synchronize do
          # Oldest first: a Hash keeps insertion order.
          @writers.shift while @writers.size >= WRITERS_MAX
          @writers[key] = entry
        end
        entry
      end

      # +FieldStruct::Introspection.properties+ for a class, which {Datum}
      # asks for every instance and nested record it converts.
      #
      # @param klass [Class<FieldStruct::Base>]
      # @param serialization [Symbol]
      # @return [Array<FieldStruct::Introspection::Property>] frozen
      def properties(klass, serialization)
        key = [klass, serialization]
        entry = @properties[key]
        return entry.list if entry && current?(klass, entry.stamp, serialization)

        # Stamped before reading, so a change made meanwhile is seen next time.
        stamp = Cache.stamp(klass, serialization)
        list = Introspection.properties(klass, serialization:).freeze
        list.each { |property| Options.check_shape(property, "#{klass.inspect}##{property.field.name}") }
        @lock.synchronize { @properties[key] = Properties.new(list, stamp) }
        list
      end

      # What an entry is valid for, per class: its Field objects, its
      # serialization mapping and its name.
      #
      # @param klass [Class<FieldStruct::Base>]
      # @param serialization [Symbol]
      # @return [Array(Array<FieldStruct::Field>, Object, String)]
      def self.stamp(klass, serialization)
        meta = klass.metadata
        [meta.to_a.freeze, meta.serialization(serialization), klass.name].freeze
      end

      # @param value [Object] a schema, or part of one
      # @return [Object] a copy sharing nothing mutable with +value+
      def self.deep_copy(value)
        case value
        # A Hash freezes its own copy of a String key, so keys can be shared.
        when ::Hash then value.to_h { |key, item| [key, deep_copy(item)] }
        when ::Array then value.map { |item| deep_copy(item) }
        when ::String then value.dup
        else value
        end
      end

      # Freezes the Hashes, Arrays and Strings {.deep_copy} made, and nothing
      # else: anything it passed through is still the caller's object.
      #
      # @param value [Object] a copy from {.deep_copy}
      # @return [Object] +value+
      def self.deep_freeze(value)
        case value
        when ::Hash then value.each_value { |item| deep_freeze(item) }.freeze
        when ::Array then value.each { |item| deep_freeze(item) }.freeze
        when ::String then value.freeze
        else value
        end
      end

      private

      # @param stamps [Hash{Class<FieldStruct::Base>=>Array<Object>}]
      # @param serialization [Symbol]
      # @return [Boolean]
      def fresh?(stamps, serialization)
        stamps.all? { |klass, stamp| current?(klass, stamp, serialization) }
      end

      # @param klass [Class<FieldStruct::Base>]
      # @param stamp [Array<Object>] see {Cache.stamp}
      # @param serialization [Symbol]
      # @return [Boolean]
      def current?(klass, stamp, serialization)
        fields, mapping, name = stamp
        meta = klass.metadata
        meta.serialization(serialization).equal?(mapping) && klass.name == name && meta.to_a == fields
      end
    end

    # The process-wide cache {FieldStruct::Avro}'s methods share.
    #
    # @api private
    # @return [FieldStruct::Avro::Cache]
    CACHE = Cache.new
  end
end
