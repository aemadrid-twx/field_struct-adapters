# frozen_string_literal: true

require 'json'
require 'actionable'
require 'field_struct/json_schema'
require_relative 'tools/version'

module Actionable
  # Actionable actions as tools an LLM can call. {.definition} describes one
  # action in a form-neutral way (a name, a description, JSON Schemas for its
  # input and result, and {Definition#call}); +actionable/tools/mcp+ and
  # +actionable/tools/ruby_llm+ wrap a definition for those libraries.
  #
  # Nothing is exposed unless you name it: there's no "every registered
  # action" option, because an action that's safe to call from your code isn't
  # automatically safe to hand to a model.
  module Tools
    # Every result has these keys, whatever its outcome, so a model never has
    # to guess which ones are present.
    #
    # @return [Array<String>]
    RESULT_KEYS = %w[status code message output errors metadata].freeze

    module_function

    # @param action [Class<Actionable::Action>] an action with an +input+ schema
    # @param description [String] what the tool does, for the model; required
    #   until actions can describe themselves
    # @param name [String, nil] the tool's name; defaults to the action's class
    #   name, underscored (+Billing::RefundOrder+ becomes +refund_order+)
    # @param context [Hash{Symbol=>Proc}] input fields your server supplies
    #   rather than the model (the current user, a tenant), each with a proc
    #   that reads it from the context the integration passes to {Definition#call}
    # @param annotations [Hash{Symbol=>Boolean}] hints for the client:
    #   +read_only:+, +destructive:+, +idempotent:+, +open_world:+
    # @raise [ArgumentError] for an action without an input schema, a context
    #   field the input doesn't declare, or a missing description
    # @return [Definition]
    def definition(action, description:, name: nil, context: {}, annotations: {})
      Definition.new(action, description: description, name: name, context: context, annotations: annotations)
    end

    # One action, described as a tool. Immutable; build it once, at boot.
    class Definition
      # @return [Class<Actionable::Action>]
      attr_reader :action
      # @return [String]
      attr_reader :name
      # @return [String]
      attr_reader :description
      # @return [Hash{Symbol=>Boolean}]
      attr_reader :annotations
      # @return [Hash{String=>Object}] the JSON Schema of what the model sends
      attr_reader :input_schema
      # @return [Hash{String=>Object}] the JSON Schema of what {#call} returns
      attr_reader :output_schema

      # @param action [Class<Actionable::Action>]
      # @param description [String]
      # @param name [String, nil]
      # @param context [Hash{Symbol=>Proc}]
      # @param annotations [Hash{Symbol=>Boolean}]
      def initialize(action, description:, name:, context:, annotations:)
        @action = action
        if action.respond_to?(:input_dispatch) && action.input_dispatch
          raise ArgumentError, "#{action} has a discriminated input (input_for), which has no single schema yet"
        end

        @input = action.input_schema or raise ArgumentError, "#{action} has no input schema; tools need one"
        raise ArgumentError, "#{action}: a tool needs a description" if description.to_s.strip.empty?

        @description = description
        @name = name || default_name(action)
        @context = context.transform_keys(&:to_sym).freeze
        unknown = @context.keys - @input.attribute_names
        raise ArgumentError, "#{action} has no input field #{unknown.join(", ")} to take from context" if unknown.any?

        @annotations = annotations.freeze
        @input_schema = build_input_schema.freeze
        @output_schema = build_output_schema.freeze
        freeze
      end

      # Runs the action with the model's arguments plus the context fields.
      #
      # A context field the model sends anyway is ignored: those values come
      # only from +source+. Exceptions the action raises propagate.
      #
      # @param arguments [Hash{String,Symbol=>Object}] the model's arguments
      # @param source [Object] what the context procs read from (MCP's
      #   +server_context+, or whatever you built the RubyLLM tool with)
      # @return [Hash{String=>Object}] +status+ (+success+, +failure+ or
      #   +skipped+), +code+, +message+, +output+, +errors+ (field name to
      #   messages) and +metadata+, always all six
      def call(arguments, source = nil)
        input = arguments.to_h.transform_keys(&:to_sym)
        @context.each { |field, reader| input[field] = reader.call(source) }
        result_hash(action.run(**input))
      end

      # @param result [Hash{String=>Object}] what {#call} returned
      # @return [Boolean] whether it reports a failure (a skip isn't one)
      def error?(result)
        result['status'] == 'failure'
      end

      private

      # @param action [Class]
      # @return [String]
      def default_name(action)
        base = action.name.to_s.split('::').last or raise ArgumentError, 'an anonymous action needs name:'
        base.gsub(/([a-z\d])([A-Z])/, '\1_\2').gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').downcase
      end

      # @return [Hash{String=>Object}]
      def build_input_schema
        schema = FieldStruct::JSONSchema.generate(@input)
        keys = @context.keys.map { |field| external_key(field) }
        schema['properties'] = schema['properties'].except(*keys)
        schema['required'] = schema['required'] - keys if schema['required']
        schema.delete('required') if schema['required'] && schema['required'].empty?
        schema
      end

      # The JSON name of an input field, as the schema's properties use it.
      #
      # @param field [Symbol]
      # @return [String]
      def external_key(field)
        FieldStruct::Introspection.properties(@input).find { |property| property.field.name == field }.key
      end

      # The result envelope. +output+ follows the action's output schema only
      # on success: a failed or skipped run's output may leave required fields
      # empty.
      #
      # @return [Hash{String=>Object}]
      def build_output_schema
        schema = {
          '$schema' => FieldStruct::JSONSchema::DRAFT,
          'type' => 'object',
          'properties' => {
            'status' => {'enum' => %w[success failure skipped]},
            'code' => {'type' => 'string', 'description' => code_description},
            'message' => {'type' => %w[string null]},
            'output' => {},
            'errors' => {'type' => 'object', 'additionalProperties' => {'type' => 'array', 'items' => {'type' => 'string'}}},
            'metadata' => {'type' => 'object'}
          },
          'required' => RESULT_KEYS
        }
        output = action.output_schema
        return schema unless output

        success = FieldStruct::JSONSchema.generate(output)
        success.delete('$schema')
        defs = success.delete('$defs')
        schema['$defs'] = defs if defs
        schema['if'] = {'properties' => {'status' => {'const' => 'success'}}}
        schema['then'] = {'properties' => {'output' => success}}
        schema
      end

      # @return [String]
      def code_description
        failures = action.declared_failures.keys
        skips = action.declared_skips.keys
        text = +'"success", or why the run failed or was skipped.'
        text << " Declared failures: #{failures.join(", ")}." if failures.any?
        text << " Declared skips: #{skips.join(", ")}." if skips.any?
        text << ' "invalid_input" means the arguments were rejected; see errors.'
        text
      end

      # @param result [Actionable::Result]
      # @return [Hash{String=>Object}]
      def result_hash(result)
        {
          'status' => result.status.to_s,
          'code' => result.code.to_s,
          'message' => result.message,
          'output' => json(result.output),
          'errors' => json(result.errors.to_h),
          'metadata' => result.respond_to?(:metadata) ? json(result.metadata) : {}
        }
      end

      # @param value [Object]
      # @return [Object] +value+ as JSON would carry it
      def json(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
