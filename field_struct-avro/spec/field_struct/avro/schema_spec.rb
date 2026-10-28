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

  it 'gives a top-level class nested in a namespace the namespace Avro gives it, so the schema parses' do
    line = struct('Line') { required :sku, :string }
    thing = struct('Other::Thing') { required :line, line }
    invoice = struct('Billing::Invoice') do
      required :line, line
      required :thing, thing
    end

    schema = schema_of(invoice) # parses
    expect(schema['fields'][0]['type']).to include('name' => 'Line', 'namespace' => 'Billing')
    expect(schema['fields'][1]['type']['fields'][0]['type']).to eq('Billing.Line')
    bytes = described_class.encode(invoice.new(line: {sku: 'a'}, thing: {line: {sku: 'b'}}))
    expect(described_class.decode(invoice, bytes)).to eq(invoice.new(line: {sku: 'a'}, thing: {line: {sku: 'b'}}))
  end

  it "refuses what Avro names can't say: a namespace-less type from inside a namespace, or two classes on one name" do
    line = struct('Line') { required :sku, :string }
    thing = struct('Other::Thing') { required :line, line }
    order = struct('Order') do
      required :line, line
      required :thing, thing
    end
    expect { described_class.schema(order) }
      .to raise_error(ArgumentError, /Line has no namespace and is used inside Other::Thing/)

    billing_line = struct('Billing::Line') { required :cents, :integer }
    both = struct('Billing::Both') do
      required :mine, billing_line
      required :top, line
    end
    expect { described_class.schema(both) }.to raise_error(ArgumentError, /Line and Billing::Line both become Avro Billing\.Line/)

    holder = struct('Outer') { required :x, :symbol, enum: %i[a b] }
    struct('Outer_x') { required :n, :integer }
    holder.required :y, Outer_x
    expect { described_class.schema(holder) }.to raise_error(ArgumentError, /Outer_x and an enum both become Avro Outer_x/)
  end

  it 'refuses an anonymous record and an enum that land on the same name, in either order' do
    member = Class.new(FieldStruct::Base) { required :n, :integer }
    enum_first = struct('Clash::EnumFirst') do
      required :x_0, :symbol, enum: %i[a b]
      required :x, :union, of: [member, :string]
    end
    expect { described_class.schema(enum_first) }
      .to raise_error(ArgumentError, /an anonymous struct and an enum both become Avro Clash\.EnumFirst_x_0; rename one of the fields/)

    record_first = struct('Clash::RecordFirst') do
      required :x, :union, of: [member, :string]
      required :x_0, :symbol, enum: %i[a b]
    end
    expect { described_class.schema(record_first) }
      .to raise_error(ArgumentError, /an enum and an anonymous struct both become Avro Clash\.RecordFirst_x_0/)

    reused = struct('Clash::Reused') do
      required :x_0, member
      required :x, :union, of: [member, :string]
    end
    expect(described_class.schema(reused)['fields'].last['type']).to eq(['Clash.Reused_x_0', 'string'])
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

  it 'only emits decimals the avro gem accepts' do
    tens = struct('Tens') { required :n, :big_decimal, round: -1 }
    wide = struct('Wide') { required :n, :big_decimal, round: 40 }
    narrow = struct('Narrow') { required :n, :big_decimal, round: 2, avro: {precision: 0} }

    # round: -1 leaves no fractional digits, which scale 0 holds exactly.
    expect(field_type(tens, :n)).to include('scale' => 0)
    expect(FieldStruct::Avro.decode(tens, FieldStruct::Avro.encode(tens.new(n: '123')))).to eq(tens.new(n: '123'))
    expect { described_class.schema(wide) }.to raise_error(ArgumentError, /Wide_n: scale 40 is more than precision 38/)
    expect { described_class.schema(narrow) }.to raise_error(ArgumentError, /Narrow_n: precision 0 must be at least 1/)
    # Scale may equal precision: every digit is fractional.
    expect(field_type(struct('Edge') { required :n, :big_decimal, avro: {precision: 2, scale: 2} }, :n))
      .to include('precision' => 2, 'scale' => 2)
    expect { described_class.schema(struct('Text') { required :n, :big_decimal, round: 2, avro: {precision: '12'} }) }
      .to raise_error(ArgumentError, /Text_n: decimal precision and scale must be integers, got "12" and 2/)
  end

  it 'writes a float default as a double, even when given as an integer' do
    klass = struct('Ratio') do
      optional :ratio, :float, default: 1
      optional :share, :float, default: 0.25
    end

    defaults = schema_of(klass)['fields'].map { |field| field['default'] }
    expect(defaults).to eq([1.0, 0.25])
    expect(defaults.first).to be_a(Float)
  end

  it 'refuses a union of structs where an earlier one would swallow a later one' do
    small = struct('Pay::Small') { required :a, :string }
    big = struct('Pay::Big') do
      required :a, :string
      required :b, :string
    end
    loose = struct('Pay::Loose') do
      required :a, :string
      optional :c, :string
    end
    card = struct('Pay::Card') { required :number, :string }
    bank = struct('Pay::Bank') { required :number, :integer }

    # Avro writes the first branch a datum fits, and a record ignores extra
    # keys, so a Big would be written as a Small and lose b.
    swallow = struct('Pay::Swallow') { required :v, :union, of: [small, big] }
    expect { described_class.schema(swallow) }
      .to raise_error(ArgumentError, /Pay::Big would be written as Pay::Small.*or put Pay::Big first/)
    # An optional field can be missing, so a Small fits Loose.
    optional = struct('Pay::Optional') { required :v, :union, of: [loose, small] }
    expect { described_class.schema(optional) }
      .to raise_error(ArgumentError, /Pay::Small would be written as Pay::Loose/)
    # The same keys can't be told apart on the way back either.
    same = struct('Pay::Same') { required :v, :union, of: [card, bank] }
    expect { described_class.schema(same) }.to raise_error(ArgumentError, /Pay::Bank would be written as Pay::Card.*distinct required fields\z/)

    # A field overridden to a nullable type can be missing, like an optional one.
    nullable = struct('Pay::Nullable') { required :a, :string, avro: {type: %w[null string]} }
    other = struct('Pay::Other') { required :z, :integer }
    expect { described_class.schema(struct('Pay::Override') { required :v, :union, of: [nullable, other] }) }
      .to raise_error(ArgumentError, /Pay::Nullable has no required fields, so any record fits it/)

    # The other order is fine: a Small datum lacks b, so it doesn't fit Big.
    expect(field_type(struct('Pay::Ok') { required :v, :union, of: [big, small] }, :v).map { |t| t.is_a?(Hash) ? t['name'] : t })
      .to eq(%w[Big Small])
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
