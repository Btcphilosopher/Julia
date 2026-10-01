using LinearAlgebra

# ============================================================
# ADAPTIVE RIDE / SUSPENSION OPTIMISER
# Julia prototype
# ============================================================

struct Suspension
    sprung_mass::Float64
    unsprung_mass::Float64

    spring_rate::Float64
    tyre_rate::Float64
    damping::Float64

    max_force::Float64
    max_travel::Float64
end


struct RideState
    body_position::Float64
    body_velocity::Float64

    wheel_position::Float64
    wheel_velocity::Float64

    road_height::Float64
    road_velocity::Float64
end


# ============================================================
# VEHICLE SUSPENSION
# ============================================================

suspension = Suspension(

    360.0,       # sprung mass per corner
    45.0,        # unsprung mass

    28000.0,     # suspension spring N/m
    190000.0,    # tyre stiffness N/m
    1800.0,      # damping Ns/m

    5000.0,      # active actuator limit
    0.12         # suspension travel ±12 cm
)


# ============================================================
# ROAD PREVIEW
# ============================================================

function road_profile(x)

    # Example urban road:
    #
    # smooth surface
    # followed by speed bump
    # followed by pothole

    bump =
        0.06 *
        exp(
            -((x - 15.0) / 0.8)^2
        )

    pothole =
        -0.04 *
        exp(
            -((x - 30.0) / 0.5)^2
        )

    ripple =
        0.005 *
        sin(2π * x / 4.0)

    return (
        bump +
        pothole +
        ripple
    )
end


# ============================================================
# SUSPENSION DYNAMICS
# ============================================================

function suspension_dynamics(
    state::RideState,
    force::Float64,
    system::Suspension,
    dt::Float64
)

    relative_position =
        state.body_position -
        state.wheel_position

    relative_velocity =
        state.body_velocity -
        state.wheel_velocity

    spring_force =
        system.spring_rate *
        relative_position

    damper_force =
        system.damping *
        relative_velocity

    tyre_force =
        system.tyre_rate *
        (
            state.wheel_position -
            state.road_height
        )

    # Body acceleration
    body_acceleration =
        (
            -spring_force -
            damper_force +
            force
        ) /
        system.sprung_mass

    # Wheel acceleration
    wheel_acceleration =
        (
            spring_force +
            damper_force -
            force -
            tyre_force
        ) /
        system.unsprung_mass

    new_body_velocity =
        state.body_velocity +
        body_acceleration * dt

    new_wheel_velocity =
        state.wheel_velocity +
        wheel_acceleration * dt

    new_body_position =
        state.body_position +
        new_body_velocity * dt

    new_wheel_position =
        state.wheel_position +
        new_wheel_velocity * dt

    return RideState(
        new_body_position,
        new_body_velocity,

        new_wheel_position,
        new_wheel_velocity,

        state.road_height,
        state.road_velocity
    )
end


# ============================================================
# RIDE QUALITY COST
# ============================================================

function ride_cost(
    current::RideState,
    predicted::RideState,
    force::Float64,
    system::Suspension
)

    # Passenger comfort
    body_motion =
        predicted.body_velocity^2

    # Road holding
    tyre_deflection =
        (
            predicted.wheel_position -
            predicted.road_height
        )^2

    # Suspension travel
    suspension_travel =
        (
            predicted.body_position -
            predicted.wheel_position
        )^2

    # Actuator energy
    actuator_cost =
        force^2

    return (
        100.0 * body_motion +
        80.0  * tyre_deflection +
        40.0  * suspension_travel +
        0.00001 * actuator_cost
    )
end


# ============================================================
# OPTIMAL SUSPENSION FORCE
# ============================================================

function optimise_suspension(
    state::RideState,
    system::Suspension;
    dt = 0.01
)

    candidate_forces =
        range(
            -system.max_force,
            system.max_force,
            length=101
        )

    best_force = 0.0
    best_cost = Inf

    for force in candidate_forces

        predicted =
            suspension_dynamics(
                state,
                force,
                system,
                dt
            )

        travel =
            abs(
                predicted.body_position -
                predicted.wheel_position
            )

        # Never command beyond suspension travel
        if travel >
           system.max_travel

            continue
        end

        cost =
            ride_cost(
                state,
                predicted,
                force,
                system
            )

        if cost < best_cost

            best_cost = cost
            best_force = force

        end
    end

    return best_force, best_cost
end


# ============================================================
# ADAPTIVE RIDE CONTROLLER
# ============================================================

function ride_controller!(
    state::RideState,
    system::Suspension,
    road_x::Float64;
    dt = 0.01
)

    # Sensor / road-preview input
    road =
        road_profile(road_x)

    state.road_height = road

    # Optimise actuator force
    force, cost =
        optimise_suspension(
            state,
            system;
            dt
        )

    # Apply optimal suspension force
    new_state =
        suspension_dynamics(
            state,
            force,
            system,
            dt
        )

    return new_state, force, cost
end


# ============================================================
# SIMULATION
# ============================================================

state =
    RideState(
        0.0,
        0.0,

        0.0,
        0.0,

        0.0,
        0.0
    )


for t in 0.0:0.01:40.0

    # Vehicle travelling at approximately 15 m/s
    x = 15.0 * t

    state,
    force,
    cost =
        ride_controller!(
            state,
            suspension,
            x
        )

    if mod(round(Int, t * 100), 50) == 0

        println(
            "t=",
            round(t, digits=2),
            " | body=",
            round(state.body_position, digits=4),
            " m | body velocity=",
            round(state.body_velocity, digits=3),
            " m/s | actuator=",
            round(force),
            " N"
        )
    end
end
