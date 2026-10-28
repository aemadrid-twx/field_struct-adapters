# frozen_string_literal: true

# A complete MCP server over stdio exposing one action, for MCP Inspector or a
# desktop client:
#
#   npx @modelcontextprotocol/inspector bundle exec ruby examples/stdio_server.rb
#
# The spec in spec/actionable/tools/stdio_spec.rb drives it as a client would.
require 'actionable/tools/mcp'
require_relative '../spec/support/actions'

tool = Actionable::Tools::MCP.tool(
  ToolSpecs::RefundOrder,
  description: 'Refund part or all of an order. Refunds over 100 fail with over_limit.',
  # In a real app, the user comes from the session the transport authenticated.
  context: {user_id: ->(_server_context) { 7 }},
  annotations: {destructive: true, idempotent: false}
)

server = MCP::Server.new(name: 'shop', version: '0.1.0', tools: [tool])
MCP::Server::Transports::StdioTransport.new(server).open
