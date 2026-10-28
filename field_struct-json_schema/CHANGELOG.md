# Changelog

## [Unreleased]

### Added

- `FieldStruct::JSONSchema.generate`, `.pattern_for` and the opt-in `FieldStruct::JSONSchema::Methods` (`Klass.to_json_schema`), moved here from field_struct's core (aemadrid-twx/field_struct#18 and #23), where they were never released.

### Changed

- `Klass.to_json_schema` is opt-in: `include FieldStruct::JSONSchema::Methods`. In core it was defined on every struct.
- A custom type gives its own schema by defining `json_schema`; core's `Types::Base` no longer defines a default one.
