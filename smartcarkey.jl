using Dates
using UUIDs

# ============================================================
# SMART CAR KEY / PROXIMITY ENGINE
# Julia prototype
#
# NFC       = cryptographic close-range confirmation
# BLE/UWB   = proximity / distance estimation
# IMU       = movement / approach detection
# Vehicle   = authoritative lock controller
# ============================================================

@enum LockState LOCKED UNLOCK_PENDING UNLOCKED LOCK_PENDING

struct KeyCredential
    key_id::UUID
    vehicle_id::UUID
    public_key::Vector{UInt8}
    enabled::Bool
end

struct ProximitySample
    distance_m::Float64
    signal_strength::Float64
    velocity_mps::Float64
    timestamp::DateTime
end

struct NFCEvent
    key_id::UUID
    vehicle_id::UUID
    challenge_response::Vector{UInt8}
    timestamp::DateTime
end

mutable struct VehicleState
    vehicle_id::UUID
    lock_state::LockState

    last_proximity::Union{Nothing,ProximitySample}
    last_nfc::Union{Nothing,NFCEvent}

    unlock_radius_m::Float64
    lock_radius_m::Float64

    unlock_hold_seconds::Float64
    lock_hold_seconds::Float64

    unlock_started::Union{Nothing,DateTime}
    lock_started::Union{Nothing,DateTime}

    last_action::Union{Nothing,DateTime}
end


# ============================================================
# CONFIGURATION
# ============================================================

const DEFAULT_UNLOCK_RADIUS = 2.5
const DEFAULT_LOCK_RADIUS   = 6.0

const UNLOCK_HOLD = 0.75
const LOCK_HOLD   = 3.0

const NFC_VALIDITY_SECONDS = 10.0


# ============================================================
# CRYPTOGRAPHIC AUTHENTICATION
# ============================================================

"""
Verify that an NFC credential belongs to this vehicle.

In a production implementation this should perform a real
challenge/response signature verification using a hardware-
backed key / secure element.
"""
function authenticate_nfc(
    event::NFCEvent,
    credential::KeyCredential,
    vehicle_id::UUID
)::Bool

    if !credential.enabled
        return false
    end

    if event.vehicle_id != vehicle_id
        return false
    end

    if event.key_id != credential.key_id
        return false
    end

    age = Dates.value(now(UTC) - event.timestamp) / 1000

    if age < 0 || age > NFC_VALIDITY_SECONDS
        return false
    end

    # --------------------------------------------------------
    # PLACEHOLDER
    #
    # Production:
    #
    # verify_signature(
    #     credential.public_key,
    #     event.challenge_response,
    #     vehicle_challenge
    # )
    # --------------------------------------------------------

    return true
end


# ============================================================
# PROXIMITY ANALYSIS
# ============================================================

"""
Determine whether the user is approaching the vehicle.

Negative velocity = getting closer.
Positive velocity = moving away.
"""
function approaching_vehicle(
    proximity::ProximitySample
)::Bool

    return proximity.velocity_mps < -0.15
end


function inside_unlock_radius(
    proximity::ProximitySample,
    radius::Float64
)::Bool

    return proximity.distance_m <= radius
end


function outside_lock_radius(
    proximity::ProximitySample,
    radius::Float64
)::Bool

    return proximity.distance_m >= radius
end


# ============================================================
# SMART UNLOCK DECISION
# ============================================================

function unlock_conditions_met(
    vehicle::VehicleState,
    proximity::ProximitySample,
    nfc_authenticated::Bool
)::Bool

    # Must have authenticated key
    if !nfc_authenticated
        return false
    end

    # Must actually be close
    if !inside_unlock_radius(
        proximity,
        vehicle.unlock_radius_m
    )
        return false
    end

    # Ideally the user is approaching rather than walking away
    if !approaching_vehicle(proximity)
        return false
    end

    return true
end


# ============================================================
# SMART LOCK DECISION
# ============================================================

function lock_conditions_met(
    vehicle::VehicleState,
    proximity::ProximitySample
)::Bool

    return outside_lock_radius(
        proximity,
        vehicle.lock_radius_m
    )
end


# ============================================================
# VEHICLE COMMANDS
# ============================================================

function send_unlock_command(vehicle::VehicleState)

    println("🔓 VEHICLE COMMAND: UNLOCK")

    vehicle.lock_state = UNLOCKED
    vehicle.unlock_started = nothing
    vehicle.last_action = now(UTC)
end


function send_lock_command(vehicle::VehicleState)

    println("🔒 VEHICLE COMMAND: LOCK")

    vehicle.lock_state = LOCKED
    vehicle.lock_started = nothing
    vehicle.last_action = now(UTC)
end


# ============================================================
# SMART STATE MACHINE
# ============================================================

function process_proximity!(
    vehicle::VehicleState,
    proximity::ProximitySample,
    nfc_authenticated::Bool
)

    vehicle.last_proximity = proximity

    # --------------------------------------------------------
    # LOCKED → UNLOCK_PENDING
    # --------------------------------------------------------

    if vehicle.lock_state == LOCKED

        if unlock_conditions_met(
            vehicle,
            proximity,
            nfc_authenticated
        )

            if vehicle.unlock_started === nothing

                vehicle.unlock_started =
                    proximity.timestamp

                println(
                    "→ Unlock conditions detected"
                )

            else

                elapsed =
                    Dates.value(
                        proximity.timestamp -
                        vehicle.unlock_started
                    ) / 1000

                if elapsed >= vehicle.unlock_hold_seconds

                    send_unlock_command(vehicle)

                end
            end

        else

            vehicle.unlock_started = nothing

        end

    # --------------------------------------------------------
    # UNLOCKED → LOCK_PENDING
    # --------------------------------------------------------

    elseif vehicle.lock_state == UNLOCKED

        if lock_conditions_met(
            vehicle,
            proximity
        )

            if vehicle.lock_started === nothing

                vehicle.lock_started =
                    proximity.timestamp

                println(
                    "→ Vehicle left proximity zone"
                )

            else

                elapsed =
                    Dates.value(
                        proximity.timestamp -
                        vehicle.lock_started
                    ) / 1000

                if elapsed >= vehicle.lock_hold_seconds

                    send_lock_command(vehicle)

                end
            end

        else

            vehicle.lock_started = nothing

        end
    end
end


# ============================================================
# NFC EVENT PROCESSING
# ============================================================

function process_nfc!(
    vehicle::VehicleState,
    event::NFCEvent,
    credential::KeyCredential
)

    authenticated = authenticate_nfc(
        event,
        credential,
        vehicle.vehicle_id
    )

    if authenticated

        vehicle.last_nfc = event

        println(
            "✓ NFC credential authenticated"
        )

        return true
    end

    println(
        "✗ NFC authentication failed"
    )

    return false
end


# ============================================================
# COMPLETE SMART KEY LOOP
# ============================================================

function smart_key_tick!(
    vehicle::VehicleState,
    proximity::ProximitySample,
    nfc_authenticated::Bool
)

    process_proximity!(
        vehicle,
        proximity,
        nfc_authenticated
    )

end


# ============================================================
# EXAMPLE VEHICLE
# ============================================================

vehicle = VehicleState(
    uuid4(),
    LOCKED,

    nothing,
    nothing,

    DEFAULT_UNLOCK_RADIUS,
    DEFAULT_LOCK_RADIUS,

    UNLOCK_HOLD,
    LOCK_HOLD,

    nothing,
    nothing,

    nothing
)


# ============================================================
# EXAMPLE KEY
# ============================================================

key = KeyCredential(
    uuid4(),
    vehicle.vehicle_id,
    rand(UInt8, 32),
    true
)


# ============================================================
# SIMULATED NFC AUTHENTICATION
# ============================================================

nfc = NFCEvent(
    key.key_id,
    vehicle.vehicle_id,
    rand(UInt8, 64),
    now(UTC)
)

authenticated = process_nfc!(
    vehicle,
    nfc,
    key
)


# ============================================================
# SIMULATE PERSON WALKING TOWARD CAR
# ============================================================

for distance in 5.0:-0.25:1.0

    proximity = ProximitySample(
        distance,
        -50.0,
        -1.0,
        now(UTC)
    )

    smart_key_tick!(
        vehicle,
        proximity,
        authenticated
    )

    sleep(0.1)
end
