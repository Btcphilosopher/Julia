using LinearAlgebra
using Statistics
using Dates

# ============================================================
# AUREOM VEHICLE AI
# SENSOR OPTIMISATION + SENSOR FUSION ENGINE
#
# Simulation / research prototype
# ============================================================


# ============================================================
# SENSOR TYPES
# ============================================================

@enum SensorType begin
    CAMERA
    RADAR
    LIDAR
    ULTRASONIC
    GNSS
    IMU
    WHEEL_SPEED
    STEERING
end


# ============================================================
# SENSOR MEASUREMENT
# ============================================================

struct SensorMeasurement
    sensor::SensorType

    x::Float64
    y::Float64
    z::Float64

    vx::Float64
    vy::Float64

    timestamp::Float64

    noise::Float64
    confidence::Float64

    valid::Bool
end


# ============================================================
# SENSOR HEALTH
# ============================================================

mutable struct SensorHealth

    sensor::SensorType

    confidence::Float64

    latency_ms::Float64

    dropout_rate::Float64

    noise_estimate::Float64

    temperature::Float64

    contamination::Float64

    calibration_error::Float64

    health_score::Float64

    enabled::Bool
end


# ============================================================
# VEHICLE STATE
# ============================================================

mutable struct VehicleState

    x::Float64
    y::Float64
    z::Float64

    vx::Float64
    vy::Float64
    vz::Float64

    yaw::Float64
    yaw_rate::Float64

    acceleration_x::Float64
    acceleration_y::Float64

    steering_angle::Float64

    speed::Float64

    timestamp::Float64
end


# ============================================================
# OBJECT TRACK
# ============================================================

mutable struct ObjectTrack

    id::Int

    x::Float64
    y::Float64

    vx::Float64
    vy::Float64

    acceleration_x::Float64
    acceleration_y::Float64

    length::Float64
    width::Float64

    confidence::Float64

    age::Int
    missed_frames::Int

    last_update::Float64
end


# ============================================================
# SENSOR CONFIGURATION
# ============================================================

struct SensorConfig

    max_camera_range::Float64
    max_radar_range::Float64
    max_lidar_range::Float64
    max_ultrasonic_range::Float64

    max_sensor_latency_ms::Float64

    maximum_dropout_rate::Float64

    outlier_threshold::Float64

    fusion_dt::Float64
end


function create_sensor_config()

    SensorConfig(
        200.0,
        300.0,
        250.0,
        8.0,

        100.0,

        0.10,

        3.0,

        0.02
    )

end


# ============================================================
# SENSOR BASELINE CONFIDENCE
# ============================================================

function baseline_confidence(sensor::SensorType)

    if sensor == CAMERA
        return 0.82

    elseif sensor == RADAR
        return 0.90

    elseif sensor == LIDAR
        return 0.94

    elseif sensor == ULTRASONIC
        return 0.88

    elseif sensor == GNSS
        return 0.90

    elseif sensor == IMU
        return 0.97

    elseif sensor == WHEEL_SPEED
        return 0.98

    elseif sensor == STEERING
        return 0.98
    end

end


# ============================================================
# SENSOR HEALTH SCORE
# ============================================================

function calculate_sensor_health!(
    health::SensorHealth,
    cfg::SensorConfig
)

    latency_factor =
        clamp(
            1.0 -
            health.latency_ms /
            cfg.max_sensor_latency_ms,
            0.0,
            1.0
        )

    dropout_factor =
        clamp(
            1.0 -
            health.dropout_rate /
            cfg.maximum_dropout_rate,
            0.0,
            1.0
        )

    noise_factor =
        clamp(
            1.0 -
            health.noise_estimate,
            0.0,
            1.0
        )

    contamination_factor =
        1.0 -
        health.contamination

    calibration_factor =
        1.0 -
        health.calibration_error

    health.health_score =
        0.25 * health.confidence +
        0.15 * latency_factor +
        0.15 * dropout_factor +
        0.15 * noise_factor +
        0.15 * contamination_factor +
        0.15 * calibration_factor

    health.health_score =
        clamp(
            health.health_score,
            0.0,
            1.0
        )

    health.enabled =
        health.health_score > 0.25

    return health
end


# ============================================================
# ADAPTIVE SENSOR WEIGHT
# ============================================================

function sensor_weight(
    health::SensorHealth
)

    if !health.enabled
        return 0.0
    end

    # Confidence is not enough:
    # sensor quality + health + uncertainty
    return (
        health.health_score^2 /
        max(
            health.noise_estimate,
            0.01
        )
    )

end


# ============================================================
# NORMALISE WEIGHTS
# ============================================================

function normalise_weights(
    weights::Vector{Float64}
)

    total =
        sum(weights)

    if total <= 0.0
        return zeros(length(weights))
    end

    return weights ./ total

end


# ============================================================
# OUTLIER DETECTION
# ============================================================

function measurement_distance(
    a::SensorMeasurement,
    b::SensorMeasurement
)

    return sqrt(
        (a.x - b.x)^2 +
        (a.y - b.y)^2 +
        (a.z - b.z)^2
    )

end


function reject_outlier(
    measurement::SensorMeasurement,
    reference::SensorMeasurement,
    cfg::SensorConfig
)

    distance =
        measurement_distance(
            measurement,
            reference
        )

    return distance >
           cfg.outlier_threshold

end


# ============================================================
# WEIGHTED POSITION FUSION
# ============================================================

function fuse_position(
    measurements::Vector{SensorMeasurement},
    healths::Vector{SensorHealth},
    cfg::SensorConfig
)

    valid_measurements =
        SensorMeasurement[]

    raw_weights =
        Float64[]

    for i in eachindex(measurements)

        m = measurements[i]
        h = healths[i]

        if m.valid && h.enabled

            push!(
                valid_measurements,
                m
            )

            push!(
                raw_weights,
                sensor_weight(h)
            )

        end
    end

    if isempty(valid_measurements)

        return (
            0.0,
            0.0,
            0.0,
            0.0
        )
    end

    weights =
        normalise_weights(
            raw_weights
        )

    x = 0.0
    y = 0.0
    z = 0.0

    for i in eachindex(valid_measurements)

        m =
            valid_measurements[i]

        w =
            weights[i]

        x += w * m.x
        y += w * m.y
        z += w * m.z

    end

    confidence =
        sum(weights.^2)

    return (
        x,
        y,
        z,
        confidence
    )

end


# ============================================================
# VELOCITY FUSION
# ============================================================

function fuse_velocity(
    measurements::Vector{SensorMeasurement},
    healths::Vector{SensorHealth}
)

    values_x =
        Float64[]

    values_y =
        Float64[]

    weights =
        Float64[]

    for i in eachindex(measurements)

        m = measurements[i]
        h = healths[i]

        if m.valid && h.enabled

            push!(
                values_x,
                m.vx
            )

            push!(
                values_y,
                m.vy
            )

            push!(
                weights,
                sensor_weight(h)
            )

        end
    end

    if isempty(values_x)

        return (
            0.0,
            0.0
        )
    end

    weights =
        normalise_weights(
            weights
        )

    vx =
        sum(
            values_x .* weights
        )

    vy =
        sum(
            values_y .* weights
        )

    return (
        vx,
        vy
    )

end


# ============================================================
# SIMPLE STATE PREDICTION
# ============================================================

function predict_vehicle_state!(
    state::VehicleState,
    dt::Float64
)

    state.x +=
        state.vx * dt

    state.y +=
        state.vy * dt

    state.vx +=
        state.acceleration_x * dt

    state.vy +=
        state.acceleration_y * dt

    state.yaw +=
        state.yaw_rate * dt

    state.speed =
        sqrt(
            state.vx^2 +
            state.vy^2
        )

    state.timestamp +=
        dt

    return state

end


# ============================================================
# MEASUREMENT UPDATE
# ============================================================

function update_vehicle_state!(
    state::VehicleState,
    measurements::Vector{SensorMeasurement},
    healths::Vector{SensorHealth},
    cfg::SensorConfig
)

    x, y, z, confidence =
        fuse_position(
            measurements,
            healths,
            cfg
        )

    vx, vy =
        fuse_velocity(
            measurements,
            healths
        )

    # Confidence-dependent correction
    gain =
        clamp(
            confidence * 1.5,
            0.1,
            0.9
        )

    state.x =
        (1.0 - gain) *
        state.x +
        gain * x

    state.y =
        (1.0 - gain) *
        state.y +
        gain * y

    state.z =
        (1.0 - gain) *
        state.z +
        gain * z

    state.vx =
        (1.0 - gain) *
        state.vx +
        gain * vx

    state.vy =
        (1.0 - gain) *
        state.vy +
        gain * vy

    state.speed =
        sqrt(
            state.vx^2 +
            state.vy^2
        )

    return state

end


# ============================================================
# OBJECT TRACKING
# ============================================================

function predict_track!(
    track::ObjectTrack,
    dt::Float64
)

    track.x +=
        track.vx * dt

    track.y +=
        track.vy * dt

    track.vx +=
        track.acceleration_x * dt

    track.vy +=
        track.acceleration_y * dt

    track.age += 1

    track.missed_frames += 1

end


# ============================================================
# TRACK UPDATE
# ============================================================

function update_track!(
    track::ObjectTrack,
    measurement::SensorMeasurement,
    confidence::Float64
)

    gain =
        clamp(
            confidence,
            0.1,
            0.9
        )

    track.x =
        (1.0 - gain) *
        track.x +
        gain *
        measurement.x

    track.y =
        (1.0 - gain) *
        track.y +
        gain *
        measurement.y

    track.vx =
        (1.0 - gain) *
        track.vx +
        gain *
        measurement.vx

    track.vy =
        (1.0 - gain) *
        track.vy +
        gain *
        measurement.vy

    track.confidence =
        0.8 *
        track.confidence +
        0.2 *
        confidence

    track.missed_frames = 0

    track.last_update =
        measurement.timestamp

end


# ============================================================
# OBJECT ASSOCIATION
# ============================================================

function associate_measurements(
    tracks::Vector{ObjectTrack},
    measurements::Vector{SensorMeasurement},
    association_distance::Float64
)

    associations =
        Vector{Tuple{Int,Int}}()

    for (mi, m) in enumerate(measurements)

        best_track = 0
        best_distance = Inf

        for (ti, t) in enumerate(tracks)

            distance =
                sqrt(
                    (m.x - t.x)^2 +
                    (m.y - t.y)^2
                )

            if distance <
               best_distance &&
               distance <
               association_distance

                best_distance =
                    distance

                best_track =
                    ti
            end
        end

        if best_track > 0

            push!(
                associations,
                (best_track, mi)
            )

        end

    end

    return associations

end


# ============================================================
# SENSOR ENVIRONMENT MODEL
# ============================================================

struct EnvironmentState

    rain::Float64
    fog::Float64
    darkness::Float64
    snow::Float64

    road_spray::Float64
    dust::Float64

    tunnel::Bool
    urban_canyon::Bool
end


# ============================================================
# ENVIRONMENT-DEPENDENT SENSOR PERFORMANCE
# ============================================================

function environment_factor(
    sensor::SensorType,
    env::EnvironmentState
)

    factor = 1.0

    if sensor == CAMERA

        factor *=
            1.0 -
            0.65 * env.fog

        factor *=
            1.0 -
            0.40 * env.rain

        factor *=
            1.0 -
            0.55 * env.darkness

        factor *=
            1.0 -
            0.30 * env.snow

    elseif sensor == LIDAR

        factor *=
            1.0 -
            0.55 * env.fog

        factor *=
            1.0 -
            0.35 * env.rain

        factor *=
            1.0 -
            0.45 * env.road_spray

        factor *=
            1.0 -
            0.25 * env.dust

    elseif sensor == RADAR

        factor *=
            1.0 -
            0.12 * env.rain

        factor *=
            1.0 -
            0.08 * env.snow

    elseif sensor == GNSS

        if env.urban_canyon
            factor *= 0.55
        end

        if env.tunnel
            factor *= 0.05
        end

    elseif sensor == ULTRASONIC

        factor *=
            1.0 -
            0.40 * env.road_spray

        factor *=
            1.0 -
            0.30 * env.snow

    end

    return clamp(
        factor,
        0.0,
        1.0
    )

end


# ============================================================
# ADAPTIVE SENSOR MANAGER
# ============================================================

function optimise_sensor_weights!(
    healths::Vector{SensorHealth},
    env::EnvironmentState,
    cfg::SensorConfig
)

    for h in healths

        environmental =
            environment_factor(
                h.sensor,
                env
            )

        h.confidence =
            baseline_confidence(
                h.sensor
            ) *
            environmental

        calculate_sensor_health!(
            h,
            cfg
        )
    end

    return healths

end


# ============================================================
# SENSOR FAILURE DETECTION
# ============================================================

function detect_sensor_failures(
    healths::Vector{SensorHealth}
)

    failed =
        SensorType[]

    for h in healths

        if h.health_score < 0.25

            push!(
                failed,
                h.sensor
            )

        end

    end

    return failed

end


# ============================================================
# REDUNDANCY SCORE
# ============================================================

function calculate_redundancy(
    healths::Vector{SensorHealth}
)

    healthy =
        count(
            h -> h.health_score > 0.60,
            healths
        )

    return clamp(
        healthy / 5.0,
        0.0,
        1.0
    )

end


# ============================================================
# COMPLETE SENSOR OPTIMISER
# ============================================================

function optimise_sensor_system!(
    state::VehicleState,
    measurements::Vector{SensorMeasurement},
    healths::Vector{SensorHealth},
    environment::EnvironmentState,
    cfg::SensorConfig
)

    # --------------------------------------------------------
    # 1. Evaluate sensor environment
    # --------------------------------------------------------

    optimise_sensor_weights!(
        healths,
        environment,
        cfg
    )

    # --------------------------------------------------------
    # 2. Remove unusable sensors
    # --------------------------------------------------------

    failed =
        detect_sensor_failures(
            healths
        )

    # --------------------------------------------------------
    # 3. Predict vehicle state
    # --------------------------------------------------------

    predict_vehicle_state!(
        state,
        cfg.fusion_dt
    )

    # --------------------------------------------------------
    # 4. Fuse measurements
    # --------------------------------------------------------

    update_vehicle_state!(
        state,
        measurements,
        healths,
        cfg
    )

    # --------------------------------------------------------
    # 5. Calculate system redundancy
    # --------------------------------------------------------

    redundancy =
        calculate_redundancy(
            healths
        )

    return (
        state,
        failed,
        redundancy
    )

end


# ============================================================
# EXAMPLE SYSTEM
# ============================================================

cfg =
    create_sensor_config()


healths = [

    SensorHealth(
        CAMERA,
        0.90,
        25.0,
        0.01,
        0.10,
        35.0,
        0.05,
        0.02,
        0.0,
        true
    ),

    SensorHealth(
        RADAR,
        0.95,
        15.0,
        0.005,
        0.05,
        35.0,
        0.01,
        0.01,
        0.0,
        true
    ),

    SensorHealth(
        LIDAR,
        0.94,
        20.0,
        0.01,
        0.04,
        35.0,
        0.02,
        0.01,
        0.0,
        true
    ),

    SensorHealth(
        GNSS,
        0.92,
        40.0,
        0.02,
        0.05,
        35.0,
        0.0,
        0.02,
        0.0,
        true
    ),

    SensorHealth(
        IMU,
        0.98,
        5.0,
        0.001,
        0.02,
        35.0,
        0.0,
        0.005,
        0.0,
        true
    ),

    SensorHealth(
        WHEEL_SPEED,
        0.99,
        4.0,
        0.001,
        0.01,
        35.0,
        0.0,
        0.005,
        0.0,
        true
    )
]


environment =
    EnvironmentState(
        0.25,     # rain
        0.10,     # fog
        0.15,     # darkness
        0.0,      # snow

        0.20,     # road spray
        0.0,      # dust

        false,    # tunnel
        false     # urban canyon
    )


measurements = [

    SensorMeasurement(
        CAMERA,
        48.2, 1.1, 0.0,
        19.8, 0.2,
        0.00,
        0.10,
        0.88,
        true
    ),

    SensorMeasurement(
        RADAR,
        47.8, 1.0, 0.0,
        19.5, 0.1,
        0.01,
        0.05,
        0.93,
        true
    ),

    SensorMeasurement(
        LIDAR,
        48.0, 1.05, 0.0,
        19.7, 0.15,
        0.015,
        0.04,
        0.96,
        true
    )
]


state =
    VehicleState(
        0.0,
        0.0,
        0.0,

        20.0,
        0.0,
        0.0,

        0.0,
        0.0,

        0.0,
        0.0,

        0.0,

        20.0,

        0.0
    )


println()
println("==============================================")
println(" AUREOM SENSOR OPTIMISATION ENGINE")
println("==============================================")


for step in 1:100

    result =
        optimise_sensor_system!(
            state,
            measurements,
            healths,
            environment,
            cfg
        )

    fused_state =
        result[1]

    failed =
        result[2]

    redundancy =
        result[3]

    if step % 10 == 0

        println()
        println(
            "Cycle: ",
            step
        )

        println(
            "Position: ",
            round(fused_state.x, digits=2),
            " / ",
            round(fused_state.y, digits=2)
        )

        println(
            "Velocity: ",
            round(fused_state.speed, digits=2),
            " m/s"
        )

        println(
            "Sensor redundancy: ",
            round(
                redundancy * 100,
                digits=1
            ),
            "%"
        )

        println(
            "Failed sensors: ",
            failed
        )

        println("Sensor health:")

        for h in healths

            println(
                "  ",
                h.sensor,
                " = ",
                round(
                    h.health_score * 100,
                    digits=1
                ),
                "%"
            )

        end
    end

end

