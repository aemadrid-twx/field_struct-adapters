# field_struct-json_schema

JSON Schema (draft 2020-12) for [FieldStruct](https://github.com/aemadrid-twx/field_struct) classes: the schema of the JSON a class writes with `to_json` and reads back with `from_json`. Use it for API docs, request validation in other languages, LLM tool parameters (RubyLLM and MCP take a JSON Schema) or TypeScript types. It has no dependencies beyond field_struct.

> **Status: 0.1.0, unreleased.** It needs `FieldStruct::Introspection`, which is on field_struct `develop` but not yet in a release, so install it from git for now:
>
> ```ruby
> gem 'field_struct', git: 'https://github.com/aemadrid-twx/field_struct', branch: 'develop'
> gem 'field_struct-json_schema', git: 'https://github.com/aemadrid-twx/field_struct-adapters', glob: 'field_struct-json_schema/*.gemspec'
> ```

```ruby
require 'field_struct/json_schema'

class Pet < FieldStruct::Base
  required :name, :string, description: 'Call name'
  optional :born, :date
end

class Owner < FieldStruct::Base
  include FieldStruct::JSONSchema::Methods # adds Owner.to_json_schema; optional

  required :first_name, :string
  optional :plan, :string, enum: %w[free pro], default: 'free'
  optional :age,  :integer, in: 0..150
  optional :pets, :array, of: Pet
  serialize :json, first_name: 'firstName'
end

schema = FieldStruct::JSONSchema.generate(Owner) # or Owner.to_json_schema
schema['type']                    # => "object"
schema['required']                # => ["firstName"]
schema['properties']['firstName'] # => {"type" => "string"}
schema['properties']['age']       # => {"type" => ["integer", "null"], "minimum" => 0, "maximum" => 150}
schema['properties']['plan']['default']             # => "free"
schema['properties']['pets']['items']['anyOf'].first.keys  # => ["$ref"]
schema['$defs'].values.first['properties']['born']  # => {"type" => ["string", "null"], "format" => "date"}
```

It returns a Hash with String keys, a fresh copy each time: add enum values or descriptions for an LLM tool without touching the class, then `Oj.dump` or `JSON.generate` it.

## What it describes

- **The canonical JSON, not every input the setters coerce.** `age: "30"` is a fine assignment but not valid against `"type": "integer"`. BigDecimal is a decimal string (`"pattern": "^-?[0-9]+\\.[0-9]+$"`, as `to_json` writes it); dates are `"format": "date"`, times and datetimes `"date-time"` (only for the default or `:iso8601` format: a `:db`, `:rfc2822` or strftime format is a plain string); `:value` is `{}` (anything).
- **`:uuid`, `:url`, `:email`** are described by the Regexp the struct checks: the default UUID one is `"format": "uuid"`; the URL and Email defaults become a `pattern`, because JSON Schema's `uri` and `email` are stricter than field_struct's (`josé@example.com` passes the struct and fails `email`).
- **Property names** are the `serialize :json` names; `generate(klass, serialization: :xml)` uses another format's.
- **`required`** lists required fields without a `default:` (a default fills a missing key). Optional fields also accept `null`.
- **Constraints:** `enum:` → `enum`; an `in:` Range → `minimum` / `maximum` / `exclusiveMaximum` (an infinite end stays open), an `in:` Array → `enum`; a Regexp `format:` → `pattern` (below). `in:` on dates, times and decimals has no keyword and is left out.
- **Nested structs** go in `$defs` under their class name and are referenced with `$ref`; the root itself is `#`, so recursive structs work. An anonymous nested struct is inlined, and so is one named under an anonymous module.
- **Annotations:** `description:` → `description`; a `default:` that is already what `to_json` writes → `default` (a callable, or `default: 1` on a string field, is left out); `sensitive: true` → `x-sensitive` (`to_json` still writes the value). `unknown_attributes :raise` → `"additionalProperties": false`.

## Regexp formats

`FieldStruct::JSONSchema.pattern_for(regexp)` translates a Ruby Regexp into an ECMA-262 pattern that matches exactly the same strings under the `u` flag (what Ajv and JSON Schema 2020-12 use), or returns `nil`. A wrong pattern would make a validator reject values the struct accepts, so anything without an exact equivalent is left out rather than approximated:

```ruby
FieldStruct::JSONSchema.pattern_for(/\A\d+\.\d+\z/)  # => "^\\d+\\.\\d+$"
FieldStruct::JSONSchema.pattern_for(/\A\h+\z/i)      # => "^[0-9a-fA-F]+$"
FieldStruct::JSONSchema.pattern_for(/\A(?>a+)\z/)    # => nil
```

`\A` / `\z` become `^` / `$`; `.`, `\s`, `^` and `$` keep Ruby's meaning; `/i` is spelled out with Ruby's extra case folds (`ok` → `[oO][kKK]`, the last being the Kelvin sign). A Regexp with no exact translation becomes `x-ruby-pattern` with the Ruby source: an annotation, not checked by validators. That includes possessive quantifiers, atomic groups, backreferences, `\p{…}`, POSIX brackets, `/x`, and under `/i` non-ASCII letters and letter pairs Ruby matches as one character (`/fi/i` matches `ﬁ`, so `/\Afile\z/i` doesn't translate). More Regexps may translate in later versions.

## Overrides

A field's `json_schema: {...}` option beats the type's own `json_schema` method, which beats the derived schema. `true` and `false` are the always/never schemas. Define `json_schema` on a custom type to describe it; a custom type without one is unconstrained and named, `{"x-ruby-type" => "Money"}`. An override describes a present value: an optional field still adds `null`.

```ruby
class Money < FieldStruct::Types::Base
  def coerce(value, **) = value.to_r
  def ruby_type = Rational
  def json_schema = {'type' => 'string', 'pattern' => '^[0-9]+/[0-9]+$'}
end
```

## Limits

These follow field_struct's own validation, so the schema accepts exactly what the struct does (decided 2026-10-27):

- An optional string field with `enum:` or a `format:` also accepts a blank string: blank counts as missing there, so the struct is valid and `to_json` writes `""`.
- Every array element may be `null`, nested ones too: validation skips `nil` elements.
- `:array, of: :uuid` (or `:url`, `:email`) checks nothing per element unless `element: {format: …}` says so, and the schema says the same.

## Development

`bundle exec rake` runs the specs and RuboCop. The specs validate real `to_json` output against generated schemas with an independent validator (json_schemer, dev only).
