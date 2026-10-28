# Changelog

## [Unreleased]

### Added

- `Actionable::Tools.definition`: an actionable action described as an LLM tool. You get a name, a description, the JSON Schema of its input (without the fields listed in `context:`, which your server supplies) and of its result, and `call`, which runs the action and returns one six-key result Hash for success, failure and skip alike.
- `require 'actionable/tools/mcp'`: `Actionable::Tools::MCP.tool` turns an action into an `MCP::Tool` for the MCP Ruby SDK (`mcp` 1.8). A failure sets `isError`, a skip doesn't, and `annotations:` maps to MCP's hints.
- `require 'actionable/tools/ruby_llm'`: `Actionable::Tools::RubyLLM.tool` turns an action into a `RubyLLM::Tool` class (`ruby_llm` 2.1), with `approval:` for `requires_approval`.
