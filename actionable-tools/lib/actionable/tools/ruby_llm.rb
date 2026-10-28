# frozen_string_literal: true

require 'actionable/tools'
begin
  require 'ruby_llm'
rescue LoadError
  raise LoadError, "actionable/tools/ruby_llm needs the ruby_llm gem: add `gem 'ruby_llm', '~> 2.1'` to your Gemfile"
end

module Actionable
  module Tools
    # Actions as RubyLLM tools.
    #
    #   RefundTool = Actionable::Tools::RubyLLM.tool(RefundOrder,
    #     description: 'Refund part or all of an order',
    #     context: {user_id: ->(user) { user.id }})
    #   chat.with_tool(RefundTool.new(current_user))
    #
    # The tool's argument is what its context procs read. Every outcome comes
    # back to the model as the Hash {Definition#call} documents.
    module RubyLLM
      module_function

      # The keyword splat is named, not anonymous, so sord can type it from its
      # @param.
      # rubocop:disable Style/ArgumentsForwarding

      # @param action [Class<Actionable::Action>]
      # @param approval [Boolean] pause each call until it's approved
      #   (RubyLLM's +requires_approval+)
      # @param options [Hash{Symbol=>Object}] {Tools.definition}'s keywords
      # @return [Class] a +::RubyLLM::Tool+ subclass (ruby_llm ships no RBS
      #   signatures)
      def tool(action, approval: false, **options)
        from(Tools.definition(action, **options), approval: approval)
      end
      # rubocop:enable Style/ArgumentsForwarding

      # @param definition [Definition]
      # @param approval [Boolean]
      # @return [Class] a +::RubyLLM::Tool+ subclass
      def from(definition, approval: false)
        Class.new(::RubyLLM::Tool) do
          description definition.description
          parameters definition.input_schema
          requires_approval if approval
          define_singleton_method(:tool_name) { definition.name }

          define_method(:initialize) do |source = nil|
            super()
            @source = source
          end

          define_method(:execute) { |**arguments| definition.call(arguments, @source) }
        end
      end
    end
  end
end
