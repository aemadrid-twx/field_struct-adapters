# frozen_string_literal: true

RSpec.describe FieldStruct::JSONSchema::Cache do
  def struct(const_name, &body)
    klass = Class.new(FieldStruct::Base)
    klass.class_eval(&body) if body
    stub_const(const_name, klass)
    klass
  end

  def generate(klass, **options) = FieldStruct::JSONSchema.generate(klass, **options)

  let(:part) { struct('JInv::Part') { required :sku, :string } }
  let(:box) do
    inner = part
    struct('JInv::Box') do
      required :id, :integer
      required :part, inner
    end
  end

  it 'builds once, and still hands every caller its own unfrozen copy' do
    first = generate(box)
    first['properties']['id']['type'] = 'string'
    first['required'] << 'mutated'
    second = generate(box)

    expect(second['properties']['id']).to eq('type' => 'integer')
    expect(second['required']).to eq(%w[id part])
    expect(second).not_to be_frozen
    expect(second['properties']['id']['type']).not_to be_frozen
    expect(FieldStruct::JSONSchema::CACHE.schema(box, :json)).to be(FieldStruct::JSONSchema::CACHE.schema(box, :json))
  end

  it 'picks up fields added or re-declared later, in the class or a nested one, and a later serialize' do
    generate(box)

    box.optional :note, :string
    expect(generate(box)['properties'].keys).to eq(%w[id part note])
    part.optional :qty, :integer
    expect(generate(box)['$defs']['JInv::Part']['properties'].keys).to eq(%w[sku qty])
    box.required :id, :string
    expect(generate(box)['properties']['id']).to eq('type' => 'string')
    box.serialize :json, note: 'noteText'
    expect(generate(box)['properties'].keys).to include('noteText')
  end

  it 'picks up unknown_attributes set later, and an anonymous struct that gets a name' do
    anon = Class.new(FieldStruct::Base) { required :v, :integer }
    holder = struct('JInv::Holder') { required :thing, anon }
    expect(generate(holder)['$defs']).to be_nil

    holder.unknown_attributes :raise
    expect(generate(holder)['additionalProperties']).to be(false)
    stub_const('JInv::Thing', anon)
    expect(generate(holder)['$defs'].keys).to eq(['JInv::Thing'])
  end

  it "doesn't keep a schema that asked a type's own json_schema method" do
    calls = 0
    money = Class.new(FieldStruct::Types::Base) do
      define_method(:coerce) { |value, **| value }
      define_method(:ruby_type) { Rational }
      define_method(:json_schema) { {'type' => 'string', 'description' => "call #{calls += 1}"} }
    end
    ledger = struct('JInv::Ledger') { required :amount, money }

    expect(generate(ledger)['properties']['amount']['description']).to eq('call 1')
    expect(generate(ledger)['properties']['amount']['description']).to eq('call 2')
  end

  it 'agrees across threads' do
    expected = generate(box)

    results = Array.new(8) { Thread.new { Array.new(100) { generate(box) == expected }.all? } }.map(&:value)
    expect(results).to all(be(true))
  end
end
