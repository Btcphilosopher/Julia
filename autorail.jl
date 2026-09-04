using Dates
using Printf

# ============================================================
# RHINO RAIL ATO
# AUTOMATED STATION-TO-STATION TRAIN CONTROLLER
#
# SIMULATION / CONTROL-LOGIC PROTOTYPE
# ============================================================

# ------------------------------------------------------------
# TRAIN STATES
# ------------------------------------------------------------

const STOPPED    = :STOPPED
const ACCELERATE = :ACCELERATE
const CRUISE     = :CRUISE
const BRAKE      = :BRAKE
const DOORS_OPEN = :DOORS_OPEN
const DWELL      = :DWELL
const DOORS_CLOSE = :DOORS_CLOSE
const DEPART     = :DEPART
const EMERGENCY  = :EMERGENCY

# ------------------------------------------------------------
# STATION
# ------------------------------------------------------------

struct Station

    id::String
    name::String

    distance_from_previous_km::Float64

    platform::Int

    dwell_seconds::Float64

    stopping_tolerance_m::Float64
end

# ------------------------------------------------------------
# TRAIN
# ------------------------------------------------------------

mutable struct Train

    id::String

    speed_kmh::Float64

    position_km::Float64

    acceleration_ms2::Float64

    braking_ms2::Float64

    max_speed_kmh::Float64

    state::Symbol

    doors_open::Bool

    brake_applied::Bool

    current_station::Int

    target_station::Int

    dwell_remaining::Float64

    emergency_brake::Bool

    movement_authority_km::Float64
end

# ------------------------------------------------------------
# LINE
# ------------------------------------------------------------

struct RailwayLine

    stations::Vector{Station}
end

# ------------------------------------------------------------
# CONTROLLER
# ------------------------------------------------------------

mutable struct ATOController

    train::Train

    line::RailwayLine

    running::Bool

    simulation_time::Float64

    log::Vector{String}
end

# ============================================================
# LOGGING
# ============================================================

function log_event!(controller, message)

    timestamp = @sprintf(
        "%08.1f",
        controller.simulation_time
    )

    entry = "[$timestamp s] $message"

    push!(
        controller.log,
        entry
    )

    println(entry)
end

# ============================================================
# BASIC PHYSICS
# ============================================================

function speed_ms(train)

    return train.speed_kmh / 3.6
end

function speed_kmh(ms)

    return ms * 3.6
end

# ============================================================
# BRAKING DISTANCE
# ============================================================

function braking_distance(train)

    v = speed_ms(train)

    a = train.braking_ms2

    if a <= 0
        return Inf
    end

    return v^2 / (2a) / 1000
end

# ============================================================
# DISTANCE TO STATION
# ============================================================

function distance_to_station(controller)

    train = controller.train

    station =
        controller.line.stations[
            train.target_station
        ]

    return station.distance_from_previous_km -
           (
               train.position_km -
               controller.line.stations[
                   train.current_station
               ].distance_from_previous_km
           )
end

# ============================================================
# SIMPLIFIED TARGET DISTANCE
# ============================================================

function target_distance(controller)

    train = controller.train

    current_station =
        controller.line.stations[
            train.current_station
        ]

    target_station =
        controller.line.stations[
            train.target_station
        ]

    # Position represented relative to route origin.
    target_absolute =
        sum(
            s.distance_from_previous_km
            for s in controller.line.stations[
                2:train.target_station
            ]
        )

    return target_absolute -
           train.position_km
end

# ============================================================
# SAFE SPEED CALCULATION
# ============================================================

function safe_speed_for_stop(controller)

    train = controller.train

    distance_km =
        max(target_distance(controller), 0.001)

    distance_m =
        distance_km * 1000

    a =
        train.braking_ms2

    # v = sqrt(2as)

    safe_speed_ms =
        sqrt(
            2 *
            a *
            distance_m
        )

    return speed_kmh(
        safe_speed_ms
    )
end

# ============================================================
# ACCELERATION
# ============================================================

function accelerate!(controller, dt)

    train = controller.train

    if train.emergency_brake
        return
    end

    velocity =
        speed_ms(train)

    velocity +=
        train.acceleration_ms2 * dt

    velocity =
        min(
            velocity,
            speed_ms(
                train.max_speed_kmh
            )
        )

    train.speed_kmh =
        speed_kmh(velocity)

    train.position_km +=
        train.speed_kmh *
        dt /
        3600
end

# ============================================================
# CRUISE
# ============================================================

function cruise!(controller, dt)

    train = controller.train

    train.speed_kmh =
        min(
            train.speed_kmh,
            train.max_speed_kmh
        )

    train.position_km +=
        train.speed_kmh *
        dt /
        3600
end

# ============================================================
# BRAKING
# ============================================================

function brake!(controller, dt)

    train = controller.train

    velocity =
        speed_ms(train)

    velocity -=
        train.braking_ms2 * dt

    velocity =
        max(velocity, 0.0)

    train.speed_kmh =
        speed_kmh(velocity)

    train.position_km +=
        train.speed_kmh *
        dt /
        3600
end

# ============================================================
# DOOR CONTROL
# ============================================================

function open_doors!(controller)

    train = controller.train

    if train.speed_kmh > 0.1
        return false
    end

    train.brake_applied = true

    train.doors_open = true

    train.state = DOORS_OPEN

    log_event!(
        controller,
        "DOORS OPEN"
    )

    return true
end

function close_doors!(controller)

    train = controller.train

    train.doors_open = false

    train.state = DOORS_CLOSE

    log_event!(
        controller,
        "DOORS CLOSED"
    )

    return true
end

# ============================================================
# STATION ARRIVAL
# ============================================================

function arrive_at_station!(controller)

    train = controller.train

    station =
        controller.line.stations[
            train.target_station
        ]

    train.speed_kmh = 0.0

    train.brake_applied = true

    train.state = STOPPED

    train.current_station =
        train.target_station

    train.position_km =
        sum(
            s.distance_from_previous_km
            for s in controller.line.stations[
                2:train.current_station
            ]
        )

    log_event!(
        controller,
        "ARRIVED AT $(station.name)"
    )

    log_event!(
        controller,
        "PLATFORM $(station.platform) DOCKED"
    )

    open_doors!(
        controller
    )
end

# ============================================================
# DWELL TIMER
# ============================================================

function start_dwell!(controller)

    train = controller.train

    station =
        controller.line.stations[
            train.current_station
        ]

    train.dwell_remaining =
        station.dwell_seconds

    train.state = DWELL

    log_event!(
        controller,
        "DWELL START: $(station.dwell_seconds)s"
    )
end

# ============================================================
# DEPARTURE AUTHORISATION
# ============================================================

function departure_authorised(controller)

    train = controller.train

    # --------------------------------------------------------
    # Simplified ATP / signalling permission
    # --------------------------------------------------------

    if train.emergency_brake
        return false
    end

    if train.movement_authority_km <=
       train.position_km

        return false
    end

    if train.doors_open
        return false
    end

    if train.brake_applied &&
       train.speed_kmh > 0.0

        return false
    end

    return true
end

# ============================================================
# DEPART TRAIN
# ============================================================

function depart!(controller)

    train = controller.train

    if !departure_authorised(controller)

        log_event!(
            controller,
            "DEPARTURE BLOCKED"
        )

        return false
    end

    train.brake_applied = false

    train.state = ACCELERATE

    log_event!(
        controller,
        "TRAIN DEPARTING"
    )

    return true
end

# ============================================================
# NEXT STATION
# ============================================================

function next_station!(controller)

    train = controller.train

    if train.current_station >=
       length(controller.line.stations)

        log_event!(
            controller,
            "END OF LINE"
        )

        controller.running = false

        return
    end

    train.target_station =
        train.current_station + 1

    # --------------------------------------------------------
    # Movement authority:
    #
    # In a real system this would come from ATP/ETCS/CBTC
    # rather than this simplified model.
    # --------------------------------------------------------

    target_absolute =
        sum(
            s.distance_from_previous_km
            for s in controller.line.stations[
                2:train.target_station
            ]
        )

    train.movement_authority_km =
        target_absolute + 1.0

    log_event!(
        controller,
        "NEXT STOP: " *
        controller.line.stations[
            train.target_station
        ].name
    )

    depart!(controller)
end

# ============================================================
# EMERGENCY BRAKING
# ============================================================

function emergency_brake!(controller, reason)

    train = controller.train

    train.emergency_brake = true

    train.brake_applied = true

    train.state = EMERGENCY

    log_event!(
        controller,
        "!!! EMERGENCY BRAKE !!!"
    )

    log_event!(
        controller,
        reason
    )
end

# ============================================================
# EMERGENCY RESET
# ============================================================

function reset_emergency!(controller)

    train = controller.train

    train.emergency_brake = false

    train.speed_kmh = 0.0

    train.brake_applied = true

    train.state = STOPPED

    log_event!(
        controller,
        "EMERGENCY CONDITION RESET"
    )
end

# ============================================================
# ATO DECISION ENGINE
# ============================================================

function ato_decision!(controller, dt)

    train = controller.train

    # --------------------------------------------------------
    # EMERGENCY
    # --------------------------------------------------------

    if train.emergency_brake

        brake!(
            controller,
            dt
        )

        return
    end

    # --------------------------------------------------------
    # STOPPED
    # --------------------------------------------------------

    if train.state == STOPPED

        start_dwell!(
            controller
        )

        return
    end

    # --------------------------------------------------------
    # DWELL
    # --------------------------------------------------------

    if train.state == DWELL

        train.dwell_remaining -= dt

        if train.dwell_remaining <= 0

            close_doors!(
                controller
            )

            # Release brake after door proving

            train.brake_applied = false

            next_station!(
                controller
            )
        end

        return
    end

    # --------------------------------------------------------
    # DOORS OPEN
    # --------------------------------------------------------

    if train.state == DOORS_OPEN

        start_dwell!(
            controller
        )

        return
    end

    # --------------------------------------------------------
    # DOORS CLOSE
    # --------------------------------------------------------

    if train.state == DOORS_CLOSE

        if departure_authorised(controller)

            train.brake_applied = false

            train.state = ACCELERATE

        end

        return
    end

    # --------------------------------------------------------
    # ACCELERATION
    # --------------------------------------------------------

    if train.state == ACCELERATE

        safe_speed =
            safe_speed_for_stop(
                controller
            )

        if safe_speed <
           train.speed_kmh + 5

            train.state = BRAKE

            log_event!(
                controller,
                "BRAKING COMMAND"
            )

            return
        end

        if train.speed_kmh >=
           train.max_speed_kmh

            train.state = CRUISE

            log_event!(
                controller,
                "CRUISE SPEED REACHED"
            )

            return
        end

        accelerate!(
            controller,
            dt
        )

        return
    end

    # --------------------------------------------------------
    # CRUISE
    # --------------------------------------------------------

    if train.state == CRUISE

        safe_speed =
            safe_speed_for_stop(
                controller
            )

        if safe_speed <
           train.speed_kmh

            train.state = BRAKE

            log_event!(
                controller,
                "BRAKING PROFILE REACHED"
            )

            return
        end

        cruise!(
            controller,
            dt

        )

        return
    end

    # --------------------------------------------------------
    # BRAKING
    # --------------------------------------------------------

    if train.state == BRAKE

        brake!(
            controller,
            dt
        )

        if train.speed_kmh <= 0.5

            arrive_at_station!(
                controller
            )

        end

        return
    end
end

# ============================================================
# STATUS DISPLAY
# ============================================================

function status(controller)

    train = controller.train

    println()
    println("============================================================")
    println("                    RHINO RAIL ATO")
    println("============================================================")

    @printf(
        "Train:              %s\n",
        train.id
    )

    @printf(
        "State:              %s\n",
        train.state
    )

    @printf(
        "Speed:              %.1f km/h\n",
        train.speed_kmh
    )

    @printf(
        "Position:           %.3f km\n",
        train.position_km
    )

    @printf(
        "Current station:    %s\n",
        controller.line.stations[
            train.current_station
        ].name
    )

    @printf(
        "Target station:     %s\n",
        controller.line.stations[
            train.target_station
        ].name
    )

    @printf(
        "Doors:              %s\n",
        train.doors_open ?
        "OPEN" :
        "CLOSED"
    )

    @printf(
        "Brake:              %s\n",
        train.brake_applied ?
        "APPLIED" :
        "RELEASED"
    )

    @printf(
        "Dwell remaining:    %.1f s\n",
        train.dwell_remaining
    )

    @printf(
        "Movement authority %.2f km\n",
        train.movement_authority_km
    )

    println("============================================================")
end

# ============================================================
# CREATE LINE
# ============================================================

function create_line()

    stations = [

        Station(
            "ST01",
            "London",
            0.0,
            1,
            30.0,
            0.5
        ),

        Station(
            "ST02",
            "Reading",
            58.0,
            2,
            45.0,
            0.5
        ),

        Station(
            "ST03",
            "Swindon",
            77.0,
            1,
            40.0,
            0.5
        ),

        Station(
            "ST04",
            "Bristol",
            65.0,
            3,
            60.0,
            0.5
        )
    ]

    return RailwayLine(stations)
end

# ============================================================
# CREATE TRAIN
# ============================================================

function create_train()

    return Train(
        "RHINO-001",

        0.0,       # speed
        0.0,       # position

        0.65,      # acceleration m/s²
        0.85,      # braking m/s²

        125.0,     # maximum speed

        STOPPED,

        false,     # doors
        true,      # brake

        1,         # current station
        2,         # target station

        0.0,

        false,

        59.0       # movement authority
    )
end

# ============================================================
# SIMULATION
# ============================================================

function run_simulation()

    line =
        create_line()

    train =
        create_train()

    controller =
        ATOController(
            train,
            line,
            true,
            0.0,
            String[]
        )

    println()
    println("============================================================")
    println("         RHINO RAIL AUTOMATED TRAIN OPERATION")
    println("============================================================")

    log_event!(
        controller,
        "ATO SYSTEM INITIALISED"
    )

    log_event!(
        controller,
        "TRAIN $(train.id) READY"
    )

    # Initial departure

    train.doors_open = false

    train.brake_applied = false

    train.state = ACCELERATE

    log_event!(
        controller,
        "INITIAL DEPARTURE"
    )

    dt = 0.5

    maximum_simulation_time = 25000.0

    while controller.running &&
          controller.simulation_time <
          maximum_simulation_time

        ato_decision!(
            controller,
            dt
        )

        controller.simulation_time += dt

        # Print status periodically

        if mod(
            Int(round(controller.simulation_time)),
            30
        ) == 0

            if abs(
                controller.simulation_time -
                round(controller.simulation_time)
            ) < 0.001

                status(controller)

            end
        end

        # Stop when last station reached

        if train.current_station >=
           length(line.stations)

            if train.state == DWELL ||
               train.state == STOPPED

                log_event!(
                    controller,
                    "SERVICE COMPLETE"
                )

                controller.running = false
            end
        end
    end

    status(controller)

    println()
    println("Simulation finished.")
end

# ============================================================
# RUN
# ============================================================

run_simulation()
