# field_struct-adapters

Optional gems that connect [field_struct](https://github.com/aemadrid-twx/field_struct) and [actionable](https://github.com/aemadrid-twx/actionable) to other formats and tools. Each one is its own gem, so you install, load and upgrade only the ones you use.

| Gem | What it does | Status |
|---|---|---|
| [actionable-otel](actionable-otel) | OpenTelemetry spans for actionable runs, steps and hooks, with outcome and code attributes and no input or output values | 0.1.0, unreleased |
| [field_struct-avro](field_struct-avro) | Apache Avro record schemas, and instances to and from Avro binary, for Kafka, data lakes and schema registries | 0.1.0, unreleased |
| [field_struct-json_schema](field_struct-json_schema) | JSON Schema (draft 2020-12) of a class's JSON, for API docs, LLM tool parameters, MCP and validators in other languages | 0.1.0, unreleased |

The adapters are built on `FieldStruct::Introspection`, the field walk in field_struct's core, which you can use to write your own: see [Exporting to another schema language](https://github.com/aemadrid-twx/field_struct/blob/develop/USAGE.md#exporting-to-another-schema-language).

## Installing

Until the adapters are released, install them from git (the field_struct adapters also need field_struct from git, until it ships Introspection in a release):

```ruby
gem 'field_struct', git: 'https://github.com/aemadrid-twx/field_struct', branch: 'develop'
gem 'field_struct-avro', git: 'https://github.com/aemadrid-twx/field_struct-adapters', glob: 'field_struct-avro/*.gemspec'
gem 'field_struct-json_schema', git: 'https://github.com/aemadrid-twx/field_struct-adapters', glob: 'field_struct-json_schema/*.gemspec'

gem 'actionable-otel', git: 'https://github.com/aemadrid-twx/field_struct-adapters', glob: 'actionable-otel/*.gemspec'
```

## Type signatures

Each gem ships RBS signatures in `sig/`, generated from its YARD comments by [sord](https://github.com/AaronC81/sord), as field_struct and actionable do. Each gem's default rake task fails when the committed file is stale (`rake sigs:check`) or names a type rbs can't resolve against the signatures field_struct and actionable ship (`rake sigs:validate`). After changing a YARD comment, run `bundle exec rake sigs:generate` in that gem's directory and commit the result.

Write a YARD type from field_struct or actionable in full (`FieldStruct::Field`, not `Field`): sord parses only the adapter, so a short name is a guess. `support/sigs.rb` explains how each check catches one.

## Versions and releases

Each gem has its own version, CHANGELOG and tags (`field_struct-avro/v0.1.0`), and is released on its own schedule: a fix to one adapter never forces a release of another. Each gemspec declares the field_struct (or actionable) versions it works with.

## Development

```sh
bundle install
bundle exec rake                   # every gem's specs and RuboCop
bundle exec rake field_struct-avro # one gem
```

Each gem directory is self-contained (its own Gemfile, Rakefile and specs), so you can also `cd` into one and run `bundle exec rake` there. CI runs every gem on Ruby 3.3, 3.4 and 4.0, on every PR and nightly against the newest field_struct and actionable code.

## License

MIT; see [LICENSE.txt](LICENSE.txt).
