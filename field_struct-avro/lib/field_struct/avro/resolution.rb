# frozen_string_literal: true

module FieldStruct
  module Avro
    # Checks a writer and reader schema pair before {Avro.decode} resolves
    # them. The avro gem matches a field by its base type only, so a decimal
    # written with scale 2 and read with scale 3, or a timestamp written in
    # micros and read in nanos, decodes without an error into the wrong
    # value. This walks both schemas the way resolution pairs them and raises
    # instead.
    #
    # @api private
    class Resolution
      # @param writer [Object] an +::Avro::Schema+
      # @param reader [Object] an +::Avro::Schema+
      # @return [void]
      # @raise [ArgumentError] naming each field whose logical type differs
      def self.check(writer, reader)
        problems = new.compare(writer, reader, '', [])
        return if problems.empty?

        raise ArgumentError, "FieldStruct::Avro can't read these bytes: #{problems.join("; ")}. " \
                             'A changed decimal scale or timestamp precision is not a compatible schema change'
      end

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
          return writer.schemas.flat_map { |branch| compare(branch, reader, path, seen) }
        end
        return [] unless writer.type_sym == reader.type_sym

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
          match = reader.schemas.find { |candidate| same_branch?(branch, candidate) }
          match ? compare(branch, match, path, seen) : []
        end
      end

      # @param writer [Object] an +::Avro::Schema+
      # @param reader [Object] an +::Avro::Schema+
      # @return [Boolean]
      def same_branch?(writer, reader)
        return false unless writer.type_sym == reader.type_sym

        !writer.respond_to?(:fullname) || writer.fullname == reader.fullname
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
          written ? compare(written.type, field.type, [path, field.name].reject(&:empty?).join('.'), seen + [pair]) : []
        end
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

      # @param schema [Object] an +::Avro::Schema+
      # @return [String]
      def describe(schema)
        name = schema.logical_type || schema.type_sym.to_s
        return name unless schema.logical_type == 'decimal'

        "#{name} (precision #{schema.precision}, scale #{schema.scale || 0})"
      end
    end
  end
end
