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

`encode` doesn't validate: an instance that breaks a `format:`, `enum:` or `in:` rule encodes fine as long as its values fit the Avro types, so call `valid?` first if that matters. When a value doesn't fit (`id: 'abc'` on an integer field), it raises an `ArgumentError` listing the instance's errors, which name fields, not values.

`to_datum` / `from_datum` give the Hash the avro gem reads and writes, for your own writer or a schema registry. `decode(klass, bytes, writer_schema:)` reads bytes written with an older schema, given as a Hash, JSON text or a parsed `Avro::Schema`. It raises where the avro gem would read those bytes as the wrong value, because it matches fields by base type only: a field whose decimal scale or timestamp precision changed, a date read as a number or time, or a decimal read as a plain string or the reverse. It also raises for a time, date or decimal field that went from optional to required: the avro gem 1.12 fails to decode those. A decimal's precision may change: it isn't used when decoding. An optional field the older schema lacked gets its field_struct default, a date, decimal or proc included, even where the Avro schema can't carry that default. `schema`, `encode` and `decode` keep each class's built and parsed schema (`schema` returns a fresh copy), and each writer schema they've checked (and `to_datum`/`from_datum` each class's field list), and rebuild them when a field, a `serialize` mapping or a class name changes. Changing a field's options in place (an `avro:` Hash, an `enum:` Array) isn't noticed: declare the field again instead. `include FieldStruct::Avro::Methods` adds `Klass.to_avro_schema`, `#to_avro` and `Klass.from_avro`.

<!-- doctest -->
```ruby
require 'field_struct/avro'

class Order < FieldStruct::Base
  required :id,    :integer
  required :total, :big_decimal, round: 2
  optional :due,   :date, default: Date.new(2026, 12, 1)
end

order = Order.new(id: 7, total: '12.5')
FieldStruct::Avro.to_datum(order) # => {'id' => 7, 'total' => BigDecimal('12.5'), 'due' => Date.new(2026, 12, 1)}
FieldStruct::Avro.from_datum(Order, FieldStruct::Avro.to_datum(order)) == order # => true

# An older writer, before :due existed, and the bytes it wrote:
v1 = lambda do |scale|
  {'type' => 'record', 'name' => 'Order', 'fields' => [
    {'name' => 'id', 'type' => 'long'},
    {'name' => 'total', 'type' => {'type' => 'bytes', 'logicalType' => 'decimal', 'precision' => 38, 'scale' => scale}}
  ]}
end
write = lambda do |schema|
  buffer = StringIO.new
  writer = Avro::IO::DatumWriter.new(Avro::Schema.parse(schema.to_json))
  writer.write({'id' => 7, 'total' => BigDecimal('12.5')}, Avro::IO::BinaryEncoder.new(buffer))
  buffer.string
end

FieldStruct::Avro.decode(Order, write.call(v1.call(2)), writer_schema: v1.call(2)).due # => Date.new(2026, 12, 1)

# Written with scale 3, the avro gem would read 12.500 as 125.00:
error = begin
  FieldStruct::Avro.decode(Order, write.call(v1.call(3)), writer_schema: v1.call(3))
rescue ArgumentError => e
  e.message
end
error.start_with?("FieldStruct::Avro can't read these bytes: total: written as decimal (scale 3)") # => true
```

`schema` builds and parses the schema, so a field option the avro gem can't parse raises there, naming the class, instead of at the first `encode`. Call it at boot, or in a test, for each root class with the options you use (`serialization:`, `timestamp:`), to find those early. A nested struct is covered by its root. An `avro:` option that isn't a Hash (`avro: 'string'`, `avro: false`) raises too, as does a `serialization:` that no struct the schema walks declares with `serialize` (`:avro`, the default, needs none; a struct behind an `avro: {type:}` override isn't walked):

<!-- doctest -->
```ruby
require 'field_struct/avro'

class Typo < FieldStruct::Base
  required :note, :string, avro: {type: 'strng'}
end

error = begin
  FieldStruct::Avro.schema(Typo)
rescue ArgumentError => e
  e.message
end
error.start_with?("FieldStruct::Avro: Typo doesn't make a valid Avro schema") # => true
```

Schemas, field lists and checked writer schemas are cached per class, and the cache keeps each class alive. Under code reloading, clear it on each reload:

```ruby
# config/initializers/field_struct.rb
Rails.application.reloader.to_prepare { FieldStruct::Avro.clear_cache }
```

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

A field's `avro: {type: …}` (other than `nil`, which is the same as none) replaces its mapping entirely, in the schema and in the bytes: the value goes to Avro as field_struct holds it (symbols as strings, nested structs as records, a time back in its `zone:`), so it has to fit the type you gave. A `:big_decimal` with `avro: {type: 'string'}` raises, for example, because a BigDecimal isn't a string. A `:value` overridden to a (nullable) string still travels as JSON text. The other `avro:` options of an array or union field (`precision:`, `timestamp:`, `enum: false`) apply to its elements or members. `avro:` is a field option: field_struct doesn't accept it inside `element:`.

## Defaults, and why

Decided 2026-10-27:

1. Timestamps default to **micros**, and encoding raises rather than drop nanoseconds. Micros is what most Avro readers (Spark, BigQuery, Kafka Connect) handle; pass `timestamp: :nanos` to keep everything.
2. `:big_decimal` without `round:` becomes a **string**: an Avro decimal needs a fixed scale, and without `round:` there isn't one to declare.
3. Array elements are **always nullable**, because field_struct accepts nil elements.
4. Enums are emitted as Avro enums. Give `avro: {enum_default:}` if you'll add symbols later: without a default, `decode` raises on a symbol the reader doesn't know, naming the field. A field mapped to an Avro `string` (`avro: {enum: false}`) is checked the same way and honours `enum_default:` too; one with its own `avro: {type:}` isn't checked. The avro gem itself would hand the symbol back, so the instance would fail `valid?`.
5. The API is **module functions** plus the opt-in `Methods`; nothing is added to your classes unless you include it.
6. It's built on `FieldStruct::Introspection`, the walk every adapter shares.
7. Decoding puts a field's `zone:` back, since Avro timestamps carry no offset.

Not built yet: schema-registry helpers (avro_turf), Avro → FieldStruct class generation.

## Development

`bundle exec rake` runs the specs (against the real avro gem: every schema must parse, every instance must round-trip `==`) and RuboCop.
