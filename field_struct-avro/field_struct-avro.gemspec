# frozen_string_literal: true

require_relative 'lib/field_struct/avro/version'

Gem::Specification.new do |spec|
  spec.name = 'field_struct-avro'
  spec.version = FieldStruct::Avro::VERSION
  spec.authors = ['Adrian Madrid']
  spec.email = ['amadrid@pmtbox.com']

  spec.summary = 'Apache Avro schemas and binary datums for FieldStruct classes.'
  spec.description = <<~DESC
    Generates an Avro record schema from a FieldStruct class and converts
    instances to and from Avro datums and binary, without losing decimals,
    64-bit integers, sub-millisecond times or enum symbols on the way.
  DESC
  spec.homepage = 'https://github.com/aemadrid-twx/field_struct-adapters/tree/main/field_struct-avro'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.3.0'

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = 'https://github.com/aemadrid-twx/field_struct-adapters/blob/main/field_struct-avro/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb', 'sig/**/*.rbs'] + %w[README.md CHANGELOG.md]
  spec.require_paths = ['lib']

  spec.add_dependency 'avro', '~> 1.12'
  # avro needs bigdecimal but doesn't declare it, and Ruby 3.4 unbundled it.
  spec.add_dependency 'bigdecimal', '>= 3.1'
  # Introspection, the walk this gem is built on, is on develop (still 0.16.0)
  # and lands in the next release; raise this floor to that release then.
  # lib/field_struct/avro.rb raises a clear LoadError until it's there.
  spec.add_dependency 'field_struct', '>= 0.16'
end
