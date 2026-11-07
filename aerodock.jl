#!/usr/bin/env julia

# ============================================================
# AERODOCK HOME
# Smart Drone Delivery & Secure Parcel Storage System
# Core Device Software — Julia
# ============================================================

using HTTP
using JSON3
using SQLite
using DBInterface
using Dates
using UUIDs
using SHA
using Random

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

const HOST = get(ENV, "AERODOCK_HOST", "127.0.0.1")
const PORT = parse(Int, get(ENV, "AERODOCK_PORT", "8080"))
const DB_PATH = get(ENV, "AERODOCK_DB", "./aerodock.sqlite")
const ADMIN_KEY = get(ENV, "AERODOCK_ADMIN_KEY", "")

const MAX_CODE_ATTEMPTS = 5
const CODE_LOCKOUT_SECONDS = 300
const MAX_DELIVERY_HOURS = 48

# ------------------------------------------------------------
# HARDWARE CONTROL
# ------------------------------------------------------------

abstract type HardwareAdapter end

mutable struct SimulatedHardware <: HardwareAdapter
    hatch_open::Bool
    parcel_present::Bool
    lift_at_top::Bool
    locked::Bool
    emergency_stop::Bool
end

const HARDWARE = SimulatedHardware(
    false,
    false,
    true,
    true,
    false
)

function hardware_status(hw::SimulatedHardware)

    return (
        hatch_open = hw.hatch_open,
        parcel_present = hw.parcel_present,
        lift_at_top = hw.lift_at_top,
        locked = hw.locked,
        emergency_stop = hw.emergency_stop,
        mode = "SIMULATED — NOT CONNECTED TO PHYSICAL HARDWARE"
    )

end

function safety_check(hw::SimulatedHardware)

    hw.emergency_stop &&
        error("Emergency stop is active")

    return true

end

function unlock_compartment!(hw::SimulatedHardware)

    safety_check(hw)

    hw.hatch_open = true
    hw.locked = false

    return true

end

function close_and_lock!(hw::SimulatedHardware)

    safety_check(hw)

    hw.hatch_open = false
    hw.locked = true

    return true

end

function lower_parcel_lift!(hw::SimulatedHardware)

    safety_check(hw)

    hw.parcel_present ||
        error("Parcel-presence sensor is not active")

    hw.lift_at_top = false

    return true

end

function raise_lift!(hw::SimulatedHardware)

    safety_check(hw)

    hw.lift_at_top = true

    return true

end

# ------------------------------------------------------------
# DATABASE
# ------------------------------------------------------------

const DB = SQLite.DB(DB_PATH)

function init_db!()

    DBInterface.execute(DB, """
        CREATE TABLE IF NOT EXISTS deliveries (

            id TEXT PRIMARY KEY,

            recipient TEXT NOT NULL,

            parcel_ref TEXT NOT NULL,

            status TEXT NOT NULL,

            collection_hash TEXT NOT NULL,

            drone_token_hash TEXT NOT NULL,

            created_at TEXT NOT NULL,

            expires_at TEXT NOT NULL,

            landed_at TEXT,

            secured_at TEXT,

            collection_started_at TEXT,

            collected_at TEXT,

            failed_attempts INTEGER NOT NULL DEFAULT 0,

            locked_until TEXT

        )
    """)

    DBInterface.execute(DB, """
        CREATE TABLE IF NOT EXISTS events (

            id INTEGER PRIMARY KEY AUTOINCREMENT,

            delivery_id TEXT,

            event_type TEXT NOT NULL,

            detail TEXT NOT NULL,

            created_at TEXT NOT NULL

        )
    """)

    DBInterface.execute(DB, """
        CREATE TABLE IF NOT EXISTS rate_limits (

            key TEXT PRIMARY KEY,

            attempts INTEGER NOT NULL,

            window_started_at TEXT NOT NULL,

            blocked_until TEXT

        )
    """)

end

# ------------------------------------------------------------
# SECURITY AND UTILITIES
# ------------------------------------------------------------

nowstamp() = Dates.format(
    now(UTC),
    dateformat"yyyy-mm-ddTHH:MM:SS.sssZ"
)

hashsecret(s::AbstractString) =
    bytes2hex(sha256(codeunits(s)))

random_secret(n::Int=32) =
    bytes2hex(rand(RandomDevice(), UInt8, n))

random_code() =
    lpad(
        string(rand(RandomDevice(), 0:999999)),
        6,
        '0'
    )

# ------------------------------------------------------------
# DELIVERY EVENT LOGGING
# ------------------------------------------------------------

function audit!(delivery_id, event_type, detail)

    DBInterface.execute(
        DB,
        """
        INSERT INTO events
        (delivery_id, event_type, detail, created_at)
        VALUES (?, ?, ?, ?)
        """,
        (
            delivery_id,
            event_type,
            detail,
            nowstamp()
        )
    )

end

function rowdict(row)

    return Dict(
        string(k) => getproperty(row, k)
        for k in propertynames(row)
    )

end

function get_delivery(id::String)

    rows = collect(
        DBInterface.execute(
            DB,
            "SELECT * FROM deliveries WHERE id = ?",
            (id,)
        )
    )

    isempty(rows) && return nothing

    return rowdict(rows[1])

end

# ------------------------------------------------------------
# HTTP RESPONSE UTILITIES
# ------------------------------------------------------------

function json_response(status::Int, payload)

    return HTTP.Response(
        status,
        [
            "Content-Type" => "application/json",
            "Cache-Control" => "no-store"
        ],
        JSON3.write(payload)
    )

end

function request_json(req)

    isempty(req.body) &&
        return Dict{String,Any}()

    try

        return JSON3.read(
            String(req.body),
            Dict{String,Any}
        )

    catch

        throw(
            ArgumentError(
                "Request body must be valid JSON"
            )
        )

    end

end

function header(req, name::String)

    for (k, v) in req.headers

        lowercase(k) == lowercase(name) &&
            return String(v)

    end

    return ""

end

function require_admin(req)

    isempty(ADMIN_KEY) &&
        error(
            "Server is not configured: AERODOCK_ADMIN_KEY is missing"
        )

    supplied = header(req, "X-Admin-Key")

    return !isempty(supplied) &&
        hashsecret(supplied) == hashsecret(ADMIN_KEY)

end

function bearer(req)

    value = header(req, "Authorization")

    startswith(value, "Bearer ") ?
        value[8:end] : ""

end

function parse_path(path::String)

    return split(
        first(split(path, '?')),
        '/';
        keepempty=false
    )

end

function safe_error(f)

    try

        return f()

    catch e

        if e isa ArgumentError

            return json_response(
                400,
                (error=string(e),)
            )

        elseif e isa ErrorException

            return json_response(
                409,
                (error=e.msg,)
            )

        else

            @error "AeroDock request failed" exception=(
                e,
                catch_backtrace()
            )

            return json_response(
                500,
                (error="Internal device-service error",)
            )

        end

    end

end

# ------------------------------------------------------------
# DELIVERY AUTHORISATION
# ------------------------------------------------------------

function create_delivery(body)

    recipient = strip(
        string(get(body, "recipient", ""))
    )

    parcel_ref = strip(
        string(get(body, "parcel_ref", ""))
    )

    isempty(recipient) &&
        throw(ArgumentError("recipient is required"))

    isempty(parcel_ref) &&
        throw(ArgumentError("parcel_ref is required"))

    hours = Int(
        get(body, "valid_for_hours", 24)
    )

    1 <= hours <= MAX_DELIVERY_HOURS ||
        throw(
            ArgumentError(
                "valid_for_hours must be between 1 and $MAX_DELIVERY_HOURS"
            )
        )

    id = string(uuid4())

    collection_code = random_code()

    drone_token = random_secret(32)

    created = now(UTC)

    expires = created + Hour(hours)

    DBInterface.execute(
        DB,
        """
        INSERT INTO deliveries
        (
            id,
            recipient,
            parcel_ref,
            status,
            collection_hash,
            drone_token_hash,
            created_at,
            expires_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            id,
            recipient,
            parcel_ref,
            "authorised",
            hashsecret(collection_code),
            hashsecret(drone_token),
            nowstamp(),
            Dates.format(
                expires,
                dateformat"yyyy-mm-ddTHH:MM:SS.sssZ"
            )
        )
    )

    audit!(
        id,
        "delivery_authorised",
        "Delivery authorised for recipient"
    )

    return (
        delivery_id=id,
        status="authorised",
        collection_code=collection_code,
        drone_token=drone_token,
        expires_at=Dates.format(
            expires,
            dateformat"yyyy-mm-ddTHH:MM:SS.sssZ"
        )
    )

end

# ------------------------------------------------------------
# DRONE AUTHENTICATION
# ------------------------------------------------------------

function verify_drone_token(req, delivery)

    token = bearer(req)

    isempty(token) && return false

    return hashsecret(token) ==
        delivery["drone_token_hash"]

end

function check_not_expired(delivery)

    expires = DateTime(
        replace(
            delivery["expires_at"],
            "Z" => ""
        )
    )

    now(UTC) > expires &&
        error("Delivery authorisation has expired")

end

# ------------------------------------------------------------
# DRONE ARRIVAL
# ------------------------------------------------------------

function drone_arrival(req, id)

    delivery = get_delivery(id)

    delivery === nothing &&
        return json_response(
            404,
            (error="Delivery not found",)
        )

    verify_drone_token(req, delivery) ||
        return json_response(
            401,
            (error="Invalid drone credential",)
        )

    check_not_expired(delivery)

    delivery["status"] == "authorised" ||
        error(
            "Delivery is not awaiting drone arrival"
        )

    HARDWARE.emergency_stop &&
        error("Emergency stop is active")

    HARDWARE.hatch_open &&
        error("Dock hatch is already open")

    DBInterface.execute(
        DB,
        """
        UPDATE deliveries
        SET status='landed', landed_at=?
        WHERE id=?
        """,
        (
            nowstamp(),
            id
        )
    )

    audit!(
        id,
        "drone_arrival_reported",
        "Authenticated drone arrival reported"
    )

    return json_response(
        200,
        (
            delivery_id=id,
            status="landed",
            message="Awaiting verified parcel-transfer confirmation"
        )
    )

end

# ------------------------------------------------------------
# PARCEL TRANSFER AND SECURE STORAGE
# ------------------------------------------------------------

function transfer_complete(req, id)

    delivery = get_delivery(id)

    delivery === nothing &&
        return json_response(
            404,
            (error="Delivery not found",)
        )

    verify_drone_token(req, delivery) ||
        return json_response(
            401,
            (error="Invalid drone credential",)
        )

    delivery["status"] == "landed" ||
        error("Delivery has not been marked as landed")

    check_not_expired(delivery)

    # SIMULATED HARDWARE OPERATION
    #
    # A production adapter must independently verify:
    # - Drone has cleared the transfer zone.
    # - Parcel is correctly positioned.
    # - Hatch and lift interlocks are satisfied.
    # - No obstruction is detected.

    HARDWARE.parcel_present = true

    unlock_compartment!(HARDWARE)

    close_and_lock!(HARDWARE)

    lower_parcel_lift!(HARDWARE)

    DBInterface.execute(
        DB,
        """
        UPDATE deliveries
        SET status='secured', secured_at=?
        WHERE id=?
        """,
        (
            nowstamp(),
            id
        )
    )

    audit!(
        id,
        "parcel_secured",
        "Parcel transfer completed; compartment locked"
    )

    return json_response(
        200,
        (
            delivery_id=id,
            status="secured",
            message="Parcel stored. Recipient can collect it."
        )
    )

end

# ------------------------------------------------------------
# CUSTOMER COLLECTION
# ------------------------------------------------------------

function start_collection(body)

    code = strip(
        string(get(body, "collection_code", ""))
    )

    isempty(code) &&
        throw(
            ArgumentError(
                "collection_code is required"
            )
        )

    rows = collect(
        DBInterface.execute(
            DB,
            """
            SELECT *
            FROM deliveries
            WHERE collection_hash=?
            AND status='secured'
            """,
            (hashsecret(code),)
        )
    )

    isempty(rows) &&
        return json_response(
            401,
            (error="Invalid or unavailable collection code",)
        )

    delivery = rowdict(rows[1])

    check_not_expired(delivery)

    if !isnothing(delivery["locked_until"]) &&
       !isempty(string(delivery["locked_until"]))

        locked_until = DateTime(
            replace(
                string(delivery["locked_until"]),
                "Z" => ""
            )
        )

        now(UTC) < locked_until &&
            return json_response(
                429,
                (error="Collection temporarily locked",)
            )

    end

    # Production authentication should also integrate
    # the mobile application, NFC and verified identity.

    unlock_compartment!(HARDWARE)

    DBInterface.execute(
        DB,
        """
        UPDATE deliveries
        SET status='collection_open',
            collection_started_at=?
        WHERE id=?
        """,
        (
            nowstamp(),
            delivery["id"]
        )
    )

    audit!(
        delivery["id"],
        "collection_started",
        "Recipient collection session opened"
    )

    return json_response(
        200,
        (
            delivery_id=delivery["id"],
            status="collection_open",
            message="Compartment unlocked. Remove parcel and close the door."
        )
    )

end

# ------------------------------------------------------------
# COLLECTION COMPLETION
# ------------------------------------------------------------

function complete_collection(body)

    id = string(
        get(body, "delivery_id", "")
    )

    isempty(id) &&
        throw(
            ArgumentError(
                "delivery_id is required"
            )
        )

    delivery = get_delivery(id)

    delivery === nothing &&
        return json_response(
            404,
            (error="Delivery not found",)
        )

    delivery["status"] == "collection_open" ||
        error("No collection session is open")

    # SIMULATED SENSOR STATE
    #
    # Real hardware must verify parcel removal,
    # door closure and safe lift position.

    HARDWARE.parcel_present = false

    close_and_lock!(HARDWARE)

    raise_lift!(HARDWARE)

    DBInterface.execute(
        DB,
        """
        UPDATE deliveries
        SET status='collected', collected_at=?
        WHERE id=?
        """,
        (
            nowstamp(),
            id
        )
    )

    audit!(
        id,
        "parcel_collected",
        "Parcel collected; compartment re-secured"
    )

    return json_response(
        200,
        (
            delivery_id=id,
            status="collected",
            message="Collection complete. Dock secured."
        )
    )

end

# ------------------------------------------------------------
# API ROUTER
# ------------------------------------------------------------

function router(req)

    safe_error() do

        method = String(req.method)

        parts = parse_path(
            String(req.target)
        )

        # DEVICE HEALTH

        if method == "GET" &&
           parts == ["health"]

            return json_response(
                200,
                (
                    service="AeroDock Home",
                    status="online",
                    timestamp=nowstamp()
                )
            )

        end

        # DEVICE STATUS

        if method == "GET" &&
           parts == ["api", "v1", "status"]

            require_admin(req) ||
                return json_response(
                    401,
                    (error="Admin authentication required",)
                )

            return json_response(
                200,
                (
                    device="AeroDock Home",
                    hardware=hardware_status(HARDWARE),
                    timestamp=nowstamp()
                )
            )

        end

        # AUTHORISE DELIVERY

        if method == "POST" &&
           parts == ["api", "v1", "deliveries"]

            require_admin(req) ||
                return json_response(
                    401,
                    (error="Admin authentication required",)
                )

            return json_response(
                201,
                create_delivery(
                    request_json(req)
                )
            )

        end

        # DRONE ARRIVAL

        if method == "POST" &&
           length(parts) == 5 &&
           parts[1:3] == [
               "api",
               "v1",
               "deliveries"
           ] &&
           parts[5] == "arrive"

            return drone_arrival(
                req,
                parts[4]
            )

        end

        # PARCEL TRANSFER

        if method == "POST" &&
           length(parts) == 5 &&
           parts[1:3] == [
               "api",
               "v1",
               "deliveries"
           ] &&
           parts[5] == "transfer-complete"

            return transfer_complete(
                req,
                parts[4]
            )

        end

        # CUSTOMER COLLECTION

        if method == "POST" &&
           parts == [
               "api",
               "v1",
               "collect",
               "start"
           ]

            return start_collection(
                request_json(req)
            )

        end

        # COLLECTION COMPLETION

        if method == "POST" &&
           parts == [
               "api",
               "v1",
               "collect",
               "complete"
           ]

            return complete_collection(
                request_json(req)
            )

        end

        return json_response(
            404,
            (error="Route not found",)
        )

    end

end

# ------------------------------------------------------------
# APPLICATION STARTUP
# ------------------------------------------------------------

function main()

    init_db!()

    if isempty(ADMIN_KEY)

        @warn """
        AERODOCK_ADMIN_KEY is unset.
        Admin routes will reject requests.
        """

    end

    @info "Starting AeroDock Home device service"

    @info "Host: $HOST"

    @info "Port: $PORT"

    @info "Database: $DB_PATH"

    @info """
    Hardware mode: SIMULATED.
    Not connected to physical hardware.
    """

    HTTP.serve(
        router,
        HOST,
        PORT;
        verbose=false
    )

end

main()
