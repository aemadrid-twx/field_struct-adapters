# actionable-tools

Let an LLM call your [actionable](https://github.com/aemadrid-twx/actionable) actions as tools, over [MCP](https://github.com/modelcontextprotocol/ruby-sdk) or through [RubyLLM](https://rubyllm.com). The action you already wrote, with its typed input, validations and declared failures, becomes the tool. You add a description and say which input fields your server fills in.

> **Status: 0.1.0, unreleased draft.** Install it from git for now:
>
> ```ruby
> gem 'actionable-tools', git: 'https://github.com/aemadrid-twx/field_struct-adapters', glob: 'actionable-tools/*.gemspec'
> gem 'field_struct-json_schema', git: 'https://github.com/aemadrid-twx/field_struct-adapters', glob: 'field_struct-json_schema/*.gemspec'
> gem 'field_struct', git: 'https://github.com/aemadrid-twx/field_struct', branch: 'develop'
> ```

It works with actionable-rb 1.9 and later 1.x, and builds its schemas with [field_struct-json_schema](../field_struct-json_schema). It doesn't depend on `mcp` or `ruby_llm`: add the one you use.

## An action as an MCP tool

```ruby
class RefundOrder < Actionable::Action
  input do
    required :order_id, :string, description: 'The order to refund'
    required :amount,   :big_decimal, in: 0.01..500
    optional :reason,   :string, enum: %w[damaged late]
    required :user_id,  :integer
  end

  output do
    required :refund_id, :string
  end

  fails :over_limit, kind: :rejected
  skips :already_refunded

  step :refund
  # ...
end
```

```ruby
require 'actionable/tools/mcp'

tool = Actionable::Tools::MCP.tool(RefundOrder,
  description: 'Refund part or all of an order. Refunds over 100 fail with over_limit.',
  context: {user_id: ->(server_context) { server_context[:user_id] }},
  annotations: {destructive: true, idempotent: false})

server = MCP::Server.new(name: 'shop', tools: [tool], server_context: {user_id: current_user.id})
```

What the client sees in `tools/list`:

- **`name`:** `refund_order`, from the class name. Pass `name:` to choose another.
- **`inputSchema`:** the JSON Schema of `RefundOrder.input` without `user_id`. A field listed in `context:` comes from your server, never from the model. If the model sends one anyway, it's ignored.
- **`outputSchema`:** the result shape below. On success, `output` follows `RefundOrder.output`.
- **`annotations`:** `destructiveHint: true`, `idempotentHint: false`. The keys are `read_only:`, `destructive:`, `idempotent:` and `open_world:`.

A call runs `RefundOrder.run` with the model's arguments plus `user_id`, so the action coerces and validates them as it always does.

## One result shape for every outcome

Every call returns the same six keys, so the model can branch on `status` and `code` without checking which keys exist:

```ruby
{"status" => "success", "code" => "success", "message" => nil,
 "output" => {"refund_id" => "rf_o1"}, "errors" => {}, "metadata" => {}}

{"status" => "failure", "code" => "over_limit", "message" => "refunds over 100 need a person",
 "output" => {"refund_id" => nil}, "errors" => {}, "metadata" => {"kind" => "rejected"}}

{"status" => "failure", "code" => "invalid_input", "message" => "input failed validation",
 "output" => {"refund_id" => nil}, "errors" => {"amount" => ["is invalid"]}, "metadata" => {}}

{"status" => "skipped", "code" => "already_refunded", "message" => nil,
 "output" => {"refund_id" => nil}, "errors" => {}, "metadata" => {}}
```

Over MCP, the result is the tool call's `structuredContent`, and the same JSON goes in `content` as text for clients that read only text. A failure sets `isError`. A skip doesn't: the action decided there was nothing to do, which isn't an error. The `code` description in `outputSchema` lists the action's declared failures and skips, so the model knows them up front.

An exception the action raises isn't a result: it propagates, and the MCP server reports it as an internal error.

## RubyLLM

```ruby
require 'actionable/tools/ruby_llm'

RefundTool = Actionable::Tools::RubyLLM.tool(RefundOrder,
  description: 'Refund part or all of an order',
  context: {user_id: ->(user) { user.id }},
  approval: true)

chat = RubyLLM.chat.with_tool(RefundTool.new(current_user))
```

The context procs read whatever you build the tool with, here the current user. `approval: true` sets RubyLLM's `requires_approval`, which pauses each call until you approve it. The model gets the same result Hash as above.

## Anything else

`Actionable::Tools.definition` takes the same keywords and returns the form-neutral description the two adapters wrap: `name`, `description`, `input_schema`, `output_schema`, `annotations`, and `call(arguments, source)`, which returns the result Hash. Use it for another client library or a hand-rolled tool loop.

## Choosing what to expose

There's no "every action" option. An action you call from your own code trusts its caller; a tool is called by a model that a user can talk into things. Expose the actions you've thought about, put identity and tenancy in `context:`, and mark destructive ones so clients can ask before calling them.

## Trying it

`examples/stdio_server.rb` is a complete MCP server over stdio. Point the MCP Inspector at it:

```sh
cd actionable-tools
npx @modelcontextprotocol/inspector bundle exec ruby examples/stdio_server.rb
```

## Limits

- **The input needs a schema.** An action without `input do ... end` can't be a tool, and neither can one with a discriminated input (`input_for`), which has no single schema to describe.
- **Arguments are JSON.** A `:big_decimal` is a string in the schema (`"12.50"`), because that's what its JSON is, so a model that sends `12.5` gets `Invalid arguments: value at /amount is not a string` from MCP's argument check, before the action runs. Ranges (`in:`) aren't in the schema; the action still enforces them. See field_struct-json_schema's README for what JSON Schema can and can't say.
- **No description from the action yet.** Actions have no `description` macro, so `description:` is required here.
