using LinearAlgebra
using Statistics

# ============================================================
# AUREOM VEHICLE AI
# FOUR-WHEEL OPTIMISATION ENGINE
#
# Simulation / vehicle-dynamics research prototype
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

struct WheelConfig

    mass::Float64
    wheel_radius::Float64
    wheel_inertia::Float64

    wheelbase::Float64
    front_track::Float64
    rear_track::Float64

    cg_height::Float64
    cg_longitudinal::Float64

    gravity::Float64

    max_brake_torque::Float64
    max_drive_torque::Float64

    nominal_pressure_bar::Float64
    minimum_pressure_bar::Float64
    maximum_pressure_bar::Float64

    tyre_mu_dry::Float64
    tyre_mu_wet::Float64
    tyre_mu_snow::Float64

    dt::Float64
end


function create_wheel_config()

    WheelConfig(
        1900.0,
        0.33,
        2.2,

        2.85,
        1.62,
        1.60,

        0.55,
        1.35,

        9.81,

        4500.0,
        5000.0,

        2.5,
        1.8,
        3.0,

        1.05,
        0.70,
        0.35,

        0.01
    )

end


# ============================================================
# WHEEL IDENTIFIERS
# ============================================================

@enum WheelID begin
    FL
    FR
    RL
    RR
end


# ============================================================
# INDIVIDUAL WHEEL STATE
# ============================================================

mutable struct WheelState

    id::WheelID

    angular_velocity::Float64
    vehicle_speed::Float64

    steering_angle::Float64

    longitudinal_slip::Float64
    lateral_slip_angle::Float64

    vertical_load::Float64

    longitudinal_force::Float64
    lateral_force::Float64

    drive_torque::Float64
    brake_torque::Float64

    tyre_pressure_bar::Float64
    tyre_temperature_c::Float64

    tyre_grip::Float64

    contact_confidence::Float64
end


# ============================================================
# FOUR-WHEEL VEHICLE STATE
# ============================================================

mutable struct VehicleWheelState

    speed::Float64

    longitudinal_acceleration::Float64
    lateral_acceleration::Float64

    yaw_rate::Float64

    steering_angle::Float64

    road_friction::Float64

    road_gradient::Float64

    load_transfer_longitudinal::Float64
    load_transfer_lateral::Float64

    wheels::Vector{WheelState}
end


# ============================================================
# WHEEL COMMAND
# ============================================================

struct WheelCommand

    drive_torque::Float64
    brake_torque::Float64

    target_slip::Float64

    target_force_x::Float64
    target_force_y::Float64

    available_grip::Float64
end


# ============================================================
# BASIC UTILITIES
# ============================================================

clamp01(x) =
    clamp(x, 0.0, 1.0)


function sign_safe(x)

    if x > 0.0
        return 1.0
    elseif x < 0.0
        return -1.0
    else
        return 0.0
    end

end


# ============================================================
# STATIC AXLE LOAD
# ============================================================

function static_axle_loads(
    cfg::WheelConfig
)

    front =
        cfg.mass *
        cfg.gravity *
        (
            1.0 -
            cfg.cg_longitudinal /
            cfg.wheelbase
        )

    rear =
        cfg.mass *
        cfg.gravity -
        front

    return front, rear

end


# ============================================================
# STATIC FOUR-WHEEL LOADS
# ============================================================

function static_wheel_loads(
    cfg::WheelConfig
)

    front, rear =
        static_axle_loads(cfg)

    return Dict(
        FL => front / 2.0,
        FR => front / 2.0,
        RL => rear / 2.0,
        RR => rear / 2.0
    )

end


# ============================================================
# LONGITUDINAL LOAD TRANSFER
# ============================================================

function longitudinal_load_transfer(
    state::VehicleWheelState,
    cfg::WheelConfig
)

    return (
        cfg.mass *
        state.longitudinal_acceleration *
        cfg.cg_height /
        cfg.wheelbase
    )

end


# ============================================================
# LATERAL LOAD TRANSFER
# ============================================================

function lateral_load_transfer(
    state::VehicleWheelState,
    cfg::WheelConfig
)

    average_track =
        (
            cfg.front_track +
            cfg.rear_track
        ) / 2.0

    return (
        cfg.mass *
        state.lateral_acceleration *
        cfg.cg_height /
        average_track
    )

end


# ============================================================
# CALCULATE FOUR-WHEEL LOADS
# ============================================================

function calculate_wheel_loads!(
    state::VehicleWheelState,
    cfg::WheelConfig
)

    static =
        static_wheel_loads(cfg)

    longitudinal =
        longitudinal_load_transfer(
            state,
            cfg
        )

    lateral =
        lateral_load_transfer(
            state,
            cfg
        )

    # Front/rear load transfer
    front_longitudinal =
        longitudinal *
        (
            cfg.wheelbase -
            cfg.cg_longitudinal
        ) /
        cfg.wheelbase

    rear_longitudinal =
        longitudinal -
        front_longitudinal

    # Simplified lateral distribution
    front_lateral =
        lateral * 0.55

    rear_lateral =
        lateral * 0.45

    for wheel in state.wheels

        base =
            static[wheel.id]

        if wheel.id == FL

            wheel.vertical_load =
                base -
                front_longitudinal / 2.0 -
                front_lateral / 2.0

        elseif wheel.id == FR

            wheel.vertical_load =
                base -
                front_longitudinal / 2.0 +
                front_lateral / 2.0

        elseif wheel.id == RL

            wheel.vertical_load =
                base +
                rear_longitudinal / 2.0 -
                rear_lateral / 2.0

        elseif wheel.id == RR

            wheel.vertical_load =
                base +
                rear_longitudinal / 2.0 +
                rear_lateral / 2.0
        end

        wheel.vertical_load =
            max(
                wheel.vertical_load,
                50.0
            )
    end

end


# ============================================================
# LONGITUDINAL SLIP
# ============================================================

function calculate_longitudinal_slip!(
    wheel::WheelState,
    cfg::WheelConfig
)

    wheel_speed =
        wheel.angular_velocity *
        cfg.wheel_radius

    denominator =
        max(
            abs(wheel.vehicle_speed),
            0.5
        )

    wheel.longitudinal_slip =
        (
            wheel_speed -
            wheel.vehicle_speed
        ) / denominator

    return wheel.longitudinal_slip

end


# ============================================================
# TYRE TEMPERATURE GRIP
# ============================================================

function temperature_grip(
    temperature::Float64
)

    optimal = 70.0

    deviation =
        abs(
            temperature -
            optimal
        )

    # Simplified research model
    return clamp(
        1.0 -
        0.0035 * deviation,
        0.65,
        1.0
    )

end


# ============================================================
# TYRE PRESSURE GRIP
# ============================================================

function pressure_grip(
    pressure::Float64,
    cfg::WheelConfig
)

    error =
        abs(
            pressure -
            cfg.nominal_pressure_bar
        )

    return clamp(
        1.0 -
        0.25 * error,
        0.65,
        1.0
    )

end


# ============================================================
# ROAD FRICTION
# ============================================================

function road_mu(
    state::VehicleWheelState,
    cfg::WheelConfig
)

    friction =
        state.road_friction

    if friction > 0.85

        return cfg.tyre_mu_dry

    elseif friction > 0.50

        ratio =
            (
                friction -
                0.50
            ) / 0.35

        return (
            cfg.tyre_mu_wet * (1.0 - ratio) +
            cfg.tyre_mu_dry * ratio
        )

    else

        return cfg.tyre_mu_snow

    end

end


# ============================================================
# AVAILABLE TYRE GRIP
# ============================================================

function calculate_grip(
    wheel::WheelState,
    state::VehicleWheelState,
    cfg::WheelConfig
)

    μ =
        road_mu(
            state,
            cfg
        )

    temperature_factor =
        temperature_grip(
            wheel.tyre_temperature_c
        )

    pressure_factor =
        pressure_grip(
            wheel.tyre_pressure_bar,
            cfg
        )

    load_factor =
        clamp(
            wheel.vertical_load /
            5000.0,
            0.75,
            1.05
        )

    wheel.tyre_grip =
        μ *
        temperature_factor *
        pressure_factor *
        load_factor

    return wheel.tyre_grip

end


# ============================================================
# COMBINED SLIP
# ============================================================

function combined_slip(
    wheel::WheelState
)

    longitudinal =
        wheel.longitudinal_slip

    lateral =
        tan(
            wheel.lateral_slip_angle
        )

    return sqrt(
        longitudinal^2 +
        lateral^2
    )

end


# ============================================================
# FRICTION CIRCLE
# ============================================================

function friction_limit(
    wheel::WheelState
)

    return (
        wheel.tyre_grip *
        wheel.vertical_load
    )

end


# ============================================================
# MAXIMUM LONGITUDINAL FORCE
# ============================================================

function maximum_longitudinal_force(
    wheel::WheelState
)

    μFz =
        friction_limit(wheel)

    lateral_use =
        abs(
            wheel.lateral_force
        )

    remaining =
        max(
            μFz^2 -
            lateral_use^2,
            0.0
        )

    return sqrt(remaining)

end


# ============================================================
# MAXIMUM LATERAL FORCE
# ============================================================

function maximum_lateral_force(
    wheel::WheelState
)

    μFz =
        friction_limit(wheel)

    longitudinal_use =
        abs(
            wheel.longitudinal_force
        )

    remaining =
        max(
            μFz^2 -
            longitudinal_use^2,
            0.0
        )

    return sqrt(remaining)

end


# ============================================================
# DESIRED SLIP
# ============================================================

function optimal_longitudinal_slip(
    road_friction::Float64
)

    if road_friction > 0.85

        return 0.10

    elseif road_friction > 0.50

        return 0.12

    else

        return 0.16
    end

end


# ============================================================
# FORCE FROM SLIP
# ============================================================

function longitudinal_force_from_slip(
    wheel::WheelState,
    slip::Float64
)

    μFz =
        friction_limit(wheel)

    # Smooth saturating tyre model
    force =
        μFz *
        tanh(
            10.0 * slip
        )

    return force

end


# ============================================================
# LATERAL FORCE MODEL
# ============================================================

function lateral_force_from_angle(
    wheel::WheelState,
    angle::Float64
)

    μFz =
        friction_limit(wheel)

    force =
        μFz *
        tanh(
            7.0 * angle
        )

    return force

end


# ============================================================
# COMBINED FORCE OPTIMISER
# ============================================================

function optimise_wheel_force(
    wheel::WheelState,
    desired_fx::Float64,
    desired_fy::Float64
)

    limit =
        friction_limit(wheel)

    requested =
        sqrt(
            desired_fx^2 +
            desired_fy^2
        )

    if requested <= limit

        return (
            desired_fx,
            desired_fy
        )
    end

    scale =
        limit /
        max(requested, 1e-6)

    return (
        desired_fx * scale,
        desired_fy * scale
    )

end


# ============================================================
# TORQUE FROM FORCE
# ============================================================

function force_to_drive_torque(
    force::Float64,
    cfg::WheelConfig
)

    return (
        force *
        cfg.wheel_radius
    )

end


# ============================================================
# BRAKE TORQUE OPTIMISER
# ============================================================

function optimise_brake_torque(
    wheel::WheelState,
    desired_braking_force::Float64,
    cfg::WheelConfig
)

    maximum =
        maximum_longitudinal_force(
            wheel
        )

    force =
        min(
            desired_braking_force,
            maximum
        )

    torque =
        force_to_drive_torque(
            force,
            cfg
        )

    return clamp(
        torque,
        0.0,
        cfg.max_brake_torque
    )

end


# ============================================================
# DRIVE TORQUE OPTIMISER
# ============================================================

function optimise_drive_torque(
    wheel::WheelState,
    desired_drive_force::Float64,
    cfg::WheelConfig
)

    maximum =
        maximum_longitudinal_force(
            wheel
        )

    force =
        min(
            desired_drive_force,
            maximum
        )

    torque =
        force_to_drive_torque(
            force,
            cfg
        )

    return clamp(
        torque,
        0.0,
        cfg.max_drive_torque
    )

end


# ============================================================
# TORQUE VECTORING
# ============================================================

function torque_vectoring(
    state::VehicleWheelState,
    desired_yaw_moment::Float64,
    cfg::WheelConfig
)

    front_track =
        cfg.front_track

    rear_track =
        cfg.rear_track

    # Simplified yaw moment allocation
    front_difference =
        desired_yaw_moment /
        max(front_track, 0.1)

    rear_difference =
        desired_yaw_moment /
        max(rear_track, 0.1)

    front_left =
        -front_difference / 2.0

    front_right =
        front_difference / 2.0

    rear_left =
        -rear_difference / 2.0

    rear_right =
        rear_difference / 2.0

    return Dict(
        FL => front_left,
        FR => front_right,
        RL => rear_left,
        RR => rear_right
    )

end


# ============================================================
# WHEEL OPTIMISATION OBJECTIVE
# ============================================================

function wheel_cost(
    wheel::WheelState,
    target_force_x::Float64,
    target_force_y::Float64,
    force_x::Float64,
    force_y::Float64
)

    force_error =
        (
            force_x -
            target_force_x
        )^2 +
        (
            force_y -
            target_force_y
        )^2

    slip_penalty =
        combined_slip(wheel)^2

    thermal_penalty =
        max(
            wheel.tyre_temperature_c -
            100.0,
            0.0
        )^2

    pressure_penalty =
        (
            wheel.tyre_pressure_bar -
            2.5
        )^2

    return (
        100.0 * force_error +
        20.0 * slip_penalty +
        2.0 * thermal_penalty +
        5.0 * pressure_penalty
    )

end


# ============================================================
# COMPLETE WHEEL OPTIMISER
# ============================================================

function optimise_wheel(
    wheel::WheelState,
    state::VehicleWheelState,
    desired_fx::Float64,
    desired_fy::Float64,
    cfg::WheelConfig
)

    calculate_longitudinal_slip!(
        wheel,
        cfg
    )

    calculate_grip(
        wheel,
        state,
        cfg
    )

    fx, fy =
        optimise_wheel_force(
            wheel,
            desired_fx,
            desired_fy
        )

    if fx >= 0.0

        drive_torque =
            force_to_drive_torque(
                fx,
                cfg
            )

        brake_torque = 0.0

    else

        drive_torque = 0.0

        brake_torque =
            force_to_drive_torque(
                abs(fx),
                cfg
            )
    end

    target_slip =
        optimal_longitudinal_slip(
            state.road_friction
        )

    return WheelCommand(
        drive_torque,
        brake_torque,
        target_slip,
        fx,
        fy,
        wheel.tyre_grip
    )

end


# ============================================================
# TYRE TEMPERATURE UPDATE
# ============================================================

function update_tyre_temperature!(
    wheel::WheelState,
    command::WheelCommand,
    cfg::WheelConfig
)

    slip_energy =
        abs(
            wheel.longitudinal_slip
        ) *
        abs(
            command.target_force_x
        )

    lateral_energy =
        abs(
            wheel.lateral_slip_angle
        ) *
        abs(
            command.target_force_y
        )

    heat_generation =
        (
            slip_energy +
            lateral_energy
        ) *
        0.00005

    cooling =
        (
            wheel.tyre_temperature_c -
            25.0
        ) *
        0.0005

    wheel.tyre_temperature_c +=
        (
            heat_generation -
            cooling
        ) *
        cfg.dt

    wheel.tyre_temperature_c =
        clamp(
            wheel.tyre_temperature_c,
            20.0,
            150.0
        )

end


# ============================================================
# WHEEL PRESSURE MONITOR
# ============================================================

function pressure_status(
    wheel::WheelState,
    cfg::WheelConfig
)

    if wheel.tyre_pressure_bar <
       cfg.minimum_pressure_bar

        return :LOW

    elseif wheel.tyre_pressure_bar >
           cfg.maximum_pressure_bar

        return :HIGH

    else

        return :NORMAL
    end

end


# ============================================================
# CONTACT PATCH / GRIP MARGIN
# ============================================================

function grip_margin(
    wheel::WheelState
)

    available =
        friction_limit(
            wheel
        )

    requested =
        sqrt(
            wheel.longitudinal_force^2 +
            wheel.lateral_force^2
        )

    return clamp(
        1.0 -
        requested /
        max(available, 1.0),
        0.0,
        1.0
    )

end


# ============================================================
# FULL FOUR-WHEEL CONTROLLER
# ============================================================

function optimise_all_wheels!(
    state::VehicleWheelState,
    desired_fx::Float64,
    desired_fy::Float64,
    desired_yaw_moment::Float64,
    cfg::WheelConfig
)

    # Update normal loads
    calculate_wheel_loads!(
        state,
        cfg
    )

    yaw_allocation =
        torque_vectoring(
            state,
            desired_yaw_moment,
            cfg
        )

    commands =
        Dict{WheelID,WheelCommand}()

    # Equal base force allocation
    base_fx =
        desired_fx / 4.0

    base_fy =
        desired_fy / 4.0

    for wheel in state.wheels

        # Add torque-vectoring correction
        yaw_force =
            yaw_allocation[
                wheel.id
            ]

        target_fx =
            base_fx +
            yaw_force

        target_fy =
            base_fy

        command =
            optimise_wheel(
                wheel,
                state,
                target_fx,
                target_fy,
                cfg
            )

        wheel.longitudinal_force =
            command.target_force_x

        wheel.lateral_force =
            command.target_force_y

        wheel.drive_torque =
            command.drive_torque

        wheel.brake_torque =
            command.brake_torque

        commands[
            wheel.id
        ] = command

        update_tyre_temperature!(
            wheel,
            command,
            cfg
        )
    end

    return commands

end


# ============================================================
# EXAMPLE VEHICLE
# ============================================================

cfg =
    create_wheel_config()


wheels = [

    WheelState(
        FL,
        82.0,
        27.0,
        0.05,

        0.02,
        0.03,

        0.0,

        0.0,
        0.0,

        0.0,
        0.0,

        2.50,
        65.0,

        1.0,
        1.0
    ),

    WheelState(
        FR,
        82.2,
        27.0,
        0.05,

        0.02,
        0.03,

        0.0,

        0.0,
        0.0,

        0.0,
        0.0,

        2.50,
        65.0,

        1.0,
        1.0
    ),

    WheelState(
        RL,
        82.0,
        27.0,
        0.0,

        0.015,
        0.025,

        0.0,

        0.0,
        0.0,

        0.0,
        0.0,

        2.50,
        65.0,

        1.0,
        1.0
    ),

    WheelState(
        RR,
        82.1,
        27.0,
        0.0,

        0.015,
        0.025,

        0.0,

        0.0,
        0.0,

        0.0,
        0.0,

        2.50,
        65.0,

        1.0,
        1.0
    )
]


vehicle =
    VehicleWheelState(

        27.0,

        0.35,
        3.0,

        0.15,

        0.05,

        0.95,

        0.0,

        0.0,
        0.0,

        wheels
    )


# ============================================================
# RUN OPTIMISER
# ============================================================

println()
println("==============================================")
println(" AUREOM FOUR-WHEEL OPTIMISER")
println("==============================================")


desired_longitudinal_force =
    4200.0

desired_lateral_force =
    3200.0

desired_yaw_moment =
    900.0


commands =
    optimise_all_wheels!(
        vehicle,
        desired_longitudinal_force,
        desired_lateral_force,
        desired_yaw_moment,
        cfg
    )


for wheel in vehicle.wheels

    command =
        commands[
            wheel.id
        ]

    println()
    println(
        wheel.id,
        " -----------------------------"
    )

    println(
        "Vertical load: ",
        round(
            wheel.vertical_load,
            digits=1
        ),
        " N"
    )

    println(
        "Grip: ",
        round(
            wheel.tyre_grip,
            digits=3
        )
    )

    println(
        "Longitudinal force: ",
        round(
            wheel.longitudinal_force,
            digits=1
        ),
        " N"
    )

    println(
        "Lateral force: ",
        round(
            wheel.lateral_force,
            digits=1
        ),
        " N"
    )

    println(
        "Drive torque: ",
        round(
            command.drive_torque,
            digits=1
        ),
        " Nm"
    )

    println(
        "Brake torque: ",
        round(
            command.brake_torque,
            digits=1
        ),
        " Nm"
    )

    println(
        "Target slip: ",
        round(
            command.target_slip,
            digits=3
        )
    )

    println(
        "Tyre temperature: ",
        round(
            wheel.tyre_temperature_c,
            digits=1
        ),
        " °C"
    )

    println(
        "Pressure: ",
        round(
            wheel.tyre_pressure_bar,
            digits=2
        ),
        " bar"
    )

    println(
        "Pressure status: ",
        pressure_status(
            wheel,
            cfg
        )
    )

    println(
        "Grip margin: ",
        round(
            grip_margin(wheel) * 100,
            digits=1
        ),
        "%"
    )

end

