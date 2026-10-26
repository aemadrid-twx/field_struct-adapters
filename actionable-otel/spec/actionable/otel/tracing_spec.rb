# frozen_string_literal: true

otel_loaded =
  begin
    require 'opentelemetry/sdk'
    true
  rescue LoadError
    false
  end

if otel_loaded
  require 'logger'
  require 'actionable/otel'
  require 'actionable/rspec'

  # One process-wide SDK with an in-memory exporter; each example resets it.
  ENV['OTEL_TRACES_EXPORTER'] = 'none'
  OTEL_SPEC_EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
  OpenTelemetry::SDK.configure do |config|
    config.logger = Logger.new(IO::NULL)
    config.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(OTEL_SPEC_EXPORTER))
  end
end

# The OpenTelemetry adapter against the real SDK. Runs with
# gemfiles/otel.gemfile (the `otel` CI lane); skipped in the default suite,
# which instead checks the missing-gem error (missing_gem_spec.rb).
RSpec.describe 'Actionable::Otel',
  skip: (otel_loaded ? false : 'opentelemetry not installed (BUNDLE_GEMFILE=gemfiles/otel.gemfile)') do
  before { OTEL_SPEC_EXPORTER.reset }

  after { Actionable::Otel.step_spans = true }

  let(:spans) { OTEL_SPEC_EXPORTER.finished_spans }

  def span_named(name)
    found = spans.select { |span| span.name == name }
    raise "expected one span named #{name.inspect}, got #{spans.map(&:name).inspect}" unless found.one?

    found.first
  end

  def error?(span) = span.status.code == OpenTelemetry::Trace::Status::ERROR

  describe 'the run span' do
    before do
      stub_const('Charge', Class.new(Actionable::Action) do
        step :authorize
        def authorize = nil
      end)
    end

    it 'emits one span per run, named after the action, with the outcome and code' do
      Charge.run
      span = span_named('Charge.run')

      expect(span.attributes).to include('actionable.action' => 'Charge', 'actionable.outcome' => 'success',
        'actionable.code' => 'success')
      expect(span.kind).to eq(:internal)
      expect(error?(span)).to be(false)
    end

    it "comes from the 'actionable' tracer at the gem's version" do
      Charge.run

      scope = span_named('Charge.run').instrumentation_scope
      expect([scope.name, scope.version]).to eq(['actionable', Actionable::VERSION])
    end

    it 'emits a span per item of run_each' do
      Charge.run_each([{}, {}])

      expect(spans.map(&:name).count('Charge.run')).to eq(2)
    end

    it 'leaves the result and its history untouched' do
      Charge.measure :all
      result = Charge.run

      expect(result).to be_success
      expect(result.history.steps.map(&:name)).to eq([:authorize])
    end
  end

  describe 'outcomes' do
    it 'marks a failure as an error carrying the code, without an exception event' do
      stub_const('Refuse', Class.new(Actionable::Action) do
        step :go
        def go = fail!(:card_declined, 'declined')
      end)
      Refuse.run
      span = span_named('Refuse.run')

      expect(span.attributes).to include('actionable.outcome' => 'failure', 'actionable.code' => 'card_declined')
      expect(error?(span)).to be(true)
      expect(span.status.description).to eq('card_declined')
      expect(span.events.to_a).to be_empty
    end

    it 'does not mark a skip as an error' do
      stub_const('Idle', Class.new(Actionable::Action) do
        step :go
        def go = skip!(:nothing_to_do)
      end)
      Idle.run
      span = span_named('Idle.run')

      expect(span.attributes).to include('actionable.outcome' => 'skipped', 'actionable.code' => 'nothing_to_do')
      expect(error?(span)).to be(false)
    end

    it 'traces an invalid-input run, which never reaches the steps' do
      stub_const('Typed', Class.new(Actionable::Action) do
        input { required :amount, :integer }
        step :go
        def go = nil
      end)
      Typed.run

      expect(span_named('Typed.run').attributes).to include('actionable.code' => 'invalid_input')
      expect(spans.map(&:name)).to eq(['Typed.run'])
    end

    it 'records an escaping exception on both spans and re-raises it' do
      stub_const('Boom', Class.new(Actionable::Action) do
        step :go
        def go = raise(ArgumentError, 'bad')
      end)

      expect { Boom.run }.to raise_error(ArgumentError, 'bad')
      %w[Boom.run Boom/go].each do |name|
        span = span_named(name)
        expect(error?(span)).to be(true)
        expect(span.events.map(&:name)).to eq(['exception'])
      end
      expect(span_named('Boom.run').attributes).not_to have_key('actionable.outcome')
    end
  end

  describe 'step spans' do
    before do
      stub_const('Checkout', Class.new(Actionable::Action) do
        step :reserve
        step :never, if: :never?
        step :charge
        on_success :notify
        always :audit

        def reserve = nil
        def never = nil
        def never? = false
        def charge = succeed('charged')
        def notify = nil
        def audit = nil
      end)
    end

    it 'emits a child span per executed step and hook, under the run span' do
      Checkout.run
      run = span_named('Checkout.run')
      children = spans.select { |span| span.parent_span_id == run.span_id }

      expect(children.map(&:name)).to eq(%w[Checkout/reserve Checkout/charge Checkout/notify Checkout/audit])
      expect(children.map { |span| span.attributes['actionable.section'] }).to eq(%w[main main success always])
      expect(children.map { |span| span.attributes['actionable.step'] }).to eq(%w[reserve charge notify audit])
      expect(children.map { |span| span.attributes['actionable.action'] }.uniq).to eq(['Checkout'])
    end

    it 'puts the code on a step span only when that step recorded the result' do
      Checkout.run

      expect(span_named('Checkout/charge').attributes).to include('actionable.code' => 'success')
      expect(span_named('Checkout/reserve').attributes).not_to have_key('actionable.code')
    end

    it 'records the code of a step that halts' do
      stub_const('Halting', Class.new(Actionable::Action) do
        step :go
        step :after
        def go = fail!(:stop)
        def after = nil
      end)
      Halting.run

      expect(span_named('Halting/go').attributes).to include('actionable.code' => 'stop')
      expect(error?(span_named('Halting/go'))).to be(false)
      expect(spans.map(&:name)).not_to include('Halting/after')
    end

    it 'emits only the run span when step_spans is off' do
      Actionable::Otel.step_spans = false
      Checkout.run

      expect(spans.map(&:name)).to eq(['Checkout.run'])
    end

    it 'reads the setting back' do
      expect(Actionable::Otel.step_spans?).to be(true)
      expect(Actionable::Otel.step_spans = nil).to be_nil
      expect(Actionable::Otel.step_spans?).to be(false)
    end
  end

  it "nests a child action's run span under the parent's step span" do
    stub_const('Child', Class.new(Actionable::Action) do
      step :work
      def work = nil
    end)
    stub_const('Parent', Class.new(Actionable::Action) do
      step Child
    end)
    Parent.run
    step = span_named('Parent/Child')

    expect(step.parent_span_id).to eq(span_named('Parent.run').span_id)
    expect(span_named('Child.run').parent_span_id).to eq(step.span_id)
    expect(span_named('Child/work').parent_span_id).to eq(span_named('Child.run').span_id)
    expect(spans.map(&:trace_id).uniq.size).to eq(1)
  end

  it 'never records input or output values' do
    stub_const('Pay', Class.new(Actionable::Action) do
      input { required :card_number, :string }
      output { required :token, :string }
      step :tokenize
      def tokenize = @token = "tok-#{input.card_number}"
    end)
    Pay.run(card_number: '4111111111111111')
    values = spans.flat_map { |span| span.attributes.values }

    expect(values.grep(/4111/)).to be_empty
  end

  context 'with a stubbed run' do
    include Actionable::RSpec::Stubs

    it 'emits no span' do
      stub_const('Stubbed', Class.new(Actionable::Action) { step(:go) && define_method(:go) { nil } })
      stub_actionable_success Stubbed

      expect(Stubbed.run).to be_success
      expect(spans).to be_empty
    end
  end

  it 'names an anonymous action generically' do
    Class.new(Actionable::Action) { step(:go) && define_method(:go) { nil } }.run

    expect(spans.map(&:name)).to contain_exactly('Actionable::Action.run', 'Actionable::Action/go')
    expect(span_named('Actionable::Action.run').attributes['actionable.action']).to eq('Actionable::Action')
  end
end
