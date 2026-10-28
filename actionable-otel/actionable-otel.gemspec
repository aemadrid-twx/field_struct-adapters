# frozen_string_literal: true

require_relative 'lib/actionable/otel/version'

Gem::Specification.new do |spec|
  spec.name = 'actionable-otel'
  spec.version = Actionable::Otel::VERSION
  spec.authors = ['Adrian Madrid']
  spec.email = ['amadrid@pmtbox.com']

  spec.summary = 'OpenTelemetry spans for actionable action runs, steps and hooks.'
  spec.description = <<~DESC
    Traces every actionable action run as an OpenTelemetry span, with a child
    span per executed step and lifecycle hook, the outcome and result code as
    attributes, and declared failures marked as errors. Input and output
    values are never recorded.
  DESC
  spec.homepage = 'https://github.com/aemadrid-twx/field_struct-adapters/tree/main/actionable-otel'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.3.0'

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = 'https://github.com/aemadrid-twx/field_struct-adapters/blob/main/actionable-otel/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb'] + %w[README.md CHANGELOG.md]
  spec.require_paths = ['lib']

  # The adapter prepends onto Actionable::Action.run and the runner's
  # per-step hook, which is internal: a 2.0 may move it.
  spec.add_dependency 'actionable-rb', '>= 1.9', '< 2'
  # 1.7 added Tracer#in_span's record_exception: option, which the adapter
  # uses to record an escaping exception once, on the run span.
  spec.add_dependency 'opentelemetry-api', '~> 1.7'
end
