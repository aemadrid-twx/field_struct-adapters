# frozen_string_literal: true

# opentelemetry-api used to be a soft dependency of actionable-rb, checked at
# require time; as its own gem the adapter declares it, so a Gemfile with
# actionable-otel always resolves it.
RSpec.describe 'actionable-otel.gemspec' do
  let(:spec) { Gem::Specification.load(File.expand_path('../../../actionable-otel.gemspec', __dir__)) }

  def runtime(name) = spec.runtime_dependencies.find { |dependency| dependency.name == name }

  it 'depends on opentelemetry-api, from the release with in_span(record_exception:)' do
    dependency = runtime('opentelemetry-api')

    expect(dependency.requirement).to eq(Gem::Requirement.new('~> 1.7'))
    expect(dependency.match?('opentelemetry-api', '1.6.0')).to be(false)
  end

  it 'depends on actionable-rb 1.x' do
    expect(runtime('actionable-rb').requirement).to eq(Gem::Requirement.new('>= 1.9', '< 2'))
  end

  it 'does not depend on the SDK, which the application chooses' do
    expect(runtime('opentelemetry-sdk')).to be_nil
  end
end
