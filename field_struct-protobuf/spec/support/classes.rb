# frozen_string_literal: true

# Classes register their messages in google-protobuf's process-wide pool, so
# each spec class is defined once, here.
module PbSpec
  module Billing
    class Address < FieldStruct::Base
      required :city, :string, proto: {number: 1}
      optional :zip, :string, proto: {number: 2}
    end

    class Invoice < FieldStruct::Base
      required :id, :uuid, proto: {number: 1}
      required :total, :big_decimal, round: 2, proto: {number: 2}
      required :at, :time, zone: 'America/Denver', proto: {number: 3}
      required :status, :symbol, enum: %i[open paid], proto: {number: 4}
      optional :tags, :array, of: :string, proto: {number: 5}
      optional :count, :integer, proto: {number: 6}
      optional :paid, :boolean, proto: {number: 7}
      optional :ship_to, Address, proto: {number: 8}
      optional :meta, :value, proto: {number: 9}
      optional :due_on, :date, proto: {number: 10}
      optional :blob, :binary, proto: {number: 11}
      optional :ratio, :float, proto: {number: 12}
      optional :homes, :array, of: Address, proto: {number: 13}
      optional :previous, Invoice, proto: {number: 14}
    end
  end

  class Renamed < FieldStruct::Base
    required :order_id, :string, proto: {number: 1}
    serialize :protobuf, order_id: 'orderId'
  end

  class Unnumbered < FieldStruct::Base
    required :a, :string, proto: {number: 1}
    required :b, :string
  end

  class Twice < FieldStruct::Base
    required :a, :string, proto: {number: 1}
    required :b, :string, proto: {number: 1}
  end

  class Reserved < FieldStruct::Base
    required :a, :string, proto: {number: 19_500}
  end

  class WithUnion < FieldStruct::Base
    required :ref, :union, of: %i[integer string], proto: {number: 1}
  end

  class BadName < FieldStruct::Base
    required :a, :string, proto: {number: 1}
    serialize :protobuf, a: 'a-b'
  end

  class Ping < FieldStruct::Base
    optional :pong, Pong, proto: {number: 1} if defined?(Pong)
  end

  class Pong < FieldStruct::Base
    optional :ping, Ping, proto: {number: 1}
  end
  Ping.optional :pong, Pong, proto: {number: 1}
end
