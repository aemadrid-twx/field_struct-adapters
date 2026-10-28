# frozen_string_literal: true

module FieldStruct
  module Avro
    # Checks a writer and reader schema pair before {Avro.decode} resolves
    # them. The avro gem matches a field by its base type only, so a decimal
    # written with scale 2 and read with scale 3, or a timestamp written in
    # micros and read in nanos, decodes without an error into the wrong
    # value. This walks both schemas the way resolution pairs them and raises
    # instead. Only the logical types the avro gem decodes count (decimal,
    # date, the timestamps): a +uuid+ is a plain string on the wire.
    #
    # @api private
    class Resolution
      # Writer type => the reader types Avro promotes it to.
      # @return [Hash{Symbol=>Array<Symbol>}]
      PROMOTIONS = {
        int: %i[long float double], long: %i[float double], float: %i[double],
        string: %i[bytes], bytes: %i[string]
      }.freeze

      # @param writer [Object] an +::Avro::Schema+
      # @param reader [Object] an +::Avro::Schema+
      # @return [Hash{String=>Array<String>}] for each reader record's full
      #   name, the fields the writer lacked, which the avro gem fills from
      #   the reader's defaults
      # @raise [ArgumentError] naming each field whose logical type differs,
      #   or that the avro gem fails to decode
      def self.check(writer, reader)
        resolution = new
        problems = resolution.compare(writer, reader, '', [])
        return resolution.absent if problems.empty?

        raise ArgumentError, "FieldStruct::Avro can't read these bytes: #{problems.join("; ")}. " \
                             'The avro gem would decode them as the wrong value, or fail; this is not a compatible schema change'
      end

      def initialize
        @absent = Hash.new { |hash, name| hash[name] = [] }
      end

      # @return [Hash{String=>Array<String>}]
      attr_reader :absent

      # @param writer [Object] an +::Avro::Schema+
      # @param reader [Object] an +::Avro::Schema+
      # @param path [String]
      # @param seen [Array<Array<String>>] writer and reader names of the records
      #   already walked (recursive structs)
      # @return [Array<String>]
      def compare(writer, reader, path, seen)
        if reader.type_sym == :union
          return union(writer, reader, path, seen)
        elsif writer.type_sym == :union
          # Only the branches the avro gem would read as this reader.
          paired = writer.schemas.select { |branch| ::Avro::SchemaCompatibility.match_schemas(branch, reader) }
          problems = paired.flat_map { |branch| compare(branch, reader, path, seen) }
          # The double decode matters only once nothing else blocks the field.
          return problems.empty? ? unwrapped(paired, reader, path) : problems
        end
        return promoted(writer, reader, path) unless writer.type_sym == reader.type_sym

        case reader.type_sym
        when :record then record(writer, reader, path, seen)
        when :array then compare(writer.items, reader.items, "#{path}[]", seen)
        when :map then compare(writer.values, reader.values, "#{path}{}", seen)
        else logical(writer, reader, path)
        end
      end

      private

      # @param writer [Object] an +::Avro::Schema+
      # @param reader [Object] an +::Avro::Schema+
      # @param path [String]
      # @param seen [Array<Array<String>>]
      # @return [Array<String>]
      def union(writer, reader, path, seen)
        branches = writer.type_sym == :union ? writer.schemas : [writer]
        branches.flat_map do |branch|
          # The branch the avro gem itself picks, promotions included.
          match = reader.schemas.find { |candidate| ::Avro::SchemaCompatibility.match_schemas(branch, candidate) }
          match ? compare(branch, match, path, seen) : []
        end
      end

      # @param writer [Object] an +::Avro::Schema+
      # @param reader [Object] an +::Avro::Schema+
      # @param path [String]
      # @param seen [Array<Array<String>>]
      # @return [Array<String>]
      def record(writer, reader, path, seen)
        pair = [writer.fullname, reader.fullname]
        return [] if seen.include?(pair)

        fields = writer.fields.to_h { |field| [field.name, field] }
        reader.fields.flat_map do |field|
          written = fields[field.name]
          next compare(written.type, field.type, [path, field.name].reject(&:empty?).join('.'), seen + [pair]) if written

          @absent[reader.fullname] |= [field.name]
          []
        end
      end

      # A writer's union read as a bare logical type: the avro gem 1.12
      # decodes the value twice (once for the branch, once for the reader),
      # so a time, date or decimal fails inside the gem (Time#divmod and the
      # like). Making a field required that was optional does this.
      #
      # @param paired [Array<Object>] the writer branches matching +reader+
      # @param reader [Object] an +::Avro::Schema+ the avro gem decodes
      # @param path [String]
      # @return [Array<String>]
      def unwrapped(paired, reader, path)
        return [] if paired.empty? || !decoded(reader)

        ["#{path}: written as a union with #{describe(paired.first)}, read as #{describe(reader)} outside one, " \
         'which the avro gem fails to decode (keep the field optional)']
      end

      # Avro promotes a writer's int to long, float or double, a long to
      # float or double, and string and bytes into each other. When either
      # side is a decoded logical type, the promoted value is wrong: a date's
      # day count read as a timestamp's micros, a decimal's bytes as text.
      #
      # @param writer [Object] an +::Avro::Schema+
      # @param reader [Object] an +::Avro::Schema+
      # @param path [String]
      # @return [Array<String>]
      def promoted(writer, reader, path)
        return [] unless PROMOTIONS.fetch(writer.type_sym, []).include?(reader.type_sym)
        return [] unless [writer, reader].any? { |schema| decoded(schema) }

        ["#{path}: written as #{describe(writer)}, read as #{describe(reader)}"]
      end

      # @param schema [Object] an +::Avro::Schema+
      # @return [String, nil] its logical type, when the avro gem decodes it
      def decoded(schema)
        schema.logical_type if ::Avro::LogicalTypes::TYPES.dig(schema.type, schema.logical_type)
      end

      # @param writer [Object] an +::Avro::Schema+
      # @param reader [Object] an +::Avro::Schema+
      # @param path [String]
      # @return [Array<String>]
      def logical(writer, reader, path)
        written = describe(writer)
        read = describe(reader)
        written == read ? [] : ["#{path}: written as #{written}, read as #{read}"]
      end

      # Precision isn't part of it: the avro gem never reads it when decoding,
      # so widening a decimal's precision is a safe change.
      #
      # @param schema [Object] an +::Avro::Schema+
      # @return [String]
      def describe(schema)
        name = decoded(schema) || schema.type_sym.to_s
        return name unless name == 'decimal'

        "#{name} (scale #{schema.scale || 0})"
      end
    end
  end
end
