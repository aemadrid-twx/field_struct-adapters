# frozen_string_literal: true

RSpec.describe FieldStruct::Avro, '.schema' do
  # Build a named FieldStruct subclass without leaking a top-level constant.
  def struct(const_name, &body)
    klass = Class.new(FieldStruct::Base)
    stub_const(const_name, klass)
    klass.class_eval(&body) if body
    klass
  end

  # Every schema must be one the avro gem accepts, with default validation.
  def schema_of(klass, **options)
    schema = described_class.schema(klass, **options)
    Avro::Schema.parse(JSON.generate(schema))
    schema
  end

  def field_type(klass, name, **options)
    schema_of(klass, **options)['fields'].find { |field| field['name'] == name.to_s }['type']
  end

  it 'names the record after the class, its modules as the namespace' do
    klass = struct('Billing::Invoice') { required :id, :integer }

    expect(schema_of(klass)).to eq(
      'type' => 'record', 'name' => 'Invoice', 'namespace' => 'Billing',
      'fields' => [{'name' => 'id', 'type' => 'long'}]
    )
  end

  it 'maps each built-in type without losing precision' do
    klass = struct('Everything') do
      required :s, :string
      required :i, :integer
      required :f, :float
      required :b, :boolean
      required :bin, :binary
      required :money, :big_decimal, round: 2
      required :ratio, :big_decimal
      required :on, :date
      required :at, :time
      required :dt, :datetime
      required :id, :uuid
      required :code, :uuid, format: /\A[a-z]+\z/
      required :doc, :value
      required :mail, :email
    end
    types = schema_of(klass)['fields'].to_h { |field| [field['name'], field['type']] }

    expect(types).to eq(
      's' => 'string', 'i' => 'long', 'f' => 'double', 'b' => 'boolean', 'bin' => 'bytes',
      'money' => {'type' => 'bytes', 'logicalType' => 'decimal', 'precision' => 38, 'scale' => 2},
      'ratio' => 'string',
      'on' => {'type' => 'int', 'logicalType' => 'date'},
      'at' => {'type' => 'long', 'logicalType' => 'timestamp-micros'},
      'dt' => {'type' => 'long', 'logicalType' => 'timestamp-micros'},
      'id' => {'type' => 'string', 'logicalType' => 'uuid'},
      'code' => 'string', 'doc' => 'string', 'mail' => 'string'
    )
  end

  it 'makes optional fields nullable with a null default, and keeps a literal default first' do
    klass = struct('Plan') do
      optional :note, :string
      optional :tier, :string, default: 'free'
      required :seats, :integer, default: 1
    end
    fields = schema_of(klass)['fields']

    expect(fields).to eq([
      {'name' => 'note', 'type' => %w[null string], 'default' => nil},
      {'name' => 'tier', 'type' => %w[string null], 'default' => 'free'},
      {'name' => 'seats', 'type' => 'long', 'default' => 1}
    ])
  end

  it 'turns a symbol enum into an Avro enum, and falls back to string when the symbols are not Avro names' do
    klass = struct('Ticket') do
      required :status, :symbol, enum: %i[open closed], default: :open
      required :stage, :symbol, enum: %i[in-progress done]
      required :kind, :symbol, enum: %i[bug task], avro: {enum: false}
      required :level, :symbol, enum: %i[low high], avro: {enum_default: :low}
    end
    fields = schema_of(klass)['fields'].to_h { |field| [field['name'], field] }

    expect(fields['status']).to eq(
      'name' => 'status', 'default' => 'open',
      'type' => {'type' => 'enum', 'name' => 'Ticket_status', 'symbols' => %w[open closed]}
    )
    expect(fields['stage']['type']).to eq('string')
    expect(fields['kind']['type']).to eq('string')
    expect(fields['level']['type']).to include('default' => 'low')
  end

  it 'lets every array element be null' do
    klass = struct('Tags') { required :tags, :array, of: :string }

    expect(field_type(klass, :tags)).to eq('type' => 'array', 'items' => %w[null string])
  end

  it 'defines a nested struct once and refers to it after, so recursion works' do
    node = struct('Tree::Node') { required :label, :string }
    node.optional :children, :array, of: node
    node.optional :parent, node

    fields = schema_of(node)['fields'].to_h { |field| [field['name'], field['type']] }

    expect(fields['children']).to eq(%w[null] + [{'type' => 'array', 'items' => ['null', 'Tree.Node']}])
    expect(fields['parent']).to eq(['null', 'Tree.Node'])
  end

  it 'names an anonymous nested struct after its record and field' do
    address = Class.new(FieldStruct::Base) { required :city, :string }
    klass = struct('Person') { optional :home, address }

    expect(field_type(klass, :home)).to eq(['null', {'type' => 'record', 'name' => 'Person_home', 'fields' => [{'name' => 'city', 'type' => 'string'}]}])
  end

  it 'puts long before double in a union, and refuses members that land on one Avro type' do
    klass = struct('Amount') { required :value, :union, of: %i[float integer] }

    expect(field_type(klass, :value)).to eq(%w[long double])
    clash = struct('Clash') { required :value, :union, of: %i[string uuid] }
    expect { described_class.schema(clash) }.to raise_error(ArgumentError, /two union members both become Avro string/)
    bytes = struct('Bytes') { required :value, :union, of: %i[string binary] }
    expect { described_class.schema(bytes) }.to raise_error(ArgumentError, /both become Avro string/)
  end

  it 'carries description as doc and sensitive as x-fs-sensitive' do
    klass = struct('Card') { required :pan, :string, desc: 'Card number', sensitive: true }

    expect(schema_of(klass)['fields']).to eq([{'name' => 'pan', 'doc' => 'Card number', 'type' => 'string', 'x-fs-sensitive' => true}])
  end

  it 'uses serialize names, and refuses one Avro cannot use' do
    klass = struct('Contact') do
      required :first_name, :string
      serialize :avro, first_name: 'firstName'
      serialize :json, first_name: 'first-name'
    end

    expect(schema_of(klass)['fields'].map { |field| field['name'] }).to eq(['firstName'])
    expect { described_class.schema(klass, serialization: :json) }.to raise_error(ArgumentError, /"first-name", which Avro names can't be/)
  end

  it 'honours timestamp:, a field avro: override, and refuses what it cannot map' do
    klass = struct('Event') do
      required :at, :time
      required :seen, :time, avro: {timestamp: :millis}
      required :raw, :value, avro: {type: {'type' => 'map', 'values' => 'string'}}
      required :cents, :big_decimal, round: 2, avro: {precision: 12}
    end
    types = schema_of(klass, timestamp: :nanos)['fields'].to_h { |field| [field['name'], field['type']] }

    expect(types['at']).to include('logicalType' => 'timestamp-nanos')
    expect(types['seen']).to include('logicalType' => 'timestamp-millis')
    expect(types['raw']).to eq('type' => 'map', 'values' => 'string')
    expect(types['cents']).to include('precision' => 12, 'scale' => 2)
    expect { described_class.schema(klass, timestamp: :seconds) }.to raise_error(ArgumentError, /timestamp: must be one of/)
    grid = struct('Grid') { required :rows, :array, of: :array }
    expect { described_class.schema(grid) }.to raise_error(ArgumentError, /records no element type/)
    expect { described_class.schema(Class.new(FieldStruct::Base)) }.to raise_error(ArgumentError, /needs a named class/)
  end
end
