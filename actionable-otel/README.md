# actionable-otel

OpenTelemetry tracing for [actionable](https://github.com/aemadrid-twx/actionable) actions: one span per run, a child span per step and lifecycle hook, the outcome and result code as attributes, and never an input or output value.

> **Status: 0.1.0, unreleased.** Install it from git for now:
>
> ```ruby
> gem 'actionable-otel', git: 'https://github.com/aemadrid-twx/field_struct-adapters', glob: 'actionable-otel/*.gemspec'
> ```

It works with actionable-rb 1.9 and later 1.x, and depends on `opentelemetry-api` (1.7 or later 1.x) only. Your application chooses the SDK and the exporter:

```ruby
# Gemfile
gem 'actionable-otel'
gem 'opentelemetry-sdk'
gem 'opentelemetry-exporter-otlp'

# config/initializers/opentelemetry.rb (or wherever you boot)
require 'opentelemetry/sdk'
require 'actionable/otel'

OpenTelemetry::SDK.configure { |c| c.service_name = 'shop' }
```

Requiring `actionable/otel` is what turns tracing on; `require 'actionable'` alone never loads OpenTelemetry.

## Tracing a checkout

```ruby
class Checkout < Actionable::Action
  input do
    required :order_id, :string
    required :card_token, :string
  end

  step :reserve_stock
  step :charge_card
  on_success :send_receipt
  on_failure :release_stock
  always :audit

  def charge_card
    fail!(:card_declined, 'The card was declined') unless Gateway.charge(input.card_token)
  end

  # reserve_stock, send_receipt, release_stock and audit …
end

Checkout.run(order_id: 'ord_1', card_token: 'tok_visa')
```

A successful run gives one trace:

```
Checkout.run              outcome=success code=success
  Checkout/reserve_stock  section=main
  Checkout/charge_card    section=main
  Checkout/send_receipt   section=success
  Checkout/audit          section=always
```

A declined card gives:

```
Checkout.run              outcome=failure code=card_declined   status=ERROR(card_declined)
  Checkout/reserve_stock  section=main
  Checkout/charge_card    section=main code=card_declined
  Checkout/release_stock  section=failure
  Checkout/audit          section=always
```

Each `.run` (including each item of `run_each` and each nested action step) is one span, named after the action, from the tracer named `actionable` at this gem's version. Every step and hook that runs gets a child span; a step skipped by its `if:` / `unless:` guard gets none. A `case_step`'s span is named after its value method (`Router/mode`); the branch it picks runs inside that span without one of its own. A nested action's run span sits under the parent's step span when it runs on the same thread and fiber (OpenTelemetry's context is per fiber, so a nested run in a `Thread.new`, or an `after_commit` hook that fires after `.run` returned, starts its own trace).

| Attribute | On | Value |
|---|---|---|
| `actionable.action` | run and step spans | the action's class name (`Actionable::Action` for an anonymous class) |
| `actionable.outcome` | run spans | `success`, `failure` or `skipped` |
| `actionable.code` | run spans; a step span when that step recorded the result | the result code, as a string |
| `actionable.step` | step spans | the method name, or the nested action's class name |
| `actionable.step.kind` | step spans | `method`, `action` or `case` |
| `actionable.section` | step spans | `main`, `success`, `failure`, `skip` or `always` |

## What gets recorded

- **A declared failure is an error.** The run span's status is set to error with the code as its description (`:invalid_input` included: a run that fails its input still gets a span). No exception event is recorded for it, because nothing was raised. Declared failures (`card_declined`, `not_found`) count toward your APM's error rate; filter on `actionable.code` to separate them from exceptions.
- **A skip is not an error.** Its status stays unset.
- **An exception that escapes the run** is recorded once, on the run span, and re-raised unchanged. The spans it passes through get error status. That run span has no outcome or code, since `.run` never returned a result.
- **Exception details are type-only by default.** `Actionable::Otel.exception_details` is `:type_only`: the run span gets an `exception` event with only `exception.type`, because a message or backtrace can carry input values (`"card 4111… declined"`). Opt in to the message and backtrace (OpenTelemetry's `record_exception`) with `Actionable::Otel.exception_details = :full`.
- **Input and output values are never recorded.** Neither are messages, errors or metadata. They often hold card numbers, tokens or personal data; add your own attributes in a step if you need them.
- **Sampling is OpenTelemetry's.** Spans are emitted whatever `measure` says (`measure` only governs `history`); use the SDK's sampler to keep a fraction of traces.
- **Fewer spans:** `Actionable::Otel.step_spans = false` (process-wide, e.g. in the initializer) keeps the run spans and drops the step spans; `Actionable::Otel.step_spans?` reads it back.
- **Cost:** measured on a CPU-bound action with 10 spans per run (2 runs, 8 steps and hooks), the SDK adds about 5 µs per span, about 50 µs per run; `step_spans = false` roughly halves that. Negligible next to a database call; noticeable in a tight `run_each` over many thousands of items.
- A stubbed run (`stub_actionable_success` and friends) emits no span, and `after_commit` hooks (actionable's Rails adapter) get no step span (a nested action used as one still gets its run span).

## Development

```sh
bundle install
bundle exec rake   # specs (against the real SDK's in-memory exporter) and RuboCop
```

The Gemfile builds against actionable's `main` branch from git; the gemspec's range is what users get.

## License

MIT; see [LICENSE.txt](../LICENSE.txt).
