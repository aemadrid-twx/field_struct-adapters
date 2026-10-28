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
    expect(round_trip(tick, timestamp: :nanos).at.nsec).to eq(123_456_789)
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

  it 'round-trips a recursive struct' do
    node = struct('Tree::Node') { required :label, :string }
    node.optional :children, :array, of: node
    tree = node.new(label: 'root', children: [{label: 'a', children: [{label: 'a1'}]}, {label: 'b'}])

    expect(round_trip(tree)).to eq(tree)
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
