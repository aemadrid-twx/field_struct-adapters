# frozen_string_literal: true

RSpec.describe FieldStruct::Avro, 'encode and decode' do
  def struct(const_name, &body)
    klass = Class.new(FieldStruct::Base)
    stub_const(const_name, klass)
    klass.class_eval(&body) if body
    klass
  end

  def round_trip(instance, **options)
    described_class.decode(instance.class, described_class.encode(instance, **options), **options)
  end

  let(:invoice_class) do
    line = struct('Billing::Line') do
      required :sku, :string
      required :cents, :integer
    end
    struct('Billing::Invoice') do
      required :id, :uuid
      required :total, :big_decimal, round: 2
      required :ratio, :big_decimal
      required :at, :time
      required :on, :date
      required :status, :symbol, enum: %i[open paid]
      required :big, :integer
      optional :lines, :array, of: line
      optional :tags, :array, of: :string
      optional :payload, :value
      optional :blob, :binary
      optional :flag, :boolean
      optional :score, :float
    end
  end

  let(:invoice) do
    invoice_class.new(
      id: '123e4567-e89b-12d3-a456-426614174000', total: '-12.30', ratio: '0.333333333333333333333',
      at: '1969-07-20T20:17:40.123456Z', on: '1901-12-13', status: :paid, big: 2**62,
      lines: [{sku: 'A-1', cents: 499}, nil], tags: ['x', nil], payload: {'k' => [1, 2.5, nil, 'v']},
      blob: "\xFF\x00\xC3".b, flag: false, score: -0.0
    )
  end

  it 'comes back equal, field by field, with nothing lost' do
    back = round_trip(invoice)

    expect(back).to eq(invoice)
    expect(back.total).to eq(BigDecimal('-12.30'))
    expect(back.ratio).to eq(BigDecimal('0.333333333333333333333'))
    expect(back.big).to eq(2**62)
    expect(back.at.nsec).to eq(123_456_000)
    expect(back.blob.bytes).to eq([0xFF, 0x00, 0xC3])
    expect(back.payload).to eq('k' => [1, 2.5, nil, 'v'])
  end

  it 'is smaller than the JSON' do
    expect(described_class.encode(invoice).bytesize).to be < invoice.to_json.bytesize
  end

  it 'refuses to drop nanoseconds under micros, and keeps them under nanos' do
    klass = struct('Tick') { required :at, :time }
    tick = klass.new(at: '2026-10-25T21:55:12.123456789-06:00')

    expect { described_class.encode(tick) }.to raise_error(ArgumentError, /more precision than timestamp-micros/)
    pair = struct('Pair') do
      required :created, :time
      required :updated, :array, of: :time
    end
    late = pair.new(created: '2026-10-25T21:55:12Z', updated: ['2026-10-25T21:55:12.123456789Z'])
    expect { described_class.to_datum(late) }
      .to raise_error(ArgumentError, /\AFieldStruct::Avro: Pair#updated is 2026-10-25T21:55:12\.123456789Z?.*, which has more precision than timestamp-micros/)
    holder = struct('Holder') { required :pair, pair }
    expect { described_class.to_datum(holder.new(pair: late)) }.to raise_error(ArgumentError, /\AFieldStruct::Avro: Pair#updated is/)
    expect(round_trip(tick, timestamp: :nanos).at.nsec).to eq(123_456_789)
  end

  it "lets an ArgumentError that isn't the timestamp check through as itself" do
    odd = Class.new { def inspect = raise(ArgumentError, 'unrelated') }.new
    stamp = struct('OddStamp') { required :at, :time, avro: {timestamp: odd} }

    expect { described_class.to_datum(stamp.new(at: Time.now)) }.to raise_error(ArgumentError, /\Aunrelated\z/)
  end

  it 'names a field inside an anonymous struct the way the schema does, as Holder#inner.at' do
    inner = Class.new(FieldStruct::Base) { required :at, :time }
    holder = struct('Holder') { required :inner, inner }
    late = holder.new(inner: {at: '2026-01-01T00:00:00.000000001Z'})
    expect { described_class.to_datum(late) }.to raise_error(ArgumentError, /\AFieldStruct::Avro: Holder#inner\.at is 2026-01-01T00:00:00\.000000001Z/)

    stamp = struct('Stamp') { required :at, :time, avro: {timestamp: :seconds} }
    expect { described_class.to_datum(stamp.new(at: Time.now)) }
      .to raise_error(ArgumentError, /\AFieldStruct::Avro \(Stamp#at\) avro: \{timestamp:\} must be one of/)
  end

  it "keeps a sensitive time's value out of the precision error" do
    klass = struct('Session') { required :born, :time, sensitive: true }
    session = klass.new(born: '2026-10-25T21:55:12.123456789Z')

    expect { described_class.encode(session) }.to raise_error(ArgumentError) { |error|
      expect(error.message).to eq('FieldStruct::Avro: Session#born is a sensitive time, which has more precision ' \
                                  'than timestamp-micros; round it, or use timestamp: :nanos')
    }
  end

  it 'honours a per-field avro: {timestamp:}, refusing what it would drop' do
    klass = struct('Log') do
      required :at, :time, avro: {timestamp: :millis}
      required :seen, :time
    end
    exact = klass.new(at: '2026-10-25T21:55:12.123Z', seen: '2026-10-25T21:55:12.123456Z')

    expect(round_trip(exact)).to eq(exact)
    expect { described_class.encode(klass.new(at: '2026-10-25T21:55:12.1234Z', seen: exact.seen)) }
      .to raise_error(ArgumentError, /more precision than timestamp-millis/)
  end

  it 'round-trips a :datetime in its zone, and a decimal scaled only by avro: {scale:}' do
    klass = struct('Booking') do
      required :at, :datetime, zone: 'America/Denver'
      required :fee, :big_decimal, avro: {scale: 2}
    end
    booking = klass.new(at: '2026-07-01T08:00:00', fee: '12.5')

    back = round_trip(booking)

    expect(back).to eq(booking)
    expect(back.at.offset).to eq(Rational(-6, 24))
    expect(described_class.schema(klass)['fields'][1]['type']).to include('logicalType' => 'decimal', 'scale' => 2)
  end

  it 'round-trips renamed fields, through nested structs, unions and arrays' do
    item = struct('Ren::Item') do
      required :sku_code, :string
      serialize :avro, sku_code: 'skuCode'
    end
    klass = struct('Ren::Cart') do
      required :line_items, :array, of: item
      required :first_pick, :union, of: [item, :integer]
      serialize :avro, line_items: 'lineItems', first_pick: 'firstPick'
    end
    cart = klass.new(line_items: [{sku_code: 'a'}], first_pick: {sku_code: 'b'})

    expect(described_class.to_datum(cart)).to eq('lineItems' => [{'skuCode' => 'a'}], 'firstPick' => {'skuCode' => 'b'})
    expect(round_trip(cart)).to eq(cart)
  end

  it "gives a time back in its field's zone:" do
    klass = struct('Shift') do
      required :starts, :time, zone: 'America/Denver'
      required :ends, :time, zone: '-03:00'
      required :plain, :time
      required :utc, :time, zone: 'UTC'
    end
    shift = klass.new(starts: '2026-07-01 08:00', ends: '2026-07-01T18:00:00Z', plain: '2026-07-01T18:00:00+02:00',
      utc: '2026-07-01 08:00:00')

    back = round_trip(shift)

    expect(back).to eq(shift)
    expect(back.starts.utc_offset).to eq(-6 * 3600)
    expect(back.ends.utc_offset).to eq(-3 * 3600)
    expect(back.plain.utc_offset).to eq(0) # no zone: to put back, so UTC
    expect([back.utc.utc?, back.utc.iso8601]).to eq([true, '2026-07-01T08:00:00Z']) # as field_struct gives it, so JSON keeps the Z
  end

  it "rezones to UTC without touching the caller's Time" do
    klass = struct('Stamp') { required :at, :time, zone: 'UTC' }
    given = Time.new(2026, 7, 1, 8, 0, 0, '+03:00')

    expect(described_class.from_datum(klass, {'at' => given}).at).to be_utc
    expect(given.utc_offset).to eq(10_800)
    expect(described_class.from_datum(klass, {'at' => given.dup.freeze}).at).to eq(given)
  end

  it 'raises rather than truncate a decimal or an integer that does not fit' do
    money = struct('Money') { required :amount, :big_decimal, round: 2, avro: {precision: 4} }
    count = struct('Count') { required :n, :integer }

    expect { described_class.encode(money.new(amount: '123.45')) }.to raise_error(StandardError, /precision/i)
    expect { described_class.encode(count.new(n: 2**64)) }.to raise_error(StandardError)
  end

  it 'round-trips a union, picking the struct member by its keys' do
    card = struct('Pay::Card') { required :last4, :string }
    bank = struct('Pay::Bank') { required :iban, :string }
    klass = struct('Pay::Method') do
      required :via, :union, of: [card, bank]
      required :amount, :union, of: %i[integer float]
    end
    payment = klass.new(via: bank.new(iban: 'DE89'), amount: 5)

    back = round_trip(payment)

    expect(back.via).to eq(bank.new(iban: 'DE89'))
    expect(back.amount).to be_an(Integer) # ["long", "double"]: 5 stays an integer
    expect(round_trip(klass.new(via: card.new(last4: '4242'), amount: 2.5))).to eq(klass.new(via: card.new(last4: '4242'), amount: 2.5))
  end

  it "passes a field with avro: {type:} through as is, since the override is the user's mapping" do
    klass = struct('Override') do
      required :raw, :value, avro: {type: {'type' => 'map', 'values' => 'string'}}
      required :code, :symbol, avro: {type: 'string'}
      optional :tags, :array, of: :string, avro: {type: {'type' => 'array', 'items' => 'string'}}
    end
    event = klass.new(raw: {'a' => 'b'}, code: :ok, tags: %w[x y])

    expect(described_class.to_datum(event)).to eq('raw' => {'a' => 'b'}, 'code' => 'ok', 'tags' => %w[x y])
    expect(round_trip(event)).to eq(event)
  end

  it "applies a field's avro: options to its elements and members, and avro: {type:} to struct and union fields" do
    klass = struct('Elem::Order') do
      required :amounts, :array, of: :big_decimal, element: {round: 2}, avro: {precision: 10}
      required :times, :array, of: :time, avro: {timestamp: :millis}
      required :syms, :array, of: :symbol, element: {enum: %i[a b]}, avro: {enum: false}
      required :when, :union, of: %i[time string], avro: {timestamp: :millis}
    end
    fields = described_class.schema(klass)['fields'].to_h { |field| [field['name'], field['type']] }
    expect(fields['amounts']['items']).to eq(['null', {'type' => 'bytes', 'logicalType' => 'decimal', 'precision' => 10, 'scale' => 2}])
    expect(fields['times']['items']).to eq(['null', {'type' => 'long', 'logicalType' => 'timestamp-millis'}])
    expect(fields['syms']['items']).to eq(%w[null string])
    expect(fields['when']).to include({'type' => 'long', 'logicalType' => 'timestamp-millis'})

    order = klass.new(amounts: ['1.25'], times: ['2026-07-01 08:00:00.123'], syms: %i[a], when: '2026-07-01 08:00:00.5')
    expect(round_trip(order)).to eq(order)
    # millis now applies to elements and members, so finer times raise instead of being cut.
    expect { described_class.encode(klass.new(order.to_h.merge(times: ['2026-07-01 08:00:00.123456']))) }
      .to raise_error(ArgumentError, /more precision than timestamp-millis/)
    expect { described_class.encode(klass.new(order.to_h.merge(when: Time.utc(2026, 7, 1, 8, 0, 0.123456r)))) }
      .to raise_error(ArgumentError, /more precision than timestamp-millis/)

    item = struct('Elem::Item') do
      required :sku, :string
      optional :payload, :value
    end
    as_string = %w[string null]
    holder = struct('Elem::Holder') do
      required :item, item, avro: {type: {'type' => 'record', 'name' => 'Ext', 'fields' => [{'name' => 'sku', 'type' => 'string'}, {'name' => 'payload', 'type' => as_string}]}}
      required :id, :union, of: %i[integer string], avro: {type: 'string'}
    end
    fields = described_class.schema(holder)['fields'].to_h { |field| [field['name'], field['type']] }
    expect(fields['item']['name']).to eq('Ext')
    expect(fields['id']).to eq('string')
    value = holder.new(item: {sku: 'a', payload: {'n' => 1}}, id: 'x-1')
    expect(described_class.to_datum(value)).to eq('item' => {'sku' => 'a', 'payload' => '{"n":1}'}, 'id' => 'x-1')
    expect(round_trip(value)).to eq(value)

    # A union overridden to a timestamp holds a Time; its node has no options (no zone: to put back).
    stamp = struct('Elem::Stamp') { required :at, :union, of: %i[time string], avro: {type: {'type' => 'long', 'logicalType' => 'timestamp-micros'}} }
    at = Time.utc(2026, 7, 1, 8)
    expect(round_trip(stamp.new(at: at)).at).to eq(at)

    # A member struct's field overridden to a nullable type can be missing, so it isn't a required key.
    loose = struct('Elem::Loose') { required :tag, Elem::Item, avro: {type: ['null', {'type' => 'record', 'name' => 'Tag', 'fields' => []}]} }
    other = struct('Elem::Other') { required :z, :integer }
    expect { described_class.schema(struct('Elem::Pick') { required :v, :union, of: [loose, other] }) }
      .to raise_error(ArgumentError, /Elem::Loose has no required fields, so any record fits it/)
  end

  it 'passes overridden structs, symbols in arrays and hashes, and zones through correctly' do
    line = struct('Ovr::Line') do
      required :sku, :string
      optional :payload, :value
      optional :seen, :time, zone: 'America/Denver'
    end
    record = described_class.schema(line)
    klass = struct('Ovr::Order') do
      required :lines, :array, of: line, avro: {type: {'type' => 'array', 'items' => record}}
      required :marks, :array, of: :symbol, avro: {type: {'type' => 'array', 'items' => 'string'}}
      required :meta, :value, avro: {type: {'type' => 'map', 'values' => 'string'}}
      required :note, :value, avro: {type: %w[null string]}
      required :at, :time, zone: 'America/Denver', avro: {type: {'type' => 'long', 'logicalType' => 'timestamp-micros'}}
    end
    order = klass.new(lines: [{sku: 'a', payload: {'n' => 1}, seen: '2026-07-01 08:00:00'}], marks: %i[x y], meta: {k: :v}, note: {'n' => 1}, at: '2026-07-01 08:00:00')

    datum = described_class.to_datum(order)
    expect(datum.slice('lines', 'marks', 'meta', 'note'))
      .to match('lines' => [hash_including('sku' => 'a', 'payload' => '{"n":1}')], 'marks' => %w[x y], 'meta' => {'k' => 'v'}, 'note' => '{"n":1}')
    back = round_trip(order)
    expect(back).to eq(klass.new(order.to_h.merge(meta: {'k' => 'v'})))
    expect(back.at.utc_offset).to eq(-6 * 3600)
    expect(back.lines.first.payload).to eq('n' => 1)
    expect(back.lines.first.seen.utc_offset).to eq(-6 * 3600)
  end

  it 'round-trips a :value member of a union as a value, not as JSON text, in either order' do
    first = struct('Mix::ValueFirst') { required :v, :union, of: %i[value integer] }
    last = struct('Mix::ValueLast') { required :v, :union, of: %i[integer value] }

    [first, last].each do |klass|
      [{'a' => [1, 'b']}, 5, 'text', [true, nil]].each do |value|
        back = round_trip(klass.new(v: value))

        expect([back.v, back.v.class]).to eq([value, value.class]), "#{klass}: #{value.inspect} came back as #{back.v.inspect}"
      end
    end
    # Other readers see a long, not the JSON text "5".
    expect(described_class.to_datum(first.new(v: 5))).to eq('v' => 5)
  end

  it 'round-trips a recursive struct' do
    node = struct('Tree::Node') { required :label, :string }
    node.optional :children, :array, of: node
    tree = node.new(label: 'root', children: [{label: 'a', children: [{label: 'a1'}]}, {label: 'b'}])

    expect(round_trip(tree)).to eq(tree)
  end

  it "writes a :value as the same JSON text field_struct's to_json does" do
    line = struct('Vj::Line') { required :sku, :string }
    doc = struct('Vj::Doc') { required :payload, :value }
    value = doc.new(payload: {'t' => Time.utc(2026, 1, 1, 0, 0, 0.5r), 'd' => BigDecimal('1.50'), 'on' => Date.new(2026, 1, 2),
                              's' => :x, 'line' => line.new(sku: 'a'), 'list' => [BigDecimal('2')]})

    text = described_class.to_datum(value)['payload']
    expect(JSON.parse(text)).to eq(JSON.parse(value.to_json)['payload'])
    expect(JSON.parse(text)).to include('t' => '2026-01-01T00:00:00Z', 'd' => '1.5', 'on' => '2026-01-02', 'line' => {'sku' => 'a'}, 'list' => ['2.0'])
    expect(round_trip(value)).to eq(doc.from_json(value.to_json))

    # A struct as the whole :value goes through as_json, not its inspect text.
    expect(described_class.to_datum(doc.new(payload: line.new(sku: 'a')))['payload']).to eq('{"sku":"a"}')
  end

  it 'reads avro: options the same way for the schema and the bytes' do
    stamp = struct('Opt::Stamp') { required :at, :time, avro: {timestamp: :seconds} }
    expect { described_class.to_datum(stamp.new(at: '2026-07-01 08:00:00')) }
      .to raise_error(ArgumentError, /avro: \{timestamp:\} must be one of \[:micros, :nanos, :millis\], got :seconds/)

    [:string, {'type' => 'string'}, {'type' => 'string', 'x-note' => 'raw'}, ['null', :string]].each_with_index do |spelling, index|
      raw = struct("Opt::Raw#{index}") { required :raw, :value, avro: {type: spelling} }
      value = raw.new(raw: {'a' => 1})
      expect(described_class.to_datum(value)).to eq('raw' => '{"a":1}')
      expect(round_trip(value)).to eq(value)
    end

    uuid = struct('Opt::Uuid') { required :id, :value, avro: {type: {'type' => 'string', 'logicalType' => 'uuid'}} }
    expect(described_class.to_datum(uuid.new(id: '5f0c3c8e-0000-4000-8000-000000000000'))).to eq('id' => '5f0c3c8e-0000-4000-8000-000000000000')
  end

  it 'reads bytes written with an older schema, filling new fields from defaults' do
    v1 = struct('Evolve::V1') { required :id, :integer }
    old_schema = described_class.schema(v1)
    bytes = described_class.encode(v1.new(id: 7))
    v2 = struct('Evolve::V2') do
      required :id, :integer
      optional :note, :string
    end
    old_schema = old_schema.merge('name' => 'V2')

    expect(described_class.decode(v2, bytes, writer_schema: old_schema)).to eq(v2.new(id: 7))
    # A registry client hands back a parsed schema.
    expect(described_class.decode(v2, bytes, writer_schema: Avro::Schema.parse(JSON.generate(old_schema)))).to eq(v2.new(id: 7))
    expect { described_class.decode(v2, bytes, writer_schema: :v1) }
      .to raise_error(ArgumentError, /writer_schema: expects a Hash, a JSON String or an Avro::Schema, got Symbol/)
  end

  it "fills fields the writer lacked from field_struct's defaults, even ones Avro can't express" do
    old_line = struct('Defaults::OldLine') { required :sku, :string }
    old = struct('Defaults::Old') do
      required :id, :integer
      required :line, old_line
    end
    bytes = described_class.encode(old.new(id: 7, line: {sku: 'a'}))
    writer = described_class.schema(old)
    writer = writer.merge('name' => 'New', 'fields' => writer['fields'].map do |field|
      field['name'] == 'line' ? field.merge('type' => field['type'].merge('name' => 'NewLine')) : field
    end)

    line = struct('Defaults::NewLine') do
      required :sku, :string
      optional :qty, :big_decimal, round: 2, default: '1.50'
    end
    klass = struct('Defaults::New') do
      required :id, :integer
      required :line, line
      optional :blob, :binary, default: 'abc'
      optional :on, :date, default: Date.new(2020, 1, 1)
      optional :tags, :array, of: :string, default: -> { %w[new] }
      optional :note, :string
      optional :since, :date, default: Date.new(2019, 5, 1)
      serialize :avro, since: 'firstSeen'
    end

    back = described_class.decode(klass, bytes, writer_schema: writer)
    expect(back).to eq(klass.new(id: 7, line: {sku: 'a'}))
    expect(back.attributes).to include(blob: 'abc', on: Date.new(2020, 1, 1), tags: %w[new], note: nil, since: Date.new(2019, 5, 1))
    expect(back.line.qty).to eq(BigDecimal('1.50'))
    # A field the writer had keeps what was written, nil included.
    expect(described_class.decode(klass, described_class.encode(klass.new(id: 1, line: {sku: 'b'}, on: nil)))).to have_attributes(on: nil)

    # A writer union narrowed to one of its structs: the other branch's
    # fields say nothing about what this one wrote.
    card = struct('Defaults::Card') do
      required :x, :string
      optional :note, :string, default: 'none'
    end
    bank = struct('Defaults::Bank') { required :y, :integer }
    either = struct('Defaults::Either') { required :item, :union, of: [card, bank] }
    only = struct('Defaults::Only') { required :item, card }
    bytes = described_class.encode(either.new(item: card.new(x: 'a', note: 'written')))
    back = described_class.decode(only, bytes, writer_schema: described_class.schema(either).merge('name' => 'Only'))
    expect(back.item).to eq(card.new(x: 'a', note: 'written'))

    # One anonymous struct written as two records, only one of which lacked
    # suite: the other's written value stays.
    bare = Class.new(FieldStruct::Base) { required :street, :string }
    full = Class.new(FieldStruct::Base) do
      required :street, :string
      optional :suite, :string, default: 'n/a'
    end
    old_root = struct('Defaults::OldRoot') do
      required :home, bare
      required :work, full
    end
    root = struct('Defaults::Root') do
      required :home, full
      required :work, full
    end
    writer = JSON.parse(JSON.generate(described_class.schema(old_root)).gsub('OldRoot', 'Root'))
    bytes = described_class.encode(old_root.new(home: {street: 'h'}, work: {street: 'w', suite: '5'}))
    back = described_class.decode(root, bytes, writer_schema: writer)
    expect([back.home.suite, back.work.suite]).to eq(['n/a', '5'])
  end

  it 'refuses bytes whose writer schema has another decimal scale or timestamp precision, instead of misreading them' do
    v1 = struct('Evo::Money') { required :amt, :big_decimal, round: 2 }
    v2 = struct('Evo::Money2') { required :amt, :big_decimal, round: 3 }
    bytes = described_class.encode(v1.new(amt: '12.30'))
    writer = described_class.schema(v1).merge('name' => 'Money2')

    expect { described_class.decode(v2, bytes, writer_schema: writer) }
      .to raise_error(ArgumentError, /amt: written as decimal \(scale 2\), read as decimal \(scale 3\)/)

    tick = struct('Evo::Tick') do
      required :at, :time
      optional :log, :array, of: :time
    end
    stamp = tick.new(at: '2026-01-01T00:00:00Z', log: ['2026-01-02T00:00:00Z'])
    micros = described_class.encode(stamp, timestamp: :micros)
    writer = described_class.schema(tick, timestamp: :micros)

    expect { described_class.decode(tick, micros, writer_schema: writer, timestamp: :nanos) }
      .to raise_error(ArgumentError, /at: written as timestamp-micros, read as timestamp-nanos/)
    expect(described_class.decode(tick, micros, writer_schema: writer, timestamp: :micros)).to eq(stamp)
  end

  it 'checks logical types inside arrays, unions and nested records too' do
    line = struct('Evo::Line') { required :price, :big_decimal, round: 2 }
    v1 = struct('Evo::Order') { optional :lines, :array, of: line }
    writer = described_class.schema(v1)
    writer['fields'][0]['type'][1]['items'][1]['fields'][0]['type']['scale'] = 4
    bytes = described_class.encode(v1.new(lines: [{price: '1.25'}]))

    expect { described_class.decode(v1, bytes, writer_schema: writer) }
      .to raise_error(ArgumentError, /lines\[\]\.price: written as .*scale 4/)
  end

  it 'refuses a decimal read as a plain string or the reverse, but lets uuid and string through' do
    exact = struct('Evo::Exact') { required :amt, :big_decimal, round: 2 }
    loose = struct('Evo::Loose') { required :amt, :big_decimal }
    as_decimal = described_class.encode(exact.new(amt: '12.30'))
    as_string = described_class.encode(loose.new(amt: '12.30'))

    expect { described_class.decode(loose, as_decimal, writer_schema: described_class.schema(exact).merge('name' => 'Loose')) }
      .to raise_error(ArgumentError, /amt: written as decimal .*, read as string/)
    expect { described_class.decode(exact, as_string, writer_schema: described_class.schema(loose).merge('name' => 'Exact')) }
      .to raise_error(ArgumentError, /amt: written as string, read as decimal/)

    # uuid has no decoder in the avro gem: the bytes are a plain string either way.
    id = '123e4567-e89b-12d3-a456-426614174000'
    with_uuid = struct('Evo::WithUuid') { required :id, :uuid }
    with_string = struct('Evo::WithString') { required :id, :string }
    bytes = described_class.encode(with_string.new(id: id))
    writer = described_class.schema(with_string).merge('name' => 'WithUuid')
    expect(described_class.decode(with_uuid, bytes, writer_schema: writer)).to eq(with_uuid.new(id: id))
  end

  it "lets a decimal's precision change, and refuses a date read as a time" do
    narrow = struct('Evo::Narrow') { required :amt, :big_decimal, round: 2, avro: {precision: 12} }
    wide = struct('Evo::Wide') { required :amt, :big_decimal, round: 2, avro: {precision: 18} }
    bytes = described_class.encode(narrow.new(amt: '1234567890.12'))
    writer = described_class.schema(narrow).merge('name' => 'Wide')
    expect(described_class.decode(wide, bytes, writer_schema: writer)).to eq(wide.new(amt: '1234567890.12'))

    day = struct('Evo::Day') { required :on, :date }
    moment = struct('Evo::Moment') { required :on, :time }
    bytes = described_class.encode(day.new(on: '2026-10-27'))
    writer = described_class.schema(day).merge('name' => 'Moment')
    expect { described_class.decode(moment, bytes, writer_schema: writer) }
      .to raise_error(ArgumentError, /on: written as date, read as timestamp-micros/)
  end

  it 'checks optional fields the way the avro gem pairs their union branches' do
    day = struct('Opt::Day') { optional :on, :date }
    moment = struct('Opt::Moment') { optional :on, :time }
    bytes = described_class.encode(day.new(on: '2026-10-27'))
    expect { described_class.decode(moment, bytes, writer_schema: described_class.schema(day).merge('name' => 'Moment')) }
      .to raise_error(ArgumentError, /on: written as date, read as timestamp-micros/)

    exact = struct('Opt::Exact') { optional :amt, :big_decimal, round: 2 }
    text = struct('Opt::Text') { optional :amt, :big_decimal }
    bytes = described_class.encode(exact.new(amt: '12.34'))
    expect { described_class.decode(text, bytes, writer_schema: described_class.schema(exact).merge('name' => 'Text')) }
      .to raise_error(ArgumentError, /amt: written as decimal \(scale 2\), read as string/)

    count = struct('Opt::Count') { optional :n, :integer }
    big = struct('Opt::Big') { optional :n, :float }
    bytes = described_class.encode(count.new(n: 7))
    expect(described_class.decode(big, bytes, writer_schema: described_class.schema(count).merge('name' => 'Big'))).to eq(big.new(n: 7.0))
  end

  it 'checks a recursive struct once, and a field that went from optional to required' do
    node = struct('Evo::Node') do
      required :name, :string
      optional :child, self
    end
    tree = node.new(name: 'a', child: {name: 'b'})
    expect(described_class.decode(node, described_class.encode(tree), writer_schema: described_class.schema(node))).to eq(tree)

    before = struct('Evo::Before') { optional :at, :time }
    after = struct('Evo::After') { required :at, :time }
    bytes = described_class.encode(before.new(at: '2026-01-01T00:00:00Z'))
    writer = described_class.schema(before).merge('name' => 'After')
    expect { described_class.decode(after, bytes, writer_schema: writer, timestamp: :nanos) }
      .to raise_error(ArgumentError, /at: written as timestamp-micros, read as timestamp-nanos\. /)
  end

  it 'refuses a time, date or decimal that went from optional to required, which the avro gem fails to decode' do
    {time: [{}, '2026-01-01T00:00:00Z', 'timestamp-micros'], date: [{}, '2026-01-02', 'date'],
     big_decimal: [{round: 2}, '1.25', 'decimal \\(scale 2\\)']}.each do |type, (options, value, described)|
      before = struct("Req::Before#{type}") { optional :v, type, **options }
      after = struct("Req::After#{type}") { required :v, type, **options }
      bytes = described_class.encode(before.new(v: value))
      writer = described_class.schema(before).merge('name' => "After#{type}")

      expect { described_class.decode(after, bytes, writer_schema: writer) }
        .to raise_error(ArgumentError, /v: written as a union with #{described}, read as #{described} outside one/)
    end
    plain_before = struct('Req::Plain') { optional :v, :string }
    plain_after = struct('Req::PlainAfter') { required :v, :string }
    writer = described_class.schema(plain_before).merge('name' => 'PlainAfter')
    expect(described_class.decode(plain_after, described_class.encode(plain_before.new(v: 'x')), writer_schema: writer).v).to eq('x')
  end

  it 'reads avro: {type: nil} as no override, in the datum as in the schema' do
    klass = struct('NoOverride') do
      required :v, :value, avro: {type: nil}
      required :d, :big_decimal, avro: {type: nil}
    end
    instance = klass.new(v: {'a' => 1}, d: '1.5')

    expect(described_class.decode(klass, described_class.encode(instance))).to eq(instance)
    flagged = struct('FalseOverride') { required :v, :value, avro: {type: false} }
    expect { described_class.schema(flagged) }.to raise_error(ArgumentError, /FalseOverride doesn't make a valid Avro schema/)
  end

  it 'round-trips many generated values' do
    klass = struct('Sample') do
      required :i, :integer
      required :d, :big_decimal, round: 3
      required :t, :time
      required :s, :string
      optional :on, :date
    end
    rng = Random.new(RSpec.configuration.seed)
    200.times do
      sample = klass.new(
        i: rng.rand(-(2**63)...(2**63)),
        d: BigDecimal(rng.rand((-10**9)..(10**9))) / 1000,
        t: Time.at(rng.rand(-(2**34)..(2**34)), rng.rand(0...1_000_000), :usec).utc,
        s: Array.new(rng.rand(0..12)) { rng.rand(0x20..0x2FFF).chr(Encoding::UTF_8) }.join,
        on: rng.rand < 0.2 ? nil : Date.jd(rng.rand(2_000_000..2_600_000))
      )

      expect(round_trip(sample)).to eq(sample)
    end
  end

  it 'works through the opt-in methods' do
    klass = struct('Note') do
      include FieldStruct::Avro::Methods

      required :body, :string
    end
    note = klass.new(body: 'hi')

    expect(klass.from_avro(note.to_avro)).to eq(note)
    expect(klass.to_avro_schema).to eq(described_class.schema(klass))
  end
end
