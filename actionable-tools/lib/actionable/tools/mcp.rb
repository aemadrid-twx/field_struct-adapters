# frozen_string_literal: true

require 'actionable/tools'
begin
  require 'mcp'
rescue LoadError
  raise LoadError, "actionable/tools/mcp needs the mcp gem: add `gem 'mcp', '~> 1.8'` to your Gemfile"
end

module Actionable
  module Tools
    # Actions as tools for the MCP Ruby SDK (the +mcp+ gem).
    #
    #   tool = Actionable::Tools::MCP.tool(RefundOrder,
    #     description: 'Refund part or all of an order',
    #     context: {user_id: ->(server_context) { server_context[:user_id] }},
    #     annotations: {destructive: true})
    #   MCP::Server.new(name: 'shop', tools: [tool], server_context: {user_id: current_user.id})
    #
    # Success and skipped runs come back as +structuredContent+, a failure
    # with +isError+ set, all in the shape {Definition#call} documents, and the
    # same JSON as text for clients that read only +content+.
    module MCP
      # MCP's hint names for {Tools.definition}'s +annotations:+.
      #
      # @return [Hash{Symbol=>Symbol}]
      HINTS = {read_only: :read_only_hint, destructive: :destructive_hint,
               idempotent: :idempotent_hint, open_world: :open_world_hint}.freeze

      module_function

      # @param action [Class<Actionable::Action>]
      # @param options [Hash] {Tools.definition}'s keywords; context procs
      #   receive the server's +server_context+
      # @return [Class<::MCP::Tool>]
      def tool(action, **)
        from(Tools.definition(action, **))
      end

      # @param definition [Definition]
      # @return [Class<::MCP::Tool>]
      def from(definition)
        ::MCP::Tool.define(
          name: definition.name,
          description: definition.description,
          input_schema: definition.input_schema,
          output_schema: definition.output_schema,
          annotations: annotations(definition.annotations)
        ) do |server_context: nil, **arguments|
          result = definition.call(arguments, server_context)
          ::MCP::Tool::Response.new([{type: 'text', text: JSON.generate(result)}],
            error: definition.error?(result), structured_content: result)
        end
      end

      # @param hints [Hash{Symbol=>Boolean}]
      # @return [Hash{Symbol=>Boolean}, nil]
      def annotations(hints)
        return nil if hints.empty?

        unknown = hints.keys - HINTS.keys
        raise ArgumentError, "unknown annotations: #{unknown.join(", ")} (known: #{HINTS.keys.join(", ")})" if unknown.any?

        hints.to_h { |key, value| [HINTS.fetch(key), value] }
      end
    end
  end
end
