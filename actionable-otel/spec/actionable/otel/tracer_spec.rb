# frozen_string_literal: true

# Which tracer the spans come from when the provider changes after load.
RSpec.describe Actionable::Otel do
  around do |example|
    original = OpenTelemetry.tracer_provider
    example.run
  ensure
    OpenTelemetry.tracer_provider = original
    # Drop a stub's tracer, so a broken cache fails only here.
    described_class.instance_variable_set(:@tracer, nil)
  end

  it 'follows a provider installed later' do
    stub_const('Ping', Class.new(Actionable::Action) do
      step :pong
      def pong = nil
    end)
    Ping.run
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    OpenTelemetry.tracer_provider = provider

    Ping.run

    expect(exporter.finished_spans.map(&:name)).to include('Ping.run')
  end

  it "never hands out a replaced provider's tracer while the new one is being made" do
    old_tracer = Object.new
    new_tracer = Object.new
    OpenTelemetry.tracer_provider = Struct.new(:made).new(old_tracer).tap do |provider|
      def provider.tracer(**) = made
    end
    described_class.send(:tracer)

    entered = Queue.new
    release = Queue.new
    slow = Struct.new(:made, :calls).new(new_tracer, 0)
    def slow.tracer(**)
      self.calls += 1
      yield_control if calls == 1
      made
    end
    slow.define_singleton_method(:yield_control) do
      entered << true
      release.pop(timeout: 5)
    end
    OpenTelemetry.tracer_provider = slow

    first = Thread.new { described_class.send(:tracer) }
    # Bounded waits, so a tracer that never asks the new provider fails
    # instead of hanging.
    expect(entered.pop(timeout: 5)).to be(true)
    concurrent = described_class.send(:tracer)
    release << true

    expect([concurrent, first.join(5)&.value]).to eq([new_tracer, new_tracer])
  end
end
