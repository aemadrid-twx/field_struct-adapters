# Changelog

## [Unreleased]

### Added

- `require 'actionable/otel'`: an OpenTelemetry span per actionable run, with a child span per executed step and hook (see the README). It moves here from actionable-rb, where it was merged to `main` after 1.10.0 but never released; the API (`Actionable::Otel.exception_details`, `.step_spans`) is unchanged. As a gem of its own it declares `opentelemetry-api` (`~> 1.7`) instead of checking for it at require time, and the tracer's version is this gem's version rather than actionable-rb's.
- RBS signatures in `sig/actionable-otel.rbs`, generated from the YARD comments and packaged with the gem, for Steep users.
