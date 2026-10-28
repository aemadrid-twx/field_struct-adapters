# frozen_string_literal: true

otel_available =
  begin
    require 'opentelemetry'
    true
  rescue LoadError
    false
  end

# opentelemetry-api is a soft dependency: without it, the adapter refuses to
# load with a sentence saying what to add. Only checkable where the gem is
# absent, i.e. the default suite.
RSpec.describe 'require "actionable/otel" without opentelemetry-api',
  skip: (otel_available ? 'opentelemetry-api is installed in this bundle' : false) do
  it 'raises a LoadError that says which gem to add' do
    expect { require 'actionable/otel' }.to raise_error(LoadError) { |error|
      expect(error.message).to start_with('actionable/otel needs the opentelemetry-api gem')
      expect(error.message).to include("gem 'opentelemetry-api'")
    }
  end
end
