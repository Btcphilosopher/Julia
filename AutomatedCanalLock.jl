module AutomatedCanalLock

using Printf

# ============================================================
# AUTOMATED CANAL LOCK CONTROL SYSTEM
#
# Pure Julia
#
# Simulation/control model for:
#   - Boat detection
#   - Lock direction selection
#   - Gate interlocking
#   - Paddle/sluice sequencing
#   - Water-level equalisation
#   - Chamber filling / emptying
#   - Boat position monitoring
#   - Automatic gate movement
#   - Fault detection
#   - Emergency shutdown
#   - Telemetry
#
# A real installation would require independent safety
# systems, physical interlocks, certified PLC/SCADA,
# hydraulic modelling and human/operator override.
#
# Core operating principle:
#   gates closed -> sluices operate -> water levels equalise
#   -> sluices closed -> gates may open
#
# This follows the basic lock operating sequence described
# by Canal & River Trust. :contentReference[oaicite:0]{index=0}
# ============================================================


# ============================================================
# ENUMERATIONS
# ============================================================

@enum LockState begin
    IDLE
    BOAT_APPROACHING
    WAITING_FOR_ENTRY
    ENTRY_GATE_OPENING
    BOAT_ENTERING
    BOAT_POSITIONING
    ENTRY_GATE_CLOSING
    FILLING
    EMPTYING
    LEVEL_EQUALISED
    EXIT_GATE_OPENING
    BOAT_EXITING
    EXIT_GATE_CLOSING
    COMPLETE
    FAULT
    EMERGENCY_STOP
end


@enum Direction begin
    UPHILL
    DOWNHILL
end


@enum GateState begin
    GATE_CLOSED
    GATE_OPENING
    GATE_OPEN
    GATE_CLOSING
    GATE_FAULT
end


@enum PaddleState begin
    PADDLE_CLOSED
    PADDLE_OPENING
    PADDLE_OPEN
    PADDLE_CLOSING
    PADDLE_FAULT
end


# ============================================================
# CONFIGURATION
# ============================================================

struct LockConfig

    chamber_length_m::Float64
    chamber_width_m::Float64

    lower_level_m::Float64
    upper_level_m::Float64

    initial_level_m::Float64

    maximum_fill_rate_ms::Float64
    maximum_empty_rate_ms::Float64

    gate_speed_m_s::Float64
    paddle_speed_m_s::Float64

    boat_entry_speed_ms::Float64
    boat_exit_speed_ms::Float64

    level_tolerance_m::Float64

    boat_position_tolerance_m::Float64

    gate_timeout_s::Float64
    paddle_timeout_s::Float64

    timestep_s::Float64
end


function LockConfig(;
    chamber_length_m=25.0,
    chamber_width_m=3.2,

    lower_level_m=0.0,
    upper_level_m=3.0,

    initial_level_m=0.0,

    maximum_fill_rate_ms=0.015,
    maximum_empty_rate_ms=0.015,

    gate_speed_m_s=0.04,
    paddle_speed_m_s=0.02,

    boat_entry_speed_ms=0.35,
    boat_exit_speed_ms=0.35,

    level_tolerance_m=0.02,
    boat_position_tolerance_m=1.0,

    gate_timeout_s=180.0,
    paddle_timeout_s=180.0,

    timestep_s=0.1
)

    LockConfig(
        Float64(chamber_length_m),
        Float64(chamber_width_m),

        Float64(lower_level_m),
        Float64(upper_level_m),

        Float64(initial_level_m),

        Float64(maximum_fill_rate_ms),
        Float64(maximum_empty_rate_ms),

        Float64(gate_speed_m_s),
        Float64(paddle_speed_m_s),

        Float64(boat_entry_speed_ms),
        Float64(boat_exit_speed_ms),

        Float64(level_tolerance_m),
        Float64(boat_position_tolerance_m),

        Float64(gate_timeout_s),
        Float64(paddle_timeout_s),

        Float64(timestep_s)
    )
end


# ============================================================
# BOAT
# ============================================================

mutable struct Boat

    id::Int

    length_m::Float64
    beam_m::Float64

    x_m::Float64

    speed_ms::Float64

    inside_lock::Bool

    centred::Bool

    stopped::Bool

    direction::Direction

    authorised::Bool
end


# ============================================================
# GATE
# ============================================================

mutable struct Gate

    name::Symbol

    state::GateState

    position::Float64

    command::Float64

    timer_s::Float64
end


# ============================================================
# PADDLE
# ============================================================

mutable struct Paddle

    name::Symbol

    state::PaddleState

    position::Float64

    command::Float64

    timer_s::Float64
end


# ============================================================
# LOCK
# ============================================================

mutable struct AutomatedLock

    config::LockConfig

    state::LockState

    direction::Union{Nothing,Direction}

    water_level_m::Float64

    lower_gate::Gate
    upper_gate::Gate

    lower_paddle::Paddle
    upper_paddle::Paddle

    boat::Union{Nothing,Boat}

    elapsed_s::Float64

    cycle_count::Int

    fault_code::Symbol

    emergency_stop::Bool
end


# ============================================================
# TELEMETRY
# ============================================================

struct LockTelemetry

    time_s::Float64

    state::LockState

    water_level_m::Float64

    lower_gate::GateState
    upper_gate::GateState

    lower_paddle::PaddleState
    upper_paddle::PaddleState

    boat_position_m::Float64

    boat_speed_ms::Float64

    direction::Union{Nothing,Direction}

    fault::Symbol
end


# ============================================================
# CONSTRUCTOR
# ============================================================

function create_lock(
    config::LockConfig=LockConfig()
)

    AutomatedLock(

        config,

        IDLE,

        nothing,

        config.initial_level_m,

        Gate(
            :LOWER,
            GATE_CLOSED,
            0.0,
            0.0,
            0.0
        ),

        Gate(
            :UPPER,
            GATE_CLOSED,
            0.0,
            0.0,
            0.0
        ),

        Paddle(
            :LOWER,
            PADDLE_CLOSED,
            0.0,
            0.0,
            0.0
        ),

        Paddle(
            :UPPER,
            PADDLE_CLOSED,
            0.0,
            0.0,
            0.0
        ),

        nothing,

        0.0,

        0,

        :NONE,

        false
    )
end


# ============================================================
# BOAT CREATION
# ============================================================

function create_boat(;
    id=1,
    length_m=20.0,
    beam_m=2.1,
    direction=UPHILL
)

    Boat(
        id,
        Float64(length_m),
        Float64(beam_m),
        -30.0,
        0.0,
        false,
        false,
        false,
        direction,
        false
    )
end


# ============================================================
# SAFETY INTERLOCKS
# ============================================================

function gates_closed(lock::AutomatedLock)

    return lock.lower_gate.state == GATE_CLOSED &&
           lock.upper_gate.state == GATE_CLOSED
end


function paddles_closed(lock::AutomatedLock)

    return lock.lower_paddle.state == PADDLE_CLOSED &&
           lock.upper_paddle.state == PADDLE_CLOSED
end


function safe_to_open_lower_gate(
    lock::AutomatedLock
)

    return lock.lower_paddle.state ==
           PADDLE_CLOSED &&

           lock.upper_paddle.state ==
           PADDLE_CLOSED &&

           abs(
               lock.water_level_m -
               lock.config.lower_level_m
           ) <=
           lock.config.level_tolerance_m
end


function safe_to_open_upper_gate(
    lock::AutomatedLock
)

    return lock.lower_paddle.state ==
           PADDLE_CLOSED &&

           lock.upper_paddle.state ==
           PADDLE_CLOSED &&

           abs(
               lock.water_level_m -
               lock.config.upper_level_m
           ) <=
           lock.config.level_tolerance_m
end


# ============================================================
# WATER LEVEL
# ============================================================

function water_level_equalised(
    lock::AutomatedLock
)

    target =
        lock.direction == UPHILL ?
        lock.config.upper_level_m :
        lock.config.lower_level_m

    return abs(
        lock.water_level_m -
        target
    ) <=
    lock.config.level_tolerance_m
end


# ============================================================
# GATE COMMANDS
# ============================================================

function open_gate!(
    gate::Gate
)

    if gate.state != GATE_CLOSED
        return false
    end

    gate.state =
        GATE_OPENING

    gate.command =
        1.0

    gate.timer_s =
        0.0

    return true
end


function close_gate!(
    gate::Gate
)

    if gate.state != GATE_OPEN
        return false
    end

    gate.state =
        GATE_CLOSING

    gate.command =
        -1.0

    gate.timer_s =
        0.0

    return true
end


# ============================================================
# PADDLE COMMANDS
# ============================================================

function open_paddle!(
    paddle::Paddle
)

    if paddle.state != PADDLE_CLOSED
        return false
    end

    paddle.state =
        PADDLE_OPENING

    paddle.command =
        1.0

    paddle.timer_s =
        0.0

    return true
end


function close_paddle!(
    paddle::Paddle
)

    if paddle.state != PADDLE_OPEN
        return false
    end

    paddle.state =
        PADDLE_CLOSING

    paddle.command =
        -1.0

    paddle.timer_s =
        0.0

    return true
end


# ============================================================
# GATE SIMULATION
# ============================================================

function update_gate!(
    gate::Gate,
    config::LockConfig
)

    dt =
        config.timestep_s

    if gate.state ==
       GATE_OPENING

        gate.position +=
            config.gate_speed_m_s *
            dt

        gate.timer_s +=
            dt

        if gate.position >= 1.0

            gate.position = 1.0

            gate.state =
                GATE_OPEN
        end

    elseif gate.state ==
           GATE_CLOSING

        gate.position -=
            config.gate_speed_m_s *
            dt

        gate.timer_s +=
            dt

        if gate.position <= 0.0

            gate.position = 0.0

            gate.state =
                GATE_CLOSED
        end
    end

    if gate.timer_s >
       config.gate_timeout_s

        gate.state =
            GATE_FAULT
    end

    return gate
end


# ============================================================
# PADDLE SIMULATION
# ============================================================

function update_paddle!(
    paddle::Paddle,
    config::LockConfig
)

    dt =
        config.timestep_s

    if paddle.state ==
       PADDLE_OPENING

        paddle.position +=
            config.paddle_speed_m_s *
            dt

        paddle.timer_s +=
            dt

        if paddle.position >= 1.0

            paddle.position = 1.0

            paddle.state =
                PADDLE_OPEN
        end

    elseif paddle.state ==
           PADDLE_CLOSING

        paddle.position -=
            config.paddle_speed_m_s *
            dt

        paddle.timer_s +=
            dt

        if paddle.position <= 0.0

            paddle.position = 0.0

            paddle.state =
                PADDLE_CLOSED
        end
    end

    if paddle.timer_s >
       config.paddle_timeout_s

        paddle.state =
            PADDLE_FAULT
    end

    return paddle
end


# ============================================================
# HYDRAULIC MODEL
# ============================================================

function update_water_level!(
    lock::AutomatedLock
)

    dt =
        lock.config.timestep_s

    # Upper paddle fills chamber.
    if lock.upper_paddle.state ==
       PADDLE_OPEN

        lock.water_level_m +=
            lock.config.maximum_fill_rate_ms *
            dt
    end

    # Lower paddle drains chamber.
    if lock.lower_paddle.state ==
       PADDLE_OPEN

        lock.water_level_m -=
            lock.config.maximum_empty_rate_ms *
            dt
    end

    lock.water_level_m =
        clamp(
            lock.water_level_m,
            lock.config.lower_level_m,
            lock.config.upper_level_m
        )

    return lock.water_level_m
end


# ============================================================
# BOAT MOVEMENT
# ============================================================

function update_boat!(
    lock::AutomatedLock
)

    boat =
        lock.boat

    boat === nothing &&
        return

    dt =
        lock.config.timestep_s

    # -----------------------------------------------
    # ENTERING
    # -----------------------------------------------

    if lock.state ==
       BOAT_ENTERING

        boat.speed_ms =
            min(
                boat.speed_ms +
                0.05 * dt,
                lock.config.boat_entry_speed_ms
            )

        boat.x_m +=
            boat.speed_ms * dt

        if boat.x_m >=
           lock.config.chamber_length_m / 2

            boat.x_m =
                lock.config.chamber_length_m / 2

            boat.speed_ms =
                0.0

            boat.stopped =
                true

            boat.centred =
                true

            lock.state =
                BOAT_POSITIONING
        end
    end

    # -----------------------------------------------
    # EXITING
    # -----------------------------------------------

    if lock.state ==
       BOAT_EXITING

        boat.stopped =
            false

        boat.speed_ms =
            lock.config.boat_exit_speed_ms

        if boat.direction ==
           UPHILL

            boat.x_m +=
                boat.speed_ms * dt

            if boat.x_m >
               lock.config.chamber_length_m + 10

                boat.inside_lock =
                    false

                boat.speed_ms =
                    0.0

                lock.state =
                    EXIT_GATE_CLOSING
            end

        else

            boat.x_m -=
                boat.speed_ms * dt

            if boat.x_m <
               -10.0

                boat.inside_lock =
                    false

                boat.speed_ms =
                    0.0

                lock.state =
                    EXIT_GATE_CLOSING
            end
        end
    end
end


# ============================================================
# BOAT ENTRY
# ============================================================

function admit_boat!(
    lock::AutomatedLock,
    boat::Boat
)

    lock.boat !== nothing &&
        throw(
            ArgumentError(
                "Lock already contains a boat"
            )
        )

    boat.authorised =
        true

    boat.inside_lock =
        false

    boat.stopped =
        false

    lock.boat =
        boat

    lock.direction =
        boat.direction

    lock.state =
        BOAT_APPROACHING

    return true
end


# ============================================================
# LOCK STATE MACHINE
# ============================================================

function state_machine!(
    lock::AutomatedLock
)

    boat =
        lock.boat

    config =
        lock.config

    # --------------------------------------------------------
    # FAULT CHECK
    # --------------------------------------------------------

    if lock.lower_gate.state == GATE_FAULT ||
       lock.upper_gate.state == GATE_FAULT ||
       lock.lower_paddle.state == PADDLE_FAULT ||
       lock.upper_paddle.state == PADDLE_FAULT

        lock.state =
            FAULT

        lock.fault_code =
            :ACTUATOR_FAULT

        return
    end

    if lock.emergency_stop

        lock.state =
            EMERGENCY_STOP

        return
    end

    # --------------------------------------------------------
    # BOAT APPROACHING
    # --------------------------------------------------------

    if lock.state ==
       BOAT_APPROACHING

        if boat === nothing

            lock.state =
                IDLE

            return
        end

        # Uphill uses lower gate.
        # Downhill uses upper gate.

        if boat.direction ==
           UPHILL

            if safe_to_open_lower_gate(lock)

                open_gate!(
                    lock.lower_gate
                )

                lock.state =
                    ENTRY_GATE_OPENING
            end

        else

            if safe_to_open_upper_gate(lock)

                open_gate!(
                    lock.upper_gate
                )

                lock.state =
                    ENTRY_GATE_OPENING
            end
        end
    end

    # --------------------------------------------------------
    # ENTRY GATE OPENING
    # --------------------------------------------------------

    if lock.state ==
       ENTRY_GATE_OPENING

        gate =
            boat.direction == UPHILL ?
            lock.lower_gate :
            lock.upper_gate

        if gate.state ==
           GATE_OPEN

            lock.state =
                BOAT_ENTERING

            boat.inside_lock =
                true
        end
    end

    # --------------------------------------------------------
    # BOAT POSITIONED
    # --------------------------------------------------------

    if lock.state ==
       BOAT_POSITIONING

        if boat !== nothing &&
           boat.centred

            if boat.direction ==
               UPHILL

                close_gate!(
                    lock.lower_gate

                )
            else

                close_gate!(
                    lock.upper_gate
                )
            end

            lock.state =
                ENTRY_GATE_CLOSING
        end
    end

    # --------------------------------------------------------
    # ENTRY GATE CLOSING
    # --------------------------------------------------------

    if lock.state ==
       ENTRY_GATE_CLOSING

        if gates_closed(lock)

            if boat.direction ==
               UPHILL

                open_paddle!(
                    lock.upper_paddle

                )

                lock.state =
                    FILLING

            else

                open_paddle!(
                    lock.lower_paddle

                )

                lock.state =
                    EMPTYING
            end
        end
    end

    # --------------------------------------------------------
    # FILLING
    # --------------------------------------------------------

    if lock.state ==
       FILLING

        if water_level_equalised(lock)

            close_paddle!(
                lock.upper_paddle

            )

            lock.state =
                LEVEL_EQUALISED
        end
    end

    # --------------------------------------------------------
    # EMPTYING
    # --------------------------------------------------------

    if lock.state ==
       EMPTYING

        if water_level_equalised(lock)

            close_paddle!(
                lock.lower_paddle

            )

            lock.state =
                LEVEL_EQUALISED
        end
    end

    # --------------------------------------------------------
    # LEVEL EQUALISED
    # --------------------------------------------------------

    if lock.state ==
       LEVEL_EQUALISED

        if paddles_closed(lock)

            if boat.direction ==
               UPHILL

                if safe_to_open_upper_gate(lock)

                    open_gate!(
                        lock.upper_gate
                    )

                    lock.state =
                        EXIT_GATE_OPENING
                end

            else

                if safe_to_open_lower_gate(lock)

                    open_gate!(
                        lock.lower_gate
                    )

                    lock.state =
                        EXIT_GATE_OPENING
                end
            end
        end
    end

    # --------------------------------------------------------
    # EXIT GATE OPENING
    # --------------------------------------------------------

    if lock.state ==
       EXIT_GATE_OPENING

        gate =
            boat.direction == UPHILL ?
            lock.upper_gate :
            lock.lower_gate

        if gate.state ==
           GATE_OPEN

            lock.state =
                BOAT_EXITING
        end
    end

    # --------------------------------------------------------
    # BOAT EXITING
    # --------------------------------------------------------

    if lock.state ==
       BOAT_EXITING

        # Boat movement handled separately.
    end

    # --------------------------------------------------------
    # EXIT GATE CLOSING
    # --------------------------------------------------------

    if lock.state ==
       EXIT_GATE_CLOSING

        gate =
            boat.direction == UPHILL ?
            lock.upper_gate :
            lock.lower_gate

        if gate.state ==
           GATE_OPEN

            close_gate!(
                gate
            )
        end

        if gates_closed(lock)

            lock.state =
                COMPLETE

            lock.cycle_count +=
                1
        end
    end

    # --------------------------------------------------------
    # COMPLETE
    # --------------------------------------------------------

    if lock.state ==
       COMPLETE

        lock.boat =
            nothing

        lock.direction =
            nothing

        lock.state =
            IDLE
    end
end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(
    lock::AutomatedLock
)

    lock.emergency_stop =
        true

    lock.state =
        EMERGENCY_STOP

    lock.fault_code =
        :EMERGENCY_STOP

    # Stop actuator commands.
    lock.lower_gate.command =
        0.0

    lock.upper_gate.command =
        0.0

    lock.lower_paddle.command =
        0.0

    lock.upper_paddle.command =
        0.0

    return true
end


# ============================================================
# RESET
# ============================================================

function reset!(
    lock::AutomatedLock
)

    lock.emergency_stop =
        false

    lock.fault_code =
        :NONE

    lock.state =
        IDLE

    lock.lower_gate.state =
        GATE_CLOSED

    lock.upper_gate.state =
        GATE_CLOSED

    lock.lower_gate.position =
        0.0

    lock.upper_gate.position =
        0.0

    lock.lower_paddle.state =
        PADDLE_CLOSED

    lock.upper_paddle.state =
        PADDLE_CLOSED

    lock.lower_paddle.position =
        0.0

    lock.upper_paddle.position =
        0.0

    return true
end


# ============================================================
# TELEMETRY
# ============================================================

function telemetry(
    lock::AutomatedLock
)

    boat =
        lock.boat

    boat_position =
        boat === nothing ?
        NaN :
        boat.x_m

    boat_speed =
        boat === nothing ?
        0.0 :
        boat.speed_ms

    LockTelemetry(
        lock.elapsed_s,

        lock.state,

        lock.water_level_m,

        lock.lower_gate.state,
        lock.upper_gate.state,

        lock.lower_paddle.state,
        lock.upper_paddle.state,

        boat_position,
        boat_speed,

        lock.direction,

        lock.fault_code
    )
end


# ============================================================
# SIMULATION STEP
# ============================================================

function step!(
    lock::AutomatedLock
)

    dt =
        lock.config.timestep_s

    lock.elapsed_s +=
        dt

    update_gate!(
        lock.lower_gate,
        lock.config
    )

    update_gate!(
        lock.upper_gate,
        lock.config
    )

    update_paddle!(
        lock.lower_paddle,
        lock.config
    )

    update_paddle!(
        lock.upper_paddle,
        lock.config
    )

    update_water_level!(
        lock
    )

    update_boat!(
        lock
    )

    state_machine!(
        lock
    )

    return telemetry(lock)
end


# ============================================================
# COMPLETE AUTOMATED CYCLE
# ============================================================

function run_cycle!(
    lock::AutomatedLock,
    boat::Boat;
    max_time_s=1_800.0
)

    reset!(lock)

    admit_boat!(
        lock,
        boat
    )

    history =
        LockTelemetry[]

    while lock.elapsed_s <
          max_time_s

        data =
            step!(
                lock
            )

        push!(
            history,
            data
        )

        if lock.state ==
           IDLE &&
           lock.cycle_count > 0

            break
        end

        if lock.state ==
           FAULT ||
           lock.state ==
           EMERGENCY_STOP

            break
        end
    end

    return history
end


# ============================================================
# REPORT
# ============================================================

function print_report(
    lock::AutomatedLock,
    history
)

    println()
    println(
        "=========================================================="
    )

    println(
        "          AUTOMATED CANAL LOCK CONTROLLER"
    )

    println(
        "=========================================================="
    )

    @printf(
        "Cycle time:             %.1f s\n",
        lock.elapsed_s
    )

    @printf(
        "Cycle time:             %.2f min\n",
        lock.elapsed_s / 60
    )

    @printf(
        "Final water level:      %.2f m\n",
        lock.water_level_m
    )

    println(
        "Final state:            ",
        lock.state
    )

    println(
        "Direction:              ",
        lock.direction
    )

    println(
        "Fault:                  ",
        lock.fault_code
    )

    println(
        "Cycles completed:      ",
        lock.cycle_count
    )

    if !isempty(history)

        levels =
            [
                x.water_level_m
                for x in history
            ]

        @printf(
            "Minimum water level:    %.2f m\n",
            minimum(levels)
        )

        @printf(
            "Maximum water level:    %.2f m\n",
            maximum(levels)
        )
    end

    println(
        "=========================================================="
    )
end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    config =
        LockConfig(
            chamber_length_m=25.0,
            chamber_width_m=3.2,

            lower_level_m=0.0,
            upper_level_m=3.0,

            initial_level_m=0.0,

            maximum_fill_rate_ms=0.015,
            maximum_empty_rate_ms=0.015,

            timestep_s=0.1
        )

    lock =
        create_lock(
            config
        )

    boat =
        create_boat(
            id=101,
            length_m=20.0,
            beam_m=2.1,
            direction=UPHILL
        )

    println()
    println(
        "Starting automated lock cycle..."
    )

    history =
        run_cycle!(
            lock,
            boat;
            max_time_s=1_800.0
        )

    print_report(
        lock,
        history
    )

    println()
    println(
        "State transitions:"
    )

    last_state =
        nothing

    for sample in history

        if sample.state !=
           last_state

            @printf(
                "%8.1f s   %-25s   water %.2f m\n",
                sample.time_s,
                string(sample.state),
                sample.water_level_m
            )

            last_state =
                sample.state
        end
    end

    return lock, history
end


end # module


# ============================================================
# RUN
# ============================================================

using .AutomatedCanalLock

AutomatedCanalLock.demo()
