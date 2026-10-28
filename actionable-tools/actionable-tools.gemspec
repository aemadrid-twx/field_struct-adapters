# frozen_string_literal: true

require_relative 'lib/actionable/tools/version'

Gem::Specification.new do |spec|
  spec.name = 'actionable-tools'
  spec.version = Actionable::Tools::VERSION
  spec.authors = ['Adrian Madrid']
  spec.email = ['amadrid@pmtbox.com']

  spec.summary = 'Expose actionable actions as LLM tools: MCP and RubyLLM.'
  spec.description = <<~DESC
    Turns an actionable action you name into a tool an LLM can call: a name,
    a description, a JSON Schema of its input (leaving out the fields your
    server supplies, like the current user) and of its result, and a call that
    runs the action and reports success, a declared failure or a skip in one
    stable shape. Ships adapters for the MCP Ruby SDK and RubyLLM.
  DESC
  spec.homepage = 'https://github.com/aemadrid-twx/field_struct-adapters/tree/main/actionable-tools'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.3.0'

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = 'https://github.com/aemadrid-twx/field_struct-adapters/blob/main/actionable-tools/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb', 'sig/**/*.rbs'] + %w[README.md CHANGELOG.md]
  spec.require_paths = ['lib']

  # Reads .input_schema, .output_schema and runs the action; Failure and
  # Skipped carry metadata since 1.9.
  spec.add_dependency 'actionable-rb', '>= 1.9', '< 2'
  # The input and output schemas.
  spec.add_dependency 'field_struct-json_schema', '~> 0.1'
  # mcp and ruby_llm are not dependencies: each is needed only by its own
  # require ('actionable/tools/mcp', 'actionable/tools/ruby_llm').
end
