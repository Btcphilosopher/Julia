using LinearAlgebra

# ============================================================
# AUTONOMOUS VEHICLE ACCELERATION OPTIMISER
# Julia prototype
# ============================================================

struct Vehicle
    mass::Float64                 # kg
    max_acceleration::Float64     # m/s²
    max_deceleration::Float64     # m/s²
    max_jerk::Float64             # m/s³
    max_speed::Float64             # m/s
end

struct VehicleState
    speed::Float64
    acceleration::Float64
end

struct AccelerationPlan
    acceleration::Vector{Float64}
    speed::Vector{Float64}
    cost::Float64
end


# ============================================================
# VEHICLE
# ============================================================

car = Vehicle(
    1800.0,     # mass
    3.0,        # maximum acceleration
    7.0,        # maximum braking
    4.0,        # maximum jerk
    55.0        # maximum speed (~198 km/h)
)


# ============================================================
# SPEED / ACCELERATION MODEL
# ============================================================

function predict_speed(
    speed,
    acceleration,
    dt
)

    return max(
        0.0,
        speed + acceleration * dt
    )
end


# ============================================================
# ENERGY COST
# ============================================================

function energy_cost(
    speed,
    acceleration,
    mass
)

    # Simplified longitudinal power model.
    #
    # Positive acceleration consumes energy.
    # Negative acceleration is treated as regenerative.

    if acceleration >= 0

        return (
            mass *
            acceleration *
            speed
        )

    else

        # Regeneration is not 100% efficient.
        regenerative_efficiency = 0.7

        return (
            mass *
            acceleration *
            speed *
            regenerative_efficiency
        )
    end
end


# ============================================================
# JERK COST
# ============================================================

function jerk_cost(
    previous_acceleration,
    acceleration,
    dt
)

    jerk =
        (acceleration -
         previous_acceleration) / dt

    return jerk^2
end


# ============================================================
# ACCELERATION COST FUNCTION
# ============================================================

function acceleration_cost(
    current_speed,
    target_speed,
    previous_acceleration,
    acceleration,
    dt,
    vehicle
)

    next_speed =
        predict_speed(
            current_speed,
            acceleration,
            dt
        )

    # Speed tracking
    speed_error =
        (target_speed - next_speed)^2

    # Smoothness
    smoothness =
        jerk_cost(
            previous_acceleration,
            acceleration,
            dt
        )

    # Energy
    energy =
        max(
            energy_cost(
                current_speed,
                acceleration,
                vehicle.mass
            ),
            0.0
        )

    return (
        20.0 * speed_error +
        2.0  * smoothness +
        0.0001 * energy
    )
end


# ============================================================
# OPTIMISE ONE CONTROL STEP
# ============================================================

function optimise_acceleration(
    state::VehicleState,
    target_speed::Float64,
    vehicle::Vehicle;
    dt = 0.05
)

    candidate_accelerations =
        range(
            -vehicle.max_deceleration,
            vehicle.max_acceleration,
            length=61
        )

    best_acceleration = 0.0
    best_cost = Inf

    for acceleration in
        candidate_accelerations

        # Physical speed constraint
        predicted =
            predict_speed(
                state.speed,
                acceleration,
                dt
            )

        if predicted >
           vehicle.max_speed

            continue
        end

        # Jerk constraint
        jerk =
            abs(
                acceleration -
                state.acceleration
            ) / dt

        if jerk >
           vehicle.max_jerk

            continue
        end

        cost =
            acceleration_cost(
                state.speed,
                target_speed,
                state.acceleration,
                acceleration,
                dt,
                vehicle
            )

        if cost < best_cost

            best_cost = cost
            best_acceleration = acceleration

        end
    end

    return best_acceleration
end


# ============================================================
# SPEED CONTROLLER
# ============================================================

function optimise_speed!(
    state::VehicleState,
    target_speed::Float64,
    vehicle::Vehicle;
    dt = 0.05
)

    acceleration =
        optimise_acceleration(
            state,
            target_speed,
            vehicle;
            dt
        )

    state.acceleration =
        acceleration

    state.speed =
        predict_speed(
            state.speed,
            acceleration,
            dt
        )

    return acceleration
end


# ============================================================
# EXAMPLE
# ============================================================

state =
    VehicleState(
        10.0,      # initial speed
        0.0
    )

target_speed =
    30.0          # ~108 km/h


# ============================================================
# SIMULATION
# ============================================================

for t in 0.0:0.05:15.0

    acceleration =
        optimise_speed!(
            state,
            target_speed,
            car
        )

    println(
        "t=",
        round(t, digits=2),
        " | speed=",
        round(state.speed, digits=2),
        " m/s | acceleration=",
        round(acceleration, digits=2),
        " m/s²"
    )

    if abs(
        state.speed -
        target_speed
    ) < 0.05

        println("Target speed reached.")
        break
    end
end
