module NewspaperLightning

using HTTP
using JSON3
using UUIDs
using SQLite
using Dates
using SHA

# ============================================================
# CONFIGURATION
# ============================================================

const CONFIG = Dict(
    "host" => get(ENV, "PAYWALL_HOST", "127.0.0.1"),
    "port" => parse(Int, get(ENV, "PAYWALL_PORT", "8080")),

    # Price of a single article.
    # Lightning amounts are stored in millisatoshis.
    "article_price_msat" =>
        parse(Int64, get(ENV, "ARTICLE_PRICE_MSAT", "10000")),

    # LND endpoint.
    "lnd_url" =>
        get(ENV, "LND_URL", "https://127.0.0.1:8080"),

    # In production this should come from a secrets manager.
    "lnd_macaroon" =>
        get(ENV, "LND_MACAROON", "")
)

# ============================================================
# DATABASE
# ============================================================

const DB = SQLite.DB(
    get(ENV, "PAYWALL_DB", "newspaper_paywall.db")
)

function initialise_database()

    SQLite.execute(DB, """
        CREATE TABLE IF NOT EXISTS payments (
            payment_id TEXT PRIMARY KEY,
            article_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            invoice TEXT NOT NULL,
            payment_hash TEXT,
            amount_msat INTEGER NOT NULL,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            paid_at TEXT
        )
    """)

    SQLite.execute(DB, """
        CREATE INDEX IF NOT EXISTS idx_payment_hash
        ON payments(payment_hash)
    """)

    SQLite.execute(DB, """
        CREATE INDEX IF NOT EXISTS idx_session
        ON payments(session_id)
    """)

end

# ============================================================
# UTILITIES
# ============================================================

function json_response(data; status=200)

    return HTTP.Response(
        status,
        ["Content-Type" => "application/json"],
        JSON3.write(data)
    )

end


function generate_id()

    return string(uuid4())

end


function now_iso()

    return string(now(UTC))

end

# ============================================================
# LND API
# ============================================================

function lnd_headers()

    return [
        "Content-Type" => "application/json",
        "Grpc-Metadata-macaroon" => CONFIG["lnd_macaroon"]
    ]

end


"""
Create a Lightning invoice.

LND's /v1/invoices endpoint accepts an amount in satoshis.
"""

function create_invoice(
    amount_sat::Int,
    memo::String
)

    payload = JSON3.write(Dict(
        "value" => amount_sat,
        "memo" => memo
    ))

    response = HTTP.post(
        CONFIG["lnd_url"] * "/v1/invoices",
        lnd_headers(),
        payload;
        status_exception=false
    )

    if response.status != 200
        error(
            "Lightning invoice creation failed: " *
            String(response.body)
        )
    end

    return JSON3.read(response.body)

end

# ============================================================
# PAYMENT LOOKUP
# ============================================================

function lookup_payment(payment_hash::String)

    endpoint =
        CONFIG["lnd_url"] *
        "/v1/payments/" *
        payment_hash

    response = HTTP.get(
        endpoint,
        lnd_headers();
        status_exception=false
    )

    if response.status != 200
        return nothing
    end

    return JSON3.read(response.body)

end

# ============================================================
# DATABASE OPERATIONS
# ============================================================

function create_payment_record(
    payment_id,
    article_id,
    session_id,
    invoice,
    payment_hash,
    amount_msat
)

    SQLite.execute(
        DB,
        """
        INSERT INTO payments
        (
            payment_id,
            article_id,
            session_id,
            invoice,
            payment_hash,
            amount_msat,
            status,
            created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            payment_id,
            article_id,
            session_id,
            invoice,
            payment_hash,
            amount_msat,
            "PENDING",
            now_iso()
        )
    )

end


function mark_paid(payment_hash)

    SQLite.execute(
        DB,
        """
        UPDATE payments
        SET status = 'PAID',
            paid_at = ?
        WHERE payment_hash = ?
        """,
        (
            now_iso(),
            payment_hash
        )
    )

end


function get_payment(payment_id)

    result = SQLite.Query(
        DB,
        """
        SELECT
            payment_id,
            article_id,
            session_id,
            invoice,
            payment_hash,
            amount_msat,
            status,
            created_at,
            paid_at
        FROM payments
        WHERE payment_id = ?
        """,
        (payment_id,)
    )

    rows = collect(result)

    isempty(rows) && return nothing

    return rows[1]

end

# ============================================================
# CREATE ARTICLE PAYMENT
# ============================================================

function create_article_payment(
    article_id::String,
    session_id::String
)

    amount_msat =
        CONFIG["article_price_msat"]

    # Convert millisatoshis to satoshis.
    amount_sat =
        Int(ceil(amount_msat / 1000))

    payment_id =
        generate_id()

    memo =
        "Newspaper article: " *
        article_id

    invoice =
        create_invoice(
            amount_sat,
            memo
        )

    payment_hash =
        String(invoice["r_hash"])

    payment_request =
        String(invoice["payment_request"])

    create_payment_record(
        payment_id,
        article_id,
        session_id,
        payment_request,
        payment_hash,
        amount_msat
    )

    return Dict(
        "payment_id" => payment_id,
        "article_id" => article_id,
        "amount_msat" => amount_msat,
        "amount_sat" => amount_sat,
        "invoice" => payment_request,
        "payment_hash" => payment_hash,
        "status" => "PENDING"
    )

end

# ============================================================
# VERIFY PAYMENT
# ============================================================

function verify_payment(payment_id::String)

    payment =
        get_payment(payment_id)

    payment === nothing &&
        return Dict(
            "paid" => false,
            "error" => "Payment not found"
        )

    payment.status == "PAID" &&
        return Dict(
            "paid" => true,
            "payment_id" => payment.payment_id,
            "article_id" => payment.article_id
        )

    hash =
        String(payment.payment_hash)

    lnd_payment =
        lookup_payment(hash)

    lnd_payment === nothing &&
        return Dict(
            "paid" => false,
            "status" => "PENDING"
        )

    # LND uses SETTLED / SUCCEEDED depending on
    # endpoint/version.
    settled = false

    if haskey(lnd_payment, "status")

        status =
            String(lnd_payment["status"])

        settled =
            status == "SUCCEEDED" ||
            status == "SETTLED"

    end

    if settled

        mark_paid(hash)

        return Dict(
            "paid" => true,
            "payment_id" => payment.payment_id,
            "article_id" => payment.article_id,
            "status" => "PAID"
        )

    end

    return Dict(
        "paid" => false,
        "status" => "PENDING"
    )

end

# ============================================================
# ACCESS CONTROL
# ============================================================

function article_access(
    article_id::String,
    session_id::String
)

    query = SQLite.Query(
        DB,
        """
        SELECT payment_id
        FROM payments
        WHERE article_id = ?
          AND session_id = ?
          AND status = 'PAID'
        LIMIT 1
        """,
        (
            article_id,
            session_id
        )
    )

    rows =
        collect(query)

    return !isempty(rows)

end

# ============================================================
# ROUTER
# ============================================================

function route_request(req)

    method =
        String(req.method)

    target =
        String(req.target)

    # --------------------------------------------------------
    # Health check
    # --------------------------------------------------------

    if method == "GET" &&
       target == "/health"

        return json_response(
            Dict(
                "status" => "ok",
                "service" => "newspaper-lightning-paywall"
            )
        )

    end

    # --------------------------------------------------------
    # Create invoice
    # --------------------------------------------------------

    if method == "POST" &&
       target == "/api/paywall/create"

        body =
            JSON3.read(
                String(req.body)
            )

        article_id =
            String(body["article_id"])

        session_id =
            String(body["session_id"])

        result =
            create_article_payment(
                article_id,
                session_id
            )

        return json_response(result)

    end

    # --------------------------------------------------------
    # Check payment
    # --------------------------------------------------------

    if method == "GET" &&
       startswith(target, "/api/paywall/status/")

        payment_id =
            split(target, "/")[end]

        result =
            verify_payment(payment_id)

        return json_response(result)

    end

    # --------------------------------------------------------
    # Check article access
    # --------------------------------------------------------

    if method == "GET" &&
       startswith(target, "/api/paywall/access/")

        parts =
            split(target, "/")

        article_id =
            parts[end]

        # Demo session extraction.
        # In production use a signed session cookie/token.
        session_id =
            get(ENV, "DEMO_SESSION", "demo")

        access =
            article_access(
                article_id,
                session_id
            )

        return json_response(
            Dict(
                "article_id" => article_id,
                "access" => access
            )
        )

    end

    return json_response(
        Dict(
            "error" => "Not found"
        );
        status=404
    )

end

# ============================================================
# HTTP SERVER
# ============================================================

function start_server()

    initialise_database()

    println(
        "Newspaper Lightning Paywall"
    )

    println(
        "Listening on " *
        CONFIG["host"] *
        ":" *
        string(CONFIG["port"])
    )

    HTTP.serve(
        route_request,
        CONFIG["host"],
        CONFIG["port"]
    )

end

end # module


if abspath(PROGRAM_FILE) == @__FILE__

    NewspaperLightning.start_server()

end
