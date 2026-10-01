using LinearAlgebra

# ============================================================
# Intelligent Steering Controller
# Research / simulation prototype
# ============================================================

struct SteeringConfig
    wheelbase::Float64
    steering_ratio::Float64

    max_wheel_angle::Float64
    max_wheel_rate::Float64

    max_assist_torque::Float64
    max_driver_torque::Float64

    target_yaw_gain::Float64
    stability_gain::Float64
    return_gain::Float64

    dt::Float64
end


struct VehicleState
    speed::Float64
    yaw_rate::Float64
    lateral_accel::Float64
    wheel_angle::Float64
    wheel_angle_rate::Float64
    steering_wheel_angle::Float64
    steering_torque::Float64
end


struct SteeringCommand
    target_wheel_angle::Float64
    assist_torque::Float64
    steering_ratio::Float64
end


# ------------------------------------------------------------
# Utility
# ------------------------------------------------------------

clamp_value(x, lo, hi) = clamp(x, lo, hi)


# ------------------------------------------------------------
# Speed-dependent steering ratio
# ------------------------------------------------------------

function steering_ratio(cfg::SteeringConfig, speed)

    v = abs(speed)

    # More direct at low speed,
    # more stable / progressive at high speed.

    low_speed_ratio  = 12.0
    high_speed_ratio = 18.0

    α = clamp(v / 35.0, 0.0, 1.0)

    return low_speed_ratio +
           α * (high_speed_ratio - low_speed_ratio)
end


# ------------------------------------------------------------
# Bicycle-model desired steering angle
# ------------------------------------------------------------

function curvature_to_wheel_angle(
    curvature,
    speed,
    cfg::SteeringConfig
)

    δ = atan(cfg.wheelbase * curvature)

    return clamp(
        δ,
        -cfg.max_wheel_angle,
         cfg.max_wheel_angle
    )
end


# ------------------------------------------------------------
# Desired yaw rate
# ------------------------------------------------------------

function desired_yaw_rate(
    curvature,
    speed
)

    return speed * curvature
end


# ------------------------------------------------------------
# Steering stability correction
# ------------------------------------------------------------

function stability_correction(
    state::VehicleState,
    desired_yaw,
    cfg::SteeringConfig
)

    yaw_error =
        desired_yaw - state.yaw_rate

    correction =
        cfg.target_yaw_gain * yaw_error

    # Dampen excessive lateral response.

    stability =
        -cfg.stability_gain *
        state.lateral_accel

    return correction + stability
end


# ------------------------------------------------------------
# Return-to-centre behaviour
# ------------------------------------------------------------

function return_to_centre(
    state::VehicleState,
    cfg::SteeringConfig
)

    # Steering wheel naturally wants to return
    # toward centre when driver torque is low.

    driver_present =
        abs(state.steering_torque) >
        0.5

    if driver_present
        return 0.0
    end

    return -cfg.return_gain *
           state.steering_wheel_angle
end


# ------------------------------------------------------------
# Steering torque optimiser
# ------------------------------------------------------------

function optimise_steering(
    state::VehicleState,
    curvature,
    cfg::SteeringConfig
)

    ratio =
        steering_ratio(cfg, state.speed)

    desired_yaw =
        desired_yaw_rate(
            curvature,
            state.speed
        )

    base_angle =
        curvature_to_wheel_angle(
            curvature,
            state.speed,
            cfg
        )

    stability =
        stability_correction(
            state,
            desired_yaw,
            cfg
        )

    # Convert yaw correction into
    # an additional steering angle.

    desired_angle =
        base_angle + stability

    desired_angle =
        clamp(
            desired_angle,
            -cfg.max_wheel_angle,
             cfg.max_wheel_angle
        )

    angle_error =
        desired_angle -
        state.wheel_angle

    # Steering rate limiter.

    desired_rate =
        clamp(
            angle_error / cfg.dt,
            -cfg.max_wheel_rate,
             cfg.max_wheel_rate
        )

    target_angle =
        state.wheel_angle +
        desired_rate * cfg.dt

    # Driver-centred torque assistance.

    assistance =
        2.0 * angle_error -
        0.25 * state.wheel_angle_rate

    assistance +=
        return_to_centre(
            state,
            cfg
        )

    assistance =
        clamp(
            assistance,
            -cfg.max_assist_torque,
             cfg.max_assist_torque
        )

    return SteeringCommand(
        target_angle,
        assistance,
        ratio
    )
end












cfg = SteeringConfig(
    2.85,   # wheelbase
    15.0,   # nominal steering ratio

    deg2rad(35.0),   # max road-wheel angle
    deg2rad(180.0),  # max wheel angle rate

    6.0,    # maximum EPS assist torque
    10.0,   # maximum driver torque

    0.35,   # yaw tracking
    0.015,  # stability
    0.8,    # return-to-centre

    0.01    # 100 Hz controller
)


state = VehicleState(
    25.0,       # speed m/s
    0.15,       # yaw rate
    1.5,        # lateral acceleration
    0.08,       # wheel angle
    0.02,       # wheel angle rate
    0.7,        # steering wheel angle
    0.2         # driver torque
)


curvature = 0.012

command =
    optimise_steering(
        state,
        curvature,
        cfg
    )

println("Target wheel angle: ",
        rad2deg(command.target_wheel_angle), "°")

println("Assist torque: ",
        command.assist_torque, " Nm")

println("Dynamic steering ratio: ",
        command.steering_ratio)
