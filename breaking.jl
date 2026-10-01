# ============================================================
# AUTONOMOUS VEHICLE BRAKING SYSTEM
# Julia prototype
#
# Designed for simulation / control research.
# Production automotive systems require independently validated
# safety-critical hardware/software and fail-safe controls.
# ============================================================

using LinearAlgebra

struct BrakingConfig
    max_braking::Float64       # m/s²
    comfortable_braking::Float64
    reaction_time::Float64     # seconds
    safety_margin::Float64     # metres
    control_period::Float64
end

struct VehicleState
    speed::Float64             # m/s
    acceleration::Float64      # m/s²
end

struct ObstacleState
    distance::Float64          # metres
    relative_speed::Float64    # m/s, positive = closing
end

@enum BrakeMode
    CRUISE
    PRE_BRAKE
    BRAKE
    EMERGENCY_BRAKE
    STOPPED
end


# ============================================================
# CONFIGURATION
# ============================================================

config = BrakingConfig(
    9.0,       # maximum braking
    3.0,       # comfortable braking
    0.8,       # controller/reaction allowance
    2.0,       # safety margin
    0.02       # 50 Hz controller
)


# ============================================================
# STOPPING DISTANCE
# ============================================================

function stopping_distance(
    speed::Float64,
    braking::Float64,
    reaction_time::Float64
)

    speed <= 0 && return 0.0

    reaction_distance =
        speed * reaction_time

    braking_distance =
        speed^2 /
        (2.0 * braking)

    return (
        reaction_distance +
        braking_distance
    )
end


# ============================================================
# TIME TO COLLISION
# ============================================================

function time_to_collision(
    distance::Float64,
    closing_speed::Float64
)

    if closing_speed <= 0
        return Inf
    end

    return distance / closing_speed
end


# ============================================================
# REQUIRED BRAKING
# ============================================================

function required_deceleration(
    speed::Float64,
    distance::Float64
)

    distance <= 0 && return Inf

    # v² = u² + 2as
    return speed^2 /
           (2.0 * distance)
end


# ============================================================
# BRAKING DECISION
# ============================================================

function braking_decision(
    vehicle::VehicleState,
    obstacle::ObstacleState,
    config::BrakingConfig
)

    speed =
        max(vehicle.speed, 0.0)

    distance =
        obstacle.distance -
        config.safety_margin

    # Already stopped
    if speed < 0.1
        return STOPPED, 0.0
    end

    # Collision already imminent
    if distance <= 0
        return EMERGENCY_BRAKE,
               config.max_braking
    end

    closing =
        max(
            obstacle.relative_speed,
            0.0
        )

    ttc =
        time_to_collision(
            distance,
            closing
        )

    stop_distance =
        stopping_distance(
            speed,
            config.max_braking,
            config.reaction_time
        )

    required =
        required_deceleration(
            speed,
            distance
        )

    # --------------------------------------------------------
    # EMERGENCY
    # --------------------------------------------------------

    if ttc < 1.0 ||
       required >= config.max_braking

        return (
            EMERGENCY_BRAKE,
            config.max_braking
        )
    end


    # --------------------------------------------------------
    # NORMAL BRAKING
    # --------------------------------------------------------

    if distance <= stop_distance

        braking =
            min(
                max(
                    required,
                    config.comfortable_braking
                ),
                config.max_braking
            )

        return (
            BRAKE,
            braking
        )
    end


    # --------------------------------------------------------
    # PRE-BRAKE
    # --------------------------------------------------------

    if distance <=
       stop_distance * 1.5

        return (
            PRE_BRAKE,
            config.comfortable_braking
        )
    end


    # --------------------------------------------------------
    # SAFE
    # --------------------------------------------------------

    return CRUISE, 0.0
end


# ============================================================
# VEHICLE DYNAMICS UPDATE
# ============================================================

function update_vehicle!(
    vehicle::VehicleState,
    braking::Float64,
    dt::Float64
)

    acceleration =
        -abs(braking)

    new_speed =
        vehicle.speed +
        acceleration * dt

    vehicle.speed =
        max(new_speed, 0.0)

    vehicle.acceleration =
        acceleration
end


# ============================================================
# EXAMPLE
# ============================================================

vehicle =
    VehicleState(
        13.9,     # ~50 km/h
        0.0
    )

obstacle =
    ObstacleState(
        45.0,     # 45 m ahead
        10.0      # closing at 10 m/s
    )


# ============================================================
# CONTROL LOOP
# ============================================================

for t in 0.0:config.control_period:8.0

    mode, braking =
        braking_decision(
            vehicle,
            obstacle,
            config
        )

    println(
        "t = ",
        round(t, digits=2),
        " s | speed = ",
        round(vehicle.speed, digits=2),
        " m/s | mode = ",
        mode,
        " | braking = ",
        round(braking, digits=2),
        " m/s²"
    )

    update_vehicle!(
        vehicle,
        braking,
        config.control_period
    )

    # Simplified relative-motion simulation
    obstacle =
        ObstacleState(
            obstacle.distance -
            obstacle.relative_speed *
            config.control_period,
            obstacle.relative_speed
        )

    if mode == STOPPED
        break
    end
end
