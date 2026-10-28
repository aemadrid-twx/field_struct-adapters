# frozen_string_literal: true

require_relative 'lib/field_struct/json_schema/version'

Gem::Specification.new do |spec|
  spec.name = 'field_struct-json_schema'
  spec.version = FieldStruct::JSONSchema::VERSION
  spec.authors = ['Adrian Madrid']
  spec.email = ['amadrid@pmtbox.com']

  spec.summary = 'JSON Schema (draft 2020-12) for FieldStruct classes.'
  spec.description = <<~DESC
    Generates the JSON Schema of the JSON a FieldStruct class writes and reads,
    for API docs, validators in other languages, LLM tool parameters and
    TypeScript types, with Ruby format: Regexps translated to ECMA-262 patterns
    that match exactly the same strings, or left out.
  DESC
  spec.homepage = 'https://github.com/aemadrid-twx/field_struct-adapters/tree/main/field_struct-json_schema'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.3.0'

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = 'https://github.com/aemadrid-twx/field_struct-adapters/blob/main/field_struct-json_schema/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb'] + %w[README.md CHANGELOG.md]
  spec.require_paths = ['lib']

  # Introspection, the walk this gem is built on, is on develop (still 0.16.0)
  # and lands in the next release; raise this floor to that release then.
  # lib/field_struct/json_schema.rb raises a clear LoadError until it's there.
  spec.add_dependency 'field_struct', '>= 0.16'
end
