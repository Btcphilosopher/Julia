#!/usr/bin/env julia

# ============================================================
# SHINKANSEN BATTERY ENERGY OPTIMISER
#
# Supervisory energy-management prototype
#
# Optimises:
#   - Battery SOC
#   - Regenerative braking capture
#   - Charging/discharging power
#   - Auxiliary electrical loads
#   - Energy reserves
#
# This is a simulation/optimisation layer, NOT a direct
# safety controller for a railway vehicle.
# ============================================================

using Printf
using Statistics

# ------------------------------------------------------------
# Battery model
# ------------------------------------------------------------

struct Battery

    capacity_kwh::Float64

    soc_min::Float64
    soc_max::Float64

    max_charge_kw::Float64
    max_discharge_kw::Float64

    charge_efficiency::Float64
    discharge_efficiency::Float64
end


# Example parameters for simulation only.
battery = Battery(
    1200.0,     # capacity kWh

    0.15,       # minimum SOC
    0.90,       # maximum SOC

    6000.0,     # maximum charging power
    6000.0,     # maximum discharge power

    0.94,       # charging efficiency
    0.95        # discharge efficiency
)


# ------------------------------------------------------------
# Train operating state
# ------------------------------------------------------------

struct TrainState

    speed_kmh::Float64
    gradient::Float64
    traction_kw::Float64
    auxiliary_kw::Float64

    regenerative_available_kw::Float64
end


# ------------------------------------------------------------
# Energy state
# ------------------------------------------------------------

mutable struct EnergyState

    soc::Float64
    battery_temperature::Float64

    total_charge_kwh::Float64
    total_discharge_kwh::Float64
    regenerative_captured_kwh::Float64

end


# ------------------------------------------------------------
# SOC calculations
# ------------------------------------------------------------

function available_energy(
    battery::Battery,
    state::EnergyState
)

    return (
        state.soc *
        battery.capacity_kwh
    )
end


function available_charge_space(
    battery::Battery,
    state::EnergyState
)

    return (
        battery.soc_max -
        state.soc
    ) * battery.capacity_kwh
end


# ------------------------------------------------------------
# Regenerative braking optimisation
# ------------------------------------------------------------

function optimise_regeneration(
    battery::Battery,
    state::EnergyState,
    train::TrainState,
    timestep_hours::Float64
)

    available =
        train.regenerative_available_kw

    if available <= 0
        return 0.0
    end

    # Remaining battery capacity.
    space =
        available_charge_space(
            battery,
            state
        )

    # Maximum energy that can physically be absorbed.
    max_energy =
        min(
            available *
            timestep_hours,

            space
        )

    if max_energy <= 0
        return 0.0
    end

    # Convert back into charging power.
    requested =
        max_energy /
        timestep_hours

    return min(
        requested,
        battery.max_charge_kw
    )
end


# ------------------------------------------------------------
# Traction energy optimisation
# ------------------------------------------------------------

function optimise_discharge(
    battery::Battery,
    state::EnergyState,
    train::TrainState
)

    required =
        max(
            train.traction_kw,
            0.0
        )

    available =
        available_energy(
            battery,
            state
        )

    minimum_energy =
        battery.soc_min *
        battery.capacity_kwh

    usable =
        max(
            available -
            minimum_energy,
            0.0
        )

    maximum_power =
        min(
            battery.max_discharge_kw,
            usable
        )

    return min(
        required,
        maximum_power
    )
end


# ------------------------------------------------------------
# Auxiliary load optimisation
# ------------------------------------------------------------

function optimise_auxiliary_load(
    base_load::Float64,
    passenger_load::Float64,
    ambient_temperature::Float64
)

    # Base systems:
    # lighting, control electronics, communications, etc.

    load =
        base_load +
        passenger_load

    # HVAC becomes a larger load at temperature extremes.

    if ambient_temperature < 5

        load *= 1.20

    elseif ambient_temperature > 28

        load *= 1.25

    end

    return load
end


# ------------------------------------------------------------
# Battery thermal model
# ------------------------------------------------------------

function update_temperature(
    temperature,
    charge_kw,
    discharge_kw,
    timestep
)

    current_power =
        charge_kw +
        discharge_kw

    # Simplified heat-generation model.
    heat =
        0.000015 *
        current_power^2 *
        timestep

    # Passive cooling.
    cooling =
        0.02 *
        (temperature - 25.0) *
        timestep

    return temperature +
           heat -
           cooling
end


# ------------------------------------------------------------
# Battery degradation penalty
# ------------------------------------------------------------

function degradation_penalty(
    battery::Battery,
    state::EnergyState,
    charge_kw,
    discharge_kw
)

    soc_stress =
        abs(
            state.soc - 0.55
        )

    power_stress =
        (
            charge_kw +
            discharge_kw
        ) /
        (
            battery.max_charge_kw +
            battery.max_discharge_kw
        )

    thermal_stress =
        max(
            state.battery_temperature - 30,
            0
        ) / 30

    return (
        0.40 * soc_stress +
        0.35 * power_stress +
        0.25 * thermal_stress
    )
end


# ------------------------------------------------------------
# Single simulation step
# ------------------------------------------------------------

function energy_step!(
    battery::Battery,
    state::EnergyState,
    train::TrainState,
    timestep_hours::Float64
)

    # ----------------------------------------
    # Regenerative braking
    # ----------------------------------------

    charge_kw =
        optimise_regeneration(
            battery,
            state,
            train,
            timestep_hours
        )

    charge_energy =
        charge_kw *
        timestep_hours *
        battery.charge_efficiency


    # ----------------------------------------
    # Traction discharge
    # ----------------------------------------

    discharge_kw =
        optimise_discharge(
            battery,
            state,
            train
        )

    discharge_energy =
        discharge_kw *
        timestep_hours /
        battery.discharge_efficiency


    # ----------------------------------------
    # Auxiliary systems
    # ----------------------------------------

    aux_kw =
        optimise_auxiliary_load(
            train.auxiliary_kw,
            0.0,
            20.0
        )

    aux_energy =
        aux_kw *
        timestep_hours


    # ----------------------------------------
    # Net battery energy
    # ----------------------------------------

    net_energy =
        charge_energy -
        discharge_energy -
        aux_energy


    # ----------------------------------------
    # Update SOC
    # ----------------------------------------

    state.soc +=
        net_energy /
        battery.capacity_kwh

    state.soc =
        clamp(
            state.soc,
            battery.soc_min,
            battery.soc_max
        )


    # ----------------------------------------
    # Statistics
    # ----------------------------------------

    state.total_charge_kwh +=
        charge_energy

    state.total_discharge_kwh +=
        discharge_energy

    state.regenerative_captured_kwh +=
        charge_energy


    # ----------------------------------------
    # Thermal state
    # ----------------------------------------

    state.battery_temperature =
        update_temperature(
            state.battery_temperature,
            charge_kw,
            discharge_kw,
            timestep_hours
        )

    return (
        charge_kw = charge_kw,
        discharge_kw = discharge_kw,
        auxiliary_kw = aux_kw,
        soc = state.soc
    )
end


# ------------------------------------------------------------
# Journey optimiser
# ------------------------------------------------------------

function simulate_journey(
    battery::Battery,
    profile
)

    state =
        EnergyState(
            0.65,
            25.0,
            0.0,
            0.0,
            0.0
        )

    history =
        Float64[]

    for train in profile

        result =
            energy_step!(
                battery,
                state,
                train,
                1.0 / 60.0
            )

        push!(
            history,
            state.soc
        )
    end

    return state, history
end


# ------------------------------------------------------------
# Journey profile
# ------------------------------------------------------------

function make_journey()

    profile =
        TrainState[]

    # Acceleration
    for i in 1:20

        push!(
            profile,
            TrainState(
                i * 10,
                0.0,
                4500.0,
                300.0,
                0.0
            )
        )
    end


    # High-speed cruise
    for i in 1:60

        push!(
            profile,
            TrainState(
                300.0,
                0.0,
                2500.0,
                350.0,
                0.0
            )
        )
    end


    # Regenerative braking
    for i in 1:15

        push!(
            profile,
            TrainState(
                300.0 - i * 18,
                0.0,
                0.0,
                300.0,
                4500.0
            )
        )
    end


    # Station dwell
    for i in 1:10

        push!(
            profile,
            TrainState(
                0.0,
                0.0,
                0.0,
                250.0,
                0.0
            )
        )
    end

    return profile
end


# ------------------------------------------------------------
# Report
# ------------------------------------------------------------

function report(
    state::EnergyState,
    history
)

    println()
    println("==========================================")
    println("     SHINKANSEN ENERGY OPTIMISER")
    println("==========================================")

    @printf(
        "Final SOC:              %.2f %%\n",
        state.soc * 100
    )

    @printf(
        "Charge energy:          %.2f kWh\n",
        state.total_charge_kwh
    )

    @printf(
        "Discharge energy:       %.2f kWh\n",
        state.total_discharge_kwh
    )

    @printf(
        "Regeneration captured:  %.2f kWh\n",
        state.regenerative_captured_kwh
    )

    @printf(
        "Battery temperature:    %.2f °C\n",
        state.battery_temperature
    )

    println(
        "Minimum SOC observed:   ",
        @sprintf(
            "%.2f %%",
            minimum(history) * 100
        )
    )

    println(
        "Maximum SOC observed:   ",
        @sprintf(
            "%.2f %%",
            maximum(history) * 100
        )
    )

    println("==========================================")
end


# ------------------------------------------------------------
# Run
# ------------------------------------------------------------

profile =
    make_journey()

state, history =
    simulate_journey(
        battery,
        profile
    )

report(
    state,
    history
)

















module RailCruiseControl

using LinearAlgebra
using Statistics

# ============================================================
# TYPES
# ============================================================

struct TrackSegment
    start_m::Float64
    end_m::Float64
    speed_limit_ms::Float64
    gradient::Float64          # rise/run
    curvature_limit_ms::Float64
end

struct Train
    mass_kg::Float64
    frontal_area_m2::Float64
    drag_coefficient::Float64
    rolling_coefficient::Float64
    max_traction_n::Float64
    max_brake_n::Float64
    max_speed_ms::Float64
end

struct TrainState
    position_m::Float64
    speed_ms::Float64
    acceleration_ms2::Float64
    battery_soc::Float64
end

struct CruiseTarget
    target_speed_ms::Float64
    acceleration_ms2::Float64
    distance_to_limit_m::Float64
    energy_cost::Float64
    confidence::Float64
end

# ============================================================
# PHYSICAL CONSTANTS
# ============================================================

const G = 9.80665
const AIR_DENSITY = 1.225

# ============================================================
# TRAIN RESISTANCE
# ============================================================

function aerodynamic_drag(train::Train, speed::Float64)

    return 0.5 *
           AIR_DENSITY *
           train.drag_coefficient *
           train.frontal_area_m2 *
           speed^2
end


function rolling_resistance(train::Train)

    return train.mass_kg *
           G *
           train.rolling_coefficient
end


function gradient_force(train::Train,
                        gradient::Float64)

    return train.mass_kg *
           G *
           gradient
end


function total_resistance(train::Train,
                          speed::Float64,
                          gradient::Float64)

    aerodynamic_drag(train, speed) +
    rolling_resistance(train) +
    gradient_force(train, gradient)

end

# ============================================================
# AVAILABLE ACCELERATION
# ============================================================

function traction_acceleration(train::Train,
                               speed::Float64,
                               gradient::Float64)

    resistance =
        total_resistance(train, speed, gradient)

    net_force =
        train.max_traction_n -
        resistance

    return net_force / train.mass_kg
end


function braking_deceleration(train::Train,
                              speed::Float64,
                              gradient::Float64)

    resistance =
        total_resistance(train, speed, gradient)

    net_brake =
        train.max_brake_n +
        resistance

    return net_brake / train.mass_kg
end

# ============================================================
# SPEED LIMIT LOOKAHEAD
# ============================================================

function next_speed_restriction(
    state::TrainState,
    track::Vector{TrackSegment},
    horizon_m::Float64
)

    closest_distance = Inf
    restriction = Inf

    for segment in track

        if segment.start_m >= state.position_m &&
           segment.start_m <= state.position_m + horizon_m

            distance =
                segment.start_m -
                state.position_m

            if distance < closest_distance &&
               segment.speed_limit_ms < state.speed_ms

                closest_distance = distance
                restriction = segment.speed_limit_ms
            end
        end
    end

    return restriction, closest_distance
end

# ============================================================
# BRAKING DISTANCE
# ============================================================

function braking_distance(
    train::Train,
    current_speed::Float64,
    target_speed::Float64,
    gradient::Float64
)

    if current_speed <= target_speed
        return 0.0
    end

    a =
        braking_deceleration(
            train,
            current_speed,
            gradient
        )

    return (
        current_speed^2 -
        target_speed^2
    ) / (2a)

end

# ============================================================
# ENERGY MODEL
# ============================================================

function traction_power(
    train::Train,
    speed::Float64,
    acceleration::Float64,
    gradient::Float64
)

    inertial =
        train.mass_kg *
        acceleration

    resistance =
        total_resistance(
            train,
            speed,
            gradient
        )

    force =
        max(
            inertial + resistance,
            0.0
        )

    return force * speed
end


function energy_for_step(
    train::Train,
    speed::Float64,
    acceleration::Float64,
    gradient::Float64,
    dt::Float64
)

    power =
        traction_power(
            train,
            speed,
            acceleration,
            gradient
        )

    return power * dt

end

# ============================================================
# TARGET SPEED GENERATION
# ============================================================

function legal_speed(
    state::TrainState,
    track::Vector{TrackSegment}
)

    limits = Float64[]

    for segment in track

        if state.position_m >= segment.start_m &&
           state.position_m < segment.end_m

            push!(
                limits,
                segment.speed_limit_ms
            )

            push!(
                limits,
                segment.curvature_limit_ms
            )
        end
    end

    if isempty(limits)
        return Inf
    end

    return minimum(limits)
end

# ============================================================
# ECONOMIC / ENERGY OPTIMAL CRUISE SPEED
# ============================================================

function optimal_cruise_speed(
    train::Train,
    state::TrainState,
    track::Vector{TrackSegment};
    dt = 1.0,
    horizon = 300.0
)

    current_limit =
        legal_speed(
            state,
            track
        )

    future_limit,
    distance =
        next_speed_restriction(
            state,
            track,
            horizon
        )

    effective_limit =
        min(
            current_limit,
            train.max_speed_ms
        )

    # --------------------------------------------------------
    # If a restriction is approaching,
    # calculate the speed needed to reach it safely.
    # --------------------------------------------------------

    if future_limit < state.speed_ms

        required_distance =
            braking_distance(
                train,
                state.speed_ms,
                future_limit,
                0.0
            )

        safety_margin = 150.0

        if distance <=
           required_distance +
           safety_margin

            return CruiseTarget(
                future_limit,
                -braking_deceleration(
                    train,
                    state.speed_ms,
                    0.0
                ),
                distance,
                0.0,
                0.98
            )
        end
    end

    # --------------------------------------------------------
    # Energy-efficient cruise.
    #
    # Rather than constantly running at the maximum speed,
    # search for a lower-speed operating point.
    # --------------------------------------------------------

    candidates =
        range(
            max(5.0, effective_limit * 0.70),
            effective_limit,
            length = 15
        )

    best_speed = effective_limit
    best_cost = Inf

    for v in candidates

        resistance =
            total_resistance(
                train,
                v,
                0.0
            )

        power =
            resistance * v

        # Energy cost
        energy =
            power * dt

        # Time penalty
        time_penalty =
            1000.0 / max(v, 1.0)

        cost =
            energy +
            time_penalty

        if cost < best_cost

            best_cost = cost
            best_speed = v

        end
    end

    acceleration =
        clamp(
            (best_speed - state.speed_ms) / dt,
            -2.0,
            1.0
        )

    return CruiseTarget(
        best_speed,
        acceleration,
        distance,
        best_cost,
        0.95
    )

end

# ============================================================
# SMOOTH TARGETING
# ============================================================

function smooth_target(
    current_speed::Float64,
    desired_speed::Float64,
    max_acceleration::Float64,
    max_deceleration::Float64,
    dt::Float64
)

    difference =
        desired_speed -
        current_speed

    if difference > 0

        change =
            min(
                difference,
                max_acceleration * dt
            )

    else

        change =
            max(
                difference,
                -max_deceleration * dt
            )

    end

    return current_speed + change

end

# ============================================================
# CRUISE CONTROLLER SIMULATION
# ============================================================

function simulate(
    train::Train,
    track::Vector{TrackSegment},
    initial_state::TrainState;
    dt = 0.5,
    duration = 600.0
)

    state = initial_state

    history = NamedTuple[]

    t = 0.0

    while t <= duration

        limit =
            legal_speed(
                state,
                track
            )

        target =
            optimal_cruise_speed(
                train,
                state,
                track;
                dt = dt
            )

        commanded_speed =
            min(
                target.target_speed_ms,
                limit,
                train.max_speed_ms
            )

        desired_acceleration =
            target.acceleration_ms2

        acceleration =
            clamp(
                desired_acceleration,
                -2.0,
                1.0
            )

        new_speed =
            smooth_target(
                state.speed_ms,
                commanded_speed,
                0.8,
                1.2,
                dt
            )

        acceleration =
            (new_speed -
             state.speed_ms) / dt

        # ----------------------------------------------------
        # Integrate position
        # ----------------------------------------------------

        new_position =
            state.position_m +
            state.speed_ms * dt +
            0.5 *
            acceleration *
            dt^2

        # ----------------------------------------------------
        # Prevent overspeed
        # ----------------------------------------------------

        new_speed =
            min(
                new_speed,
                limit
            )

        push!(
            history,
            (
                time = t,
                position = state.position_m,
                speed = state.speed_ms,
                target = commanded_speed,
                acceleration = acceleration,
                speed_limit = limit,
                energy = energy_for_step(
                    train,
                    state.speed_ms,
                    acceleration,
                    0.0,
                    dt
                )
            )
        )

        state =
            TrainState(
                new_position,
                new_speed,
                acceleration,
                state.battery_soc
            )

        t += dt
    end

    return history
end

# ============================================================
# REPORT
# ============================================================

function report(history)

    speeds =
        [x.speed for x in history]

    targets =
        [x.target for x in history]

    energy =
        sum(
            x.energy
            for x in history
        )

    println()
    println("======================================")
    println(" RAIL CRUISE CONTROL REPORT")
    println("======================================")

    println(
        "Simulation time: ",
        round(history[end].time, digits=1),
        " s"
    )

    println(
        "Distance: ",
        round(history[end].position, digits=1),
        " m"
    )

    println(
        "Maximum speed: ",
        round(maximum(speeds), digits=2),
        " m/s"
    )

    println(
        "Average speed: ",
        round(mean(speeds), digits=2),
        " m/s"
    )

    println(
        "Average target: ",
        round(mean(targets), digits=2),
        " m/s"
    )

    println(
        "Estimated energy: ",
        round(
            energy / 3.6e6,
            digits=3
        ),
        " kWh"
    )

    println("======================================")

end

end # module











module ShinkansenEnergyML

using Statistics
using Random

# ============================================================
# TRAIN / POWERTRAIN MODEL
# ============================================================

struct Train
    mass_kg::Float64
    frontal_area_m2::Float64
    drag_coefficient::Float64
    rolling_coefficient::Float64

    motor_efficiency::Float64
    inverter_efficiency::Float64
    transformer_efficiency::Float64

    max_power_w::Float64
end


struct OperatingPoint
    speed_ms::Float64
    acceleration_ms2::Float64
    gradient::Float64
    passenger_load::Float64
    temperature_c::Float64
    wind_ms::Float64
end


# ============================================================
# PHYSICS
# ============================================================

const G = 9.80665
const AIR_DENSITY = 1.225


function aerodynamic_force(
    train::Train,
    op::OperatingPoint
)

    relative_wind =
        op.speed_ms + op.wind_ms

    return 0.5 *
           AIR_DENSITY *
           train.frontal_area_m2 *
           train.drag_coefficient *
           relative_wind^2
end


function rolling_force(
    train::Train
)

    return train.mass_kg *
           G *
           train.rolling_coefficient
end


function gradient_force(
    train::Train,
    gradient::Float64
)

    return train.mass_kg *
           G *
           gradient
end


function inertial_force(
    train::Train,
    acceleration::Float64
)

    return train.mass_kg *
           acceleration
end


function wheel_force(
    train::Train,
    op::OperatingPoint
)

    aerodynamic_force(train, op) +
    rolling_force(train) +
    gradient_force(train, op.gradient) +
    inertial_force(train, op.acceleration_ms2)

end


# ============================================================
# ELECTRICAL POWER
# ============================================================

function mechanical_power(
    train::Train,
    op::OperatingPoint
)

    force =
        wheel_force(train, op)

    max(
        force *
        op.speed_ms,
        0.0
    )

end


function electrical_power(
    train::Train,
    op::OperatingPoint
)

    mechanical =
        mechanical_power(
            train,
            op
        )

    drivetrain_efficiency =
        train.motor_efficiency *
        train.inverter_efficiency *
        train.transformer_efficiency

    mechanical /
    drivetrain_efficiency

end


# ============================================================
# THERMAL LOSSES
# ============================================================

function copper_loss(
    current::Float64,
    resistance::Float64
)

    current^2 * resistance

end


function inverter_loss(
    power::Float64
)

    # simplified switching/conduction model
    0.015 * power +
    500.0

end


function motor_loss(
    power::Float64,
    speed::Float64
)

    # simplified iron + copper + mechanical losses
    0.01 * power +
    0.00002 * speed^2

end


function transformer_loss(
    power::Float64
)

    0.008 * power +
    300.0

end


# ============================================================
# THERMAL STATE
# ============================================================

mutable struct ThermalState

    motor_temperature_c::Float64
    inverter_temperature_c::Float64
    transformer_temperature_c::Float64

end


function update_temperature!(
    thermal::ThermalState,
    motor_heat::Float64,
    inverter_heat::Float64,
    transformer_heat::Float64,
    dt::Float64
)

    # Simplified thermal capacitance/cooling model.

    motor_capacity = 500_000.0
    inverter_capacity = 200_000.0
    transformer_capacity = 400_000.0

    motor_cooling =
        150.0 *
        (thermal.motor_temperature_c - 25.0)

    inverter_cooling =
        100.0 *
        (thermal.inverter_temperature_c - 25.0)

    transformer_cooling =
        120.0 *
        (thermal.transformer_temperature_c - 25.0)

    thermal.motor_temperature_c +=
        (
            motor_heat -
            motor_cooling
        ) /
        motor_capacity *
        dt

    thermal.inverter_temperature_c +=
        (
            inverter_heat -
            inverter_cooling
        ) /
        inverter_capacity *
        dt

    thermal.transformer_temperature_c +=
        (
            transformer_heat -
            transformer_cooling
        ) /
        transformer_capacity *
        dt

end


# ============================================================
# FEATURE VECTOR
# ============================================================

function features(
    op::OperatingPoint,
    thermal::ThermalState
)

    [
        op.speed_ms,
        op.acceleration_ms2,
        op.gradient,
        op.passenger_load,
        op.temperature_c,
        op.wind_ms,

        thermal.motor_temperature_c,
        thermal.inverter_temperature_c,
        thermal.transformer_temperature_c
    ]

end


# ============================================================
# SMALL NEURAL NETWORK
# ============================================================

mutable struct NeuralNetwork

    W1::Matrix{Float64}
    b1::Vector{Float64}

    W2::Matrix{Float64}
    b2::Vector{Float64}

    W3::Matrix{Float64}
    b3::Vector{Float64}

end


function NeuralNetwork(
    input_size::Int,
    hidden1::Int,
    hidden2::Int
)

    NeuralNetwork(

        randn(hidden1, input_size) * 0.1,
        zeros(hidden1),

        randn(hidden2, hidden1) * 0.1,
        zeros(hidden2),

        randn(1, hidden2) * 0.1,
        zeros(1)
    )

end


function relu(x)

    max.(x, 0.0)

end


function predict(
    model::NeuralNetwork,
    x::Vector{Float64}
)

    h1 =
        relu(
            model.W1 * x +
            model.b1
        )

    h2 =
        relu(
            model.W2 * h1 +
            model.b2
        )

    y =
        model.W3 * h2 +
        model.b3

    y[1]

end


# ============================================================
# ONLINE LEARNING
# ============================================================

function update_model!(
    model::NeuralNetwork,
    x::Vector{Float64},
    actual::Float64;
    learning_rate = 1e-7
)

    prediction =
        predict(model, x)

    error =
        prediction -
        actual

    # Lightweight finite-difference update.
    #
    # This is deliberately simple; production training would
    # use automatic differentiation and an optimiser such as
    # Adam/Flux/Optimisers.

    for i in eachindex(model.W3)

        model.W3[i] -=
            learning_rate *
            error

    end

end


# ============================================================
# ENERGY EVALUATION
# ============================================================

function evaluate(
    train::Train,
    op::OperatingPoint,
    thermal::ThermalState
)

    electrical =
        electrical_power(
            train,
            op
        )

    # Estimate current from traction voltage.
    voltage = 25_000.0

    current =
        electrical /
        voltage

    copper =
        copper_loss(
            current,
            0.05
        )

    inverter =
        inverter_loss(
            electrical
        )

    motor =
        motor_loss(
            electrical,
            op.speed_ms
        )

    transformer =
        transformer_loss(
            electrical
        )

    losses =
        copper +
        inverter +
        motor +
        transformer

    return (
        electrical_power = electrical,
        copper_loss = copper,
        inverter_loss = inverter,
        motor_loss = motor,
        transformer_loss = transformer,
        total_loss = losses
    )

end


# ============================================================
# ML-ASSISTED OPTIMISER
# ============================================================

function optimise_speed(
    train::Train,
    op::OperatingPoint,
    thermal::ThermalState,
    model::NeuralNetwork
)

    candidates =
        range(
            max(0.0, op.speed_ms - 10.0),
            op.speed_ms + 10.0,
            length = 41
        )

    best_speed =
        op.speed_ms

    best_cost =
        Inf

    for speed in candidates

        candidate =
            OperatingPoint(
                speed,
                op.acceleration_ms2,
                op.gradient,
                op.passenger_load,
                op.temperature_c,
                op.wind_ms
            )

        physical =
            evaluate(
                train,
                candidate,
                thermal
            )

        prediction =
            predict(
                model,
                features(
                    candidate,
                    thermal
                )
            )

        # Physics + ML objective.
        #
        # ML prediction is advisory; physics remains
        # part of the optimisation constraint.

        cost =
            0.70 *
            physical.electrical_power +

            0.20 *
            prediction +

            0.10 *
            abs(
                candidate.speed_ms -
                op.speed_ms
            ) *
            1000.0

        if cost < best_cost

            best_cost =
                cost

            best_speed =
                speed
        end
    end

    return best_speed

end


# ============================================================
# JOURNEY STEP
# ============================================================

function step!(
    train::Train,
    state::OperatingPoint,
    thermal::ThermalState,
    model::NeuralNetwork,
    dt::Float64
)

    target_speed =
        optimise_speed(
            train,
            state,
            thermal,
            model
        )

    acceleration =
        clamp(
            (
                target_speed -
                state.speed_ms
            ) / dt,

            -0.5,
            0.5
        )

    next_state =
        OperatingPoint(
            state.speed_ms +
            acceleration * dt,

            acceleration,

            state.gradient,

            state.passenger_load,

            state.temperature_c,

            state.wind_ms
        )

    energy =
        evaluate(
            train,
            next_state,
            thermal
        )

    # Thermal generation

    update_temperature!(
        thermal,

        energy.motor_loss,
        energy.inverter_loss,
        energy.transformer_loss,

        dt
    )

    # Online learning

    x =
        features(
            next_state,
            thermal
        )

    update_model!(
        model,
        x,
        energy.electrical_power
    )

    return next_state, energy

end


end # module
What makes this interesting

The algorithm can learn that the same speed does not always have the same electrical cost.

For example:

300 km/h
│
├── flat track
│      → relatively predictable consumption
│
├── +1% gradient
│      → substantially higher traction power
│
├── headwind
│      → aerodynamic penalty
│
├── high motor temperature
│      → efficiency penalty
│
├── high passenger loading
│      → greater inertial/rolling cost
│
└── approaching braking zone
       → potentially wasteful acceleration
       
       
       
       
       The ML layer therefore learns a function approximately like:

$$ P_{electrical} = f(v,a,g,w,T_{motor},T_{inverter},load,\ldots) $$

and the optimiser searches for:

$$ \min \int P_{electrical}(t)\,dt $$

subject to:

$$ v(t) \leq v_{limit}(t) $$ $$ a_{min} \leq a(t) \leq a_{max} $$

and timetable/comfort constraints.










module RegenerativeEnergyOptimizer

using Statistics

# ============================================================
# BATTERY
# ============================================================

mutable struct Battery

    capacity_kwh::Float64
    soc::Float64

    max_charge_kw::Float64
    max_discharge_kw::Float64

    temperature_c::Float64

    minimum_soc::Float64
    maximum_soc::Float64

    efficiency_charge::Float64
    efficiency_discharge::Float64

end


# ============================================================
# TRAIN
# ============================================================

struct Train

    mass_kg::Float64

    auxiliary_power_kw::Float64

    traction_efficiency::Float64
    regenerative_efficiency::Float64

    maximum_brake_force_n::Float64

end


# ============================================================
# TRAIN STATE
# ============================================================

struct TrainState

    speed_ms::Float64
    acceleration_ms2::Float64

    gradient::Float64

    distance_to_station_m::Float64

end


# ============================================================
# BATTERY ENERGY
# ============================================================

function available_charge_capacity(
    battery::Battery
)

    (
        battery.maximum_soc -
        battery.soc
    ) *
    battery.capacity_kwh

end


function available_discharge_capacity(
    battery::Battery
)

    (
        battery.soc -
        battery.minimum_soc
    ) *
    battery.capacity_kwh

end


# ============================================================
# REGENERATIVE POWER
# ============================================================

function kinetic_energy(
    train::Train,
    speed_ms::Float64
)

    0.5 *
    train.mass_kg *
    speed_ms^2

end


function regenerative_power(
    train::Train,
    state::TrainState
)

    if state.acceleration_ms2 >= 0

        return 0.0
    end

    braking_force =
        train.mass_kg *
        abs(state.acceleration_ms2)

    mechanical_power =
        braking_force *
        state.speed_ms

    regenerative_power =
        mechanical_power *
        train.regenerative_efficiency

    return regenerative_power / 1000.0

end


# ============================================================
# AVAILABLE REGENERATION
# ============================================================

function recoverable_energy(
    train::Train,
    battery::Battery,
    state::TrainState,
    dt::Float64
)

    power =
        regenerative_power(
            train,
            state
        )

    battery_limit =
        battery.max_charge_kw

    allowed_power =
        min(
            power,
            battery_limit
        )

    energy =
        allowed_power *
        dt /
        3600.0

    capacity =
        available_charge_capacity(
            battery
        )

    return min(
        energy,
        capacity
    )

end


# ============================================================
# BATTERY TEMPERATURE
# ============================================================

function battery_heat_generation(
    battery::Battery,
    charge_power_kw::Float64
)

    # Simplified representation of resistive losses.

    resistance_loss =
        0.015 *
        charge_power_kw^2 /
        100.0

    return resistance_loss

end


function update_temperature!(
    battery::Battery,
    heat_kw::Float64,
    dt::Float64
)

    thermal_capacity =
        250.0

    cooling =
        0.05 *
        (
            battery.temperature_c -
            25.0
        )

    battery.temperature_c +=
        (
            heat_kw -
            cooling
        ) /
        thermal_capacity *
        dt

end


# ============================================================
# BATTERY DEGRADATION
# ============================================================

function degradation_penalty(
    battery::Battery,
    charge_power_kw::Float64
)

    temperature_penalty =
        max(
            battery.temperature_c - 30.0,
            0.0
        )^2

    high_soc_penalty =
        max(
            battery.soc - 0.90,
            0.0
        )^2

    power_penalty =
        (
            charge_power_kw /
            battery.max_charge_kw
        )^2

    return (
        temperature_penalty +
        high_soc_penalty +
        power_penalty
    )

end


# ============================================================
# REGENERATIVE BRAKING DECISION
# ============================================================

function optimise_regeneration(
    train::Train,
    battery::Battery,
    state::TrainState;
    dt = 1.0
)

    natural_power =
        regenerative_power(
            train,
            state
        )

    available_capacity =
        available_charge_capacity(
            battery
        )

    charge_limit =
        min(
            battery.max_charge_kw,
            natural_power
        )

    # Energy available during this interval.

    energy_available =
        charge_limit *
        dt /
        3600.0

    if energy_available >
       available_capacity

        charge_power =
            available_capacity *
            3600.0 /
            dt

    else

        charge_power =
            charge_limit

    end

    penalty =
        degradation_penalty(
            battery,
            charge_power
        )

    # Prefer high recovery, but penalise
    # thermally expensive operation.

    score =
        charge_power -
        0.5 * penalty

    return (
        charge_power_kw = charge_power,
        recoverable_kwh =
            charge_power * dt / 3600.0,
        score = score
    )

end


# ============================================================
# BATTERY UPDATE
# ============================================================

function apply_regeneration!(
    battery::Battery,
    charge_power_kw::Float64,
    dt::Float64
)

    usable_power =
        min(
            charge_power_kw,
            battery.max_charge_kw
        )

    stored_energy =
        usable_power *
        battery.efficiency_charge *
        dt /
        3600.0

    capacity =
        available_charge_capacity(
            battery
        )

    stored_energy =
        min(
            stored_energy,
            capacity
        )

    battery.soc +=
        stored_energy /
        battery.capacity_kwh

    heat =
        battery_heat_generation(
            battery,
            usable_power
        )

    update_temperature!(
        battery,
        heat,
        dt
    )

    return stored_energy

end


# ============================================================
# ENERGY ROUTING
# ============================================================

function route_regenerative_energy(
    battery::Battery,
    regenerative_power_kw::Float64
)

    battery_capacity =
        available_charge_capacity(
            battery
        )

    battery_power =
        min(
            regenerative_power_kw,
            battery.max_charge_kw
        )

    remaining =
        max(
            regenerative_power_kw -
            battery_power,
            0.0
        )

    return (
        battery_kw = battery_power,
        grid_kw = remaining
    )

end


# ============================================================
# PREDICTIVE STATION BRAKING
# ============================================================

function station_braking_energy(
    train::Train,
    current_speed_ms::Float64,
    target_speed_ms::Float64
)

    if current_speed_ms <= target_speed_ms
        return 0.0
    end

    energy =
        kinetic_energy(
            train,
            current_speed_ms
        ) -
        kinetic_energy(
            train,
            target_speed_ms
        )

    return max(
        energy,
        0.0
    )

end


# ============================================================
# FUTURE BATTERY CAPACITY
# ============================================================

function predict_soc_after_regeneration(
    battery::Battery,
    recovered_kwh::Float64
)

    new_soc =
        battery.soc +
        recovered_kwh /
        battery.capacity_kwh

    return clamp(
        new_soc,
        0.0,
        1.0
    )

end


# ============================================================
# REGENERATIVE JOURNEY SIMULATOR
# ============================================================

function simulate_regeneration(
    train::Train,
    battery::Battery,
    states::Vector{TrainState};
    dt = 1.0
)

    total_recovered = 0.0
    total_regenerative = 0.0
    total_grid_energy = 0.0

    results = NamedTuple[]

    for state in states

        natural =
            regenerative_power(
                train,
                state
            )

        routing =
            route_regenerative_energy(
                battery,
                natural
            )

        recovered =
            optimise_regeneration(
                train,
                battery,
                state;
                dt = dt
            )

        stored =
            apply_regeneration!(
                battery,
                recovered.charge_power_kw,
                dt
            )

        total_recovered += stored

        total_regenerative +=
            natural * dt / 3600.0

        total_grid_energy +=
            routing.grid_kw *
            dt /
            3600.0

        push!(
            results,
            (
                speed_ms = state.speed_ms,
                soc = battery.soc,
                battery_temperature =
                    battery.temperature_c,
                regenerative_kw =
                    natural,
                battery_charge_kw =
                    recovered.charge_power_kw,
                recovered_kwh =
                    stored
            )
        )

    end

    return (
        results = results,
        recovered_kwh = total_recovered,
        regenerative_kwh = total_regenerative,
        grid_energy_kwh = total_grid_energy
    )

end


# ============================================================
# REPORT
# ============================================================

function report(result)

    println()
    println(
        "=========================================="
    )
    println(
        " REGENERATIVE ENERGY REPORT"
    )
    println(
        "=========================================="
    )

    println(
        "Regenerative energy available: ",
        round(
            result.regenerative_kwh,
            digits=2
        ),
        " kWh"
    )

    println(
        "Energy stored: ",
        round(
            result.recovered_kwh,
            digits=2
        ),
        " kWh"
    )

    utilisation =
        if result.regenerative_kwh > 0
            result.recovered_kwh /
            result.regenerative_kwh *
            100.0
        else
            0.0
        end

    println(
        "Battery recovery utilisation: ",
        round(
            utilisation,
            digits=2
        ),
        "%"
    )

    println(
        "Final SOC: ",
        round(
            result.results[end].soc * 100,
            digits=2
        ),
        "%"
    )

    println(
        "Final battery temperature: ",
        round(
            result.results[end].
            battery_temperature,
            digits=2
        ),
        " °C"
    )

    println(
        "=========================================="
    )

end

end








module PredictiveTrainEnergy

using Statistics
using Random

# ============================================================
# PHYSICAL MODEL
# ============================================================

const G = 9.80665
const AIR_DENSITY = 1.225


struct TrainModel
    mass_kg::Float64
    frontal_area_m2::Float64
    drag_coefficient::Float64
    rolling_coefficient::Float64

    traction_efficiency::Float64
    regen_efficiency::Float64

    auxiliary_power_kw::Float64

    max_acceleration::Float64
    max_deceleration::Float64
    maximum_speed::Float64
end


struct TrackState
    position_m::Float64
    speed_ms::Float64
    gradient::Float64
    speed_limit_ms::Float64

    distance_to_station_m::Float64
    station_target_speed_ms::Float64
end


struct Environment
    temperature_c::Float64
    wind_ms::Float64
    passenger_load::Float64
end


struct EnergyObservation
    features::Vector{Float64}
    actual_energy_kwh::Float64
end


# ============================================================
# TRAIN PHYSICS
# ============================================================

function drag_force(
    train::TrainModel,
    speed::Float64,
    wind::Float64
)

    relative_speed =
        speed + wind

    0.5 *
    AIR_DENSITY *
    train.frontal_area_m2 *
    train.drag_coefficient *
    relative_speed^2
end


function rolling_force(
    train::TrainModel
)

    train.mass_kg *
    G *
    train.rolling_coefficient
end


function gradient_force(
    train::TrainModel,
    gradient::Float64
)

    train.mass_kg *
    G *
    gradient
end


function traction_force(
    train::TrainModel,
    speed::Float64,
    acceleration::Float64,
    gradient::Float64
)

    inertial =
        train.mass_kg *
        acceleration

    resistance =
        drag_force(
            train,
            speed,
            0.0
        ) +

        rolling_force(train) +

        gradient_force(
            train,
            gradient
        )

    inertial + resistance
end


# ============================================================
# ELECTRICITY MODEL
# ============================================================

function electrical_power_kw(
    train::TrainModel,
    speed::Float64,
    acceleration::Float64,
    gradient::Float64,
    environment::Environment
)

    force =
        traction_force(
            train,
            speed,
            acceleration,
            gradient
        )

    mechanical_power =
        force * speed

    # Negative mechanical power means braking.
    if mechanical_power >= 0

        electrical =
            mechanical_power /
            train.traction_efficiency

    else

        electrical =
            mechanical_power *
            train.regen_efficiency

    end

    # Auxiliary systems continue operating.
    electrical +=
        train.auxiliary_power_kw * 1000.0

    return electrical / 1000.0
end


# ============================================================
# FEATURE ENGINEERING
# ============================================================

function make_features(
    track::TrackState,
    env::Environment,
    acceleration::Float64
)

    [

        # Dynamic state
        track.speed_ms,

        acceleration,

        # Track
        track.gradient,

        track.speed_limit_ms,

        # Journey geometry
        track.distance_to_station_m,

        track.station_target_speed_ms,

        # Environment
        env.temperature_c,

        env.wind_ms,

        env.passenger_load,

        # Derived features
        track.speed_ms^2,

        abs(track.gradient),

        acceleration^2

    ]

end


# ============================================================
# SMALL ONLINE ML MODEL
# ============================================================

mutable struct EnergyPredictor

    weights::Vector{Float64}
    bias::Float64

    learning_rate::Float64

    samples::Int
end


function EnergyPredictor(
    number_of_features::Int
)

    EnergyPredictor(
        zeros(number_of_features),
        0.0,
        0.00001,
        0
    )

end


function predict(
    model::EnergyPredictor,
    features::Vector{Float64}
)

    return dot(
        model.weights,
        features
    ) + model.bias

end


function update!(
    model::EnergyPredictor,
    features::Vector{Float64},
    actual_energy::Float64
)

    prediction =
        predict(
            model,
            features
        )

    error =
        prediction -
        actual_energy

    # Normalised gradient update.
    magnitude =
        dot(features, features) +
        1.0

    rate =
        model.learning_rate /
        magnitude

    model.weights .-=
        rate *
        error *
        features

    model.bias -=
        rate * error

    model.samples += 1

end


# ============================================================
# NON-LINEAR ENERGY CORRECTION
# ============================================================

function nonlinear_energy_correction(
    speed::Float64,
    acceleration::Float64,
    gradient::Float64
)

    aerodynamic =
        0.0000008 *
        speed^3

    acceleration_cost =
        0.02 *
        abs(acceleration)^2

    gradient_cost =
        100.0 *
        abs(gradient) *
        speed

    aerodynamic +
    acceleration_cost +
    gradient_cost

end


# ============================================================
# HYBRID PREDICTOR
# ============================================================

function predict_energy(
    predictor::EnergyPredictor,
    train::TrainModel,
    track::TrackState,
    env::Environment,
    acceleration::Float64,
    duration_s::Float64
)

    x =
        make_features(
            track,
            env,
            acceleration
        )

    ml_prediction =
        predict(
            predictor,
            x
        )

    physics_power =
        electrical_power_kw(
            train,
            track.speed_ms,
            acceleration,
            track.gradient,
            env
        )

    physics_energy =
        physics_power *
        duration_s /
        3600.0

    correction =
        nonlinear_energy_correction(
            track.speed_ms,
            acceleration,
            track.gradient
        )

    # Hybrid physics + ML prediction.
    #
    # Early in operation, physics dominates.
    # As the model gets more observations,
    # ML receives greater influence.

    learning_factor =
        min(
            predictor.samples / 5000.0,
            0.70
        )

    prediction =
        (
            (1.0 - learning_factor) *
            physics_energy
        ) +

        (
            learning_factor *
            max(
                ml_prediction,
                0.0
            )
        ) +

        correction

    return max(
        prediction,
        0.0
    )

end


# ============================================================
# SPEED PROFILE PREDICTION
# ============================================================

function predicted_speed(
    speed::Float64,
    acceleration::Float64,
    dt::Float64,
    speed_limit::Float64,
    maximum_speed::Float64
)

    new_speed =
        speed +
        acceleration * dt

    clamp(
        new_speed,
        0.0,
        min(
            speed_limit,
            maximum_speed
        )
    )

end


# ============================================================
# DISTANCE PREDICTION
# ============================================================

function predicted_position(
    position::Float64,
    speed::Float64,
    acceleration::Float64,
    dt::Float64
)

    position +
    speed * dt +
    0.5 *
    acceleration *
    dt^2

end


# ============================================================
# TIMETABLE COST
# ============================================================

function timetable_penalty(
    predicted_time::Float64,
    target_time::Float64
)

    error =
        predicted_time -
        target_time

    if error <= 0
        return 0.0
    end

    1000.0 *
    error^2

end


# ============================================================
# TRAJECTORY SIMULATION
# ============================================================

function simulate_trajectory(
    predictor::EnergyPredictor,
    train::TrainModel,
    track::TrackState,
    env::Environment,

    acceleration::Float64;

    horizon_s = 120.0,
    dt = 2.0
)

    current_speed =
        track.speed_ms

    current_position =
        track.position_m

    total_energy = 0.0

    total_time = 0.0

    maximum_speed =
        current_speed

    while total_time < horizon_s

        current_speed =
            predicted_speed(
                current_speed,
                acceleration,
                dt,
                track.speed_limit_ms,
                train.maximum_speed
            )

        current_position =
            predicted_position(
                current_position,
                current_speed,
                acceleration,
                dt
            )

        future_track =
            TrackState(
                current_position,
                current_speed,
                track.gradient,
                track.speed_limit_ms,
                max(
                    track.distance_to_station_m -
                    current_speed * dt,
                    0.0
                ),
                track.station_target_speed_ms
            )

        energy =
            predict_energy(
                predictor,
                train,
                future_track,
                env,
                acceleration,
                dt
            )

        total_energy += energy

        maximum_speed =
            max(
                maximum_speed,
                current_speed
            )

        total_time += dt
    end

    return (
        energy_kwh = total_energy,
        final_speed = current_speed,
        final_position = current_position,
        maximum_speed = maximum_speed,
        duration = total_time
    )

end


# ============================================================
# CANDIDATE TRAJECTORIES
# ============================================================

function candidate_accelerations(
    train::TrainModel
)

    range(
        -train.max_deceleration,
        train.max_acceleration,
        length = 17
    ) |> collect

end


# ============================================================
# PREDICTIVE OPTIMISER
# ============================================================

function optimise(
    predictor::EnergyPredictor,
    train::TrainModel,
    track::TrackState,
    env::Environment;

    horizon_s = 120.0,
    dt = 2.0
)

    best_acceleration = 0.0
    best_cost = Inf
    best_trajectory = nothing

    for acceleration in
        candidate_accelerations(train)

        trajectory =
            simulate_trajectory(
                predictor,
                train,
                track,
                env,
                acceleration;

                horizon_s = horizon_s,
                dt = dt
            )

        # ----------------------------------------------------
        # Energy objective
        # ----------------------------------------------------

        energy_cost =
            trajectory.energy_kwh

        # ----------------------------------------------------
        # Penalise unnecessary speed changes.
        # ----------------------------------------------------

        smoothness_cost =
            10.0 *
            acceleration^2

        # ----------------------------------------------------
        # Avoid approaching a station too quickly.
        # ----------------------------------------------------

        station_cost =

            if track.distance_to_station_m < 5000.0

                speed_error =
                    max(
                        trajectory.final_speed -
                        track.station_target_speed_ms,
                        0.0
                    )

                100.0 *
                speed_error^2

            else

                0.0
            end

        cost =
            energy_cost +
            smoothness_cost +
            station_cost

        if cost < best_cost

            best_cost =
                cost

            best_acceleration =
                acceleration

            best_trajectory =
                trajectory
        end
    end

    return (
        acceleration = best_acceleration,
        trajectory = best_trajectory,
        cost = best_cost
    )

end


# ============================================================
# LIVE ENERGY CONTROLLER
# ============================================================

mutable struct Controller

    predictor::EnergyPredictor

    total_energy_kwh::Float64

    total_distance_m::Float64

end


function Controller()

    Controller(
        EnergyPredictor(12),
        0.0,
        0.0
    )

end


function update!(
    controller::Controller,
    train::TrainModel,
    track::TrackState,
    environment::Environment;
    dt = 2.0
)

    result =
        optimise(
            controller.predictor,
            train,
            track,
            environment;
            horizon_s = 120.0,
            dt = dt
        )

    # --------------------------------------------------------
    # Record actual physics observation.
    #
    # In a real deployment this comes from train telemetry.
    # --------------------------------------------------------

    actual_power =
        electrical_power_kw(
            train,
            track.speed_ms,
            result.acceleration,
            track.gradient,
            environment
        )

    actual_energy =
        actual_power *
        dt /
        3600.0

    x =
        make_features(
            track,
            environment,
            result.acceleration
        )

    # Online learning.
    update!(
        controller.predictor,
        x,
        actual_energy
    )

    controller.total_energy_kwh +=
        actual_energy

    controller.total_distance_m +=
        track.speed_ms * dt

    return result

end


# ============================================================
# ENERGY REPORT
# ============================================================

function report(
    controller::Controller
)

    distance_km =
        controller.total_distance_m /
        1000.0

    energy_per_km =
        if distance_km > 0
            controller.total_energy_kwh /
            distance_km
        else
            0.0
        end

    println()
    println(
        "============================================"
    )
    println(
        " PREDICTIVE TRAIN ENERGY REPORT"
    )
    println(
        "============================================"
    )

    println(
        "Distance: ",
        round(
            distance_km,
            digits = 2
        ),
        " km"
    )

    println(
        "Energy: ",
        round(
            controller.total_energy_kwh,
            digits = 3
        ),
        " kWh"
    )

    println(
        "Energy / km: ",
        round(
            energy_per_km,
            digits = 3
        ),
        " kWh/km"
    )

    println(
        "ML observations: ",
        controller.predictor.samples
    )

    println(
        "============================================"
    )

end

end









module AutonomousRail

using Statistics

# ============================================================
# CONSTANTS
# ============================================================

const G = 9.80665
const AIR_DENSITY = 1.225


# ============================================================
# TRACK
# ============================================================

struct TrackSegment

    start_m::Float64
    end_m::Float64

    speed_limit_ms::Float64

    gradient::Float64

    curvature_limit_ms::Float64

end


# ============================================================
# TRAIN
# ============================================================

struct Train

    mass_kg::Float64

    frontal_area_m2::Float64
    drag_coefficient::Float64

    rolling_coefficient::Float64

    maximum_traction_n::Float64
    maximum_brake_n::Float64

    maximum_speed_ms::Float64

    maximum_acceleration::Float64
    maximum_deceleration::Float64

end


# ============================================================
# TRAIN STATE
# ============================================================

struct State

    position_m::Float64
    speed_ms::Float64

end


# ============================================================
# TRACK LOOKUP
# ============================================================

function track_at(
    track::Vector{TrackSegment},
    position::Float64
)

    for segment in track

        if position >= segment.start_m &&
           position < segment.end_m

            return segment
        end
    end

    return track[end]

end


function speed_limit(
    track::Vector{TrackSegment},
    position::Float64
)

    segment =
        track_at(
            track,
            position
        )

    return min(
        segment.speed_limit_ms,
        segment.curvature_limit_ms
    )

end


# ============================================================
# PHYSICS
# ============================================================

function aerodynamic_drag(
    train::Train,
    speed::Float64
)

    0.5 *
    AIR_DENSITY *
    train.frontal_area_m2 *
    train.drag_coefficient *
    speed^2

end


function rolling_resistance(
    train::Train
)

    train.mass_kg *
    G *
    train.rolling_coefficient

end


function gradient_resistance(
    train::Train,
    gradient::Float64
)

    train.mass_kg *
    G *
    gradient

end


function resistance(
    train::Train,
    speed::Float64,
    gradient::Float64
)

    aerodynamic_drag(
        train,
        speed
    ) +

    rolling_resistance(train) +

    gradient_resistance(
        train,
        gradient
    )

end


# ============================================================
# ACCELERATION
# ============================================================

function acceleration(
    train::Train,
    state::State,
    traction::Float64,
    gradient::Float64
)

    force =
        traction -
        resistance(
            train,
            state.speed_ms,
            gradient
        )

    force /
    train.mass_kg

end


# ============================================================
# BRAKING DISTANCE
# ============================================================

function braking_distance(
    train::Train,
    current_speed::Float64,
    target_speed::Float64,
    gradient::Float64
)

    if current_speed <= target_speed

        return 0.0

    end

    a =
        train.maximum_deceleration

    return (
        current_speed^2 -
        target_speed^2
    ) / (2a)

end


# ============================================================
# SAFE FUTURE SPEED
# ============================================================

function lookahead_speed(
    train::Train,
    track::Vector{TrackSegment},
    position::Float64,
    speed::Float64,
    horizon::Float64
)

    safe_speed =
        speed_limit(
            track,
            position
        )

    for segment in track

        if segment.start_m > position &&
           segment.start_m < position + horizon

            future_limit =
                min(
                    segment.speed_limit_ms,
                    segment.curvature_limit_ms
                )

            distance =
                segment.start_m -
                position

            braking =
                braking_distance(
                    train,
                    speed,
                    future_limit,
                    segment.gradient
                )

            safety_margin = 100.0

            if distance <=
               braking +
               safety_margin

                safe_speed =
                    min(
                        safe_speed,
                        future_limit
                    )
            end
        end
    end

    return safe_speed

end


# ============================================================
# ACTIONS
# ============================================================

@enum Action begin

    FULL_ACCELERATION
    MEDIUM_ACCELERATION
    COAST
    LIGHT_BRAKE
    FULL_BRAKE

end


function action_acceleration(
    action::Action,
    train::Train,
    state::State,
    gradient::Float64
)

    if action == FULL_ACCELERATION

        return train.maximum_acceleration

    elseif action == MEDIUM_ACCELERATION

        return 0.5 *
               train.maximum_acceleration

    elseif action == COAST

        return acceleration(
            train,
            state,
            0.0,
            gradient
        )

    elseif action == LIGHT_BRAKE

        return -0.35 *
               train.maximum_deceleration

    else

        return -train.maximum_deceleration

    end

end


# ============================================================
# STATE PROPAGATION
# ============================================================

function propagate(
    train::Train,
    track::Vector{TrackSegment},
    state::State,
    action::Action,
    dt::Float64
)

    segment =
        track_at(
            track,
            state.position_m
        )

    a =
        action_acceleration(
            action,
            train,
            state,
            segment.gradient
        )

    a =
        clamp(
            a,
            -train.maximum_deceleration,
            train.maximum_acceleration
        )

    new_speed =
        state.speed_ms +
        a * dt

    new_speed =
        max(
            new_speed,
            0.0
        )

    limit =
        speed_limit(
            track,
            state.position_m
        )

    new_speed =
        min(
            new_speed,
            limit
        )

    new_position =
        state.position_m +
        state.speed_ms * dt +
        0.5 * a * dt^2

    return State(
        new_position,
        new_speed
    )

end


# ============================================================
# TRAJECTORY
# ============================================================

struct TrajectoryPoint

    time_s::Float64
    position_m::Float64
    speed_ms::Float64
    acceleration_ms2::Float64

end


# ============================================================
# FASTEST TRAJECTORY
# ============================================================

function fastest_trajectory(
    train::Train,
    track::Vector{TrackSegment},
    start_position::Float64,
    destination::Float64;

    dt = 0.5,
    maximum_time = 3600.0
)

    state =
        State(
            start_position,
            0.0
        )

    trajectory =
        TrajectoryPoint[]

    time = 0.0

    actions = Action[
        FULL_ACCELERATION,
        MEDIUM_ACCELERATION,
        COAST,
        LIGHT_BRAKE,
        FULL_BRAKE
    ]

    while
        state.position_m <
        destination &&
        time <
        maximum_time

        safe =
            lookahead_speed(
                train,
                track,
                state.position_m,
                state.speed_ms,
                5000.0
            )

        # ----------------------------------------------------
        # Select action according to predicted future state.
        # ----------------------------------------------------

        selected =
            COAST

        # Accelerate if there is substantial
        # speed headroom.

        if state.speed_ms <
           safe - 2.0

            selected =
                FULL_ACCELERATION

        # Begin braking before restriction.

        elseif state.speed_ms >
               safe + 1.0

            selected =
                LIGHT_BRAKE

        end

        old_speed =
            state.speed_ms

        new_state =
            propagate(
                train,
                track,
                state,
                selected,
                dt
            )

        actual_acceleration =
            (
                new_state.speed_ms -
                old_speed
            ) / dt

        push!(
            trajectory,
            TrajectoryPoint(
                time,
                state.position_m,
                state.speed_ms,
                actual_acceleration
            )
        )

        state =
            new_state

        time += dt
    end

    return trajectory

end


# ============================================================
# REPORT
# ============================================================

function report(
    trajectory::Vector{TrajectoryPoint},
    destination::Float64
)

    final =
        trajectory[end]

    println()
    println(
        "=========================================="
    )
    println(
        " AUTONOMOUS RAIL TRAJECTORY"
    )
    println(
        "=========================================="
    )

    println(
        "Distance: ",
        round(
            final.position_m / 1000,
            digits=2
        ),
        " km"
    )

    println(
        "Travel time: ",
        round(
            final.time_s / 60,
            digits=2
        ),
        " minutes"
    )

    println(
        "Maximum speed: ",
        round(
            maximum(
                p.speed_ms
                for p in trajectory
            ) * 3.6,
            digits=1
        ),
        " km/h"
    )

    println(
        "Arrival position error: ",
        round(
            abs(
                final.position_m -
                destination
            ),
            digits=1
        ),
        " m"
    )

    println(
        "=========================================="
    )

end

end







using .AutonomousRail

train =
    Train(
        400_000.0,
        10.0,
        0.15,
        0.0015,
        500_000.0,
        700_000.0,
        320 / 3.6,
        0.8,
        1.2
    )


track = TrackSegment[

    TrackSegment(
        0.0,
        10_000.0,
        285 / 3.6,
        0.000,
        285 / 3.6
    ),

    TrackSegment(
        10_000.0,
        30_000.0,
        300 / 3.6,
        0.001,
        300 / 3.6
    ),

    TrackSegment(
        30_000.0,
        50_000.0,
        320 / 3.6,
        -0.001,
        320 / 3.6
    ),

    TrackSegment(
        50_000.0,
        60_000.0,
        250 / 3.6,
        0.000,
        250 / 3.6
    )
]


trajectory =
    fastest_trajectory(
        train,
        track,
        0.0,
        60_000.0
    )


report(
    trajectory,
    60_000.0
)







module RailThermalOptimizer

using LinearAlgebra
using Statistics
using Random

# ============================================================
# CONSTANTS
# ============================================================

const AMBIENT_REFERENCE = 25.0

const MOTOR_LIMIT = 140.0
const INVERTER_LIMIT = 105.0
const TRANSFORMER_LIMIT = 120.0

# ============================================================
# TRAIN THERMAL SYSTEM
# ============================================================

mutable struct ThermalState

    motor_temp_c::Float64
    inverter_temp_c::Float64
    transformer_temp_c::Float64

    battery_temp_c::Float64

    coolant_temp_c::Float64

end


struct TrainThermalModel

    motor_mass_kg::Float64
    inverter_mass_kg::Float64
    transformer_mass_kg::Float64
    battery_mass_kg::Float64

    motor_heat_capacity::Float64
    inverter_heat_capacity::Float64
    transformer_heat_capacity::Float64
    battery_heat_capacity::Float64

    motor_cooling_capacity_kw::Float64
    inverter_cooling_capacity_kw::Float64
    transformer_cooling_capacity_kw::Float64
    battery_cooling_capacity_kw::Float64

    ambient_cooling_coeff::Float64

end


struct OperatingState

    speed_ms::Float64
    traction_power_kw::Float64

    acceleration_ms2::Float64

    ambient_temp_c::Float64
    wind_ms::Float64

    passenger_load::Float64

end


# ============================================================
# COOLING SYSTEM
# ============================================================

struct CoolingCommand

    motor_cooling::Float64
    inverter_cooling::Float64
    transformer_cooling::Float64
    battery_cooling::Float64

end


function CoolingCommand(level::Float64)

    level = clamp(level, 0.0, 1.0)

    CoolingCommand(
        level,
        level,
        level,
        level
    )

end


# ============================================================
# HEAT GENERATION
# ============================================================

function motor_heat_generation(
    power_kw::Float64
)

    # Simplified traction-motor loss model.
    #
    # At low power, fixed losses dominate.
    # At high power, resistive losses increase.

    fixed_loss = 2.0

    variable_loss =
        0.018 *
        power_kw^2 /
        1000.0

    return fixed_loss +
           variable_loss

end


function inverter_heat_generation(
    power_kw::Float64
)

    switching_loss =
        0.008 *
        power_kw

    conduction_loss =
        0.00003 *
        power_kw^2

    switching_loss +
    conduction_loss

end


function transformer_heat_generation(
    power_kw::Float64
)

    copper_loss =
        0.004 *
        power_kw

    core_loss =
        1.0

    copper_loss +
    core_loss

end


function battery_heat_generation(
    power_kw::Float64
)

    0.01 *
    power_kw^2 /
    1000.0

end


# ============================================================
# AIRFLOW COOLING
# ============================================================

function airflow_factor(
    speed_ms::Float64,
    wind_ms::Float64
)

    relative_speed =
        max(
            speed_ms +
            wind_ms,
            0.0
        )

    # Increasing train speed improves passive airflow.
    return 1.0 +
           0.02 *
           sqrt(relative_speed)

end


# ============================================================
# NATURAL COOLING
# ============================================================

function natural_cooling(
    temperature_c::Float64,
    ambient_c::Float64,
    airflow::Float64,
    coefficient::Float64
)

    max(
        temperature_c -
        ambient_c,
        0.0
    ) *
    coefficient *
    airflow

end


# ============================================================
# THERMAL DERIVATIVE
# ============================================================

function thermal_rate(
    temperature_c::Float64,
    heat_kw::Float64,
    cooling_kw::Float64,
    heat_capacity::Float64,
    ambient_c::Float64,
    airflow::Float64,
    natural_coeff::Float64
)

    passive =
        natural_cooling(
            temperature_c,
            ambient_c,
            airflow,
            natural_coeff
        )

    net_heat =
        heat_kw -
        cooling_kw -
        passive

    net_heat /
    heat_capacity

end


# ============================================================
# THERMAL SIMULATION
# ============================================================

function simulate_thermal_step(
    model::TrainThermalModel,
    state::ThermalState,
    operation::OperatingState,
    cooling::CoolingCommand,
    dt::Float64
)

    airflow =
        airflow_factor(
            operation.speed_ms,
            operation.wind_ms
        )

    # -----------------------------------------------
    # Heat generation
    # -----------------------------------------------

    motor_heat =
        motor_heat_generation(
            operation.traction_power_kw
        )

    inverter_heat =
        inverter_heat_generation(
            operation.traction_power_kw
        )

    transformer_heat =
        transformer_heat_generation(
            operation.traction_power_kw
        )

    battery_heat =
        battery_heat_generation(
            max(
                operation.traction_power_kw,
                0.0
            )
        )

    # -----------------------------------------------
    # Cooling
    # -----------------------------------------------

    motor_cooling =
        cooling.motor_cooling *
        model.motor_cooling_capacity_kw

    inverter_cooling =
        cooling.inverter_cooling *
        model.inverter_cooling_capacity_kw

    transformer_cooling =
        cooling.transformer_cooling *
        model.transformer_cooling_capacity_kw

    battery_cooling =
        cooling.battery_cooling *
        model.battery_cooling_capacity_kw

    # -----------------------------------------------
    # Temperature derivatives
    # -----------------------------------------------

    motor_rate =
        thermal_rate(
            state.motor_temp_c,
            motor_heat,
            motor_cooling,
            model.motor_heat_capacity,
            operation.ambient_temp_c,
            airflow,
            model.ambient_cooling_coeff
        )

    inverter_rate =
        thermal_rate(
            state.inverter_temp_c,
            inverter_heat,
            inverter_cooling,
            model.inverter_heat_capacity,
            operation.ambient_temp_c,
            airflow,
            model.ambient_cooling_coeff
        )

    transformer_rate =
        thermal_rate(
            state.transformer_temp_c,
            transformer_heat,
            transformer_cooling,
            model.transformer_heat_capacity,
            operation.ambient_temp_c,
            airflow,
            model.ambient_cooling_coeff
        )

    battery_rate =
        thermal_rate(
            state.battery_temp_c,
            battery_heat,
            battery_cooling,
            model.battery_heat_capacity,
            operation.ambient_temp_c,
            airflow,
            model.ambient_cooling_coeff
        )

    # -----------------------------------------------
    # Integrate
    # -----------------------------------------------

    return ThermalState(

        state.motor_temp_c +
        motor_rate * dt,

        state.inverter_temp_c +
        inverter_rate * dt,

        state.transformer_temp_c +
        transformer_rate * dt,

        state.battery_temp_c +
        battery_rate * dt,

        state.coolant_temp_c
    )

end


# ============================================================
# FEATURE VECTOR
# ============================================================

function thermal_features(
    state::ThermalState,
    operation::OperatingState,
    cooling::CoolingCommand
)

    [

        state.motor_temp_c,
        state.inverter_temp_c,
        state.transformer_temp_c,
        state.battery_temp_c,

        operation.speed_ms,
        operation.traction_power_kw,

        operation.acceleration_ms2,

        operation.ambient_temp_c,
        operation.wind_ms,

        operation.passenger_load,

        cooling.motor_cooling,
        cooling.inverter_cooling,
        cooling.transformer_cooling,
        cooling.battery_cooling

    ]

end


# ============================================================
# ONLINE ML THERMAL MODEL
# ============================================================

mutable struct ThermalPredictor

    weights_motor::Vector{Float64}
    weights_inverter::Vector{Float64}
    weights_transformer::Vector{Float64}
    weights_battery::Vector{Float64}

    bias_motor::Float64
    bias_inverter::Float64
    bias_transformer::Float64
    bias_battery::Float64

    learning_rate::Float64

    observations::Int

end


function ThermalPredictor(
    number_features::Int
)

    ThermalPredictor(

        zeros(number_features),
        zeros(number_features),
        zeros(number_features),
        zeros(number_features),

        0.0,
        0.0,
        0.0,
        0.0,

        0.0001,

        0
    )

end


# ============================================================
# ML PREDICTION
# ============================================================

function predict_temperatures(
    predictor::ThermalPredictor,
    features::Vector{Float64}
)

    motor =
        dot(
            predictor.weights_motor,
            features
        ) +
        predictor.bias_motor

    inverter =
        dot(
            predictor.weights_inverter,
            features
        ) +
        predictor.bias_inverter

    transformer =
        dot(
            predictor.weights_transformer,
            features
        ) +
        predictor.bias_transformer

    battery =
        dot(
            predictor.weights_battery,
            features
        ) +
        predictor.bias_battery

    return (
        motor = motor,
        inverter = inverter,
        transformer = transformer,
        battery = battery
    )

end


# ============================================================
# ONLINE TRAINING
# ============================================================

function update!(
    predictor::ThermalPredictor,
    features::Vector{Float64},
    actual::ThermalState
)

    prediction =
        predict_temperatures(
            predictor,
            features
        )

    # Normalise update magnitude.

    scale =
        dot(
            features,
            features
        ) + 1.0

    rate =
        predictor.learning_rate /
        scale

    error_motor =
        prediction.motor -
        actual.motor_temp_c

    error_inverter =
        prediction.inverter -
        actual.inverter_temp_c

    error_transformer =
        prediction.transformer -
        actual.transformer_temp_c

    error_battery =
        prediction.battery -
        actual.battery_temp_c

    predictor.weights_motor .-=
        rate *
        error_motor *
        features

    predictor.weights_inverter .-=
        rate *
        error_inverter *
        features

    predictor.weights_transformer .-=
        rate *
        error_transformer *
        features

    predictor.weights_battery .-=
        rate *
        error_battery *
        features

    predictor.bias_motor -=
        rate *
        error_motor

    predictor.bias_inverter -=
        rate *
        error_inverter

    predictor.bias_transformer -=
        rate *
        error_transformer

    predictor.bias_battery -=
        rate *
        error_battery

    predictor.observations += 1

end


# ============================================================
# THERMAL RISK
# ============================================================

function thermal_risk(
    predicted::NamedTuple
)

    motor_risk =
        max(
            (
                predicted.motor -
                MOTOR_LIMIT
            ) / 10.0,
            0.0
        )

    inverter_risk =
        max(
            (
                predicted.inverter -
                INVERTER_LIMIT
            ) / 10.0,
            0.0
        )

    transformer_risk =
        max(
            (
                predicted.transformer -
                TRANSFORMER_LIMIT
            ) / 10.0,
            0.0
        )

    return (
        motor = motor_risk,
        inverter = inverter_risk,
        transformer = transformer_risk,

        total =
            motor_risk +
            inverter_risk +
            transformer_risk
    )

end


# ============================================================
# COOLING ENERGY COST
# ============================================================

function cooling_energy_cost(
    cooling::CoolingCommand
)

    total =
        cooling.motor_cooling +
        cooling.inverter_cooling +
        cooling.transformer_cooling +
        cooling.battery_cooling

    # Cooling itself consumes electricity.

    return 0.15 *
           total^2

end


# ============================================================
# PREDICTIVE THERMAL OPTIMISER
# ============================================================

function optimise_cooling(
    model::TrainThermalModel,
    predictor::ThermalPredictor,
    state::ThermalState,
    operation::OperatingState;

    horizon_s = 120.0,
    dt = 5.0
)

    best_command =
        CoolingCommand(0.0)

    best_cost =
        Inf

    # Search possible cooling levels.

    for level in
        range(
            0.0,
            1.0,
            length = 11
        )

        command =
            CoolingCommand(
                level
            )

        simulated =
            state

        predicted =
            nothing

        energy_cost =
            0.0

        max_risk =
            0.0

        elapsed = 0.0

        while elapsed < horizon_s

            simulated =
                simulate_thermal_step(
                    model,
                    simulated,
                    operation,
                    command,
                    dt
                )

            features =
                thermal_features(
                    simulated,
                    operation,
                    command
                )

            predicted =
                predict_temperatures(
                    predictor,
                    features
                )

            risk =
                thermal_risk(
                    predicted
                )

            max_risk =
                max(
                    max_risk,
                    risk.total
                )

            energy_cost +=
                cooling_energy_cost(
                    command
                ) *
                dt

            elapsed += dt

        end

        # ----------------------------------------------------
        # Optimisation objective
        # ----------------------------------------------------

        cost =
            energy_cost +

            1000.0 *
            max_risk +

            5.0 *
            level

        if cost < best_cost

            best_cost =
                cost

            best_command =
                command

        end

    end

    return (
        command = best_command,
        cost = best_cost
    )

end


# ============================================================
# COMPLETE THERMAL CONTROL STEP
# ============================================================

function control_step!(
    model::TrainThermalModel,
    predictor::ThermalPredictor,
    thermal::ThermalState,
    operation::OperatingState;
    dt = 5.0
)

    decision =
        optimise_cooling(
            model,
            predictor,
            thermal,
            operation;
            horizon_s = 120.0,
            dt = dt
        )

    new_state =
        simulate_thermal_step(
            model,
            thermal,
            operation,
            decision.command,
            dt
        )

    # Learn from actual measured response.

    x =
        thermal_features(
            thermal,
            operation,
            decision.command
        )

    update!(
        predictor,
        x,
        new_state
    )

    return (
        state = new_state,
        command = decision.command,
        cost = decision.cost
    )

end


# ============================================================
# THERMAL REPORT
# ============================================================

function report(
    state::ThermalState,
    predictor::ThermalPredictor
)

    println()
    println(
        "=========================================="
    )

    println(
        " PREDICTIVE THERMAL OPTIMISER"
    )

    println(
        "=========================================="
    )

    println(
        "Motor: ",
        round(
            state.motor_temp_c,
            digits = 2
        ),
        " °C"
    )

    println(
        "Inverter: ",
        round(
            state.inverter_temp_c,
            digits = 2
        ),
        " °C"
    )

    println(
        "Transformer: ",
        round(
            state.transformer_temp_c,
            digits = 2
        ),
        " °C"
    )

    println(
        "Battery: ",
        round(
            state.battery_temp_c,
            digits = 2
        ),
        " °C"
    )

    println(
        "ML observations: ",
        predictor.observations
    )

    println(
        "=========================================="
    )

end


end # module




