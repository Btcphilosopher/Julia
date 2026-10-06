# ================================================================
# DISTRIBUTED TRAIN BRAKING ARRAY OPTIMISER
# Julia 1.10+
#
# Concept:
#   - Train represented as N vehicle/mass nodes
#   - Each vehicle has independently controllable braking effort
#   - Coupler forces propagate braking loads through the train
#   - Optimiser distributes braking force across the train
#   - Objective balances:
#         1. stopping distance
#         2. braking time
#         3. coupler compression/tension
#         4. uneven braking
#
# This is a research/simulation model, NOT a safety-certified
# railway braking controller.
# ================================================================

using JuMP
using HiGHS
using LinearAlgebra
using Printf

# ---------------------------------------------------------------
# Vehicle definition
# ---------------------------------------------------------------

struct Vehicle
    mass::Float64              # kg
    brake_max::Float64         # N
    brake_rate::Float64        # N/s
    rolling_resistance::Float64
end

# ---------------------------------------------------------------
# Train
# ---------------------------------------------------------------

struct Train
    vehicles::Vector{Vehicle}
    coupler_max_compression::Float64
    coupler_max_tension::Float64
end

nv(train::Train) = length(train.vehicles)

# ---------------------------------------------------------------
# Example large train
#
# 200 vehicles × 100 tonnes = ~20,000 tonnes
# ---------------------------------------------------------------

function make_train(
    N::Int;
    mass_per_vehicle = 100_000.0,
    brake_force = 300_000.0,
    brake_rate = 600_000.0,
    rolling_resistance = 2_000.0
)

    vehicles = Vehicle[]

    for i in 1:N
        push!(
            vehicles,
            Vehicle(
                mass_per_vehicle,
                brake_force,
                brake_rate,
                rolling_resistance
            )
        )
    end

    return Train(
        vehicles,
        2.0e6,       # maximum coupler compression
        2.0e6        # maximum coupler tension
    )
end

# ---------------------------------------------------------------
# State vector
#
# x[i] = position of vehicle i
# v[i] = velocity of vehicle i
#
# Coupler force:
#
# F_c[i]
#
# acts between vehicle i and i+1.
# ---------------------------------------------------------------

mutable struct TrainState
    x::Vector{Float64}
    v::Vector{Float64}
    brake::Vector{Float64}
end

function initial_state(train::Train, speed::Float64)

    N = nv(train)

    # Vehicle length approximation
    vehicle_length = 25.0

    x = [
        (i - 1) * vehicle_length
        for i in 1:N
    ]

    v = fill(speed, N)

    brake = zeros(N)

    return TrainState(x, v, brake)
end

# ---------------------------------------------------------------
# Calculate coupler forces
#
# Simplified Kelvin-Voigt coupler model:
#
# F = k * extension + c * relative velocity
#
# Positive force = tension
# Negative force = compression
# ---------------------------------------------------------------

function coupler_forces(
    train::Train,
    state::TrainState;
    k = 5.0e6,
    c = 5.0e5,
    nominal_spacing = 25.0
)

    N = nv(train)

    F = zeros(N - 1)

    for i in 1:N-1

        extension =
            (state.x[i+1] - state.x[i]) -
            nominal_spacing

        relative_velocity =
            state.v[i+1] - state.v[i]

        F[i] =
            k * extension +
            c * relative_velocity
    end

    return F
end

# ---------------------------------------------------------------
# Calculate longitudinal acceleration
# ---------------------------------------------------------------

function acceleration(
    train::Train,
    state::TrainState,
    coupler::Vector{Float64}
)

    N = nv(train)

    a = zeros(N)

    for i in 1:N

        vehicle = train.vehicles[i]

        # Braking force
        Fbrake = state.brake[i]

        # Rolling resistance
        Fresist = vehicle.rolling_resistance

        # Forces from couplers
        Fc = 0.0

        if i > 1
            Fc += coupler[i-1]
        end

        if i < N
            Fc -= coupler[i]
        end

        a[i] =
            (-Fbrake - Fresist + Fc) /
            vehicle.mass
    end

    return a
end

# ---------------------------------------------------------------
# DISTRIBUTED BRAKING OPTIMISER
#
# Optimises instantaneous brake-force distribution.
#
# Important idea:
#
# Don't simply:
#
#     brake[i] = maximum
#
# Instead minimise a cost function containing:
#
#   Σ brake²
#   Σ (brake[i]-brake[i+1])²
#   Σ estimated coupler loading²
#
# This produces a much smoother braking wave.
# ---------------------------------------------------------------

function optimise_braking_array(
    train::Train,
    state::TrainState;
    target_deceleration = 0.5,
    smoothness_weight = 2.0,
    gradient_weight = 5.0,
    utilisation_weight = 0.2
)

    N = nv(train)

    masses = [
        v.mass for v in train.vehicles
    ]

    max_brakes = [
        v.brake_max for v in train.vehicles
    ]

    total_mass = sum(masses)

    # -----------------------------------------------------------
    # Required total braking force
    # -----------------------------------------------------------

    required_force =
        total_mass * target_deceleration

    # -----------------------------------------------------------
    # Optimisation model
    # -----------------------------------------------------------

    model = Model(HiGHS.Optimizer)

    set_silent(model)

    @variable(
        model,
        0 <= b[1:N] <= max_brakes
    )

    # Auxiliary variables for brake-force differences
    @variable(
        model,
        d[1:N-1] >= 0
    )

    # -----------------------------------------------------------
    # Total braking requirement
    # -----------------------------------------------------------

    @constraint(
        model,
        sum(b[i] for i in 1:N)
        >= required_force
    )

    # -----------------------------------------------------------
    # Smooth braking distribution
    # -----------------------------------------------------------

    for i in 1:N-1

        @constraint(
            model,
            d[i] >= b[i+1] - b[i]
        )

        @constraint(
            model,
            d[i] >= b[i] - b[i+1]
        )

    end

    # -----------------------------------------------------------
    # Objective
    #
    # 1. Penalise excessive braking
    # 2. Penalise abrupt changes
    # 3. Penalise unequal utilisation
    # -----------------------------------------------------------

    average_brake =
        required_force / N

    @objective(
        model,
        Min,

        # overall brake effort
        utilisation_weight *
        sum((b[i] - average_brake)^2 for i in 1:N)

        +

        # adjacent brake-force smoothness
        smoothness_weight *
        sum(d[i]^2 for i in 1:N-1)

        +

        # gradient penalty
        gradient_weight *
        sum((b[i] - average_brake)^2 for i in 1:N)
    )

    optimize!(model)

    if termination_status(model) != MOI.OPTIMAL
        error("Braking optimisation failed")
    end

    return value.(b)
end

# ---------------------------------------------------------------
# More advanced braking strategy:
#
# account for vehicle position in the train.
#
# The front of the train begins braking slightly earlier,
# then braking propagates toward the rear.
#
# This is useful for modelling brake-pipe propagation.
# ---------------------------------------------------------------

function propagation_weight(
    i,
    N;
    propagation_strength = 0.20
)

    # 0 at front
    # 1 at rear

    position = (i - 1) / max(N - 1, 1)

    return 1.0 - propagation_strength * position
end

function distributed_brake_command(
    train::Train,
    state::TrainState;
    target_deceleration = 0.5
)

    N = nv(train)

    optimal =
        optimise_braking_array(
            train,
            state;
            target_deceleration =
                target_deceleration
        )

    command = similar(optimal)

    for i in 1:N

        w =
            propagation_weight(i, N)

        command[i] =
            clamp(
                optimal[i] * w,
                0.0,
                train.vehicles[i].brake_max
            )
    end

    return command
end

# ---------------------------------------------------------------
# Dynamic simulation
# ---------------------------------------------------------------

function simulate_braking(
    train::Train;
    initial_speed = 25.0,
    dt = 0.02,
    simulation_time = 120.0,
    target_deceleration = 0.5
)

    state =
        initial_state(
            train,
            initial_speed
        )

    N = nv(train)

    steps =
        Int(
            simulation_time / dt
        )

    history_velocity =
        Vector{Vector{Float64}}()

    history_brake =
        Vector{Vector{Float64}}()

    history_coupler =
        Vector{Vector{Float64}}()

    time = Float64[]

    for step in 1:steps

        t = step * dt

        # -------------------------------------------------------
        # Optimise brake array
        # -------------------------------------------------------

        state.brake =
            distributed_brake_command(
                train,
                state;
                target_deceleration =
                    target_deceleration
            )

        # -------------------------------------------------------
        # Coupler dynamics
        # -------------------------------------------------------

        Fc =
            coupler_forces(
                train,
                state
            )

        # -------------------------------------------------------
        # Vehicle acceleration
        # -------------------------------------------------------

        a =
            acceleration(
                train,
                state,
                Fc
            )

        # -------------------------------------------------------
        # Integrate
        # -------------------------------------------------------

        for i in 1:N

            state.v[i] =
                max(
                    0.0,
                    state.v[i] + a[i] * dt
                )

            state.x[i] +=
                state.v[i] * dt
        end

        push!(
            history_velocity,
            copy(state.v)
        )

        push!(
            history_brake,
            copy(state.brake)
        )

        push!(
            history_coupler,
            copy(Fc)
        )

        push!(
            time,
            t
        )

        # -------------------------------------------------------
        # Stop when train has effectively stopped
        # -------------------------------------------------------

        if maximum(state.v) < 0.05
            break
        end
    end

    return (
        time = time,
        velocity = history_velocity,
        brake = history_brake,
        coupler = history_coupler,
        final_state = state
    )
end

# ---------------------------------------------------------------
# ANALYSIS FUNCTIONS
# ---------------------------------------------------------------

function maximum_coupler_force(result)

    maximum(
        abs.(reduce(
            vcat,
            result.coupler
        ))
    )
end

function stopping_distance(result)

    x =
        result.final_state.x

    initial_x =
        [0.0 for _ in x]

    return maximum(x) -
           minimum(initial_x)
end

# ---------------------------------------------------------------
# Example
# ---------------------------------------------------------------

train =
    make_train(
        200;
        mass_per_vehicle = 100_000.0,
        brake_force = 300_000.0
    )

println()
println("==============================================")
println(" DISTRIBUTED TRAIN BRAKING SIMULATION")
println("==============================================")
println()

@printf(
    "Vehicles:          %d\n",
    nv(train)
)

@printf(
    "Train mass:        %.1f tonnes\n",
    sum(v.mass for v in train.vehicles) / 1000
)

@printf(
    "Initial speed:     %.1f km/h\n",
    25.0 * 3.6
)

result =
    simulate_braking(
        train;
        initial_speed = 25.0,
        target_deceleration = 0.5
    )

println()

@printf(
    "Simulation time:   %.2f s\n",
    result.time[end]
)

@printf(
    "Maximum coupler:   %.0f kN\n",
    maximum_coupler_force(result) / 1000
)

println()
println("Braking optimisation complete.")

