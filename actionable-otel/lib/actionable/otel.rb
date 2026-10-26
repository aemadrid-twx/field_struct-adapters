# frozen_string_literal: true

# Optional OpenTelemetry adapter. Load it explicitly with
# `require 'actionable/otel'`; the core entry point never loads it, so nothing
# touches OpenTelemetry unless you opt in. `opentelemetry-api` is a soft
# dependency: actionable-rb does not depend on it, so add it to your own
# Gemfile (plus `opentelemetry-sdk` and an exporter to send the spans
# anywhere).
require_relative '../actionable' # ensure the core is loaded (self-contained entry)

begin
  require 'opentelemetry'
rescue LoadError => e
  raise LoadError,
    'actionable/otel needs the opentelemetry-api gem, which actionable-rb does not depend on: add ' \
    "`gem 'opentelemetry-api'` to your Gemfile (and opentelemetry-sdk with an exporter to send the spans " \
    "anywhere), then require 'actionable/otel' again. (#{e.message})"
end

module Actionable
  # Traces every action run as an OpenTelemetry span, with a child span per
  # executed step and lifecycle hook.
  #
  # A run's span is named after the action (+Charge.run+) and carries
  # +actionable.action+, +actionable.outcome+ (+success+ / +failure+ /
  # +skipped+) and +actionable.code+. A failure sets the span's status to
  # error with the code as its description; a skip is not an error. An
  # exception that escapes the run is recorded on the span and re-raised. A
  # step's span (+Charge/authorize+) carries +actionable.action+,
  # +actionable.step+, +actionable.section+ (+main+, +success+, +failure+,
  # +skip+ or +always+) and, when that step recorded the result,
  # +actionable.code+. A nested action's run span nests under the parent's
  # step span.
  #
  # Input and output values are never recorded: they are often sensitive
  # (card numbers, tokens, personal data). Spans follow OpenTelemetry's own
  # sampling, not +measure+, which only governs {History}.
  module Otel
    # The instrumentation scope name the tracer is obtained under.
    # @return [String]
    TRACER_NAME = 'actionable'

    @step_spans = true

    class << self
      # Turn the per-step spans on or off for the whole process. Off, each run
      # emits only its own span. On by default.
      #
      #   Actionable::Otel.step_spans = false
      #
      # @param enabled [Boolean] +false+ to emit run spans only
      # @return [Boolean] whether step spans are now on
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
      # @param action [Class<Action>] the action being run
      # @yieldreturn [Result] the run's result
      # @return [Result] the block's result
      def trace_run(action)
        label = label_for(action)
        tracer.in_span("#{label}.run", attributes: {'actionable.action' => label}, kind: :internal) do |span|
          result = yield
          annotate_run(span, result)
          result
        end
      end

      # Run the block inside the span for one step or hook of +instance+'s run,
      # recording the step's code when it changed the result (even when it
      # halted). Called by {RunnerSteps}.
      #
      # @api private
      # @param instance [Action] the running action instance
      # @param section [Symbol] where the step runs: +:main+ or a hook phase
      # @param step [Steps::Base] the step
      # @yieldreturn [Object]
      # @return [Object] the block's value
      def trace_step(instance, section, step, &block)
        label = label_for(instance.class)
        name = step.name.is_a?(Class) ? label_for(step.name) : step.name.to_s
        attributes = {'actionable.action' => label, 'actionable.step' => name, 'actionable.section' => section.to_s}
        tracer.in_span("#{label}/#{name}", attributes: attributes, kind: :internal) do |span|
          traced_step(instance, span, &block)
        end
      end

      private

      # The tracer, fetched from the current provider on every use so a
      # provider installed after this file loads still applies.
      #
      # @return [Object] an +OpenTelemetry::Trace::Tracer+
      def tracer
        OpenTelemetry.tracer_provider.tracer(TRACER_NAME, Actionable::VERSION)
      end

      # @param span [Object] the +OpenTelemetry::Trace::Span+
      # @param result [Result]
      # @return [void]
      def annotate_run(span, result)
        code = result.code.to_s
        span.set_attribute('actionable.outcome', result.status.to_s)
        span.set_attribute('actionable.code', code)
        span.status = OpenTelemetry::Trace::Status.error(code) if result.failure?
      end

      # @param instance [Action]
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
      # @return [Result]
      def run(*args, **kwargs)
        Otel.trace_run(self) { super }
      end
    end

    # Prepended onto {Actionable::Runner} so each executed step and hook runs
    # inside its own span (unless {Otel.step_spans=} turned them off).
    module RunnerSteps
      private

      # @param section [Symbol]
      # @param step [Steps::Base]
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
