# frozen_string_literal: true

# Rules that the rest of the suite left unpinned (a mutation-testing pass found
# each one survived a change to the code).
RSpec.describe FieldStruct::Avro, 'edge cases' do
  def struct(const_name, &body)
    klass = Class.new(FieldStruct::Base)
    stub_const(const_name, klass)
    klass.class_eval(&body) if body
    klass
  end

  def round_trip(instance)
    described_class.decode(instance.class, described_class.encode(instance))
  end

  it 'refuses FieldStruct::Base itself' do
    expect { described_class.schema(FieldStruct::Base) }
      .to raise_error(ArgumentError, /expects a FieldStruct::Base subclass, got FieldStruct::Base/)
  end

  it 'refers to a namespace-less struct by name again, from a namespace-less record' do
    address = struct('Address') { required :city, :string }
    order = struct('Order') do
      required :billing, address
      required :shipping, address
    end
    node = struct('Node') { required :label, :string }
    node.optional :next, node

    types = described_class.schema(order)['fields'].map { |field| field['type'] }
    expect(types[0]).to include('type' => 'record', 'name' => 'Address')
    expect(types[1]).to eq('Address')
    expect(described_class.schema(node)['fields'][1]['type']).to eq(%w[null Node])
    instance = order.new(billing: {city: 'a'}, shipping: {city: 'b'})
    expect(round_trip(instance)).to eq(instance)
  end

  it 'leaves out a float default that JSON cannot carry' do
    klass = struct('Ratios') do
      required :up, :float, default: Float::INFINITY
      required :nan, :float, default: Float::NAN
    end

    schema = described_class.schema(klass)
    expect(schema['fields'].map { |field| field.key?('default') }).to eq([false, false])
    expect { JSON.generate(schema) }.not_to raise_error
  end

  it 'makes an optional field with a nullable avro: {type:} nullable once, null first' do
    klass = struct('Overrides') do
      optional :a, :string, avro: {type: %w[null string]}
      optional :b, :string, avro: {type: %w[string null]}
    end

    types = described_class.schema(klass)['fields'].map { |field| field['type'] }
    expect(types).to eq([%w[null string], %w[null string]])
    instance = klass.new(a: 'x')
    expect(round_trip(instance)).to eq(instance)
  end

  it 'keeps every value under a sensitive struct field out of the errors, the inner struct named or not (R30)' do
    stamp = struct('Stamp') { required :at, :time }
    status = struct('Status') { required :s, :symbol, enum: %i[open paid] }
    anonymous = Class.new(FieldStruct::Base) { required :at, :time }
    vault = struct('Vault') do
      required :stamp, stamp, sensitive: true
      required :status, status, sensitive: true
      optional :loose, anonymous, sensitive: true
    end
    late = '2026-01-01T00:00:00.000000001Z'

    expect { described_class.to_datum(vault.new(stamp: {at: late}, status: {s: :open})) }
      .to raise_error(ArgumentError, /\AFieldStruct::Avro: Stamp#at is a sensitive time, which/)
    expect { described_class.to_datum(vault.new(stamp: {at: Time.at(0)}, status: {s: :open}, loose: {at: late})) }
      .to raise_error(ArgumentError, /\AFieldStruct::Avro: Vault#loose\.at is a sensitive time, which/)
    datum = described_class.to_datum(vault.new(stamp: {at: Time.at(0)}, status: {s: :open}))
    expect { described_class.from_datum(vault, datum.merge('status' => {'s' => 'void'})) }
      .to raise_error(ArgumentError, /\AFieldStruct::Avro: Status#s is a sensitive symbol, which/)

    plain = struct('Plain') { required :status, status }
    expect { described_class.from_datum(plain, {'status' => {'s' => 'void'}}) }
      .to raise_error(ArgumentError, /\AFieldStruct::Avro: Status#s is :void, which/)
  end

  it "keeps a sensitive time inside an anonymous struct out of the precision error, whatever the holder field's sensitivity" do
    inner = Class.new(FieldStruct::Base) { required :at, :time, sensitive: true }
    holder = struct('Holder') { required :inner, inner }
    instance = holder.new(inner: {at: '2026-10-25T21:55:12.123456789Z'})

    expect { described_class.encode(instance) }.to raise_error(ArgumentError) { |error|
      expect(error.message).to include('Holder#inner.at is a sensitive time')
      expect(error.message).not_to include('2026')
    }
  end

  it 'reads a :value back as plain JSON data: decimals as BigDecimal, never as Oj objects' do
    klass = struct('Carrier') { optional :payload, :value }

    expect(round_trip(klass.new(payload: {'n' => 2.5})).payload['n']).to be_a(BigDecimal)
    # Bytes from another writer: Oj's default (object) mode would build an Object from "^o".
    datum = described_class.to_datum(klass.new(payload: {}))
    datum['payload'] = '{"^o":"Object","^i":1}'
    expect(described_class.from_datum(klass, datum).payload).to eq('^o' => 'Object', '^i' => 1)
  end

  it 'keeps at most WRITERS_MAX checked writer schemas' do
    klass = struct('Bounded') { required :id, :integer }
    entry = FieldStruct::Avro::CACHE.reader(klass, :avro, :micros)
    base = described_class.schema(klass)
    (FieldStruct::Avro::Cache::WRITERS_MAX + 1).times do |index|
      FieldStruct::Avro::CACHE.writer(base.merge('doc' => "v#{index}"), entry)
    end

    expect(FieldStruct::Avro::CACHE.instance_variable_get(:@writers).size).to be <= FieldStruct::Avro::Cache::WRITERS_MAX
  end
end
