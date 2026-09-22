module FastTollGate

using Dates
using UUIDs
using SHA
using Base.Threads

# ============================================================
# CONFIGURATION
# ============================================================

struct GateConfig
    minimum_payment::Float64
    gate_open_time_ms::Int
    vehicle_timeout_ms::Int
    transaction_timeout_ms::Int
end


# ============================================================
# PAYMENT STATES
# ============================================================

@enum PaymentStatus begin
    PaymentPending
    PaymentAuthorised
    PaymentDeclined
    PaymentExpired
    PaymentDuplicate
end


# ============================================================
# GATE STATES
# ============================================================

@enum GateState begin
    GateClosed
    GateOpening
    GateOpen
    GateClosing
    GateFault
end


# ============================================================
# PAYMENT EVENT
# ============================================================

struct PaymentEvent
    transaction_id::UUID
    account_id::String

    amount::Float64
    currency::String

    timestamp::DateTime

    payment_reference::String
    status::PaymentStatus
end


# ============================================================
# VEHICLE
# ============================================================

struct Vehicle
    id::String
    detected_at::DateTime
end


# ============================================================
# TRANSACTION RECORD
# ============================================================

mutable struct TollTransaction
    transaction_id::UUID

    account_id::String
    vehicle_id::String

    amount::Float64

    created_at::DateTime
    authorised_at::Union{DateTime,Nothing}
    completed_at::Union{DateTime,Nothing}

    status::PaymentStatus
end


# ============================================================
# PAYMENT CACHE
#
# Fast in-memory lookup avoids repeatedly querying a
# remote payment service for the same transaction.
# ============================================================

mutable struct PaymentCache
    payments::Dict{UUID,PaymentEvent}

    lock::ReentrantLock
end


function PaymentCache()

    return PaymentCache(
        Dict{UUID,PaymentEvent}(),
        ReentrantLock()
    )

end


function store_payment!(
    cache::PaymentCache,
    payment::PaymentEvent
)

    lock(cache.lock)

    try

        cache.payments[
            payment.transaction_id
        ] = payment

    finally

        unlock(cache.lock)

    end

end


function get_payment(
    cache::PaymentCache,
    id::UUID
)

    lock(cache.lock)

    try

        return get(
            cache.payments,
            id,
            nothing
        )

    finally

        unlock(cache.lock)

    end

end


# ============================================================
# IDEMPOTENCY
#
# Prevents the same payment from opening the gate twice.
# ============================================================

mutable struct IdempotencyStore

    processed::Set{UUID}

    lock::ReentrantLock

end


function IdempotencyStore()

    return IdempotencyStore(
        Set{UUID}(),
        ReentrantLock()
    )

end


function already_processed(
    store::IdempotencyStore,
    id::UUID
)

    lock(store.lock)

    try

        return id in store.processed

    finally

        unlock(store.lock)

    end

end


function mark_processed!(
    store::IdempotencyStore,
    id::UUID
)

    lock(store.lock)

    try

        push!(
            store.processed,
            id
        )

    finally

        unlock(store.lock)

    end

end


# ============================================================
# PAYMENT VALIDATION
# ============================================================

function validate_payment(
    payment::PaymentEvent,
    config::GateConfig
)

    if payment.status != PaymentAuthorised
        return false
    end

    if payment.amount < config.minimum_payment
        return false
    end

    if payment.currency != "GBP"
        return false
    end

    return true

end


# ============================================================
# GATE CONTROLLER
# ============================================================

mutable struct GateController

    state::GateState

    last_transaction::Union{UUID,Nothing}

    state_changed_at::DateTime

    lock::ReentrantLock

end


function GateController()

    return GateController(
        GateClosed,
        nothing,
        now(),
        ReentrantLock()
    )

end


# ============================================================
# HARDWARE ABSTRACTION
#
# Replace these functions with the actual PLC,
# relay controller, CAN bus, Ethernet I/O, etc.
# ============================================================

function hardware_open_gate!(
    controller::GateController
)

    println(
        "[GATE] OPEN COMMAND"
    )

    return true

end


function hardware_close_gate!(
    controller::GateController
)

    println(
        "[GATE] CLOSE COMMAND"
    )

    return true

end


# ============================================================
# OPEN GATE
# ============================================================

function open_gate!(
    controller::GateController,
    transaction_id::UUID
)

    lock(controller.lock)

    try

        # Never reopen an already-open gate.

        if controller.state != GateClosed
            return false
        end

        success =
            hardware_open_gate!(
                controller
            )

        if !success

            controller.state =
                GateFault

            return false

        end

        controller.state =
            GateOpening

        controller.last_transaction =
            transaction_id

        controller.state_changed_at =
            now()

        return true

    finally

        unlock(controller.lock)

    end

end


# ============================================================
# GATE OPEN CONFIRMATION
# ============================================================

function gate_open_confirmed!(
    controller::GateController
)

    lock(controller.lock)

    try

        if controller.state ==
           GateOpening

            controller.state =
                GateOpen

            controller.state_changed_at =
                now()

            return true

        end

        return false

    finally

        unlock(controller.lock)

    end

end


# ============================================================
# CLOSE GATE
# ============================================================

function close_gate!(
    controller::GateController
)

    lock(controller.lock)

    try

        if controller.state != GateOpen
            return false
        end

        success =
            hardware_close_gate!(
                controller
            )

        if !success

            controller.state =
                GateFault

            return false

        end

        controller.state =
            GateClosing

        controller.state_changed_at =
            now()

        return true

    finally

        unlock(controller.lock)

    end

end


# ============================================================
# CLOSE CONFIRMATION
# ============================================================

function gate_closed_confirmed!(
    controller::GateController
)

    lock(controller.lock)

    try

        if controller.state ==
           GateClosing

            controller.state =
                GateClosed

            controller.state_changed_at =
                now()

            return true

        end

        return false

    finally

        unlock(controller.lock)

    end

end


# ============================================================
# FAST PAYMENT → GATE PIPELINE
# ============================================================

function process_payment!(
    payment::PaymentEvent,
    vehicle::Vehicle,

    cache::PaymentCache,
    idempotency::IdempotencyStore,

    gate::GateController,
    config::GateConfig
)

    start_time =
        time_ns()


    # --------------------------------------------------------
    # STEP 1
    # Validate payment
    # --------------------------------------------------------

    if !validate_payment(
        payment,
        config
    )

        println(
            "[PAYMENT] REJECTED"
        )

        return false
    end


    # --------------------------------------------------------
    # STEP 2
    # Check duplicate
    # --------------------------------------------------------

    if already_processed(
        idempotency,
        payment.transaction_id
    )

        println(
            "[PAYMENT] DUPLICATE"
        )

        return false
    end


    # --------------------------------------------------------
    # STEP 3
    # Cache authorised payment
    # --------------------------------------------------------

    store_payment!(
        cache,
        payment
    )


    # --------------------------------------------------------
    # STEP 4
    # Mark transaction consumed
    # --------------------------------------------------------

    mark_processed!(
        idempotency,
        payment.transaction_id
    )


    # --------------------------------------------------------
    # STEP 5
    # Open gate
    # --------------------------------------------------------

    success =
        open_gate!(
            gate,
            payment.transaction_id
        )


    elapsed_ms =
        (time_ns() - start_time) / 1_000_000


    if success

        println(
            "[GATE] OPENED | " *
            "transaction=" *
            string(payment.transaction_id) *
            " | latency=" *
            string(round(elapsed_ms,digits=2)) *
            " ms"
        )

    end


    return success

end


# ============================================================
# VEHICLE PASSAGE
# ============================================================

function vehicle_passed!(
    gate::GateController
)

    if gate.state != GateOpen
        return false
    end

    println(
        "[VEHICLE] PASSAGE CONFIRMED"
    )

    close_gate!(
        gate
    )

    return true

end


# ============================================================
# PAYMENT PROVIDER INTERFACE
#
# A real payment provider/terminal integration should call
# this function after receiving an authenticated payment
# confirmation.
# ============================================================

function payment_received!(
    transaction_id::UUID,
    account_id::String,
    vehicle_id::String,
    amount::Float64,

    cache::PaymentCache,
    idempotency::IdempotencyStore,
    gate::GateController,
    config::GateConfig
)

    payment =
        PaymentEvent(
            transaction_id,
            account_id,
            amount,
            "GBP",
            now(),
            string(transaction_id),
            PaymentAuthorised
        )


    vehicle =
        Vehicle(
            vehicle_id,
            now()
        )


    return process_payment!(
        payment,
        vehicle,

        cache,
        idempotency,

        gate,
        config
    )

end


# ============================================================
# COMPLETE SYSTEM
# ============================================================

mutable struct TollGateSystem

    config::GateConfig

    cache::PaymentCache

    idempotency::IdempotencyStore

    gate::GateController

end


function TollGateSystem(;
    minimum_payment=2.50,
    gate_open_time_ms=250,
    vehicle_timeout_ms=10_000,
    transaction_timeout_ms=15_000
)

    config =
        GateConfig(
            minimum_payment,
            gate_open_time_ms,
            vehicle_timeout_ms,
            transaction_timeout_ms
        )

    return TollGateSystem(
        config,
        PaymentCache(),
        IdempotencyStore(),
        GateController()
    )

end


# ============================================================
# HIGH-LEVEL API
# ============================================================

function authorise_vehicle!(
    system::TollGateSystem,

    transaction_id::UUID,
    account_id::String,
    vehicle_id::String,
    amount::Float64
)

    return payment_received!(
        transaction_id,
        account_id,
        vehicle_id,
        amount,

        system.cache,
        system.idempotency,
        system.gate,
        system.config
    )

end


end # module


