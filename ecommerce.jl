# TETHERSHOP — FULL-STACK USDT ECOMMERCE IN PURE JULIA

```julia
module TetherShop

using HTTP
using SQLite
using DBInterface
using UUIDs
using Dates
using SHA
using Printf


# ============================================================
# CONFIGURATION
# ============================================================

const APP_NAME = "TetherShop"

const USDT_DECIMALS = 6
const USDT_UNIT = Int64(1_000_000)


# ============================================================
# MONEY
# ============================================================

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
    USDT(a.units + b.units)


Base.:-(a::USDT, b::USDT) =
    USDT(a.units - b.units)


Base.:(==)(a::USDT, b::USDT) =
    a.units == b.units


Base.isless(a::USDT, b::USDT) =
    a.units < b.units


function money(
    x::USDT
)

    whole =
        x.units ÷ USDT_UNIT

    fractional =
        abs(
            x.units % USDT_UNIT
        )

    @sprintf(
        "%d.%06d USDT",
        whole,
        fractional
    )

end


# ============================================================
# NETWORKS
# ============================================================

@enum Network begin

    ETHEREUM
    TRON
    SOLANA
    TON
    AVALANCHE
    CELO
    APTOS
    NEAR

end


network_name(n::Network) =
    string(n)


# ============================================================
# DATABASE
# ============================================================

mutable struct Store

    db::SQLite.DB

end


function Store(
    filename::String="tethershop.db"
)

    db =
        SQLite.DB(filename)

    initialise_database!(
        db
    )

    Store(db)

end


function initialise_database!(
    db::SQLite.DB
)

    DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS products (

            id TEXT PRIMARY KEY,

            name TEXT NOT NULL,

            description TEXT,

            price_units INTEGER NOT NULL,

            stock INTEGER NOT NULL,

            image TEXT,

            active INTEGER NOT NULL DEFAULT 1

        )
        """
    )


    DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS customers (

            id TEXT PRIMARY KEY,

            email TEXT UNIQUE NOT NULL,

            name TEXT,

            created_at TEXT NOT NULL

        )
        """
    )


    DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS orders (

            id TEXT PRIMARY KEY,

            customer_id TEXT,

            total_units INTEGER NOT NULL,

            network TEXT NOT NULL,

            status TEXT NOT NULL,

            payment_address TEXT,

            payment_reference TEXT,

            created_at TEXT NOT NULL

        )
        """
    )


    DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS order_items (

            id TEXT PRIMARY KEY,

            order_id TEXT NOT NULL,

            product_id TEXT NOT NULL,

            quantity INTEGER NOT NULL,

            price_units INTEGER NOT NULL

        )
        """
    )


    DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS payments (

            id TEXT PRIMARY KEY,

            order_id TEXT NOT NULL,

            tx_hash TEXT UNIQUE,

            network TEXT NOT NULL,

            amount_units INTEGER NOT NULL,

            sender TEXT,

            receiver TEXT,

            confirmations INTEGER DEFAULT 0,

            status TEXT NOT NULL,

            created_at TEXT NOT NULL

        )
        """
    )


    DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS sessions (

            token TEXT PRIMARY KEY,

            customer_id TEXT,

            created_at TEXT NOT NULL,

            expires_at TEXT NOT NULL

        )
        """
    )

end


# ============================================================
# PRODUCTS
# ============================================================

struct Product

    id::String

    name::String

    description::String

    price::USDT

    stock::Int

    image::String

end


function add_product!(
    store::Store,

    name::String,

    description::String,

    price::USDT,

    stock::Int;

    image=""

)

    id =
        string(
            uuid4()
        )

    DBInterface.execute(
        store.db,

        """
        INSERT INTO products
        (id,name,description,price_units,stock,image)
        VALUES (?,?,?,?,?,?)
        """,

        (
            id,
            name,
            description,
            price.units,
            stock,
            image
        )
    )

    id

end


function products(
    store::Store
)

    rows =
        DBInterface.execute(
            store.db,
            """
            SELECT
                id,
                name,
                description,
                price_units,
                stock,
                image
            FROM products
            WHERE active = 1
            ORDER BY name
            """
        )

    collect(rows)

end


function get_product(
    store::Store,
    id::String
)

    rows =
        DBInterface.execute(
            store.db,

            """
            SELECT
                id,
                name,
                description,
                price_units,
                stock,
                image
            FROM products
            WHERE id = ?
            """,

            (id,)
        )

    result =
        collect(rows)

    isempty(result) &&
        error(
            "Product not found."
        )

    result[1]

end


# ============================================================
# CART
# ============================================================

mutable struct CartItem

    product_id::String

    quantity::Int

end


mutable struct Cart

    items::Dict{String,Int}

end


Cart() =
    Cart(
        Dict{String,Int}()
    )


function add_to_cart!(
    cart::Cart,
    product_id::String,
    quantity::Int
)

    quantity > 0 ||
        error(
            "Quantity must be positive."
        )

    cart.items[
        product_id
    ] =
        get(
            cart.items,
            product_id,
            0
        ) +
        quantity

    cart

end


function remove_from_cart!(
    cart::Cart,
    product_id::String
)

    delete!(
        cart.items,
        product_id
    )

    cart

end


# ============================================================
# CART TOTAL
# ============================================================

function cart_total(
    store::Store,
    cart::Cart
)

    total =
        Int64(0)

    for (
        product_id,
        quantity
    ) in cart.items

        p =
            get_product(
                store,
                product_id
            )

        total +=
            Int64(
                p.price_units
            ) *
            quantity

    end

    USDT(total)

end


# ============================================================
# CUSTOMERS
# ============================================================

function create_customer!(
    store::Store,

    email::String,

    name::String
)

    id =
        string(
            uuid4()
        )

    DBInterface.execute(
        store.db,

        """
        INSERT INTO customers
        (id,email,name,created_at)
        VALUES (?,?,?,?)
        """,

        (
            id,
            email,
            name,
            string(now())
        )
    )

    id

end


# ============================================================
# SESSION
# ============================================================

function create_session!(
    store::Store,
    customer_id::String
)

    token =
        bytes2hex(
            sha256(
                codeunits(
                    string(
                        uuid4(),
                        uuid4(),
                        now()
                    )
                )
            )
        )

    created =
        now()

    expires =
        created +
        Hour(24)

    DBInterface.execute(
        store.db,

        """
        INSERT INTO sessions
        (token,customer_id,created_at,expires_at)
        VALUES (?,?,?,?)
        """,

        (
            token,
            customer_id,
            string(created),
            string(expires)
        )
    )

    token

end


# ============================================================
# PAYMENT ADDRESS
# ============================================================

struct PaymentAddress

    network::Network

    address::String

end


# ============================================================
# PAYMENT GATEWAY
# ============================================================

abstract type AbstractUSDTGateway end


"""
Reference gateway.

A real implementation would connect to a blockchain
RPC/indexer and independently verify transactions.
"""
struct USDTGateway <:
    AbstractUSDTGateway

    network::Network

    merchant_address::String

end


# ============================================================
# PAYMENT REQUEST
# ============================================================

struct PaymentRequest

    order_id::String

    amount::USDT

    network::Network

    address::String

    reference::String

end


function create_payment_request(
    gateway::USDTGateway,
    order_id::String,
    amount::USDT
)

    PaymentRequest(

        order_id,

        amount,

        gateway.network,

        gateway.merchant_address,

        string(
            "ORDER-",
            order_id
        )

    )

end


# ============================================================
# PAYMENT VERIFICATION
# ============================================================

struct VerifiedPayment

    tx_hash::String

    network::Network

    amount::USDT

    sender::String

    receiver::String

    confirmations::Int

end


"""
This function is deliberately a security boundary.

The client must NEVER be allowed to submit an arbitrary
"paid=true" value.

A production gateway should verify:

    - transaction exists
    - correct blockchain
    - correct USDT token
    - correct recipient
    - correct amount
    - successful transaction
    - sufficient confirmations
    - transaction has not already been used

The reference implementation rejects by default.
"""
function verify_payment(
    gateway::USDTGateway,
    request::PaymentRequest,
    tx::VerifiedPayment
)

    tx.network ==
        request.network ||
        return false

    lowercase(
        tx.receiver
    ) ==
    lowercase(
        request.address
    ) ||
        return false

    tx.amount >=
        request.amount ||
        return false

    tx.confirmations >=
        3 ||
        return false

    true

end


# ============================================================
# ORDER
# ============================================================

function create_order!(
    store::Store,

    cart::Cart,

    customer_id::String,

    network::Network,

    payment_address::String
)

    isempty(cart.items) &&
        error(
            "Cart is empty."
        )

    order_id =
        string(
            uuid4()
        )

    total =
        cart_total(
            store,
            cart
        )

    reference =
        "ORDER-" *
        order_id

    DBInterface.execute(
        store.db,

        """
        INSERT INTO orders
        (
            id,
            customer_id,
            total_units,
            network,
            status,
            payment_address,
            payment_reference,
            created_at
        )
        VALUES (?,?,?,?,?,?,?,?)
        """,

        (
            order_id,
            customer_id,
            total.units,
            string(network),
            "AWAITING_PAYMENT",
            payment_address,
            reference,
            string(now())
        )
    )


    for (
        product_id,
        quantity
    ) in cart.items

        p =
            get_product(
                store,
                product_id
            )

        quantity <=
            p.stock ||
            error(
                "Insufficient inventory."
            )

        item_id =
            string(
                uuid4()
            )

        DBInterface.execute(
            store.db,

            """
            INSERT INTO order_items
            (
                id,
                order_id,
                product_id,
                quantity,
                price_units
            )
            VALUES (?,?,?,?,?)
            """,

            (
                item_id,
                order_id,
                product_id,
                quantity,
                p.price_units
            )
        )

    end

    order_id

end


# ============================================================
# RESERVE INVENTORY
# ============================================================

function reserve_inventory!(
    store::Store,
    order_id::String
)

    rows =
        DBInterface.execute(
            store.db,

            """
            SELECT
                product_id,
                quantity
            FROM order_items
            WHERE order_id = ?
            """,

            (order_id,)
        )

    for row in rows

        DBInterface.execute(
            store.db,

            """
            UPDATE products
            SET stock = stock - ?
            WHERE id = ?
            AND stock >= ?
            """,

            (
                row.quantity,
                row.product_id,
                row.quantity
            )
        )

    end

end


# ============================================================
# PAYMENT RECORD
# ============================================================

function record_payment!(
    store::Store,

    order_id::String,

    payment::VerifiedPayment
)

    payment_id =
        string(
            uuid4()
        )

    DBInterface.execute(
        store.db,

        """
        INSERT INTO payments
        (
            id,
            order_id,
            tx_hash,
            network,
            amount_units,
            sender,
            receiver,
            confirmations,
            status,
            created_at
        )
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """,

        (
            payment_id,
            order_id,
            payment.tx_hash,
            string(payment.network),
            payment.amount.units,
            payment.sender,
            payment.receiver,
            payment.confirmations,
            "CONFIRMED",
            string(now())
        )
    )

    DBInterface.execute(
        store.db,

        """
        UPDATE orders
        SET status = 'PAID'
        WHERE id = ?
        """,

        (order_id,)
    )

    reserve_inventory!(
        store,
        order_id
    )

    payment_id

end


# ============================================================
# ORDER LOOKUP
# ============================================================

function get_order(
    store::Store,
    order_id::String
)

    rows =
        DBInterface.execute(
            store.db,

            """
            SELECT *
            FROM orders
            WHERE id = ?
            """,

            (order_id,)
        )

    result =
        collect(rows)

    isempty(result) &&
        error(
            "Order not found."
        )

    result[1]

end


# ============================================================
# HTML
# ============================================================

function html_page(
    title::String,
    body::String
)

    """
    <!DOCTYPE html>

    <html>

    <head>

        <meta charset="UTF-8">

        <meta
            name="viewport"
            content="width=device-width,initial-scale=1"
        >

        <title>
            $(title) — $(APP_NAME)
        </title>

        <style>

            :root {
                --bg: #0b0d10;
                --panel: #151920;
                --text: #f2f4f7;
                --muted: #9da5b1;
                --accent: #26a17b;
                --border: #2a3039;
            }

            * {
                box-sizing: border-box;
            }

            body {
                margin: 0;
                background: var(--bg);
                color: var(--text);
                font-family:
                    Inter,
                    system-ui,
                    sans-serif;
            }

            header {
                border-bottom:
                    1px solid var(--border);
                padding: 20px 40px;
                display: flex;
                justify-content: space-between;
                align-items: center;
            }

            .logo {
                font-size: 24px;
                font-weight: 800;
            }

            .logo span {
                color: var(--accent);
            }

            main {
                max-width: 1200px;
                margin: auto;
                padding: 50px 24px;
            }

            .grid {
                display: grid;
                grid-template-columns:
                    repeat(
                        auto-fit,
                        minmax(240px,1fr)
                    );
                gap: 24px;
            }

            .card {
                background: var(--panel);
                border:
                    1px solid var(--border);
                border-radius: 16px;
                padding: 24px;
            }

            .price {
                color: var(--accent);
                font-size: 22px;
                font-weight: 800;
                margin: 20px 0;
            }

            button {
                border: 0;
                border-radius: 10px;
                padding: 12px 18px;
                background: var(--accent);
                color: white;
                font-weight: 700;
                cursor: pointer;
            }

            .muted {
                color: var(--muted);
            }

            .payment {
                max-width: 700px;
                margin: auto;
                text-align: center;
            }

            .address {
                background: #080a0d;
                border: 1px solid var(--border);
                padding: 20px;
                border-radius: 10px;
                word-break: break-all;
                margin: 20px 0;
            }

        </style>

    </head>

    <body>

        <header>

            <div class="logo">
                Tether<span>Shop</span>
            </div>

            <div class="muted">
                USDT ONLY
            </div>

        </header>

        <main>

            $(body)

        </main>

    </body>

    </html>
    """

end


# ============================================================
# STOREFRONT
# ============================================================

function storefront(
    store::Store
)

    rows =
        products(
            store
        )

    cards =
        String[]

    for p in rows

        push!(
            cards,

            """
            <div class="card">

                <h2>
                    $(p.name)
                </h2>

                <p class="muted">
                    $(p.description)
                </p>

                <div class="price">
                    $(money(USDT(p.price_units)))
                </div>

                <p class="muted">
                    $(p.stock) available
                </p>

                <a
                    href="/product/$(p.id)"
                >
                    <button>
                        View product
                    </button>
                </a>

            </div>
            """
        )

    end

    html_page(

        "Store",

        """
        <h1>
            TetherShop
        </h1>

        <p class="muted">
            Digital commerce. Settled exclusively
            in USDT.
        </p>

        <div class="grid">
            $(join(cards,"\n"))
        </div>
        """

    )

end


# ============================================================
# PRODUCT PAGE
# ============================================================

function product_page(
    store::Store,
    product_id::String
)

    p =
        get_product(
            store,
            product_id
        )

    html_page(

        p.name,

        """
        <div class="card">

            <h1>
                $(p.name)
            </h1>

            <p>
                $(p.description)
            </p>

            <div class="price">
                $(money(USDT(p.price_units)))
            </div>

            <p class="muted">
                Stock: $(p.stock)
            </p>

            <form
                method="POST"
                action="/cart/add"
            >

                <input
                    type="hidden"
                    name="product"
                    value="$(p.id)"
                >

                <input
                    type="number"
                    name="quantity"
                    value="1"
                    min="1"
                    max="$(p.stock)"
                >

                <button>
                    Add to cart
                </button>

            </form>

        </div>
        """

    )

end


# ============================================================
# CHECKOUT PAGE
# ============================================================

function checkout_page(
    order,
    request::PaymentRequest
)

    html_page(

        "Checkout",

        """
        <div class="card payment">

            <h1>
                Complete Payment
            </h1>

            <p class="muted">
                Order
            </p>

            <h2>
                $(order.id)
            </h2>

            <div class="price">
                $(money(request.amount))
            </div>

            <p>
                Network:
                <strong>
                    $(network_name(request.network))
                </strong>
            </p>

            <p class="muted">
                Send exactly the required amount
                of USDT to:
            </p>

            <div class="address">
                $(request.address)
            </div>

            <p class="muted">
                Payment reference:
                $(request.reference)
            </p>

            <p class="muted">
                After the blockchain transaction
                confirms, payment will be verified
                automatically.
            </p>

        </div>
        """

    )

end


# ============================================================
# ROUTER
# ============================================================

mutable struct App

    store::Store

    gateway::USDTGateway

    carts::Dict{String,Cart}

end


function App(
    store::Store,
    gateway::USDTGateway
)

    App(
        store,
        gateway,
        Dict{String,Cart}()
    )

end


# ============================================================
# HTTP HANDLER
# ============================================================

function handler(
    app::App,
    request::HTTP.Request
)

    target =
        String(
            request.target
        )

    # --------------------------------------------------------
    # HOME
    # --------------------------------------------------------

    if request.method ==
       "GET" &&
       target == "/"

        return HTTP.Response(

            200,

            ["Content-Type" =>
             "text/html"],

            storefront(
                app.store
            )

        )

    end


    # --------------------------------------------------------
    # PRODUCT
    # --------------------------------------------------------

    if startswith(
        target,
        "/product/"
    )

        id =
            split(
                target,
                "/"
            )[3]

        return HTTP.Response(

            200,

            ["Content-Type" =>
             "text/html"],

            product_page(
                app.store,
                id
            )

        )

    end


    # --------------------------------------------------------
    # CART
    # --------------------------------------------------------

    if target ==
       "/cart"

        session =
            "demo"

        cart =
            get!(
                app.carts,
                session,
                Cart()
            )

        total =
            cart_total(
                app.store,
                cart
            )

        return HTTP.Response(

            200,

            ["Content-Type" =>
             "text/html"],

            html_page(

                "Cart",

                """
                <div class="card">

                    <h1>
                        Your Cart
                    </h1>

                    <p>
                        Total:
                        <strong>
                            $(money(total))
                        </strong>
                    </p>

                    <a href="/checkout">
                        <button>
                            Checkout with USDT
                        </button>
                    </a>

                </div>
                """

            )

        )

    end


    # --------------------------------------------------------
    # CHECKOUT
    # --------------------------------------------------------

    if target ==
       "/checkout"

        session =
            "demo"

        cart =
            get!(
                app.carts,
                session,
                Cart()
            )

        isempty(cart.items) &&
            return HTTP.Response(
                400,
                "Cart is empty."
            )

        total =
            cart_total(
                app.store,
                cart
            )

        order_id =
            create_order!(
                app.store,
                cart,
                "",
                app.gateway.network,
                app.gateway.merchant_address
            )

        request =
            create_payment_request(
                app.gateway,
                order_id,
                total
            )

        order =
            get_order(
                app.store,
                order_id
            )

        return HTTP.Response(

            200,

            ["Content-Type" =>
             "text/html"],

            checkout_page(
                order,
                request
            )

        )

    end


    # --------------------------------------------------------
    # 404
    # --------------------------------------------------------

    HTTP.Response(
        404,
        "Not Found"
    )

end


# ============================================================
# START SERVER
# ============================================================

function start!(
    app::App;

    host="127.0.0.1",

    port=8080

)

    println()
    println(
        "=========================================="
    )

    println(
        "             TetherShop"
    )

    println(
        "=========================================="
    )

    println(
        "Listening on http://",
        host,
        ":",
        port
    )

    println(
        "Payment network: ",
        app.gateway.network
    )

    println(
        "USDT address: ",
        app.gateway.merchant_address
    )

    println(
        "=========================================="
    )

    HTTP.serve!(
        request ->
            handler(
                app,
                request
            ),

        host,
        port
    )

end


# ============================================================
# DEMO STORE
# ============================================================

function demo_store()

    store =
        Store(
            "tethershop.db"
        )

    # --------------------------------------------------------
    # Products
    # --------------------------------------------------------

    if isempty(
        products(store)
    )

        add_product!(
            store,

            "AUREOM T-Shirt",

            "Premium heavyweight cotton shirt.",

            USDT(25),

            100
        )


        add_product!(
            store,

            "AUREOM Cap",

            "Structured six-panel cap.",

            USDT(15),

            250
        )


        add_product!(
            store,

            "Digital Systems Manual",

            "Downloadable technical publication.",

            USDT(5),

            999999
        )

    end

    store

end


# ============================================================
# APPLICATION
# ============================================================

function main()

    store =
        demo_store()

    # --------------------------------------------------------
    # IMPORTANT:
    #
    # Replace this with your actual merchant address.
    #
    # Do not put private keys in this application.
    # --------------------------------------------------------

    gateway =
        USDTGateway(

            TRON,

            "YOUR_USDT_MERCHANT_ADDRESS"

        )

    app =
        App(
            store,
            gateway
        )

    start!(
        app;
        host="127.0.0.1",
        port=8080
    )

end


# ============================================================
# EXPORTS
# ============================================================

export USDT
export Network

export ETHEREUM
export TRON
export SOLANA
export TON
export AVALANCHE
export CELO
export APTOS
export NEAR

export Store
export App
export USDTGateway
export PaymentRequest
export VerifiedPayment

export add_product!
export products
export get_product

export Cart
export add_to_cart!
export remove_from_cart!
export cart_total

export create_customer!
export create_session!

export create_order!
export get_order

export create_payment_request
export verify_payment
export record_payment!

export storefront
export start!

export money
export network_name

export main


end # module


# ============================================================
# START APPLICATION
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .TetherShop

    TetherShop.main()

end
```

