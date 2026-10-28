# frozen_string_literal: true

# OpenTelemetry adapter for actionable. Load it explicitly with
# `require 'actionable/otel'`; requiring it is what wires the spans in, so
# nothing touches OpenTelemetry until you opt in. This gem depends on
# opentelemetry-api only: add opentelemetry-sdk and an exporter to your own
# Gemfile to send the spans anywhere.
require 'actionable'
require 'opentelemetry'
require_relative 'otel/version'

module Actionable
  # Traces every action run as an OpenTelemetry span, with a child span per
  # executed step and lifecycle hook.
  #
  # A run's span is named after the action (+Charge.run+) and carries
  # +actionable.action+, +actionable.outcome+ (+success+ / +failure+ /
  # +skipped+) and +actionable.code+. A failure sets the span's status to
  # error with the code as its description; a skip is not an error. An
  # exception that escapes the run is recorded once, on the run span, and
  # re-raised (see {.exception_details=}). A
  # step's span (+Charge/authorize+) carries +actionable.action+,
  # +actionable.step+, +actionable.section+ (+main+, +success+, +failure+,
  # +skip+ or +always+) and, when that step recorded the result,
  # +actionable.code+. A nested action's run span nests under the parent's
  # step span, when it runs on the same thread and fiber (OpenTelemetry's
  # context is per fiber). +actionable.step.kind+ says whether a step is a
  # +method+, an +action+ or a +case+; a case step's span is named after its
  # value method, and the branch it picked runs inside it without a span.
  #
  # Input and output values are never recorded: they are often sensitive
  # (card numbers, tokens, personal data). An escaping exception's message
  # and backtrace can hold them too, so by default only its class is
  # recorded. Spans follow OpenTelemetry's own sampling, not +measure+, which
  # only governs {History}.
  module Otel
    # The instrumentation scope name the tracer is obtained under.
    # @return [String]
    TRACER_NAME = 'actionable'

    # Values {.exception_details=} accepts.
    # @return [Array<Symbol>]
    EXCEPTION_DETAILS = %i[type_only full].freeze

    @step_spans = true
    @exception_details = :type_only

    class << self
      # How much of an exception that escapes a run goes on the run span.
      # +:type_only+ (the default) adds an +exception+ event with only
      # +exception.type+, because a message or backtrace can carry input
      # values (+"card 4111… declined"+). +:full+ uses OpenTelemetry's
      # +record_exception+: type, message and backtrace.
      #
      #   Actionable::Otel.exception_details = :full
      #
      # @param level [Symbol] +:type_only+ or +:full+
      # @return [Symbol] the level now in effect
      # @raise [ArgumentError] for any other value
      def exception_details=(level)
        unless EXCEPTION_DETAILS.include?(level)
          raise ArgumentError, "Actionable::Otel.exception_details must be #{EXCEPTION_DETAILS.map(&:inspect).join(" or ")}, " \
                               "got #{level.inspect}"
        end

        @exception_details = level
      end

      # @return [Symbol] +:type_only+ or +:full+; see {.exception_details=}
      attr_reader :exception_details

      # Turn the per-step spans on or off for the whole process. Off, each run
      # emits only its own span. On by default.
      #
      #   Actionable::Otel.step_spans = false
      #
      # @param enabled [Boolean, nil] +false+ (or +nil+) to emit run spans only
      # @return [Boolean, nil] +enabled+, as Ruby returns from any setter;
      #   {.step_spans?} reads the setting back
      def step_spans=(enabled)
        @step_spans = enabled ? true : false
      end

      # Whether each executed step and hook gets its own span.
      #
      # @return [Boolean]
      def step_spans?
        @step_spans
      end

      # Run the block inside the span for one run of +action+, then record the
      # result's outcome and code on it. Called by {ActionRun}.
      #
      # @api private
      # @param action [Class<Actionable::Action>] the action being run
      # @yieldreturn [Actionable::Result] the run's result
      # @return [Actionable::Result] the block's result
      def trace_run(action)
        label = label_for(action)
        attributes = {'actionable.action' => label}
        tracer.in_span("#{label}.run", attributes: attributes, kind: :internal, record_exception: false) do |span|
          result = yield
          annotate_run(span, result)
          result
        rescue Exception => e # rubocop:disable Lint/RescueException -- recorded, then re-raised as is
          record_exception(span, e)
          raise
        end
      end

      # Run the block inside the span for one step or hook of +instance+'s run,
      # recording the step's code when it changed the result (even when it
      # halted). Called by {RunnerSteps}.
      #
      # @api private
      # @param instance [Actionable::Action] the running action instance
      # @param section [Symbol] where the step runs: +:main+ or a hook phase
      # @param step [Actionable::Steps::Base] the step
      # @yieldreturn [Object]
      # @return [Object] the block's value
      def trace_step(instance, section, step, &block)
        label = label_for(instance.class)
        name = step.name.is_a?(Class) ? label_for(step.name) : step.name.to_s
        attributes = {'actionable.action' => label, 'actionable.step' => name,
                      'actionable.step.kind' => step.kind.to_s, 'actionable.section' => section.to_s}
        # The exception is recorded once, on the run span; a step span only
        # gets the error status OpenTelemetry sets as it passes through.
        tracer.in_span("#{label}/#{name}", attributes: attributes, kind: :internal, record_exception: false) do |span|
          traced_step(instance, span, &block)
        end
      end

      private

      # The tracer for the current provider, so a provider installed after
      # this file loads still applies. Cached per provider: asking the SDK
      # takes a mutex and allocates on every call. The provider and its
      # tracer are one frozen pair, so another thread never sees a new
      # provider next to the old one's tracer.
      #
      # @return [Object] an +OpenTelemetry::Trace::Tracer+
      def tracer
        provider = OpenTelemetry.tracer_provider
        pair = @tracer
        return pair[1] if pair && pair[0].equal?(provider)

        made = provider.tracer(name: TRACER_NAME, version: VERSION)
        @tracer = [provider, made].freeze
        made
      end

      # @param span [Object] the +OpenTelemetry::Trace::Span+
      # @param error [Exception]
      # @return [void]
      def record_exception(span, error)
        if exception_details == :full
          span.record_exception(error)
        else
          # to_s, as record_exception does: an anonymous class has no name.
          span.add_event('exception', attributes: {'exception.type' => error.class.to_s})
        end
      end

      # @param span [Object] the +OpenTelemetry::Trace::Span+
      # @param result [Actionable::Result]
      # @return [void]
      def annotate_run(span, result)
        code = result.code.to_s
        span.set_attribute('actionable.outcome', result.status.to_s)
        span.set_attribute('actionable.code', code)
        span.status = OpenTelemetry::Trace::Status.error(code) if result.failure?
      end

      # @param instance [Actionable::Action]
      # @param span [Object] the +OpenTelemetry::Trace::Span+
      # @yieldreturn [Object]
      # @return [Object] the block's value
      def traced_step(instance, span)
        before = instance.result
        yield
      ensure
        after = instance.result
        span.set_attribute('actionable.code', after.code.to_s) if after.is_a?(Result) && !after.equal?(before)
      end

      # @param action [Class]
      # @return [String] the class name, or +Actionable::Action+ for an anonymous one
      def label_for(action)
        action.name || Action.name.to_s
      end
    end

    # Prepended onto {Actionable::Action}'s singleton class so every +.run+
    # (+run_each+ and nested action steps included) runs inside its span.
    module ActionRun
      # {Actionable::Action.run}, inside the run's span.
      #
      # @param args [Object] forwarded to +.run+
      # @param kwargs [Object] forwarded to +.run+
      # @return [Actionable::Result]
      def run(*args, **kwargs)
        Otel.trace_run(self) { super }
      end
    end

    # Prepended onto {Actionable::Runner} so each executed step and hook runs
    # inside its own span (unless {Otel.step_spans=} turned them off).
    module RunnerSteps
      private

      # @param section [Symbol]
      # @param step [Actionable::Steps::Base]
      # @return [void]
      def record(section, step, &)
        return super unless Otel.step_spans?

        Otel.trace_step(@instance, section, step) { super }
      end
    end
  end
end

# Wire the adapter into the core: a span around every run, and one around
# every step and hook the runner executes.
Actionable::Action.singleton_class.prepend(Actionable::Otel::ActionRun)
Actionable::Runner.prepend(Actionable::Otel::RunnerSteps)
