# field_struct-avro

Apache Avro for [FieldStruct](https://github.com/aemadrid-twx/field_struct) classes: a record schema per class, and instances to and from Avro binary, without losing decimals, 64-bit integers, sub-millisecond times or enum symbols.

> **Status: 0.1.0, unreleased.** It needs `FieldStruct::Introspection`, which is on field_struct `develop` but not yet in a release, so install it from git for now:
>
> ```ruby
> gem 'field_struct', git: 'https://github.com/aemadrid-twx/field_struct', branch: 'develop'
> gem 'field_struct-avro', git: 'https://github.com/aemadrid-twx/field_struct-adapters', glob: 'field_struct-avro/*.gemspec'
> ```

<!-- doctest -->
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

invoice = Billing::Invoice.new(id: '0b9d6a4e-3c1f-4a59-9d1e-2f6a8c7b5e10', total: '19.90',
                               at: '2026-10-27 09:30:00.123456', status: :paid, tags: ['rush'])
bytes = FieldStruct::Avro.encode(invoice)
FieldStruct::Avro.decode(Billing::Invoice, bytes) == invoice  # => true
```

`to_datum` / `from_datum` give the Hash the avro gem reads and writes, for your own writer or a schema registry. `decode(klass, bytes, writer_schema:)` reads bytes written with an older schema. It raises where the avro gem would read those bytes as the wrong value, because it matches fields by base type only: a field whose decimal scale or timestamp precision changed, a date read as a number or time, or a decimal read as a plain string or the reverse. A decimal's precision may change: it isn't used when decoding. `include FieldStruct::Avro::Methods` adds `Klass.to_avro_schema`, `#to_avro` and `Klass.from_avro`.

## Mapping

| FieldStruct | Avro | Notes |
|---|---|---|
| `:string`, `:immutable_string`, `:email`, `:url` | `string` | `format:` can't be expressed, so validation is lost; the data isn't |
| `:uuid` (default format) | `string` / `uuid` | a custom `format:` is a plain `string` |
| `:binary` | `bytes` | |
| `:integer` | `long` | never `int`; a value past 64 bits raises |
| `:float` | `double` | |
| `:big_decimal, round: n` | `bytes` / `decimal`, precision 38, scale n | `avro: {precision:}`; a value that doesn't fit raises, and so does a scale above the precision. A negative `round:` is scale 0 |
| `:big_decimal` without `round:` | `string` | there's no scale to declare |
| `:date` | `int` / `date` | |
| `:time`, `:datetime` | `long` / `timestamp-micros` | `timestamp: :nanos`/`:millis`, globally or `avro: {timestamp:}`; encoding raises rather than drop precision; decoding puts the field's `zone:` back |
| `:symbol, enum:` | named `enum` `<Record>_<field>` | symbols that aren't Avro names, or `avro: {enum: false}`, give a `string`; `avro: {enum_default:}` |
| `:symbol` | `string` | |
| `:value` | `string` holding JSON | the same JSON `to_json` writes (ISO 8601 times, plain decimals), so it reads back as from `from_json`: times and decimals as Strings, floats as BigDecimal |
| optional | `["null", T]`, default `null` | with a literal default: `[T, "null"]` and that default |
| `:array, of: T` | `array` of `["null", T]` | an array of arrays or unions raises: no element type is recorded |
| nested struct | named `record` (`Billing::Line` → namespace `Billing`, name `Line`) | defined once, then referenced, so recursion works; anonymous ones are `<Record>_<field>`. A class with no module takes the namespace of the record it first appears in, as Avro gives it (`Line` inside `Billing::Invoice` is `Billing.Line`), and raises where Avro can't name it |
| `:union` | Avro union, `long` before `double` | members landing on one Avro type (string + uuid, string + binary) raise, and so do struct members where an earlier one's required fields are all in a later one: Avro picks a record branch by shape, so the later struct would be written as the earlier |
| `desc:` | `doc` | |
| `sensitive:` | `"x-fs-sensitive": true` | the avro gem's parser drops `x-` properties: register the Hash/JSON, not a parsed schema |

A field's `avro: {type: …}` replaces its mapping entirely, in the schema and in the bytes: the value goes to Avro as field_struct holds it (symbols as strings, nested structs as records, a time back in its `zone:`), so it has to fit the type you gave. A `:big_decimal` with `avro: {type: 'string'}` raises, for example, because a BigDecimal isn't a string. A `:value` overridden to a (nullable) string still travels as JSON text. The other `avro:` options of an array or union field (`precision:`, `timestamp:`, `enum: false`) apply to its elements or members.

## Defaults, and why

Decided 2026-10-27:

1. Timestamps default to **micros**, and encoding raises rather than drop nanoseconds. Micros is what most Avro readers (Spark, BigQuery, Kafka Connect) handle; pass `timestamp: :nanos` to keep everything.
2. `:big_decimal` without `round:` becomes a **string**: an Avro decimal needs a fixed scale, and without `round:` there isn't one to declare.
3. Array elements are **always nullable**, because field_struct accepts nil elements.
4. Enums are emitted as Avro enums. Give `avro: {enum_default:}` if you'll add symbols later: an Avro reader without a default fails on a symbol it doesn't know.
5. The API is **module functions** plus the opt-in `Methods`; nothing is added to your classes unless you include it.
6. It's built on `FieldStruct::Introspection`, the walk every adapter shares.
7. Decoding puts a field's `zone:` back, since Avro timestamps carry no offset.

Not built yet: schema-registry helpers (avro_turf), Avro → FieldStruct class generation.

## Development

`bundle exec rake` runs the specs (against the real avro gem: every schema must parse, every instance must round-trip `==`) and RuboCop.
