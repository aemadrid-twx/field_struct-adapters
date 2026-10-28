# frozen_string_literal: true

require 'logger'
require 'opentelemetry/sdk'
require 'actionable/otel'
require 'actionable/rspec'

# One process-wide SDK with an in-memory exporter; each example resets it.
ENV['OTEL_TRACES_EXPORTER'] = 'none'
OTEL_SPEC_EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
OpenTelemetry::SDK.configure do |config|
  config.logger = Logger.new(IO::NULL)
  config.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(OTEL_SPEC_EXPORTER))
end

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
