# frozen_string_literal: true

RSpec.describe FieldStruct::Avro::Cache do
  def struct(const_name, &body)
    klass = Class.new(FieldStruct::Base)
    stub_const(const_name, klass)
    klass.class_eval(&body) if body
    klass
  end

  def round_trip(instance)
    FieldStruct::Avro.decode(instance.class, FieldStruct::Avro.encode(instance))
  end

  let(:part) { struct('Inv::Part') { required :sku, :string } }
  let(:box) do
    inner = part
    struct('Inv::Box') do
      required :id, :integer
      required :part, inner
    end
  end

  it 'parses a schema once per class and options' do
    first = FieldStruct::Avro::CACHE.reader(box, :avro, :micros)

    expect(FieldStruct::Avro::CACHE.reader(box, :avro, :micros)).to be(first)
    expect(FieldStruct::Avro::CACHE.reader(box, :avro, :nanos)).not_to be(first)
  end

  it 'builds the schema Hash once, and hands each schema call its own copy' do
    first = FieldStruct::Avro.schema(box)
    allow(FieldStruct::Avro::SchemaBuilder).to receive(:new).and_call_original
    second = FieldStruct::Avro.schema(box)

    expect(FieldStruct::Avro::SchemaBuilder).not_to have_received(:new)
    expect(second).to eq(first)
    second['fields'].first['name'] << '_mine'
    second['fields'] << {'name' => 'extra'}
    expect(FieldStruct::Avro.schema(box)).to eq(first)
    expect(FieldStruct::Avro::CACHE.reader(box, :avro, :micros).schema).to be_frozen

    box.optional :later, :integer
    expect(FieldStruct::Avro.schema(box)['fields'].map { |field| field['name'] }).to eq(%w[id part later])
  end

  it "freezes only the copy it made, never an object of the caller's" do
    mine = Object.new
    copy = FieldStruct::Avro::Cache.deep_freeze(FieldStruct::Avro::Cache.deep_copy({'a' => ['s', mine]}))

    expect([copy, copy['a'], copy['a'][0]]).to all(be_frozen)
    expect(mine).not_to be_frozen
  end

  it 'picks up fields added or re-declared after first use, in the class or a nested one' do
    round_trip(box.new(id: 1, part: {sku: 'a'}))

    box.optional :note, :string
    value = box.new(id: 2, part: {sku: 'b'}, note: 'hi')
    expect(round_trip(value)).to eq(value)

    part.optional :qty, :integer
    expect(round_trip(box.new(id: 3, part: {sku: 'c', qty: 9})).part.qty).to eq(9)

    box.required :id, :string
    expect(round_trip(box.new(id: 'five', part: {sku: 'e'})).id).to eq('five')
  end

  it 'picks up a serialize declared after first use' do
    box.optional :note, :string
    round_trip(box.new(id: 1, part: {sku: 'a'}, note: 'x'))

    box.serialize :avro, note: 'noteText'
    entry = FieldStruct::Avro::CACHE.reader(box, :avro, :micros)
    expect(entry.parsed.fields.map(&:name)).to include('noteText')
    value = box.new(id: 4, part: {sku: 'd'}, note: 'x')
    expect(round_trip(value)).to eq(value)
  end

  it 'keeps one entry per serialization' do
    box.serialize :api, id: 'boxId'
    value = box.new(id: 1, part: {sku: 'a'})
    FieldStruct::Avro.encode(value)

    expect(FieldStruct::Avro::CACHE.reader(box, :api, :micros).parsed.fields.map(&:name)).to eq(%w[boxId part])
    expect(FieldStruct::Avro.decode(box, FieldStruct::Avro.encode(value, serialization: :api), serialization: :api)).to eq(value)
  end

  it 'stamps a class before reading it, so a change made while the schema is built is noticed' do
    builder = FieldStruct::Avro::SchemaBuilder.new(box, serialization: :avro, timestamp: :micros)
    allow(FieldStruct::Avro::SchemaBuilder).to receive(:new).and_return(builder)
    allow(builder).to receive(:schema).and_wrap_original do |original|
      original.call.tap { box.optional :late, :string }
    end
    FieldStruct::Avro::CACHE.reader(box, :avro, :nanos)
    allow(FieldStruct::Avro::SchemaBuilder).to receive(:new).and_call_original

    expect(FieldStruct::Avro::CACHE.reader(box, :avro, :nanos).parsed.fields.map(&:name)).to include('late')
  end

  it 'renames the record of an anonymous struct once it is assigned to a constant' do
    anon = Class.new(FieldStruct::Base) { required :v, :integer }
    holder = struct('Inv::Holder') { required :thing, anon }
    FieldStruct::Avro.encode(holder.new(thing: {v: 1}))

    stub_const('Inv::Thing', anon)
    expect(FieldStruct::Avro::CACHE.reader(holder, :avro, :micros).parsed.fields[0].type.name).to eq('Thing')
  end

  it 'keeps a checked writer schema per reader, and rechecks it when the reader changes' do
    old = JSON.generate(FieldStruct::Avro.schema(box))
    bytes = FieldStruct::Avro.encode(box.new(id: 1, part: {sku: 'a'}))
    box.optional :extra, :integer, default: 7

    expect(FieldStruct::Avro.decode(box, bytes, writer_schema: old).extra).to eq(7)
    entry = FieldStruct::Avro::CACHE.reader(box, :avro, :micros)
    expect(FieldStruct::Avro::CACHE.writer(old.dup, entry)).to be(FieldStruct::Avro::CACHE.writer(old, entry))

    box.optional :later, :date, default: Date.new(2020, 1, 1)
    expect(FieldStruct::Avro.decode(box, bytes, writer_schema: old)).to have_attributes(extra: 7, later: Date.new(2020, 1, 1))
  end

  it 'keeps the properties Datum walks, and picks up a field or serialize added later' do
    first = FieldStruct::Avro::CACHE.properties(box, :avro)
    expect(FieldStruct::Avro::CACHE.properties(box, :avro)).to be(first)

    box.optional :note, :string
    expect(FieldStruct::Avro.to_datum(box.new(id: 1, part: {sku: 'a'}, note: 'x'))).to include('note' => 'x')
    box.serialize :avro, note: 'noteText'
    expect(FieldStruct::Avro.to_datum(box.new(id: 1, part: {sku: 'a'}, note: 'x'))).to include('noteText' => 'x')
    part.optional :qty, :integer
    expect(FieldStruct::Avro.from_datum(box, {'id' => 1, 'part' => {'sku' => 'a', 'qty' => 2}, 'noteText' => nil}).part.qty).to eq(2)
  end

  it 'stamps the properties before reading them, so a field added meanwhile is seen next time' do
    added = false
    allow(FieldStruct::Introspection).to receive(:properties).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap do
        box.optional :late, :string unless added
        added = true
      end
    end
    FieldStruct::Avro::CACHE.properties(box, :avro)
    allow(FieldStruct::Introspection).to receive(:properties).and_call_original

    expect(FieldStruct::Avro::CACHE.properties(box, :avro).map(&:key)).to include('late')
  end

  it 'agrees across threads' do
    value = box.new(id: 1, part: {sku: 'a'})

    results = Array.new(8) { Thread.new { Array.new(100) { round_trip(value) == value }.all? } }.map(&:value)
    expect(results).to all(be(true))
  end
end
