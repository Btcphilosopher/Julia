# ============================================================
# GEAR SELECTION OPTIMISER
# Julia prototype
# ============================================================

struct Gearbox
    gears::Vector{Int}

    ratios::Vector{Float64}

    final_drive::Float64

    wheel_radius::Float64

    idle_rpm::Float64
    max_rpm::Float64

    shift_time::Float64
end


struct VehicleState
    speed::Float64          # m/s
    acceleration::Float64   # m/s²
    throttle::Float64       # 0–1
    engine_rpm::Float64

    current_gear::Int
end


# ============================================================
# GEARBOX
# ============================================================

gearbox = Gearbox(

    [1, 2, 3, 4, 5, 6, 7, 8],

    [
        4.70,
        3.13,
        2.10,
        1.67,
        1.29,
        1.00,
        0.84,
        0.67
    ],

    3.20,       # final drive

    0.34,       # wheel radius

    800.0,      # idle RPM
    6500.0,     # maximum RPM

    0.25        # shift time
)


# ============================================================
# ENGINE RPM
# ============================================================

function calculate_rpm(
    speed,
    gear,
    gearbox
)

    ratio =
        gearbox.ratios[gear]

    wheel_rpm =
        speed /
        (
            2π *
            gearbox.wheel_radius
        ) *
        60.0

    engine_rpm =
        wheel_rpm *
        ratio *
        gearbox.final_drive

    return engine_rpm
end


# ============================================================
# TORQUE MODEL
# ============================================================

function engine_torque(
    rpm,
    throttle
)

    # Simplified torque curve
    peak_torque = 400.0

    rpm_factor =
        exp(
            -(
                (rpm - 3500.0)^2 /
                (2 * 1800.0^2)
            )
        )

    return (
        peak_torque *
        rpm_factor *
        throttle
    )
end


# ============================================================
# WHEEL TORQUE
# ============================================================

function wheel_torque(
    rpm,
    gear,
    throttle,
    gearbox
)

    torque =
        engine_torque(
            rpm,
            throttle
        )

    return (
        torque *
        gearbox.ratios[gear] *
        gearbox.final_drive
    )
end


# ============================================================
# SHIFT COST
# ============================================================

function shift_cost(
    current_gear,
    candidate_gear
)

    if current_gear == candidate_gear
        return 0.0
    end

    # Penalise unnecessary shifts
    return 2.0 +
           0.5 *
           abs(
               candidate_gear -
               current_gear
           )
end


# ============================================================
# EFFICIENCY COST
# ============================================================

function efficiency_cost(
    rpm,
    throttle
)

    # Simplified ideal operating region.
    ideal_rpm = 2200.0

    rpm_penalty =
        (
            (rpm - ideal_rpm) /
            2500.0
        )^2

    load_penalty =
        (throttle - 0.65)^2

    return (
        3.0 * rpm_penalty +
        1.0 * load_penalty
    )
end


# ============================================================
# RPM SAFETY COST
# ============================================================

function rpm_cost(
    rpm,
    gearbox
)

    if rpm > gearbox.max_rpm

        return 1e9

    elseif rpm < gearbox.idle_rpm

        return 100.0

    end

    return 0.0
end


# ============================================================
# ACCELERATION COST
# ============================================================

function acceleration_cost(
    torque
)

    # Higher available wheel torque is desirable
    # when the driver requests acceleration.

    return 1.0 /
           max(torque, 1.0)
end


# ============================================================
# TOTAL GEAR COST
# ============================================================

function gear_cost(
    state,
    candidate_gear,
    gearbox
)

    rpm =
        calculate_rpm(
            state.speed,
            candidate_gear,
            gearbox
        )

    torque =
        wheel_torque(
            rpm,
            candidate_gear,
            state.throttle,
            gearbox
        )

    cost = 0.0

    # Efficiency
    cost +=
        efficiency_cost(
            rpm,
            state.throttle
        )

    # Safety
    cost +=
        rpm_cost(
            rpm,
            gearbox
        )

    # Acceleration capability
    cost +=
        acceleration_cost(
            torque
        )

    # Shift penalty
    cost +=
        shift_cost(
            state.current_gear,
            candidate_gear
        )

    return cost
end


# ============================================================
# OPTIMAL GEAR
# ============================================================

function optimise_gear(
    state::VehicleState,
    gearbox::Gearbox
)

    best_gear =
        state.current_gear

    best_cost =
        Inf

    for gear in gearbox.gears

        cost =
            gear_cost(
                state,
                gear,
                gearbox
            )

        if cost < best_cost

            best_cost = cost
            best_gear = gear

        end
    end

    return best_gear, best_cost
end


# ============================================================
# SHIFT HYSTERESIS
# ============================================================

function should_shift(
    current_gear,
    optimal_gear,
    current_cost,
    optimal_cost
)

    # Prevent gear hunting.

    if current_gear == optimal_gear
        return false
    end

    improvement =
        current_cost -
        optimal_cost

    return improvement > 1.0
end


# ============================================================
# GEARBOX CONTROLLER
# ============================================================

function transmission_controller!(
    state,
    gearbox
)

    optimal_gear,
    optimal_cost =
        optimise_gear(
            state,
            gearbox
        )

    current_cost =
        gear_cost(
            state,
            state.current_gear,
            gearbox
        )

    if should_shift(
        state.current_gear,
        optimal_gear,
        current_cost,
        optimal_cost
    )

        println(
            "SHIFT: ",
            state.current_gear,
            " → ",
            optimal_gear
        )

        state.current_gear =
            optimal_gear
    end

    state.engine_rpm =
        calculate_rpm(
            state.speed,
            state.current_gear,
            gearbox
        )

    return state.current_gear
end


# ============================================================
# EXAMPLE
# ============================================================

state =
    VehicleState(
        20.0,      # speed
        1.5,       # acceleration
        0.65,      # throttle
        0.0,
        3          # current gear
    )


# ============================================================
# SIMULATION
# ============================================================

for t in 0.0:0.5:20.0

    # Example changing driver demand
    state.throttle =
        0.45 +
        0.25 *
        sin(t / 3.0)

    transmission_controller!(
        state,
        gearbox
    )

    println(
        "t=",
        round(t, digits=1),
        " | speed=",
        round(state.speed, digits=1),
        " m/s | gear=",
        state.current_gear,
        " | RPM=",
        round(state.engine_rpm),
        " | throttle=",
        round(state.throttle, digits=2)
    )
end

