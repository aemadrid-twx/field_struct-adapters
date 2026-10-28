# field_struct-json_schema

JSON Schema (draft 2020-12) for [FieldStruct](https://github.com/aemadrid-twx/field_struct) classes: the schema of the JSON a class writes with `to_json` and reads back with `from_json`. Use it for API docs, request validation in other languages, LLM tool parameters (RubyLLM and MCP take a JSON Schema) or TypeScript types. It has no dependencies beyond field_struct.

> **Status: 0.1.0, unreleased.** It needs `FieldStruct::Introspection`, which is on field_struct `develop` but not yet in a release, so install it from git for now:
>
> ```ruby
> gem 'field_struct', git: 'https://github.com/aemadrid-twx/field_struct', branch: 'develop'
> gem 'field_struct-json_schema', git: 'https://github.com/aemadrid-twx/field_struct-adapters', glob: 'field_struct-json_schema/*.gemspec'
> ```

<!-- doctest -->
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
Owner.to_json_schema == schema    # => true
```

It returns a Hash with String keys, a fresh copy each time: add enum values or descriptions for an LLM tool without touching the class, then `Oj.dump` or `JSON.generate` it. The built schema is kept per class and copied, so calling `generate` per request is cheap. It's rebuilt when a field, a `serialize` mapping, `unknown_attributes` or a class name changes, and it's never kept when a custom type's own `json_schema` method was asked, since that method may answer differently next time. A field's options changed in place (an `enum:` Array, a `json_schema:` Hash), or a `json_schema` method added to a type later, aren't noticed: declare the field again instead.

## What it describes

- **The canonical JSON, not every input the setters coerce.** `age: "30"` is a fine assignment but not valid against `"type": "integer"`. BigDecimal is a decimal string (`"pattern": "^-?[0-9]+\\.[0-9]+$"`, as `to_json` writes it); dates are `"format": "date"`, times and datetimes `"date-time"` (only for the default or `:iso8601` format: a `:db`, `:rfc2822` or strftime format is a plain string); `:value` is `{}` (anything).
- **`:uuid`, `:url`, `:email`** are described by the Regexp the struct checks: the default UUID one is `"format": "uuid"`; the URL and Email defaults become a `pattern`, because JSON Schema's `uri` and `email` are stricter than field_struct's (`josé@example.com` passes the struct and fails `email`).
- **Property names** are the `serialize :json` names; `generate(klass, serialization: :xml)` uses another format's.
- **`required`** lists required fields without a `default:` (a default fills a missing key). Optional fields also accept `null`.
- **Constraints:** `enum:` → `enum`; an `in:` Range → `minimum` / `maximum` / `exclusiveMaximum` (an infinite end stays open), an `in:` Array → `enum`; a Regexp `format:` → `pattern` (below). `in:` on dates, times and decimals has no keyword and is left out.
- **Nested structs** go in `$defs` under their class name and are referenced with `$ref`; the root itself is `#`, so recursive structs work. An anonymous nested struct is inlined, and so is one named under an anonymous module.
- **Annotations:** `description:` → `description`; a `default:` that is already what `to_json` writes → `default` (a callable, or `default: 1` on a string field, is left out); `sensitive: true` → `x-sensitive`, and the field's `default` is left out, since a schema is published (`to_json` still writes the value). `unknown_attributes :raise` → `"additionalProperties": false`.

## Regexp formats

`FieldStruct::JSONSchema.pattern_for(regexp)` translates a Ruby Regexp into an ECMA-262 pattern that matches exactly the same strings under the `u` flag (what Ajv and JSON Schema 2020-12 use), or returns `nil`. A wrong pattern would make a validator reject values the struct accepts, so anything without an exact equivalent is left out rather than approximated:

<!-- doctest -->
```ruby
FieldStruct::JSONSchema.pattern_for(/\A\d+\.\d+\z/)  # => "^\\d+\\.\\d+$"
FieldStruct::JSONSchema.pattern_for(/\A\h+\z/i)      # => "^[0-9a-fA-F]+$"
FieldStruct::JSONSchema.pattern_for(/\A(?>a+)\z/)    # => nil
```

`\A` / `\z` become `^` / `$`; `.`, `\s`, `^` and `$` keep Ruby's meaning; `/i` is spelled out with Ruby's extra case folds (`ok` → `[oO][kKK]`, the last being the Kelvin sign). A Regexp with no exact translation becomes `x-ruby-pattern` with the Ruby source: an annotation, not checked by validators. That includes possessive quantifiers, atomic groups, backreferences, a repeated group that holds a variable repeat or an alternation (`(a+)+`, `(\w+\s?)+`, `(a|aa)+`: Ruby's regex memoization makes them safe, but a JavaScript validator backtracks exponentially on a crafted input; `(\d{3}-){2}` is fine). For now that includes delimited ones that are safe, like slugs `[a-z]+(-[a-z]+)*`, IPv4 `(?:\d{1,3}\.){3}\d{1,3}`, hostnames `(?:[a-z0-9-]+\.)+[a-z]{2,}` and `\d+(,\d+)*`, and alternatives that can't overlap, like `(?:[^"\\]|\\.)*`. The list also has `\p{…}`, POSIX brackets, `/x`, and under `/i` non-ASCII letters and letter pairs Ruby matches as one character (`/fi/i` matches `ﬁ`, so `/\Afile\z/i` doesn't translate). More Regexps may translate in later versions.

## Overrides

A field's `json_schema: {...}` option beats the type's own `json_schema` method, which beats the derived schema. `true` and `false` are the always/never schemas. Define `json_schema` on a custom type to describe it (if it raises, `generate` raises an `ArgumentError` naming the type and the field, with your error as `cause`); a custom type without one is unconstrained and named after its `ruby_type`: `{"x-ruby-type" => "Rational"}` for a type whose `ruby_type` is `Rational`. An override describes a present value: an optional field still adds `null`.

<!-- doctest -->
```ruby
class Money < FieldStruct::Types::Base
  def coerce(value, **) = value.to_r
  def ruby_type = Rational
  def json_schema = {'type' => 'string', 'pattern' => '^[0-9]+/[0-9]+$'}
end

class Ratio < FieldStruct::Types::Base # no json_schema method
  def coerce(value, **) = value.to_r
  def ruby_type = Rational
end

class Quote < FieldStruct::Base
  required :price,  Money
  optional :margin, Money
  required :share,  Ratio
  required :sku,    :string, json_schema: {'type' => 'string', 'minLength' => 8}
  optional :legacy, :value, json_schema: false
end

properties = FieldStruct::JSONSchema.generate(Quote)['properties']
properties['price']  # => {"type" => "string", "pattern" => "^[0-9]+/[0-9]+$"}
properties['margin'] # => {"type" => ["string", "null"], "pattern" => "^[0-9]+/[0-9]+$"}
properties['share']  # => {"x-ruby-type" => "Rational"}
properties['sku']    # => {"type" => "string", "minLength" => 8}
properties['legacy'] # => {"anyOf" => [{"not" => {}}, {"type" => "null"}]}
```

## Limits

These follow field_struct's own validation, so the schema accepts exactly what the struct does (decided 2026-10-27):

- An optional string field with `enum:` or a `format:` also accepts a blank string: blank counts as missing there, so the struct is valid and `to_json` writes `""`. A `:binary` field accepts only an empty one, since a blank binary is a value.
- Every array element may be `null`, nested ones too: validation skips `nil` elements.
- `:array, of: :uuid` (or `:url`, `:email`) checks nothing per element unless `element: {format: …}` says so, and the schema says the same.

## Development

`bundle exec rake` runs the specs and RuboCop. The specs validate real `to_json` output against generated schemas with an independent validator (json_schemer, dev only).

`bundle exec rake differential` (needs Node) checks the translation itself. It runs every Regexp in `spec/differential/corpus.json` (about 600) through `pattern_for`, computes Ruby's answer for each of their samples on the Ruby you're running, and checks that Node's `u`-flag RegExp gives the same answer for every one. CI runs it on Ruby 3.3 and 4.0. When a bug report shows a Regexp that translates wrongly, add it to the corpus with the strings that disagree.
