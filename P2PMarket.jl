# P2P PREDICTION MARKET — PURE JULIA

```julia
module P2PMarket

using Dates
using UUIDs
using Printf


# ============================================================
# PLAY-MONEY
# ============================================================

const CREDITS_PER_UNIT = 1_000_000


struct Credits

    units::Int64

end


Credits(x::Integer) =
    Credits(Int64(x))


Credits(x::Real) =
    Credits(
        round(
            Int64,
            x * CREDITS_PER_UNIT
        )
    )


Base.:+(a::Credits, b::Credits) =
    Credits(a.units + b.units)


Base.:-(a::Credits, b::Credits) =
    Credits(a.units - b.units)


Base.isless(a::Credits, b::Credits) =
    a.units < b.units


Base.:(==)(a::Credits, b::Credits) =
    a.units == b.units


function show_credits(
    x::Credits
)

    whole =
        x.units ÷ CREDITS_PER_UNIT

    fraction =
        abs(
            x.units % CREDITS_PER_UNIT
        )

    @sprintf(
        "%d.%06d",
        whole,
        fraction
    )

end


# ============================================================
# OUTCOME
# ============================================================

@enum Outcome begin

    YES
    NO

end


# ============================================================
# ORDER SIDE
# ============================================================

@enum Side begin

    BUY
    SELL

end


# ============================================================
# USER
# ============================================================

mutable struct User

    id::String

    name::String

    balance::Credits

    yes_position::Int

    no_position::Int

end


function User(
    name::String;
    balance=Credits(1000)
)

    User(
        string(uuid4()),
        name,
        balance,
        0,
        0
    )

end


# ============================================================
# ORDER
# ============================================================

mutable struct Order

    id::String

    user_id::String

    outcome::Outcome

    side::Side

    quantity::Int

    price::Float64

    remaining::Int

    created_at::DateTime

end


function Order(

    user_id::String,

    outcome::Outcome,

    side::Side,

    quantity::Int,

    price::Float64

)

    0.0 < price < 1.0 ||
        error(
            "Prediction-market price must be between 0 and 1."
        )

    quantity > 0 ||
        error(
            "Quantity must be positive."
        )

    Order(

        string(uuid4()),

        user_id,

        outcome,

        side,

        quantity,

        price,

        quantity,

        now()

    )

end


# ============================================================
# TRADE
# ============================================================

struct Trade

    id::String

    market_id::String

    buy_order::String

    sell_order::String

    outcome::Outcome

    quantity::Int

    price::Float64

    timestamp::DateTime

end


# ============================================================
# MARKET
# ============================================================

mutable struct Market

    id::String

    question::String

    yes_orders::Vector{Order}

    no_orders::Vector{Order}

    trades::Vector{Trade}

    status::Symbol

    resolution::Union{Nothing,Outcome}

    created_at::DateTime

end


function Market(
    question::String
)

    Market(

        string(uuid4()),

        question,

        Order[],

        Order[],

        Trade[],

        :OPEN,

        nothing,

        now()

    )

end


# ============================================================
# EXCHANGE
# ============================================================

mutable struct Exchange

    users::Dict{String,User}

    markets::Dict{String,Market}

end


Exchange() =
    Exchange(

        Dict{String,User}(),

        Dict{String,Market}()

    )


# ============================================================
# USER MANAGEMENT
# ============================================================

function add_user!(
    exchange::Exchange,
    user::User
)

    exchange.users[
        user.id
    ] = user

    user

end


function user(
    exchange::Exchange,
    id::String
)

    haskey(
        exchange.users,
        id
    ) ||
        error(
            "User not found."
        )

    exchange.users[id]

end


# ============================================================
# MARKET MANAGEMENT
# ============================================================

function create_market!(
    exchange::Exchange,
    question::String
)

    market =
        Market(
            question
        )

    exchange.markets[
        market.id
    ] = market

    market

end


# ============================================================
# ORDER VALIDATION
# ============================================================

function validate_order!(
    exchange::Exchange,
    market::Market,
    order::Order
)

    market.status == :OPEN ||
        error(
            "Market is not open."
        )

    u =
        user(
            exchange,
            order.user_id
        )

    required =
        Credits(
            round(
                Int64,
                order.quantity *
                order.price *
                CREDITS_PER_UNIT
            )
        )

    if order.side == BUY

        u.balance >= required ||
            error(
                "Insufficient play-money balance."
            )

    end

    nothing

end


# ============================================================
# ORDER BOOK
# ============================================================

function orderbook(
    market::Market,
    outcome::Outcome
)

    orders =
        outcome == YES ?
        market.yes_orders :
        market.no_orders

    buys =
        filter(
            x -> x.side == BUY &&
                 x.remaining > 0,
            orders
        )

    sells =
        filter(
            x -> x.side == SELL &&
                 x.remaining > 0,
            orders
        )

    sort!(
        buys,
        by=x -> -x.price
    )

    sort!(
        sells,
        by=x -> x.price
    )

    (
        bids = buys,
        asks = sells
    )

end


# ============================================================
# ADD ORDER
# ============================================================

function place_order!(
    exchange::Exchange,
    market_id::String,
    order::Order
)

    market =
        exchange.markets[
            market_id
        ]

    validate_order!(
        exchange,
        market,
        order
    )

    if order.outcome == YES

        push!(
            market.yes_orders,
            order
        )

    else

        push!(
            market.no_orders,
            order
        )

    end

    match_orders!(
        exchange,
        market,
        order.outcome
    )

    order

end


# ============================================================
# MATCH ENGINE
# ============================================================

function match_orders!(
    exchange::Exchange,
    market::Market,
    outcome::Outcome
)

    orders =
        outcome == YES ?
        market.yes_orders :
        market.no_orders

    while true

        buys =
            filter(
                x ->
                    x.side == BUY &&
                    x.remaining > 0,
                orders
            )

        sells =
            filter(
                x ->
                    x.side == SELL &&
                    x.remaining > 0,
                orders
            )

        isempty(buys) &&
            break

        isempty(sells) &&
            break

        sort!(
            buys,
            by=x -> -x.price
        )

        sort!(
            sells,
            by=x -> x.price
        )

        buyer =
            buys[1]

        seller =
            sells[1]

        buyer.price >= seller.price ||
            break

        quantity =
            min(
                buyer.remaining,
                seller.remaining
            )

        # ----------------------------------------------------
        # Price-time matching
        # ----------------------------------------------------

        execution_price =
            seller.price

        execute_trade!(
            exchange,
            market,
            buyer,
            seller,
            quantity,
            execution_price
        )

    end

end


# ============================================================
# EXECUTE TRADE
# ============================================================

function execute_trade!(

    exchange::Exchange,

    market::Market,

    buyer::Order,

    seller::Order,

    quantity::Int,

    price::Float64

)

    buyer_user =
        user(
            exchange,
            buyer.user_id
        )

    seller_user =
        user(
            exchange,
            seller.user_id
        )

    cost =
        Credits(
            round(
                Int64,
                quantity *
                price *
                CREDITS_PER_UNIT
            )
        )

    # --------------------------------------------------------
    # Transfer play-money
    # --------------------------------------------------------

    buyer_user.balance -=
        cost

    seller_user.balance +=
        cost

    # --------------------------------------------------------
    # Position update
    # --------------------------------------------------------

    if buyer.outcome == YES

        buyer_user.yes_position +=
            quantity

    else

        buyer_user.no_position +=
            quantity

    end


    if seller.outcome == YES

        seller_user.yes_position -=
            quantity

    else

        seller_user.no_position -=
            quantity

    end

    # --------------------------------------------------------
    # Order quantities
    # --------------------------------------------------------

    buyer.remaining -=
        quantity

    seller.remaining -=
        quantity

    # --------------------------------------------------------
    # Trade record
    # --------------------------------------------------------

    trade =
        Trade(

            string(uuid4()),

            market.id,

            buyer.id,

            seller.id,

            buyer.outcome,

            quantity,

            price,

            now()

        )

    push!(
        market.trades,
        trade
    )

    trade

end


# ============================================================
# MARKET PRICE
# ============================================================

function market_price(

    market::Market,

    outcome::Outcome

)

    book =
        orderbook(
            market,
            outcome
        )

    isempty(book.bids) &&
    isempty(book.asks) &&
        return nothing

    if !isempty(book.bids) &&
       !isempty(book.asks)

        return (
            book.bids[1].price +
            book.asks[1].price
        ) / 2

    elseif !isempty(book.bids)

        return book.bids[1].price

    else

        return book.asks[1].price

    end

end


# ============================================================
# MARKET RESOLUTION
# ============================================================

function resolve_market!(

    exchange::Exchange,

    market_id::String,

    outcome::Outcome

)

    market =
        exchange.markets[
            market_id
        ]

    market.status == :OPEN ||
        error(
            "Market already resolved."
        )

    market.resolution =
        outcome

    market.status =
        :RESOLVED

    settle_market!(
        exchange,
        market
    )

    market

end


# ============================================================
# SETTLEMENT
# ============================================================

function settle_market!(
    exchange::Exchange,
    market::Market
)

    winning =
        market.resolution

    for u in values(
        exchange.users
    )

        position =
            winning == YES ?
            u.yes_position :
            u.no_position

        if position > 0

            payout =
                Credits(
                    position
                )

            u.balance +=
                payout

        end

    end

end


# ============================================================
# MARKET SUMMARY
# ============================================================

function market_summary(

    exchange::Exchange,

    market_id::String

)

    market =
        exchange.markets[
            market_id
        ]

    yes_price =
        market_price(
            market,
            YES
        )

    no_price =
        market_price(
            market,
            NO
        )

    (

        id = market.id,

        question = market.question,

        status = market.status,

        yes_price = yes_price,

        no_price = no_price,

        trades =
            length(
                market.trades
            ),

        resolution =
            market.resolution

    )

end


# ============================================================
# USER PORTFOLIO
# ============================================================

function portfolio(

    exchange::Exchange,

    user_id::String

)

    u =
        user(
            exchange,
            user_id
        )

    (

        user = u.name,

        balance =
            show_credits(
                u.balance
            ),

        yes =
            u.yes_position,

        no =
            u.no_position

    )

end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println()
    println(
        "="^72
    )

    println(
        "              P2P PREDICTION MARKET"
    )

    println(
        "                 PURE JULIA"
    )

    println(
        "="^72
    )


    exchange =
        Exchange()


    # --------------------------------------------------------
    # USERS
    # --------------------------------------------------------

    alice =
        add_user!(
            exchange,
            User(
                "Alice";
                balance=Credits(1000)
            )
        )


    bob =
        add_user!(
            exchange,
            User(
                "Bob";
                balance=Credits(1000)
            )
        )


    # --------------------------------------------------------
    # MARKET
    # --------------------------------------------------------

    market =
        create_market!(
            exchange,

            "Will BTC exceed the specified threshold by settlement?"
        )


    println()
    println(
        "Market:"
    )

    println(
        market.question
    )


    # --------------------------------------------------------
    # ALICE BUYS YES
    # --------------------------------------------------------

    buy_yes =
        Order(

            alice.id,

            YES,

            BUY,

            100,

            0.60

        )


    place_order!(
        exchange,
        market.id,
        buy_yes
    )


    # --------------------------------------------------------
    # BOB SELLS YES
    # --------------------------------------------------------

    sell_yes =
        Order(

            bob.id,

            YES,

            SELL,

            100,

            0.55

        )


    place_order!(
        exchange,
        market.id,
        sell_yes
    )


    # --------------------------------------------------------
    # RESULT
    # --------------------------------------------------------

    println()
    println(
        "Market price:"
    )

    println(
        market_price(
            market,
            YES
        )
    )


    println()
    println(
        "Trades:"
    )

    for trade in market.trades

        println(
            "YES ",
            trade.quantity,
            " @ ",
            trade.price
        )

    end


    # --------------------------------------------------------
    # RESOLVE
    # --------------------------------------------------------

    resolve_market!(
        exchange,
        market.id,
        YES
    )


    println()
    println(
        "Market resolved: YES"
    )


    println()
    println(
        "Alice:"
    )

    println(
        portfolio(
            exchange,
            alice.id
        )
    )


    println()
    println(
        "Bob:"
    )

    println(
        portfolio(
            exchange,
            bob.id
        )
    )


    println()
    println(
        "="^72
    )

end


# ============================================================
# EXPORTS
# ============================================================

export Credits

export YES
export NO

export BUY
export SELL

export User
export Order
export Trade
export Market
export Exchange

export add_user!
export create_market!
export place_order!

export orderbook
export market_price

export resolve_market!
export market_summary
export portfolio

export demo


end # module


# ============================================================
# RUN
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .P2PMarket

    P2PMarket.demo()

end
```

