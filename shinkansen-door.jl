#!/usr/bin/env julia

# ============================================================
# Shinkansen Door Optimisation / Supervisory Controller
#
# Julia prototype
#
# Julia determines:
#   - opening/closing timing recommendations
#   - passenger-flow optimisation
#   - dwell-time estimation
#   - obstruction response
#   - fault detection
#   - door health statistics
#
# A certified door controller should remain responsible for
# the actual motor/interlock commands.
# ============================================================

using Statistics
using Printf
using Dates


# ============================================================
# DOOR STATES
# ============================================================

@enum DoorState begin
    CLOSED
    OPENING
    OPEN
    CLOSING
    OBSTRUCTED
    FAULT
end


# ============================================================
# DOOR SENSOR DATA
# ============================================================

struct DoorSensors

    train_speed::Float64
    platform_aligned::Bool
    door_enabled::Bool
    obstruction::Bool

    passenger_density::Float64
    platform_density::Float64

    open_position::Float64
    close_position::Float64

    motor_temperature::Float64
    motor_current::Float64

end


# ============================================================
# DOOR MODEL
# ============================================================

mutable struct Door

    id::Int

    state::DoorState

    opening_time::Float64
    closing_time::Float64

    total_cycles::Int
    obstruction_count::Int
    fault_count::Int

    last_current::Float64
    health::Float64

end


# ============================================================
# PARAMETERS
# ============================================================

const MAX_SAFE_SPEED = 0.5

const NOMINAL_OPEN_TIME = 1.8
const NOMINAL_CLOSE_TIME = 1.8

const MAX_MOTOR_TEMP = 75.0
const MAX_MOTOR_CURRENT = 15.0

const MIN_HEALTH = 0.50


# ============================================================
# DOOR SAFETY PERMISSION
# ============================================================

function opening_permitted(
    sensors::DoorSensors
)

    return (
        sensors.train_speed <= MAX_SAFE_SPEED &&
        sensors.platform_aligned &&
        sensors.door_enabled &&
        !sensors.obstruction
    )

end


function closing_permitted(
    sensors::DoorSensors
)

    return (
        sensors.door_enabled &&
        !sensors.obstruction
    )

end


# ============================================================
# PASSENGER FLOW MODEL
# ============================================================

function passenger_flow_factor(
    sensors::DoorSensors
)

    density =
        sensors.passenger_density +
        sensors.platform_density

    if density < 0.5
        return 0.85

    elseif density < 1.0
        return 1.0

    elseif density < 1.5
        return 1.15

    else
        return 1.30
    end

end


# ============================================================
# OPENING TIME OPTIMISER
# ============================================================

function optimal_open_time(
    sensors::DoorSensors
)

    factor =
        passenger_flow_factor(
            sensors
        )

    # Higher passenger density means allowing a little
    # additional dwell time.

    return clamp(
        NOMINAL_OPEN_TIME * factor,
        1.5,
        4.0
    )

end


# ============================================================
# CLOSING TIME OPTIMISER
# ============================================================

function optimal_close_time(
    sensors::DoorSensors
)

    factor =
        passenger_flow_factor(
            sensors
        )

    # Avoid unnecessarily aggressive closing when passenger
    # flow is high.

    return clamp(
        NOMINAL_CLOSE_TIME * factor,
        1.5,
        4.0
    )

end


# ============================================================
# OBSTRUCTION HANDLING
# ============================================================

function obstruction_response(
    door::Door,
    sensors::DoorSensors
)

    if sensors.obstruction

        door.obstruction_count += 1

        return :STOP_AND_REOPEN

    end

    return :NORMAL

end


# ============================================================
# MOTOR HEALTH
# ============================================================

function evaluate_motor_health(
    door::Door,
    sensors::DoorSensors
)

    health =
        door.health

    # Temperature penalty.
    if sensors.motor_temperature >
       MAX_MOTOR_TEMP

        excess =
            sensors.motor_temperature -
            MAX_MOTOR_TEMP

        health -=
            0.01 * excess
    end

    # Current penalty.
    if sensors.motor_current >
       MAX_MOTOR_CURRENT

        excess =
            sensors.motor_current -
            MAX_MOTOR_CURRENT

        health -=
            0.015 * excess
    end

    # Sudden current changes can indicate mechanical
    # resistance or degradation.

    current_delta =
        abs(
            sensors.motor_current -
            door.last_current
        )

    if current_delta > 5.0

        health -= 0.05
    end

    door.last_current =
        sensors.motor_current

    door.health =
        clamp(
            health,
            0.0,
            1.0
        )

    return door.health

end


# ============================================================
# FAULT DETECTION
# ============================================================

function detect_fault(
    door::Door,
    sensors::DoorSensors
)

    if sensors.motor_temperature >
       MAX_MOTOR_TEMP + 10

        return :MOTOR_OVERHEAT

    end

    if sensors.motor_current >
       MAX_MOTOR_CURRENT * 1.5

        return :EXCESSIVE_CURRENT

    end

    if door.health <
       MIN_HEALTH

        return :DOOR_HEALTH_LOW

    end

    if !sensors.door_enabled

        return :DOOR_DISABLED

    end

    return :NO_FAULT

end


# ============================================================
# SUPERVISORY DECISION
# ============================================================

function evaluate_door(
    door::Door,
    sensors::DoorSensors
)

    health =
        evaluate_motor_health(
            door,
            sensors
        )

    fault =
        detect_fault(
            door,
            sensors
        )

    obstruction =
        obstruction_response(
            door,
            sensors
        )

    if fault != :NO_FAULT

        door.state =
            FAULT

        door.fault_count += 1

        return (
            action = :FAULT,
            state = FAULT,
            fault = fault,
            health = health
        )

    end

    if obstruction ==
       :STOP_AND_REOPEN

        door.state =
            OBSTRUCTED

        return (
            action = :STOP_AND_REOPEN,
            state = OBSTRUCTED,
            fault = :NONE,
            health = health
        )

    end

    return (
        action = :NORMAL,
        state = door.state,
        fault = :NONE,
        health = health
    )

end


# ============================================================
# DWELL-TIME OPTIMISER
# ============================================================

function optimise_dwell_time(
    sensors::DoorSensors,
    number_of_doors::Int
)

    flow =
        passenger_flow_factor(
            sensors
        )

    base =
        20.0

    # More passengers → longer dwell.
    dwell =
        base * flow

    # Multiple doors reduce required dwell time.
    if number_of_doors > 1

        dwell *=
            1.0 -
            min(
                0.25,
                0.04 *
                (number_of_doors - 1)
            )
    end

    return clamp(
        dwell,
        12.0,
        60.0
    )

end


# ============================================================
# PREDICTIVE DOOR MAINTENANCE
# ============================================================

function maintenance_score(
    door::Door
)

    cycle_factor =
        min(
            door.total_cycles / 1_000_000,
            1.0
        )

    obstruction_factor =
        min(
            door.obstruction_count / 1000,
            1.0
        )

    fault_factor =
        min(
            door.fault_count / 100,
            1.0
        )

    risk =
        0.35 * cycle_factor +
        0.25 * obstruction_factor +
        0.40 * fault_factor

    return clamp(
        risk,
        0.0,
        1.0
    )

end


# ============================================================
# REPORT
# ============================================================

function report(
    door::Door,
    sensors::DoorSensors
)

    result =
        evaluate_door(
            door,
            sensors
        )

    open_time =
        optimal_open_time(
            sensors
        )

    close_time =
        optimal_close_time(
            sensors
        )

    dwell =
        optimise_dwell_time(
            sensors,
            16
        )

    maintenance =
        maintenance_score(
            door
        )

    println()
    println("========================================")
    println("      SHINKANSEN DOOR OPTIMISER")
    println("========================================")

    println(
        "Door:              ",
        door.id
    )

    println(
        "State:             ",
        result.state
    )

    println(
        "Action:            ",
        result.action
    )

    println(
        "Fault:             ",
        result.fault
    )

    @printf(
        "Door health:       %.1f %%\n",
        result.health * 100
    )

    @printf(
        "Optimal open:      %.2f s\n",
        open_time
    )

    @printf(
        "Optimal close:     %.2f s\n",
        close_time
    )

    @printf(
        "Estimated dwell:   %.1f s\n",
        dwell
    )

    @printf(
        "Maintenance risk:  %.1f %%\n",
        maintenance * 100
    )

    println(
        "Cycles:            ",
        door.total_cycles
    )

    println(
        "Obstructions:      ",
        door.obstruction_count
    )

    println(
        "Faults:            ",
        door.fault_count
    )

    println("========================================")

end


# ============================================================
# SIMULATION
# ============================================================

door =
    Door(
        8,
        CLOSED,
        NOMINAL_OPEN_TIME,
        NOMINAL_CLOSE_TIME,
        185_421,
        2,
        0,
        1.0,
        8.0
    )


sensors =
    DoorSensors(
        0.0,       # train speed
        true,      # platform aligned
        true,      # door enabled
        false,     # obstruction

        0.75,      # train passenger density
        1.10,      # platform density

        0.0,
        1.0,

        42.0,      # motor temperature
        7.2        # motor current
    )


report(
    door,
    sensors
)
