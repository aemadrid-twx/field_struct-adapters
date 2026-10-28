# frozen_string_literal: true

require_relative 'lib/field_struct/protobuf/version'

Gem::Specification.new do |spec|
  spec.name = 'field_struct-protobuf'
  spec.version = FieldStruct::Protobuf::VERSION
  spec.authors = ['Adrian Madrid']
  spec.email = ['amadrid@pmtbox.com']

  spec.summary = 'Protocol Buffers messages for FieldStruct classes: .proto files, message classes and binary.'
  spec.description = <<~DESC
    Builds a Protocol Buffers message for a FieldStruct class at runtime, with
    no protoc step: the .proto text to share with other teams, a message class
    registered with google-protobuf, and instances to and from protobuf binary.
    Field numbers are declared on each field, never inferred.
  DESC
  spec.homepage = 'https://github.com/aemadrid-twx/field_struct-adapters/tree/main/field_struct-protobuf'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.3.0'

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = 'https://github.com/aemadrid-twx/field_struct-adapters/blob/main/field_struct-protobuf/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb'] + %w[README.md CHANGELOG.md]
  spec.require_paths = ['lib']

  spec.add_dependency 'bigdecimal', '>= 3.1'
  # Introspection, the walk this gem is built on, is on develop (still 0.16.0)
  # and lands in the next release; raise this floor to that release then.
  # lib/field_struct/protobuf.rb raises a clear LoadError until it's there.
  spec.add_dependency 'field_struct', '>= 0.16'
  # DescriptorPool#add_serialized_file and proto3 optional fields.
  spec.add_dependency 'google-protobuf', '~> 4.30'
end
