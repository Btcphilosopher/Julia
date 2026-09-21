module ShinkansenAccelerationML

using LinearAlgebra
using Statistics
using Random

# ============================================================
# TRAIN MODEL
# ============================================================

struct Train
    mass_kg::Float64
    max_traction_kw::Float64
    max_acceleration_ms2::Float64
    max_jerk_ms3::Float64

    rolling_coefficient::Float64
    aerodynamic_coefficient::Float64
    frontal_area_m2::Float64

    wheel_radius_m::Float64
end


struct Track
    gradient::Float64
    speed_limit_ms::Float64
    target_speed_ms::Float64
    target_distance_m::Float64
end


struct Environment
    air_density::Float64
    wind_ms::Float64
    ambient_temperature_c::Float64
    adhesion_factor::Float64
end


struct TrainState
    position_m::Float64
    speed_ms::Float64
    acceleration_ms2::Float64

    motor_temp_c::Float64
    inverter_temp_c::Float64

    energy_kwh::Float64
end


# ============================================================
# PHYSICS
# ============================================================

function rolling_force(
    train::Train
)

    return train.mass_kg *
           9.81 *
           train.rolling_coefficient

end


function aerodynamic_force(
    train::Train,
    state::TrainState,
    env::Environment
)

    relative_speed =
        state.speed_ms +
        env.wind_ms

    return 0.5 *
           env.air_density *
           train.aerodynamic_coefficient *
           train.frontal_area_m2 *
           relative_speed^2

end


function gradient_force(
    train::Train,
    track::Track
)

    return train.mass_kg *
           9.81 *
           track.gradient

end


function resistance_force(
    train::Train,
    track::Track,
    state::TrainState,
    env::Environment
)

    rolling_force(train) +
    aerodynamic_force(train, state, env) +
    gradient_force(train, track)

end


# ============================================================
# TRACTION EFFICIENCY
# ============================================================

function traction_efficiency(
    speed_ms::Float64,
    power_kw::Float64
)

    # Simplified efficiency curve.

    speed_factor =
        0.88 +
        0.06 *
        exp(
            -((speed_ms - 55.0)^2) /
            (2.0 * 25.0^2)
        )

    load_ratio =
        clamp(
            power_kw / 10000.0,
            0.0,
            1.0
        )

    load_factor =
        0.90 -
        0.08 *
        (load_ratio - 0.75)^2

    return clamp(
        speed_factor *
        load_factor,
        0.70,
        0.97
    )

end


# ============================================================
# TRACTION FORCE
# ============================================================

function traction_force(
    train::Train,
    power_kw::Float64,
    speed_ms::Float64
)

    if speed_ms < 0.5

        # Low-speed traction region.
        return (
            power_kw * 1000.0
        ) / 0.5

    end

    return (
        power_kw * 1000.0
    ) / speed_ms

end


# ============================================================
# PHYSICS ACCELERATION
# ============================================================

function physics_acceleration(
    train::Train,
    track::Track,
    state::TrainState,
    env::Environment,
    power_kw::Float64
)

    force =
        traction_force(
            train,
            power_kw,
            state.speed_ms
        )

    resistance =
        resistance_force(
            train,
            track,
            state,
            env
        )

    acceleration =
        (
            force -
            resistance
        ) /
        train.mass_kg

    return clamp(
        acceleration,
        -train.max_acceleration_ms2,
        train.max_acceleration_ms2
    )

end


# ============================================================
# ML ACCELERATION MODEL
# ============================================================

mutable struct AccelerationPredictor

    weights::Vector{Float64}

    bias::Float64

    learning_rate::Float64

    observations::Int

end


function AccelerationPredictor(
    feature_count::Int;
    learning_rate = 0.00005
)

    AccelerationPredictor(
        zeros(feature_count),
        0.0,
        learning_rate,
        0
    )

end


# ============================================================
# FEATURES
# ============================================================

function acceleration_features(
    state::TrainState,
    track::Track,
    env::Environment,
    power_kw::Float64
)

    [

        1.0,

        state.speed_ms,

        state.acceleration_ms2,

        power_kw,

        power_kw^2,

        track.gradient,

        env.wind_ms,

        env.ambient_temperature_c,

        state.motor_temp_c,

        state.inverter_temp_c,

        state.speed_ms^2,

        power_kw *
        state.speed_ms

    ]

end


# ============================================================
# ML PREDICTION
# ============================================================

function predict_acceleration(
    model::AccelerationPredictor,
    features::Vector{Float64}
)

    return dot(
        model.weights,
        features
    ) +
    model.bias

end


# ============================================================
# ONLINE LEARNING
# ============================================================

function update!(
    model::AccelerationPredictor,
    features::Vector{Float64},
    actual_acceleration::Float64
)

    prediction =
        predict_acceleration(
            model,
            features
        )

    error =
        prediction -
        actual_acceleration

    normalisation =
        dot(
            features,
            features
        ) + 1.0

    rate =
        model.learning_rate /
        normalisation

    model.weights .-=
        rate *
        error *
        features

    model.bias -=
        rate *
        error

    model.observations += 1

end


# ============================================================
# HYBRID PHYSICS + ML MODEL
# ============================================================

function hybrid_acceleration(
    train::Train,
    track::Track,
    state::TrainState,
    env::Environment,
    model::AccelerationPredictor,
    power_kw::Float64
)

    physics =
        physics_acceleration(
            train,
            track,
            state,
            env,
            power_kw
        )

    features =
        acceleration_features(
            state,
            track,
            env,
            power_kw
        )

    ml =
        predict_acceleration(
            model,
            features
        )

    # ML learns the residual between
    # idealised physics and actual train behaviour.

    prediction =
        physics +
        0.20 *
        ml

    return clamp(
        prediction,
        -train.max_acceleration_ms2,
        train.max_acceleration_ms2
    )

end


# ============================================================
# JERK LIMIT
# ============================================================

function apply_jerk_limit(
    previous_acceleration::Float64,
    requested_acceleration::Float64,
    max_jerk::Float64,
    dt::Float64
)

    maximum_change =
        max_jerk *
        dt

    change =
        requested_acceleration -
        previous_acceleration

    change =
        clamp(
            change,
            -maximum_change,
            maximum_change
        )

    return previous_acceleration +
           change

end


# ============================================================
# ENERGY
# ============================================================

function electrical_energy(
    power_kw::Float64,
    dt::Float64
)

    power_kw *
    dt /
    3600.0

end


# ============================================================
# STATE PROPAGATION
# ============================================================

function propagate(
    train::Train,
    track::Track,
    state::TrainState,
    env::Environment,
    model::AccelerationPredictor,
    power_kw::Float64,
    dt::Float64
)

    requested_acceleration =
        hybrid_acceleration(
            train,
            track,
            state,
            env,
            model,
            power_kw
        )

    acceleration =
        apply_jerk_limit(
            state.acceleration_ms2,
            requested_acceleration,
            train.max_jerk_ms3,
            dt
        )

    new_speed =
        max(
            state.speed_ms +
            acceleration * dt,
            0.0
        )

    new_position =
        state.position_m +
        state.speed_ms * dt +
        0.5 *
        acceleration *
        dt^2

    efficiency =
        traction_efficiency(
            state.speed_ms,
            power_kw
        )

    input_power =
        power_kw /
        efficiency

    energy =
        electrical_energy(
            input_power,
            dt
        )

    # Simplified thermal model.

    motor_heat =
        0.015 *
        power_kw *
        (1.0 - efficiency)

    motor_temp =
        state.motor_temp_c +
        motor_heat *
        dt -
        0.015 *
        (
            state.motor_temp_c -
            env.ambient_temperature_c
        ) *
        dt

    inverter_temp =
        state.inverter_temp_c +
        0.005 *
        power_kw *
        dt -
        0.02 *
        (
            state.inverter_temp_c -
            env.ambient_temperature_c
        ) *
        dt

    return TrainState(

        new_position,

        new_speed,

        acceleration,

        motor_temp,

        inverter_temp,

        state.energy_kwh +
        energy

    )

end


# ============================================================
# TRAJECTORY RESULT
# ============================================================

struct Trajectory

    states::Vector{TrainState}

    powers_kw::Vector{Float64}

end


# ============================================================
# SIMULATE ACCELERATION PROFILE
# ============================================================

function simulate_profile(
    train::Train,
    track::Track,
    initial::TrainState,
    env::Environment,
    model::AccelerationPredictor,
    power_fraction::Float64;

    dt = 1.0,
    horizon_s = 180.0
)

    state =
        initial

    states =
        TrainState[state]

    powers =
        Float64[]

    elapsed =
        0.0

    while elapsed <
          horizon_s

        # Stop accelerating once target
        # speed is reached.

        if state.speed_ms >=
           track.target_speed_ms

            power_kw = 0.0

        else

            power_kw =
                train.max_traction_kw *
                power_fraction

        end

        state =
            propagate(
                train,
                track,
                state,
                env,
                model,
                power_kw,
                dt
            )

        push!(
            states,
            state
        )

        push!(
            powers,
            power_kw
        )

        if state.position_m >=
           track.target_distance_m

            break

        end

        elapsed += dt

    end

    Trajectory(
        states,
        powers
    )

end


# ============================================================
# TRAJECTORY METRICS
# ============================================================

function trajectory_metrics(
    trajectory::Trajectory,
    track::Track
)

    final =
        trajectory.states[end]

    arrival_time =
        length(
            trajectory.states
        ) - 1

    energy =
        final.energy_kwh

    maximum_motor_temperature =
        maximum(
            x.motor_temp_c
            for x in trajectory.states
        )

    maximum_inverter_temperature =
        maximum(
            x.inverter_temp_c
            for x in trajectory.states
        )

    speed_error =
        abs(
            final.speed_ms -
            track.target_speed_ms
        )

    return (

        time = arrival_time,

        energy = energy,

        motor_temperature =
            maximum_motor_temperature,

        inverter_temperature =
            maximum_inverter_temperature,

        speed_error =
            speed_error

    )

end


# ============================================================
# ACCELERATION OBJECTIVE
# ============================================================

function acceleration_cost(
    metrics;
    time_weight = 1.0,
    energy_weight = 0.005,
    thermal_weight = 10.0
)

    time_cost =
        time_weight *
        metrics.time

    energy_cost =
        energy_weight *
        metrics.energy

    thermal_penalty =
        thermal_weight *
        max(
            metrics.motor_temperature -
            120.0,
            0.0
        )^2

    inverter_penalty =
        thermal_weight *
        max(
            metrics.inverter_temperature -
            95.0,
            0.0
        )^2

    speed_penalty =
        100.0 *
        metrics.speed_error

    return (
        time_cost +
        energy_cost +
        thermal_penalty +
        inverter_penalty +
        speed_penalty
    )

end


# ============================================================
# OPTIMISE ACCELERATION
# ============================================================

function optimise_acceleration(
    train::Train,
    track::Track,
    initial::TrainState,
    env::Environment,
    model::AccelerationPredictor
)

    best_fraction =
        0.0

    best_cost =
        Inf

    best_trajectory =
        nothing

    # Search traction levels.

    for fraction in
        range(
            0.20,
            1.00,
            length = 33
        )

        trajectory =
            simulate_profile(
                train,
                track,
                initial,
                env,
                model,
                fraction;
                dt = 1.0,
                horizon_s = 180.0
            )

        metrics =
            trajectory_metrics(
                trajectory,
                track
            )

        cost =
            acceleration_cost(
                metrics
            )

        if cost < best_cost

            best_cost =
                cost

            best_fraction =
                fraction

            best_trajectory =
                trajectory

        end

    end

    return (

        traction_fraction =
            best_fraction,

        cost =
            best_cost,

        trajectory =
            best_trajectory

    )

end


# ============================================================
# ADAPTIVE ML OPTIMISER
# ============================================================

mutable struct AccelerationController

    predictor::AccelerationPredictor

    last_power_fraction::Float64

end


function AccelerationController()

    AccelerationController(
        AccelerationPredictor(
            12
        ),
        0.5
    )

end


# ============================================================
# ONLINE CONTROL
# ============================================================

function control!(
    controller::AccelerationController,
    train::Train,
    track::Track,
    state::TrainState,
    env::Environment
)

    result =
        optimise_acceleration(
            train,
            track,
            state,
            env,
            controller.predictor
        )

    controller.last_power_fraction =
        result.traction_fraction

    return result

end


# ============================================================
# LEARN FROM REAL TRAIN DATA
# ============================================================

function learn_from_observation!(
    controller::AccelerationController,
    state::TrainState,
    track::Track,
    env::Environment,
    power_kw::Float64,
    measured_acceleration::Float64
)

    features =
        acceleration_features(
            state,
            track,
            env,
            power_kw
        )

    update!(
        controller.predictor,
        features,
        measured_acceleration
    )

end


# ============================================================
# REPORT
# ============================================================

function report(
    trajectory::Trajectory
)

    metrics =
        trajectory_metrics(
            trajectory,
            Track(
                0.0,
                100.0,
                trajectory.states[end].speed_ms,
                trajectory.states[end].position_m
            )
        )

    println()
    println(
        "======================================="
    )

    println(
        " SHINKANSEN ACCELERATION ML"
    )

    println(
        "======================================="
    )

    println(
        "Distance: ",
        round(
            trajectory.states[end].position_m,
            digits = 1
        ),
        " m"
    )

    println(
        "Final speed: ",
        round(
            trajectory.states[end].speed_ms,
            digits = 2
        ),
        " m/s"
    )

    println(
        "Energy: ",
        round(
            trajectory.states[end].energy_kwh,
            digits = 2
        ),
        " kWh"
    )

    println(
        "Peak motor temperature: ",
        round(
            metrics.motor_temperature,
            digits = 2
        ),
        " °C"
    )

    println(
        "Peak inverter temperature: ",
        round(
            metrics.inverter_temperature,
            digits = 2
        ),
        " °C"
    )

    println(
        "======================================="
    )

end


end




using .ShinkansenAccelerationML

train =
    Train(
        450_000.0,   # mass
        12_000.0,    # maximum traction power
        1.0,         # maximum acceleration
        0.15,        # jerk limit

        0.0015,
        0.002,
        10.0,

        0.45
    )


track =
    Track(
        0.0,
        83.3,       # ~300 km/h
        83.3,
        20_000.0
    )


environment =
    Environment(
        1.225,
        2.0,
        25.0,
        0.95
    )


state =
    TrainState(
        0.0,
        0.0,
        0.0,

        35.0,
        30.0,

        0.0
    )


controller =
    AccelerationController()


result =
    control!(
        controller,
        train,
        track,
        state,
        environment
    )


println(
    "Optimal traction fraction = ",
    result.traction_fraction
)

println(
    "Optimisation cost = ",
    result.cost
)

report(
    result.trajectory
)

