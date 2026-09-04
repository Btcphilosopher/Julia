module RailDoorOptimizer

using Statistics
using Printf

# ============================================================
# ENUMS
# ============================================================

@enum DoorState begin
    CLOSED
    UNLOCKING
    OPENING
    OPEN
    CLOSING
    LOCKING
    OBSTRUCTION
    FAULT
end


# ============================================================
# DOOR MODEL
# ============================================================

mutable struct Door
    id::Int

    width_m::Float64

    # Mechanical characteristics
    mass_kg::Float64
    max_velocity_ms::Float64
    max_acceleration_ms2::Float64
    max_deceleration_ms2::Float64

    # Control characteristics
    unlock_time_s::Float64
    lock_time_s::Float64

    sensor_latency_s::Float64
    controller_latency_s::Float64

    # Safety limits
    obstacle_detection_time_s::Float64
    minimum_warning_time_s::Float64

    # State
    state::DoorState
    position_m::Float64
    velocity_ms::Float64

    cycle_time_s::Float64
end


# ============================================================
# TRAIN DOOR SYSTEM
# ============================================================

mutable struct DoorSystem

    doors::Vector{Door}

    commanded_open_time_s::Float64
    commanded_close_time_s::Float64

    synchronisation_tolerance_s::Float64

    passenger_flow_rate::Float64

    door_cycle_count::Int
end


# ============================================================
# DOOR PHYSICS
# ============================================================

function trapezoidal_move_time(
    distance::Float64,
    vmax::Float64,
    acceleration::Float64,
    deceleration::Float64
)

    # Time required to reach maximum velocity
    t_acc = vmax / acceleration
    t_dec = vmax / deceleration

    d_acc = 0.5 * acceleration * t_acc^2
    d_dec = 0.5 * deceleration * t_dec^2

    # Door cannot reach vmax
    # if the travel distance is too short.

    if d_acc + d_dec >= distance

        v_peak = sqrt(
            2.0 * distance /
            (
                1.0 / acceleration +
                1.0 / deceleration
            )
        )

        t_acc = v_peak / acceleration
        t_dec = v_peak / deceleration

        return t_acc + t_dec
    end

    cruise_distance =
        distance - d_acc - d_dec

    t_cruise =
        cruise_distance / vmax

    return t_acc + t_cruise + t_dec
end


# ============================================================
# OPENING CYCLE
# ============================================================

function calculate_open_time(
    door::Door
)

    movement = trapezoidal_move_time(
        door.width_m,
        door.max_velocity_ms,
        door.max_acceleration_ms2,
        door.max_deceleration_ms2
    )

    return (
        door.controller_latency_s +
        door.unlock_time_s +
        movement +
        door.sensor_latency_s
    )
end


# ============================================================
# CLOSING CYCLE
# ============================================================

function calculate_close_time(
    door::Door
)

    movement = trapezoidal_move_time(
        door.width_m,
        door.max_velocity_ms,
        door.max_acceleration_ms2,
        door.max_deceleration_ms2
    )

    return (
        door.controller_latency_s +
        door.minimum_warning_time_s +
        movement +
        door.sensor_latency_s +
        door.lock_time_s
    )
end


# ============================================================
# COMPLETE CYCLE
# ============================================================

function calculate_cycle_time(
    door::Door,
    dwell_time_s::Float64
)

    open_time =
        calculate_open_time(door)

    close_time =
        calculate_close_time(door)

    return (
        open_time +
        dwell_time +
        close_time
    )
end


# ============================================================
# DOOR SIMULATION
# ============================================================

function simulate_open!(
    door::Door,
    dt::Float64 = 0.01
)

    door.state = UNLOCKING

    t = 0.0

    while t < door.unlock_time_s
        t += dt
    end

    door.state = OPENING

    distance = door.width_m

    movement_time = trapezoidal_move_time(
        distance,
        door.max_velocity_ms,
        door.max_acceleration_ms2,
        door.max_deceleration_ms2
    )

    t = 0.0

    while t < movement_time

        # Simplified position model
        fraction =
            min(1.0, t / movement_time)

        door.position_m =
            fraction * door.width_m

        t += dt
    end

    door.position_m = door.width_m

    door.velocity_ms = 0.0
    door.state = OPEN

    return movement_time
end


function simulate_close!(
    door::Door,
    dt::Float64 = 0.01
)

    door.state = CLOSING

    movement_time = trapezoidal_move_time(
        door.width_m,
        door.max_velocity_ms,
        door.max_acceleration_ms2,
        door.max_deceleration_ms2
    )

    t = 0.0

    while t < movement_time

        fraction =
            min(1.0, t / movement_time)

        door.position_m =
            door.width_m *
            (1.0 - fraction)

        t += dt
    end

    door.position_m = 0.0

    door.velocity_ms = 0.0

    door.state = LOCKING

    t = 0.0

    while t < door.lock_time_s
        t += dt
    end

    door.state = CLOSED

    return movement_time
end


# ============================================================
# OBSTACLE RESPONSE
# ============================================================

function obstacle_response!(
    door::Door
)

    door.state = OBSTRUCTION

    door.velocity_ms = 0.0

    # Safety response:
    # stop movement rather than trying
    # to force the door through the obstacle.

    return (
        detected = true,
        response_time =
            door.obstacle_detection_time_s,
        reopened = true
    )
end


# ============================================================
# PARALLEL DOOR OPERATION
# ============================================================

function parallel_open_time(
    system::DoorSystem
)

    times = [
        calculate_open_time(door)
        for door in system.doors
    ]

    return maximum(times)
end


function parallel_close_time(
    system::DoorSystem
)

    times = [
        calculate_close_time(door)
        for door in system.doors
    ]

    return maximum(times)
end


# ============================================================
# TRAIN DWELL TIME
# ============================================================

function station_dwell_time(
    system::DoorSystem,
    passenger_exchange_time_s::Float64
)

    open_time =
        parallel_open_time(system)

    close_time =
        parallel_close_time(system)

    return (
        open_time +
        passenger_exchange_time_s +
        close_time
    )
end


# ============================================================
# PERFORMANCE OPTIMIZER
# ============================================================

struct DoorOptimizationResult

    velocity_ms::Float64
    acceleration_ms2::Float64

    opening_time_s::Float64
    closing_time_s::Float64

    total_door_cycle_s::Float64

    passenger_exchange_s::Float64

    total_dwell_s::Float64

    status::String
end


function evaluate_configuration(
    system::DoorSystem,
    velocity_ms::Float64,
    acceleration_ms2::Float64,
    passenger_exchange_s::Float64
)

    # Preserve original parameters
    original_velocity = [
        d.max_velocity_ms
        for d in system.doors
    ]

    original_acceleration = [
        d.max_acceleration_ms2
        for d in system.doors
    ]

    # Apply test configuration
    for door in system.doors

        door.max_velocity_ms =
            velocity_ms

        door.max_acceleration_ms2 =
            acceleration_ms2
    end

    open_time =
        parallel_open_time(system)

    close_time =
        parallel_close_time(system)

    cycle =
        open_time +
        passenger_exchange_s +
        close_time

    # Example safety constraint:
    #
    # Never allow automatic closing warning
    # to be reduced below the configured minimum.
    safe = all(
        d.minimum_warning_time_s >= 2.0
        for d in system.doors
    )

    status =
        safe ? "PASS" : "HOLD"

    # Restore
    for (i, door) in enumerate(system.doors)

        door.max_velocity_ms =
            original_velocity[i]

        door.max_acceleration_ms2 =
            original_acceleration[i]
    end

    return DoorOptimizationResult(
        velocity_ms,
        acceleration_ms2,
        open_time,
        close_time,
        cycle,
        passenger_exchange_s,
        cycle,
        status
    )
end


# ============================================================
# GRID SEARCH
# ============================================================

function optimize_doors(
    system::DoorSystem;

    velocity_range =
        0.35:0.05:0.80,

    acceleration_range =
        0.50:0.25:2.50,

    passenger_exchange_s = 18.0
)

    candidates =
        DoorOptimizationResult[]

    for velocity in velocity_range

        for acceleration in acceleration_range

            result =
                evaluate_configuration(
                    system,
                    velocity,
                    acceleration,
                    passenger_exchange_s
                )

            if result.status == "PASS"

                push!(
                    candidates,
                    result
                )
            end
        end
    end

    if isempty(candidates)
        error(
            "No configuration satisfied the constraints."
        )
    end

    sort!(
        candidates,
        by = x -> x.total_dwell_s
    )

    return candidates
end


# ============================================================
# ENERGY ESTIMATE
# ============================================================

function door_energy(
    door::Door,
    cycle_time_s::Float64
)

    # Very simplified actuator-energy model.
    #
    # Real implementation would use:
    # motor torque,
    # gearbox efficiency,
    # seal friction,
    # door acceleration,
    # aerodynamic effects,
    # controller losses.

    kinetic_energy =
        0.5 *
        door.mass_kg *
        door.max_velocity_ms^2

    return (
        kinetic_energy *
        2.0 /
        max(cycle_time_s, 0.01)
    )
end


# ============================================================
# REPORTING
# ============================================================

function report(
    result::DoorOptimizationResult
)

    println()
    println("=" ^ 70)
    println("RAIL DOOR PERFORMANCE OPTIMISER")
    println("=" ^ 70)

    @printf(
        "Door velocity:          %.2f m/s\n",
        result.velocity_ms
    )

    @printf(
        "Door acceleration:      %.2f m/s²\n",
        result.acceleration_ms2
    )

    @printf(
        "Opening time:           %.2f s\n",
        result.opening_time_s
    )

    @printf(
        "Closing time:           %.2f s\n",
        result.closing_time_s
    )

    @printf(
        "Passenger exchange:     %.2f s\n",
        result.passenger_exchange_s
    )

    @printf(
        "Total dwell:            %.2f s\n",
        result.total_dwell_s
    )

    println(
        "Engineering status:     ",
        result.status
    )

    println("=" ^ 70)
end


# ============================================================
# FACTORY
# ============================================================

function create_train_doors(
    number_of_doors::Int = 16
)

    doors = Door[]

    for i in 1:number_of_doors

        push!(
            doors,

            Door(
                i,

                1.30,       # width

                120.0,      # mass

                0.55,       # max velocity

                1.20,       # acceleration

                1.20,       # deceleration

                0.25,       # unlock

                0.25,       # lock

                0.05,       # sensor latency

                0.02,       # controller latency

                0.10,       # obstacle response

                2.0,        # closing warning

                CLOSED,

                0.0,

                0.0,

                0.0
            )
        )
    end

    return DoorSystem(
        doors,

        0.0,
        0.0,

        0.10,

        1.0,

        0
    )
end


# ============================================================
# DEMONSTRATION
# ============================================================

function main()

    system =
        create_train_doors(16)

    println()
    println(
        "RAILBOOST DOOR SYSTEM"
    )

    println(
        "Optimising ",
        length(system.doors),
        " passenger doors"
    )

    # --------------------------------------------------------
    # Baseline
    # --------------------------------------------------------

    baseline =
        evaluate_configuration(
            system,
            0.55,
            1.20,
            18.0
        )

    println()
    println("BASELINE")
    report(baseline)

    # --------------------------------------------------------
    # Optimisation
    # --------------------------------------------------------

    results =
        optimize_doors(
            system,

            velocity_range =
                0.40:0.05:0.80,

            acceleration_range =
                0.75:0.25:2.50,

            passenger_exchange_s =
                18.0
        )

    best = results[1]

    println()
    println("OPTIMISED CONFIGURATION")
    report(best)

    # --------------------------------------------------------
    # Show top candidates
    # --------------------------------------------------------

    println()
    println("=" ^ 70)
    println("TOP CONFIGURATIONS")
    println("=" ^ 70)

    for result in results[1:min(10, length(results))]

        @printf(
            "v=%4.2f m/s | a=%4.2f m/s² | "
            "cycle=%6.2f s | %s\n",

            result.velocity_ms,

            result.acceleration_ms2,

            result.total_dwell_s,

            result.status
        )
    end

    # --------------------------------------------------------
    # Energy estimate
    # --------------------------------------------------------

    energy =
        door_energy(
            system.doors[1],
            best.total_dwell_s
        )

    println()

    @printf(
        "Estimated actuator power proxy: %.1f W\n",
        energy
    )

    println()
    println(
        "Optimisation complete."
    )
end


end # module


using .RailDoorOptimizer

RailDoorOptimizer.main()
