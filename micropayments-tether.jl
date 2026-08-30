# TETHER MICROPAY — PURE JULIA

```julia
module TetherMicroPay

using Dates
using UUIDs
using SHA
using Printf


# ============================================================
# TETHER MICROPAY
#
# Pure Julia USDT micropayment engine.
#
# Architecture:
#
#   USER
#     │
#     ▼
#   WALLET
#     │
#     ▼
#   PAYMENT INTENT
#     │
#     ▼
#   RISK / VALIDATION
#     │
#     ▼
#   INTERNAL LEDGER
#     │
#     ▼
#   SETTLEMENT ROUTER
#     │
#     ├── Ethereum
#     ├── Tron
#     ├── Solana
#     ├── TON
#     └── other supported networks
#
# This implementation is an accounting/simulation layer.
# It does NOT hold private keys or broadcast real blockchain
# transactions.
#
# Production deployment would require:
#   - audited cryptography
#   - secure key management
#   - RPC/node integration
#   - transaction confirmation
#   - durable database
#   - AML/KYC/compliance controls where applicable
# ============================================================


# ============================================================
# USDT DENOMINATION
# ============================================================

"""
USDT is represented internally using integer base units.

USDT normally uses 6 decimal places on common token
implementations.

Example:

    1 USDT
        = 1_000_000 units

    0.001 USDT
        = 1_000 units
"""
const USDT_DECIMALS = 6
const USDT_UNIT = Int64(1_000_000)


struct USDT

    units::Int64
end


USDT(x::Integer) =
    USDT(Int64(x))


function USDT(amount::Real)

    USDT(
        round(
            Int64,
            amount *
            USDT_UNIT
        )
    )
end


Base.:+(a::USDT, b::USDT) =
    USDT(
        a.units +
        b.units
    )


Base.:-(a::USDT, b::USDT) =
    USDT(
        a.units -
        b.units
    )


Base.:*(a::USDT, b::Integer) =
    USDT(
        a.units *
        b
    )


Base.isless(a::USDT, b::USDT) =
    a.units < b.units


Base.:(==)(a::USDT, b::USDT) =
    a.units == b.units


function usdt_string(
    value::USDT
)

    sign =
        value.units < 0 ?
        "-" :
        ""

    absolute =
        abs(
            value.units
        )

    whole =
        absolute ÷ USDT_UNIT

    fraction =
        absolute %
        USDT_UNIT

    @sprintf(
        "%s%d.%06d USDT",
        sign,
        whole,
        fraction
    )
end


# ============================================================
# NETWORK
# ============================================================

@enum USDTNetwork begin

    ETHEREUM

    TRON

    SOLANA

    TON

    AVALANCHE

    CELO

    APTOS

    NEAR
end


function network_name(
    network::USDTNetwork
)

    string(network)
end


# ============================================================
# WALLET
# ============================================================

mutable struct Wallet

    id::UUID

    owner::String

    network::USDTNetwork

    address::String

    balance::USDT

    locked::USDT

    enabled::Bool

    created_at::DateTime
end


function Wallet(
    owner::String,
    network::USDTNetwork,
    address::String;
    balance=USDT(0)
)

    Wallet(
        uuid4(),
        owner,
        network,
        address,
        balance,
        USDT(0),
        true,
        now()
    )
end


# ============================================================
# MERCHANT
# ============================================================

mutable struct Merchant

    id::UUID

    name::String

    wallet_id::UUID

    enabled::Bool

    total_revenue::USDT

    transaction_count::Int
end


# ============================================================
# PAYMENT STATUS
# ============================================================

@enum PaymentStatus begin

    CREATED

    AUTHORIZED

    SETTLED

    FAILED

    REFUNDED

    EXPIRED
end


# ============================================================
# PAYMENT
# ============================================================

mutable struct Payment

    id::UUID

    idempotency_key::String

    sender_wallet::UUID

    receiver_wallet::UUID

    merchant_id::Union{UUID,Nothing}

    network::USDTNetwork

    amount::USDT

    fee::USDT

    total_debit::USDT

    status::PaymentStatus

    reference::String

    created_at::DateTime

    authorized_at::Union{DateTime,Nothing}

    settled_at::Union{DateTime,Nothing}

    metadata::Dict{String,String}

    digest::String
end


# ============================================================
# LEDGER
# ============================================================

struct LedgerEntry

    id::UUID

    timestamp::DateTime

    wallet_id::UUID

    payment_id::UUID

    amount::USDT

    direction::Symbol

    balance_after::USDT

    description::String
end


# ============================================================
# AUDIT
# ============================================================

struct AuditEvent

    timestamp::DateTime

    event::Symbol

    message::String
end


mutable struct AuditLog

    events::Vector{AuditEvent}
end


AuditLog() =
    AuditLog(
        AuditEvent[]
    )


function audit!(
    log::AuditLog,
    event::Symbol,
    message::String
)

    push!(
        log.events,
        AuditEvent(
            now(),
            event,
            message
        )
    )
end


# ============================================================
# SETTLEMENT TRANSACTION
# ============================================================

mutable struct Settlement

    id::UUID

    payment_id::UUID

    network::USDTNetwork

    from_address::String

    to_address::String

    amount::USDT

    blockchain_fee::USDT

    tx_hash::Union{String,Nothing}

    confirmations::Int

    confirmed::Bool

    created_at::DateTime
end


# ============================================================
# PAYMENT ENGINE
# ============================================================

mutable struct TetherPaymentEngine

    wallets::Dict{UUID,Wallet}

    merchants::Dict{UUID,Merchant}

    payments::Dict{UUID,Payment}

    settlements::Dict{UUID,Settlement}

    idempotency::Dict{String,UUID}

    ledger::Vector{LedgerEntry}

    audit::AuditLog

    fee_rate::Float64

    minimum_fee::USDT

    maximum_payment::USDT

    minimum_payment::USDT

    enabled::Bool
end


function TetherPaymentEngine(;
    fee_rate=0.001,

    minimum_fee=USDT(10),

    maximum_payment=USDT(1000),

    minimum_payment=USDT(1)
)

    TetherPaymentEngine(

        Dict{UUID,Wallet}(),

        Dict{UUID,Merchant}(),

        Dict{UUID,Payment}(),

        Dict{UUID,Settlement}(),

        Dict{String,UUID}(),

        LedgerEntry[],

        AuditLog(),

        fee_rate,

        minimum_fee,

        maximum_payment,

        minimum_payment,

        true
    )
end


# ============================================================
# WALLET MANAGEMENT
# ============================================================

function create_wallet!(
    engine::TetherPaymentEngine,
    owner::String,
    network::USDTNetwork,
    address::String;
    balance=USDT(0)
)

    wallet =
        Wallet(
            owner,
            network,
            address;
            balance=balance
        )

    engine.wallets[
        wallet.id
    ] = wallet

    audit!(
        engine.audit,
        :WALLET_CREATED,
        "Created wallet for $(owner)"
    )

    wallet
end


function wallet(
    engine::TetherPaymentEngine,
    id::UUID
)

    haskey(
        engine.wallets,
        id
    ) ||
        error(
            "Wallet not found."
        )

    engine.wallets[id]
end


# ============================================================
# MERCHANT MANAGEMENT
# ============================================================

function create_merchant!(
    engine::TetherPaymentEngine,
    name::String,
    wallet_id::UUID
)

    w =
        wallet(
            engine,
            wallet_id
        )

    merchant =
        Merchant(
            uuid4(),
            name,
            wallet_id,
            true,
            USDT(0),
            0
        )

    engine.merchants[
        merchant.id
    ] = merchant

    audit!(
        engine.audit,
        :MERCHANT_CREATED,
        "Merchant $(name) created"
    )

    merchant
end


# ============================================================
# FUND WALLET
# ============================================================

function fund_wallet!(
    engine::TetherPaymentEngine,
    wallet_id::UUID,
    amount::USDT
)

    amount.units > 0 ||
        error(
            "Amount must be positive."
        )

    w =
        wallet(
            engine,
            wallet_id
        )

    w.balance +=
        amount

    audit!(
        engine.audit,
        :WALLET_FUNDED,
        "$(usdt_string(amount)) credited to $(w.owner)"
    )

    w.balance
end


# ============================================================
# FEE ENGINE
# ============================================================

function calculate_fee(
    engine::TetherPaymentEngine,
    amount::USDT
)

    percentage =
        USDT(
            round(
                Int64,
                amount.units *
                engine.fee_rate
            )
        )

    USDT(
        max(
            percentage.units,
            engine.minimum_fee.units
        )
    )
end


# ============================================================
# PAYMENT DIGEST
# ============================================================

function payment_digest(
    sender::UUID,
    receiver::UUID,
    network::USDTNetwork,
    amount::USDT,
    fee::USDT,
    idempotency_key::String
)

    payload =
        join(
            [
                string(sender),
                string(receiver),
                string(network),
                string(amount.units),
                string(fee.units),
                idempotency_key
            ],
            "|"
        )

    bytes2hex(
        sha256(
            codeunits(payload)
        )
    )
end


# ============================================================
# PAYMENT VALIDATION
# ============================================================

function validate_payment(
    engine::TetherPaymentEngine,
    sender::Wallet,
    receiver::Wallet,
    amount::USDT,
    fee::USDT
)

    engine.enabled ||
        return false,
        "Payment engine disabled."

    sender.enabled ||
        return false,
        "Sender wallet disabled."

    receiver.enabled ||
        return false,
        "Receiver wallet disabled."

    sender.network ==
        receiver.network ||
        return false,
        "Cross-network payment requires a bridge/router."

    amount >=
        engine.minimum_payment ||
        return false,
        "Payment below minimum."

    amount <=
        engine.maximum_payment ||
        return false,
        "Payment exceeds maximum."

    total =
        amount +
        fee

    sender.balance >=
        total ||
        return false,
        "Insufficient balance."

    return true, ""
end


# ============================================================
# CREATE PAYMENT
# ============================================================

function create_payment!(
    engine::TetherPaymentEngine,

    sender_wallet_id::UUID,

    receiver_wallet_id::UUID,

    amount::USDT;

    merchant_id=nothing,

    idempotency_key=string(uuid4()),

    reference="",

    metadata=Dict{String,String}()
)

    # --------------------------------------------------------
    # IDEMPOTENCY
    # --------------------------------------------------------

    if haskey(
        engine.idempotency,
        idempotency_key
    )

        existing =
            engine.idempotency[
                idempotency_key
            ]

        return engine.payments[
            existing
        ]
    end

    sender =
        wallet(
            engine,
            sender_wallet_id
        )

    receiver =
        wallet(
            engine,
            receiver_wallet_id
        )

    fee =
        calculate_fee(
            engine,
            amount
        )

    valid, reason =
        validate_payment(
            engine,
            sender,
            receiver,
            amount,
            fee
        )

    if !valid

        payment =
            Payment(
                uuid4(),

                idempotency_key,

                sender_wallet_id,

                receiver_wallet_id,

                merchant_id,

                sender.network,

                amount,

                fee,

                amount + fee,

                FAILED,

                reference,

                now(),

                nothing,

                nothing,

                metadata,

                ""
            )

        engine.payments[
            payment.id
        ] = payment

        engine.idempotency[
            idempotency_key
        ] =
            payment.id

        audit!(
            engine.audit,
            :PAYMENT_FAILED,
            reason
        )

        return payment
    end

    digest =
        payment_digest(
            sender_wallet_id,
            receiver_wallet_id,
            sender.network,
            amount,
            fee,
            idempotency_key
        )

    payment =
        Payment(
            uuid4(),

            idempotency_key,

            sender_wallet_id,

            receiver_wallet_id,

            merchant_id,

            sender.network,

            amount,

            fee,

            amount + fee,

            CREATED,

            reference,

            now(),

            nothing,

            nothing,

            metadata,

            digest
        )

    engine.payments[
        payment.id
    ] =
        payment

    engine.idempotency[
        idempotency_key
    ] =
        payment.id

    audit!(
        engine.audit,
        :PAYMENT_CREATED,
        "Payment $(payment.id): $(usdt_string(amount))"
    )

    payment
end


# ============================================================
# AUTHORIZE PAYMENT
# ============================================================

function authorize!(
    engine::TetherPaymentEngine,
    payment_id::UUID
)

    payment =
        engine.payments[
            payment_id
        ]

    payment.status ==
        CREATED ||
        error(
            "Payment is not authorizable."
        )

    sender =
        wallet(
            engine,
            payment.sender_wallet
        )

    sender.balance >=
        payment.total_debit ||
        error(
            "Insufficient funds."
        )

    # Lock funds.

    sender.balance -=
        payment.total_debit

    sender.locked +=
        payment.total_debit

    payment.status =
        AUTHORIZED

    payment.authorized_at =
        now()

    audit!(
        engine.audit,
        :PAYMENT_AUTHORIZED,
        "Payment $(payment.id) authorized"
    )

    payment
end


# ============================================================
# SETTLE INTERNAL LEDGER
# ============================================================

function settle!(
    engine::TetherPaymentEngine,
    payment_id::UUID
)

    payment =
        engine.payments[
            payment_id
        ]

    payment.status ==
        AUTHORIZED ||
        error(
            "Payment must be authorized."
        )

    sender =
        wallet(
            engine,
            payment.sender_wallet
        )

    receiver =
        wallet(
            engine,
            payment.receiver_wallet
        )

    # --------------------------------------------------------
    # Release sender's locked amount.
    # --------------------------------------------------------

    sender.locked -=
        payment.total_debit

    # --------------------------------------------------------
    # Credit receiver.
    # --------------------------------------------------------

    receiver.balance +=
        payment.amount

    # --------------------------------------------------------
    # LEDGER
    # --------------------------------------------------------

    push!(
        engine.ledger,

        LedgerEntry(
            uuid4(),

            now(),

            sender.id,

            payment.id,

            payment.total_debit,

            :DEBIT,

            sender.balance,

            "USDT payment + fee"
        )
    )

    push!(
        engine.ledger,

        LedgerEntry(
            uuid4(),

            now(),

            receiver.id,

            payment.id,

            payment.amount,

            :CREDIT,

            receiver.balance,

            "USDT received"
        )
    )

    # --------------------------------------------------------
    # Merchant accounting
    # --------------------------------------------------------

    if payment.merchant_id !== nothing

        merchant =
            engine.merchants[
                payment.merchant_id
            ]

        merchant.total_revenue +=
            payment.amount

        merchant.transaction_count +=
            1
    end

    payment.status =
        SETTLED

    payment.settled_at =
        now()

    audit!(
        engine.audit,
        :PAYMENT_SETTLED,
        "Payment $(payment.id) settled"
    )

    payment
end


# ============================================================
# BLOCKCHAIN SETTLEMENT
# ============================================================
#
# This represents the interface that a real blockchain
# adapter would implement.
# ============================================================

function create_settlement!(
    engine::TetherPaymentEngine,
    payment_id::UUID
)

    payment =
        engine.payments[
            payment_id
        ]

    payment.status ==
        SETTLED ||
        error(
            "Payment must be internally settled first."
        )

    sender =
        wallet(
            engine,
            payment.sender_wallet
        )

    receiver =
        wallet(
            engine,
            payment.receiver_wallet
        )

    settlement =
        Settlement(

            uuid4(),

            payment.id,

            payment.network,

            sender.address,

            receiver.address,

            payment.amount,

            USDT(0),

            nothing,

            0,

            false,

            now()
        )

    engine.settlements[
        settlement.id
    ] =
        settlement

    audit!(
        engine.audit,
        :CHAIN_SETTLEMENT_CREATED,
        "Blockchain settlement prepared"
    )

    settlement
end


# ============================================================
# SIMULATED BLOCKCHAIN CONFIRMATION
# ============================================================

function confirm_settlement!(
    engine::TetherPaymentEngine,
    settlement_id::UUID,
    tx_hash::String;
    confirmations=1
)

    settlement =
        engine.settlements[
            settlement_id
        ]

    settlement.tx_hash =
        tx_hash

    settlement.confirmations =
        confirmations

    settlement.confirmed =
        confirmations >= 1

    audit!(
        engine.audit,
        :CHAIN_CONFIRMED,
        "Settlement $(settlement.id) confirmed"
    )

    settlement
end


# ============================================================
# REFUND
# ============================================================

function refund!(
    engine::TetherPaymentEngine,
    payment_id::UUID
)

    payment =
        engine.payments[
            payment_id
        ]

    payment.status ==
        SETTLED ||
        error(
            "Payment is not refundable."
        )

    sender =
        wallet(
            engine,
            payment.sender_wallet
        )

    receiver =
        wallet(
            engine,
            payment.receiver_wallet
        )

    receiver.balance >=
        payment.amount ||
        error(
            "Receiver lacks funds."
        )

    receiver.balance -=
        payment.amount

    sender.balance +=
        payment.amount

    payment.status =
        REFUNDED

    push!(
        engine.ledger,

        LedgerEntry(
            uuid4(),

            now(),

            receiver.id,

            payment.id,

            payment.amount,

            :DEBIT,

            receiver.balance,

            "USDT refund"
        )
    )

    push!(
        engine.ledger,

        LedgerEntry(
            uuid4(),

            now(),

            sender.id,

            payment.id,

            payment.amount,

            :CREDIT,

            sender.balance,

            "USDT refund received"
        )
    )

    audit!(
        engine.audit,
        :REFUND,
        "Payment $(payment.id) refunded"
    )

    payment
end


# ============================================================
# MICROTRANSACTION BATCHING
# ============================================================
#
# Useful for:
#
#   £ / $0.001 content payments
#   machine-to-machine payments
#   API calls
#   streaming payments
#   vending
#   transport
#   automated pub equipment
#
# Instead of broadcasting every tiny payment, the engine can
# aggregate many internal payments and settle them together.
# ============================================================

mutable struct PaymentBatch

    id::UUID

    network::USDTNetwork

    payments::Vector{UUID}

    total::USDT

    created_at::DateTime

    settled::Bool
end


PaymentBatch(
    network::USDTNetwork
) =
    PaymentBatch(
        uuid4(),
        network,
        UUID[],
        USDT(0),
        now(),
        false
    )


function add_to_batch!(
    engine::TetherPaymentEngine,
    batch::PaymentBatch,
    payment_id::UUID
)

    payment =
        engine.payments[
            payment_id
        ]

    payment.status ==
        SETTLED ||
        error(
            "Only settled payments can be batched."
        )

    payment.network ==
        batch.network ||
        error(
            "Network mismatch."
        )

    push!(
        batch.payments,
        payment.id
    )

    batch.total +=
        payment.amount

    batch
end


function batch_summary(
    batch::PaymentBatch
)

    (
        id =
            batch.id,

        network =
            batch.network,

        transaction_count =
            length(batch.payments),

        total =
            batch.total,

        settled =
            batch.settled
    )
end


# ============================================================
# STREAMING MICRO-PAYMENTS
# ============================================================
#
# Example:
#
#   Pay 0.000001 USDT per API request.
#
# Internally accumulate and settle once the threshold is
# reached.
# ============================================================

mutable struct PaymentStream

    id::UUID

    sender_wallet::UUID

    receiver_wallet::UUID

    network::USDTNetwork

    unit_price::USDT

    accumulated::USDT

    units::Int

    settlement_threshold::USDT

    active::Bool
end


function PaymentStream(
    sender_wallet::UUID,
    receiver_wallet::UUID,
    network::USDTNetwork,
    unit_price::USDT;
    settlement_threshold=USDT(1000)
)

    PaymentStream(

        uuid4(),

        sender_wallet,

        receiver_wallet,

        network,

        unit_price,

        USDT(0),

        0,

        settlement_threshold,

        true
    )
end


function consume!(
    stream::PaymentStream,
    units::Int=1
)

    units > 0 ||
        error(
            "Units must be positive."
        )

    stream.units +=
        units

    stream.accumulated +=
        stream.unit_price *
        units

    stream.accumulated
end


function should_settle(
    stream::PaymentStream
)

    stream.accumulated >=
        stream.settlement_threshold
end


function reset_stream!(
    stream::PaymentStream
)

    stream.accumulated =
        USDT(0)

    stream.units =
        0

    stream
end


# ============================================================
# PAYMENT REQUEST
# ============================================================

struct PaymentRequest

    merchant::String

    amount::USDT

    network::USDTNetwork

    wallet_address::String

    reference::String

    expires_at::DateTime
end


function create_payment_request(
    merchant::String,
    amount::USDT,
    network::USDTNetwork,
    wallet_address::String;
    reference="",
    lifetime_seconds=300
)

    PaymentRequest(

        merchant,

        amount,

        network,

        wallet_address,

        reference,

        now() +
        Second(lifetime_seconds)
    )
end


function payment_request_valid(
    request::PaymentRequest
)

    now() <=
        request.expires_at
end


# ============================================================
# MERCHANT CHECKOUT
# ============================================================

function checkout!(
    engine::TetherPaymentEngine,

    customer_wallet::UUID,

    merchant_id::UUID,

    amount::USDT;

    reference=""
)

    merchant =
        engine.merchants[
            merchant_id
        ]

    merchant.enabled ||
        error(
            "Merchant disabled."
        )

    payment =
        create_payment!(
            engine,

            customer_wallet,

            merchant.wallet_id,

            amount;

            merchant_id =
                merchant.id,

            reference =
                reference
        )

    payment.status ==
        CREATED ||
        return payment

    authorize!(
        engine,
        payment.id
    )

    settle!(
        engine,
        payment.id
    )

    payment
end


# ============================================================
# BALANCE
# ============================================================

function balance(
    engine::TetherPaymentEngine,
    wallet_id::UUID
)

    wallet(
        engine,
        wallet_id
    ).balance
end


# ============================================================
# TELEMETRY
# ============================================================

function telemetry(
    engine::TetherPaymentEngine
)

    settled =
        count(
            p ->
                p.status ==
                SETTLED,

            values(
                engine.payments
            )
        )

    volume =
        sum(
            (
                p.amount.units
                for p in
                values(engine.payments)
                if p.status ==
                   SETTLED
            );

            init=Int64(0)
        )

    (

        timestamp =
            now(),

        wallets =
            length(engine.wallets),

        merchants =
            length(engine.merchants),

        payments =
            length(engine.payments),

        settled_payments =
            settled,

        settled_volume =
            USDT(volume),

        ledger_entries =
            length(engine.ledger),

        blockchain_settlements =
            length(engine.settlements)
    )
end


# ============================================================
# DEMO
# ============================================================

function demo()

    println()
    println("="^72)
    println("                  TETHER MICROPAY")
    println("                    PURE JULIA")
    println("="^72)

    engine =
        TetherPaymentEngine(
            fee_rate=0.001,
            minimum_fee=USDT(1),
            minimum_payment=USDT(1),
            maximum_payment=USDT(100_000_000)
        )

    # --------------------------------------------------------
    # Customer wallet
    # --------------------------------------------------------

    customer =
        create_wallet!(
            engine,
            "Customer",
            TRON,
            "TRON_CUSTOMER_ADDRESS";
            balance=USDT(100.0)
        )

    # --------------------------------------------------------
    # Merchant wallet
    # --------------------------------------------------------

    merchant_wallet =
        create_wallet!(
            engine,
            "Pub",
            TRON,
            "TRON_PUB_ADDRESS"
        )

    merchant =
        create_merchant!(
            engine,
            "OpenAllHours Pub",
            merchant_wallet.id
        )

    println()
    println(
        "Customer balance: ",
        usdt_string(
            customer.balance
        )
    )

    # --------------------------------------------------------
    # Tiny purchase
    # --------------------------------------------------------

    payment =
        checkout!(
            engine,

            customer.id,

            merchant.id,

            USDT(0.01);

            reference =
                "PINT-000001"
        )

    println()
    println(
        "Payment ID: ",
        payment.id
    )

    println(
        "Amount:     ",
        usdt_string(
            payment.amount
        )
    )

    println(
        "Fee:        ",
        usdt_string(
            payment.fee
        )
    )

    println(
        "Network:    ",
        network_name(
            payment.network
        )
    )

    println(
        "Status:     ",
        payment.status
    )

    println()
    println(
        "Customer balance: ",
        usdt_string(
            customer.balance
        )
    )

    println(
        "Merchant balance: ",
        usdt_string(
            merchant_wallet.balance
        )
    )

    # --------------------------------------------------------
    # Blockchain settlement interface
    # --------------------------------------------------------

    settlement =
        create_settlement!(
            engine,
            payment.id
        )

    confirm_settlement!(
        engine,
        settlement.id,
        "SIMULATED_USDT_TX_HASH";
        confirmations=12
    )

    println()
    println(
        "Blockchain settlement:"
    )

    println(
        "Network:       ",
        settlement.network
    )

    println(
        "Amount:        ",
        usdt_string(
            settlement.amount
        )
    )

    println(
        "Confirmations: ",
        settlement.confirmations
    )

    println(
        "Confirmed:     ",
        settlement.confirmed
    )

    # --------------------------------------------------------
    # Streaming micropayment example
    # --------------------------------------------------------

    stream =
        PaymentStream(
            customer.id,
            merchant_wallet.id,
            TRON,
            USDT(0.000001);
            settlement_threshold=USDT(0.001)
        )

    for i in 1:1000

        consume!(
            stream
        )

    end

    println()
    println(
        "Streaming payments:"
    )

    println(
        "Units consumed: ",
        stream.units
    )

    println(
        "Accumulated:    ",
        usdt_string(
            stream.accumulated
        )
    )

    println(
        "Should settle:   ",
        should_settle(
            stream
        )
    )

    # --------------------------------------------------------
    # System telemetry
    # --------------------------------------------------------

    println()
    println(
        "System telemetry:"
    )

    println(
        telemetry(
            engine
        )
    )

    println("="^72)

    return engine
end


# ============================================================
# EXPORTS
# ============================================================

export USDT
export USDTNetwork
export Wallet
export Merchant
export Payment
export Settlement
export PaymentBatch
export PaymentStream
export PaymentRequest
export TetherPaymentEngine

export ETHEREUM
export TRON
export SOLANA
export TON
export AVALANCHE
export CELO
export APTOS
export NEAR

export create_wallet!
export create_merchant!
export fund_wallet!

export create_payment!
export authorize!
export settle!
export refund!

export create_settlement!
export confirm_settlement!

export create_payment_request
export payment_request_valid

export checkout!

export PaymentStream
export consume!
export should_settle
export reset_stream!

export PaymentBatch
export add_to_batch!
export batch_summary

export balance
export telemetry
export usdt_string

export demo


end # module


# ============================================================
# EXECUTE DEMONSTRATION
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .TetherMicroPay

    TetherMicroPay.demo()

end
```

