module HighSpeedRailOptimizer

using Printf

# ============================================================
# HIGH-SPEED ELECTRIC TRAIN PERFORMANCE OPTIMIZER
#
# Simulation / digital-twin software.
# NOT a safety-critical train-control system.
# ============================================================


# ============================================================
# ENUMERATIONS
# ============================================================

@enum OperatingMode begin
    IDLE
    ACCELERATION
    CRUISE
    HIGH_SPEED
    BRAKING
    THERMAL_LIMIT
    POWER_LIMIT
end


# ============================================================
# MOTOR
# ============================================================

mutable struct TractionMotor

    rated_power_W::Float64
    max_power_W::Float64

    max_torque_Nm::Float64

    efficiency::Float64

    temperature_K::Float64
    max_temperature_K::Float64

    thermal_time_constant::Float64

    rpm::Float64
end


# ============================================================
# INVERTER
# ============================================================

mutable struct Inverter

    dc_voltage_V::Float64

    max_current_A::Float64

    switching_efficiency::Float64

    temperature_K::Float64
    max_temperature_K::Float64
end


# ============================================================
# TRACTION UNIT
# ============================================================

mutable struct TractionSystem

    motor_count::Int

    wheel_radius_m::Float64

    gear_ratio::Float64

    adhesion_coefficient::Float64

    requested_power_W::Float64
    actual_power_W::Float64

    tractive_force_N::Float64

    inverter::Inverter

    motors::Vector{TractionMotor}
end


# ============================================================
# TRAIN
# ============================================================

mutable struct Train

    mass_kg::Float64

    speed_m_s::Float64

    position_m::Float64

    gradient::Float64

    frontal_area_m2::Float64

    drag_coefficient::Float64

    rolling_resistance::Float64

    air_density::Float64

    max_speed_m_s::Float64

    operating_mode::OperatingMode
end


# ============================================================
# POWER SUPPLY
# ============================================================

mutable struct PowerSupply

    voltage_V::Float64

    max_power_W::Float64

    available_power_W::Float64

    catenary_limit_A::Float64

    substation_limit_W::Float64
end


# ============================================================
# OPTIMIZER
# ============================================================

mutable struct PerformanceOptimizer

    target_speed_m_s::Float64

    speed_gain::Float64

    acceleration_gain::Float64

    efficiency_weight::Float64

    thermal_weight::Float64

    adhesion_margin::Float64

    aerodynamic_margin::Float64
end


# ============================================================
# CONSTANTS
# ============================================================

const G = 9.80665


# ============================================================
# AIR DENSITY
# ============================================================

function air_density(altitude_m)

    ρ0 = 1.225

    scale_height = 8500.0

    return ρ0 *
           exp(-altitude_m / scale_height)

end


# ============================================================
# AERODYNAMIC DRAG
# ============================================================

function aerodynamic_drag(train)

    ρ = train.air_density

    v = train.speed_m_s

    return 0.5 *
           ρ *
           v^2 *
           train.drag_coefficient *
           train.frontal_area_m2

end


# ============================================================
# ROLLING RESISTANCE
# ============================================================

function rolling_resistance(train)

    return train.mass_kg *
           G *
           train.rolling_resistance

end


# ============================================================
# GRADIENT RESISTANCE
# ============================================================

function gradient_resistance(train)

    return train.mass_kg *
           G *
           train.gradient

end


# ============================================================
# TOTAL RESISTANCE
# ============================================================

function total_resistance(train)

    return aerodynamic_drag(train) +
           rolling_resistance(train) +
           gradient_resistance(train)

end


# ============================================================
# ADHESION-LIMITED FORCE
# ============================================================

function adhesion_limit(train,
                         traction)

    normal_force =
        train.mass_kg * G

    return traction.adhesion_coefficient *
           normal_force

end


# ============================================================
# POWER-LIMITED FORCE
# ============================================================

function power_limited_force(
    traction,
    speed
)

    v = max(speed, 1.0)

    return traction.actual_power_W / v

end


# ============================================================
# MAXIMUM TRACTIVE FORCE
# ============================================================

function maximum_tractive_force(
    train,
    traction
)

    adhesion =
        adhesion_limit(
            train,
            traction
        )

    power =
        power_limited_force(
            traction,
            train.speed_m_s
        )

    return min(
        adhesion,
        power
    )

end


# ============================================================
# MOTOR EFFICIENCY MAP
# ============================================================

function motor_efficiency(motor,
                           rpm,
                           torque)

    speed_factor =
        rpm / 3000.0

    torque_factor =
        torque /
        motor.max_torque_Nm

    # Simplified efficiency surface.

    efficiency =
        0.96 -
        0.08 *
        abs(speed_factor - 0.65) -
        0.06 *
        abs(torque_factor - 0.65)

    return clamp(
        efficiency,
        0.70,
        0.97
    )

end


# ============================================================
# MOTOR THERMAL MODEL
# ============================================================

function update_motor_temperature!(
    motor,
    power,
    ambient_K,
    dt
)

    losses =
        power *
        (1.0 / motor.efficiency - 1.0)

    target_temperature =
        ambient_K +
        losses *
        0.004

    motor.temperature_K +=
        (
            target_temperature -
            motor.temperature_K
        ) *
        dt /
        motor.thermal_time_constant

end


# ============================================================
# MOTOR RPM
# ============================================================

function motor_rpm(
    traction,
    train_speed
)

    wheel_rpm =
        train_speed /
        (
            2π *
            traction.wheel_radius_m
        ) *
        60.0

    return wheel_rpm *
           traction.gear_ratio

end


# ============================================================
# INVERTER LIMIT
# ============================================================

function inverter_power_limit(
    inverter
)

    electrical_limit =
        inverter.dc_voltage_V *
        inverter.max_current_A

    return electrical_limit *
           inverter.switching_efficiency

end


# ============================================================
# POWER-SUPPLY LIMIT
# ============================================================

function supply_power_limit(
    supply
)

    current_limit =
        supply.voltage_V *
        supply.catenary_limit_A

    return min(
        current_limit,
        supply.substation_limit_W,
        supply.max_power_W
    )

end


# ============================================================
# AVAILABLE SYSTEM POWER
# ============================================================

function available_power(
    traction,
    supply
)

    motor_limit =
        traction.motor_count *
        traction.motors[1].max_power_W

    inverter_limit =
        inverter_power_limit(
            traction.inverter
        )

    supply_limit =
        supply_power_limit(
            supply
        )

    return min(
        motor_limit,
        inverter_limit,
        supply_limit
    )

end


# ============================================================
# SPEED ERROR
# ============================================================

function speed_error(
    train,
    optimizer
)

    return optimizer.target_speed_m_s -
           train.speed_m_s

end


# ============================================================
# OPTIMAL POWER REQUEST
# ============================================================

function calculate_power_request(
    train,
    traction,
    supply,
    optimizer
)

    resistance =
        total_resistance(train)

    error =
        speed_error(
            train,
            optimizer
        )

    # Required power merely to maintain speed.

    base_power =
        resistance *
        max(train.speed_m_s, 1.0)

    # Additional power for acceleration.

    acceleration_power =
        max(error, 0.0) *
        train.mass_kg *
        optimizer.acceleration_gain

    requested =
        base_power +
        acceleration_power

    maximum =
        available_power(
            traction,
            supply
        )

    return clamp(
        requested,
        0.0,
        maximum
    )

end


# ============================================================
# OPTIMIZED MOTOR COMMAND
# ============================================================

function optimize_motor_command!(
    train,
    traction,
    supply,
    optimizer
)

    power =
        calculate_power_request(
            train,
            traction,
            supply,
            optimizer
        )

    # High-speed aerodynamic penalty.

    aero =
        aerodynamic_drag(train)

    aero_fraction =
        aero /
        max(
            total_resistance(train),
            1.0
        )

    if aero_fraction >
       optimizer.aerodynamic_margin

        # Avoid wasting power when
        # aerodynamic drag dominates.

        power *= 0.98

    end


    # Thermal derating.

    hottest =
        maximum(
            m.temperature_K
            for m in traction.motors
        )

    temperature_ratio =
        hottest /
        traction.motors[1].max_temperature_K

    if temperature_ratio > 0.90

        power *=
            max(
                0.30,
                1.0 -
                (temperature_ratio - 0.90) *
                5.0
            )

        train.operating_mode =
            THERMAL_LIMIT

    end


    # Adhesion management.

    max_force =
        adhesion_limit(
            train,
            traction
        )

    requested_force =
        power /
        max(train.speed_m_s, 1.0)

    if requested_force >
       max_force

        power =
            max_force *
            max(train.speed_m_s, 1.0)

    end


    traction.requested_power_W =
        power

    return power

end


# ============================================================
# APPLY TRACTION POWER
# ============================================================

function apply_power!(
    traction,
    train
)

    power =
        traction.requested_power_W

    force =
        power /
        max(train.speed_m_s, 1.0)

    maximum_force =
        adhesion_limit(
            train,
            traction
        )

    force =
        min(
            force,
            maximum_force
        )

    actual_power =
        force *
        max(train.speed_m_s, 1.0)

    traction.tractive_force_N =
        force

    traction.actual_power_W =
        actual_power

end


# ============================================================
# TRAIN DYNAMICS
# ============================================================

function update_train!(
    train,
    traction,
    dt
)

    traction_force =
        traction.tractive_force_N

    resistance =
        total_resistance(train)

    net_force =
        traction_force -
        resistance

    acceleration =
        net_force /
        train.mass_kg

    train.speed_m_s +=
        acceleration * dt

    train.speed_m_s =
        clamp(
            train.speed_m_s,
            0.0,
            train.max_speed_m_s
        )

    train.position_m +=
        train.speed_m_s * dt

end


# ============================================================
# TRAIN MODE
# ============================================================

function update_mode!(
    train,
    optimizer
)

    error =
        abs(
            train.speed_m_s -
            optimizer.target_speed_m_s
        )

    if train.speed_m_s <
       optimizer.target_speed_m_s - 5.0

        train.operating_mode =
            ACCELERATION

    elseif error < 1.0

        train.operating_mode =
            CRUISE

    elseif train.speed_m_s >
           optimizer.target_speed_m_s + 5.0

        train.operating_mode =
            HIGH_SPEED

    end

end


# ============================================================
# COMPLETE SYSTEM STEP
# ============================================================

function simulation_step!(
    train,
    traction,
    supply,
    optimizer,
    dt
)

    update_mode!(
        train,
        optimizer
    )


    optimize_motor_command!(
        train,
        traction,
        supply,
        optimizer
    )


    apply_power!(
        traction,
        train
    )


    # Motor RPM.

    rpm =
        motor_rpm(
            traction,
            train.speed_m_s
        )


    # Motor efficiency.

    for motor in traction.motors

        motor.rpm = rpm

        motor.efficiency =
            motor_efficiency(
                motor,
                rpm,
                motor.max_torque_Nm
            )

        update_motor_temperature!(
            motor,
            traction.actual_power_W /
            traction.motor_count,
            293.15,
            dt
        )

    end


    # Train dynamics.

    update_train!(
        train,
        traction,
        dt
    )

end


# ============================================================
# TELEMETRY
# ============================================================

function telemetry(
    train,
    traction,
    supply
)

    hottest =
        maximum(
            m.temperature_K
            for m in traction.motors
        )

    @printf(
        "SPD %7.1f km/h | " *
        "POWER %6.2f MW | " *
        "FORCE %7.1f kN | " *
        "DRAG %7.1f kN | " *
        "MOTOR %6.0f rpm | " *
        "TEMP %5.1f C | " *
        "MODE %s\n",

        train.speed_m_s * 3.6,

        traction.actual_power_W / 1e6,

        traction.tractive_force_N / 1000,

        aerodynamic_drag(train) / 1000,

        traction.motors[1].rpm,

        hottest - 273.15,

        string(train.operating_mode)
    )

end


# ============================================================
# SYSTEM FACTORY
# ============================================================

function create_train()

    motors = [

        TractionMotor(
            1.5e6,
            1.8e6,
            12_000.0,
            0.94,
            320.0,
            423.15,
            120.0,
            0.0
        )

        for i in 1:8
    ]


    inverter =
        Inverter(
            3000.0,
            1200.0,
            0.98,
            320.0,
            423.15
        )


    traction =
        TractionSystem(
            8,
            0.46,
            4.2,
            0.20,
            0.0,
            0.0,
            0.0,
            inverter,
            motors
        )


    train =
        Train(
            450_000.0,
            0.0,
            0.0,
            0.0,
            11.0,
            0.13,
            0.001,
            1.225,
            360.0 / 3.6,
            IDLE
        )


    supply =
        PowerSupply(
            25_000.0,
            15.0e6,
            15.0e6,
            600.0,
            15.0e6
        )


    optimizer =
        PerformanceOptimizer(
            330.0,
            0.5,
            0.8,
            1.0,
            1.0,
            0.95,
            0.80
        )


    return train,
           traction,
           supply,
           optimizer

end


# ============================================================
# HIGH-SPEED TEST
# ============================================================

function run_simulation(
    duration
)

    train,
    traction,
    supply,
    optimizer =
        create_train()


    dt = 0.25

    t = 0.0

    println()
    println(
        "=================================================="
    )
    println(
        " HIGH-SPEED ELECTRIC TRAIN OPTIMIZER"
    )
    println(
        "=================================================="
    )
    println()


    while t < duration

        simulation_step!(
            train,
            traction,
            supply,
            optimizer,
            dt
        )


        if mod(
            floor(Int, t),
            5
        ) == 0

            telemetry(
                train,
                traction,
                supply
            )

        end


        t += dt

    end


    println()
    println(
        "SIMULATION COMPLETE"
    )

    println(
        "Distance: ",
        round(
            train.position_m / 1000,
            digits=2
        ),
        " km"
    )

    println(
        "Speed: ",
        round(
            train.speed_m_s * 3.6,
            digits=1
        ),
        " km/h"
    )

    println(
        "Power: ",
        round(
            traction.actual_power_W / 1e6,
            digits=2
        ),
        " MW"
    )

end


end # module


# ============================================================
# RUN
# ============================================================

using .HighSpeedRailOptimizer

HighSpeedRailOptimizer.run_simulation(180.0)
