# field_struct-avro

Apache Avro for [FieldStruct](https://github.com/aemadrid-twx/field_struct) classes: a record schema per class, and instances to and from Avro binary, without losing decimals, 64-bit integers, sub-millisecond times or enum symbols.

> **Status: local draft (0.1.0), not published.** It needs `FieldStruct::Introspection`, merged to field_struct `develop` (#23) but unreleased. The defaults below are proposals waiting on a decision; see [Open decisions](#open-decisions).

```ruby
require 'field_struct/avro'

module Billing
  class Invoice < FieldStruct::Base
    required :id,     :uuid
    required :total,  :big_decimal, round: 2
    required :at,     :time, zone: 'America/Denver'
    required :status, :symbol, enum: %i[open paid]
    optional :tags,   :array, of: :string
  end
end

FieldStruct::Avro.schema(Billing::Invoice)
# => {"type" => "record", "name" => "Invoice", "namespace" => "Billing", "fields" => [
#      {"name" => "id",     "type" => {"type" => "string", "logicalType" => "uuid"}},
#      {"name" => "total",  "type" => {"type" => "bytes", "logicalType" => "decimal", "precision" => 38, "scale" => 2}},
#      {"name" => "at",     "type" => {"type" => "long", "logicalType" => "timestamp-micros"}},
#      {"name" => "status", "type" => {"type" => "enum", "name" => "Invoice_status", "symbols" => ["open", "paid"]}},
#      {"name" => "tags",   "type" => ["null", {"type" => "array", "items" => ["null", "string"]}], "default" => nil}]}

bytes = FieldStruct::Avro.encode(invoice)
FieldStruct::Avro.decode(Billing::Invoice, bytes) == invoice  # => true
```

`to_datum` / `from_datum` give the Hash the avro gem reads and writes, for your own writer or a schema registry. `decode(klass, bytes, writer_schema:)` reads bytes written with an older schema. `include FieldStruct::Avro::Methods` adds `Klass.to_avro_schema`, `#to_avro` and `Klass.from_avro`.

## Mapping

| FieldStruct | Avro | Notes |
|---|---|---|
| `:string`, `:immutable_string`, `:email`, `:url` | `string` | `format:` can't be expressed, so validation is lost; the data isn't |
| `:uuid` (default format) | `string` / `uuid` | a custom `format:` is a plain `string` |
| `:binary` | `bytes` | |
| `:integer` | `long` | never `int`; a value past 64 bits raises |
| `:float` | `double` | |
| `:big_decimal, round: n` | `bytes` / `decimal`, precision 38, scale n | `avro: {precision:}`; a value that doesn't fit raises |
| `:big_decimal` without `round:` | `string` | there's no scale to declare |
| `:date` | `int` / `date` | |
| `:time`, `:datetime` | `long` / `timestamp-micros` | `timestamp: :nanos`/`:millis`, globally or `avro: {timestamp:}`; encoding raises rather than drop precision; decoding puts the field's `zone:` back |
| `:symbol, enum:` | named `enum` `<Record>_<field>` | symbols that aren't Avro names, or `avro: {enum: false}`, give a `string`; `avro: {enum_default:}` |
| `:symbol` | `string` | |
| `:value` | `string` holding JSON | |
| optional | `["null", T]`, default `null` | with a literal default: `[T, "null"]` and that default |
| `:array, of: T` | `array` of `["null", T]` | an array of arrays or unions raises: no element type is recorded |
| nested struct | named `record` (`Billing::Line` → namespace `Billing`, name `Line`) | defined once, then referenced, so recursion works; anonymous ones are `<Record>_<field>` |
| `:union` | Avro union, `long` before `double` | members landing on one Avro type (string + uuid, string + binary) raise |
| `desc:` | `doc` | |
| `sensitive:` | `"x-fs-sensitive": true` | the avro gem's parser drops `x-` properties: register the Hash/JSON, not a parsed schema |

A field's `avro: {type: …}` replaces its mapping entirely.

## Open decisions

Each default here is a proposal from the overnight run of 2026-10-25, not yet decided:

1. Timestamps default to **micros**, raising rather than dropping nanoseconds (alternatives: nanos, or RFC 3339 strings, which keep the offset but lose time semantics downstream).
2. `:big_decimal` without `round:` becomes a **string** (alternatives: raise, or require `avro: {precision:, scale:}`).
3. Array elements are **always nullable**, matching JSON Schema.
4. Enums are emitted, with opt-in `enum_default:` (Avro readers break on new symbols without one).
5. API: **module functions** plus opt-in `Methods`, no monkey-patching.
6. Built on `FieldStruct::Introspection` (field_struct#23).
7. Time zones are put back **in this gem** on decode; whether field_struct's `Time#coerce` should re-zone a `Time` it's given is a separate core question.

Not built yet: schema-registry helpers (avro_turf), Avro → FieldStruct class generation.

## Development

`bundle exec rake` runs the specs (against the real avro gem: every schema must parse, every instance must round-trip `==`) and RuboCop.
