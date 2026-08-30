module DigitalPadlock

using SHA
using Dates
using Printf

# ============================================================
# DIGITAL PADLOCK
# Pure Julia
#
# Simulated electronic padlock controller.
#
# Features:
#   - PIN credentials
#   - Lock / unlock state machine
#   - Failed-attempt protection
#   - Temporary lockout
#   - Battery monitoring
#   - Tamper detection
#   - Audit log
#   - Auto-lock
#   - Mechanical override simulation
#   - Credential management
#   - Event logging
#
# Security note:
#   This is a software simulation/reference architecture.
#   A production lock needs a security-reviewed embedded
#   implementation, secure hardware, protected key storage,
#   authenticated firmware and a formally specified threat model.
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

struct LockConfig

    max_attempts::Int

    lockout_seconds::Float64

    auto_lock_seconds::Float64

    low_battery_percent::Float64

    critical_battery_percent::Float64

    tamper_lockout_seconds::Float64
end


# ============================================================
# CREDENTIAL
# ============================================================

struct Credential

    id::Int

    label::String

    secret_hash::Vector{UInt8}

    enabled::Bool
end


function credential(
    id::Int,
    label::String,
    secret::String
)

    digest =
        sha256(
            secret
        )

    Credential(
        id,
        label,
        digest,
        true
    )
end


# ============================================================
# LOCK STATE
# ============================================================

@enum LockState begin
    LOCKED
    UNLOCKED
    LOCKOUT
    TAMPER
    DISABLED
end


# ============================================================
# EVENTS
# ============================================================

struct LockEvent

    timestamp::DateTime

    event::Symbol

    credential_id::Int

    message::String
end


# ============================================================
# AUDIT LOG
# ============================================================

mutable struct AuditLog

    events::Vector{LockEvent}
end


AuditLog() =
    AuditLog(LockEvent[])


function log_event!(
    log::AuditLog,
    event::Symbol,
    credential_id::Int,
    message::String
)

    push!(
        log.events,
        LockEvent(
            now(),
            event,
            credential_id,
            message
        )
    )

    return nothing
end


# ============================================================
# PADLOCK
# ============================================================

mutable struct DigitalPadlock

    config::LockConfig

    state::LockState

    credentials::Dict{Int,Credential}

    next_credential_id::Int

    failed_attempts::Int

    lockout_until::Union{DateTime,Nothing}

    tamper_until::Union{DateTime,Nothing}

    battery_percent::Float64

    battery_voltage_V::Float64

    last_activity::DateTime

    unlocked_since::Union{DateTime,Nothing}

    audit::AuditLog

    physical_override::Bool
end


function DigitalPadlock(;
    battery_percent=100.0,
    battery_voltage_V=3.7
)

    config =
        LockConfig(
            5,
            30.0,
            20.0,
            20.0,
            5.0,
            60.0
        )

    DigitalPadlock(
        config,
        LOCKED,
        Dict{Int,Credential}(),
        1,
        0,
        nothing,
        nothing,
        battery_percent,
        battery_voltage_V,
        now(),
        nothing,
        AuditLog(),
        false
    )
end


# ============================================================
# TIME HELPERS
# ============================================================

function seconds_since(
    timestamp::DateTime
)

    Dates.value(
        now() - timestamp
    ) / 1000.0
end


# ============================================================
# CREDENTIAL MANAGEMENT
# ============================================================

function add_credential!(
    lock::DigitalPadlock,
    label::String,
    secret::String
)

    id =
        lock.next_credential_id

    lock.next_credential_id += 1

    lock.credentials[id] =
        credential(
            id,
            label,
            secret
        )

    log_event!(
        lock.audit,
        :CREDENTIAL_ADDED,
        id,
        "Credential added"
    )

    return id
end


function disable_credential!(
    lock::DigitalPadlock,
    id::Int
)

    haskey(
        lock.credentials,
        id
    ) || error(
        "Credential does not exist."
    )

    old =
        lock.credentials[id]

    lock.credentials[id] =
        Credential(
            old.id,
            old.label,
            old.secret_hash,
            false
        )

    log_event!(
        lock.audit,
        :CREDENTIAL_DISABLED,
        id,
        "Credential disabled"
    )
end


# ============================================================
# SECRET VERIFICATION
# ============================================================

function verify_secret(
    stored::Vector{UInt8},
    supplied::String
)

    supplied_hash =
        sha256(
            supplied
        )

    length(stored) ==
        length(supplied_hash) ||
        return false

    result =
        UInt8(0)

    for i in eachindex(stored)

        result |=
            stored[i] ⊻
            supplied_hash[i]
    end

    return result == 0x00
end


function valid_credential(
    lock::DigitalPadlock,
    supplied::String
)

    for (
        id,
        cred
    ) in lock.credentials

        if cred.enabled &&
           verify_secret(
               cred.secret_hash,
               supplied
           )

            return id
        end
    end

    return nothing
end


# ============================================================
# BATTERY
# ============================================================

function battery_status(
    lock::DigitalPadlock
)

    if lock.battery_percent <=
       lock.config.critical_battery_percent

        return :CRITICAL

    elseif lock.battery_percent <=
           lock.config.low_battery_percent

        return :LOW

    else

        return :NORMAL
    end
end


function consume_battery!(
    lock::DigitalPadlock,
    amount::Float64
)

    lock.battery_percent =
        clamp(
            lock.battery_percent -
            amount,
            0.0,
            100.0
        )

    # Approximate Li-ion voltage model.

    lock.battery_voltage_V =
        3.0 +
        0.007 *
        lock.battery_percent

    if lock.battery_percent <= 0

        lock.state =
            DISABLED

        log_event!(
            lock.audit,
            :BATTERY_EMPTY,
            0,
            "Battery exhausted"
        )
    end
end


# ============================================================
# LOCK
# ============================================================

function lock!(
    lock::DigitalPadlock;
    reason=:MANUAL
)

    if lock.state ==
       DISABLED

        return false
    end

    lock.state =
        LOCKED

    lock.unlocked_since =
        nothing

    lock.last_activity =
        now()

    consume_battery!(
        lock,
        0.05
    )

    log_event!(
        lock.audit,
        :LOCKED,
        0,
        string(
            "Lock engaged: ",
            reason
        )
    )

    return true
end


# ============================================================
# UNLOCK
# ============================================================

function unlock!(
    lock::DigitalPadlock,
    secret::String
)

    # ----------------------------------------
    # Disabled
    # ----------------------------------------

    if lock.state ==
       DISABLED

        return false
    end

    # ----------------------------------------
    # Existing tamper state
    # ----------------------------------------

    if lock.state ==
       TAMPER

        if lock.tamper_until !== nothing &&
           now() >= lock.tamper_until

            lock.state =
                LOCKED

            lock.tamper_until =
                nothing

        else

            log_event!(
                lock.audit,
                :UNLOCK_BLOCKED,
                0,
                "Unlock blocked by tamper state"
            )

            return false
        end
    end

    # ----------------------------------------
    # Lockout
    # ----------------------------------------

    if lock.state ==
       LOCKOUT

        if lock.lockout_until !== nothing &&
           now() >= lock.lockout_until

            lock.state =
                LOCKED

            lock.lockout_until =
                nothing

            lock.failed_attempts =
                0

        else

            log_event!(
                lock.audit,
                :UNLOCK_BLOCKED,
                0,
                "Unlock blocked by lockout"
            )

            return false
        end
    end

    # ----------------------------------------
    # Verify
    # ----------------------------------------

    id =
        valid_credential(
            lock,
            secret
        )

    if id === nothing

        lock.failed_attempts += 1

        consume_battery!(
            lock,
            0.02
        )

        log_event!(
            lock.audit,
            :FAILED_UNLOCK,
            0,
            "Invalid credential"
        )

        if lock.failed_attempts >=
           lock.config.max_attempts

            lock.state =
                LOCKOUT

            lock.lockout_until =
                now() +
                Millisecond(
                    round(
                        lock.config.lockout_seconds *
                        1000
                    )
                )

            log_event!(
                lock.audit,
                :LOCKOUT,
                0,
                "Maximum failed attempts exceeded"
            )
        end

        return false
    end

    # ----------------------------------------
    # Successful unlock
    # ----------------------------------------

    lock.state =
        UNLOCKED

    lock.failed_attempts =
        0

    lock.lockout_until =
        nothing

    lock.unlocked_since =
        now()

    lock.last_activity =
        now()

    consume_battery!(
        lock,
        0.10
    )

    log_event!(
        lock.audit,
        :UNLOCKED,
        id,
        "Credential accepted"
    )

    return true
end


# ============================================================
# ACTIVITY
# ============================================================

function activity!(
    lock::DigitalPadlock
)

    lock.last_activity =
        now()

    if lock.state ==
       UNLOCKED

        lock.unlocked_since =
            now()
    end
end


# ============================================================
# AUTO LOCK
# ============================================================

function update!(
    lock::DigitalPadlock
)

    if lock.state ==
       DISABLED

        return
    end

    # ----------------------------------------
    # Lockout expiration
    # ----------------------------------------

    if lock.state ==
       LOCKOUT &&
       lock.lockout_until !== nothing

        if now() >=
           lock.lockout_until

            lock.state =
                LOCKED

            lock.lockout_until =
                nothing

            lock.failed_attempts =
                0

            log_event!(
                lock.audit,
                :LOCKOUT_CLEARED,
                0,
                "Lockout expired"
            )
        end
    end

    # ----------------------------------------
    # Tamper expiration
    # ----------------------------------------

    if lock.state ==
       TAMPER &&
       lock.tamper_until !== nothing

        if now() >=
           lock.tamper_until

            lock.state =
                LOCKED

            lock.tamper_until =
                nothing

            log_event!(
                lock.audit,
                :TAMPER_CLEARED,
                0,
                "Tamper state cleared"
            )
        end
    end

    # ----------------------------------------
    # Auto lock
    # ----------------------------------------

    if lock.state ==
       UNLOCKED &&
       lock.unlocked_since !== nothing

        elapsed =
            seconds_since(
                lock.unlocked_since
            )

        if elapsed >=
           lock.config.auto_lock_seconds

            lock!(
                lock;
                reason=:AUTO_LOCK
            )
        end
    end

    return nothing
end


# ============================================================
# TAMPER DETECTION
# ============================================================

function tamper!(
    lock::DigitalPadlock,
    reason::String
)

    if lock.state ==
       DISABLED

        return
    end

    lock.state =
        TAMPER

    lock.tamper_until =
        now() +
        Millisecond(
            round(
                lock.config.tamper_lockout_seconds *
                1000
            )
        )

    consume_battery!(
        lock,
        0.50
    )

    log_event!(
        lock.audit,
        :TAMPER,
        0,
        reason
    )
end


# ============================================================
# PHYSICAL OVERRIDE
# ============================================================

function enable_physical_override!(
    lock::DigitalPadlock
)

    lock.physical_override =
        true

    log_event!(
        lock.audit,
        :OVERRIDE_ENABLED,
        0,
        "Physical override enabled"
    )
end


function disable_physical_override!(
    lock::DigitalPadlock
)

    lock.physical_override =
        false

    log_event!(
        lock.audit,
        :OVERRIDE_DISABLED,
        0,
        "Physical override disabled"
    )
end


function override_unlock!(
    lock::DigitalPadlock
)

    lock.physical_override ||
        error(
            "Physical override not enabled."
        )

    lock.state =
        UNLOCKED

    lock.unlocked_since =
        now()

    log_event!(
        lock.audit,
        :OVERRIDE_UNLOCK,
        0,
        "Mechanical override used"
    )

    return true
end


# ============================================================
# STATUS
# ============================================================

function status(
    lock::DigitalPadlock
)

    return (
        state = lock.state,
        battery_percent =
            lock.battery_percent,
        battery_voltage_V =
            lock.battery_voltage_V,
        battery_status =
            battery_status(lock),
        failed_attempts =
            lock.failed_attempts,
        credential_count =
            length(lock.credentials),
        physical_override =
            lock.physical_override
    )
end


function print_status(
    lock::DigitalPadlock
)

    s =
        status(lock)

    println()
    println(
        "="^50
    )

    println(
        "           DIGITAL PADLOCK"
    )

    println(
        "="^50
    )

    println(
        "State:             ",
        s.state
    )

    @printf(
        "Battery:           %.1f %%\n",
        s.battery_percent
    )

    @printf(
        "Battery voltage:   %.2f V\n",
        s.battery_voltage_V
    )

    println(
        "Battery status:    ",
        s.battery_status
    )

    println(
        "Failed attempts:   ",
        s.failed_attempts
    )

    println(
        "Credentials:       ",
        s.credential_count
    )

    println(
        "Override:           ",
        s.physical_override
    )

    println(
        "="^50
    )
end


# ============================================================
# AUDIT REPORT
# ============================================================

function print_audit(
    lock::DigitalPadlock
)

    println()
    println(
        "="^75
    )

    println(
        "              PADLOCK AUDIT LOG"
    )

    println(
        "="^75
    )

    for event in lock.audit.events

        println(
            event.timestamp,
            " | ",
            event.event,
            " | credential=",
            event.credential_id,
            " | ",
            event.message
        )
    end

    println(
        "="^75
    )
end


# ============================================================
# DEMO
# ============================================================

function demo()

    println()
    println(
        "OPEN DIGITAL PADLOCK"
    )
    println(
        "Pure Julia"
    )
    println()

    lock =
        DigitalPadlock()

    admin =
        add_credential!(
            lock,
            "Owner",
            "482917"
        )

    user =
        add_credential!(
            lock,
            "Staff",
            "731604"
        )

    print_status(lock)

    println()
    println(
        "Attempting incorrect credential..."
    )

    unlock!(
        lock,
        "111111"
    )

    println(
        "Attempting owner credential..."
    )

    success =
        unlock!(
            lock,
            "482917"
        )

    println(
        "Unlocked: ",
        success
    )

    print_status(lock)

    println()
    println(
        "Locking..."
    )

    lock!(
        lock
    )

    print_status(lock)

    println()
    println(
        "Simulating tamper event..."
    )

    tamper!(
        lock,
        "Forced movement detected"
    )

    print_status(lock)

    println()
    println(
        "Audit:"
    )

    print_audit(lock)

    return lock
end


# ============================================================
# EXPORTS
# ============================================================

export LockConfig
export Credential
export LockState
export LockEvent
export AuditLog
export DigitalPadlock

export add_credential!
export disable_credential!

export unlock!
export lock!

export activity!
export update!

export tamper!

export enable_physical_override!
export disable_physical_override!
export override_unlock!

export battery_status
export status
export print_status
export print_audit

export demo


end # module DigitalPadlock


# ============================================================
# RUN DEMO
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .DigitalPadlock

    DigitalPadlock.demo()

end
