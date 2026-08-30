# TETHER PAYWALL — PURE JULIA

```julia
module TetherPaywall

using Dates
using UUIDs
using SHA
using Printf


# ============================================================
# TETHER PAYWALL
#
# Pure Julia payment-gated access system.
#
# Example:
#
#     Article costs 0.01 USDT
#
#     Customer:
#
#         GET /article/123
#
#             ↓
#
#         PAYWALL
#
#             ↓
#
#         Payment Request
#
#             ↓
#
#         USDT PAYMENT
#
#             ↓
#
#         PAYMENT VERIFIED
#
#             ↓
#
#         ACCESS TOKEN
#
#             ↓
#
#         ARTICLE UNLOCKED
#
#
# The blockchain verification layer is deliberately abstract.
# A production implementation should connect this interface
# to the relevant chain/RPC/indexer and independently verify
# transaction details.
# ============================================================


# ============================================================
# USDT
# ============================================================

const USDT_DECIMALS = 6
const USDT_UNIT = Int64(1_000_000)


struct USDT

    units::Int64

end


USDT(x::Integer) =
    USDT(Int64(x))


function USDT(x::Real)

    USDT(
        round(
            Int64,
            x * USDT_UNIT
        )
    )

end


Base.:+(a::USDT, b::USDT) =
    USDT(
        a.units + b.units
    )


Base.:-(a::USDT, b::USDT) =
    USDT(
        a.units - b.units
    )


Base.:(==)(a::USDT, b::USDT) =
    a.units == b.units


Base.isless(a::USDT, b::USDT) =
    a.units < b.units


function usdt_string(
    amount::USDT
)

    whole =
        amount.units ÷ USDT_UNIT

    fraction =
        abs(
            amount.units % USDT_UNIT
        )

    @sprintf(
        "%d.%06d USDT",
        whole,
        fraction
    )

end


# ============================================================
# SUPPORTED NETWORK
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


function network_string(
    network::USDTNetwork
)

    lowercase(
        string(network)
    )

end


# ============================================================
# PAYWALL RESOURCE
# ============================================================

struct Resource

    id::String

    title::String

    content::String

    price::USDT

    network::USDTNetwork

end


# ============================================================
# PAYMENT REQUEST
# ============================================================

mutable struct PaymentRequest

    id::UUID

    resource_id::String

    amount::USDT

    network::USDTNetwork

    merchant_address::String

    created_at::DateTime

    expires_at::DateTime

    status::Symbol

end


# ============================================================
# BLOCKCHAIN PAYMENT
# ============================================================

struct BlockchainPayment

    tx_hash::String

    network::USDTNetwork

    token_address::String

    sender_address::String

    receiver_address::String

    amount::USDT

    block_number::Int64

    confirmations::Int

    timestamp::DateTime

end


# ============================================================
# ACCESS TOKEN
# ============================================================

mutable struct AccessToken

    token::String

    resource_id::String

    payment_id::UUID

    created_at::DateTime

    expires_at::DateTime

    used::Bool

end


# ============================================================
# PAYWALL
# ============================================================

mutable struct Paywall

    merchant_name::String

    merchant_address::String

    resources::Dict{String,Resource}

    requests::Dict{UUID,PaymentRequest}

    payments::Dict{UUID,BlockchainPayment}

    access_tokens::Dict{String,AccessToken}

    used_transactions::Set{String}

    minimum_confirmations::Int

    token_contracts::Dict{USDTNetwork,String}

end


# ============================================================
# CONSTRUCTOR
# ============================================================

function Paywall(

    merchant_name::String,

    merchant_address::String;

    minimum_confirmations=3

)

    Paywall(

        merchant_name,

        merchant_address,

        Dict{String,Resource}(),

        Dict{UUID,PaymentRequest}(),

        Dict{UUID,BlockchainPayment}(),

        Dict{String,AccessToken}(),

        Set{String}(),

        minimum_confirmations,

        Dict{USDTNetwork,String}()

    )

end


# ============================================================
# CONFIGURE TOKEN CONTRACT
# ============================================================

function set_token_contract!(

    paywall::Paywall,

    network::USDTNetwork,

    contract::String

)

    paywall.token_contracts[
        network
    ] = contract

end


# ============================================================
# ADD RESOURCE
# ============================================================

function add_resource!(

    paywall::Paywall,

    id::String,

    title::String,

    content::String,

    price::USDT,

    network::USDTNetwork

)

    price.units > 0 ||
        error(
            "Resource price must be positive."
        )

    paywall.resources[id] =
        Resource(
            id,
            title,
            content,
            price,
            network
        )

    paywall.resources[id]

end


# ============================================================
# RESOURCE LOOKUP
# ============================================================

function resource(

    paywall::Paywall,

    id::String

)

    haskey(
        paywall.resources,
        id
    ) ||
        error(
            "Resource not found."
        )

    paywall.resources[id]

end


# ============================================================
# CREATE PAYMENT REQUEST
# ============================================================

function create_payment_request!(

    paywall::Paywall,

    resource_id::String;

    lifetime_seconds=900

)

    r =
        resource(
            paywall,
            resource_id
        )

    request =

        PaymentRequest(

            uuid4(),

            resource_id,

            r.price,

            r.network,

            paywall.merchant_address,

            now(),

            now() +
            Second(lifetime_seconds),

            :pending
        )

    paywall.requests[
        request.id
    ] = request

    request

end


# ============================================================
# PAYMENT REQUEST VALIDITY
# ============================================================

function request_valid(

    request::PaymentRequest

)

    request.status ==
        :pending &&
        now() <=
        request.expires_at

end


# ============================================================
# PAYMENT HASH
# ============================================================

function payment_identifier(

    tx::BlockchainPayment

)

    payload =
        join(
            [
                tx.tx_hash,
                string(tx.network),
                tx.token_address,
                tx.sender_address,
                tx.receiver_address,
                string(tx.amount.units),
                string(tx.block_number)
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
# VERIFY PAYMENT
# ============================================================
#
# This is the critical security boundary.
#
# A real chain adapter must verify:
#
#   1. transaction exists
#   2. correct network
#   3. correct token contract
#   4. correct recipient
#   5. correct amount
#   6. correct transaction status
#   7. sufficient confirmations
#   8. transaction has not already been consumed
#
# ============================================================

function verify_payment(

    paywall::Paywall,

    request::PaymentRequest,

    tx::BlockchainPayment

)

    # --------------------------------------------------------
    # Request
    # --------------------------------------------------------

    request_valid(request) ||
        return false,
        "Payment request expired or already completed."

    # --------------------------------------------------------
    # Network
    # --------------------------------------------------------

    tx.network ==
        request.network ||
        return false,
        "Incorrect blockchain network."

    # --------------------------------------------------------
    # Recipient
    # --------------------------------------------------------

    lowercase(
        tx.receiver_address
    ) ==
    lowercase(
        request.merchant_address
    ) ||
        return false,
        "Incorrect recipient address."

    # --------------------------------------------------------
    # Amount
    # --------------------------------------------------------

    tx.amount >=
        request.amount ||
        return false,
        "Insufficient payment."

    # --------------------------------------------------------
    # Confirmations
    # --------------------------------------------------------

    tx.confirmations >=
        paywall.minimum_confirmations ||
        return false,
        "Insufficient confirmations."

    # --------------------------------------------------------
    # Token contract
    # --------------------------------------------------------

    if haskey(
        paywall.token_contracts,
        tx.network
    )

        expected =
            paywall.token_contracts[
                tx.network
            ]

        lowercase(
            tx.token_address
        ) ==
        lowercase(
            expected
        ) ||
            return false,
            "Incorrect token contract."

    end

    # --------------------------------------------------------
    # Replay protection
    # --------------------------------------------------------

    tx.tx_hash in
        paywall.used_transactions &&
        return false,
        "Transaction already consumed."

    return true, ""

end


# ============================================================
# CREATE ACCESS TOKEN
# ============================================================

function generate_access_token()

    raw =
        string(
            uuid4(),
            "-",
            uuid4(),
            "-",
            now()
        )

    bytes2hex(
        sha256(
            codeunits(raw)
        )
    )

end


# ============================================================
# UNLOCK RESOURCE
# ============================================================

function unlock!(

    paywall::Paywall,

    request_id::UUID,

    tx::BlockchainPayment;

    access_lifetime_seconds=3600

)

    haskey(
        paywall.requests,
        request_id
    ) ||
        error(
            "Payment request does not exist."
        )

    request =
        paywall.requests[
            request_id
        ]

    valid, reason =
        verify_payment(
            paywall,
            request,
            tx
        )

    valid ||
        error(
            reason
        )

    payment_id =
        uuid4()

    paywall.payments[
        payment_id
    ] =
        tx

    push!(
        paywall.used_transactions,
        tx.tx_hash
    )

    request.status =
        :paid

    token =
        generate_access_token()

    access =
        AccessToken(

            token,

            request.resource_id,

            payment_id,

            now(),

            now() +
            Second(
                access_lifetime_seconds
            ),

            false
        )

    paywall.access_tokens[
        token
    ] =
        access

    access

end


# ============================================================
# VALIDATE ACCESS
# ============================================================

function validate_access(

    paywall::Paywall,

    token::String,

    resource_id::String

)

    haskey(
        paywall.access_tokens,
        token
    ) ||
        return false

    access =
        paywall.access_tokens[
            token
        ]

    access.resource_id ==
        resource_id ||
        return false

    now() <=
        access.expires_at ||
        return false

    access.used ||
        return true

end


# ============================================================
# READ PROTECTED RESOURCE
# ============================================================

function read_resource(

    paywall::Paywall,

    token::String,

    resource_id::String

)

    validate_access(
        paywall,
        token,
        resource_id
    ) ||
        error(
            "PAYWALL: payment required."
        )

    r =
        resource(
            paywall,
            resource_id
        )

    r.content

end


# ============================================================
# ONE-TIME ACCESS
# ============================================================

function consume_access!(

    paywall::Paywall,

    token::String,

    resource_id::String

)

    validate_access(
        paywall,
        token,
        resource_id
    ) ||
        error(
            "PAYWALL: payment required."
        )

    access =
        paywall.access_tokens[
            token
        ]

    access.used =
        true

    resource(
        paywall,
        resource_id
    ).content

end


# ============================================================
# PAYMENT PAGE DATA
# ============================================================

function payment_page(

    paywall::Paywall,

    request::PaymentRequest

)

    """

    ┌──────────────────────────────────────────────┐
    │              TETHER PAYWALL                  │
    │                                              │
    │              PAYMENT REQUIRED               │
    │                                              │
    │                 $(usdt_string(request.amount))             │
    │                                              │
    │ Network: $(network_string(request.network))                  │
    │                                              │
    │ Send USDT to:                               │
    │ $(request.merchant_address)                 │
    │                                              │
    │ Reference: $(request.id)                    │
    │                                              │
    │ Expires: $(request.expires_at)              │
    └──────────────────────────────────────────────┘

    """

end


# ============================================================
# API-STYLE REQUEST ROUTER
# ============================================================

function route(

    paywall::Paywall,

    method::String,

    path::String;

    token=nothing

)

    # --------------------------------------------------------
    # GET RESOURCE
    # --------------------------------------------------------

    if method == "GET"

        if startswith(
            path,
            "/resource/"
        )

            resource_id =
                split(
                    path,
                    "/"
                )[3]

            if token === nothing

                request =
                    create_payment_request!(
                        paywall,
                        resource_id
                    )

                return (
                    status = 402,
                    type = "PAYMENT_REQUIRED",
                    request_id =
                        string(request.id),
                    amount =
                        usdt_string(
                            request.amount
                        ),
                    network =
                        network_string(
                            request.network
                        ),
                    address =
                        request.merchant_address
                )

            end

            if validate_access(
                paywall,
                token,
                resource_id
            )

                return (
                    status = 200,
                    type = "CONTENT",
                    content =
                        resource(
                            paywall,
                            resource_id
                        ).content
                )

            end

            return (
                status = 402,
                type = "PAYMENT_REQUIRED"
            )

        end

    end

    return (
        status = 404,
        type = "NOT_FOUND"
    )

end


# ============================================================
# PAYMENT RECEIPT
# ============================================================

function receipt(

    paywall::Paywall,

    request_id::UUID

)

    request =
        paywall.requests[
            request_id
        ]

    (

        request_id =
            request.id,

        resource =
            request.resource_id,

        amount =
            usdt_string(
                request.amount
            ),

        network =
            network_string(
                request.network
            ),

        recipient =
            request.merchant_address,

        status =
            request.status,

        expires =
            request.expires_at
    )

end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println()
    println("="^72)
    println("                    TETHER PAYWALL")
    println("                      PURE JULIA")
    println("="^72)

    # --------------------------------------------------------
    # Merchant
    # --------------------------------------------------------

    merchant_address =
        "TRON_MERCHANT_ADDRESS"

    paywall =
        Paywall(
            "OpenAllHours",
            merchant_address;
            minimum_confirmations=3
        )

    # --------------------------------------------------------
    # Current USDT TRC20 contract
    #
    # Tether's official supported-protocol documentation
    # currently identifies:
    #
    # TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t
    #
    # for USD₮ on Tron.
    # --------------------------------------------------------

    set_token_contract!(
        paywall,
        TRON,
        "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
    )

    # --------------------------------------------------------
    # Protected content
    # --------------------------------------------------------

    add_resource!(
        paywall,

        "article-001",

        "The Future of Pub Technology",

        """
        THIS IS PREMIUM CONTENT.

        Congratulations.

        Your USDT payment has unlocked the article.

        Micro-payments can now gate:
        - articles
        - APIs
        - software
        - video
        - music
        - downloads
        - machine services
        """,

        USDT(0.01),

        TRON
    )

    # --------------------------------------------------------
    # Customer requests article
    # --------------------------------------------------------

    response =
        route(
            paywall,
            "GET",
            "/resource/article-001"
        )

    println()
    println(
        "Initial request:"
    )

    println(
        response
    )

    request =
        paywall.requests[
            UUID(
                response.request_id
            )
        ]

    println()
    println(
        payment_page(
            paywall,
            request
        )
    )

    # --------------------------------------------------------
    # Simulated blockchain payment
    # --------------------------------------------------------

    tx =
        BlockchainPayment(

            "SIMULATED_TRON_TX_001",

            TRON,

            "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",

            "TRON_CUSTOMER_ADDRESS",

            merchant_address,

            USDT(0.01),

            12345678,

            12,

            now()
        )

    # --------------------------------------------------------
    # Verify + unlock
    # --------------------------------------------------------

    access =
        unlock!(
            paywall,
            request.id,
            tx
        )

    println()
    println(
        "Payment verified."
    )

    println(
        "Access token:"
    )

    println(
        access.token
    )

    # --------------------------------------------------------
    # Access protected content
    # --------------------------------------------------------

    content =
        read_resource(
            paywall,
            access.token,
            "article-001"
        )

    println()
    println(
        "UNLOCKED CONTENT:"
    )

    println(
        content
    )

    println()
    println("="^72)

end


# ============================================================
# EXPORTS
# ============================================================

export USDT
export USDTNetwork

export ETHEREUM
export TRON
export SOLANA
export TON
export AVALANCHE
export CELO
export APTOS
export NEAR

export Resource
export PaymentRequest
export BlockchainPayment
export AccessToken
export Paywall

export add_resource!
export create_payment_request!
export verify_payment
export unlock!

export validate_access
export read_resource
export consume_access!

export payment_page
export receipt
export route

export set_token_contract!

export usdt_string
export network_string

export demo


end # module


# ============================================================
# RUN DEMO
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .TetherPaywall

    TetherPaywall.demo()

end
```

