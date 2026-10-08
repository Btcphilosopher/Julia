module EBikeControl

using Statistics

# ============================================================
# E-BIKE CONTROL SYSTEM
#
# Reference/simulation architecture for an electric bicycle.
#
# Covers:
#   - Battery
#   - BLDC/PMSM motor
#   - Torque sensor
#   - Cadence sensor
#   - Wheel speed
#   - Motor controller
#   - Pedal-assist control
#   - Regenerative braking
#   - Thermal management
#   - Power limiting
#   - Fault detection
#   - Ride telemetry
#
# Not production safety-certified firmware.
# ============================================================


# ============================================================
# CONSTANTS
# ============================================================

const NOMINAL_BATTERY_VOLTAGE = 48.0
const MAX_BATTERY_VOLTAGE = 54.6
const MIN_BATTERY_VOLTAGE = 39.0

const BATTERY_CAPACITY_AH = 15.0
const BATTERY_CAPACITY_WH =
    NOMINAL_BATTERY_VOLTAGE * BATTERY_CAPACITY_AH

const MAX_MOTOR_POWER = 750.0
const NOMINAL_MOTOR_POWER = 500.0

const MAX_MOTOR_CURRENT = 25.0
const MAX_BATTERY_CURRENT = 20.0

const MAX_MOTOR_RPM = 5000.0
const MAX_WHEEL_SPEED_KPH = 45.0

const TORQUE_SENSOR_MAX_NM = 120.0

const MIN_ASSIST_CADENCE = 20.0
const MAX_ASSIST_CADENCE = 130.0

const MOTOR_TEMPERATURE_WARNING = 70.0
const MOTOR_TEMPERATURE_DERATE = 80.0
const MOTOR_TEMPERATURE_CRITICAL = 95.0

const BATTERY_TEMPERATURE_WARNING = 40.0
const BATTERY_TEMPERATURE_DERATE = 50.0
const BATTERY_TEMPERATURE_CRITICAL = 60.0

const CONTROLLER_TEMPERATURE_WARNING = 65.0
const CONTROLLER_TEMPERATURE_DERATE = 75.0
const CONTROLLER_TEMPERATURE_CRITICAL = 90.0

const ASSIST_RESPONSE = 0.15
const SPEED_FILTER = 0.10
const TORQUE_FILTER = 0.12
const CADENCE_FILTER = 0.15


# ============================================================
# ENUMS
# ============================================================

@enum RideMode begin
    MODE_OFF
    MODE_ECO
    MODE_TOUR
    MODE_SPORT
    MODE_TURBO
    MODE_CUSTOM
end

@enum MotorState begin
    MOTOR_DISABLED
    MOTOR_READY
    MOTOR_RUNNING
    MOTOR_DERATED
    MOTOR_REGEN
    MOTOR_FAULT
end

@enum BrakeState begin
    BRAKE_RELEASED
    BRAKE_ACTIVE
    BRAKE_EMERGENCY
end

@enum FaultSeverity begin
    FAULT_NONE
    FAULT_WARNING
    FAULT_DERATE
    FAULT_CRITICAL
end


# ============================================================
# VECTOR
# ============================================================

struct Vector3

    x::Float64
    y::Float64
    z::Float64

end


# ============================================================
# BATTERY PARAMETERS
# ============================================================

struct BatteryParameters

    nominal_voltage::Float64
    maximum_voltage::Float64
    minimum_voltage::Float64

    capacity_ah::Float64

    maximum_current::Float64
    maximum_power::Float64

    internal_resistance::Float64

    thermal_capacity::Float64
    thermal_resistance::Float64

end


# ============================================================
# BATTERY STATE
# ============================================================

mutable struct BatteryState

    soc::Float64
    soh::Float64

    voltage::Float64
    current::Float64
    power::Float64

    temperature::Float64

    energy_used_wh::Float64
    energy_recovered_wh::Float64

    cycle_count::Float64

end


# ============================================================
# MOTOR PARAMETERS
# ============================================================

struct MotorParameters

    rated_power::Float64
    maximum_power::Float64

    maximum_current::Float64

    torque_constant::Float64
    back_emf_constant::Float64

    rotor_inertia::Float64
    friction::Float64

    pole_pairs::Int

    maximum_rpm::Float64

    thermal_capacity::Float64
    thermal_resistance::Float64

end


# ============================================================
# MOTOR STATE
# ============================================================

mutable struct MotorState

    state::MotorState

    rpm::Float64
    angular_velocity::Float64

    current::Float64
    torque::Float64

    electrical_power::Float64
    mechanical_power::Float64

    temperature::Float64

    efficiency::Float64

    rotor_angle::Float64

end


# ============================================================
# TORQUE SENSOR
# ============================================================

mutable struct TorqueSensor

    raw_torque::Float64
    filtered_torque::Float64

    offset::Float64
    gain::Float64

    valid::Bool

end


# ============================================================
# CADENCE SENSOR
# ============================================================

mutable struct CadenceSensor

    rpm::Float64
    filtered_rpm::Float64

    pulses::Int
    valid::Bool

end


# ============================================================
# SPEED SENSOR
# ============================================================

mutable struct SpeedSensor

    wheel_rpm::Float64
    speed_kph::Float64

    filtered_speed_kph::Float64

    wheel_circumference_m::Float64

    valid::Bool

end


# ============================================================
# BRAKE SENSOR
# ============================================================

mutable struct BrakeSensor

    front_active::Bool
    rear_active::Bool

    pressure::Float64

end


# ============================================================
# THERMAL STATE
# ============================================================

mutable struct ThermalState

    motor_temperature::Float64
    battery_temperature::Float64
    controller_temperature::Float64

    ambient_temperature::Float64

    motor_derating::Float64
    battery_derating::Float64
    controller_derating::Float64

end


# ============================================================
# RIDE STATE
# ============================================================

mutable struct RideState

    elapsed_time::Float64

    distance_km::Float64

    average_speed_kph::Float64
    maximum_speed_kph::Float64

    rider_power::Float64
    motor_power::Float64

    total_energy_wh::Float64
    recovered_energy_wh::Float64

    elevation_gain_m::Float64

end


# ============================================================
# CONTROLLER PARAMETERS
# ============================================================

struct ControllerParameters

    eco_power::Float64
    tour_power::Float64
    sport_power::Float64
    turbo_power::Float64

    eco_assist::Float64
    tour_assist::Float64
    sport_assist::Float64
    turbo_assist::Float64

    maximum_speed_kph::Float64

end


# ============================================================
# CONTROL COMMAND
# ============================================================

mutable struct MotorCommand

    enabled::Bool

    target_torque::Float64
    target_power::Float64

    target_current::Float64

    regenerative_braking::Bool
    regeneration_power::Float64

end


# ============================================================
# FAULT
# ============================================================

struct Fault

    code::Symbol
    severity::FaultSeverity
    message::String
    timestamp::Float64

end


# ============================================================
# COMPLETE E-BIKE
# ============================================================

mutable struct EBikeSystem

    battery_parameters::BatteryParameters
    motor_parameters::MotorParameters
    controller_parameters::ControllerParameters

    battery::BatteryState
    motor::MotorState

    torque_sensor::TorqueSensor
    cadence_sensor::CadenceSensor
    speed_sensor::SpeedSensor
    brake_sensor::BrakeSensor

    thermal::ThermalState
    ride::RideState

    mode::RideMode
    command::MotorCommand

    faults::Vector{Fault}

end


# ============================================================
# FACTORY
# ============================================================

function create_ebike()

    battery_parameters =
        BatteryParameters(
            NOMINAL_BATTERY_VOLTAGE,
            MAX_BATTERY_VOLTAGE,
            MIN_BATTERY_VOLTAGE,
            BATTERY_CAPACITY_AH,
            MAX_BATTERY_CURRENT,
            MAX_MOTOR_POWER,
            0.10,
            15000.0,
            3.5
        )

    motor_parameters =
        MotorParameters(
            NOMINAL_MOTOR_POWER,
            MAX_MOTOR_POWER,
            MAX_MOTOR_CURRENT,
            0.80,
            0.08,
            0.002,
            0.001,
            7,
            MAX_MOTOR_RPM,
            10000.0,
            0.25
        )

    controller_parameters =
        ControllerParameters(
            250.0,
            450.0,
            650.0,
            750.0,
            0.50,
            0.90,
            1.40,
            2.00,
            45.0
        )

    battery =
        BatteryState(
            1.0,
            1.0,
            MAX_BATTERY_VOLTAGE,
            0.0,
            0.0,
            22.0,
            0.0,
            0.0,
            0.0
        )

    motor =
        MotorState(
            MOTOR_DISABLED,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            22.0,
            0.0,
            0.0
        )

    torque =
        TorqueSensor(
            0.0,
            0.0,
            0.0,
            1.0,
            true
        )

    cadence =
        CadenceSensor(
            0.0,
            0.0,
            0,
            true
        )

    speed =
        SpeedSensor(
            0.0,
            0.0,
            0.0,
            2.20,
            true
        )

    brakes =
        BrakeSensor(
            false,
            false,
            0.0
        )

    thermal =
        ThermalState(
            22.0,
            22.0,
            22.0,
            22.0,
            1.0,
            1.0,
            1.0
        )

    ride =
        RideState(
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0
        )

    command =
        MotorCommand(
            false,
            0.0,
            0.0,
            0.0,
            false,
            0.0
        )

    return EBikeSystem(
        battery_parameters,
        motor_parameters,
        controller_parameters,
        battery,
        motor,
        torque,
        cadence,
        speed,
        brakes,
        thermal,
        ride,
        MODE_OFF,
        command,
        Fault[]
    )

end


# ============================================================
# SENSOR FILTER
# ============================================================

function lowpass(
    previous::Float64,
    input::Float64,
    alpha::Float64
)

    return previous +
           alpha * (input - previous)

end


# ============================================================
# TORQUE SENSOR UPDATE
# ============================================================

function update_torque_sensor!(
    bike::EBikeSystem,
    torque::Float64
)

    sensor = bike.torque_sensor

    sensor.raw_torque =
        torque

    corrected =
        (
            torque -
            sensor.offset
        ) * sensor.gain

    sensor.filtered_torque =
        lowpass(
            sensor.filtered_torque,
            corrected,
            TORQUE_FILTER
        )

end


# ============================================================
# CADENCE UPDATE
# ============================================================

function update_cadence!(
    bike::EBikeSystem,
    cadence::Float64
)

    sensor =
        bike.cadence_sensor

    sensor.rpm =
        max(cadence, 0.0)

    sensor.filtered_rpm =
        lowpass(
            sensor.filtered_rpm,
            sensor.rpm,
            CADENCE_FILTER
        )

end


# ============================================================
# WHEEL SPEED
# ============================================================

function update_speed!(
    bike::EBikeSystem,
    wheel_rpm::Float64
)

    sensor =
        bike.speed_sensor

    sensor.wheel_rpm =
        max(wheel_rpm, 0.0)

    circumference =
        sensor.wheel_circumference_m

    speed_ms =
        wheel_rpm *
        circumference /
        60.0

    speed_kph =
        speed_ms * 3.6

    sensor.speed_kph =
        speed_kph

    sensor.filtered_speed_kph =
        lowpass(
            sensor.filtered_speed_kph,
            speed_kph,
            SPEED_FILTER
        )

end


# ============================================================
# RIDER POWER
# ============================================================

function rider_power(
    bike::EBikeSystem
)

    torque =
        max(
            bike.torque_sensor.filtered_torque,
            0.0
        )

    cadence =
        bike.cadence_sensor.filtered_rpm

    angular_velocity =
        cadence * 2π / 60.0

    return torque *
           angular_velocity

end


# ============================================================
# ASSIST FACTOR
# ============================================================

function assist_factor(
    bike::EBikeSystem
)

    cp =
        bike.controller_parameters

    if bike.mode == MODE_ECO
        return cp.eco_assist

    elseif bike.mode == MODE_TOUR
        return cp.tour_assist

    elseif bike.mode == MODE_SPORT
        return cp.sport_assist

    elseif bike.mode == MODE_TURBO
        return cp.turbo_assist

    else
        return 0.0
    end

end


# ============================================================
# POWER LIMIT
# ============================================================

function mode_power_limit(
    bike::EBikeSystem
)

    cp =
        bike.controller_parameters

    if bike.mode == MODE_ECO
        return cp.eco_power

    elseif bike.mode == MODE_TOUR
        return cp.tour_power

    elseif bike.mode == MODE_SPORT
        return cp.sport_power

    elseif bike.mode == MODE_TURBO
        return cp.turbo_power

    else
        return 0.0
    end

end


# ============================================================
# SPEED LIMIT
# ============================================================

function speed_factor(
    bike::EBikeSystem
)

    speed =
        bike.speed_sensor.filtered_speed_kph

    limit =
        bike.controller_parameters.maximum_speed_kph

    if speed >= limit
        return 0.0
    end

    if speed > 0.95 * limit

        return (
            limit - speed
        ) / (
            0.05 * limit
        )

    end

    return 1.0

end


# ============================================================
# CADENCE FACTOR
# ============================================================

function cadence_factor(
    bike::EBikeSystem
)

    cadence =
        bike.cadence_sensor.filtered_rpm

    if cadence < MIN_ASSIST_CADENCE
        return 0.0
    end

    if cadence > MAX_ASSIST_CADENCE
        return 0.5
    end

    ideal = 75.0

    distance =
        abs(cadence - ideal)

    return clamp(
        1.0 - distance / 100.0,
        0.50,
        1.0
    )

end


# ============================================================
# BATTERY POWER LIMIT
# ============================================================

function battery_power_limit(
    bike::EBikeSystem
)

    battery =
        bike.battery

    if battery.soc <= 0.03
        return 0.0
    end

    if battery.voltage <=
       MIN_BATTERY_VOLTAGE

        return 0.0
    end

    soc_factor =
        if battery.soc < 0.10
            0.40
        elseif battery.soc < 0.20
            0.70
        else
            1.0
        end

    temperature_factor =
        bike.thermal.battery_derating

    return (
        MAX_MOTOR_POWER *
        soc_factor *
        temperature_factor
    )

end


# ============================================================
# THERMAL DERATING
# ============================================================

function thermal_multiplier(
    temperature::Float64,
    warning::Float64,
    derate::Float64,
    critical::Float64
)

    if temperature < warning
        return 1.0

    elseif temperature < derate

        return 0.85

    elseif temperature < critical

        return (
            critical - temperature
        ) / (
            critical - derate
        )

    else

        return 0.0

    end

end


# ============================================================
# UPDATE THERMAL LIMITS
# ============================================================

function update_thermal_limits!(
    bike::EBikeSystem
)

    t =
        bike.thermal

    t.motor_derating =
        thermal_multiplier(
            t.motor_temperature,
            MOTOR_TEMPERATURE_WARNING,
            MOTOR_TEMPERATURE_DERATE,
            MOTOR_TEMPERATURE_CRITICAL
        )

    t.battery_derating =
        thermal_multiplier(
            t.battery_temperature,
            BATTERY_TEMPERATURE_WARNING,
            BATTERY_TEMPERATURE_DERATE,
            BATTERY_TEMPERATURE_CRITICAL
        )

    t.controller_derating =
        thermal_multiplier(
            t.controller_temperature,
            CONTROLLER_TEMPERATURE_WARNING,
            CONTROLLER_TEMPERATURE_DERATE,
            CONTROLLER_TEMPERATURE_CRITICAL
        )

end


# ============================================================
# ASSIST TORQUE
# ============================================================

function calculate_assist_torque(
    bike::EBikeSystem
)

    rider_torque =
        max(
            bike.torque_sensor.filtered_torque,
            0.0
        )

    assist =
        assist_factor(bike)

    cadence =
        cadence_factor(bike)

    speed =
        speed_factor(bike)

    thermal =
        bike.thermal.motor_derating

    battery =
        battery_power_limit(bike) /
        MAX_MOTOR_POWER

    requested =
        rider_torque *
        assist *
        cadence *
        speed *
        thermal *
        battery

    return clamp(
        requested,
        0.0,
        TORQUE_SENSOR_MAX_NM
    )

end


# ============================================================
# POWER COMMAND
# ============================================================

function calculate_power_command(
    bike::EBikeSystem
)

    rider =
        rider_power(bike)

    assist =
        calculate_assist_torque(bike)

    cadence =
        bike.cadence_sensor.filtered_rpm

    ω =
        cadence * 2π / 60.0

    motor_power =
        assist * ω

    limit =
        mode_power_limit(bike)

    battery_limit =
        battery_power_limit(bike)

    thermal_limit =
        bike.thermal.motor_derating *
        bike.thermal.controller_derating

    return min(
        motor_power,
        limit,
        battery_limit,
        MAX_MOTOR_POWER * thermal_limit
    )

end


# ============================================================
# MOTOR COMMAND
# ============================================================

function update_motor_command!(
    bike::EBikeSystem
)

    command =
        bike.command

    if bike.mode == MODE_OFF

        command.enabled = false
        command.target_torque = 0.0
        command.target_power = 0.0
        command.target_current = 0.0

        return

    end

    if bike.brake_sensor.front_active ||
       bike.brake_sensor.rear_active

        command.enabled = false
        command.target_torque = 0.0
        command.target_power = 0.0
        command.target_current = 0.0

        return

    end

    torque =
        calculate_assist_torque(bike)

    power =
        calculate_power_command(bike)

    voltage =
        max(
            bike.battery.voltage,
            1.0
        )

    current =
        power / voltage

    command.enabled =
        torque > 0.0 &&
        power > 0.0

    command.target_torque =
        torque

    command.target_power =
        power

    command.target_current =
        min(
            current,
            MAX_MOTOR_CURRENT
        )

end


# ============================================================
# MOTOR DYNAMICS
# ============================================================

function update_motor!(
    bike::EBikeSystem,
    dt::Float64
)

    motor =
        bike.motor

    mp =
        bike.motor_parameters

    command =
        bike.command

    if !command.enabled

        motor.current *=
            max(0.0, 1.0 - 10.0 * dt)

        motor.torque =
            motor.current *
            mp.torque_constant

    else

        target_current =
            command.target_current

        motor.current +=
            (
                target_current -
                motor.current
            ) * ASSIST_RESPONSE

        motor.torque =
            motor.current *
            mp.torque_constant

    end

    load_torque =
        bike.speed_sensor.filtered_speed_kph *
        0.002

    friction =
        mp.friction *
        motor.angular_velocity

    net_torque =
        motor.torque -
        load_torque -
        friction

    acceleration =
        net_torque /
        mp.rotor_inertia

    motor.angular_velocity +=
        acceleration * dt

    motor.angular_velocity =
        max(
            motor.angular_velocity,
            0.0
        )

    motor.rpm =
        motor.angular_velocity *
        60.0 /
        (2π)

    motor.rpm =
        min(
            motor.rpm,
            mp.maximum_rpm
        )

    motor.electrical_power =
        motor.current *
        bike.battery.voltage

    motor.mechanical_power =
        motor.torque *
        motor.angular_velocity

    motor.efficiency =
        if motor.electrical_power > 1.0
            clamp(
                motor.mechanical_power /
                motor.electrical_power,
                0.0,
                1.0
            )
        else
            0.0
        end

end


# ============================================================
# MOTOR TEMPERATURE
# ============================================================

function update_motor_temperature!(
    bike::EBikeSystem,
    dt::Float64
)

    motor =
        bike.motor

    mp =
        bike.motor_parameters

    heat =
        motor.current^2 *
        0.12

    cooling =
        (
            motor.temperature -
            bike.thermal.ambient_temperature
        ) /
        mp.thermal_resistance

    dT =
        (
            heat -
            cooling
        ) /
        mp.thermal_capacity

    motor.temperature +=
        dT * dt

    bike.thermal.motor_temperature =
        motor.temperature

end


# ============================================================
# BATTERY UPDATE
# ============================================================

function update_battery!(
    bike::EBikeSystem,
    dt::Float64
)

    battery =
        bike.battery

    bp =
        bike.battery_parameters

    battery.current =
        bike.motor.electrical_power /
        max(
            battery.voltage,
            1.0
        )

    battery.current =
        min(
            battery.current,
            MAX_BATTERY_CURRENT
        )

    voltage_ocv =
        bp.minimum_voltage +
        (
            bp.maximum_voltage -
            bp.minimum_voltage
        ) * battery.soc

    voltage_sag =
        battery.current *
        bp.internal_resistance

    battery.voltage =
        max(
            voltage_ocv -
            voltage_sag,
            bp.minimum_voltage
        )

    delta_ah =
        battery.current *
        dt /
        3600.0

    battery.soc -=
        delta_ah /
        bp.capacity_ah

    battery.soc =
        clamp(
            battery.soc,
            0.0,
            1.0
        )

    battery.power =
        battery.voltage *
        battery.current

    battery.energy_used_wh +=
        battery.power *
        dt /
        3600.0

end


# ============================================================
# BATTERY TEMPERATURE
# ============================================================

function update_battery_temperature!(
    bike::EBikeSystem,
    dt::Float64
)

    battery =
        bike.battery

    bp =
        bike.battery_parameters

    heat =
        battery.current^2 *
        bp.internal_resistance

    cooling =
        (
            battery.temperature -
            bike.thermal.ambient_temperature
        ) /
        bp.thermal_resistance

    dT =
        (
            heat -
            cooling
        ) /
        bp.thermal_capacity

    battery.temperature +=
        dT * dt

    bike.thermal.battery_temperature =
        battery.temperature

end


# ============================================================
# REGENERATIVE BRAKING
# ============================================================

function regenerative_braking!(
    bike::EBikeSystem,
    braking_request::Float64,
    dt::Float64
)

    if braking_request <= 0.0
        return 0.0
    end

    if bike.battery.soc >= 0.98
        return 0.0
    end

    if bike.battery.temperature >
       BATTERY_TEMPERATURE_DERATE

        return 0.0
    end

    maximum_regen =
        min(
            400.0,
            MAX_BATTERY_CURRENT *
            bike.battery.voltage
        )

    power =
        min(
            braking_request,
            maximum_regen
        )

    recovered =
        power *
        dt /
        3600.0

    bike.battery.energy_recovered_wh +=
        recovered

    bike.battery.soc +=
        recovered /
        BATTERY_CAPACITY_WH

    bike.battery.soc =
        clamp(
            bike.battery.soc,
            0.0,
            1.0
        )

    return power

end


# ============================================================
# RIDE TELEMETRY
# ============================================================

function update_ride!(
    bike::EBikeSystem,
    dt::Float64
)

    ride =
        bike.ride

    speed =
        bike.speed_sensor.filtered_speed_kph

    ride.elapsed_time += dt

    ride.distance_km +=
        speed *
        dt /
        3600.0

    ride.maximum_speed_kph =
        max(
            ride.maximum_speed_kph,
            speed
        )

    rider =
        rider_power(bike)

    ride.rider_power =
        rider

    ride.motor_power =
        bike.motor.mechanical_power

    n =
        max(
            ride.elapsed_time,
            1.0
        )

    ride.average_speed_kph =
        ride.distance_km /
        (n / 3600.0)

end


# ============================================================
# SAFETY CHECK
# ============================================================

function safety_check!(
    bike::EBikeSystem
)

    empty!(
        bike.faults
    )

    t =
        bike.thermal

    b =
        bike.battery

    m =
        bike.motor

    if b.voltage <
       MIN_BATTERY_VOLTAGE

        push!(
            bike.faults,
            Fault(
                :LOW_BATTERY_VOLTAGE,
                FAULT_CRITICAL,
                "Battery voltage too low",
                bike.ride.elapsed_time
            )
        )

    end

    if m.rpm >
       MAX_MOTOR_RPM

        push!(
            bike.faults,
            Fault(
                :MOTOR_OVERSPEED,
                FAULT_CRITICAL,
                "Motor overspeed",
                bike.ride.elapsed_time
            )
        )

    end

    if m.temperature >
       MOTOR_TEMPERATURE_CRITICAL

        push!(
            bike.faults,
            Fault(
                :MOTOR_OVERHEAT,
                FAULT_CRITICAL,
                "Motor temperature critical",
                bike.ride.elapsed_time
            )
        )

    end

    if b.temperature >
       BATTERY_TEMPERATURE_CRITICAL

        push!(
            bike.faults,
            Fault(
                :BATTERY_OVERHEAT,
                FAULT_CRITICAL,
                "Battery temperature critical",
                bike.ride.elapsed_time
            )
        )

    end

    if b.current >
       MAX_BATTERY_CURRENT

        push!(
            bike.faults,
            Fault(
                :BATTERY_OVERCURRENT,
                FAULT_CRITICAL,
                "Battery current exceeded",
                bike.ride.elapsed_time
            )
        )

    end

end


# ============================================================
# SAFETY ARBITRATION
# ============================================================

function apply_safety!(
    bike::EBikeSystem
)

    critical =
        any(
            f.severity ==
            FAULT_CRITICAL
            for f in bike.faults
        )

    if critical

        bike.command.enabled =
            false

        bike.command.target_torque =
            0.0

        bike.command.target_power =
            0.0

        bike.motor.state =
            MOTOR_FAULT

        return

    end

    if !isempty(bike.faults)

        bike.motor.state =
            MOTOR_DERATED

    else

        bike.motor.state =
            bike.command.enabled ?
            MOTOR_RUNNING :
            MOTOR_READY

    end

end


# ============================================================
# MAIN CONTROL LOOP
# ============================================================

function step!(
    bike::EBikeSystem,
    dt::Float64;
    rider_torque = 20.0,
    cadence = 75.0,
    wheel_speed_kph = 25.0,
    brake = false,
    ambient_temperature = 20.0
)

    bike.thermal.ambient_temperature =
        ambient_temperature

    bike.brake_sensor.front_active =
        brake

    bike.brake_sensor.rear_active =
        brake

    update_torque_sensor!(
        bike,
        rider_torque
    )

    update_cadence!(
        bike,
        cadence
    )

    update_speed!(
        bike,
        wheel_speed_kph /
        3.6 *
        60.0 /
        bike.speed_sensor.wheel_circumference_m
    )

    update_thermal_limits!(
        bike)

    safety_check!(
        bike)

    apply_safety!(
        bike)

    if bike.motor.state != MOTOR_FAULT

        update_motor_command!(
            bike)

    end

    update_motor!(
        bike,
        dt
    )

    update_motor_temperature!(
        bike,
        dt
    )

    update_battery!(
        bike,
        dt
    )

    update_battery_temperature!(
        bike,
        dt
    )

    update_thermal_limits!(
        bike)

    update_ride!(
        bike,
        dt
    )

    return bike

end


# ============================================================
# RIDE MODE
# ============================================================

function set_mode!(
    bike::EBikeSystem,
    mode::RideMode
)

    bike.mode = mode

    if mode == MODE_OFF

        bike.command.enabled =
            false

    end

end


# ============================================================
# TELEMETRY
# ============================================================

function telemetry(
    bike::EBikeSystem
)

    return (
        mode = bike.mode,

        battery_soc =
            bike.battery.soc,

        battery_voltage =
            bike.battery.voltage,

        battery_current =
            bike.battery.current,

        battery_temperature =
            bike.battery.temperature,

        motor_rpm =
            bike.motor.rpm,

        motor_torque =
            bike.motor.torque,

        motor_power =
            bike.motor.mechanical_power,

        motor_temperature =
            bike.motor.temperature,

        rider_power =
            rider_power(bike),

        speed_kph =
            bike.speed_sensor.filtered_speed_kph,

        cadence =
            bike.cadence_sensor.filtered_rpm,

        distance_km =
            bike.ride.distance_km,

        faults =
            bike.faults

    )

end


# ============================================================
# RIDE SIMULATION
# ============================================================

function simulate!(
    bike::EBikeSystem,
    duration::Float64;
    dt = 0.01
)

    steps =
        Int(
            ceil(
                duration / dt
            )
        )

    for _ in 1:steps

        step!(
            bike,
            dt
        )

        if bike.motor.state ==
           MOTOR_FAULT

            break

        end

    end

    return telemetry(bike)

end


# ============================================================
# RESET
# ============================================================

function reset!(
    bike::EBikeSystem
)

    bike.battery.soc = 1.0
    bike.battery.voltage =
        MAX_BATTERY_VOLTAGE

    bike.battery.current = 0.0
    bike.battery.power = 0.0

    bike.motor.rpm = 0.0
    bike.motor.angular_velocity = 0.0
    bike.motor.current = 0.0
    bike.motor.torque = 0.0

    bike.motor.state =
        MOTOR_READY

    bike.ride.elapsed_time = 0.0
    bike.ride.distance_km = 0.0

    empty!(
        bike.faults
    )

    bike.command.enabled =
        false

    return bike

end


end # module
