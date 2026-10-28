# frozen_string_literal: true

require 'open3'
require 'rbconfig'

# Rules that the rest of the suite left unpinned (a mutation-testing pass found
# each one survived a change to the code).
RSpec.describe Actionable::Otel, 'edge cases' do
  before { OTEL_SPEC_EXPORTER.reset }

  let(:spans) { OTEL_SPEC_EXPORTER.finished_spans }

  def span_named(name)
    found = spans.select { |span| span.name == name }
    raise "expected one span named #{name.inspect}, got #{spans.map(&:name).inspect}" unless found.one?

    found.first
  end

  it 'records an escaping exception that is not a StandardError too, then re-raises it' do
    failure = Class.new(Exception) # rubocop:disable Lint/InheritException -- the point: not a StandardError
    stub_const('Abort', Class.new(Actionable::Action) do
      step :go
      define_method(:go) { raise failure }
    end)

    expect { Abort.run }.to raise_error(failure)
    expect(span_named('Abort.run').events.map { |event| [event.name, event.attributes] })
      .to eq([['exception', {'exception.type' => failure.to_s}]])
  end

  it 'names a step that runs an anonymous action generically' do
    child = Class.new(Actionable::Action) { step(:go) && define_method(:go) { nil } }
    stub_const('Parent', Class.new(Actionable::Action) { step child })
    Parent.run

    expect(spans.map(&:name)).to include('Parent/Actionable::Action')
  end

  it 'repeats no code on a hook that leaves the result alone' do
    stub_const('Checkout', Class.new(Actionable::Action) do
      step :charge
      on_success :notify
      def charge = succeed('charged')
      def notify = nil
    end)
    Checkout.run

    expect(span_named('Checkout/charge').attributes).to include('actionable.code' => 'success')
    expect(span_named('Checkout/notify').attributes).not_to have_key('actionable.code')
  end

  it 'defaults to step spans on and type-only exception details, in a fresh process' do
    script = 'require "actionable/otel"; print [Actionable::Otel.step_spans?, Actionable::Otel.exception_details].inspect'
    out, status = Open3.capture2(RbConfig.ruby, '-e', script)

    expect([status.success?, out]).to eq([true, '[true, :type_only]'])
  end
end
