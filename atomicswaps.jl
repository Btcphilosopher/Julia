# ATOMIC SWAPS — PURE JULIA

```julia
module AtomicSwaps

using SHA
using UUIDs
using Dates


# ============================================================
# HASH-LOCKED ATOMIC SWAP
#
# Alice and Bob exchange two assets.
#
# Alice:
#     locks Asset A
#
# Bob:
#     locks Asset B
#
# Both locks use:
#
#     H = SHA256(secret)
#
# Whoever knows `secret` can claim the counterparty's asset.
#
# If the swap expires:
#
#     Alice refunds Asset A
#     Bob refunds Asset B
#
# The simulator deliberately contains no real blockchain,
# wallet, private-key, or transaction-broadcast functionality.
# ============================================================


# ============================================================
# STATES
# ============================================================

@enum SwapState begin
    CREATED
    FIRST_LOCKED
    BOTH_LOCKED
    COMPLETED
    REFUNDED
    EXPIRED
end


# ============================================================
# ASSET
# ============================================================

struct Asset

    symbol::String

    amount::Int64

end


function Asset(
    symbol::String,
    amount::Integer
)

    amount > 0 ||
        error("Asset amount must be positive.")

    Asset(
        symbol,
        Int64(amount)
    )

end


# ============================================================
# PARTICIPANT
# ============================================================

mutable struct Participant

    id::String

    name::String

    balances::Dict{String,Int64}

end


function Participant(
    name::String
)

    Participant(

        string(uuid4()),

        name,

        Dict{String,Int64}()

    )

end


function credit!(
    participant::Participant,
    asset::Asset
)

    participant.balances[
        asset.symbol
    ] =
        get(
            participant.balances,
            asset.symbol,
            0
        ) +
        asset.amount

end


function balance(
    participant::Participant,
    symbol::String
)

    get(
        participant.balances,
        symbol,
        0
    )

end


function debit!(
    participant::Participant,
    asset::Asset
)

    current =
        balance(
            participant,
            asset.symbol
        )

    current >= asset.amount ||
        error(
            "Insufficient balance."
        )

    participant.balances[
        asset.symbol
    ] =
        current -
        asset.amount

end


# ============================================================
# SECRET
# ============================================================

struct SwapSecret

    value::Vector{UInt8}

end


function SwapSecret()

    # Simulator entropy source.
    # A production wallet implementation should use a
    # cryptographically secure random source.
    raw =
        string(
            uuid4(),
            uuid4(),
            now()
        )

    SwapSecret(
        Vector{UInt8}(
            codeunits(raw)
        )
    )

end


function secret_hash(
    secret::SwapSecret
)

    bytes2hex(
        sha256(
            secret.value
        )
    )

end


# ============================================================
# LOCK
# ============================================================

mutable struct HTLCLock

    id::String

    owner::String

    beneficiary::String

    asset::Asset

    hashlock::String

    timeout::DateTime

    claimed::Bool

    refunded::Bool

end


# ============================================================
# SWAP
# ============================================================

mutable struct AtomicSwap

    id::String

    party_a::Participant

    party_b::Participant

    asset_a::Asset

    asset_b::Asset

    hashlock::String

    timeout_a::DateTime

    timeout_b::DateTime

    lock_a::Union{Nothing,HTLCLock}

    lock_b::Union{Nothing,HTLCLock}

    state::SwapState

    secret_revealed::Bool

end


# ============================================================
# CREATE SWAP
# ============================================================

function create_swap(

    party_a::Participant,

    party_b::Participant,

    asset_a::Asset,

    asset_b::Asset;

    timeout_seconds::Int=3600

)

    timeout_seconds > 0 ||
        error(
            "Timeout must be positive."
        )

    secret =
        SwapSecret()

    hash =
        secret_hash(
            secret
        )

    swap =
        AtomicSwap(

            string(uuid4()),

            party_a,

            party_b,

            asset_a,

            asset_b,

            hash,

            now() +
            Second(timeout_seconds),

            now() +
            Second(timeout_seconds * 2),

            nothing,

            nothing,

            CREATED,

            false

        )

    return swap, secret

end


# ============================================================
# LOCK ASSET A
# ============================================================

function lock_a!(
    swap::AtomicSwap
)

    swap.lock_a === nothing ||
        error(
            "Party A has already locked its asset."
        )

    swap.state == CREATED ||
        error(
            "Swap is not in the correct state."
        )

    debit!(
        swap.party_a,
        swap.asset_a
    )

    swap.lock_a =
        HTLCLock(

            string(uuid4()),

            swap.party_a.id,

            swap.party_b.id,

            swap.asset_a,

            swap.hashlock,

            swap.timeout_a,

            false,

            false

        )

    swap.state =
        FIRST_LOCKED

    swap.lock_a

end


# ============================================================
# LOCK ASSET B
# ============================================================

function lock_b!(
    swap::AtomicSwap
)

    swap.lock_a !== nothing ||
        error(
            "Party A must lock first."
        )

    swap.lock_b === nothing ||
        error(
            "Party B has already locked its asset."
        )

    swap.state == FIRST_LOCKED ||
        error(
            "Swap is not in the correct state."
        )

    debit!(
        swap.party_b,
        swap.asset_b
    )

    swap.lock_b =
        HTLCLock(

            string(uuid4()),

            swap.party_b.id,

            swap.party_a.id,

            swap.asset_b,

            swap.hashlock,

            swap.timeout_b,

            false,

            false

        )

    swap.state =
        BOTH_LOCKED

    swap.lock_b

end


# ============================================================
# VERIFY SECRET
# ============================================================

function valid_secret(

    swap::AtomicSwap,

    secret::SwapSecret

)

    secret_hash(secret) ==
        swap.hashlock

end


# ============================================================
# CLAIM ASSET B
# ============================================================

function claim_b!(

    swap::AtomicSwap,

    secret::SwapSecret

)

    swap.lock_b !== nothing ||
        error(
            "Party B has not locked its asset."
        )

    swap.state == BOTH_LOCKED ||
        error(
            "Swap is not ready for settlement."
        )

    valid_secret(
        swap,
        secret
    ) ||
        error(
            "Invalid secret."
        )

    lock =
        swap.lock_b

    lock.claimed ||
        error(
            "Asset B already claimed."
        )

    lock.refunded &&
        error(
            "Asset B already refunded."
        )

    now() <
        lock.timeout ||
        error(
            "HTLC has expired."
        )

    credit!(
        swap.party_a,
        swap.asset_b
    )

    lock.claimed =
        true

    swap.secret_revealed =
        true

    swap.state =
        COMPLETED

    swap.asset_b

end


# ============================================================
# CLAIM ASSET A
# ============================================================
#
# Once the secret has been revealed by the first claimant,
# the other party can use the same preimage to claim the
# other locked asset.
#
# ============================================================

function claim_a!(

    swap::AtomicSwap,

    secret::SwapSecret

)

    swap.lock_a !== nothing ||
        error(
            "Party A has not locked its asset."
        )

    valid_secret(
        swap,
        secret
    ) ||
        error(
            "Invalid secret."
        )

    lock =
        swap.lock_a

    lock.claimed ||
        error(
            "Asset A already claimed."
        )

    lock.refunded &&
        error(
            "Asset A already refunded."
        )

    now() <
        lock.timeout ||
        error(
            "HTLC has expired."
        )

    credit!(
        swap.party_b,
        swap.asset_a
    )

    lock.claimed =
        true

    swap.secret_revealed =
        true

    swap.state =
        COMPLETED

    swap.asset_a

end


# ============================================================
# REFUND A
# ============================================================

function refund_a!(
    swap::AtomicSwap
)

    swap.lock_a !== nothing ||
        error(
            "No Asset A lock exists."
        )

    lock =
        swap.lock_a

    lock.claimed &&
        error(
            "Asset A has already been claimed."
        )

    lock.refunded &&
        error(
            "Asset A already refunded."
        )

    now() >=
        lock.timeout ||
        error(
            "Asset A timeout has not expired."
        )

    credit!(
        swap.party_a,
        swap.asset_a
    )

    lock.refunded =
        true

    swap.state =
        REFUNDED

    swap.asset_a

end


# ============================================================
# REFUND B
# ============================================================

function refund_b!(
    swap::AtomicSwap
)

    swap.lock_b !== nothing ||
        error(
            "No Asset B lock exists."
        )

    lock =
        swap.lock_b

    lock.claimed &&
        error(
            "Asset B has already been claimed."
        )

    lock.refunded &&
        error(
            "Asset B already refunded."
        )

    now() >=
        lock.timeout ||
        error(
            "Asset B timeout has not expired."
        )

    credit!(
        swap.party_b,
        swap.asset_b
    )

    lock.refunded =
        true

    swap.state =
        REFUNDED

    swap.asset_b

end


# ============================================================
# STATUS
# ============================================================

function status(
    swap::AtomicSwap
)

    (

        id =
            swap.id,

        state =
            swap.state,

        hashlock =
            swap.hashlock,

        asset_a =
            swap.asset_a,

        asset_b =
            swap.asset_b,

        secret_revealed =
            swap.secret_revealed,

        party_a =
            swap.party_a.name,

        party_b =
            swap.party_b.name

    )

end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println()
    println("="^70)
    println("                 JULIA ATOMIC SWAP")
    println("="^70)


    # --------------------------------------------------------
    # Participants
    # --------------------------------------------------------

    alice =
        Participant(
            "Alice"
        )

    bob =
        Participant(
            "Bob"
        )


    # --------------------------------------------------------
    # Assets
    # --------------------------------------------------------

    credit!(
        alice,
        Asset(
            "BTC",
            1
        )
    )

    credit!(
        bob,
        Asset(
            "USDT",
            1000
        )
    )


    println()
    println(
        "Initial balances:"
    )

    println(
        "Alice BTC  = ",
        balance(
            alice,
            "BTC"
        )
    )

    println(
        "Bob USDT   = ",
        balance(
            bob,
            "USDT"
        )
    )


    # --------------------------------------------------------
    # Create swap
    # --------------------------------------------------------

    swap, secret =
        create_swap(

            alice,

            bob,

            Asset(
                "BTC",
                1
            ),

            Asset(
                "USDT",
                1000
            );

            timeout_seconds=3600

        )


    println()
    println(
        "Swap created:"
    )

    println(
        swap.id
    )

    println()
    println(
        "Hashlock:"
    )

    println(
        swap.hashlock
    )


    # --------------------------------------------------------
    # Alice locks BTC
    # --------------------------------------------------------

    lock_a!(
        swap
    )

    println()
    println(
        "Alice locked BTC."
    )


    # --------------------------------------------------------
    # Bob locks USDT
    # --------------------------------------------------------

    lock_b!(
        swap
    )

    println(
        "Bob locked USDT."
    )


    # --------------------------------------------------------
    # Alice reveals secret and claims USDT
    # --------------------------------------------------------

    claim_b!(
        swap,
        secret
    )

    println()
    println(
        "Alice claimed Bob's USDT."
    )


    # --------------------------------------------------------
    # Bob learns secret and claims BTC
    # --------------------------------------------------------

    claim_a!(
        swap,
        secret
    )

    println(
        "Bob claimed Alice's BTC."
    )


    # --------------------------------------------------------
    # Final balances
    # --------------------------------------------------------

    println()
    println(
        "Final balances:"
    )

    println(
        "Alice BTC  = ",
        balance(
            alice,
            "BTC"
        )
    )

    println(
        "Alice USDT = ",
        balance(
            alice,
            "USDT"
        )
    )

    println(
        "Bob BTC    = ",
        balance(
            bob,
            "BTC"
        )
    )

    println(
        "Bob USDT   = ",
        balance(
            bob,
            "USDT"
        )
    )


    println()
    println(
        "Swap status:"
    )

    println(
        status(
            swap
        )
    )


    println()
    println("="^70)

end


# ============================================================
# EXPORTS
# ============================================================

export Asset
export Participant
export SwapSecret
export HTLCLock
export AtomicSwap

export CREATED
export FIRST_LOCKED
export BOTH_LOCKED
export COMPLETED
export REFUNDED
export EXPIRED

export credit!
export debit!
export balance

export secret_hash

export create_swap

export lock_a!
export lock_b!

export claim_a!
export claim_b!

export refund_a!
export refund_b!

export status

export demo


end # module


# ============================================================
# RUN DEMO
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .AtomicSwaps

    AtomicSwaps.demo()

end
```

