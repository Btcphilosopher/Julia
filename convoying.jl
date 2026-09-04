# ================================================================
# RHINO CONVOY
# Autonomous HGV Convoy / Platooning Simulation
#
# Julia 1.10+
#
# PURPOSE
# -------
# Simulation of multiple autonomous heavy goods vehicles travelling
# as a convoy on a motorway.
#
# Features:
#   - Lead vehicle trajectory
#   - Following vehicle control
#   - Adaptive time-gap control
#   - Vehicle-to-vehicle state sharing
#   - Radar-style distance measurement
#   - Acceleration / braking limits
#   - Emergency braking propagation
#   - Safe-gap enforcement
#   - Convoy formation
#   - Basic communication timeout handling
#   - Disturbance simulation
#   - Telemetry logging
#   - Convoy statistics
#
# This is a simulation/prototyping system, NOT production
# autonomous-driving software.
# ================================================================

using Random
using Statistics
using Printf

# ---------------------------------------------------------------
# CONSTANTS
# ---------------------------------------------------------------

const GRAVITY = 9.81
const MAX_SPEED = 25.0          # m/s ≈ 90 km/h
const MIN_SPEED = 0.0

const DEFAULT_TIME_STEP = 0.05 # 20 Hz simulation

# ---------------------------------------------------------------
# VEHICLE
# ---------------------------------------------------------------

mutable struct Vehicle
    id::Int

    # Vehicle state
    x::Float64
    speed::Float64
    acceleration::Float64

    # Physical parameters
    mass::Float64
    max_acceleration::Float64
    max_braking::Float64

    # Platooning parameters
    desired_time_gap::Float64
    minimum_gap::Float64

    # Sensor / communications
    radar_range::Float64
    communication_timeout::Float64
    last_message_time::Float64

    # State
    autonomous::Bool
    emergency_braking::Bool
end


# ---------------------------------------------------------------
# TELEMETRY
# ---------------------------------------------------------------

struct Telemetry
    time::Float64
    vehicle_id::Int
    x::Float64
    speed::Float64
    acceleration::Float64
    gap::Float64
    desired_gap::Float64
    safe::Bool
end


# ---------------------------------------------------------------
# V2V MESSAGE
# ---------------------------------------------------------------

struct V2VMessage
    sender_id::Int
    timestamp::Float64

    x::Float64
    speed::Float64
    acceleration::Float64

    emergency::Bool
end


# ---------------------------------------------------------------
# CONVOY
# ---------------------------------------------------------------

mutable struct Convoy
    vehicles::Vector{Vehicle}

    messages::Dict{Int,V2VMessage}

    telemetry::Vector{Telemetry}

    time::Float64

    communication_enabled::Bool
end


# ---------------------------------------------------------------
# VEHICLE CREATION
# ---------------------------------------------------------------

function create_vehicle(
    id::Int;
    x = 0.0,
    speed = 20.0,
    mass = 40_000.0,
    max_acceleration = 1.0,
    max_braking = 5.0,
    desired_time_gap = 1.5,
    minimum_gap = 8.0,
    radar_range = 250.0
)

    return Vehicle(
        id,
        x,
        speed,
        0.0,
        mass,
        max_acceleration,
        max_braking,
        desired_time_gap,
        minimum_gap,
        radar_range,
        0.5,
        0.0,
        true,
        false
    )
end


# ---------------------------------------------------------------
# SAFE FOLLOWING DISTANCE
# ---------------------------------------------------------------

function desired_gap(vehicle::Vehicle)

    dynamic_gap =
        vehicle.speed *
        vehicle.desired_time_gap

    return max(
        vehicle.minimum_gap,
        dynamic_gap
    )
end


# ---------------------------------------------------------------
# RADAR MODEL
# ---------------------------------------------------------------

function radar_measure(
    follower::Vehicle,
    leader::Vehicle
)

    raw_distance =
        leader.x - follower.x

    # Simple sensor uncertainty
    noise = randn() * 0.05

    return max(
        0.0,
        raw_distance + noise
    )
end


# ---------------------------------------------------------------
# RELATIVE SPEED
# ---------------------------------------------------------------

function relative_speed(
    follower::Vehicle,
    leader::Vehicle
)

    return leader.speed - follower.speed
end


# ---------------------------------------------------------------
# SAFE DISTANCE CHECK
# ---------------------------------------------------------------

function is_safe_gap(
    follower::Vehicle,
    gap::Float64
)

    return gap >= desired_gap(follower)
end


# ---------------------------------------------------------------
# EMERGENCY STOPPING DISTANCE
# ---------------------------------------------------------------

function stopping_distance(
    vehicle::Vehicle
)

    if vehicle.max_braking <= 0
        return Inf
    end

    return vehicle.speed^2 /
           (2.0 * vehicle.max_braking)
end


# ---------------------------------------------------------------
# EMERGENCY SAFETY GAP
# ---------------------------------------------------------------

function emergency_gap(
    vehicle::Vehicle
)

    reaction_time = 0.5

    reaction_distance =
        vehicle.speed * reaction_time

    return (
        stopping_distance(vehicle) +
        reaction_distance +
        vehicle.minimum_gap
    )
end


# ---------------------------------------------------------------
# V2V BROADCAST
# ---------------------------------------------------------------

function broadcast_state!(
    convoy::Convoy
)

    for vehicle in convoy.vehicles

        convoy.messages[vehicle.id] =
            V2VMessage(
                vehicle.id,
                convoy.time,
                vehicle.x,
                vehicle.speed,
                vehicle.acceleration,
                vehicle.emergency_braking
            )
    end
end


# ---------------------------------------------------------------
# GET LEADER
# ---------------------------------------------------------------

function get_leader(
    convoy::Convoy,
    index::Int
)

    if index == 1
        return nothing
    end

    return convoy.vehicles[index - 1]
end


# ---------------------------------------------------------------
# PLATOON CONTROLLER
#
# Hybrid controller:
#
#   gap error
#   + relative velocity
#   + feed-forward leader acceleration
#
# The controller is deliberately conservative.
# ---------------------------------------------------------------

function platoon_controller(
    follower::Vehicle,
    leader::Vehicle,
    gap::Float64,
    dt::Float64
)

    target_gap =
        desired_gap(follower)

    gap_error =
        gap - target_gap

    relative_velocity =
        leader.speed - follower.speed

    # Controller gains
    k_gap = 0.35
    k_relative = 0.85
    k_speed = 0.15

    target_speed =
        min(
            MAX_SPEED,
            leader.speed
        )

    speed_error =
        target_speed - follower.speed

    acceleration =
        k_gap * gap_error +
        k_relative * relative_velocity +
        k_speed * speed_error

    # -----------------------------------------------------------
    # HARD SAFETY OVERRIDE
    # -----------------------------------------------------------

    critical_gap =
        emergency_gap(follower)

    if gap < critical_gap

        # Strong braking
        acceleration =
            -follower.max_braking

        follower.emergency_braking = true

    else

        follower.emergency_braking = false

    end

    return clamp(
        acceleration,
        -follower.max_braking,
        follower.max_acceleration
    )
end


# ---------------------------------------------------------------
# LEAD VEHICLE CONTROLLER
# ---------------------------------------------------------------

function lead_controller(
    vehicle::Vehicle,
    time::Float64
)

    # Example motorway speed profile

    if time < 20.0

        target_speed = 20.0

    elseif time < 40.0

        target_speed = 24.0

    elseif time < 55.0

        target_speed = 18.0

    else

        target_speed = 22.0

    end

    error =
        target_speed - vehicle.speed

    acceleration =
        0.35 * error

    return clamp(
        acceleration,
        -vehicle.max_braking,
        vehicle.max_acceleration
    )
end


# ---------------------------------------------------------------
# PHYSICS UPDATE
# ---------------------------------------------------------------

function update_vehicle!(
    vehicle::Vehicle,
    acceleration::Float64,
    dt::Float64
)

    vehicle.acceleration =
        clamp(
            acceleration,
            -vehicle.max_braking,
            vehicle.max_acceleration
        )

    # Kinematic update

    vehicle.x +=
        vehicle.speed * dt +
        0.5 * vehicle.acceleration * dt^2

    vehicle.speed +=
        vehicle.acceleration * dt

    vehicle.speed =
        clamp(
            vehicle.speed,
            MIN_SPEED,
            MAX_SPEED
        )

end


# ---------------------------------------------------------------
# CONVOY INITIALISATION
# ---------------------------------------------------------------

function create_convoy(
    number_of_vehicles::Int
)

    vehicles =
        Vehicle[]

    initial_speed = 20.0

    spacing = 45.0

    for i in 1:number_of_vehicles

        # Vehicle 1 is at the front.

        x =
            -(i - 1) * spacing

        vehicle =
            create_vehicle(
                i,
                x = x,
                speed = initial_speed
            )

        push!(
            vehicles,
            vehicle
        )
    end

    return Convoy(
        vehicles,
        Dict{Int,V2VMessage}(),
        Telemetry[],
        0.0,
        true
    )
end


# ---------------------------------------------------------------
# COMMUNICATION HEALTH
# ---------------------------------------------------------------

function communication_ok(
    convoy::Convoy,
    vehicle::Vehicle
)

    if !convoy.communication_enabled
        return false
    end

    message =
        get(
            convoy.messages,
            vehicle.id - 1,
            nothing
        )

    if message === nothing
        return false
    end

    age =
        convoy.time -
        message.timestamp

    return age <=
           vehicle.communication_timeout
end


# ---------------------------------------------------------------
# UPDATE CONVOY
# ---------------------------------------------------------------

function update_convoy!(
    convoy::Convoy,
    dt::Float64
)

    convoy.time += dt

    # -----------------------------------------------------------
    # BROADCAST VEHICLE STATES
    # -----------------------------------------------------------

    broadcast_state!(convoy)

    # -----------------------------------------------------------
    # CALCULATE CONTROLS
    # -----------------------------------------------------------

    accelerations =
        zeros(
            length(convoy.vehicles)
        )

    for i in eachindex(convoy.vehicles)

        vehicle =
            convoy.vehicles[i]

        # -------------------------------------------------------
        # LEAD VEHICLE
        # -------------------------------------------------------

        if i == 1

            accelerations[i] =
                lead_controller(
                    vehicle,
                    convoy.time
                )

        # -------------------------------------------------------
        # FOLLOWER
        # -------------------------------------------------------

        else

            leader =
                convoy.vehicles[i - 1]

            gap =
                leader.x -
                vehicle.x

            accelerations[i] =
                platoon_controller(
                    vehicle,
                    leader,
                    gap,
                    dt
                )

            # ---------------------------------------------------
            # COMMUNICATION FAILURE
            # ---------------------------------------------------

            if !communication_ok(
                convoy,
                vehicle
            )

                # Fall back to local sensing.
                #
                # Reduce speed and increase following distance.

                local_target =
                    max(
                        12.0,
                        leader.speed - 2.0
                    )

                speed_error =
                    local_target -
                    vehicle.speed

                fallback_accel =
                    0.2 *
                    speed_error

                accelerations[i] =
                    min(
                        accelerations[i],
                        fallback_accel
                    )
            end
        end
    end

    # -----------------------------------------------------------
    # APPLY PHYSICS
    # -----------------------------------------------------------

    for i in eachindex(convoy.vehicles)

        vehicle =
            convoy.vehicles[i]

        update_vehicle!(
            vehicle,
            accelerations[i],
            dt
        )
    end

    # -----------------------------------------------------------
    # TELEMETRY
    # -----------------------------------------------------------

    record_telemetry!(
        convoy
    )

end


# ---------------------------------------------------------------
# TELEMETRY LOGGER
# ---------------------------------------------------------------

function record_telemetry!(
    convoy::Convoy
)

    for i in eachindex(convoy.vehicles)

        vehicle =
            convoy.vehicles[i]

        if i == 1

            gap = Inf

        else

            leader =
                convoy.vehicles[i - 1]

            gap =
                leader.x -
                vehicle.x
        end

        safe =
            i == 1 ||
            is_safe_gap(
                vehicle,
                gap
            )

        push!(
            convoy.telemetry,
            Telemetry(
                convoy.time,
                vehicle.id,
                vehicle.x,
                vehicle.speed,
                vehicle.acceleration,
                gap,
                desired_gap(vehicle),
                safe
            )
        )
    end
end


# ---------------------------------------------------------------
# EMERGENCY BRAKING EVENT
# ---------------------------------------------------------------

function trigger_emergency_braking!(
    convoy::Convoy
)

    println(
        "\n!!! LEAD VEHICLE EMERGENCY BRAKING !!!"
    )

    convoy.vehicles[1].emergency_braking =
        true

    convoy.vehicles[1].acceleration =
        -convoy.vehicles[1].max_braking
end


# ---------------------------------------------------------------
# EMERGENCY BRAKING PROPAGATION
# ---------------------------------------------------------------

function propagate_emergency!(
    convoy::Convoy
)

    for i in 2:length(convoy.vehicles)

        leader =
            convoy.vehicles[i - 1]

        follower =
            convoy.vehicles[i]

        gap =
            leader.x -
            follower.x

        if leader.emergency_braking

            if gap <
               emergency_gap(follower)

                follower.emergency_braking =
                    true

                follower.acceleration =
                    -follower.max_braking
            end
        end
    end
end


# ---------------------------------------------------------------
# CONVOY STATISTICS
# ---------------------------------------------------------------

function convoy_statistics(
    convoy::Convoy
)

    speeds =
        [v.speed for v in convoy.vehicles]

    gaps =
        Float64[]

    for i in 2:length(convoy.vehicles)

        push!(
            gaps,
            convoy.vehicles[i - 1].x -
            convoy.vehicles[i].x
        )
    end

    println()
    println(
        "==============================="
    )
    println(
        "RHINO CONVOY STATISTICS"
    )
    println(
        "==============================="
    )

    @printf(
        "Vehicles:          %d\n",
        length(convoy.vehicles)
    )

    @printf(
        "Convoy time:       %.1f s\n",
        convoy.time
    )

    @printf(
        "Average speed:     %.2f m/s\n",
        mean(speeds)
    )

    @printf(
        "Average speed:     %.2f km/h\n",
        mean(speeds) * 3.6
    )

    if !isempty(gaps)

        @printf(
            "Minimum gap:       %.2f m\n",
            minimum(gaps)
        )

        @printf(
            "Average gap:       %.2f m\n",
            mean(gaps)
        )
    end

    unsafe_count =
        count(
            t -> !t.safe,
            convoy.telemetry
        )

    @printf(
        "Unsafe observations:%d\n",
        unsafe_count
    )

    println(
        "==============================="
    )
end


# ---------------------------------------------------------------
# LIVE STATUS
# ---------------------------------------------------------------

function print_status(
    convoy::Convoy
)

    println()
    @printf(
        "TIME %.1f s\n",
        convoy.time
    )

    println(
        "-----------------------------------------------"
    )

    @printf(
        "%-8s %-12s %-12s %-12s %-10s\n",
        "TRUCK",
        "POSITION",
        "SPEED",
        "ACCEL",
        "GAP"
    )

    for i in eachindex(convoy.vehicles)

        v =
            convoy.vehicles[i]

        if i == 1

            gap = Inf

        else

            gap =
                convoy.vehicles[i-1].x -
                v.x
        end

        @printf(
            "%-8d %-12.1f %-12.2f %-12.2f %-10.1f\n",
            v.id,
            v.x,
            v.speed * 3.6,
            v.acceleration,
            gap
        )
    end
end


# ---------------------------------------------------------------
# MAIN SIMULATION
# ---------------------------------------------------------------

function run_simulation(;
    vehicles = 8,
    duration = 120.0,
    dt = DEFAULT_TIME_STEP
)

    println()
    println(
        "=============================================="
    )

    println(
        "          RHINO CONVOY SIMULATOR"
    )

    println(
        " Autonomous HGV Platooning Demonstrator"
    )

    println(
        "=============================================="
    )

    convoy =
        create_convoy(
            vehicles
        )

    next_status =
        0.0

    emergency_triggered =
        false

    while convoy.time < duration

        # -------------------------------------------------------
        # Example emergency event
        # -------------------------------------------------------

        if convoy.time >= 60.0 &&
           !emergency_triggered

            trigger_emergency_braking!(
                convoy
            )

            emergency_triggered =
                true
        end

        # -------------------------------------------------------
        # Propagate emergency state
        # -------------------------------------------------------

        propagate_emergency!(
            convoy
        )

        # -------------------------------------------------------
        # Update simulation
        # -------------------------------------------------------

        update_convoy!(
            convoy,
            dt
        )

        # -------------------------------------------------------
        # Console status
        # -------------------------------------------------------

        if convoy.time >= next_status

            print_status(
                convoy
            )

            next_status += 5.0
        end
    end

    convoy_statistics(
        convoy
    )

    return convoy
end


# ---------------------------------------------------------------
# RUN
# ---------------------------------------------------------------

if abspath(PROGRAM_FILE) ==
   @__FILE__

    convoy =
        run_simulation(
            vehicles = 10,
            duration = 120.0
        )

end
