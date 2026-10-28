# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'

# The example server, driven over stdio the way an MCP client drives it.
RSpec.describe 'examples/stdio_server.rb' do
  let(:server) { File.expand_path('../../../examples/stdio_server.rb', __dir__) }

  def session(*requests)
    messages = [
      {jsonrpc: '2.0', id: 0, method: 'initialize',
       params: {protocolVersion: '2025-06-18', capabilities: {}, clientInfo: {name: 'spec', version: '0'}}},
      {jsonrpc: '2.0', method: 'notifications/initialized'},
      *requests.each_with_index.map { |(method, params), index| {jsonrpc: '2.0', id: index + 1, method: method, params: params} }
    ]
    out, err, status = Open3.capture3(RbConfig.ruby, server, stdin_data: messages.map { |m| "#{JSON.generate(m)}\n" }.join)
    raise "server failed: #{err}" unless status.success?

    out.lines.map { |line| JSON.parse(line) }.select { |reply| reply['id']&.positive? }.sort_by { |reply| reply['id'] }
  end

  it 'lists the tool and runs it, success and declared failure' do
    listed, refunded, refused = session(['tools/list', {}],
      ['tools/call', {name: 'refund_order', arguments: {order_id: 'o1', amount: '12.50'}}],
      ['tools/call', {name: 'refund_order', arguments: {order_id: 'o1', amount: '200.0'}}])

    expect(listed.dig('result', 'tools', 0, 'name')).to eq('refund_order')
    expect(refunded.dig('result', 'structuredContent', 'output', 'refund_id')).to eq('rf_o1')
    expect(refused.dig('result', 'isError')).to be(true)
    expect(refused.dig('result', 'structuredContent', 'code')).to eq('over_limit')
  end
end
