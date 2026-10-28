# frozen_string_literal: true

module ToolSpecs
  # The refunds RefundOrder made: it stands in for any action with side effects.
  def self.refunds
    @refunds ||= []
  end

  class Address < FieldStruct::Base
    required :city, :string
  end

  class RefundOrder < Actionable::Action
    input do
      required :order_id, :string, description: 'The order to refund'
      required :amount, :big_decimal, in: 0.01..500
      optional :reason, :string, enum: %w[damaged late]
      required :user_id, :integer
      optional :ship_to, Address
    end

    output do
      required :refund_id, :string
      optional :amount, :big_decimal
      optional :ship_to, Address
    end

    fails :over_limit, kind: :rejected
    skips :already_refunded

    step :refund

    def refund
      return fail!(:over_limit, 'refunds over 100 need a person') if input.amount > 100
      return skip!(:already_refunded) if input.order_id == 'dup'

      ToolSpecs.refunds << {order_id: input.order_id, amount: input.amount, user_id: input.user_id}
      @refund_id = "rf_#{input.order_id}"
      @amount = input.amount
      @ship_to = input.ship_to
    end
  end

  # No input schema: can't be a tool.
  class FreeForm < Actionable::Action
    step :noop

    def noop
    end
  end

  class Sale < FieldStruct::Base
    required :kind, :string
  end

  # A discriminated input: no single schema.
  class Dispatched < Actionable::Action
    input_for(:kind) { on 'sale', Sale }
    step :noop

    def noop
    end
  end

  # Free-form output.
  class Ping < Actionable::Action
    input { optional :echo, :string }
    step :pong

    def pong
      succeed(echo: input.echo)
    end
  end
end
