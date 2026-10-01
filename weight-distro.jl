using LinearAlgebra
using Random

# ============================================================
# Intelligent Vehicle Weight Distribution Estimator
# Julia ML research prototype
# ============================================================

struct Vehicle
    mass::Float64
    wheelbase::Float64
    track_front::Float64
    track_rear::Float64
    cg_height::Float64
    cg_longitudinal::Float64
end


struct VehicleObservation
    longitudinal_accel::Float64
    lateral_accel::Float64
    yaw_rate::Float64

    suspension_fl::Float64
    suspension_fr::Float64
    suspension_rl::Float64
    suspension_rr::Float64

    wheel_speed_fl::Float64
    wheel_speed_fr::Float64
    wheel_speed_rl::Float64
    wheel_speed_rr::Float64
end


struct WheelLoads
    fl::Float64
    fr::Float64
    rl::Float64
    rr::Float64
end


# ============================================================
# Static weight distribution
# ============================================================

function static_loads(car::Vehicle)

    g = 9.81

    total_weight =
        car.mass * g

    front_fraction =
        (car.wheelbase - car.cg_longitudinal) /
        car.wheelbase

    front_load =
        total_weight * front_fraction

    rear_load =
        total_weight - front_load

    return WheelLoads(
        front_load / 2,
        front_load / 2,
        rear_load / 2,
        rear_load / 2
    )
end


# ============================================================
# Physics-based load transfer
# ============================================================

function physics_load_estimate(
    car::Vehicle,
    obs::VehicleObservation
)

    g = 9.81

    static = static_loads(car)

    # Longitudinal load transfer
    longitudinal_transfer =
        car.mass *
        obs.longitudinal_accel *
        car.cg_height /
        car.wheelbase

    # Lateral load transfer
    lateral_transfer_front =
        car.mass *
        obs.lateral_accel *
        car.cg_height /
        car.track_front

    lateral_transfer_rear =
        car.mass *
        obs.lateral_accel *
        car.cg_height /
        car.track_rear

    # Front/rear transfer
    fl = static.fl -
         longitudinal_transfer / 2 -
         lateral_transfer_front / 2

    fr = static.fr -
         longitudinal_transfer / 2 +
         lateral_transfer_front / 2

    rl = static.rl +
         longitudinal_transfer / 2 -
         lateral_transfer_rear / 2

    rr = static.rr +
         longitudinal_transfer / 2 +
         lateral_transfer_rear / 2

    return WheelLoads(
        max(fl, 0.0),
        max(fr, 0.0),
        max(rl, 0.0),
        max(rr, 0.0)
    )
end




# ============================================================
# Simple online linear ML model
# ============================================================

mutable struct LoadMLModel
    weights::Matrix{Float64}
    bias::Vector{Float64}
    learning_rate::Float64
end


function create_model(
    input_size::Int,
    output_size::Int
)

    LoadMLModel(
        0.01 .* randn(output_size, input_size),
        zeros(output_size),
        0.001
    )
end


# ------------------------------------------------------------
# Feature vector
# ------------------------------------------------------------

function features(obs::VehicleObservation)

    return [
        1.0,

        obs.longitudinal_accel,
        obs.lateral_accel,
        obs.yaw_rate,

        obs.suspension_fl,
        obs.suspension_fr,
        obs.suspension_rl,
        obs.suspension_rr,

        obs.wheel_speed_fl,
        obs.wheel_speed_fr,
        obs.wheel_speed_rl,
        obs.wheel_speed_rr,

        obs.longitudinal_accel^2,
        obs.lateral_accel^2,
        obs.longitudinal_accel *
        obs.lateral_accel
    ]
end


# ------------------------------------------------------------
# Prediction
# ------------------------------------------------------------

function predict(
    model::LoadMLModel,
    x
)

    model.weights * x[2:end] +
    model.bias
end


# ------------------------------------------------------------
# Online learning
# ------------------------------------------------------------

function train_step!(
    model::LoadMLModel,
    x,
    target
)

    prediction =
        predict(model, x)

    error =
        prediction - target

    model.weights .-=
        model.learning_rate *
        (error * x[2:end]')

    model.bias .-=
        model.learning_rate *
        error

    return error
end




function normalise_loads(
    loads::WheelLoads,
    total_mass
)

    total =
        loads.fl +
        loads.fr +
        loads.rl +
        loads.rr

    target =
        total_mass * 9.81

    scale =
        target / max(total, 1e-6)

    return WheelLoads(
        loads.fl * scale,
        loads.fr * scale,
        loads.rl * scale,
        loads.rr * scale
    )
end

This is important because otherwise an unconstrained ML model could theoretically predict:

FL = 4,200 N
FR = 3,900 N
RL = 2,100 N
RR = 2,300 N

when the actual vehicle weighs only 10,000 N.

The model therefore learns distribution, while physics enforces conservation.

Then make it predictive

This is where I'd make the Aureom-style system much more interesting.

Instead of asking:

What is the weight distribution now?

we ask:

What will the weight distribution be 0.5–2 seconds from now?

Inputs:

struct DrivingPredictionInput

    speed
    acceleration
    steering_angle
    steering_rate

    yaw_rate
    lateral_acceleration

    braking_pressure
    throttle_position

    road_gradient
    road_curvature

    battery_mass
    cargo_mass

end

The model could predict:

t + 0.1 s
t + 0.2 s
t + 0.5 s
t + 1.0 s
t + 2.0 s

giving something like:

             FRONT        REAR

CURRENT      53.1%       46.9%

+0.1 sec     55.8%       44.2%
+0.2 sec     57.4%       42.6%
+0.5 sec     59.0%       41.0%
+1.0 sec     58.1%       41.9%

That prediction can then be passed into the braking, acceleration, steering and suspension optimisers we've been building.


