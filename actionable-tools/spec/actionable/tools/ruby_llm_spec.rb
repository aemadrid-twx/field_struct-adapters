# frozen_string_literal: true

require 'actionable/tools/ruby_llm'

RSpec.describe Actionable::Tools::RubyLLM do
  let(:tool_class) do
    described_class.tool(ToolSpecs::RefundOrder,
      description: 'Refund part or all of an order',
      context: {user_id: lambda(&:id)})
  end
  let(:user) { Struct.new(:id).new(7) }
  let(:tool) { tool_class.new(user) }

  before { ToolSpecs.refunds.clear }

  it 'describes itself as RubyLLM sends it to a model' do
    expect(tool.name).to eq('refund_order')
    expect(tool.description).to eq('Refund part or all of an order')
    expect(tool.parameters_schema['required']).to eq(%w[order_id amount])
  end

  it 'runs the action through RubyLLM, with the user it was built with' do
    result = tool.call(order_id: 'o1', amount: '12.50')

    expect(result.slice('status', 'code')).to eq('status' => 'success', 'code' => 'success')
    expect(ToolSpecs.refunds.last[:user_id]).to eq(7)
  end

  it 'hands a failure back to the model rather than raising' do
    expect(tool.call(order_id: 'o1', amount: '200.0')['code']).to eq('over_limit')
  end

  it 'asks for approval when told to' do
    approved = described_class.tool(ToolSpecs::RefundOrder, description: 'x', approval: true)

    expect(approved.requires_approval?).to be(true)
    expect(tool_class.requires_approval?).to be(false)
  end
end
