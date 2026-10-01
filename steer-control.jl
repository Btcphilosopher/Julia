Predictive Corner Executor — Julia
using LinearAlgebra

# ============================================================
# PREDICTIVE CORNER EXECUTOR
#
# Research / simulation controller.
#
# Pipeline:
#
# Road preview
#      ↓
# Corner detection
#      ↓
# Curvature / radius estimation
#      ↓
# Corner classification
#      ↓
# Target speed
#      ↓
# Steering prediction
#      ↓
# Corner execution
#      ↓
# Steering unwind / exit
# ============================================================


# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

struct CornerConfig

    # Vehicle
    wheelbase::Float64
    mass::Float64

    # Steering
    max_steering_angle::Float64
    max_steering_rate::Float64

    # Tyre / handling
    max_lateral_accel::Float64
    safety_factor::Float64

    # Preview
    preview_distance::Float64

    # Control
    steering_gain::Float64
    curvature_gain::Float64
    yaw_gain::Float64

    # Cornering
    entry_margin::Float64
    exit_margin::Float64

    dt::Float64
end


# ------------------------------------------------------------
# Vehicle state
# ------------------------------------------------------------

struct VehicleState

    speed::Float64

    steering_angle::Float64
    steering_rate::Float64

    yaw_rate::Float64

    lateral_accel::Float64

    lateral_error::Float64
    heading_error::Float64
end


# ------------------------------------------------------------
# Road preview
# curvature = 1 / radius
# ------------------------------------------------------------

struct RoadPreview

    distance::Vector{Float64}
    curvature::Vector{Float64}
end


# ------------------------------------------------------------
# Output command
# ------------------------------------------------------------

struct CornerCommand

    target_speed::Float64
    steering_angle::Float64

    corner_detected::Bool

    corner_radius::Float64
    corner_severity::Float64

    phase::Symbol
end


# ------------------------------------------------------------
# Utility
# ------------------------------------------------------------

function clamp_value(x, lo, hi)

    return max(lo, min(hi, x))

end


# ------------------------------------------------------------
# Estimate corner radius
# ------------------------------------------------------------

function estimate_corner_radius(preview::RoadPreview)

    nonzero = abs.(preview.curvature)

    valid = nonzero .> 1e-5

    if !any(valid)
        return Inf
    end

    # Use strongest upcoming curvature.
    κ = maximum(nonzero[valid])

    return 1.0 / κ
end


# ------------------------------------------------------------
# Detect corner
# ------------------------------------------------------------

function detect_corner(preview::RoadPreview)

    κ = abs.(preview.curvature)

    # Ignore essentially straight road.
    if maximum(κ) < 1e-4
        return false
    end

    return true
end


# ------------------------------------------------------------
# Corner severity
#
# Higher curvature = tighter corner.
# ------------------------------------------------------------

function corner_severity(preview::RoadPreview)

    κmax = maximum(abs.(preview.curvature))

    # Approximate severity scale.
    severity =
        clamp_value(
            κmax / 0.04,
            0.0,
            1.0
        )

    return severity
end


# ------------------------------------------------------------
# Calculate safe corner speed
#
# a_lat = v² / R
#
# therefore:
#
# v = sqrt(a_lat / curvature)
# ------------------------------------------------------------

function corner_speed(cfg::CornerConfig,
                      curvature::Float64)

    if abs(curvature) < 1e-6
        return Inf
    end

    allowed_accel =
        cfg.max_lateral_accel *
        cfg.safety_factor

    speed =
        sqrt(
            allowed_accel /
            abs(curvature)
        )

    return speed
end


# ------------------------------------------------------------
# Predict entry speed
# ------------------------------------------------------------

function target_corner_speed(cfg::CornerConfig,
                             state::VehicleState,
                             preview::RoadPreview)

    κ = maximum(abs.(preview.curvature))

    limit =
        corner_speed(cfg, κ)

    # Give the controller a small entry margin.
    target =
        limit -
        cfg.entry_margin

    return max(target, 5.0)
end


# ------------------------------------------------------------
# Feed-forward steering
#
# Bicycle model:
#
# δ ≈ atan(L * κ)
# ------------------------------------------------------------

function curvature_steering(cfg::CornerConfig,
                            curvature::Float64)

    δ =
        atan(
            cfg.wheelbase *
            curvature
        )

    return clamp_value(
        δ,
        -cfg.max_steering_angle,
        cfg.max_steering_angle
    )
end


# ------------------------------------------------------------
# Predictive steering correction
# ------------------------------------------------------------

function steering_prediction(cfg::CornerConfig,
                             state::VehicleState,
                             preview::RoadPreview)

    # Strongest upcoming curvature
    κ =
        preview.curvature[argmax(
            abs.(preview.curvature)
        )]

    # Feed-forward component.
    feedforward =
        curvature_steering(
            cfg,
            κ
        )

    # Lateral tracking correction.
    lateral =
        -cfg.steering_gain *
        state.lateral_error

    # Heading correction.
    heading =
        -cfg.yaw_gain *
        state.heading_error

    # Existing yaw response.
    yaw =
        -cfg.curvature_gain *
        state.yaw_rate

    target =
        feedforward +
        lateral +
        heading +
        yaw

    return clamp_value(
        target,
        -cfg.max_steering_angle,
        cfg.max_steering_angle
    )
end


# ------------------------------------------------------------
# Steering rate limiter
# ------------------------------------------------------------

function rate_limit_steering(cfg::CornerConfig,
                             current,
                             target)

    maximum_change =
        cfg.max_steering_rate *
        cfg.dt

    difference =
        target - current

    difference =
        clamp_value(
            difference,
            -maximum_change,
            maximum_change
        )

    return current + difference
end


# ------------------------------------------------------------
# Determine corner phase
# ------------------------------------------------------------

function corner_phase(preview::RoadPreview)

    κ = abs.(preview.curvature)

    n = length(κ)

    if n < 3
        return :entry
    end

    first_half =
        mean(
            κ[1:div(n,2)]
        )

    second_half =
        mean(
            κ[div(n,2)+1:end]
        )

    peak_index =
        argmax(κ)

    if peak_index <= div(n,3)

        return :entry

    elseif peak_index >= 2*div(n,3)

        return :exit

    elseif second_half > first_half * 0.9

        return :apex

    else

        return :exit

    end
end


# ------------------------------------------------------------
# Main corner executor
# ------------------------------------------------------------

function execute_corner(cfg::CornerConfig,
                        state::VehicleState,
                        preview::RoadPreview)

    detected =
        detect_corner(preview)

    if !detected

        return CornerCommand(
            Inf,
            0.0,
            false,
            Inf,
            0.0,
            :straight
        )
    end

    radius =
        estimate_corner_radius(
            preview
        )

    severity =
        corner_severity(
            preview
        )

    target_speed =
        target_corner_speed(
            cfg,
            state,
            preview
        )

    desired_steering =
        steering_prediction(
            cfg,
            state,
            preview
        )

    steering =
        rate_limit_steering(
            cfg,
            state.steering_angle,
            desired_steering
        )

    phase =
        corner_phase(preview)

    # During exit, progressively unwind steering.
    if phase == :exit

        steering *=
            0.75

    end

    return CornerCommand(
        target_speed,
        steering,
        true,
        radius,
        severity,
        phase
    )
end
Example: approaching a right-hand corner
cfg = CornerConfig(

    2.85,       # wheelbase
    1850.0,     # mass

    deg2rad(32),
    deg2rad(90),

    8.0,        # maximum lateral acceleration
    0.80,       # safety factor

    100.0,      # preview distance

    0.25,
    0.15,
    0.20,

    2.0,
    1.0,

    0.02
)


state = VehicleState(

    27.0,       # 97 km/h

    0.0,        # steering
    0.0,

    0.0,        # yaw rate

    0.0,

    0.0,        # lateral error
    0.0         # heading error
)


road = RoadPreview(

    [0, 20, 40, 60, 80, 100],

    [
        0.000,
        0.003,
        0.008,
        0.015,
        0.020,
        0.010
    ]
)


command =
    execute_corner(
        cfg,
        state,
        road
    )


println("Corner detected: ",
        command.corner_detected)

println("Radius: ",
        command.corner_radius,
        " m")

println("Severity: ",
        command.corner_severity)

println("Phase: ",
        command.phase)

println("Target speed: ",
        command.target_speed,
        " m/s")

println("Steering: ",
        rad2deg(command.steering_angle),
        " degrees")
But I would take this considerably further

The really interesting part is to make the vehicle plan the entire corner as a trajectory, rather than simply calculate steering from instantaneous curvature.

The architecture becomes:

             CAMERA / MAP / LIDAR
                     │
                     ▼
              ROAD GEOMETRY
                     │
          ┌──────────┴──────────┐
          │                     │
     curvature κ(s)       curvature rate
          │                     │
          └──────────┬──────────┘
                     ▼
             CORNER PREDICTOR
                     │
        ┌────────────┼────────────┐
        ▼            ▼            ▼
      ENTRY         APEX         EXIT
        │            │            │
        ▼            ▼            ▼
   target speed   target speed  unwind
        │            │            │
        └────────────┼────────────┘
                     ▼
                MPC / OPTIMISER
                     │
          ┌──────────┴──────────┐
          ▼                     ▼
       STEERING              BRAKING
          │                     │
          ▼                     ▼
         EPS                 BRAKES

This is essentially the distinction between a reactive steering system and a preview controller: road curvature ahead becomes a measured disturbance/reference across the prediction horizon.

The next-generation version

I would give your car a Corner Intent Model:

struct CornerPrediction

    entry_distance::Float64
    apex_distance::Float64
    exit_distance::Float64

    entry_speed::Float64
    apex_speed::Float64
    exit_speed::Float64

    radius::Float64
    curvature::Float64

    steering_entry::Float64
    steering_apex::Float64
    steering_exit::Float64

    braking_required::Float64
end

Then it can produce something like:

CORNER PREDICTION

Distance:             94 m
Direction:            RIGHT
Radius:              118 m
Severity:            MEDIUM

ENTRY
  Speed:              108 km/h
  Steering:            +7.1°

APEX
  Distance:             47 m
  Speed:               86 km/h
  Steering:            +9.8°

EXIT
  Speed:               93 km/h
  Steering:             +4.2°

ACTION
  Lift throttle
  Progressive steering
  Hold apex
  Begin steering unwind
  Accelerate on exit
  
