# frozen_string_literal: true

require 'actionable/tools/mcp'

RSpec.describe Actionable::Tools::MCP do
  let(:tool) do
    described_class.tool(ToolSpecs::RefundOrder,
      description: 'Refund part or all of an order',
      context: {user_id: ->(server_context) { server_context[:user_id] }},
      annotations: {destructive: true, idempotent: false})
  end

  # A real server, as a client reaches it over JSON-RPC, checking results
  # against the output schema too (off by default in the SDK).
  let(:server) do
    configuration = MCP::Configuration.new(validate_tool_call_results: true)
    MCP::Server.new(name: 'shop', tools: [tool], server_context: {user_id: 7}, configuration: configuration)
  end

  before { ToolSpecs.refunds.clear }

  def rpc(method, params = {})
    server.handle({jsonrpc: '2.0', id: 1, method: method, params: params})
  end

  def call(arguments)
    rpc('tools/call', {name: 'refund_order', arguments: arguments})
  end

  it 'lists the tool with its schemas and hints' do
    listed = rpc('tools/list')[:result][:tools].first

    expect(listed.slice(:name, :description)).to eq(name: 'refund_order', description: 'Refund part or all of an order')
    expect(listed[:inputSchema][:required]).to eq(%w[order_id amount])
    expect(listed[:outputSchema][:required]).to eq(Actionable::Tools::RESULT_KEYS)
    expect(listed[:annotations]).to include(destructiveHint: true, idempotentHint: false)
  end

  it 'runs the action with the server context' do
    result = call(order_id: 'o1', amount: '12.50')[:result]

    expect(result[:isError]).to be(false)
    expect(result[:structuredContent]['output']['refund_id']).to eq('rf_o1')
    expect(JSON.parse(result[:content].first[:text])).to eq(result[:structuredContent])
    expect(ToolSpecs.refunds.last[:user_id]).to eq(7)
  end

  it 'marks a declared failure as an error result' do
    result = call(order_id: 'o1', amount: '200.0')[:result]

    expect(result[:isError]).to be(true)
    expect(result[:structuredContent].slice('code', 'message'))
      .to eq('code' => 'over_limit', 'message' => 'refunds over 100 need a person')
  end

  it 'passes a skip, which the output schema accepts' do
    result = call(order_id: 'dup', amount: '1.0')[:result]

    expect(result[:isError]).to be(false)
    expect(result[:structuredContent]['code']).to eq('already_refunded')
  end

  it 'lets the SDK reject arguments the input schema forbids, before the action runs' do
    result = call(order_id: 'o1', amount: 12.5)[:result]

    expect(result[:isError]).to be(true)
    expect(ToolSpecs.refunds).to be_empty
  end

  it 'refuses an annotation MCP has no hint for' do
    expect { described_class.tool(ToolSpecs::Ping, description: 'x', annotations: {safe: true}) }
      .to raise_error(ArgumentError, /unknown annotations: safe/)
  end
end
