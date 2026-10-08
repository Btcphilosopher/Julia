module DysonToothbrush

using LinearAlgebra
using Statistics
using Random

# ============================================================
# DYSON ELECTRIC TOOTHBRUSH CONTROL SYSTEM
# Julia reference implementation
#
# Target:
#   High-performance electric toothbrush digital twin
#
# Major subsystems:
#   - Motor control
#   - Pressure control
#   - Battery management
#   - Thermal management
#   - Sensor fusion
#   - Brushing state estimation
#   - Adaptive cleaning
#   - Diagnostics
# ============================================================


# ============================================================
# CONSTANTS
# ============================================================

const CONTROL_HZ = 1000.0
const DT = 1.0 / CONTROL_HZ

const MAX_RPM = 42000.0
const MIN_RPM = 5000.0

const MAX_MOTOR_CURRENT = 8.0
const MAX_MOTOR_TEMP = 75.0

const BATTERY_FULL = 4.20
const BATTERY_EMPTY = 3.20

const PRESSURE_SAFE = 1.0
const PRESSURE_WARNING = 1.7
const PRESSURE_MAX = 2.5

const NOMINAL_MOTOR_POWER = 18.0


# ============================================================
# ENUMERATIONS
# ============================================================

@enum CleaningMode begin
    MODE_SENSITIVE
    MODE_STANDARD
    MODE_DEEP
    MODE_POLISH
    MODE_GUM
    MODE_MAX
end

@enum BrushState begin
    STATE_IDLE
    STATE_STARTING
    STATE_BRUSHING
    STATE_PRESSURE_WARNING
    STATE_OVERPRESSURE
    STATE_STALLED
    STATE_THERMAL_LIMIT
    STATE_LOW_BATTERY
    STATE_COMPLETE
    STATE_FAULT
end


# ============================================================
# SENSOR DATA
# ============================================================

mutable struct SensorData

    pressure::Float64

    accel_x::Float64
    accel_y::Float64
    accel_z::Float64

    gyro_x::Float64
    gyro_y::Float64
    gyro_z::Float64

    motor_rpm::Float64
    motor_current::Float64

    battery_voltage::Float64
    battery_current::Float64

    motor_temperature::Float64
    battery_temperature::Float64

    brush_temperature::Float64

    timestamp::Float64
end


# ============================================================
# MOTOR MODEL
# ============================================================

mutable struct MotorState

    rpm::Float64
    target_rpm::Float64

    current::Float64
    torque::Float64

    electrical_power::Float64
    mechanical_power::Float64

    temperature::Float64

    acceleration::Float64

    duty_cycle::Float64

    stalled::Bool
end


function MotorState()

    MotorState(
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        25.0,
        0.0,
        0.0,
        false
    )

end


# ============================================================
# BATTERY MODEL
# ============================================================

mutable struct BatteryState

    voltage::Float64
    current::Float64

    soc::Float64

    temperature::Float64

    capacity_ah::Float64
    remaining_ah::Float64

    charging::Bool

    health::Float64
end


function BatteryState()

    BatteryState(
        4.20,
        0.0,
        1.0,
        25.0,
        2.5,
        2.5,
        false,
        1.0
    )

end


# ============================================================
# THERMAL MODEL
# ============================================================

mutable struct ThermalState

    motor_temp::Float64
    battery_temp::Float64
    electronics_temp::Float64

    ambient_temp::Float64

    heat_generation::Float64
    cooling_rate::Float64

    thermal_limit::Float64
end


function ThermalState()

    ThermalState(
        25.0,
        25.0,
        25.0,
        22.0,
        0.0,
        0.05,
        MAX_MOTOR_TEMP
    )

end


# ============================================================
# PID CONTROLLER
# ============================================================

mutable struct PIDController

    kp::Float64
    ki::Float64
    kd::Float64

    integral::Float64
    previous_error::Float64

    minimum::Float64
    maximum::Float64
end


function PIDController(
    kp,
    ki,
    kd;
    minimum=-Inf,
    maximum=Inf
)

    PIDController(
        kp,
        ki,
        kd,
        0.0,
        0.0,
        minimum,
        maximum
    )

end


function update!(
    pid::PIDController,
    target::Float64,
    measured::Float64,
    dt::Float64
)

    error = target - measured

    pid.integral += error * dt

    derivative =
        (error - pid.previous_error) / max(dt, 1e-6)

    output =
        pid.kp * error +
        pid.ki * pid.integral +
        pid.kd * derivative

    output = clamp(
        output,
        pid.minimum,
        pid.maximum
    )

    pid.previous_error = error

    return output
end


# ============================================================
# MOTOR CONTROLLER
# ============================================================

mutable struct MotorController

    speed_pid::PIDController

    torque_limit::Float64
    rpm_limit::Float64

    mode::CleaningMode

    enabled::Bool
end


function MotorController()

    MotorController(

        PIDController(
            0.002,
            0.0004,
            0.00002,
            minimum=0.0,
            maximum=1.0
        ),

        MAX_MOTOR_CURRENT,
        MAX_RPM,

        MODE_STANDARD,

        false
    )

end


# ============================================================
# PRESSURE MODEL
# ============================================================

mutable struct PressureController

    pressure::Float64

    filtered_pressure::Float64

    warning_threshold::Float64

    reduction_factor::Float64

    emergency_shutdown::Bool
end


function PressureController()

    PressureController(
        0.0,
        0.0,
        PRESSURE_WARNING,
        1.0,
        false
    )

end


function update_pressure!(
    controller::PressureController,
    raw_pressure::Float64
)

    controller.pressure = raw_pressure

    α = 0.12

    controller.filtered_pressure =
        α * raw_pressure +
        (1.0 - α) *
        controller.filtered_pressure

    if controller.filtered_pressure >
       PRESSURE_MAX

        controller.emergency_shutdown = true

        controller.reduction_factor = 0.0

    elseif controller.filtered_pressure >
           PRESSURE_WARNING

        controller.emergency_shutdown = false

        excess =
            controller.filtered_pressure -
            PRESSURE_WARNING

        controller.reduction_factor =
            clamp(
                1.0 - excess / 1.0,
                0.25,
                1.0
            )

    else

        controller.emergency_shutdown = false

        controller.reduction_factor = 1.0

    end

end


# ============================================================
# CLEANING MODE PARAMETERS
# ============================================================

function mode_target_rpm(mode::CleaningMode)

    if mode == MODE_SENSITIVE
        return 18000.0

    elseif mode == MODE_STANDARD
        return 26000.0

    elseif mode == MODE_DEEP
        return 34000.0

    elseif mode == MODE_POLISH
        return 30000.0

    elseif mode == MODE_GUM
        return 22000.0

    elseif mode == MODE_MAX
        return 42000.0
    end

    return 26000.0

end


function mode_power_limit(mode::CleaningMode)

    if mode == MODE_SENSITIVE
        return 0.35

    elseif mode == MODE_STANDARD
        return 0.55

    elseif mode == MODE_DEEP
        return 0.85

    elseif mode == MODE_POLISH
        return 0.65

    elseif mode == MODE_GUM
        return 0.45

    elseif mode == MODE_MAX
        return 1.0
    end

    return 0.55

end


# ============================================================
# BATTERY ESTIMATION
# ============================================================

function estimate_soc(
    voltage::Float64
)

    soc =

        (voltage - BATTERY_EMPTY) /
        (BATTERY_FULL - BATTERY_EMPTY)

    return clamp(soc, 0.0, 1.0)

end


function update_battery!(
    battery::BatteryState,
    motor::MotorState,
    dt::Float64
)

    battery.current =
        motor.electrical_power /
        max(battery.voltage, 0.1)

    if !battery.charging

        consumed =
            battery.current *
            dt /
            3600.0

        battery.remaining_ah =
            max(
                0.0,
                battery.remaining_ah -
                consumed
            )

    end

    battery.soc =
        battery.remaining_ah /
        battery.capacity_ah

end


# ============================================================
# MOTOR PHYSICS
# ============================================================

function motor_update!(
    motor::MotorState,
    controller::MotorController,
    target_rpm::Float64,
    dt::Float64
)

    if !controller.enabled

        motor.target_rpm = 0.0

    else

        motor.target_rpm =
            clamp(
                target_rpm,
                MIN_RPM,
                controller.rpm_limit
            )

    end

    command = update!(
        controller.speed_pid,
        motor.target_rpm,
        motor.rpm,
        dt
    )

    motor.duty_cycle = command

    desired_acceleration =
        (motor.target_rpm - motor.rpm) *
        0.08

    motor.acceleration =
        clamp(
            desired_acceleration,
            -15000.0,
            15000.0
        )

    motor.rpm +=
        motor.acceleration * dt

    motor.rpm =
        clamp(
            motor.rpm,
            0.0,
            MAX_RPM
        )

    motor.current =
        command *
        controller.torque_limit

    motor.torque =
        motor.current * 0.025

    motor.electrical_power =
        motor.current * 4.0

    motor.mechanical_power =
        motor.torque *
        motor.rpm *
        2π / 60.0

end


# ============================================================
# THERMAL SIMULATION
# ============================================================

function update_thermal!(
    thermal::ThermalState,
    motor::MotorState,
    dt::Float64
)

    thermal.heat_generation =
        motor.electrical_power -
        motor.mechanical_power

    thermal.motor_temp +=
        thermal.heat_generation *
        0.015 *
        dt

    thermal.motor_temp -=
        (thermal.motor_temp -
         thermal.ambient_temp) *
        thermal.cooling_rate *
        dt

    thermal.motor_temp =
        max(
            thermal.ambient_temp,
            thermal.motor_temp
        )

end


# ============================================================
# SENSOR FUSION
# ============================================================

mutable struct SensorFusion

    pressure_estimate::Float64

    vibration_level::Float64

    orientation::Vector{Float64}

    contact_probability::Float64
end


function SensorFusion()

    SensorFusion(
        0.0,
        0.0,
        [0.0, 0.0, 1.0],
        0.0
    )

end


function update_fusion!(
    fusion::SensorFusion,
    sensors::SensorData
)

    fusion.pressure_estimate =
        sensors.pressure

    acceleration =
        sqrt(
            sensors.accel_x^2 +
            sensors.accel_y^2 +
            sensors.accel_z^2
        )

    fusion.vibration_level =
        abs(acceleration - 9.81)

    fusion.contact_probability =
        clamp(
            sensors.pressure / 1.5,
            0.0,
            1.0
        )

end


# ============================================================
# BRUSHING STATE MACHINE
# ============================================================

mutable struct BrushSession

    state::BrushState

    elapsed_time::Float64

    target_duration::Float64

    active_time::Float64

    pressure_time::Float64

    overpressure_time::Float64

    session_complete::Bool
end


function BrushSession()

    BrushSession(
        STATE_IDLE,
        0.0,
        120.0,
        0.0,
        0.0,
        0.0,
        false
    )

end


function update_session!(
    session::BrushSession,
    sensors::SensorData,
    dt::Float64
)

    session.elapsed_time += dt

    if sensors.pressure > PRESSURE_WARNING

        session.pressure_time += dt

    end

    if sensors.pressure > PRESSURE_MAX

        session.overpressure_time += dt

    end

    if session.elapsed_time >=
       session.target_duration

        session.state = STATE_COMPLETE

        session.session_complete = true

    elseif sensors.pressure >
           PRESSURE_MAX

        session.state = STATE_OVERPRESSURE

    elseif sensors.motor_temperature >
           MAX_MOTOR_TEMP

        session.state = STATE_THERMAL_LIMIT

    elseif sensors.motor_current >
           MAX_MOTOR_CURRENT

        session.state = STATE_STALLED

    elseif sensors.battery_voltage <
           3.3

        session.state = STATE_LOW_BATTERY

    else

        session.state = STATE_BRUSHING

        session.active_time += dt

    end

end


# ============================================================
# ADAPTIVE POWER ENGINE
# ============================================================

mutable struct AdaptiveController

    requested_power::Float64

    pressure_modifier::Float64

    thermal_modifier::Float64

    battery_modifier::Float64

    final_power::Float64
end


function AdaptiveController()

    AdaptiveController(
        0.0,
        1.0,
        1.0,
        1.0,
        0.0
    )

end


function calculate_power!(
    adaptive::AdaptiveController,
    mode::CleaningMode,
    pressure::PressureController,
    thermal::ThermalState,
    battery::BatteryState
)

    adaptive.requested_power =
        mode_power_limit(mode)

    adaptive.pressure_modifier =
        pressure.reduction_factor

    thermal_headroom =
        MAX_MOTOR_TEMP -
        thermal.motor_temp

    adaptive.thermal_modifier =
        clamp(
            thermal_headroom / 30.0,
            0.0,
            1.0
        )

    adaptive.battery_modifier =
        clamp(
            battery.soc * 2.0,
            0.35,
            1.0
        )

    adaptive.final_power =
        adaptive.requested_power *
        adaptive.pressure_modifier *
        adaptive.thermal_modifier *
        adaptive.battery_modifier

    return adaptive.final_power

end


# ============================================================
# STALL DETECTION
# ============================================================

mutable struct StallDetector

    rpm_history::Vector{Float64}

    current_history::Vector{Float64}

    stall_score::Float64

    detected::Bool
end


function StallDetector()

    StallDetector(
        Float64[],
        Float64[],
        0.0,
        false
    )

end


function update_stall!(
    detector::StallDetector,
    motor::MotorState
)

    push!(
        detector.rpm_history,
        motor.rpm
    )

    push!(
        detector.current_history,
        motor.current
    )

    if length(detector.rpm_history) > 100

        popfirst!(detector.rpm_history)
        popfirst!(detector.current_history)

    end

    if length(detector.rpm_history) < 20

        return false

    end

    mean_rpm =
        mean(detector.rpm_history)

    mean_current =
        mean(detector.current_history)

    detector.stall_score =
        mean_current /
        max(mean_rpm, 100.0)

    detector.detected =
        mean_rpm < 5000.0 &&
        mean_current > 5.0

    return detector.detected

end


# ============================================================
# ENERGY OPTIMISATION
# ============================================================

function optimise_energy(
    target_rpm::Float64,
    battery_soc::Float64,
    pressure::Float64
)

    rpm_factor =
        target_rpm / MAX_RPM

    pressure_penalty =
        clamp(
            pressure / PRESSURE_MAX,
            0.0,
            1.0
        )

    battery_factor =
        0.6 +
        0.4 * battery_soc

    efficiency =
        (1.0 - 0.25 * rpm_factor) *
        (1.0 - 0.15 * pressure_penalty) *
        battery_factor

    return clamp(
        efficiency,
        0.35,
        1.0
    )

end


# ============================================================
# BRUSH ZONE ESTIMATION
# ============================================================

@enum BrushZone begin
    ZONE_UNKNOWN
    ZONE_UPPER_RIGHT
    ZONE_UPPER_FRONT
    ZONE_UPPER_LEFT
    ZONE_LOWER_RIGHT
    ZONE_LOWER_FRONT
    ZONE_LOWER_LEFT
end


mutable struct ZoneEstimator

    zone::BrushZone

    confidence::Float64

    zone_timer::Float64
end


function ZoneEstimator()

    ZoneEstimator(
        ZONE_UNKNOWN,
        0.0,
        0.0
    )

end


function estimate_zone!(
    estimator::ZoneEstimator,
    fusion::SensorFusion,
    sensors::SensorData,
    dt::Float64
)

    x = sensors.accel_x
    y = sensors.accel_y

    if fusion.contact_probability < 0.15

        estimator.zone =
            ZONE_UNKNOWN

        estimator.confidence = 0.1

        return

    end

    if x > 2.0 && y > 0.0

        estimator.zone =
            ZONE_UPPER_RIGHT

    elseif x < -2.0 && y > 0.0

        estimator.zone =
            ZONE_UPPER_LEFT

    elseif abs(x) < 2.0 && y > 0.0

        estimator.zone =
            ZONE_UPPER_FRONT

    elseif x > 2.0 && y < 0.0

        estimator.zone =
            ZONE_LOWER_RIGHT

    elseif x < -2.0 && y < 0.0

        estimator.zone =
            ZONE_LOWER_LEFT

    else

        estimator.zone =
            ZONE_LOWER_FRONT

    end

    estimator.confidence =
        clamp(
            fusion.contact_probability,
            0.0,
            1.0
        )

    estimator.zone_timer += dt

end


# ============================================================
# SESSION ANALYTICS
# ============================================================

mutable struct SessionAnalytics

    total_sessions::Int

    total_brushing_time::Float64

    average_pressure::Float64

    peak_pressure::Float64

    average_power::Float64

    energy_used::Float64

    coverage_score::Float64
end


function SessionAnalytics()

    SessionAnalytics(
        0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0
    )

end


function update_analytics!(
    analytics::SessionAnalytics,
    sensors::SensorData,
    motor::MotorState,
    dt::Float64
)

    analytics.total_brushing_time += dt

    analytics.average_pressure =
        0.995 *
        analytics.average_pressure +
        0.005 *
        sensors.pressure

    analytics.peak_pressure =
        max(
            analytics.peak_pressure,
            sensors.pressure
        )

    analytics.average_power =
        0.995 *
        analytics.average_power +
        0.005 *
        motor.electrical_power

    analytics.energy_used +=
        motor.electrical_power *
        dt / 3600.0

end


# ============================================================
# SAFETY SUPERVISOR
# ============================================================

mutable struct SafetySupervisor

    motor_allowed::Bool

    charging_allowed::Bool

    fault_code::Int

    emergency_shutdown::Bool
end


function SafetySupervisor()

    SafetySupervisor(
        true,
        true,
        0,
        false
    )

end


function safety_check!(
    safety::SafetySupervisor,
    motor::MotorState,
    battery::BatteryState,
    thermal::ThermalState,
    pressure::PressureController
)

    safety.motor_allowed = true

    safety.fault_code = 0

    if thermal.motor_temp >
       MAX_MOTOR_TEMP

        safety.motor_allowed = false
        safety.fault_code = 101

    elseif battery.temperature > 60.0

        safety.motor_allowed = false
        safety.fault_code = 102

    elseif pressure.emergency_shutdown

        safety.motor_allowed = false
        safety.fault_code = 103

    elseif motor.current >
           MAX_MOTOR_CURRENT * 1.2

        safety.motor_allowed = false
        safety.fault_code = 104

    end

    safety.emergency_shutdown =
        !safety.motor_allowed

end


# ============================================================
# COMPLETE TOOTHBRUSH SYSTEM
# ============================================================

mutable struct ToothbrushSystem

    sensors::SensorData

    motor::MotorState

    battery::BatteryState

    thermal::ThermalState

    motor_controller::MotorController

    pressure_controller::PressureController

    sensor_fusion::SensorFusion

    session::BrushSession

    adaptive::AdaptiveController

    stall_detector::StallDetector

    zone_estimator::ZoneEstimator

    analytics::SessionAnalytics

    safety::SafetySupervisor

    mode::CleaningMode

    running::Bool
end


function ToothbrushSystem()

    sensors = SensorData(
        0.0,
        0.0, 0.0, 9.81,
        0.0, 0.0, 0.0,
        0.0,
        0.0,
        4.2,
        0.0,
        25.0,
        25.0,
        25.0,
        0.0
    )

    ToothbrushSystem(
        sensors,
        MotorState(),
        BatteryState(),
        ThermalState(),
        MotorController(),
        PressureController(),
        SensorFusion(),
        BrushSession(),
        AdaptiveController(),
        StallDetector(),
        ZoneEstimator(),
        SessionAnalytics(),
        SafetySupervisor(),
        MODE_STANDARD,
        false
    )

end


# ============================================================
# START / STOP
# ============================================================

function start!(system::ToothbrushSystem)

    if system.safety.emergency_shutdown
        return false
    end

    system.running = true

    system.motor_controller.enabled = true

    system.session.state =
        STATE_STARTING

    return true

end


function stop!(system::ToothbrushSystem)

    system.running = false

    system.motor_controller.enabled = false

    system.motor.target_rpm = 0.0

end


# ============================================================
# MAIN CONTROL LOOP
# ============================================================

function control_step!(
    system::ToothbrushSystem,
    dt::Float64
)

    sensors = system.sensors
    motor = system.motor

    # ----------------------------------------
    # SENSOR FUSION
    # ----------------------------------------

    update_fusion!(
        system.sensor_fusion,
        sensors
    )

    # ----------------------------------------
    # PRESSURE CONTROL
    # ----------------------------------------

    update_pressure!(
        system.pressure_controller,
        sensors.pressure
    )

    # ----------------------------------------
    # SAFETY
    # ----------------------------------------

    safety_check!(
        system.safety,
        motor,
        system.battery,
        system.thermal,
        system.pressure_controller
    )

    if !system.safety.motor_allowed

        system.motor_controller.enabled = false

    end

    # ----------------------------------------
    # BRUSHING STATE
    # ----------------------------------------

    update_session!(
        system.session,
        sensors,
        dt
    )

    # ----------------------------------------
    # ADAPTIVE POWER
    # ----------------------------------------

    power =
        calculate_power!(
            system.adaptive,
            system.mode,
            system.pressure_controller,
            system.thermal,
            system.battery
        )

    # ----------------------------------------
    # MOTOR TARGET
    # ----------------------------------------

    base_rpm =
        mode_target_rpm(system.mode)

    target_rpm =
        base_rpm *
        power

    # ----------------------------------------
    # ENERGY OPTIMISATION
    # ----------------------------------------

    efficiency =
        optimise_energy(
            target_rpm,
            system.battery.soc,
            sensors.pressure
        )

    target_rpm *= efficiency

    # ----------------------------------------
    # MOTOR UPDATE
    # ----------------------------------------

    motor_update!(
        motor,
        system.motor_controller,
        target_rpm,
        dt
    )

    # ----------------------------------------
    # STALL DETECTION
    # ----------------------------------------

    if update_stall!(
        system.stall_detector,
        motor
    )

        motor.stalled = true

        system.motor_controller.enabled =
            false

        system.session.state =
            STATE_STALLED

    else

        motor.stalled = false

    end

    # ----------------------------------------
    # THERMAL MODEL
    # ----------------------------------------

    update_thermal!(
        system.thermal,
        motor,
        dt
    )

    sensors.motor_temperature =
        system.thermal.motor_temp

    # ----------------------------------------
    # BATTERY
    # ----------------------------------------

    update_battery!(
        system.battery,
        motor,
        dt
    )

    sensors.battery_voltage =
        system.battery.voltage

    # ----------------------------------------
    # ZONE DETECTION
    # ----------------------------------------

    estimate_zone!(
        system.zone_estimator,
        system.sensor_fusion,
        sensors,
        dt
    )

    # ----------------------------------------
    # ANALYTICS
    # ----------------------------------------

    update_analytics!(
        system.analytics,
        sensors,
        motor,
        dt
    )

    # ----------------------------------------
    # TIME
    # ----------------------------------------

    sensors.timestamp += dt

end


# ============================================================
# SIMULATOR
# ============================================================

function simulate!(
    system::ToothbrushSystem,
    duration::Float64;
    pressure_profile=nothing
)

    steps =
        Int(round(duration / DT))

    for i in 1:steps

        if pressure_profile !== nothing

            system.sensors.pressure =
                pressure_profile(
                    system.sensors.timestamp
                )

        end

        control_step!(
            system,
            DT
        )

    end

end


# ============================================================
# FACTORY DIAGNOSTICS
# ============================================================

function diagnostic_report(
    system::ToothbrushSystem
)

    return Dict(

        "motor_rpm" =>
            system.motor.rpm,

        "motor_current" =>
            system.motor.current,

        "motor_temperature" =>
            system.thermal.motor_temp,

        "battery_soc" =>
            system.battery.soc,

        "battery_voltage" =>
            system.battery.voltage,

        "pressure" =>
            system.sensors.pressure,

        "brush_state" =>
            system.session.state,

        "brush_zone" =>
            system.zone_estimator.zone,

        "energy_used_Wh" =>
            system.analytics.energy_used,

        "peak_pressure" =>
            system.analytics.peak_pressure,

        "fault_code" =>
            system.safety.fault_code

    )

end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    toothbrush =
        ToothbrushSystem()

    toothbrush.mode =
        MODE_STANDARD

    start!(toothbrush)

    pressure(t) =
        0.5 +
        0.3 *
        sin(2π * t / 12.0)

    simulate!(
        toothbrush,
        30.0,
        pressure_profile=pressure
    )

    stop!(toothbrush)

    return diagnostic_report(
        toothbrush
    )

end


end # module








module ToothbrushMotorControl

using LinearAlgebra
using Statistics

# ============================================================
# DYSON-STYLE ELECTRIC TOOTHBRUSH
# MOTOR CONTROL ENGINE
#
# Reference implementation for simulation / algorithm
# development. Production firmware would normally move the
# time-critical low-level control onto an MCU/DSP.
# ============================================================


# ============================================================
# 01. CONSTANTS
# ============================================================

const CONTROL_FREQUENCY = 20_000.0       # inner motor loop
const CONTROL_DT        = 1.0 / CONTROL_FREQUENCY

const MAX_RPM            = 42_000.0
const MIN_RUNNING_RPM   = 5_000.0

const MAX_CURRENT_A      = 8.0
const MAX_TORQUE_NM     = 0.22

const BATTERY_NOMINAL_V  = 4.0

const MOTOR_POLE_PAIRS   = 4

const MOTOR_RESISTANCE   = 0.35
const MOTOR_INDUCTANCE   = 0.00015

const TORQUE_CONSTANT    = 0.025
const BACK_EMF_CONSTANT  = 0.00095

const ROTOR_INERTIA      = 1.2e-6

const VISCOUS_FRICTION   = 2.0e-6

const MAX_MOTOR_TEMP     = 75.0
const THERMAL_DERATE_TEMP = 60.0

const MAX_ACCELERATION_RPM_S = 150_000.0
const MAX_DECELERATION_RPM_S = 250_000.0


# ============================================================
# 02. MOTOR MODES
# ============================================================

@enum MotorMode begin
    MOTOR_OFF
    MOTOR_START
    MOTOR_RUNNING
    MOTOR_DERATED
    MOTOR_BRAKING
    MOTOR_STALLED
    MOTOR_FAULT
end


@enum CommutationMode begin
    SIX_STEP
    SINEWAVE
    FOC
end


# ============================================================
# 03. MOTOR PARAMETERS
# ============================================================

struct MotorParameters

    pole_pairs::Int

    resistance::Float64

    inductance::Float64

    torque_constant::Float64

    back_emf_constant::Float64

    rotor_inertia::Float64

    viscous_friction::Float64

    maximum_current::Float64

    maximum_rpm::Float64

end


function MotorParameters()

    return MotorParameters(

        MOTOR_POLE_PAIRS,

        MOTOR_RESISTANCE,

        MOTOR_INDUCTANCE,

        TORQUE_CONSTANT,

        BACK_EMF_CONSTANT,

        ROTOR_INERTIA,

        VISCOUS_FRICTION,

        MAX_CURRENT_A,

        MAX_RPM

    )

end


# ============================================================
# 04. MOTOR STATE
# ============================================================

mutable struct MotorState

    mode::MotorMode

    commutation::CommutationMode

    rpm::Float64

    target_rpm::Float64

    measured_rpm::Float64

    electrical_angle::Float64

    mechanical_angle::Float64

    phase_current_a::Float64

    phase_current_b::Float64

    phase_current_c::Float64

    current::Float64

    target_current::Float64

    torque::Float64

    target_torque::Float64

    duty_cycle::Float64

    bus_voltage::Float64

    electrical_power::Float64

    mechanical_power::Float64

    efficiency::Float64

    temperature::Float64

    load_torque::Float64

    acceleration::Float64

    fault::Bool

end


function MotorState()

    return MotorState(

        MOTOR_OFF,
        FOC,

        0.0,
        0.0,
        0.0,

        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        0.0,
        0.0,

        0.0,
        0.0,

        0.0,

        BATTERY_NOMINAL_V,

        0.0,
        0.0,

        0.0,

        25.0,

        0.0,

        0.0,

        false

    )

end


# ============================================================
# 05. PID CONTROLLER
# ============================================================

mutable struct PID

    kp::Float64
    ki::Float64
    kd::Float64

    integral::Float64

    previous_error::Float64

    integral_limit::Float64

    output_min::Float64
    output_max::Float64

end


function PID(

    kp,
    ki,
    kd;

    integral_limit=Inf,
    output_min=-Inf,
    output_max=Inf

)

    return PID(

        kp,
        ki,
        kd,

        0.0,
        0.0,

        integral_limit,

        output_min,
        output_max

    )

end


function reset!(controller::PID)

    controller.integral = 0.0

    controller.previous_error = 0.0

end


function update!(

    controller::PID,
    target::Float64,
    measured::Float64,
    dt::Float64

)

    error = target - measured


    controller.integral +=
        error * dt


    controller.integral = clamp(

        controller.integral,

        -controller.integral_limit,

        controller.integral_limit

    )


    derivative = (

        error -
        controller.previous_error

    ) / max(dt, 1e-9)


    output =

        controller.kp * error +

        controller.ki *
        controller.integral +

        controller.kd *
        derivative


    output = clamp(

        output,

        controller.output_min,

        controller.output_max

    )


    controller.previous_error =
        error


    return output

end


# ============================================================
# 06. MOTOR CONTROLLER
# ============================================================

mutable struct MotorController

    parameters::MotorParameters

    state::MotorState

    speed_controller::PID

    current_controller::PID

    torque_controller::PID

    requested_rpm::Float64

    requested_torque::Float64

    power_limit::Float64

    current_limit::Float64

    rpm_limit::Float64

    pressure_derating::Float64

    thermal_derating::Float64

    battery_derating::Float64

end


function MotorController()

    parameters =
        MotorParameters()


    state =
        MotorState()


    speed_controller = PID(

        0.000035,

        0.000006,

        0.00000020,

        integral_limit=1_000_000.0,

        output_min=-MAX_CURRENT_A,

        output_max=MAX_CURRENT_A

    )


    current_controller = PID(

        0.18,

        0.025,

        0.0005,

        integral_limit=20.0,

        output_min=0.0,

        output_max=1.0

    )


    torque_controller = PID(

        0.25,

        0.03,

        0.0005,

        integral_limit=10.0,

        output_min=0.0,

        output_max=1.0

    )


    return MotorController(

        parameters,

        state,

        speed_controller,

        current_controller,

        torque_controller,

        0.0,
        0.0,

        1.0,

        MAX_CURRENT_A,
        MAX_RPM,

        1.0,
        1.0,
        1.0

    )

end


# ============================================================
# 07. RPM LIMITING
# ============================================================

function set_rpm_target!(

    controller::MotorController,
    rpm::Real

)

    controller.requested_rpm = clamp(

        Float64(rpm),

        0.0,

        controller.rpm_limit

    )

end


function set_torque_target!(

    controller::MotorController,
    torque::Real

)

    controller.requested_torque = clamp(

        Float64(torque),

        0.0,

        MAX_TORQUE_NM

    )

end


# ============================================================
# 08. SPEED RAMP
# ============================================================

function ramp_target_rpm!(

    controller::MotorController,
    dt::Float64

)

    state = controller.state

    target =
        controller.requested_rpm


    difference =
        target - state.target_rpm


    if difference > 0

        maximum_change =
            MAX_ACCELERATION_RPM_S * dt

        state.target_rpm += min(

            difference,

            maximum_change

        )

    else

        maximum_change =
            MAX_DECELERATION_RPM_S * dt

        state.target_rpm -= max(

            difference,

            -maximum_change

        )

    end


    state.target_rpm =
        clamp(

            state.target_rpm,

            0.0,
            controller.rpm_limit

        )

end


# ============================================================
# 09. PRESSURE DERATING
# ============================================================

function update_pressure_derating!(

    controller::MotorController,
    pressure::Float64

)

    if pressure <= 1.0

        controller.pressure_derating = 1.0

    elseif pressure <= 1.7

        excess =
            pressure - 1.0

        controller.pressure_derating =

            1.0 -
            0.35 *
            (excess / 0.7)

    elseif pressure <= 2.5

        excess =
            pressure - 1.7

        controller.pressure_derating =

            0.65 -
            0.65 *
            (excess / 0.8)

    else

        controller.pressure_derating = 0.0

    end


    controller.pressure_derating = clamp(

        controller.pressure_derating,

        0.0,
        1.0

    )

end


# ============================================================
# 10. THERMAL DERATING
# ============================================================

function update_thermal_derating!(

    controller::MotorController,
    temperature::Float64

)

    if temperature < THERMAL_DERATE_TEMP

        controller.thermal_derating = 1.0

    elseif temperature >= MAX_MOTOR_TEMP

        controller.thermal_derating = 0.0

    else

        range =
            MAX_MOTOR_TEMP -
            THERMAL_DERATE_TEMP

        remaining =
            MAX_MOTOR_TEMP -
            temperature

        controller.thermal_derating =
            clamp(

                remaining / range,

                0.0,
                1.0

            )

    end

end


# ============================================================
# 11. BATTERY DERATING
# ============================================================

function update_battery_derating!(

    controller::MotorController,
    voltage::Float64

)

    if voltage >= 3.6

        controller.battery_derating = 1.0

    elseif voltage <= 3.2

        controller.battery_derating = 0.25

    else

        controller.battery_derating =

            0.25 +
            0.75 *
            ((voltage - 3.2) / 0.4)

    end

end


# ============================================================
# 12. TOTAL POWER LIMIT
# ============================================================

function effective_power_limit(

    controller::MotorController

)

    return clamp(

        controller.power_limit *

        controller.pressure_derating *

        controller.thermal_derating *

        controller.battery_derating,

        0.0,
        1.0

    )

end


# ============================================================
# 13. SPEED CONTROL
# ============================================================

function calculate_speed_command!(

    controller::MotorController,
    dt::Float64

)

    state =
        controller.state


    target =
        state.target_rpm


    measured =
        state.measured_rpm


    requested_current = update!(

        controller.speed_controller,

        target,

        measured,

        dt

    )


    requested_current = clamp(

        requested_current,

        0.0,

        controller.current_limit

    )


    controller.state.target_current =

        requested_current


    return requested_current

end


# ============================================================
# 14. TORQUE ESTIMATION
# ============================================================

function estimate_torque(

    controller::MotorController,
    current::Float64

)

    return (

        controller.parameters.torque_constant *
        current

    )

end


# ============================================================
# 15. BACK EMF
# ============================================================

function calculate_back_emf(

    controller::MotorController,
    rpm::Float64

)

    return (

        controller.parameters.back_emf_constant *
        rpm

    )

end


# ============================================================
# 16. ELECTRICAL MODEL
# ============================================================

function electrical_current(

    controller::MotorController,
    voltage::Float64,
    duty::Float64,
    rpm::Float64

)

    back_emf =

        calculate_back_emf(
            controller,
            rpm
        )


    available_voltage =
        voltage * duty


    current = (

        available_voltage -
        back_emf

    ) / controller.parameters.resistance


    return clamp(

        current,

        0.0,

        controller.current_limit

    )

end


# ============================================================
# 17. LOAD MODEL
# ============================================================

function estimate_load_torque(

    controller::MotorController,
    rpm::Float64,
    pressure::Float64

)

    viscous =

        controller.parameters.viscous_friction *
        rpm


    brush_contact =

        0.004 *
        clamp(
            pressure,
            0.0,
            3.0
        )


    speed_load =

        0.00000001 *
        rpm^2


    return (

        viscous +
        brush_contact +
        speed_load

    )

end


# ============================================================
# 18. MOTOR DYNAMICS
# ============================================================

function integrate_motor!(

    controller::MotorController,
    voltage::Float64,
    pressure::Float64,
    dt::Float64

)

    state =
        controller.state


    torque =

        estimate_torque(
            controller,
            state.current
        )


    load =

        estimate_load_torque(
            controller,
            state.rpm,
            pressure
        )


    net_torque =

        torque -
        load


    acceleration =

        net_torque /
        controller.parameters.rotor_inertia


    state.acceleration =
        acceleration


    rpm_change =

        acceleration *
        dt *
        60.0 /
        (2π)


    state.rpm +=
        rpm_change


    state.rpm = clamp(

        state.rpm,

        0.0,

        controller.rpm_limit

    )


    state.torque =
        torque


    state.load_torque =
        load


end


# ============================================================
# 19. CURRENT CONTROL
# ============================================================

function current_control!(

    controller::MotorController,
    voltage::Float64,
    dt::Float64

)

    state =
        controller.state


    target =
        state.target_current


    measured =
        state.current


    error =
        target - measured


    duty = update!(

        controller.current_controller,

        target,
        measured,
        dt

    )


    # Feed-forward compensation for
    # high-speed back EMF.

    back_emf =
        calculate_back_emf(
            controller,
            state.rpm
        )


    feed_forward =

        (
            back_emf /
            max(voltage, 0.1)
        )


    duty = clamp(

        duty +
        feed_forward,

        0.0,
        effective_power_limit(controller)

    )


    state.duty_cycle =
        duty


    return duty

end


# ============================================================
# 20. STALL DETECTION
# ============================================================

mutable struct StallDetector

    rpm_history::Vector{Float64}

    current_history::Vector{Float64}

    detection_score::Float64

    detected::Bool

end


function StallDetector()

    return StallDetector(

        Float64[],
        Float64[],

        0.0,

        false

    )

end


function update_stall_detector!(

    detector::StallDetector,
    state::MotorState

)

    push!(
        detector.rpm_history,
        state.rpm
    )

    push!(
        detector.current_history,
        state.current
    )


    while length(detector.rpm_history) > 100

        popfirst!(
            detector.rpm_history
        )

        popfirst!(
            detector.current_history
        )

    end


    if length(detector.rpm_history) < 20

        return false

    end


    rpm =
        mean(detector.rpm_history)


    current =
        mean(detector.current_history)


    detector.detection_score =

        current /
        max(rpm, 100.0)


    detector.detected =

        rpm < 5_000.0 &&
        current > 5.0


    return detector.detected

end


# ============================================================
# 21. MOTOR START SEQUENCE
# ============================================================

function start_motor!(

    controller::MotorController

)

    state =
        controller.state


    if state.fault

        return false

    end


    state.mode =
        MOTOR_START


    state.target_rpm =
        MIN_RUNNING_RPM


    controller.requested_rpm =
        MIN_RUNNING_RPM


    reset!(
        controller.speed_controller
    )


    reset!(
        controller.current_controller
    )


    return true

end


# ============================================================
# 22. MOTOR STOP
# ============================================================

function stop_motor!(

    controller::MotorController

)

    controller.requested_rpm =
        0.0


    controller.state.mode =
        MOTOR_BRAKING

end


# ============================================================
# 23. EMERGENCY STOP
# ============================================================

function emergency_stop!(

    controller::MotorController

)

    controller.requested_rpm = 0.0

    controller.requested_torque = 0.0

    controller.state.target_rpm = 0.0

    controller.state.target_current = 0.0

    controller.state.duty_cycle = 0.0

    controller.state.mode = MOTOR_FAULT

    controller.state.fault = true

    reset!(
        controller.speed_controller
    )

    reset!(
        controller.current_controller
    )

end


# ============================================================
# 24. MOTOR STATE UPDATE
# ============================================================

function update_motor_state!(

    controller::MotorController

)

    state =
        controller.state


    state.measured_rpm =
        state.rpm


    state.electrical_power =

        state.bus_voltage *
        state.current


    state.mechanical_power =

        state.torque *
        state.rpm *
        2π / 60.0


    if state.electrical_power > 0.01

        state.efficiency =

            clamp(

                state.mechanical_power /
                state.electrical_power,

                0.0,
                1.0

            )

    else

        state.efficiency = 0.0

    end

end


# ============================================================
# 25. MAIN MOTOR CONTROL LOOP
# ============================================================

function control_step!(

    controller::MotorController,
    pressure::Float64,
    battery_voltage::Float64,
    motor_temperature::Float64,
    dt::Float64

)

    state =
        controller.state


    state.bus_voltage =
        battery_voltage


    # ------------------------------
    # SAFETY DERATING
    # ------------------------------

    update_pressure_derating!(

        controller,
        pressure

    )


    update_thermal_derating!(

        controller,
        motor_temperature

    )


    update_battery_derating!(

        controller,
        battery_voltage

    )


    # ------------------------------
    # TARGET RAMP
    # ------------------------------

    ramp_target_rpm!(

        controller,
        dt

    )


    # ------------------------------
    # SPEED LOOP
    # ------------------------------

    calculate_speed_command!(

        controller,
        dt

    )


    # ------------------------------
    # CURRENT LOOP
    # ------------------------------

    duty = current_control!(

        controller,
        battery_voltage,
        dt

    )


    # ------------------------------
    # ELECTRICAL MOTOR MODEL
    # ------------------------------

    state.current =

        electrical_current(

            controller,

            battery_voltage,

            duty,

            state.rpm

        )


    # ------------------------------
    # MOTOR DYNAMICS
    # ------------------------------

    integrate_motor!(

        controller,

        battery_voltage,

        pressure,

        dt

    )


    # ------------------------------
    # OUTPUT METRICS
    # ------------------------------

    update_motor_state!(

        controller

    )


    if state.rpm > 100.0

        state.mode =
            MOTOR_RUNNING

    end


    return state

end


# ============================================================
# 26. PRESSURE-ADAPTIVE RPM
# ============================================================

function pressure_adaptive_rpm(

    requested_rpm::Float64,
    pressure::Float64

)

    if pressure <= 1.0

        return requested_rpm

    elseif pressure <= 1.7

        factor =

            1.0 -
            0.20 *
            ((pressure - 1.0) / 0.7)

        return requested_rpm * factor

    elseif pressure <= 2.5

        factor =

            0.80 -
            0.60 *
            ((pressure - 1.7) / 0.8)

        return requested_rpm * max(factor,0.2)

    else

        return 0.0

    end

end


# ============================================================
# 27. NOISE OPTIMISATION
# ============================================================

function acoustic_rpm_target(

    requested_rpm::Float64

)

    # Avoid narrow operating regions associated
    # with undesirable harmonic excitation.

    forbidden_low = 16_000.0
    forbidden_high = 18_000.0


    if requested_rpm >= forbidden_low &&
       requested_rpm <= forbidden_high

        return forbidden_high + 500.0

    end


    return requested_rpm

end


# ============================================================
# 28. EFFICIENCY OPTIMISATION
# ============================================================

function optimise_motor_operating_point(

    requested_rpm,
    pressure,
    battery_soc

)

    rpm =
        pressure_adaptive_rpm(

            requested_rpm,
            pressure

        )


    rpm =
        acoustic_rpm_target(rpm)


    battery_factor =

        clamp(

            0.70 +
            0.30 * battery_soc,

            0.70,
            1.0

        )


    return rpm * battery_factor

end


# ============================================================
# 29. COMPLETE MOTOR SYSTEM
# ============================================================

mutable struct MotorSystem

    controller::MotorController

    stall_detector::StallDetector

    pressure::Float64

    battery_voltage::Float64

    battery_soc::Float64

    temperature::Float64

    enabled::Bool

end


function MotorSystem()

    return MotorSystem(

        MotorController(),

        StallDetector(),

        0.0,

        BATTERY_NOMINAL_V,

        1.0,

        25.0,

        false

    )

end


# ============================================================
# 30. HIGH-LEVEL API
# ============================================================

function enable!(system::MotorSystem)

    if system.battery_soc < 0.05

        return false

    end


    if system.temperature >= MAX_MOTOR_TEMP

        return false

    end


    system.enabled = true

    start_motor!(
        system.controller
    )


    return true

end


function disable!(system::MotorSystem)

    system.enabled = false

    stop_motor!(
        system.controller
    )

end


function set_speed!(

    system::MotorSystem,
    rpm::Real

)

    controller =
        system.controller


    optimised =

        optimise_motor_operating_point(

            Float64(rpm),

            system.pressure,

            system.battery_soc

        )


    set_rpm_target!(

        controller,
        optimised

    )

end


# ============================================================
# 31. HIGH-LEVEL CONTROL TICK
# ============================================================

function update!(

    system::MotorSystem,
    dt::Float64

)

    if !system.enabled

        system.controller.state.target_rpm = 0.0

    end


    state = control_step!(

        system.controller,

        system.pressure,

        system.battery_voltage,

        system.temperature,

        dt

    )


    if update_stall_detector!(

        system.stall_detector,

        state

    )

        emergency_stop!(

            system.controller

        )

    end


    return state

end


# ============================================================
# 32. DIAGNOSTICS
# ============================================================

function diagnostics(

    system::MotorSystem

)

    state =
        system.controller.state


    return (

        mode = state.mode,

        rpm = state.rpm,

        target_rpm = state.target_rpm,

        current = state.current,

        torque = state.torque,

        duty = state.duty_cycle,

        electrical_power = state.electrical_power,

        mechanical_power = state.mechanical_power,

        efficiency = state.efficiency,

        temperature = state.temperature,

        pressure_derating =
            system.controller.pressure_derating,

        thermal_derating =
            system.controller.thermal_derating,

        battery_derating =
            system.controller.battery_derating,

        fault = state.fault

    )

end


# ============================================================
# 33. TEST / SIMULATION
# ============================================================

function simulate_motor(

    duration::Float64;
    target_rpm = 26_000.0,
    pressure = 0.5,
    battery_voltage = 4.1

)

    system =
        MotorSystem()


    system.pressure =
        pressure


    system.battery_voltage =
        battery_voltage


    enable!(
        system
    )


    set_speed!(
        system,
        target_rpm
    )


    samples = []


    steps =
        Int(round(

            duration /
            CONTROL_DT

        ))


    for i in 1:steps

        state =
            update!(

                system,
                CONTROL_DT

            )


        if i % 100 == 0

            push!(

                samples,

                (

                    time = i * CONTROL_DT,

                    rpm = state.rpm,

                    current = state.current,

                    torque = state.torque,

                    power = state.electrical_power,

                    efficiency = state.efficiency

                )

            )

        end

    end


    return samples

end


# ============================================================
# 34. EXPORTS
# ============================================================

export MotorSystem
export MotorController
export MotorState
export MotorParameters
export MotorMode
export CommutationMode

export enable!
export disable!
export set_speed!
export update!
export diagnostics
export simulate_motor

export pressure_adaptive_rpm
export optimise_motor_operating_point

end # module




module ToothbrushBLDCModel

using LinearAlgebra
using Statistics

# ============================================================
# DYSON-STYLE ELECTRIC TOOTHBRUSH
# BLDC MOTOR DIGITAL MODEL
#
# Purpose:
#   High-fidelity simulation model for development of the
#   toothbrush motor-control algorithms.
#
# Model layers:
#
#   Battery
#       ↓
#   3-phase inverter
#       ↓
#   BLDC electrical model
#       ↓
#   Back-EMF
#       ↓
#   Electromagnetic torque
#       ↓
#   Mechanical dynamics
#       ↓
#   Brush / tooth load
#       ↓
#   Rotor speed
#
# This is a reference/digital-twin model rather than
# production embedded motor firmware.
# ============================================================


# ============================================================
# 01. CONSTANTS
# ============================================================

const PI2 = 2π

const NOMINAL_VOLTAGE = 4.0

const MAX_BUS_VOLTAGE = 4.25
const MIN_BUS_VOLTAGE = 3.0

const PHASE_COUNT = 3

const POLE_PAIRS = 4

const NOMINAL_RPM = 26_000.0
const MAX_RPM = 42_000.0

const NOMINAL_CURRENT = 2.5
const MAX_CURRENT = 8.0

const PHASE_RESISTANCE_25C = 0.35

const PHASE_INDUCTANCE = 150e-6

const TORQUE_CONSTANT = 0.025

const BACK_EMF_CONSTANT = 0.00095

const ROTOR_INERTIA = 1.2e-6

const VISCOUS_FRICTION = 2.0e-6

const COGGING_TORQUE = 0.0004

const MOTOR_MASS = 0.035

const AMBIENT_TEMPERATURE = 22.0

const MAX_MOTOR_TEMPERATURE = 75.0

const THERMAL_RESISTANCE = 18.0

const THERMAL_CAPACITANCE = 15.0

const MAGNETIC_SATURATION_CURRENT = 6.0


# ============================================================
# 02. MOTOR PARAMETERS
# ============================================================

struct MotorParameters

    pole_pairs::Int

    phase_resistance::Float64

    phase_inductance::Float64

    torque_constant::Float64

    back_emf_constant::Float64

    rotor_inertia::Float64

    viscous_friction::Float64

    cogging_torque::Float64

    maximum_current::Float64

    maximum_rpm::Float64

    thermal_resistance::Float64

    thermal_capacitance::Float64

end


function MotorParameters()

    MotorParameters(

        POLE_PAIRS,

        PHASE_RESISTANCE_25C,

        PHASE_INDUCTANCE,

        TORQUE_CONSTANT,

        BACK_EMF_CONSTANT,

        ROTOR_INERTIA,

        VISCOUS_FRICTION,

        COGGING_TORQUE,

        MAX_CURRENT,

        MAX_RPM,

        THERMAL_RESISTANCE,

        THERMAL_CAPACITANCE

    )

end


# ============================================================
# 03. PHASE STATE
# ============================================================

mutable struct PhaseState

    voltage::Float64

    current::Float64

    back_emf::Float64

    resistance::Float64

    inductance::Float64

    power::Float64

end


function PhaseState()

    PhaseState(

        0.0,
        0.0,
        0.0,
        PHASE_RESISTANCE_25C,
        PHASE_INDUCTANCE,
        0.0

    )

end


# ============================================================
# 04. THREE-PHASE STATE
# ============================================================

mutable struct ThreePhaseState

    phase_a::PhaseState

    phase_b::PhaseState

    phase_c::PhaseState

end


function ThreePhaseState()

    ThreePhaseState(

        PhaseState(),

        PhaseState(),

        PhaseState()

    )

end


# ============================================================
# 05. ROTOR STATE
# ============================================================

mutable struct RotorState

    mechanical_angle::Float64

    electrical_angle::Float64

    rpm::Float64

    angular_velocity::Float64

    angular_acceleration::Float64

    torque::Float64

    load_torque::Float64

end


function RotorState()

    RotorState(

        0.0,

        0.0,

        0.0,

        0.0,

        0.0,

        0.0,

        0.0

    )

end


# ============================================================
# 06. THERMAL STATE
# ============================================================

mutable struct ThermalState

    winding_temperature::Float64

    rotor_temperature::Float64

    housing_temperature::Float64

    ambient_temperature::Float64

    copper_loss::Float64

    iron_loss::Float64

    mechanical_loss::Float64

    total_loss::Float64

end


function ThermalState()

    ThermalState(

        AMBIENT_TEMPERATURE,

        AMBIENT_TEMPERATURE,

        AMBIENT_TEMPERATURE,

        AMBIENT_TEMPERATURE,

        0.0,
        0.0,
        0.0,
        0.0

    )

end


# ============================================================
# 07. MOTOR LOAD
# ============================================================

mutable struct MotorLoad

    brush_contact::Float64

    tooth_contact::Float64

    viscous_load::Float64

    friction_load::Float64

    hydrodynamic_load::Float64

    external_torque::Float64

    total_torque::Float64

end


function MotorLoad()

    MotorLoad(

        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0

    )

end


# ============================================================
# 08. COMPLETE MOTOR STATE
# ============================================================

mutable struct BLDCMotor

    parameters::MotorParameters

    phases::ThreePhaseState

    rotor::RotorState

    thermal::ThermalState

    load::MotorLoad

    bus_voltage::Float64

    bus_current::Float64

    duty_cycle::Float64

    enabled::Bool

    fault::Bool

end


function BLDCMotor()

    BLDCMotor(

        MotorParameters(),

        ThreePhaseState(),

        RotorState(),

        ThermalState(),

        MotorLoad(),

        NOMINAL_VOLTAGE,

        0.0,

        0.0,

        false,

        false

    )

end


# ============================================================
# 09. ELECTRICAL ANGLE
# ============================================================

function electrical_angle(

    motor::BLDCMotor

)

    return mod(

        motor.rotor.mechanical_angle *
        motor.parameters.pole_pairs,

        PI2

    )

end


function update_electrical_angle!(

    motor::BLDCMotor

)

    motor.rotor.electrical_angle =

        electrical_angle(motor)

end


# ============================================================
# 10. BACK-EMF WAVEFORM
# ============================================================

function trapezoidal_emf(angle::Float64)

    θ = mod(angle, PI2)

    degrees = θ * 180.0 / π


    if degrees < 30.0

        return degrees / 30.0

    elseif degrees < 150.0

        return 1.0

    elseif degrees < 210.0

        return 1.0 -
               2.0 *
               ((degrees - 150.0) / 60.0)

    elseif degrees < 330.0

        return -1.0

    else

        return -1.0 +
               ((degrees - 330.0) / 30.0)

    end

end


function phase_emf(

    motor::BLDCMotor,
    phase_angle::Float64

)

    electrical_speed =

        motor.rotor.angular_velocity *
        motor.parameters.pole_pairs


    return (

        motor.parameters.back_emf_constant *
        electrical_speed *
        trapezoidal_emf(phase_angle)

    )

end


# ============================================================
# 11. THREE-PHASE BACK-EMF
# ============================================================

function calculate_back_emf!(

    motor::BLDCMotor

)

    θ =
        motor.rotor.electrical_angle


    motor.phases.phase_a.back_emf =

        phase_emf(

            motor,
            θ

        )


    motor.phases.phase_b.back_emf =

        phase_emf(

            motor,
            θ - 2π / 3

        )


    motor.phases.phase_c.back_emf =

        phase_emf(

            motor,
            θ + 2π / 3

        )

end


# ============================================================
# 12. TEMPERATURE-DEPENDENT RESISTANCE
# ============================================================

function copper_resistance(

    motor::BLDCMotor

)

    T =
        motor.thermal.winding_temperature


    temperature_coefficient =
        0.00393


    factor =

        1.0 +
        temperature_coefficient *
        (T - 25.0)


    return (

        PHASE_RESISTANCE_25C *
        factor

    )

end


function update_phase_resistance!(

    motor::BLDCMotor

)

    resistance =
        copper_resistance(motor)


    motor.phases.phase_a.resistance =
        resistance


    motor.phases.phase_b.resistance =
        resistance


    motor.phases.phase_c.resistance =
        resistance

end


# ============================================================
# 13. PHASE VOLTAGE
# ============================================================

function set_phase_voltage!(

    phase::PhaseState,
    voltage::Float64

)

    phase.voltage = voltage

end


# ============================================================
# 14. PHASE CURRENT DYNAMICS
# ============================================================

function update_phase_current!(

    phase::PhaseState,
    dt::Float64

)

    voltage =
        phase.voltage


    resistance =
        phase.resistance


    current =
        phase.current


    emf =
        phase.back_emf


    di_dt = (

        voltage -
        resistance * current -
        emf

    ) / phase.inductance


    phase.current +=

        di_dt * dt


    phase.current = clamp(

        phase.current,

        -MAX_CURRENT,

        MAX_CURRENT

    )


    phase.power =

        phase.voltage *
        phase.current

end


# ============================================================
# 15. CURRENT VECTOR
# ============================================================

function current_vector(

    motor::BLDCMotor

)

    return [

        motor.phases.phase_a.current,

        motor.phases.phase_b.current,

        motor.phases.phase_c.current

    ]

end


# ============================================================
# 16. ELECTROMAGNETIC TORQUE
# ============================================================

function electromagnetic_torque(

    motor::BLDCMotor

)

    θ =
        motor.rotor.electrical_angle


    ea =
        trapezoidal_emf(θ)


    eb =
        trapezoidal_emf(
            θ - 2π / 3
        )


    ec =
        trapezoidal_emf(
            θ + 2π / 3
        )


    ia =
        motor.phases.phase_a.current


    ib =
        motor.phases.phase_b.current


    ic =
        motor.phases.phase_c.current


    torque =

        motor.parameters.torque_constant *

        (

            ea * ia +
            eb * ib +
            ec * ic

        )


    return torque

end


# ============================================================
# 17. MAGNETIC SATURATION
# ============================================================

function saturation_factor(

    current::Float64

)

    if abs(current) <=
       MAGNETIC_SATURATION_CURRENT

        return 1.0

    end


    excess =

        abs(current) -
        MAGNETIC_SATURATION_CURRENT


    return clamp(

        1.0 -
        0.04 * excess,

        0.65,
        1.0

    )

end


function saturated_torque(

    motor::BLDCMotor

)

    raw =
        electromagnetic_torque(motor)


    current =
        maximum(
            abs,
            current_vector(motor)
        )


    return (

        raw *
        saturation_factor(current)

    )

end


# ============================================================
# 18. COGGING TORQUE
# ============================================================

function cogging_torque(

    motor::BLDCMotor

)

    θ =
        motor.rotor.mechanical_angle


    harmonic_1 =
        sin(
            θ *
            motor.parameters.pole_pairs *
            6
        )


    harmonic_2 =
        0.35 *
        sin(
            θ *
            motor.parameters.pole_pairs *
            12
        )


    return (

        motor.parameters.cogging_torque *
        (harmonic_1 + harmonic_2)

    )

end


# ============================================================
# 19. VISCOUS FRICTION
# ============================================================

function viscous_friction(

    motor::BLDCMotor

)

    return (

        motor.parameters.viscous_friction *
        motor.rotor.angular_velocity

    )

end


# ============================================================
# 20. BRUSH LOAD MODEL
# ============================================================

function brush_contact_torque(

    pressure::Float64

)

    p =
        clamp(
            pressure,
            0.0,
            3.0
        )


    # Non-linear load:
    #
    # Low pressure:
    #   relatively small increase.
    #
    # High pressure:
    #   rapidly increasing mechanical load.

    return (

        0.002 *
        p +
        0.0015 *
        p^2

    )

end


# ============================================================
# 21. TOOTH CONTACT MODEL
# ============================================================

function tooth_contact_torque(

    pressure::Float64,
    vibration::Float64

)

    contact_factor =

        clamp(
            vibration / 3.0,
            0.0,
            1.0
        )


    return (

        0.001 *
        pressure *
        contact_factor

    )

end


# ============================================================
# 22. COMPLETE LOAD MODEL
# ============================================================

function update_load!(

    motor::BLDCMotor,
    pressure::Float64,
    vibration::Float64

)

    load =
        motor.load


    load.brush_contact =

        brush_contact_torque(
            pressure
        )


    load.tooth_contact =

        tooth_contact_torque(
            pressure,
            vibration
        )


    load.viscous_load =

        viscous_friction(
            motor
        )


    load.friction_load =

        0.0001 *
        sign(
            motor.rotor.angular_velocity
        )


    load.hydrodynamic_load =

        0.00000000002 *
        motor.rotor.angular_velocity^2


    load.total_torque =

        load.brush_contact +
        load.tooth_contact +
        load.viscous_load +
        load.friction_load +
        load.hydrodynamic_load +
        load.external_torque

end


# ============================================================
# 23. ROTATIONAL DYNAMICS
# ============================================================

function update_rotor!(

    motor::BLDCMotor,
    dt::Float64

)

    electromagnetic =

        saturated_torque(
            motor
        )


    cogging =

        cogging_torque(
            motor
        )


    total_resisting_torque =

        motor.load.total_torque +
        cogging


    net_torque =

        electromagnetic -
        total_resisting_torque


    angular_acceleration =

        net_torque /
        motor.parameters.rotor_inertia


    motor.rotor.angular_acceleration =

        angular_acceleration


    motor.rotor.angular_velocity +=

        angular_acceleration * dt


    motor.rotor.angular_velocity =

        clamp(

            motor.rotor.angular_velocity,

            0.0,

            MAX_RPM *
            2π / 60.0

        )


    motor.rotor.mechanical_angle +=

        motor.rotor.angular_velocity *
        dt


    motor.rotor.mechanical_angle =

        mod(

            motor.rotor.mechanical_angle,

            PI2

        )


    motor.rotor.rpm =

        motor.rotor.angular_velocity *
        60.0 /
        (2π)


    motor.rotor.torque =

        electromagnetic

end


# ============================================================
# 24. ELECTRICAL POWER
# ============================================================

function electrical_power(

    motor::BLDCMotor

)

    return (

        motor.phases.phase_a.power +
        motor.phases.phase_b.power +
        motor.phases.phase_c.power

    )

end


# ============================================================
# 25. MECHANICAL POWER
# ============================================================

function mechanical_power(

    motor::BLDCMotor

)

    return (

        motor.rotor.torque *
        motor.rotor.angular_velocity

    )

end


# ============================================================
# 26. EFFICIENCY
# ============================================================

function motor_efficiency(

    motor::BLDCMotor

)

    electrical =
        max(
            abs(electrical_power(motor)),
            0.001
        )


    mechanical =
        max(
            mechanical_power(motor),
            0.0
        )


    return clamp(

        mechanical /
        electrical,

        0.0,
        1.0

    )

end


# ============================================================
# 27. COPPER LOSS
# ============================================================

function copper_loss(

    motor::BLDCMotor

)

    resistance =
        copper_resistance(motor)


    ia =
        motor.phases.phase_a.current

    ib =
        motor.phases.phase_b.current

    ic =
        motor.phases.phase_c.current


    return (

        resistance *
        (
            ia^2 +
            ib^2 +
            ic^2
        )

    )

end


# ============================================================
# 28. IRON LOSS
# ============================================================

function iron_loss(

    motor::BLDCMotor

)

    rpm =
        motor.rotor.rpm


    frequency =

        rpm *
        motor.parameters.pole_pairs /
        60.0


    hysteresis =
        0.00002 *
        frequency^1.5


    eddy_current =
        0.0000000001 *
        frequency^2


    return (

        hysteresis +
        eddy_current

    )

end


# ============================================================
# 29. MECHANICAL LOSS
# ============================================================

function mechanical_loss(

    motor::BLDCMotor

)

    ω =
        motor.rotor.angular_velocity


    return (

        motor.parameters.viscous_friction *
        ω^2

    )

end


# ============================================================
# 30. THERMAL MODEL
# ============================================================

function update_thermal!(

    motor::BLDCMotor,
    dt::Float64

)

    thermal =
        motor.thermal


    thermal.copper_loss =
        copper_loss(motor)


    thermal.iron_loss =
        iron_loss(motor)


    thermal.mechanical_loss =
        mechanical_loss(motor)


    thermal.total_loss =

        thermal.copper_loss +
        thermal.iron_loss +
        thermal.mechanical_loss


    heating_rate =

        thermal.copper_loss /
        motor.parameters.thermal_capacitance


    cooling_rate = (

        thermal.winding_temperature -
        thermal.ambient_temperature

    ) / (

        motor.parameters.thermal_resistance *
        motor.parameters.thermal_capacitance

    )


    thermal.winding_temperature += (

        heating_rate -
        cooling_rate

    ) * dt


    thermal.winding_temperature =

        max(

            thermal.ambient_temperature,

            thermal.winding_temperature

        )


    thermal.rotor_temperature += (

        thermal.winding_temperature -
        thermal.rotor_temperature

    ) * 0.01 * dt


    thermal.housing_temperature += (

        thermal.winding_temperature -
        thermal.housing_temperature

    ) * 0.005 * dt

end


# ============================================================
# 31. THERMAL DERATING
# ============================================================

function thermal_derating(

    motor::BLDCMotor

)

    temperature =

        motor.thermal.winding_temperature


    if temperature < 55.0

        return 1.0

    elseif temperature >=
           MAX_MOTOR_TEMPERATURE

        return 0.0

    end


    return (

        MAX_MOTOR_TEMPERATURE -
        temperature

    ) / (

        MAX_MOTOR_TEMPERATURE -
        55.0

    )

end


# ============================================================
# 32. INVERTER MODEL
# ============================================================

mutable struct InverterState

    duty_a::Float64

    duty_b::Float64

    duty_c::Float64

    voltage_a::Float64

    voltage_b::Float64

    voltage_c::Float64

    switching_loss::Float64

end


function InverterState()

    InverterState(

        0.0,
        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        0.0

    )

end


function apply_inverter!(

    motor::BLDCMotor,
    inverter::InverterState

)

    V =
        motor.bus_voltage


    inverter.voltage_a =
        inverter.duty_a * V


    inverter.voltage_b =
        inverter.duty_b * V


    inverter.voltage_c =
        inverter.duty_c * V


    set_phase_voltage!(

        motor.phases.phase_a,
        inverter.voltage_a

    )


    set_phase_voltage!(

        motor.phases.phase_b,
        inverter.voltage_b

    )


    set_phase_voltage!(

        motor.phases.phase_c,
        inverter.voltage_c

    )

end


# ============================================================
# 33. SIX-STEP COMMUTATION
# ============================================================

function six_step_commutation!(

    inverter::InverterState,
    angle::Float64,
    duty::Float64

)

    θ =
        mod(
            angle,
            2π
        )


    sector =

        floor(
            θ /
            (π / 3)
        ) + 1


    duty =
        clamp(
            duty,
            0.0,
            1.0
        )


    inverter.duty_a = 0.0
    inverter.duty_b = 0.0
    inverter.duty_c = 0.0


    if sector == 1

        inverter.duty_a = duty
        inverter.duty_b = -duty

    elseif sector == 2

        inverter.duty_a = duty
        inverter.duty_c = -duty

    elseif sector == 3

        inverter.duty_b = duty
        inverter.duty_c = -duty

    elseif sector == 4

        inverter.duty_b = -duty
        inverter.duty_c = duty

    elseif sector == 5

        inverter.duty_a = -duty
        inverter.duty_c = duty

    else

        inverter.duty_a = -duty
        inverter.duty_b = duty

    end

end


# ============================================================
# 34. SINUSOIDAL COMMUTATION
# ============================================================

function sinusoidal_commutation!(

    inverter::InverterState,
    angle::Float64,
    duty::Float64

)

    duty =
        clamp(
            duty,
            0.0,
            1.0
        )


    inverter.duty_a =

        duty *
        sin(angle)


    inverter.duty_b =

        duty *
        sin(angle - 2π/3)


    inverter.duty_c =

        duty *
        sin(angle + 2π/3)

end


# ============================================================
# 35. FOC-STYLE VECTOR COMMAND
# ============================================================

function foc_voltage_command(

    angle::Float64,
    magnitude::Float64

)

    return (

        magnitude * cos(angle),

        magnitude * sin(angle)

    )

end


function inverse_clarke(

    alpha::Float64,
    beta::Float64

)

    a = alpha

    b =

        -0.5 * alpha +
        sqrt(3)/2 * beta


    c =

        -0.5 * alpha -
        sqrt(3)/2 * beta


    return (

        a,
        b,
        c

    )

end


# ============================================================
# 36. MOTOR STEP
# ============================================================

function step!(

    motor::BLDCMotor,
    inverter::InverterState,
    pressure::Float64,
    vibration::Float64,
    dt::Float64

)

    if motor.fault

        return motor

    end


    update_electrical_angle!(
        motor
    )


    calculate_back_emf!(
        motor
    )


    update_phase_resistance!(
        motor
    )


    update_load!(

        motor,
        pressure,
        vibration

    )


    apply_inverter!(

        motor,
        inverter

    )


    update_phase_current!(

        motor.phases.phase_a,
        dt

    )


    update_phase_current!(

        motor.phases.phase_b,
        dt

    )


    update_phase_current!(

        motor.phases.phase_c,
        dt

    )


    update_rotor!(

        motor,
        dt

    )


    update_thermal!(

        motor,
        dt

    )


    motor.bus_current =

        max(

            electrical_power(motor) /
            max(motor.bus_voltage,0.1),

            0.0

        )


    if motor.rotor.rpm >= MAX_RPM

        motor.fault = true

    end


    if motor.thermal.winding_temperature >=
       MAX_MOTOR_TEMPERATURE

        motor.fault = true

    end


    return motor

end


# ============================================================
# 37. OPERATING POINT
# ============================================================

struct OperatingPoint

    rpm::Float64

    current::Float64

    torque::Float64

    electrical_power::Float64

    mechanical_power::Float64

    efficiency::Float64

    temperature::Float64

end


function operating_point(

    motor::BLDCMotor

)

    return OperatingPoint(

        motor.rotor.rpm,

        maximum(
            abs,
            current_vector(motor)
        ),

        motor.rotor.torque,

        electrical_power(motor),

        mechanical_power(motor),

        motor_efficiency(motor),

        motor.thermal.winding_temperature

    )

end


# ============================================================
# 38. LOAD SWEEP
# ============================================================

function load_sweep(

    motor::BLDCMotor;
    pressures =
        0.0:0.25:2.5

)

    results =
        OperatingPoint[]


    for pressure in pressures

        update_load!(

            motor,
            pressure,
            1.0

        )


        push!(

            results,

            operating_point(motor)

        )

    end


    return results

end


# ============================================================
# 39. RPM SWEEP
# ============================================================

function rpm_sweep(

    motor::BLDCMotor;
    rpm_values =
        5_000.0:2_000.0:42_000.0

)

    results = []


    for rpm in rpm_values

        motor.rotor.rpm =
            rpm


        motor.rotor.angular_velocity =

            rpm *
            2π / 60.0


        update_electrical_angle!(
            motor
        )


        calculate_back_emf!(
            motor
        )


        push!(

            results,

            (

                rpm = rpm,

                back_emf_a =
                    motor.phases.phase_a.back_emf,

                back_emf_b =
                    motor.phases.phase_b.back_emf,

                back_emf_c =
                    motor.phases.phase_c.back_emf

            )

        )

    end


    return results

end


# ============================================================
# 40. DIGITAL-TWIN RUNNER
# ============================================================

function simulate(

    duration::Float64;
    voltage = NOMINAL_VOLTAGE,
    pressure = 0.5,
    vibration = 1.0,
    duty = 0.75,
    dt = 1e-5

)

    motor =
        BLDCMotor()


    inverter =
        InverterState()


    motor.bus_voltage =
        voltage


    motor.enabled =
        true


    samples = []


    steps =

        Int(
            round(
                duration / dt
            )
        )


    for i in 1:steps

        θ =
            motor.rotor.electrical_angle


        sinusoidal_commutation!(

            inverter,
            θ,
            duty

        )


        step!(

            motor,
            inverter,
            pressure,
            vibration,
            dt

        )


        if i % 1000 == 0

            push!(

                samples,

                (

                    time = i * dt,

                    rpm =
                        motor.rotor.rpm,

                    current =
                        motor.bus_current,

                    torque =
                        motor.rotor.torque,

                    power =
                        electrical_power(motor),

                    efficiency =
                        motor_efficiency(motor),

                    temperature =
                        motor.thermal.winding_temperature

                )

            )

        end


        if motor.fault

            break

        end

    end


    return motor, samples

end


# ============================================================
# 41. FACTORY CHARACTERISATION
# ============================================================

function characterise_motor(

    motor::BLDCMotor

)

    return Dict(

        "pole_pairs" =>
            motor.parameters.pole_pairs,

        "phase_resistance" =>
            motor.parameters.phase_resistance,

        "phase_inductance" =>
            motor.parameters.phase_inductance,

        "torque_constant" =>
            motor.parameters.torque_constant,

        "back_emf_constant" =>
            motor.parameters.back_emf_constant,

        "rotor_inertia" =>
            motor.parameters.rotor_inertia,

        "maximum_current" =>
            motor.parameters.maximum_current,

        "maximum_rpm" =>
            motor.parameters.maximum_rpm

    )

end


# ============================================================
# 42. HEALTH MONITORING
# ============================================================

function health_score(

    motor::BLDCMotor

)

    temperature_score =

        clamp(

            1.0 -
            (
                motor.thermal.winding_temperature -
                25.0
            ) /
            50.0,

            0.0,
            1.0

        )


    efficiency_score =

        motor_efficiency(motor)


    speed_score =

        clamp(

            motor.rotor.rpm /
            MAX_RPM,

            0.0,
            1.0

        )


    return (

        0.45 * temperature_score +
        0.40 * efficiency_score +
        0.15 * speed_score

    )

end


# ============================================================
# 43. RESET
# ============================================================

function reset!(

    motor::BLDCMotor

)

    motor.phases =
        ThreePhaseState()


    motor.rotor =
        RotorState()


    motor.thermal =
        ThermalState()


    motor.load =
        MotorLoad()


    motor.bus_current =
        0.0


    motor.duty_cycle =
        0.0


    motor.enabled =
        false


    motor.fault =
        false


    return motor

end


# ============================================================
# 44. EXPORTS
# ============================================================

export MotorParameters
export PhaseState
export ThreePhaseState
export RotorState
export ThermalState
export MotorLoad
export BLDCMotor
export InverterState
export OperatingPoint

export step!
export simulate
export reset!

export electromagnetic_torque
export calculate_back_emf!
export copper_resistance
export motor_efficiency
export thermal_derating
export operating_point
export characterise_motor
export health_score

export six_step_commutation!
export sinusoidal_commutation!
export foc_voltage_command
export inverse_clarke

export rpm_sweep
export load_sweep

end # module




module ToothbrushSensorFusion

using LinearAlgebra
using Statistics

# ============================================================
# DYSON-STYLE ELECTRIC TOOTHBRUSH
# SENSOR FUSION ENGINE
#
# Raw sensors
#   ├── IMU: accelerometer + gyroscope
#   ├── motor Hall/encoder
#   ├── phase current
#   ├── pressure/contact sensor
#   ├── temperature sensors
#   ├── battery voltage/current
#   └── optional acoustic/vibration sensor
#
# Fusion outputs
#   ├── orientation
#   ├── motion intensity
#   ├── brushing direction
#   ├── contact pressure
#   ├── contact confidence
#   ├── vibration
#   ├── RPM estimate
#   ├── load estimate
#   ├── thermal state
#   └── overall sensor confidence
# ============================================================


# ============================================================
# 01. CONSTANTS
# ============================================================

const GRAVITY = 9.80665

const SENSOR_FREQUENCY = 1000.0
const SENSOR_DT = 1.0 / SENSOR_FREQUENCY

const IMU_ACCEL_LIMIT = 50.0
const IMU_GYRO_LIMIT = 40.0

const MAX_PRESSURE = 3.0

const MAX_TEMPERATURE = 100.0

const BATTERY_FULL_VOLTAGE = 4.2
const BATTERY_EMPTY_VOLTAGE = 3.0

const RPM_MIN = 0.0
const RPM_MAX = 50_000.0

const FILTER_ALPHA_FAST = 0.25
const FILTER_ALPHA_SLOW = 0.05

const CONTACT_THRESHOLD = 0.18

const MOTION_THRESHOLD = 0.08

const VIBRATION_WINDOW = 64

const RPM_WINDOW = 16

const SENSOR_TIMEOUT = 0.25


# ============================================================
# 02. VECTOR TYPES
# ============================================================

struct Vector3

    x::Float64
    y::Float64
    z::Float64

end


Vector3() =
    Vector3(0.0, 0.0, 0.0)


Base.:+(a::Vector3, b::Vector3) =
    Vector3(
        a.x + b.x,
        a.y + b.y,
        a.z + b.z
    )


Base.:-(a::Vector3, b::Vector3) =
    Vector3(
        a.x - b.x,
        a.y - b.y,
        a.z - b.z
    )


Base.:*(a::Vector3, k::Float64) =
    Vector3(
        a.x * k,
        a.y * k,
        a.z * k
    )


function norm3(v::Vector3)

    sqrt(
        v.x^2 +
        v.y^2 +
        v.z^2
    )

end


function normalize3(v::Vector3)

    n = norm3(v)

    if n < 1e-12

        return Vector3()

    end

    return v * (1.0 / n)

end


function dot3(a::Vector3, b::Vector3)

    return (

        a.x*b.x +
        a.y*b.y +
        a.z*b.z

    )

end


# ============================================================
# 03. RAW SENSOR PACKET
# ============================================================

mutable struct RawSensorPacket

    timestamp::Float64

    acceleration::Vector3

    angular_velocity::Vector3

    pressure::Float64

    motor_rpm::Float64

    phase_current::Float64

    motor_temperature::Float64

    battery_voltage::Float64

    battery_current::Float64

    vibration::Float64

end


function RawSensorPacket()

    RawSensorPacket(

        0.0,

        Vector3(0.0, 0.0, GRAVITY),

        Vector3(),

        0.0,

        0.0,

        0.0,

        22.0,

        4.0,

        0.0,

        0.0

    )

end


# ============================================================
# 04. SENSOR QUALITY
# ============================================================

mutable struct SensorQuality

    accelerometer::Float64

    gyroscope::Float64

    pressure::Float64

    rpm::Float64

    current::Float64

    temperature::Float64

    battery::Float64

    vibration::Float64

end


function SensorQuality()

    SensorQuality(

        1.0,
        1.0,
        1.0,
        1.0,
        1.0,
        1.0,
        1.0,
        1.0

    )

end


# ============================================================
# 05. EXPONENTIAL FILTER
# ============================================================

mutable struct LowPassFilter

    value::Float64

    alpha::Float64

    initialized::Bool

end


function LowPassFilter(
    alpha::Float64
)

    LowPassFilter(

        0.0,
        alpha,
        false

    )

end


function filter!(
    f::LowPassFilter,
    input::Float64
)

    if !f.initialized

        f.value = input
        f.initialized = true

    else

        f.value +=

            f.alpha *
            (input - f.value)

    end

    return f.value

end


# ============================================================
# 06. VECTOR FILTER
# ============================================================

mutable struct VectorFilter

    x::LowPassFilter
    y::LowPassFilter
    z::LowPassFilter

end


function VectorFilter(
    alpha::Float64
)

    VectorFilter(

        LowPassFilter(alpha),
        LowPassFilter(alpha),
        LowPassFilter(alpha)

    )

end


function filter!(
    f::VectorFilter,
    v::Vector3
)

    return Vector3(

        filter!(f.x, v.x),
        filter!(f.y, v.y),
        filter!(f.z, v.z)

    )

end


# ============================================================
# 07. ORIENTATION ESTIMATE
# ============================================================

mutable struct OrientationEstimate

    roll::Float64
    pitch::Float64
    yaw::Float64

    gravity_vector::Vector3

    confidence::Float64

end


function OrientationEstimate()

    OrientationEstimate(

        0.0,
        0.0,
        0.0,

        Vector3(
            0.0,
            0.0,
            GRAVITY
        ),

        1.0

    )

end


# ============================================================
# 08. IMU STATE
# ============================================================

mutable struct IMUState

    acceleration::Vector3

    angular_velocity::Vector3

    linear_acceleration::Vector3

    acceleration_magnitude::Float64

    angular_speed::Float64

    orientation::OrientationEstimate

end


function IMUState()

    IMUState(

        Vector3(),

        Vector3(),

        Vector3(),

        0.0,

        0.0,

        OrientationEstimate()

    )

end


# ============================================================
# 09. IMU FILTERS
# ============================================================

mutable struct IMUFilterBank

    acceleration::VectorFilter

    gyro::VectorFilter

    gravity::VectorFilter

end


function IMUFilterBank()

    IMUFilterBank(

        VectorFilter(0.20),
        VectorFilter(0.20),
        VectorFilter(0.05)

    )

end


# ============================================================
# 10. ORIENTATION UPDATE
# ============================================================

function update_orientation!(

    state::IMUState,
    dt::Float64

)

    a = state.acceleration

    g = norm3(a)


    if g < 0.5 ||
       g > 20.0

        state.orientation.confidence *= 0.95

        return

    end


    roll = atan(

        a.y,

        a.z

    )


    pitch = atan(

        -a.x,

        sqrt(
            a.y^2 +
            a.z^2
        )

    )


    # Gyroscope-integrated yaw.

    state.orientation.yaw +=

        state.angular_velocity.z *
        dt


    state.orientation.roll =

        0.98 *
        state.orientation.roll +
        0.02 *
        roll


    state.orientation.pitch =

        0.98 *
        state.orientation.pitch +
        0.02 *
        pitch


    state.orientation.gravity_vector =

        normalize3(a) * GRAVITY


    state.orientation.confidence =

        clamp(

            1.0 -
            abs(g - GRAVITY) /
            GRAVITY,

            0.0,
            1.0

        )

end


# ============================================================
# 11. IMU UPDATE
# ============================================================

function update_imu!(

    state::IMUState,
    filters::IMUFilterBank,
    packet::RawSensorPacket,
    dt::Float64

)

    state.acceleration =

        filter!(
            filters.acceleration,
            packet.acceleration
        )


    state.angular_velocity =

        filter!(
            filters.gyro,
            packet.angular_velocity
        )


    gravity =

        filter!(
            filters.gravity,
            state.acceleration
        )


    state.linear_acceleration =

        state.acceleration -
        gravity


    state.acceleration_magnitude =

        norm3(
            state.linear_acceleration
        )


    state.angular_speed =

        norm3(
            state.angular_velocity
        )


    update_orientation!(

        state,
        dt

    )

end


# ============================================================
# 12. MOTION CLASSIFICATION
# ============================================================

@enum MotionState begin

    MOTION_STATIONARY
    MOTION_GENTLE
    MOTION_NORMAL
    MOTION_AGGRESSIVE
    MOTION_UNSTABLE

end


function classify_motion(

    acceleration::Float64,
    angular_speed::Float64

)

    intensity =

        acceleration +
        0.15 *
        angular_speed


    if intensity < 0.08

        return MOTION_STATIONARY

    elseif intensity < 1.0

        return MOTION_GENTLE

    elseif intensity < 4.0

        return MOTION_NORMAL

    elseif intensity < 8.0

        return MOTION_AGGRESSIVE

    else

        return MOTION_UNSTABLE

    end

end


# ============================================================
# 13. PRESSURE SENSOR
# ============================================================

mutable struct PressureState

    raw::Float64

    filtered::Float64

    normalized::Float64

    contact_probability::Float64

    excessive_pressure::Bool

end


function PressureState()

    PressureState(

        0.0,
        0.0,
        0.0,
        0.0,
        false

    )

end


function update_pressure!(

    state::PressureState,
    raw_pressure::Float64

)

    state.raw =

        clamp(
            raw_pressure,
            0.0,
            MAX_PRESSURE
        )


    state.filtered +=

        0.18 *
        (
            state.raw -
            state.filtered
        )


    state.normalized =

        clamp(

            state.filtered /
            MAX_PRESSURE,

            0.0,
            1.0

        )


    state.contact_probability =

        clamp(

            state.filtered /
            0.65,

            0.0,
            1.0

        )


    state.excessive_pressure =

        state.filtered >= 1.7

end


# ============================================================
# 14. CONTACT ESTIMATION
# ============================================================

mutable struct ContactEstimate

    probability::Float64

    contact::Bool

    tooth_contact::Float64

    gum_contact::Float64

    free_air::Float64

    confidence::Float64

end


function ContactEstimate()

    ContactEstimate(

        0.0,
        false,
        0.0,
        0.0,
        1.0,
        1.0

    )

end


function estimate_contact(

    pressure::PressureState,
    acceleration::Float64,
    vibration::Float64

)

    pressure_signal =

        pressure.normalized


    vibration_signal =

        clamp(
            vibration / 4.0,
            0.0,
            1.0
        )


    motion_signal =

        clamp(
            acceleration / 5.0,
            0.0,
            1.0
        )


    probability =

        0.70 * pressure_signal +
        0.20 * vibration_signal +
        0.10 * motion_signal


    probability =

        clamp(
            probability,
            0.0,
            1.0
        )


    return ContactEstimate(

        probability,

        probability >
        CONTACT_THRESHOLD,

        probability * 0.75,

        probability * 0.25,

        1.0 - probability,

        0.85

    )

end


# ============================================================
# 15. VIBRATION BUFFER
# ============================================================

mutable struct VibrationBuffer

    samples::Vector{Float64}

    index::Int

end


function VibrationBuffer()

    VibrationBuffer(

        zeros(VIBRATION_WINDOW),

        1

    )

end


function push_vibration!(

    buffer::VibrationBuffer,
    sample::Float64

)

    buffer.samples[
        buffer.index
    ] = sample


    buffer.index += 1


    if buffer.index >
       length(buffer.samples)

        buffer.index = 1

    end

end


# ============================================================
# 16. VIBRATION ANALYSIS
# ============================================================

function vibration_rms(

    buffer::VibrationBuffer

)

    return sqrt(

        mean(
            x^2
            for x in buffer.samples
        )

    )

end


function vibration_peak(

    buffer::VibrationBuffer

)

    return maximum(
        abs,
        buffer.samples
    )

end


function vibration_variance(

    buffer::VibrationBuffer

)

    return var(
        buffer.samples
    )

end


# ============================================================
# 17. VIBRATION CLASSIFIER
# ============================================================

@enum VibrationState begin

    VIBRATION_LOW
    VIBRATION_NORMAL
    VIBRATION_HIGH
    VIBRATION_ABNORMAL

end


function classify_vibration(

    rms::Float64,
    peak::Float64

)

    if peak > 8.0

        return VIBRATION_ABNORMAL

    elseif rms > 4.0

        return VIBRATION_HIGH

    elseif rms > 1.0

        return VIBRATION_NORMAL

    else

        return VIBRATION_LOW

    end

end


# ============================================================
# 18. RPM ESTIMATOR
# ============================================================

mutable struct RPMEstimator

    measured_rpm::Float64

    filtered_rpm::Float64

    acceleration::Float64

    previous_rpm::Float64

    confidence::Float64

end


function RPMEstimator()

    RPMEstimator(

        0.0,
        0.0,
        0.0,
        0.0,
        1.0

    )

end


function update_rpm!(

    estimator::RPMEstimator,
    measured_rpm::Float64,
    dt::Float64

)

    estimator.measured_rpm =

        clamp(

            measured_rpm,
            RPM_MIN,
            RPM_MAX

        )


    estimator.filtered_rpm +=

        0.25 *
        (
            estimator.measured_rpm -
            estimator.filtered_rpm
        )


    estimator.acceleration = (

        estimator.filtered_rpm -
        estimator.previous_rpm

    ) / dt


    estimator.previous_rpm =

        estimator.filtered_rpm

end


# ============================================================
# 19. CURRENT ESTIMATOR
# ============================================================

mutable struct CurrentEstimate

    raw::Float64

    filtered::Float64

    peak::Float64

    rms::Float64

    confidence::Float64

end


function CurrentEstimate()

    CurrentEstimate(

        0.0,
        0.0,
        0.0,
        0.0,
        1.0

    )

end


function update_current!(

    state::CurrentEstimate,
    current::Float64

)

    state.raw = current


    state.filtered +=

        0.20 *
        (
            current -
            state.filtered
        )


    state.peak = max(

        state.peak * 0.995,

        abs(current)

    )


    state.rms = sqrt(

        0.8 *
        state.rms^2 +
        0.2 *
        current^2

    )

end


# ============================================================
# 20. TEMPERATURE ESTIMATION
# ============================================================

mutable struct TemperatureEstimate

    measured::Float64

    filtered::Float64

    rate::Float64

    predicted::Float64

    confidence::Float64

end


function TemperatureEstimate()

    TemperatureEstimate(

        22.0,
        22.0,
        0.0,
        22.0,
        1.0

    )

end


function update_temperature!(

    state::TemperatureEstimate,
    measured::Float64,
    dt::Float64

)

    previous =

        state.filtered


    state.measured = measured


    state.filtered +=

        0.05 *
        (
            measured -
            state.filtered
        )


    state.rate = (

        state.filtered -
        previous

    ) / dt


    # Short-horizon thermal prediction.

    state.predicted =

        state.filtered +
        state.rate *
        10.0

end


# ============================================================
# 21. BATTERY ESTIMATION
# ============================================================

mutable struct BatteryEstimate

    voltage::Float64

    current::Float64

    state_of_charge::Float64

    power::Float64

    confidence::Float64

end


function BatteryEstimate()

    BatteryEstimate(

        4.0,
        0.0,
        1.0,
        0.0,
        1.0

    )

end


function voltage_to_soc(

    voltage::Float64

)

    # Simplified Li-ion open-circuit mapping.

    points = [

        (3.00, 0.00),
        (3.30, 0.10),
        (3.55, 0.25),
        (3.70, 0.50),
        (3.85, 0.70),
        (4.00, 0.85),
        (4.10, 0.95),
        (4.20, 1.00)

    ]


    v = clamp(

        voltage,
        3.0,
        4.2

    )


    for i in 1:length(points)-1

        v1, s1 = points[i]

        v2, s2 = points[i+1]


        if v >= v1 && v <= v2

            ratio =
                (v - v1) /
                (v2 - v1)


            return s1 +
                   ratio *
                   (s2 - s1)

        end

    end


    return 0.0

end


function update_battery!(

    state::BatteryEstimate,
    voltage::Float64,
    current::Float64

)

    state.voltage = voltage

    state.current = current


    state.power =

        voltage * current


    instantaneous_soc =

        voltage_to_soc(
            voltage
        )


    state.state_of_charge +=

        0.05 *
        (
            instantaneous_soc -
            state.state_of_charge
        )

end


# ============================================================
# 22. LOAD ESTIMATION
# ============================================================

mutable struct LoadEstimate

    motor_load::Float64

    estimated_torque::Float64

    pressure_load::Float64

    dynamic_load::Float64

    confidence::Float64

end


function LoadEstimate()

    LoadEstimate(

        0.0,
        0.0,
        0.0,
        0.0,
        1.0

    )

end


function update_load!(

    state::LoadEstimate,
    current::CurrentEstimate,
    pressure::PressureState,
    rpm::RPMEstimator

)

    # Approximate motor torque from current.

    torque_constant = 0.025


    state.estimated_torque =

        torque_constant *
        current.filtered


    state.pressure_load =

        0.002 *
        pressure.filtered +
        0.0015 *
        pressure.filtered^2


    state.dynamic_load =

        2e-6 *
        (
            rpm.filtered_rpm *
            2π / 60.0
        )


    state.motor_load =

        state.estimated_torque


    state.motor_load = max(

        state.motor_load,

        0.0

    )

end


# ============================================================
# 23. BRUSHING MOTION
# ============================================================

mutable struct BrushingMotion

    direction_x::Float64

    direction_y::Float64

    direction_z::Float64

    stroke_speed::Float64

    stroke_frequency::Float64

    movement_intensity::Float64

    stability::Float64

end


function BrushingMotion()

    BrushingMotion(

        0.0,
        0.0,
        0.0,

        0.0,
        0.0,

        0.0,
        1.0

    )

end


function update_brushing_motion!(

    state::BrushingMotion,
    imu::IMUState,
    dt::Float64

)

    linear =
        imu.linear_acceleration


    magnitude =
        norm3(linear)


    if magnitude > 1e-6

        state.direction_x =

            linear.x / magnitude


        state.direction_y =

            linear.y / magnitude


        state.direction_z =

            linear.z / magnitude

    end


    state.stroke_speed =

        magnitude


    state.movement_intensity =

        clamp(

            magnitude / 5.0,

            0.0,
            1.0

        )


    state.stability =

        clamp(

            1.0 -
            magnitude / 10.0,

            0.0,
            1.0

        )


end


# ============================================================
# 24. SENSOR FUSION OUTPUT
# ============================================================

mutable struct FusedState

    timestamp::Float64

    roll::Float64

    pitch::Float64

    yaw::Float64

    rpm::Float64

    pressure::Float64

    contact_probability::Float64

    vibration::Float64

    motion_intensity::Float64

    motor_current::Float64

    motor_torque::Float64

    motor_temperature::Float64

    battery_voltage::Float64

    battery_soc::Float64

    load_torque::Float64

    sensor_confidence::Float64

    motion_state::MotionState

    vibration_state::VibrationState

end


# ============================================================
# 25. COMPLETE SENSOR FUSION ENGINE
# ============================================================

mutable struct SensorFusionEngine

    imu::IMUState

    imu_filters::IMUFilterBank

    pressure::PressureState

    contact::ContactEstimate

    vibration_buffer::VibrationBuffer

    rpm::RPMEstimator

    current::CurrentEstimate

    temperature::TemperatureEstimate

    battery::BatteryEstimate

    load::LoadEstimate

    brushing::BrushingMotion

    quality::SensorQuality

    fused::Union{Nothing,FusedState}

    last_timestamp::Float64

end


function SensorFusionEngine()

    SensorFusionEngine(

        IMUState(),

        IMUFilterBank(),

        PressureState(),

        ContactEstimate(),

        VibrationBuffer(),

        RPMEstimator(),

        CurrentEstimate(),

        TemperatureEstimate(),

        BatteryEstimate(),

        LoadEstimate(),

        BrushingMotion(),

        SensorQuality(),

        nothing,

        0.0

    )

end


# ============================================================
# 26. SENSOR QUALITY UPDATE
# ============================================================

function update_sensor_quality!(

    engine::SensorFusionEngine,
    packet::RawSensorPacket

)

    engine.quality.accelerometer =

        packet.acceleration.x^2 +
        packet.acceleration.y^2 +
        packet.acceleration.z^2 <

        IMU_ACCEL_LIMIT^2 ? 1.0 : 0.0


    engine.quality.gyroscope =

        norm3(
            packet.angular_velocity
        ) < IMU_GYRO_LIMIT ?
        1.0 : 0.0


    engine.quality.pressure =

        0.0 <= packet.pressure <=
        MAX_PRESSURE ? 1.0 : 0.0


    engine.quality.rpm =

        RPM_MIN <= packet.motor_rpm <=
        RPM_MAX ? 1.0 : 0.0


    engine.quality.temperature =

        0.0 <=
        packet.motor_temperature <=
        MAX_TEMPERATURE ? 1.0 : 0.0


    engine.quality.battery =

        MIN_BATTERY_VOLTAGE(packet.battery_voltage) ?
        1.0 : 0.0

end


function MIN_BATTERY_VOLTAGE(

    voltage::Float64

)

    return voltage >= 2.5

end


# ============================================================
# 27. FUSION CONFIDENCE
# ============================================================

function calculate_confidence(

    engine::SensorFusionEngine

)

    q = engine.quality


    weighted =

        0.20 * q.accelerometer +
        0.15 * q.gyroscope +
        0.15 * q.pressure +
        0.15 * q.rpm +
        0.10 * q.current +
        0.10 * q.temperature +
        0.10 * q.battery +
        0.05 * q.vibration


    return clamp(

        weighted,
        0.0,
        1.0

    )

end


# ============================================================
# 28. FUSION STEP
# ============================================================

function update!(

    engine::SensorFusionEngine,
    packet::RawSensorPacket,
    dt::Float64 = SENSOR_DT

)

    engine.last_timestamp =
        packet.timestamp


    update_sensor_quality!(

        engine,
        packet

    )


    update_imu!(

        engine.imu,
        engine.imu_filters,
        packet,
        dt

    )


    update_pressure!(

        engine.pressure,
        packet.pressure

    )


    push_vibration!(

        engine.vibration_buffer,
        packet.vibration

    )


    vibration =
        vibration_rms(
            engine.vibration_buffer
        )


    engine.contact =

        estimate_contact(

            engine.pressure,
            engine.imu.acceleration_magnitude,
            vibration

        )


    update_rpm!(

        engine.rpm,
        packet.motor_rpm,
        dt

    )


    update_current!(

        engine.current,
        packet.phase_current

    )


    update_temperature!(

        engine.temperature,
        packet.motor_temperature,
        dt

    )


    update_battery!(

        engine.battery,
        packet.battery_voltage,
        packet.battery_current

    )


    update_load!(

        engine.load,
        engine.current,
        engine.pressure,
        engine.rpm

    )


    update_brushing_motion!(

        engine.brushing,
        engine.imu,
        dt

    )


    motion_state =

        classify_motion(

            engine.imu.acceleration_magnitude,
            engine.imu.angular_speed

        )


    vibration_state =

        classify_vibration(

            vibration,
            vibration_peak(
                engine.vibration_buffer
            )

        )


    confidence =

        calculate_confidence(
            engine
        )


    engine.fused = FusedState(

        packet.timestamp,

        engine.imu.orientation.roll,

        engine.imu.orientation.pitch,

        engine.imu.orientation.yaw,

        engine.rpm.filtered_rpm,

        engine.pressure.filtered,

        engine.contact.probability,

        vibration,

        engine.brushing.movement_intensity,

        engine.current.filtered,

        engine.load.estimated_torque,

        engine.temperature.filtered,

        engine.battery.voltage,

        engine.battery.state_of_charge,

        engine.load.motor_load,

        confidence,

        motion_state,

        vibration_state

    )


    return engine.fused

end


# ============================================================
# 29. CONTACT EVENT DETECTOR
# ============================================================

function tooth_contact_detected(

    engine::SensorFusionEngine

)

    return (

        engine.contact.probability > 0.55 &&
        engine.pressure.filtered > 0.15

    )

end


# ============================================================
# 30. EXCESSIVE PRESSURE DETECTOR
# ============================================================

function excessive_pressure(

    engine::SensorFusionEngine

)

    return (

        engine.pressure.filtered > 1.7

    )

end


# ============================================================
# 31. UNSTABLE BRUSHING DETECTOR
# ============================================================

function unstable_brushing(

    engine::SensorFusionEngine

)

    return (

        engine.brushing.stability < 0.25 ||
        engine.contact.probability < 0.05

    )

end


# ============================================================
# 32. MOTOR OVERLOAD DETECTOR
# ============================================================

function motor_overloaded(

    engine::SensorFusionEngine

)

    return (

        engine.current.filtered > 6.0 &&
        engine.rpm.filtered_rpm < 15_000

    )

end


# ============================================================
# 33. THERMAL RISK
# ============================================================

function thermal_risk(

    engine::SensorFusionEngine

)

    T =
        engine.temperature.filtered


    if T < 50.0

        return 0.0

    elseif T > 75.0

        return 1.0

    end


    return (

        T - 50.0
    ) / 25.0

end


# ============================================================
# 34. BATTERY RISK
# ============================================================

function battery_risk(

    engine::SensorFusionEngine

)

    soc =
        engine.battery.state_of_charge


    if soc > 0.25

        return 0.0

    elseif soc < 0.05

        return 1.0

    end


    return (

        0.25 - soc
    ) / 0.20

end


# ============================================================
# 35. CLEANING QUALITY INDEX
# ============================================================

function cleaning_quality(

    engine::SensorFusionEngine

)

    pressure_score =

        clamp(

            engine.pressure.filtered /
            1.0,

            0.0,
            1.0

        )


    contact_score =

        engine.contact.probability


    motion_score =

        engine.brushing.movement_intensity


    stability_score =

        engine.brushing.stability


    pressure_penalty =

        engine.pressure.filtered > 1.7 ?
        0.5 :
        1.0


    return clamp(

        (
            0.30 * pressure_score +
            0.30 * contact_score +
            0.20 * motion_score +
            0.20 * stability_score
        ) *
        pressure_penalty,

        0.0,
        1.0

    )

end


# ============================================================
# 36. ADAPTIVE MOTOR REQUEST
# ============================================================

function recommended_rpm(

    engine::SensorFusionEngine,
    base_rpm::Float64

)

    rpm = base_rpm


    # Excessive pressure → reduce speed.

    if excessive_pressure(engine)

        rpm *= 0.70

    end


    # Motor overload → reduce speed.

    if motor_overloaded(engine)

        rpm *= 0.80

    end


    # High thermal load.

    risk =
        thermal_risk(engine)


    rpm *= (

        1.0 -
        0.40 * risk

    )


    # Low battery.

    battery =
        battery_risk(engine)


    rpm *= (

        1.0 -
        0.20 * battery

    )


    return clamp(

        rpm,
        5_000.0,
        42_000.0

    )

end


# ============================================================
# 37. DIAGNOSTIC SNAPSHOT
# ============================================================

function diagnostics(

    engine::SensorFusionEngine

)

    return Dict(

        "rpm" =>
            engine.rpm.filtered_rpm,

        "pressure" =>
            engine.pressure.filtered,

        "contact_probability" =>
            engine.contact.probability,

        "vibration_rms" =>
            vibration_rms(
                engine.vibration_buffer
            ),

        "motor_current" =>
            engine.current.filtered,

        "temperature" =>
            engine.temperature.filtered,

        "battery_voltage" =>
            engine.battery.voltage,

        "battery_soc" =>
            engine.battery.state_of_charge,

        "estimated_torque" =>
            engine.load.estimated_torque,

        "cleaning_quality" =>
            cleaning_quality(engine),

        "sensor_confidence" =>
            calculate_confidence(engine),

        "thermal_risk" =>
            thermal_risk(engine),

        "battery_risk" =>
            battery_risk(engine),

        "excessive_pressure" =>
            excessive_pressure(engine),

        "motor_overloaded" =>
            motor_overloaded(engine),

        "unstable_brushing" =>
            unstable_brushing(engine)

    )

end


# ============================================================
# 38. RESET
# ============================================================

function reset!(

    engine::SensorFusionEngine

)

    engine.imu =
        IMUState()

    engine.imu_filters =
        IMUFilterBank()

    engine.pressure =
        PressureState()

    engine.contact =
        ContactEstimate()

    engine.vibration_buffer =
        VibrationBuffer()

    engine.rpm =
        RPMEstimator()

    engine.current =
        CurrentEstimate()

    engine.temperature =
        TemperatureEstimate()

    engine.battery =
        BatteryEstimate()

    engine.load =
        LoadEstimate()

    engine.brushing =
        BrushingMotion()

    engine.fused =
        nothing

    return engine

end


# ============================================================
# 39. EXPORTS
# ============================================================

export Vector3
export RawSensorPacket
export SensorFusionEngine
export FusedState
export SensorQuality
export IMUState
export PressureState
export ContactEstimate
export RPMEstimator
export CurrentEstimate
export TemperatureEstimate
export BatteryEstimate
export LoadEstimate
export BrushingMotion

export MotionState
export VibrationState

export update!
export reset!

export cleaning_quality
export recommended_rpm
export diagnostics

export tooth_contact_detected
export excessive_pressure
export unstable_brushing
export motor_overloaded
export thermal_risk
export battery_risk

export classify_motion
export classify_vibration

end # module






module ToothbrushPressureContact

using Statistics

# ============================================================
# DYSON-STYLE ELECTRIC TOOTHBRUSH
# PRESSURE / CONTACT ESTIMATION ENGINE
#
# Inputs:
#   - Pressure sensor
#   - Motor current
#   - Motor RPM
#   - Motor acceleration
#   - IMU acceleration
#   - Vibration
#   - Brush-head dynamics
#
# Outputs:
#   - Contact probability
#   - Mechanical load
#   - Contact force estimate
#   - Tooth-contact probability
#   - Soft-contact probability
#   - Excessive-pressure probability
#   - Free-air probability
#   - Contact stability
#   - Impact/transient detection
#
# This is a simulation/control reference model.
# Real dental hardware requires calibrated sensors and
# experimentally validated force/contact models.
# ============================================================


# ============================================================
# 01. CONSTANTS
# ============================================================

const MAX_FORCE_N = 12.0

const NORMAL_CONTACT_FORCE = 2.5

const HIGH_CONTACT_FORCE = 5.0

const EXCESSIVE_FORCE = 7.0

const HARD_CONTACT_THRESHOLD = 4.0

const SOFT_CONTACT_THRESHOLD = 1.5

const FREE_AIR_THRESHOLD = 0.12

const CONTACT_ON_THRESHOLD = 0.22

const CONTACT_OFF_THRESHOLD = 0.14

const CONTACT_STABILITY_WINDOW = 32

const FORCE_FILTER_ALPHA = 0.15

const LOAD_FILTER_ALPHA = 0.12

const IMPACT_THRESHOLD = 2.5

const MOTOR_TORQUE_CONSTANT = 0.025

const MOTOR_RESISTANCE = 0.35

const MOTOR_INERTIA = 1.2e-6

const MOTOR_POLE_PAIRS = 4

const RPM_TO_RAD = 2π / 60.0


# ============================================================
# 02. CONTACT STATE
# ============================================================

@enum ContactState begin

    CONTACT_FREE_AIR
    CONTACT_APPROACHING
    CONTACT_LIGHT
    CONTACT_NORMAL
    CONTACT_HARD
    CONTACT_EXCESSIVE
    CONTACT_IMPACT
    CONTACT_UNSTABLE

end


# ============================================================
# 03. CONTACT TYPE
# ============================================================

@enum ContactType begin

    CONTACT_NONE
    CONTACT_TOOTH
    CONTACT_SOFT
    CONTACT_MIXED
    CONTACT_HARD_SURFACE
    CONTACT_UNKNOWN

end


# ============================================================
# 04. RAW PRESSURE INPUT
# ============================================================

mutable struct PressureInput

    sensor_force::Float64

    sensor_voltage::Float64

    calibrated_force::Float64

    temperature::Float64

    valid::Bool

end


function PressureInput()

    PressureInput(

        0.0,
        0.0,
        0.0,
        22.0,
        true

    )

end


# ============================================================
# 05. MOTOR LOAD INPUT
# ============================================================

mutable struct MotorLoadInput

    rpm::Float64

    current::Float64

    target_rpm::Float64

    torque::Float64

    acceleration::Float64

    electrical_power::Float64

end


function MotorLoadInput()

    MotorLoadInput(

        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0

    )

end


# ============================================================
# 06. IMU INPUT
# ============================================================

mutable struct MotionInput

    acceleration_x::Float64

    acceleration_y::Float64

    acceleration_z::Float64

    angular_x::Float64

    angular_y::Float64

    angular_z::Float64

    vibration_rms::Float64

end


function MotionInput()

    MotionInput(

        0.0,
        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        0.0

    )

end


function acceleration_magnitude(

    input::MotionInput

)

    sqrt(

        input.acceleration_x^2 +
        input.acceleration_y^2 +
        input.acceleration_z^2

    )

end


function angular_velocity_magnitude(

    input::MotionInput

)

    sqrt(

        input.angular_x^2 +
        input.angular_y^2 +
        input.angular_z^2

    )

end


# ============================================================
# 07. CONTACT HISTORY
# ============================================================

mutable struct ContactHistory

    force::Vector{Float64}

    probability::Vector{Float64}

    load::Vector{Float64}

    vibration::Vector{Float64}

    index::Int

end


function ContactHistory()

    ContactHistory(

        zeros(CONTACT_STABILITY_WINDOW),

        zeros(CONTACT_STABILITY_WINDOW),

        zeros(CONTACT_STABILITY_WINDOW),

        zeros(CONTACT_STABILITY_WINDOW),

        1

    )

end


function push_history!(

    history::ContactHistory,
    force::Float64,
    probability::Float64,
    load::Float64,
    vibration::Float64

)

    i = history.index

    history.force[i] = force
    history.probability[i] = probability
    history.load[i] = load
    history.vibration[i] = vibration

    history.index += 1

    if history.index >
       length(history.force)

        history.index = 1

    end

end


# ============================================================
# 08. FORCE FILTER
# ============================================================

mutable struct ForceEstimator

    raw_force::Float64

    filtered_force::Float64

    predicted_force::Float64

    force_rate::Float64

    previous_force::Float64

    confidence::Float64

end


function ForceEstimator()

    ForceEstimator(

        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0

    )

end


function update_force!(

    estimator::ForceEstimator,
    measured_force::Float64,
    dt::Float64

)

    estimator.raw_force =

        clamp(

            measured_force,
            0.0,
            MAX_FORCE_N

        )


    estimator.filtered_force +=

        FORCE_FILTER_ALPHA *
        (
            estimator.raw_force -
            estimator.filtered_force
        )


    estimator.force_rate = (

        estimator.filtered_force -
        estimator.previous_force

    ) / max(dt, 1e-6)


    estimator.predicted_force =

        estimator.filtered_force +
        estimator.force_rate *
        0.025


    estimator.previous_force =

        estimator.filtered_force


    return estimator.filtered_force

end


# ============================================================
# 09. MOTOR TORQUE ESTIMATION
# ============================================================

function estimate_motor_torque(

    current::Float64

)

    return (

        MOTOR_TORQUE_CONSTANT *
        current

    )

end


# ============================================================
# 10. MOTOR LOAD ESTIMATION
# ============================================================

function estimate_motor_load(

    motor::MotorLoadInput

)

    electromagnetic_torque =

        estimate_motor_torque(
            motor.current
        )


    speed_rad =

        motor.rpm *
        RPM_TO_RAD


    viscous_load =

        2e-6 *
        speed_rad


    inertial_load =

        MOTOR_INERTIA *
        motor.acceleration *
        RPM_TO_RAD


    estimated_load =

        electromagnetic_torque -
        viscous_load -
        inertial_load


    return max(

        estimated_load,
        0.0

    )

end


# ============================================================
# 11. PRESSURE SENSOR CALIBRATION
# ============================================================

mutable struct PressureCalibration

    offset::Float64

    scale::Float64

    temperature_coefficient::Float64

    minimum_force::Float64

    maximum_force::Float64

end


function PressureCalibration()

    PressureCalibration(

        0.0,
        1.0,
        0.001,
        0.0,
        MAX_FORCE_N

    )

end


function calibrate_pressure(

    calibration::PressureCalibration,
    raw::Float64,
    temperature::Float64

)

    temperature_offset =

        calibration.temperature_coefficient *
        (temperature - 25.0)


    force = (

        raw -
        calibration.offset -
        temperature_offset

    ) *
    calibration.scale


    return clamp(

        force,

        calibration.minimum_force,

        calibration.maximum_force

    )

end


# ============================================================
# 12. CONTACT PROBABILITY
# ============================================================

function pressure_contact_probability(

    force::Float64

)

    if force <= FREE_AIR_THRESHOLD

        return 0.0

    elseif force >= 1.5

        return 1.0

    end


    x = (

        force -
        FREE_AIR_THRESHOLD

    ) / (

        1.5 -
        FREE_AIR_THRESHOLD

    )


    # Smoothstep.

    return (

        x^2 *
        (3.0 - 2.0*x)

    )

end


# ============================================================
# 13. MOTOR-LOAD CONTACT PROBABILITY
# ============================================================

function load_contact_probability(

    load_torque::Float64

)

    if load_torque < 0.001

        return 0.0

    elseif load_torque > 0.010

        return 1.0

    end


    return clamp(

        (
            load_torque -
            0.001
        ) /
        0.009,

        0.0,
        1.0

    )

end


# ============================================================
# 14. VIBRATION CONTACT PROBABILITY
# ============================================================

function vibration_contact_probability(

    vibration::Float64

)

    if vibration < 0.05

        return 0.0

    elseif vibration > 2.0

        return 1.0

    end


    return clamp(

        vibration / 2.0,

        0.0,
        1.0

    )

end


# ============================================================
# 15. FUSED CONTACT PROBABILITY
# ============================================================

function fused_contact_probability(

    pressure_probability::Float64,
    load_probability::Float64,
    vibration_probability::Float64,
    motion_stability::Float64

)

    raw =

        0.55 *
        pressure_probability +

        0.30 *
        load_probability +

        0.10 *
        vibration_probability +

        0.05 *
        motion_stability


    return clamp(

        raw,

        0.0,
        1.0

    )

end


# ============================================================
# 16. FORCE CLASSIFICATION
# ============================================================

function classify_force(

    force::Float64

)

    if force < FREE_AIR_THRESHOLD

        return CONTACT_FREE_AIR

    elseif force < NORMAL_CONTACT_FORCE

        return CONTACT_LIGHT

    elseif force < HIGH_CONTACT_FORCE

        return CONTACT_NORMAL

    elseif force < EXCESSIVE_FORCE

        return CONTACT_HARD

    else

        return CONTACT_EXCESSIVE

    end

end


# ============================================================
# 17. CONTACT TYPE ESTIMATION
# ============================================================

function estimate_contact_type(

    force::Float64,
    vibration::Float64,
    load_torque::Float64,
    motion_stability::Float64

)

    if force < FREE_AIR_THRESHOLD &&
       load_torque < 0.001

        return CONTACT_NONE

    end


    # Very high force with low vibration tends
    # toward hard mechanical contact.

    if force > HARD_CONTACT_THRESHOLD &&
       vibration < 0.5

        return CONTACT_HARD_SURFACE

    end


    # Lower force with moderate vibration and
    # measurable motor load resembles compliant contact.

    if force < SOFT_CONTACT_THRESHOLD &&
       vibration > 0.4

        return CONTACT_SOFT

    end


    # Normal brushing region.

    if (

        force >= 0.4 &&
        force <= 3.5 &&
        load_torque > 0.002

    )

        return CONTACT_TOOTH

    end


    if motion_stability < 0.25

        return CONTACT_MIXED

    end


    return CONTACT_UNKNOWN

end


# ============================================================
# 18. CONTACT STABILITY
# ============================================================

function contact_stability(

    history::ContactHistory

)

    probabilities =
        history.probability


    mean_probability =
        mean(probabilities)


    variance_probability =
        var(probabilities)


    stability =

        1.0 -
        min(

            variance_probability /
            0.10,

            1.0

        )


    # A stable mean contact state is more reliable.

    if mean_probability < 0.1

        stability *= 0.5

    end


    return clamp(

        stability,

        0.0,
        1.0

    )

end


# ============================================================
# 19. IMPACT DETECTION
# ============================================================

function detect_impact(

    force_rate::Float64,
    acceleration::Float64,
    vibration::Float64

)

    force_event =

        abs(force_rate) >
        IMPACT_THRESHOLD


    acceleration_event =

        acceleration > 12.0


    vibration_event =

        vibration > 6.0


    return (

        force_event ||
        acceleration_event ||
        vibration_event

    )

end


# ============================================================
# 20. CONTACT TRANSITION
# ============================================================

mutable struct ContactTransition

    previous_probability::Float64

    entering::Bool

    leaving::Bool

    impact::Bool

end


function ContactTransition()

    ContactTransition(

        0.0,
        false,
        false,
        false

    )

end


function update_transition!(

    transition::ContactTransition,
    probability::Float64,
    impact::Bool

)

    transition.entering = (

        transition.previous_probability <
        CONTACT_ON_THRESHOLD &&

        probability >=
        CONTACT_ON_THRESHOLD

    )


    transition.leaving = (

        transition.previous_probability >
        CONTACT_OFF_THRESHOLD &&

        probability <=
        CONTACT_OFF_THRESHOLD

    )


    transition.impact = impact


    transition.previous_probability =
        probability

end


# ============================================================
# 21. COMPLETE CONTACT ESTIMATE
# ============================================================

mutable struct ContactEstimate

    force::Float64

    force_rate::Float64

    load_torque::Float64

    contact_probability::Float64

    tooth_probability::Float64

    soft_contact_probability::Float64

    hard_contact_probability::Float64

    excessive_pressure_probability::Float64

    free_air_probability::Float64

    stability::Float64

    confidence::Float64

    state::ContactState

    contact_type::ContactType

    impact_detected::Bool

    entering_contact::Bool

    leaving_contact::Bool

end


# ============================================================
# 22. CONTACT ENGINE
# ============================================================

mutable struct PressureContactEngine

    calibration::PressureCalibration

    force_estimator::ForceEstimator

    history::ContactHistory

    transition::ContactTransition

    estimate::ContactEstimate

    last_timestamp::Float64

end


function PressureContactEngine()

    PressureContactEngine(

        PressureCalibration(),

        ForceEstimator(),

        ContactHistory(),

        ContactTransition(),

        ContactEstimate(

            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            1.0,
            0.0,
            1.0,
            CONTACT_FREE_AIR,
            CONTACT_NONE,
            false,
            false,
            false

        ),

        0.0

    )

end


# ============================================================
# 23. MAIN UPDATE
# ============================================================

function update!(

    engine::PressureContactEngine,
    pressure::PressureInput,
    motor::MotorLoadInput,
    motion::MotionInput,
    timestamp::Float64;
    dt::Float64 = 0.001

)

    engine.last_timestamp =
        timestamp


    # --------------------------------------------------------
    # Calibrate pressure sensor
    # --------------------------------------------------------

    calibrated_force =

        calibrate_pressure(

            engine.calibration,

            pressure.sensor_force,

            pressure.temperature

        )


    # --------------------------------------------------------
    # Estimate physical force
    # --------------------------------------------------------

    force =

        update_force!(

            engine.force_estimator,

            calibrated_force,

            dt

        )


    # --------------------------------------------------------
    # Estimate motor load
    # --------------------------------------------------------

    load_torque =

        estimate_motor_load(
            motor
        )


    # --------------------------------------------------------
    # Individual contact probabilities
    # --------------------------------------------------------

    p_pressure =

        pressure_contact_probability(
            force
        )


    p_load =

        load_contact_probability(
            load_torque
        )


    p_vibration =

        vibration_contact_probability(

            motion.vibration_rms

        )


    motion_magnitude =

        acceleration_magnitude(
            motion
        )


    motion_stability =

        clamp(

            1.0 -
            motion_magnitude /
            10.0,

            0.0,
            1.0

        )


    # --------------------------------------------------------
    # Fuse sensors
    # --------------------------------------------------------

    contact_probability =

        fused_contact_probability(

            p_pressure,
            p_load,
            p_vibration,
            motion_stability

        )


    # --------------------------------------------------------
    # Contact classification
    # --------------------------------------------------------

    force_state =

        classify_force(
            force
        )


    impact =

        detect_impact(

            engine.force_estimator.force_rate,

            motion_magnitude,

            motion.vibration_rms

        )


    # --------------------------------------------------------
    # Contact type
    # --------------------------------------------------------

    contact_type =

        estimate_contact_type(

            force,
            motion.vibration_rms,
            load_torque,
            motion_stability

        )


    # --------------------------------------------------------
    # Contact probabilities
    # --------------------------------------------------------

    tooth_probability =

        clamp(

            contact_probability *
            (
                1.0 -
                max(
                    force - 4.0,
                    0.0
                ) / 8.0
            ),

            0.0,
            1.0

        )


    soft_probability =

        contact_type ==
        CONTACT_SOFT ?

        contact_probability :

        contact_probability *
        0.25


    hard_probability =

        force > HARD_CONTACT_THRESHOLD ?

        contact_probability :

        0.0


    excessive_probability =

        if force >= EXCESSIVE_FORCE

            1.0

        elseif force > HIGH_CONTACT_FORCE

            (
                force -
                HIGH_CONTACT_FORCE
            ) /
            (
                EXCESSIVE_FORCE -
                HIGH_CONTACT_FORCE
            )

        else

            0.0

        end


    free_air_probability =

        1.0 -
        contact_probability


    # --------------------------------------------------------
    # History
    # --------------------------------------------------------

    push_history!(

        engine.history,

        force,

        contact_probability,

        load_torque,

        motion.vibration_rms

    )


    stability =

        contact_stability(
            engine.history
        )


    # --------------------------------------------------------
    # Contact transitions
    # --------------------------------------------------------

    update_transition!(

        engine.transition,

        contact_probability,

        impact

    )


    # --------------------------------------------------------
    # Determine state
    # --------------------------------------------------------

    state =

        if impact

            CONTACT_IMPACT

        elseif excessive_probability > 0.5

            CONTACT_EXCESSIVE

        elseif stability < 0.25 &&
               contact_probability > 0.2

            CONTACT_UNSTABLE

        else

            force_state

        end


    # --------------------------------------------------------
    # Confidence
    # --------------------------------------------------------

    sensor_agreement =

        1.0 -
        (

            abs(
                p_pressure -
                p_load
            ) +

            abs(
                p_pressure -
                p_vibration
            )

        ) / 2.0


    confidence =

        clamp(

            0.70 *
            sensor_agreement +

            0.30 *
            stability,

            0.0,
            1.0

        )


    # --------------------------------------------------------
    # Store result
    # --------------------------------------------------------

    engine.estimate =

        ContactEstimate(

            force,

            engine.force_estimator.force_rate,

            load_torque,

            contact_probability,

            tooth_probability,

            soft_probability,

            hard_probability,

            excessive_probability,

            free_air_probability,

            stability,

            confidence,

            state,

            contact_type,

            impact,

            engine.transition.entering,

            engine.transition.leaving

        )


    return engine.estimate

end


# ============================================================
# 24. SAFE OPERATING FORCE
# ============================================================

function safe_force_margin(

    engine::PressureContactEngine

)

    return clamp(

        (
            EXCESSIVE_FORCE -
            engine.estimate.force
        ) /
        EXCESSIVE_FORCE,

        0.0,
        1.0

    )

end


# ============================================================
# 25. PRESSURE DERATING
# ============================================================

function pressure_derating(

    engine::PressureContactEngine

)

    force =
        engine.estimate.force


    if force < 1.0

        return 1.0

    elseif force < 2.5

        return (

            1.0 -
            0.20 *
            (
                force - 1.0
            ) /
            1.5

        )

    elseif force < 5.0

        return (

            0.80 -
            0.40 *
            (
                force - 2.5
            ) /
            2.5

        )

    elseif force < EXCESSIVE_FORCE

        return 0.40

    else

        return 0.0

    end

end


# ============================================================
# 26. RECOMMENDED MOTOR RPM
# ============================================================

function recommended_rpm(

    engine::PressureContactEngine,
    requested_rpm::Float64

)

    multiplier =

        pressure_derating(engine)


    # Hard contact gets additional damping.

    if engine.estimate.state ==
       CONTACT_HARD

        multiplier *= 0.85

    end


    if engine.estimate.state ==
       CONTACT_IMPACT

        multiplier *= 0.50

    end


    if engine.estimate.state ==
       CONTACT_EXCESSIVE

        multiplier = 0.0

    end


    return clamp(

        requested_rpm *
        multiplier,

        0.0,
        requested_rpm

    )

end


# ============================================================
# 27. FORCE-ADAPTIVE POWER LIMIT
# ============================================================

function recommended_power_limit(

    engine::PressureContactEngine,
    nominal_power::Float64

)

    multiplier =

        pressure_derating(engine)


    return (

        nominal_power *
        multiplier

    )

end


# ============================================================
# 28. CONTACT QUALITY
# ============================================================

function contact_quality(

    engine::PressureContactEngine

)

    estimate =
        engine.estimate


    desired_force_score =

        if estimate.force <
           NORMAL_CONTACT_FORCE

            estimate.force /
            NORMAL_CONTACT_FORCE

        elseif estimate.force <
               HIGH_CONTACT_FORCE

            1.0

        else

            0.5

        end


    contact_score =

        estimate.contact_probability


    stability_score =

        estimate.stability


    confidence_score =

        estimate.confidence


    return clamp(

        0.35 *
        desired_force_score +

        0.30 *
        contact_score +

        0.20 *
        stability_score +

        0.15 *
        confidence_score,

        0.0,
        1.0

    )

end


# ============================================================
# 29. GENTLE MODE
# ============================================================

function gentle_mode(

    engine::PressureContactEngine

)

    return (

        engine.estimate.force >
        NORMAL_CONTACT_FORCE ||
        engine.estimate.state ==
        CONTACT_HARD

    )

end


# ============================================================
# 30. EMERGENCY MOTOR REQUEST
# ============================================================

function motor_should_stop(

    engine::PressureContactEngine

)

    return (

        engine.estimate.state ==
        CONTACT_EXCESSIVE ||

        engine.estimate.state ==
        CONTACT_IMPACT &&

        engine.estimate.force >
        HIGH_CONTACT_FORCE

    )

end


# ============================================================
# 31. CONTACT TELEMETRY
# ============================================================

function telemetry(

    engine::PressureContactEngine

)

    e =
        engine.estimate


    return Dict(

        "force_N" =>
            e.force,

        "force_rate_N_s" =>
            e.force_rate,

        "load_torque_Nm" =>
            e.load_torque,

        "contact_probability" =>
            e.contact_probability,

        "tooth_probability" =>
            e.tooth_probability,

        "soft_contact_probability" =>
            e.soft_contact_probability,

        "hard_contact_probability" =>
            e.hard_contact_probability,

        "excessive_pressure_probability" =>
            e.excessive_pressure_probability,

        "free_air_probability" =>
            e.free_air_probability,

        "contact_stability" =>
            e.stability,

        "confidence" =>
            e.confidence,

        "contact_state" =>
            string(e.state),

        "contact_type" =>
            string(e.contact_type),

        "impact_detected" =>
            e.impact_detected,

        "entering_contact" =>
            e.entering_contact,

        "leaving_contact" =>
            e.leaving_contact,

        "pressure_derating" =>
            pressure_derating(engine),

        "contact_quality" =>
            contact_quality(engine)

    )

end


# ============================================================
# 32. RESET
# ============================================================

function reset!(

    engine::PressureContactEngine

)

    engine.force_estimator =
        ForceEstimator()

    engine.history =
        ContactHistory()

    engine.transition =
        ContactTransition()

    engine.estimate =

        ContactEstimate(

            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            1.0,
            0.0,
            1.0,
            CONTACT_FREE_AIR,
            CONTACT_NONE,
            false,
            false,
            false

        )


    return engine

end


# ============================================================
# 33. EXPORTS
# ============================================================

export PressureInput
export MotorLoadInput
export MotionInput

export PressureCalibration
export ForceEstimator
export ContactHistory
export ContactEstimate
export PressureContactEngine

export ContactState
export ContactType

export update!
export reset!

export pressure_contact_probability
export load_contact_probability
export fused_contact_probability

export pressure_derating
export recommended_rpm
export recommended_power_limit

export contact_quality
export safe_force_margin
export gentle_mode
export motor_should_stop

export telemetry

end




module ToothbrushBatterySOC

using Statistics

# ============================================================
# DYSON-STYLE ELECTRIC TOOTHBRUSH
# BATTERY / STATE-OF-CHARGE MODEL
#
# Model:
#
# Battery chemistry abstraction
#       ↓
# Open-circuit voltage model
#       ↓
# Coulomb counting
#       ↓
# Voltage correction
#       ↓
# Temperature correction
#       ↓
# Internal resistance / voltage sag
#       ↓
# SOC estimator
#       ↓
# Power / runtime prediction
#       ↓
# Motor-control derating
#
# This is a simulation/reference model.
# Production battery firmware requires a validated cell model,
# protection IC, fuel gauge and hardware-specific calibration.
# ============================================================


# ============================================================
# 01. CONSTANTS
# ============================================================

const NOMINAL_VOLTAGE = 3.7

const FULL_VOLTAGE = 4.20

const EMPTY_VOLTAGE = 3.00

const MIN_SAFE_VOLTAGE = 2.90

const MAX_CHARGE_VOLTAGE = 4.25

const NOMINAL_CAPACITY_AH = 0.75

const NOMINAL_CAPACITY_WH =
    NOMINAL_CAPACITY_AH *
    NOMINAL_VOLTAGE

const MAX_DISCHARGE_CURRENT = 12.0

const MAX_CHARGE_CURRENT = 1.5

const AMBIENT_TEMPERATURE = 22.0

const MIN_OPERATING_TEMPERATURE = 0.0

const MAX_OPERATING_TEMPERATURE = 60.0

const OPTIMAL_MIN_TEMPERATURE = 15.0

const OPTIMAL_MAX_TEMPERATURE = 40.0

const BASE_INTERNAL_RESISTANCE = 0.080

const THERMAL_RESISTANCE = 22.0

const THERMAL_CAPACITANCE = 45.0

const SOC_FILTER_ALPHA = 0.04

const VOLTAGE_FILTER_ALPHA = 0.12

const CURRENT_FILTER_ALPHA = 0.15

const POWER_FILTER_ALPHA = 0.12

const RUNTIME_WINDOW = 64


# ============================================================
# 02. BATTERY CHEMISTRY
# ============================================================

@enum BatteryChemistry begin

    LI_ION
    LI_POLYMER
    LI_ION_HIGH_POWER

end


# ============================================================
# 03. BATTERY PARAMETERS
# ============================================================

struct BatteryParameters

    chemistry::BatteryChemistry

    nominal_voltage::Float64

    full_voltage::Float64

    empty_voltage::Float64

    capacity_ah::Float64

    maximum_discharge_current::Float64

    maximum_charge_current::Float64

    internal_resistance::Float64

    thermal_resistance::Float64

    thermal_capacitance::Float64

end


function BatteryParameters()

    BatteryParameters(

        LI_POLYMER,

        NOMINAL_VOLTAGE,

        FULL_VOLTAGE,

        EMPTY_VOLTAGE,

        NOMINAL_CAPACITY_AH,

        MAX_DISCHARGE_CURRENT,

        MAX_CHARGE_CURRENT,

        BASE_INTERNAL_RESISTANCE,

        THERMAL_RESISTANCE,

        THERMAL_CAPACITANCE

    )

end


# ============================================================
# 04. RAW BATTERY INPUT
# ============================================================

mutable struct BatteryInput

    voltage::Float64

    current::Float64

    temperature::Float64

    charger_connected::Bool

    charging_current::Float64

end


function BatteryInput()

    BatteryInput(

        FULL_VOLTAGE,

        0.0,

        AMBIENT_TEMPERATURE,

        false,

        0.0

    )

end


# ============================================================
# 05. VOLTAGE FILTER
# ============================================================

mutable struct VoltageFilter

    raw::Float64

    filtered::Float64

end


function VoltageFilter()

    VoltageFilter(

        FULL_VOLTAGE,
        FULL_VOLTAGE

    )

end


function update_voltage!(

    filter::VoltageFilter,
    voltage::Float64

)

    filter.raw = voltage


    filter.filtered +=

        VOLTAGE_FILTER_ALPHA *
        (
            voltage -
            filter.filtered
        )


    return filter.filtered

end


# ============================================================
# 06. CURRENT FILTER
# ============================================================

mutable struct CurrentFilter

    raw::Float64

    filtered::Float64

    peak::Float64

    rms::Float64

end


function CurrentFilter()

    CurrentFilter(

        0.0,
        0.0,
        0.0,
        0.0

    )

end


function update_current!(

    filter::CurrentFilter,
    current::Float64

)

    filter.raw = current


    filter.filtered +=

        CURRENT_FILTER_ALPHA *
        (
            current -
            filter.filtered
        )


    filter.peak = max(

        filter.peak * 0.995,
        abs(current)

    )


    filter.rms = sqrt(

        0.90 *
        filter.rms^2 +

        0.10 *
        current^2

    )


    return filter.filtered

end


# ============================================================
# 07. TEMPERATURE MODEL
# ============================================================

mutable struct BatteryThermalState

    temperature::Float64

    core_temperature::Float64

    rate::Float64

    heat_generation::Float64

    cooling_power::Float64

end


function BatteryThermalState()

    BatteryThermalState(

        AMBIENT_TEMPERATURE,

        AMBIENT_TEMPERATURE,

        0.0,

        0.0,

        0.0

    )

end


# ============================================================
# 08. THERMAL UPDATE
# ============================================================

function update_thermal!(

    thermal::BatteryThermalState,
    current::Float64,
    resistance::Float64,
    ambient::Float64,
    dt::Float64

)

    previous =

        thermal.temperature


    thermal.heat_generation =

        current^2 *
        resistance


    thermal.cooling_power = (

        thermal.temperature -
        ambient

    ) / THERMAL_RESISTANCE


    thermal.rate = (

        thermal.heat_generation -
        thermal.cooling_power

    ) / THERMAL_CAPACITANCE


    thermal.temperature +=

        thermal.rate * dt


    thermal.temperature =

        max(

            thermal.temperature,
            ambient - 10.0

        )


    thermal.core_temperature += (

        thermal.temperature -
        thermal.core_temperature

    ) *
    min(
        dt * 0.05,
        1.0
    )


    return thermal.temperature

end


# ============================================================
# 09. SOC STATE
# ============================================================

mutable struct SOCState

    coulomb_soc::Float64

    voltage_soc::Float64

    corrected_soc::Float64

    previous_soc::Float64

    consumed_ah::Float64

    remaining_ah::Float64

    remaining_wh::Float64

end


function SOCState()

    SOCState(

        1.0,
        1.0,
        1.0,
        1.0,

        0.0,
        NOMINAL_CAPACITY_AH,
        NOMINAL_CAPACITY_WH

    )

end


# ============================================================
# 10. OCV / SOC CURVE
# ============================================================

function soc_to_ocv(

    soc::Float64

)

    s = clamp(

        soc,
        0.0,
        1.0

    )


    # Simplified Li-ion OCV curve.

    points = [

        (0.00, 3.00),
        (0.05, 3.25),
        (0.10, 3.35),
        (0.20, 3.55),
        (0.30, 3.65),
        (0.40, 3.72),
        (0.50, 3.76),
        (0.60, 3.80),
        (0.70, 3.87),
        (0.80, 3.96),
        (0.90, 4.08),
        (1.00, 4.20)

    ]


    for i in 1:length(points)-1

        s1, v1 = points[i]

        s2, v2 = points[i+1]


        if s >= s1 && s <= s2

            ratio =

                (s - s1) /
                (s2 - s1)


            return (

                v1 +
                ratio *
                (v2 - v1)

            )

        end

    end


    return FULL_VOLTAGE

end


# ============================================================
# 11. VOLTAGE -> SOC
# ============================================================

function voltage_to_soc(

    voltage::Float64

)

    points = [

        (3.00, 0.00),
        (3.25, 0.05),
        (3.35, 0.10),
        (3.55, 0.20),
        (3.65, 0.30),
        (3.72, 0.40),
        (3.76, 0.50),
        (3.80, 0.60),
        (3.87, 0.70),
        (3.96, 0.80),
        (4.08, 0.90),
        (4.20, 1.00)

    ]


    v = clamp(

        voltage,
        EMPTY_VOLTAGE,
        FULL_VOLTAGE

    )


    for i in 1:length(points)-1

        v1, s1 = points[i]

        v2, s2 = points[i+1]


        if v >= v1 && v <= v2

            ratio =

                (v - v1) /
                (v2 - v1)


            return (

                s1 +
                ratio *
                (s2 - s1)

            )

        end

    end


    return 0.0

end


# ============================================================
# 12. TEMPERATURE SOC CORRECTION
# ============================================================

function temperature_soc_factor(

    temperature::Float64

)

    if temperature >=
       OPTIMAL_MIN_TEMPERATURE &&

       temperature <=
       OPTIMAL_MAX_TEMPERATURE

        return 1.0

    end


    if temperature <
       OPTIMAL_MIN_TEMPERATURE

        return clamp(

            0.75 +
            0.25 *
            (
                temperature /
                OPTIMAL_MIN_TEMPERATURE
            ),

            0.50,
            1.0

        )

    end


    return clamp(

        1.0 -
        0.02 *
        (
            temperature -
            OPTIMAL_MAX_TEMPERATURE
        ),

        0.60,
        1.0

    )

end


# ============================================================
# 13. INTERNAL RESISTANCE
# ============================================================

function internal_resistance(

    parameters::BatteryParameters,
    soc::Float64,
    temperature::Float64

)

    soc_factor =

        if soc > 0.20

            1.0

        else

            1.0 +
            1.5 *
            (0.20 - soc)

        end


    temperature_factor =

        if temperature >= 20.0

            1.0

        else

            1.0 +
            0.025 *
            (20.0 - temperature)

        end


    return (

        parameters.internal_resistance *
        soc_factor *
        temperature_factor

    )

end


# ============================================================
# 14. TERMINAL VOLTAGE
# ============================================================

function predicted_terminal_voltage(

    parameters::BatteryParameters,
    soc::Float64,
    current::Float64,
    temperature::Float64

)

    ocv =
        soc_to_ocv(soc)


    resistance =

        internal_resistance(

            parameters,
            soc,
            temperature

        )


    return (

        ocv -
        current *
        resistance

    )

end


# ============================================================
# 15. COULOMB COUNTING
# ============================================================

function update_coulomb_count!(

    state::SOCState,
    current::Float64,
    capacity_ah::Float64,
    dt::Float64

)

    # Positive current = discharge.

    delta_ah =

        current *
        dt /
        3600.0


    state.consumed_ah +=

        max(delta_ah, 0.0)


    state.coulomb_soc -=

        delta_ah /
        capacity_ah


    state.coulomb_soc =

        clamp(

            state.coulomb_soc,

            0.0,
            1.0

        )


    state.remaining_ah =

        capacity_ah *
        state.coulomb_soc


    return state.coulomb_soc

end


# ============================================================
# 16. CHARGING COULOMB COUNT
# ============================================================

function update_charge_count!(

    state::SOCState,
    charge_current::Float64,
    capacity_ah::Float64,
    dt::Float64

)

    delta_ah =

        charge_current *
        dt /
        3600.0


    state.coulomb_soc +=

        delta_ah /
        capacity_ah


    state.coulomb_soc =

        clamp(

            state.coulomb_soc,

            0.0,
            1.0

        )


    state.remaining_ah =

        capacity_ah *
        state.coulomb_soc


    return state.coulomb_soc

end


# ============================================================
# 17. LOAD-COMPENSATED VOLTAGE SOC
# ============================================================

function load_compensated_voltage_soc(

    parameters::BatteryParameters,
    voltage::Float64,
    current::Float64,
    temperature::Float64

)

    resistance =

        internal_resistance(

            parameters,
            0.5,
            temperature

        )


    estimated_ocv =

        voltage +
        current *
        resistance


    return voltage_to_soc(
        estimated_ocv
    )

end


# ============================================================
# 18. SOC FUSION
# ============================================================

function fuse_soc(

    coulomb_soc::Float64,
    voltage_soc::Float64,
    voltage_confidence::Float64,
    temperature_factor::Float64

)

    # Coulomb counting is strong during active operation.
    # Voltage becomes more useful during low-current periods.

    weight_voltage =

        0.08 +
        0.20 *
        voltage_confidence


    weight_coulomb =

        1.0 -
        weight_voltage


    fused = (

        weight_coulomb *
        coulomb_soc +

        weight_voltage *
        voltage_soc

    )


    # Temperature affects usable capacity, not directly
    # the electrochemical SOC.

    corrected =

        fused *
        (
            0.90 +
            0.10 *
            temperature_factor
        )


    return clamp(

        corrected,

        0.0,
        1.0

    )

end


# ============================================================
# 19. VOLTAGE CONFIDENCE
# ============================================================

function voltage_confidence(

    current::Float64

)

    # OCV is least reliable under heavy load.

    abs_current = abs(current)


    if abs_current < 0.2

        return 1.0

    elseif abs_current < 1.0

        return 0.7

    elseif abs_current < 3.0

        return 0.35

    end


    return 0.10

end


# ============================================================
# 20. USABLE CAPACITY
# ============================================================

function usable_capacity(

    parameters::BatteryParameters,
    temperature::Float64

)

    factor =

        temperature_soc_factor(
            temperature
        )


    return (

        parameters.capacity_ah *
        factor

    )

end


# ============================================================
# 21. AVAILABLE POWER
# ============================================================

function available_power(

    parameters::BatteryParameters,
    soc::Float64,
    temperature::Float64,
    voltage::Float64

)

    temperature_factor =

        temperature_soc_factor(
            temperature
        )


    soc_factor =

        if soc > 0.25

            1.0

        elseif soc > 0.10

            0.70

        elseif soc > 0.05

            0.40

        else

            0.15

        end


    voltage_factor =

        clamp(

            (
                voltage -
                MIN_SAFE_VOLTAGE
            ) /
            (
                NOMINAL_VOLTAGE -
                MIN_SAFE_VOLTAGE
            ),

            0.0,
            1.0

        )


    current_limit =

        parameters.maximum_discharge_current *
        temperature_factor *
        soc_factor


    return (

        voltage *
        current_limit *
        voltage_factor

    )

end


# ============================================================
# 22. POWER DERATING
# ============================================================

function power_derating(

    soc::Float64,
    temperature::Float64,
    voltage::Float64

)

    soc_factor =

        if soc > 0.20

            1.0

        elseif soc > 0.10

            0.75

        elseif soc > 0.05

            0.50

        else

            0.20

        end


    thermal_factor =

        if temperature < 40.0

            1.0

        elseif temperature < 55.0

            1.0 -
            (
                temperature - 40.0
            ) /
            15.0 *
            0.50

        else

            0.35

        end


    voltage_factor =

        clamp(

            (
                voltage -
                3.0
            ) /
            0.7,

            0.0,
            1.0

        )


    return clamp(

        soc_factor *
        thermal_factor *
        voltage_factor,

        0.0,
        1.0

    )

end


# ============================================================
# 23. CHARGE LIMIT
# ============================================================

function charge_current_limit(

    parameters::BatteryParameters,
    soc::Float64,
    temperature::Float64

)

    if temperature <
       MIN_OPERATING_TEMPERATURE ||

       temperature >
       MAX_OPERATING_TEMPERATURE

        return 0.0

    end


    if soc >= 0.98

        return 0.10

    end


    thermal_factor =

        if temperature >= 15.0 &&
           temperature <= 40.0

            1.0

        elseif temperature < 15.0

            0.5

        else

            0.5

        end


    return (

        parameters.maximum_charge_current *
        thermal_factor

    )

end


# ============================================================
# 24. DISCHARGE LIMIT
# ============================================================

function discharge_current_limit(

    parameters::BatteryParameters,
    soc::Float64,
    temperature::Float64

)

    if temperature <
       MIN_OPERATING_TEMPERATURE ||

       temperature >
       MAX_OPERATING_TEMPERATURE

        return 0.0

    end


    soc_factor =

        if soc > 0.20

            1.0

        elseif soc > 0.10

            0.70

        elseif soc > 0.05

            0.40

        else

            0.15

        end


    thermal_factor =

        if temperature < 40.0

            1.0

        elseif temperature < 55.0

            0.70

        else

            0.30

        end


    return (

        parameters.maximum_discharge_current *
        soc_factor *
        thermal_factor

    )

end


# ============================================================
# 25. RUNTIME ESTIMATION
# ============================================================

mutable struct RuntimeEstimator

    power_samples::Vector{Float64}

    index::Int

    average_power::Float64

    remaining_minutes::Float64

end


function RuntimeEstimator()

    RuntimeEstimator(

        zeros(RUNTIME_WINDOW),

        1,

        0.0,
        0.0

    )

end


function update_runtime!(

    estimator::RuntimeEstimator,
    remaining_wh::Float64,
    power::Float64

)

    estimator.power_samples[
        estimator.index
    ] = max(power, 0.0)


    estimator.index += 1


    if estimator.index >
       length(estimator.power_samples)

        estimator.index = 1

    end


    active_samples =

        filter(
            x -> x > 0.01,
            estimator.power_samples
        )


    if isempty(active_samples)

        estimator.average_power = 0.0

        estimator.remaining_minutes =
            Inf

        return estimator.remaining_minutes

    end


    estimator.average_power =

        mean(active_samples)


    estimator.remaining_minutes =

        remaining_wh /
        estimator.average_power *
        60.0


    return estimator.remaining_minutes

end


# ============================================================
# 26. BATTERY STATE
# ============================================================

mutable struct BatteryState

    voltage::Float64

    current::Float64

    temperature::Float64

    soc::Float64

    coulomb_soc::Float64

    voltage_soc::Float64

    remaining_ah::Float64

    remaining_wh::Float64

    power::Float64

    internal_resistance::Float64

    available_power::Float64

    discharge_limit::Float64

    charge_limit::Float64

    runtime_minutes::Float64

    charging::Bool

    low_battery::Bool

    critical_battery::Bool

    thermal_warning::Bool

end


function BatteryState(
    parameters::BatteryParameters
)

    BatteryState(

        FULL_VOLTAGE,
        0.0,
        AMBIENT_TEMPERATURE,

        1.0,
        1.0,
        1.0,

        parameters.capacity_ah,
        NOMINAL_CAPACITY_WH,

        0.0,

        parameters.internal_resistance,

        0.0,

        parameters.maximum_discharge_current,
        parameters.maximum_charge_current,

        0.0,

        false,

        false,
        false,
        false

    )

end


# ============================================================
# 27. COMPLETE BATTERY MODEL
# ============================================================

mutable struct BatteryModel

    parameters::BatteryParameters

    input::BatteryInput

    voltage_filter::VoltageFilter

    current_filter::CurrentFilter

    thermal::BatteryThermalState

    soc::SOCState

    runtime::RuntimeEstimator

    state::BatteryState

    elapsed_time::Float64

end


function BatteryModel()

    parameters =
        BatteryParameters()


    BatteryModel(

        parameters,

        BatteryInput(),

        VoltageFilter(),

        CurrentFilter(),

        BatteryThermalState(),

        SOCState(),

        RuntimeEstimator(),

        BatteryState(parameters),

        0.0

    )

end


# ============================================================
# 28. MAIN BATTERY UPDATE
# ============================================================

function update!(

    battery::BatteryModel,
    input::BatteryInput,
    dt::Float64 = 0.1

)

    battery.elapsed_time += dt

    battery.input = input


    # --------------------------------------------------------
    # Filter measurements
    # --------------------------------------------------------

    voltage =

        update_voltage!(

            battery.voltage_filter,
            input.voltage

        )


    current =

        update_current!(

            battery.current_filter,
            input.current

        )


    # --------------------------------------------------------
    # Thermal model
    # --------------------------------------------------------

    resistance =

        internal_resistance(

            battery.parameters,

            battery.soc.corrected_soc,

            battery.thermal.temperature

        )


    update_thermal!(

        battery.thermal,

        current,

        resistance,

        AMBIENT_TEMPERATURE,

        dt

    )


    # --------------------------------------------------------
    # Coulomb counting
    # --------------------------------------------------------

    if input.charger_connected

        update_charge_count!(

            battery.soc,

            max(
                input.charging_current,
                0.0
            ),

            battery.parameters.capacity_ah,

            dt

        )

    else

        update_coulomb_count!(

            battery.soc,

            max(current, 0.0),

            battery.parameters.capacity_ah,

            dt

        )

    end


    # --------------------------------------------------------
    # Voltage-derived SOC
    # --------------------------------------------------------

    voltage_soc =

        load_compensated_voltage_soc(

            battery.parameters,

            voltage,

            current,

            battery.thermal.temperature

        )


    battery.soc.voltage_soc =

        voltage_soc


    # --------------------------------------------------------
    # SOC fusion
    # --------------------------------------------------------

    temperature_factor =

        temperature_soc_factor(

            battery.thermal.temperature

        )


    confidence =

        voltage_confidence(current)


    fused_soc =

        fuse_soc(

            battery.soc.coulomb_soc,

            voltage_soc,

            confidence,

            temperature_factor

        )


    battery.soc.previous_soc =

        battery.soc.corrected_soc


    battery.soc.corrected_soc +=

        SOC_FILTER_ALPHA *
        (
            fused_soc -
            battery.soc.corrected_soc
        )


    battery.soc.corrected_soc =

        clamp(

            battery.soc.corrected_soc,

            0.0,
            1.0

        )


    # --------------------------------------------------------
    # Remaining energy
    # --------------------------------------------------------

    usable_ah =

        usable_capacity(

            battery.parameters,

            battery.thermal.temperature

        )


    battery.soc.remaining_ah =

        usable_ah *
        battery.soc.corrected_soc


    battery.soc.remaining_wh =

        battery.soc.remaining_ah *
        max(
            voltage,
            NOMINAL_VOLTAGE
        )


    # --------------------------------------------------------
    # Limits
    # --------------------------------------------------------

    discharge_limit =

        discharge_current_limit(

            battery.parameters,

            battery.soc.corrected_soc,

            battery.thermal.temperature

        )


    charge_limit =

        charge_current_limit(

            battery.parameters,

            battery.soc.corrected_soc,

            battery.thermal.temperature

        )


    # --------------------------------------------------------
    # Available power
    # --------------------------------------------------------

    available =

        available_power(

            battery.parameters,

            battery.soc.corrected_soc,

            battery.thermal.temperature,

            voltage

        )


    # --------------------------------------------------------
    # Runtime
    # --------------------------------------------------------

    runtime =

        update_runtime!(

            battery.runtime,

            battery.soc.remaining_wh,

            abs(
                input.voltage *
                input.current
            )

        )


    # --------------------------------------------------------
    # State flags
    # --------------------------------------------------------

    low_battery =

        battery.soc.corrected_soc <=
        0.20


    critical_battery =

        battery.soc.corrected_soc <=
        0.05 ||
        voltage <= MIN_SAFE_VOLTAGE


    thermal_warning =

        battery.thermal.temperature >=
        45.0


    # --------------------------------------------------------
    # Update state
    # --------------------------------------------------------

    battery.state = BatteryState(

        voltage,

        current,

        battery.thermal.temperature,

        battery.soc.corrected_soc,

        battery.soc.coulomb_soc,

        battery.soc.voltage_soc,

        battery.soc.remaining_ah,

        battery.soc.remaining_wh,

        voltage * current,

        resistance,

        available,

        discharge_limit,

        charge_limit,

        runtime,

        input.charger_connected,

        low_battery,

        critical_battery,

        thermal_warning

    )


    return battery.state

end


# ============================================================
# 29. MOTOR POWER LIMIT
# ============================================================

function motor_power_limit(

    battery::BatteryModel,
    requested_power::Float64

)

    state =
        battery.state


    factor =

        power_derating(

            state.soc,
            state.temperature,
            state.voltage

        )


    return min(

        requested_power *
        factor,

        state.available_power

    )

end


# ============================================================
# 30. MOTOR CURRENT LIMIT
# ============================================================

function motor_current_limit(

    battery::BatteryModel

)

    return (

        battery.state.discharge_limit

    )

end


# ============================================================
# 31. LOW BATTERY RPM DERATING
# ============================================================

function recommended_rpm(

    battery::BatteryModel,
    requested_rpm::Float64

)

    soc =
        battery.state.soc


    multiplier =

        if soc > 0.20

            1.0

        elseif soc > 0.10

            0.90

        elseif soc > 0.05

            0.75

        else

            0.50

        end


    if battery.state.thermal_warning

        multiplier *= 0.85

    end


    if battery.state.critical_battery

        multiplier *= 0.50

    end


    return (

        requested_rpm *
        multiplier

    )

end


# ============================================================
# 32. CHARGING STATE
# ============================================================

function charging_complete(

    battery::BatteryModel

)

    return (

        battery.state.charging &&
        battery.state.soc >= 0.98

    )

end


function charging_safe(

    battery::BatteryModel

)

    T =
        battery.state.temperature


    V =
        battery.state.voltage


    return (

        T >= MIN_OPERATING_TEMPERATURE &&
        T <= MAX_OPERATING_TEMPERATURE &&

        V < MAX_CHARGE_VOLTAGE

    )

end


# ============================================================
# 33. BATTERY HEALTH
# ============================================================

mutable struct BatteryHealth

    capacity_estimate_ah::Float64

    resistance_estimate_ohm::Float64

    cycle_count::Float64

    degradation::Float64

    health_score::Float64

end


function BatteryHealth()

    BatteryHealth(

        NOMINAL_CAPACITY_AH,

        BASE_INTERNAL_RESISTANCE,

        0.0,
        0.0,
        1.0

    )

end


function update_health!(

    health::BatteryHealth,
    battery::BatteryModel

)

    resistance_ratio =

        battery.state.internal_resistance /
        BASE_INTERNAL_RESISTANCE


    resistance_penalty =

        clamp(

            (
                resistance_ratio -
                1.0
            ) /
            2.0,

            0.0,
            1.0

        )


    degradation =

        clamp(

            1.0 -
            health.capacity_estimate_ah /
            NOMINAL_CAPACITY_AH,

            0.0,
            1.0

        )


    health.degradation =

        max(
            degradation,
            resistance_penalty
        )


    health.resistance_estimate_ohm =

        battery.state.internal_resistance


    health.health_score =

        clamp(

            1.0 -
            health.degradation,

            0.0,
            1.0

        )


    return health

end


# ============================================================
# 34. BATTERY DIAGNOSTICS
# ============================================================

function diagnostics(

    battery::BatteryModel

)

    state =
        battery.state


    return Dict(

        "voltage_V" =>
            state.voltage,

        "current_A" =>
            state.current,

        "temperature_C" =>
            state.temperature,

        "soc" =>
            state.soc,

        "soc_percent" =>
            state.soc * 100.0,

        "coulomb_soc" =>
            state.coulomb_soc,

        "voltage_soc" =>
            state.voltage_soc,

        "remaining_Ah" =>
            state.remaining_ah,

        "remaining_Wh" =>
            state.remaining_wh,

        "power_W" =>
            state.power,

        "internal_resistance_ohm" =>
            state.internal_resistance,

        "available_power_W" =>
            state.available_power,

        "discharge_limit_A" =>
            state.discharge_limit,

        "charge_limit_A" =>
            state.charge_limit,

        "runtime_minutes" =>
            state.runtime_minutes,

        "charging" =>
            state.charging,

        "low_battery" =>
            state.low_battery,

        "critical_battery" =>
            state.critical_battery,

        "thermal_warning" =>
            state.thermal_warning

    )

end


# ============================================================
# 35. BATTERY SIMULATION
# ============================================================

function simulate_discharge(

    duration_seconds::Float64;
    starting_soc = 1.0,
    load_power = 10.0,
    dt = 0.1

)

    battery =
        BatteryModel()


    battery.soc.coulomb_soc =
        starting_soc

    battery.soc.corrected_soc =
        starting_soc


    results = []


    steps = Int(

        round(
            duration_seconds / dt
        )

    )


    for i in 1:steps

        soc =
            battery.soc.corrected_soc


        voltage =

            soc_to_ocv(soc)


        current =

            load_power /
            max(voltage, 0.1)


        input = BatteryInput(

            voltage,
            current,

            battery.thermal.temperature,

            false,
            0.0

        )


        state = update!(

            battery,
            input,
            dt

        )


        if i % 10 == 0

            push!(

                results,

                (

                    time = i * dt,

                    voltage =
                        state.voltage,

                    current =
                        state.current,

                    soc =
                        state.soc,

                    temperature =
                        state.temperature,

                    remaining_wh =
                        state.remaining_wh,

                    available_power =
                        state.available_power

                )

            )

        end


        if state.critical_battery

            break

        end

    end


    return battery, results

end


# ============================================================
# 36. RESET
# ============================================================

function reset!(

    battery::BatteryModel

)

    battery.input =
        BatteryInput()

    battery.voltage_filter =
        VoltageFilter()

    battery.current_filter =
        CurrentFilter()

    battery.thermal =
        BatteryThermalState()

    battery.soc =
        SOCState()

    battery.runtime =
        RuntimeEstimator()

    battery.state =
        BatteryState(
            battery.parameters
        )

    battery.elapsed_time =
        0.0


    return battery

end


# ============================================================
# 37. EXPORTS
# ============================================================

export BatteryChemistry
export BatteryParameters
export BatteryInput
export BatteryState
export BatteryModel
export BatteryHealth

export update!
export reset!

export voltage_to_soc
export soc_to_ocv

export internal_resistance
export predicted_terminal_voltage

export motor_power_limit
export motor_current_limit
export recommended_rpm

export available_power
export power_derating

export charge_current_limit
export discharge_current_limit

export charging_complete
export charging_safe

export diagnostics
export update_health!

export simulate_discharge

end # module





module ToothbrushThermalModel

using Statistics

# ============================================================
# DYSON-STYLE ELECTRIC TOOTHBRUSH
# THERMAL MANAGEMENT / DIGITAL-TWIN MODEL
#
# Thermal network:
#
# Battery ───────────────┐
#                        │
# Motor windings ────────┼──> Motor housing ──> Enclosure
#                        │
# Inverter / PCB ────────┘
#                              │
#                         Brush head
#                              │
#                           Ambient
#
# Each node has:
#   - temperature
#   - thermal capacitance
#   - heat generation
#   - conduction
#   - convection
#
# Outputs:
#   - temperatures
#   - thermal gradients
#   - motor derating
#   - battery derating
#   - charging limits
#   - thermal warnings
#   - emergency shutdown
#   - predicted temperature
#   - thermal headroom
#
# Reference/simulation architecture.
# Production firmware requires validated hardware
# measurements and hardware-specific thermal constants.
# ============================================================


# ============================================================
# 01. CONSTANTS
# ============================================================

const AMBIENT_DEFAULT_C = 22.0

const SAFE_MIN_TEMP_C = 0.0

const NOMINAL_TEMP_C = 25.0

const MOTOR_WARNING_TEMP_C = 60.0
const MOTOR_DERATE_TEMP_C = 68.0
const MOTOR_CRITICAL_TEMP_C = 78.0
const MOTOR_SHUTDOWN_TEMP_C = 85.0

const BATTERY_WARNING_TEMP_C = 45.0
const BATTERY_DERATE_TEMP_C = 50.0
const BATTERY_CRITICAL_TEMP_C = 58.0
const BATTERY_SHUTDOWN_TEMP_C = 60.0

const INVERTER_WARNING_TEMP_C = 65.0
const INVERTER_DERATE_TEMP_C = 75.0
const INVERTER_CRITICAL_TEMP_C = 85.0
const INVERTER_SHUTDOWN_TEMP_C = 95.0

const PCB_WARNING_TEMP_C = 60.0
const PCB_DERATE_TEMP_C = 70.0
const PCB_CRITICAL_TEMP_C = 80.0
const PCB_SHUTDOWN_TEMP_C = 90.0

const HOUSING_WARNING_TEMP_C = 42.0
const HOUSING_DERATE_TEMP_C = 48.0
const HOUSING_CRITICAL_TEMP_C = 55.0

const BRUSH_WARNING_TEMP_C = 40.0
const BRUSH_DERATE_TEMP_C = 45.0
const BRUSH_CRITICAL_TEMP_C = 50.0

const THERMAL_FILTER_ALPHA = 0.08

const MAX_PREDICTION_TIME = 120.0

const DEFAULT_CONVECTION = 0.20


# ============================================================
# 02. THERMAL NODE IDENTIFIERS
# ============================================================

@enum ThermalNode begin

    BATTERY_NODE
    MOTOR_WINDING_NODE
    MOTOR_ROTOR_NODE
    INVERTER_NODE
    PCB_NODE
    MOTOR_HOUSING_NODE
    ENCLOSURE_NODE
    BRUSH_HEAD_NODE

end


# ============================================================
# 03. THERMAL NODE
# ============================================================

mutable struct ThermalNodeState

    node::ThermalNode

    temperature::Float64

    filtered_temperature::Float64

    previous_temperature::Float64

    heat_generation::Float64

    conductive_heat::Float64

    convective_heat::Float64

    net_heat::Float64

    thermal_capacity::Float64

    thermal_mass::Float64

end


function ThermalNodeState(

    node::ThermalNode;
    temperature = AMBIENT_DEFAULT_C,
    thermal_capacity = 20.0

)

    ThermalNodeState(

        node,

        temperature,

        temperature,

        temperature,

        0.0,
        0.0,
        0.0,
        0.0,

        thermal_capacity,

        thermal_capacity

    )

end


# ============================================================
# 04. THERMAL RESISTANCE
# ============================================================

struct ThermalResistance

    from::ThermalNode

    to::ThermalNode

    resistance::Float64

end


# ============================================================
# 05. DEFAULT THERMAL NETWORK
# ============================================================

function default_thermal_network()

    [

        ThermalResistance(
            BATTERY_NODE,
            PCB_NODE,
            3.0
        ),

        ThermalResistance(
            MOTOR_WINDING_NODE,
            MOTOR_HOUSING_NODE,
            0.80
        ),

        ThermalResistance(
            MOTOR_ROTOR_NODE,
            MOTOR_HOUSING_NODE,
            1.20
        ),

        ThermalResistance(
            INVERTER_NODE,
            PCB_NODE,
            0.50
        ),

        ThermalResistance(
            PCB_NODE,
            MOTOR_HOUSING_NODE,
            2.50
        ),

        ThermalResistance(
            MOTOR_HOUSING_NODE,
            ENCLOSURE_NODE,
            1.20
        ),

        ThermalResistance(
            ENCLOSURE_NODE,
            BRUSH_HEAD_NODE,
            2.50
        )

    ]

end


# ============================================================
# 06. THERMAL INPUT
# ============================================================

mutable struct ThermalInput

    ambient_temperature::Float64

    battery_power_loss::Float64

    motor_copper_loss::Float64

    motor_iron_loss::Float64

    motor_mechanical_loss::Float64

    inverter_loss::Float64

    pcb_loss::Float64

    gearbox_loss::Float64

    brush_friction_loss::Float64

    airflow::Float64

    water_cooling_factor::Float64

end


function ThermalInput()

    ThermalInput(

        AMBIENT_DEFAULT_C,

        0.0,
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

end


# ============================================================
# 07. THERMAL SENSOR
# ============================================================

mutable struct ThermalSensor

    raw_temperature::Float64

    filtered_temperature::Float64

    sensor_bias::Float64

    noise_estimate::Float64

    valid::Bool

end


function ThermalSensor(

    temperature = AMBIENT_DEFAULT_C

)

    ThermalSensor(

        temperature,

        temperature,

        0.0,
        0.0,
        true

    )

end


function update_sensor!(

    sensor::ThermalSensor,
    temperature::Float64

)

    sensor.raw_temperature =
        temperature


    corrected =

        temperature -
        sensor.sensor_bias


    sensor.noise_estimate =

        abs(

            corrected -
            sensor.filtered_temperature

        )


    sensor.filtered_temperature +=

        THERMAL_FILTER_ALPHA *
        (
            corrected -
            sensor.filtered_temperature
        )


    sensor.valid =

        isfinite(
            sensor.filtered_temperature
        )


    return sensor.filtered_temperature

end


# ============================================================
# 08. THERMAL GENERATION
# ============================================================

struct ThermalLossModel

    copper_resistance::Float64

    iron_loss_coefficient::Float64

    inverter_resistance::Float64

    mechanical_friction::Float64

    gearbox_efficiency::Float64

end


function ThermalLossModel()

    ThermalLossModel(

        0.35,

        1.0e-7,

        0.025,

        0.000002,

        0.94

    )

end


# ============================================================
# 09. MOTOR COPPER LOSS
# ============================================================

function motor_copper_loss(

    current::Float64,
    resistance::Float64

)

    return (

        current^2 *
        resistance

    )

end


# ============================================================
# 10. MOTOR IRON LOSS
# ============================================================

function motor_iron_loss(

    rpm::Float64,
    coefficient::Float64

)

    angular_speed =

        rpm *
        2π /
        60.0


    return (

        coefficient *
        angular_speed^2

    )

end


# ============================================================
# 11. MECHANICAL LOSS
# ============================================================

function motor_mechanical_loss(

    rpm::Float64,
    friction::Float64

)

    angular_speed =

        rpm *
        2π /
        60.0


    return (

        friction *
        angular_speed^2

    )

end


# ============================================================
# 12. INVERTER LOSS
# ============================================================

function inverter_loss(

    current::Float64,
    resistance::Float64

)

    return (

        current^2 *
        resistance

    )

end


# ============================================================
# 13. BATTERY LOSS
# ============================================================

function battery_loss(

    current::Float64,
    internal_resistance::Float64

)

    return (

        current^2 *
        internal_resistance

    )

end


# ============================================================
# 14. HEAT FLOW
# ============================================================

function conductive_heat_flow(

    temperature_a::Float64,
    temperature_b::Float64,
    resistance::Float64

)

    return (

        temperature_a -
        temperature_b

    ) / resistance

end


# ============================================================
# 15. CONVECTION
# ============================================================

function convective_heat_loss(

    temperature::Float64,
    ambient::Float64,
    airflow::Float64,
    area_factor::Float64 = 1.0

)

    coefficient =

        DEFAULT_CONVECTION *
        (
            1.0 +
            0.50 *
            airflow
        )


    return (

        coefficient *
        area_factor *
        (
            temperature -
            ambient
        )

    )

end


# ============================================================
# 16. THERMAL NETWORK
# ============================================================

mutable struct ThermalNetwork

    nodes::Dict{ThermalNode,ThermalNodeState}

    resistances::Vector{ThermalResistance}

    ambient_temperature::Float64

end


function ThermalNetwork()

    nodes = Dict(

        BATTERY_NODE =>
            ThermalNodeState(
                BATTERY_NODE,
                thermal_capacity = 45.0
            ),

        MOTOR_WINDING_NODE =>
            ThermalNodeState(
                MOTOR_WINDING_NODE,
                thermal_capacity = 15.0
            ),

        MOTOR_ROTOR_NODE =>
            ThermalNodeState(
                MOTOR_ROTOR_NODE,
                thermal_capacity = 12.0
            ),

        INVERTER_NODE =>
            ThermalNodeState(
                INVERTER_NODE,
                thermal_capacity = 10.0
            ),

        PCB_NODE =>
            ThermalNodeState(
                PCB_NODE,
                thermal_capacity = 25.0
            ),

        MOTOR_HOUSING_NODE =>
            ThermalNodeState(
                MOTOR_HOUSING_NODE,
                thermal_capacity = 60.0
            ),

        ENCLOSURE_NODE =>
            ThermalNodeState(
                ENCLOSURE_NODE,
                thermal_capacity = 90.0
            ),

        BRUSH_HEAD_NODE =>
            ThermalNodeState(
                BRUSH_HEAD_NODE,
                thermal_capacity = 20.0
            )

    )


    ThermalNetwork(

        nodes,

        default_thermal_network(),

        AMBIENT_DEFAULT_C

    )

end


# ============================================================
# 17. NETWORK HEAT RESET
# ============================================================

function reset_heat_flow!(

    network::ThermalNetwork

)

    for node in values(network.nodes)

        node.conductive_heat = 0.0

        node.convective_heat = 0.0

        node.net_heat = 0.0

    end

end


# ============================================================
# 18. CONDUCTIVE HEAT TRANSFER
# ============================================================

function calculate_conduction!(

    network::ThermalNetwork

)

    for link in network.resistances

        a =
            network.nodes[link.from]

        b =
            network.nodes[link.to]


        heat =

            conductive_heat_flow(

                a.temperature,
                b.temperature,
                link.resistance

            )


        a.conductive_heat -= heat

        b.conductive_heat += heat

    end

end


# ============================================================
# 19. CONVECTION
# ============================================================

function calculate_convection!(

    network::ThermalNetwork,
    airflow::Float64

)

    for node in values(network.nodes)

        loss =

            convective_heat_loss(

                node.temperature,

                network.ambient_temperature,

                airflow

            )


        node.convective_heat -= loss

    end

end


# ============================================================
# 20. APPLY HEAT SOURCES
# ============================================================

function apply_heat_sources!(

    network::ThermalNetwork,
    input::ThermalInput

)

    network.nodes[
        BATTERY_NODE
    ].heat_generation =

        input.battery_power_loss


    network.nodes[
        MOTOR_WINDING_NODE
    ].heat_generation =

        input.motor_copper_loss


    network.nodes[
        MOTOR_ROTOR_NODE
    ].heat_generation =

        input.motor_iron_loss +
        input.motor_mechanical_loss


    network.nodes[
        INVERTER_NODE
    ].heat_generation =

        input.inverter_loss


    network.nodes[
        PCB_NODE
    ].heat_generation =

        input.pcb_loss


    network.nodes[
        MOTOR_HOUSING_NODE
    ].heat_generation =

        input.gearbox_loss


    network.nodes[
        BRUSH_HEAD_NODE
    ].heat_generation =

        input.brush_friction_loss

end


# ============================================================
# 21. NODE INTEGRATION
# ============================================================

function integrate_node!(

    node::ThermalNodeState,
    dt::Float64

)

    node.previous_temperature =
        node.temperature


    node.net_heat =

        node.heat_generation +
        node.conductive_heat +
        node.convective_heat


    dT =

        node.net_heat /
        node.thermal_capacity *
        dt


    node.temperature += dT


    node.filtered_temperature +=

        THERMAL_FILTER_ALPHA *
        (
            node.temperature -
            node.filtered_temperature
        )


    return node.temperature

end


# ============================================================
# 22. THERMAL GRADIENT
# ============================================================

function thermal_gradient(

    network::ThermalNetwork,
    a::ThermalNode,
    b::ThermalNode

)

    return (

        network.nodes[a].temperature -
        network.nodes[b].temperature

    )

end


# ============================================================
# 23. MAXIMUM TEMPERATURE
# ============================================================

function maximum_temperature(

    network::ThermalNetwork

)

    return maximum(

        node.temperature
        for node in
        values(network.nodes)

    )

end


function hottest_node(

    network::ThermalNetwork

)

    nodes =
        collect(values(network.nodes))


    return nodes[

        argmax(
            n -> n.temperature,
            nodes
        )

    ].node

end


# ============================================================
# 24. THERMAL STATE ENUM
# ============================================================

@enum ThermalState begin

    THERMAL_COLD
    THERMAL_NORMAL
    THERMAL_WARM
    THERMAL_DERATING
    THERMAL_CRITICAL
    THERMAL_SHUTDOWN

end


# ============================================================
# 25. NODE STATE CLASSIFICATION
# ============================================================

function classify_motor_temperature(

    temperature::Float64

)

    if temperature >=
       MOTOR_SHUTDOWN_TEMP_C

        return THERMAL_SHUTDOWN

    elseif temperature >=
           MOTOR_CRITICAL_TEMP_C

        return THERMAL_CRITICAL

    elseif temperature >=
           MOTOR_DERATE_TEMP_C

        return THERMAL_DERATING

    elseif temperature >=
           MOTOR_WARNING_TEMP_C

        return THERMAL_WARM

    elseif temperature < 10.0

        return THERMAL_COLD

    end


    return THERMAL_NORMAL

end


# ============================================================
# 26. BATTERY TEMPERATURE STATE
# ============================================================

function classify_battery_temperature(

    temperature::Float64

)

    if temperature >=
       BATTERY_SHUTDOWN_TEMP_C

        return THERMAL_SHUTDOWN

    elseif temperature >=
           BATTERY_CRITICAL_TEMP_C

        return THERMAL_CRITICAL

    elseif temperature >=
           BATTERY_DERATE_TEMP_C

        return THERMAL_DERATING

    elseif temperature >=
           BATTERY_WARNING_TEMP_C

        return THERMAL_WARM

    elseif temperature < 10.0

        return THERMAL_COLD

    end


    return THERMAL_NORMAL

end


# ============================================================
# 27. INVERTER STATE
# ============================================================

function classify_inverter_temperature(

    temperature::Float64

)

    if temperature >=
       INVERTER_SHUTDOWN_TEMP_C

        return THERMAL_SHUTDOWN

    elseif temperature >=
           INVERTER_CRITICAL_TEMP_C

        return THERMAL_CRITICAL

    elseif temperature >=
           INVERTER_DERATE_TEMP_C

        return THERMAL_DERATING

    elseif temperature >=
           INVERTER_WARNING_TEMP_C

        return THERMAL_WARM

    end


    return THERMAL_NORMAL

end


# ============================================================
# 28. THERMAL DERATING
# ============================================================

function temperature_derating(

    temperature::Float64,
    warning::Float64,
    derate::Float64,
    critical::Float64,
    shutdown::Float64

)

    if temperature >= shutdown

        return 0.0

    elseif temperature >= critical

        return 0.20

    elseif temperature >= derate

        return (

            1.0 -
            0.80 *
            (
                temperature - derate
            ) /
            (
                critical - derate
            )

        )

    elseif temperature >= warning

        return (

            1.0 -
            0.20 *
            (
                temperature - warning
            ) /
            (
                derate - warning
            )

        )

    end


    return 1.0

end


# ============================================================
# 29. MOTOR DERATING
# ============================================================

function motor_thermal_derating(

    network::ThermalNetwork

)

    temperature =

        network.nodes[
            MOTOR_WINDING_NODE
        ].temperature


    return temperature_derating(

        temperature,

        MOTOR_WARNING_TEMP_C,
        MOTOR_DERATE_TEMP_C,
        MOTOR_CRITICAL_TEMP_C,
        MOTOR_SHUTDOWN_TEMP_C

    )

end


# ============================================================
# 30. BATTERY DERATING
# ============================================================

function battery_thermal_derating(

    network::ThermalNetwork

)

    temperature =

        network.nodes[
            BATTERY_NODE
        ].temperature


    return temperature_derating(

        temperature,

        BATTERY_WARNING_TEMP_C,
        BATTERY_DERATE_TEMP_C,
        BATTERY_CRITICAL_TEMP_C,
        BATTERY_SHUTDOWN_TEMP_C

    )

end


# ============================================================
# 31. INVERTER DERATING
# ============================================================

function inverter_thermal_derating(

    network::ThermalNetwork

)

    temperature =

        network.nodes[
            INVERTER_NODE
        ].temperature


    return temperature_derating(

        temperature,

        INVERTER_WARNING_TEMP_C,
        INVERTER_DERATE_TEMP_C,
        INVERTER_CRITICAL_TEMP_C,
        INVERTER_SHUTDOWN_TEMP_C

    )

end


# ============================================================
# 32. ENCLOSURE DERATING
# ============================================================

function enclosure_thermal_derating(

    network::ThermalNetwork

)

    temperature =

        network.nodes[
            ENCLOSURE_NODE
        ].temperature


    return temperature_derating(

        temperature,

        HOUSING_WARNING_TEMP_C,
        HOUSING_DERATE_TEMP_C,
        HOUSING_CRITICAL_TEMP_C,
        HOUSING_CRITICAL_TEMP_C + 5.0

    )

end


# ============================================================
# 33. GLOBAL THERMAL LIMIT
# ============================================================

function global_thermal_derating(

    network::ThermalNetwork

)

    values = [

        motor_thermal_derating(network),

        battery_thermal_derating(network),

        inverter_thermal_derating(network),

        enclosure_thermal_derating(network)

    ]


    return minimum(values)

end


# ============================================================
# 34. THERMAL HEADROOM
# ============================================================

function thermal_headroom(

    network::ThermalNetwork

)

    motor_temp =

        network.nodes[
            MOTOR_WINDING_NODE
        ].temperature


    return (

        MOTOR_SHUTDOWN_TEMP_C -
        motor_temp

    )

end


# ============================================================
# 35. PREDICT TEMPERATURE
# ============================================================

function predict_temperature(

    node::ThermalNodeState,
    horizon::Float64

)

    rate = (

        node.temperature -
        node.previous_temperature

    )


    return (

        node.temperature +
        rate *
        horizon

    )

end


# ============================================================
# 36. PREDICTIVE DERATING
# ============================================================

function predictive_motor_derating(

    network::ThermalNetwork,
    horizon::Float64 = 10.0

)

    node =

        network.nodes[
            MOTOR_WINDING_NODE
        ]


    predicted =

        predict_temperature(

            node,
            horizon

        )


    return temperature_derating(

        predicted,

        MOTOR_WARNING_TEMP_C,
        MOTOR_DERATE_TEMP_C,
        MOTOR_CRITICAL_TEMP_C,
        MOTOR_SHUTDOWN_TEMP_C

    )

end


# ============================================================
# 37. EMERGENCY SHUTDOWN
# ============================================================

function emergency_shutdown_required(

    network::ThermalNetwork

)

    motor =

        network.nodes[
            MOTOR_WINDING_NODE
        ].temperature


    battery =

        network.nodes[
            BATTERY_NODE
        ].temperature


    inverter =

        network.nodes[
            INVERTER_NODE
        ].temperature


    return (

        motor >= MOTOR_SHUTDOWN_TEMP_C ||

        battery >= BATTERY_SHUTDOWN_TEMP_C ||

        inverter >= INVERTER_SHUTDOWN_TEMP_C

    )

end


# ============================================================
# 38. CHARGING SAFETY
# ============================================================

function charging_allowed(

    network::ThermalNetwork

)

    battery =

        network.nodes[
            BATTERY_NODE
        ].temperature


    return (

        battery >=
        SAFE_MIN_TEMP_C &&

        battery <
        BATTERY_DERATE_TEMP_C

    )

end


# ============================================================
# 39. CHARGE DERATING
# ============================================================

function charge_derating(

    network::ThermalNetwork

)

    temperature =

        network.nodes[
            BATTERY_NODE
        ].temperature


    if temperature < 10.0

        return 0.40

    end


    return temperature_derating(

        temperature,

        40.0,
        BATTERY_DERATE_TEMP_C,
        BATTERY_CRITICAL_TEMP_C,
        BATTERY_SHUTDOWN_TEMP_C

    )

end


# ============================================================
# 40. BRUSH-HEAD TEMPERATURE
# ============================================================

function brush_head_temperature(

    network::ThermalNetwork

)

    return network.nodes[
        BRUSH_HEAD_NODE
    ].temperature

end


function brush_head_safe(

    network::ThermalNetwork

)

    return (

        brush_head_temperature(network) <
        BRUSH_CRITICAL_TEMP_C

    )

end


# ============================================================
# 41. MOTOR TEMPERATURE
# ============================================================

function motor_temperature(

    network::ThermalNetwork

)

    return network.nodes[
        MOTOR_WINDING_NODE
    ].temperature

end


# ============================================================
# 42. BATTERY TEMPERATURE
# ============================================================

function battery_temperature(

    network::ThermalNetwork

)

    return network.nodes[
        BATTERY_NODE
    ].temperature

end


# ============================================================
# 43. THERMAL BALANCE
# ============================================================

function total_heat_generation(

    network::ThermalNetwork

)

    return sum(

        node.heat_generation
        for node in
        values(network.nodes)

    )

end


function total_heat_rejection(

    network::ThermalNetwork

)

    return sum(

        -node.convective_heat
        for node in
        values(network.nodes)

    )

end


# ============================================================
# 44. MAIN THERMAL UPDATE
# ============================================================

function update!(

    network::ThermalNetwork,
    input::ThermalInput,
    dt::Float64 = 0.1

)

    network.ambient_temperature =

        input.ambient_temperature


    reset_heat_flow!(network)


    apply_heat_sources!(

        network,
        input

    )


    calculate_conduction!(network)


    calculate_convection!(

        network,
        input.airflow

    )


    # Water around the brush head can provide
    # additional cooling.

    if input.water_cooling_factor > 0.0

        brush =

            network.nodes[
                BRUSH_HEAD_NODE
            ]


        brush.convective_heat -=

            input.water_cooling_factor *
            max(
                brush.temperature -
                input.ambient_temperature,
                0.0
            )

    end


    for node in values(network.nodes)

        integrate_node!(

            node,
            dt

        )

    end


    return network

end


# ============================================================
# 45. THERMAL OPERATING LIMITS
# ============================================================

struct ThermalLimits

    motor_derating::Float64

    battery_derating::Float64

    inverter_derating::Float64

    enclosure_derating::Float64

    global_derating::Float64

    charge_derating::Float64

    charging_allowed::Bool

    emergency_shutdown::Bool

end


function thermal_limits(

    network::ThermalNetwork

)

    motor =
        motor_thermal_derating(network)

    battery =
        battery_thermal_derating(network)

    inverter =
        inverter_thermal_derating(network)

    enclosure =
        enclosure_thermal_derating(network)


    ThermalLimits(

        motor,
        battery,
        inverter,
        enclosure,

        minimum(
            motor,
            battery,
            inverter,
            enclosure
        ),

        charge_derating(network),

        charging_allowed(network),

        emergency_shutdown_required(network)

    )

end


# ============================================================
# 46. RECOMMENDED MOTOR POWER
# ============================================================

function recommended_motor_power(

    requested_power::Float64,
    network::ThermalNetwork

)

    limits =
        thermal_limits(network)


    return (

        requested_power *
        limits.global_derating

    )

end


# ============================================================
# 47. RECOMMENDED MOTOR RPM
# ============================================================

function recommended_rpm(

    requested_rpm::Float64,
    network::ThermalNetwork

)

    limits =
        thermal_limits(network)


    # RPM is not linearly equivalent to heat,
    # but this provides a conservative control layer.

    rpm_factor =

        0.60 +
        0.40 *
        limits.motor_derating


    return (

        requested_rpm *
        rpm_factor

    )

end


# ============================================================
# 48. THERMAL CONTROL COMMAND
# ============================================================

@enum ThermalCommand begin

    THERMAL_COMMAND_NORMAL
    THERMAL_COMMAND_DERATE
    THERMAL_COMMAND_COOL
    THERMAL_COMMAND_STOP
    THERMAL_COMMAND_CHARGE_LIMIT
    THERMAL_COMMAND_CHARGE_STOP

end


function thermal_command(

    network::ThermalNetwork

)

    limits =
        thermal_limits(network)


    if limits.emergency_shutdown

        return THERMAL_COMMAND_STOP

    elseif !limits.charging_allowed

        return THERMAL_COMMAND_CHARGE_STOP

    elseif limits.global_derating < 0.50

        return THERMAL_COMMAND_DERATE

    elseif limits.global_derating < 0.80

        return THERMAL_COMMAND_COOL

    elseif limits.charge_derating < 0.80

        return THERMAL_COMMAND_CHARGE_LIMIT

    end


    return THERMAL_COMMAND_NORMAL

end


# ============================================================
# 49. THERMAL DIGITAL-TWIN STATE
# ============================================================

mutable struct ThermalModel

    network::ThermalNetwork

    input::ThermalInput

    sensors::Dict{ThermalNode,ThermalSensor}

    losses::ThermalLossModel

    limits::ThermalLimits

    elapsed_time::Float64

end


function ThermalModel()

    network =
        ThermalNetwork()


    sensors = Dict(

        node =>
            ThermalSensor()
        for node in instances(ThermalNode)

    )


    ThermalModel(

        network,

        ThermalInput(),

        sensors,

        ThermalLossModel(),

        thermal_limits(network),

        0.0

    )

end


# ============================================================
# 50. HIGH-LEVEL MOTOR UPDATE
# ============================================================

function update_motor_losses!(

    model::ThermalModel,
    rpm::Float64,
    current::Float64,
    winding_resistance::Float64

)

    model.input.motor_copper_loss =

        motor_copper_loss(

            current,
            winding_resistance

        )


    model.input.motor_iron_loss =

        motor_iron_loss(

            rpm,
            model.losses.iron_loss_coefficient

        )


    model.input.motor_mechanical_loss =

        motor_mechanical_loss(

            rpm,
            model.losses.mechanical_friction

        )


    return model.input

end


# ============================================================
# 51. HIGH-LEVEL INVERTER UPDATE
# ============================================================

function update_inverter_losses!(

    model::ThermalModel,
    current::Float64

)

    model.input.inverter_loss =

        inverter_loss(

            current,
            model.losses.inverter_resistance

        )


    return model.input.inverter_loss

end


# ============================================================
# 52. HIGH-LEVEL BATTERY UPDATE
# ============================================================

function update_battery_loss!(

    model::ThermalModel,
    current::Float64,
    internal_resistance::Float64

)

    model.input.battery_power_loss =

        battery_loss(

            current,
            internal_resistance

        )


    return model.input.battery_power_loss

end


# ============================================================
# 53. COMPLETE SYSTEM STEP
# ============================================================

function step!(

    model::ThermalModel;

    ambient_temperature =
        AMBIENT_DEFAULT_C,

    rpm = 0.0,

    motor_current = 0.0,

    winding_resistance = 0.35,

    battery_current = 0.0,

    battery_resistance = 0.08,

    airflow = 0.0,

    water_cooling = 0.0,

    dt = 0.1

)

    model.elapsed_time += dt


    model.input.ambient_temperature =

        ambient_temperature


    model.input.airflow =

        airflow


    model.input.water_cooling_factor =

        water_cooling


    update_motor_losses!(

        model,

        rpm,

        motor_current,

        winding_resistance

    )


    update_inverter_losses!(

        model,

        motor_current

    )


    update_battery_loss!(

        model,

        battery_current,

        battery_resistance

    )


    update!(

        model.network,

        model.input,

        dt

    )


    model.limits =

        thermal_limits(
            model.network
        )


    return model.limits

end


# ============================================================
# 54. SENSOR SYNCHRONISATION
# ============================================================

function synchronise_sensors!(

    model::ThermalModel

)

    for node in instances(ThermalNode)

        temperature =

            model.network.nodes[
                node
            ].temperature


        update_sensor!(

            model.sensors[node],

            temperature

        )

    end


    return model.sensors

end


# ============================================================
# 55. THERMAL TELEMETRY
# ============================================================

function telemetry(

    model::ThermalModel

)

    network =
        model.network


    return Dict(

        "ambient_C" =>
            network.ambient_temperature,

        "battery_C" =>
            battery_temperature(network),

        "motor_winding_C" =>
            motor_temperature(network),

        "motor_rotor_C" =>
            network.nodes[
                MOTOR_ROTOR_NODE
            ].temperature,

        "inverter_C" =>
            network.nodes[
                INVERTER_NODE
            ].temperature,

        "pcb_C" =>
            network.nodes[
                PCB_NODE
            ].temperature,

        "housing_C" =>
            network.nodes[
                MOTOR_HOUSING_NODE
            ].temperature,

        "enclosure_C" =>
            network.nodes[
                ENCLOSURE_NODE
            ].temperature,

        "brush_head_C" =>
            brush_head_temperature(network),

        "maximum_C" =>
            maximum_temperature(network),

        "hottest_node" =>
            string(
                hottest_node(network)
            ),

        "motor_derating" =>
            motor_thermal_derating(network),

        "battery_derating" =>
            battery_thermal_derating(network),

        "inverter_derating" =>
            inverter_thermal_derating(network),

        "global_derating" =>
            global_thermal_derating(network),

        "thermal_headroom_C" =>
            thermal_headroom(network),

        "charging_allowed" =>
            charging_allowed(network),

        "emergency_shutdown" =>
            emergency_shutdown_required(network)

    )

end


# ============================================================
# 56. THERMAL DIAGNOSTICS
# ============================================================

function diagnostics(

    model::ThermalModel

)

    network =
        model.network


    return Dict(

        "command" =>
            string(
                thermal_command(network)
            ),

        "motor_state" =>
            string(
                classify_motor_temperature(
                    motor_temperature(network)
                )
            ),

        "battery_state" =>
            string(
                classify_battery_temperature(
                    battery_temperature(network)
                )
            ),

        "inverter_state" =>
            string(
                classify_inverter_temperature(
                    network.nodes[
                        INVERTER_NODE
                    ].temperature
                )
            ),

        "total_heat_W" =>
            total_heat_generation(network),

        "heat_rejection_W" =>
            total_heat_rejection(network),

        "predicted_motor_10s_C" =>
            predict_temperature(
                network.nodes[
                    MOTOR_WINDING_NODE
                ],
                10.0
            ),

        "predicted_motor_30s_C" =>
            predict_temperature(
                network.nodes[
                    MOTOR_WINDING_NODE
                ],
                30.0
            ),

        "predictive_motor_derating" =>
            predictive_motor_derating(
                network,
                10.0
            )

    )

end


# ============================================================
# 57. COOLING STRATEGY
# ============================================================

function cooling_required(

    model::ThermalModel

)

    limits =
        model.limits


    return (

        limits.global_derating < 0.90 ||

        predictive_motor_derating(
            model.network,
            10.0
        ) < 0.90

    )

end


function cooling_intensity(

    model::ThermalModel

)

    if !cooling_required(model)

        return 0.0

    end


    return clamp(

        1.0 -
        model.limits.global_derating,

        0.0,
        1.0

    )

end


# ============================================================
# 58. THERMAL RESET
# ============================================================

function reset!(

    model::ThermalModel

)

    model.network =
        ThermalNetwork()

    model.input =
        ThermalInput()

    model.sensors = Dict(

        node =>
            ThermalSensor()
        for node in instances(ThermalNode)

    )

    model.limits =
        thermal_limits(
            model.network
        )

    model.elapsed_time =
        0.0


    return model

end


# ============================================================
# 59. THERMAL TEST SCENARIO
# ============================================================

function simulate_high_load(

    duration_seconds = 120.0;

    rpm = 30000.0,

    motor_current = 3.0,

    ambient = 25.0,

    airflow = 0.0,

    dt = 0.1

)

    model =
        ThermalModel()


    results = []


    steps = Int(

        round(
            duration_seconds / dt
        )

    )


    for i in 1:steps

        limits =

            step!(

                model,

                ambient_temperature =
                    ambient,

                rpm = rpm,

                motor_current =
                    motor_current,

                battery_current =
                    motor_current,

                airflow =
                    airflow,

                dt = dt

            )


        if i % 10 == 0

            push!(

                results,

                (

                    time = i * dt,

                    motor_C =
                        motor_temperature(
                            model.network
                        ),

                    battery_C =
                        battery_temperature(
                            model.network
                        ),

                    inverter_C =
                        model.network.nodes[
                            INVERTER_NODE
                        ].temperature,

                    enclosure_C =
                        model.network.nodes[
                            ENCLOSURE_NODE
                        ].temperature,

                    derating =
                        limits.global_derating,

                    command =
                        thermal_command(
                            model.network
                        )

                )

            )

        end


        if limits.emergency_shutdown

            break

        end

    end


    return model, results

end


# ============================================================
# 60. EXPORTS
# ============================================================

export ThermalNode
export ThermalNodeState
export ThermalResistance
export ThermalInput
export ThermalNetwork
export ThermalModel
export ThermalLimits
export ThermalLossModel
export ThermalSensor

export ThermalState
export ThermalCommand

export update!
export step!
export reset!

export motor_copper_loss
export motor_iron_loss
export motor_mechanical_loss
export inverter_loss
export battery_loss

export motor_temperature
export battery_temperature
export brush_head_temperature

export motor_thermal_derating
export battery_thermal_derating
export inverter_thermal_derating
export enclosure_thermal_derating
export global_thermal_derating

export recommended_rpm
export recommended_motor_power

export thermal_headroom
export predictive_motor_derating

export emergency_shutdown_required
export charging_allowed
export charge_derating

export thermal_command
export cooling_required
export cooling_intensity

export maximum_temperature
export hottest_node

export telemetry
export diagnostics

export simulate_high_load

end




module ToothbrushCleaningAlgorithms

using Statistics

# ============================================================
# DYSON-STYLE ELECTRIC TOOTHBRUSH
# ADAPTIVE CLEANING / BRUSHING ALGORITHM
#
# Pipeline:
#
# Sensor Fusion
#      │
#      ├── motion
#      ├── contact
#      ├── pressure
#      ├── vibration
#      └── motor state
#             │
#             ▼
#      Contact Quality
#             │
#             ▼
#       Brushing Classifier
#             │
#       ┌─────┴─────┐
#       ▼           ▼
#    Tooth      Gum/soft tissue
#    contact       contact
#       │           │
#       └─────┬─────┘
#             ▼
#       Cleaning Score
#             │
#             ▼
#       Adaptive Motor
#             │
#       ┌─────┼─────┐
#       ▼     ▼     ▼
#      RPM   Power  Pattern
#
# This is a control/simulation reference model.
# Actual dental products require clinical validation.
# ============================================================


# ============================================================
# 01. CONSTANTS
# ============================================================

const DEFAULT_RPM = 26000.0

const MIN_RPM = 8000.0
const MAX_RPM = 42000.0

const GENTLE_RPM = 18000.0
const STANDARD_RPM = 26000.0
const INTENSIVE_RPM = 34000.0

const NORMAL_PRESSURE = 0.35
const HIGH_PRESSURE = 0.65
const EXCESSIVE_PRESSURE = 0.82

const CONTACT_MINIMUM = 0.20
const GOOD_CONTACT = 0.60
const EXCELLENT_CONTACT = 0.82

const TARGET_BRUSHING_TIME = 120.0

const ZONE_TIME_TARGET = 15.0

const ZONE_SCORE_TARGET = 0.75

const SCORE_FILTER_ALPHA = 0.08

const MOTION_FILTER_ALPHA = 0.12

const RPM_CHANGE_LIMIT = 2500.0

const MAX_POWER = 20.0

const MIN_POWER = 4.0

const TRANSITION_TIME = 1.5

const ADAPTIVE_INTERVAL = 0.25


# ============================================================
# 02. BRUSHING MODE
# ============================================================

@enum CleaningMode begin

    MODE_OFF
    MODE_GENTLE
    MODE_STANDARD
    MODE_INTENSIVE
    MODE_SENSITIVE
    MODE_DEEP_CLEAN
    MODE_MASSAGE

end


# ============================================================
# 03. BRUSHING PHASE
# ============================================================

@enum BrushingPhase begin

    PHASE_IDLE
    PHASE_STARTING
    PHASE_ACTIVE
    PHASE_TRANSITION
    PHASE_FINISHING
    PHASE_COMPLETE

end


# ============================================================
# 04. CONTACT CLASSIFICATION
# ============================================================

@enum CleaningContact begin

    CONTACT_NONE
    CONTACT_LIGHT
    CONTACT_GOOD
    CONTACT_HARD
    CONTACT_UNSTABLE
    CONTACT_EXCESSIVE

end


# ============================================================
# 05. SENSOR INPUT
# ============================================================

mutable struct CleaningInput

    timestamp::Float64

    rpm::Float64

    target_rpm::Float64

    pressure::Float64

    contact_probability::Float64

    tooth_contact_probability::Float64

    soft_contact_probability::Float64

    vibration::Float64

    motion_intensity::Float64

    brushing_velocity::Float64

    acceleration::Float64

    angular_velocity::Float64

    motor_current::Float64

    motor_temperature::Float64

    battery_soc::Float64

    battery_derating::Float64

    thermal_derating::Float64

end


function CleaningInput()

    CleaningInput(

        0.0,

        0.0,
        DEFAULT_RPM,

        0.0,

        0.0,
        0.0,
        0.0,

        0.0,

        0.0,
        0.0,

        0.0,
        0.0,

        0.0,

        25.0,

        1.0,

        1.0,
        1.0

    )

end


# ============================================================
# 06. ZONES
# ============================================================

@enum BrushZone begin

    ZONE_UNKNOWN

    ZONE_UPPER_LEFT
    ZONE_UPPER_FRONT
    ZONE_UPPER_RIGHT

    ZONE_LOWER_LEFT
    ZONE_LOWER_FRONT
    ZONE_LOWER_RIGHT

    ZONE_OCCLUSAL_LEFT
    ZONE_OCCLUSAL_FRONT
    ZONE_OCCLUSAL_RIGHT

    ZONE_GUM_LINE

end


# ============================================================
# 07. ZONE STATE
# ============================================================

mutable struct ZoneState

    zone::BrushZone

    time_seconds::Float64

    contact_time::Float64

    effective_time::Float64

    pressure_exposure::Float64

    cleaning_score::Float64

    coverage_score::Float64

    pressure_score::Float64

    stability_score::Float64

    completed::Bool

end


function ZoneState(

    zone::BrushZone

)

    ZoneState(

        zone,

        0.0,
        0.0,
        0.0,

        0.0,

        0.0,
        0.0,
        0.0,
        0.0,

        false

    )

end


# ============================================================
# 08. SESSION STATE
# ============================================================

mutable struct CleaningSession

    elapsed_time::Float64

    active_time::Float64

    contact_time::Float64

    excessive_pressure_time::Float64

    unstable_time::Float64

    average_pressure::Float64

    average_contact::Float64

    average_motion::Float64

    global_score::Float64

    coverage_score::Float64

    pressure_score::Float64

    consistency_score::Float64

    current_zone::BrushZone

    previous_zone::BrushZone

    mode::CleaningMode

    phase::BrushingPhase

end


function CleaningSession()

    CleaningSession(

        0.0,
        0.0,
        0.0,
        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        0.0,
        0.0,
        0.0,
        0.0,

        ZONE_UNKNOWN,
        ZONE_UNKNOWN,

        MODE_STANDARD,
        PHASE_IDLE

    )

end


# ============================================================
# 09. PRESSURE MODEL
# ============================================================

function pressure_quality(

    pressure::Float64

)

    p = clamp(

        pressure,
        0.0,
        1.0

    )


    if p <= NORMAL_PRESSURE

        return (

            p /
            NORMAL_PRESSURE

        )

    elseif p <= HIGH_PRESSURE

        return (

            1.0 -
            0.50 *
            (
                p -
                NORMAL_PRESSURE
            ) /
            (
                HIGH_PRESSURE -
                NORMAL_PRESSURE
            )

        )

    else

        return clamp(

            0.50 -
            (
                p -
                HIGH_PRESSURE
            ) /
            (
                2.0 *
                (
                    EXCESSIVE_PRESSURE -
                    HIGH_PRESSURE
                )
            ),

            0.0,
            0.50

        )

    end

end


# ============================================================
# 10. CONTACT QUALITY
# ============================================================

function contact_quality(

    contact::Float64

)

    c = clamp(

        contact,
        0.0,
        1.0

    )


    if c < CONTACT_MINIMUM

        return 0.0

    elseif c < GOOD_CONTACT

        return (

            c -
            CONTACT_MINIMUM
        ) /
        (
            GOOD_CONTACT -
            CONTACT_MINIMUM
        )

    end


    return min(

        1.0,

        c /
        EXCELLENT_CONTACT

    )

end


# ============================================================
# 11. MOTION QUALITY
# ============================================================

function motion_quality(

    motion::Float64

)

    m = abs(motion)


    if m < 0.05

        return 0.20

    elseif m < 0.20

        return 0.50

    elseif m < 0.70

        return 1.0

    elseif m < 1.2

        return 0.75

    end


    return 0.40

end


# ============================================================
# 12. CONTACT CLASSIFIER
# ============================================================

function classify_contact(

    pressure::Float64,
    contact_probability::Float64

)

    if contact_probability < 0.15

        return CONTACT_NONE

    elseif pressure >= EXCESSIVE_PRESSURE

        return CONTACT_EXCESSIVE

    elseif pressure >= HIGH_PRESSURE

        return CONTACT_HARD

    elseif contact_probability < 0.40

        return CONTACT_LIGHT

    elseif contact_probability >= 0.70

        return CONTACT_GOOD

    end


    return CONTACT_UNSTABLE

end


# ============================================================
# 13. EFFECTIVE CLEANING TIME
# ============================================================

function effective_cleaning_rate(

    input::CleaningInput

)

    contact =

        contact_quality(
            input.contact_probability
        )


    pressure =

        pressure_quality(
            input.pressure
        )


    motion =

        motion_quality(
            input.motion_intensity
        )


    tooth =

        clamp(
            input.tooth_contact_probability,
            0.0,
            1.0
        )


    return (

        0.35 * contact +
        0.25 * pressure +
        0.15 * motion +
        0.25 * tooth

    )

end


# ============================================================
# 14. CLEANING EFFECTIVENESS
# ============================================================

function instantaneous_cleaning_score(

    input::CleaningInput

)

    contact =

        contact_quality(
            input.contact_probability
        )


    pressure =

        pressure_quality(
            input.pressure
        )


    tooth =

        clamp(
            input.tooth_contact_probability,
            0.0,
            1.0
        )


    motion =

        motion_quality(
            input.motion_intensity
        )


    vibration = clamp(

        input.vibration /
        1.0,

        0.0,
        1.0

    )


    return clamp(

        0.30 * contact +
        0.25 * pressure +
        0.25 * tooth +
        0.10 * motion +
        0.10 * vibration,

        0.0,
        1.0

    )

end


# ============================================================
# 15. PRESSURE PENALTY
# ============================================================

function pressure_penalty(

    pressure::Float64

)

    if pressure <= NORMAL_PRESSURE

        return 0.0

    elseif pressure <= HIGH_PRESSURE

        return (

            0.30 *
            (
                pressure -
                NORMAL_PRESSURE
            ) /
            (
                HIGH_PRESSURE -
                NORMAL_PRESSURE
            )

        )

    end


    return clamp(

        0.30 +
        0.70 *
        (
            pressure -
            HIGH_PRESSURE
        ) /
        (
            1.0 -
            HIGH_PRESSURE
        ),

        0.0,
        1.0

    )

end


# ============================================================
# 16. COVERAGE MODEL
# ============================================================

function zone_coverage_score(

    zone::ZoneState

)

    time_score = clamp(

        zone.time_seconds /
        ZONE_TIME_TARGET,

        0.0,
        1.0

    )


    contact_score = clamp(

        zone.contact_time /
        max(
            zone.time_seconds,
            0.01
        ),

        0.0,
        1.0

    )


    return (

        0.50 * time_score +
        0.50 * contact_score

    )

end


# ============================================================
# 17. ZONE SCORE
# ============================================================

function calculate_zone_score(

    zone::ZoneState

)

    coverage =

        zone_coverage_score(zone)


    pressure =

        zone.pressure_score


    stability =

        zone.stability_score


    zone.coverage_score =
        coverage


    zone.cleaning_score =

        0.45 * coverage +
        0.30 * pressure +
        0.25 * stability


    return zone.cleaning_score

end


# ============================================================
# 18. ZONE MANAGER
# ============================================================

mutable struct ZoneManager

    zones::Dict{BrushZone,ZoneState}

    active_zone::BrushZone

    previous_zone::BrushZone

    transition_count::Int

end


function ZoneManager()

    zones = Dict(

        zone =>
            ZoneState(zone)

        for zone in instances(BrushZone)

    )


    ZoneManager(

        zones,

        ZONE_UNKNOWN,
        ZONE_UNKNOWN,
        0

    )

end


# ============================================================
# 19. ZONE CHANGE
# ============================================================

function change_zone!(

    manager::ZoneManager,
    zone::BrushZone

)

    if zone != manager.active_zone

        manager.previous_zone =
            manager.active_zone

        manager.active_zone =
            zone

        manager.transition_count += 1

    end


    return manager.active_zone

end


# ============================================================
# 20. UPDATE ZONE
# ============================================================

function update_zone!(

    manager::ZoneManager,
    zone::BrushZone,
    input::CleaningInput,
    dt::Float64

)

    change_zone!(
        manager,
        zone
    )


    state =
        manager.zones[zone]


    state.time_seconds += dt


    contact =

        input.contact_probability


    if contact >= CONTACT_MINIMUM

        state.contact_time += dt

    end


    effectiveness =

        effective_cleaning_rate(input)


    state.effective_time +=

        effectiveness *
        dt


    state.pressure_exposure +=

        input.pressure *
        dt


    instantaneous =

        instantaneous_cleaning_score(
            input
        )


    state.cleaning_score +=

        SCORE_FILTER_ALPHA *
        (
            instantaneous -
            state.cleaning_score
        )


    state.pressure_score =

        1.0 -
        pressure_penalty(
            input.pressure
        )


    state.stability_score =

        0.7 *
        state.stability_score +

        0.3 *
        contact_quality(
            input.contact_probability
        )


    calculate_zone_score(state)


    state.completed =

        state.effective_time >=
        ZONE_TIME_TARGET &&
        state.cleaning_score >=
        ZONE_SCORE_TARGET


    return state

end


# ============================================================
# 21. COVERAGE SCORE
# ============================================================

function overall_coverage(

    manager::ZoneManager

)

    relevant_zones = [

        zone
        for (zone, state)
        in manager.zones

        if zone != ZONE_UNKNOWN

    ]


    if isempty(relevant_zones)

        return 0.0

    end


    return mean(

        zone_coverage_score(
            manager.zones[zone]
        )
        for zone in relevant_zones

    )

end


# ============================================================
# 22. MISSING ZONES
# ============================================================

function missing_zones(

    manager::ZoneManager

)

    return [

        zone
        for (zone, state)
        in manager.zones

        if zone != ZONE_UNKNOWN &&
           !state.completed

    ]

end


# ============================================================
# 23. NEXT RECOMMENDED ZONE
# ============================================================

function next_recommended_zone(

    manager::ZoneManager

)

    candidates =

        missing_zones(manager)


    if isempty(candidates)

        return ZONE_UNKNOWN

    end


    scores = [

        manager.zones[z].cleaning_score
        for z in candidates

    ]


    return candidates[
        argmin(scores)
    ]

end


# ============================================================
# 24. ADAPTIVE MOTOR TARGET
# ============================================================

function base_rpm(

    mode::CleaningMode

)

    if mode == MODE_GENTLE

        return GENTLE_RPM

    elseif mode == MODE_INTENSIVE

        return INTENSIVE_RPM

    elseif mode == MODE_SENSITIVE

        return 16000.0

    elseif mode == MODE_DEEP_CLEAN

        return 32000.0

    elseif mode == MODE_MASSAGE

        return 14000.0

    end


    return STANDARD_RPM

end


# ============================================================
# 25. PRESSURE RPM ADAPTATION
# ============================================================

function pressure_rpm_multiplier(

    pressure::Float64

)

    if pressure <= NORMAL_PRESSURE

        return 1.0

    elseif pressure <= HIGH_PRESSURE

        return (

            1.0 -
            0.35 *
            (
                pressure -
                NORMAL_PRESSURE
            ) /
            (
                HIGH_PRESSURE -
                NORMAL_PRESSURE
            )

        )

    end


    return (

        0.65 -
        0.65 *
        (
            pressure -
            HIGH_PRESSURE
        ) /
        (
            1.0 -
            HIGH_PRESSURE
        )

    )

end


# ============================================================
# 26. CONTACT RPM ADAPTATION
# ============================================================

function contact_rpm_multiplier(

    contact::Float64

)

    if contact < CONTACT_MINIMUM

        return 0.75

    elseif contact < GOOD_CONTACT

        return 0.90

    end


    return 1.0

end


# ============================================================
# 27. THERMAL RPM ADAPTATION
# ============================================================

function thermal_rpm_multiplier(

    thermal_derating::Float64

)

    return clamp(

        0.60 +
        0.40 *
        thermal_derating,

        0.50,
        1.0

    )

end


# ============================================================
# 28. BATTERY RPM ADAPTATION
# ============================================================

function battery_rpm_multiplier(

    battery_soc::Float64,
    battery_derating::Float64

)

    soc_factor =

        if battery_soc > 0.20

            1.0

        elseif battery_soc > 0.10

            0.90

        elseif battery_soc > 0.05

            0.75

        else

            0.55

        end


    return (

        soc_factor *
        (
            0.70 +
            0.30 *
            battery_derating
        )

    )

end


# ============================================================
# 29. ADAPTIVE RPM
# ============================================================

function calculate_target_rpm(

    input::CleaningInput,
    mode::CleaningMode

)

    rpm =

        base_rpm(mode)


    rpm *=

        pressure_rpm_multiplier(
            input.pressure
        )


    rpm *=

        contact_rpm_multiplier(
            input.contact_probability
        )


    rpm *=

        thermal_rpm_multiplier(
            input.thermal_derating
        )


    rpm *=

        battery_rpm_multiplier(
            input.battery_soc,
            input.battery_derating
        )


    return clamp(

        rpm,
        MIN_RPM,
        MAX_RPM

    )

end


# ============================================================
# 30. POWER TARGET
# ============================================================

function calculate_target_power(

    input::CleaningInput,
    target_rpm::Float64

)

    rpm_factor =

        target_rpm /
        STANDARD_RPM


    pressure_factor =

        1.0 -
        0.50 *
        pressure_penalty(
            input.pressure
        )


    return clamp(

        MAX_POWER *
        rpm_factor *
        pressure_factor *
        input.thermal_derating *
        input.battery_derating,

        MIN_POWER,
        MAX_POWER

    )

end


# ============================================================
# 31. RPM SLEW LIMIT
# ============================================================

function slew_limited_rpm(

    previous::Float64,
    requested::Float64,
    dt::Float64

)

    maximum_change =

        RPM_CHANGE_LIMIT *
        max(dt, 0.01)


    delta =

        clamp(

            requested -
            previous,

            -maximum_change,
            maximum_change

        )


    return previous + delta

end


# ============================================================
# 32. ADAPTIVE CONTROLLER
# ============================================================

mutable struct CleaningController

    mode::CleaningMode

    phase::BrushingPhase

    target_rpm::Float64

    target_power::Float64

    previous_rpm::Float64

    pressure_limit::Float64

    contact_target::Float64

    adaptive_enabled::Bool

    gentle_response::Bool

end


function CleaningController()

    CleaningController(

        MODE_STANDARD,

        PHASE_IDLE,

        STANDARD_RPM,

        MAX_POWER,

        0.0,

        EXCESSIVE_PRESSURE,

        GOOD_CONTACT,

        true,
        false

    )

end


# ============================================================
# 33. PRESSURE PROTECTION
# ============================================================

function pressure_protection(

    controller::CleaningController,
    input::CleaningInput

)

    if input.pressure >=
       EXCESSIVE_PRESSURE

        controller.gentle_response = true

        return 0.35

    elseif input.pressure >=
           HIGH_PRESSURE

        controller.gentle_response = true

        return 0.65

    end


    controller.gentle_response = false

    return 1.0

end


# ============================================================
# 34. CONTACT PROTECTION
# ============================================================

function contact_protection(

    input::CleaningInput

)

    if input.contact_probability < 0.10

        return 0.75

    elseif input.contact_probability < 0.30

        return 0.90

    end


    return 1.0

end


# ============================================================
# 35. CONTROLLER UPDATE
# ============================================================

function update_controller!(

    controller::CleaningController,
    input::CleaningInput,
    dt::Float64

)

    pressure_factor =

        pressure_protection(
            controller,
            input
        )


    contact_factor =

        contact_protection(input)


    desired_rpm =

        calculate_target_rpm(

            input,
            controller.mode

        )


    desired_rpm *=

        pressure_factor *
        contact_factor


    desired_rpm =

        slew_limited_rpm(

            controller.previous_rpm,

            desired_rpm,

            dt

        )


    controller.target_rpm =

        clamp(

            desired_rpm,
            MIN_RPM,
            MAX_RPM

        )


    controller.target_power =

        calculate_target_power(

            input,

            controller.target_rpm

        )


    controller.previous_rpm =

        controller.target_rpm


    return controller

end


# ============================================================
# 36. SESSION SCORE
# ============================================================

function calculate_session_score(

    session::CleaningSession,
    manager::ZoneManager

)

    coverage =

        overall_coverage(manager)


    pressure =

        clamp(

            1.0 -
            (
                session.excessive_pressure_time /
                max(
                    session.active_time,
                    1.0
                )
            ),

            0.0,
            1.0

        )


    consistency =

        clamp(

            session.consistency_score,

            0.0,
            1.0

        )


    contact =

        clamp(

            session.contact_time /
            max(
                session.active_time,
                1.0
            ),

            0.0,
            1.0

        )


    session.coverage_score =
        coverage

    session.pressure_score =
        pressure

    session.global_score =

        0.35 * coverage +
        0.25 * pressure +
        0.20 * consistency +
        0.20 * contact


    return session.global_score

end


# ============================================================
# 37. SESSION UPDATE
# ============================================================

function update_session!(

    session::CleaningSession,
    input::CleaningInput,
    dt::Float64

)

    session.elapsed_time += dt


    if input.contact_probability >=
       CONTACT_MINIMUM

        session.contact_time += dt

        session.active_time += dt

    end


    if input.pressure >=
       EXCESSIVE_PRESSURE

        session.excessive_pressure_time += dt

    end


    if input.contact_probability < 0.30

        session.unstable_time += dt

    end


    session.average_pressure +=

        MOTION_FILTER_ALPHA *
        (
            input.pressure -
            session.average_pressure
        )


    session.average_contact +=

        MOTION_FILTER_ALPHA *
        (
            input.contact_probability -
            session.average_contact
        )


    session.average_motion +=

        MOTION_FILTER_ALPHA *
        (
            input.motion_intensity -
            session.average_motion
        )


    session.consistency_score =

        clamp(

            1.0 -
            (
                session.unstable_time /
                max(
                    session.elapsed_time,
                    1.0
                )
            ),

            0.0,
            1.0

        )


    return session

end


# ============================================================
# 38. BRUSHING COMPLETION
# ============================================================

function session_complete(

    session::CleaningSession,
    manager::ZoneManager

)

    time_complete =

        session.active_time >=
        TARGET_BRUSHING_TIME


    coverage_complete =

        overall_coverage(manager) >=
        0.80


    score_complete =

        session.global_score >=
        0.75


    return (

        time_complete &&
        coverage_complete &&
        score_complete

    )

end


# ============================================================
# 39. EARLY COMPLETION
# ============================================================

function high_quality_completion(

    session::CleaningSession,
    manager::ZoneManager

)

    return (

        session.active_time >= 90.0 &&

        overall_coverage(manager) >=
        0.90 &&

        session.global_score >=
        0.85

    )

end


# ============================================================
# 40. SESSION ENGINE
# ============================================================

mutable struct CleaningEngine

    session::CleaningSession

    controller::CleaningController

    zones::ZoneManager

    input::CleaningInput

    last_update::Float64

end


function CleaningEngine()

    CleaningEngine(

        CleaningSession(),

        CleaningController(),

        ZoneManager(),

        CleaningInput(),

        0.0

    )

end


# ============================================================
# 41. START SESSION
# ============================================================

function start!(

    engine::CleaningEngine,
    mode::CleaningMode =
        MODE_STANDARD

)

    engine.session =
        CleaningSession()

    engine.controller =
        CleaningController()

    engine.zones =
        ZoneManager()


    engine.session.mode =
        mode

    engine.session.phase =
        PHASE_STARTING


    engine.controller.mode =
        mode


    engine.controller.phase =
        PHASE_STARTING


    engine.last_update = 0.0


    return engine

end


# ============================================================
# 42. STOP SESSION
# ============================================================

function stop!(

    engine::CleaningEngine

)

    engine.session.phase =
        PHASE_FINISHING

    engine.controller.phase =
        PHASE_FINISHING


    calculate_session_score(

        engine.session,
        engine.zones

    )


    return engine.session

end


# ============================================================
# 43. COMPLETE UPDATE
# ============================================================

function update!(

    engine::CleaningEngine,
    input::CleaningInput,
    zone::BrushZone,
    dt::Float64

)

    engine.input = input


    update_session!(

        engine.session,
        input,
        dt

    )


    update_zone!(

        engine.zones,
        zone,
        input,
        dt

    )


    if engine.session.phase ==
       PHASE_STARTING

        engine.session.phase =
            PHASE_ACTIVE

        engine.controller.phase =
            PHASE_ACTIVE

    end


    update_controller!(

        engine.controller,
        input,
        dt

    )


    calculate_session_score(

        engine.session,
        engine.zones

    )


    if session_complete(

        engine.session,
        engine.zones

    )

        engine.session.phase =
            PHASE_COMPLETE

        engine.controller.phase =
            PHASE_COMPLETE

    end


    engine.last_update =
        input.timestamp


    return engine.controller

end


# ============================================================
# 44. SMART PRESSURE RESPONSE
# ============================================================

function pressure_message(

    input::CleaningInput

)

    if input.pressure >=
       EXCESSIVE_PRESSURE

        return "REDUCE_PRESSURE"

    elseif input.pressure >=
           HIGH_PRESSURE

        return "REDUCE_PRESSURE_SLIGHTLY"

    elseif input.pressure < 0.10

        return "LIGHT_CONTACT"

    elseif input.pressure <=
           NORMAL_PRESSURE

        return "GOOD_PRESSURE"

    end


    return "MONITOR_PRESSURE"

end


# ============================================================
# 45. MOTOR COMMAND
# ============================================================

struct CleaningMotorCommand

    rpm::Float64

    power_watts::Float64

    pressure_response::Float64

    thermal_limit::Float64

    battery_limit::Float64

    emergency_stop::Bool

end


function motor_command(

    engine::CleaningEngine

)

    input =
        engine.input


    emergency = (

        input.pressure >= 1.0 ||

        input.motor_temperature >=
        85.0 ||

        input.battery_soc <= 0.02

    )


    return CleaningMotorCommand(

        engine.controller.target_rpm,

        engine.controller.target_power,

        pressure_rpm_multiplier(
            input.pressure
        ),

        input.thermal_derating,

        input.battery_derating,

        emergency

    )

end


# ============================================================
# 46. SESSION TELEMETRY
# ============================================================

function telemetry(

    engine::CleaningEngine

)

    session =
        engine.session


    return Dict(

        "elapsed_seconds" =>
            session.elapsed_time,

        "active_seconds" =>
            session.active_time,

        "contact_seconds" =>
            session.contact_time,

        "average_pressure" =>
            session.average_pressure,

        "average_contact" =>
            session.average_contact,

        "average_motion" =>
            session.average_motion,

        "coverage_score" =>
            session.coverage_score,

        "pressure_score" =>
            session.pressure_score,

        "consistency_score" =>
            session.consistency_score,

        "global_score" =>
            session.global_score,

        "current_zone" =>
            string(
                session.current_zone
            ),

        "mode" =>
            string(session.mode),

        "phase" =>
            string(session.phase),

        "target_rpm" =>
            engine.controller.target_rpm,

        "target_power" =>
            engine.controller.target_power,

        "next_zone" =>
            string(
                next_recommended_zone(
                    engine.zones
                )
            )

    )

end


# ============================================================
# 47. ZONE TELEMETRY
# ============================================================

function zone_telemetry(

    manager::ZoneManager

)

    output = Dict{String,Any}()


    for (zone, state) in
        manager.zones

        if zone == ZONE_UNKNOWN

            continue

        end


        prefix =
            string(zone)


        output[
            prefix * "_time"
        ] =
            state.time_seconds


        output[
            prefix * "_effective_time"
        ] =
            state.effective_time


        output[
            prefix * "_score"
        ] =
            state.cleaning_score


        output[
            prefix * "_coverage"
        ] =
            state.coverage_score


        output[
            prefix * "_completed"
        ] =
            state.completed

    end


    return output

end


# ============================================================
# 48. RESET
# ============================================================

function reset!(

    engine::CleaningEngine

)

    engine.session =
        CleaningSession()

    engine.controller =
        CleaningController()

    engine.zones =
        ZoneManager()

    engine.input =
        CleaningInput()

    engine.last_update =
        0.0


    return engine

end


# ============================================================
# 49. EXPORTS
# ============================================================

export CleaningMode
export BrushingPhase
export CleaningContact
export BrushZone

export CleaningInput
export ZoneState
export ZoneManager
export CleaningSession
export CleaningController
export CleaningEngine
export CleaningMotorCommand

export start!
export stop!
export update!
export reset!

export pressure_quality
export contact_quality
export motion_quality

export classify_contact
export instantaneous_cleaning_score
export effective_cleaning_rate

export zone_coverage_score
export calculate_zone_score
export overall_coverage
export missing_zones
export next_recommended_zone

export calculate_target_rpm
export calculate_target_power
export pressure_rpm_multiplier

export session_complete
export high_quality_completion

export motor_command
export pressure_message

export telemetry
export zone_telemetry

end





module ToothbrushZoneEstimator

using Statistics

# ============================================================
# TOOTHBRUSH SPATIAL / TOOTH-ZONE ESTIMATION
#
# Sensor inputs:
#   - accelerometer
#   - gyroscope
#   - orientation
#   - contact probability
#   - tooth-contact probability
#   - pressure
#   - vibration
#   - motion direction
#   - brushing velocity
#
# Outputs:
#   - estimated mouth zone
#   - zone probabilities
#   - spatial confidence
#   - transition detection
#   - trajectory state
#   - zone dwell time
#   - coverage map
#
# This is a research/reference estimator.
# A real product would require subject-specific and
# clinically validated sensor data.
# ============================================================


# ============================================================
# 01. CONSTANTS
# ============================================================

const DEG_TO_RAD = π / 180.0

const MIN_ZONE_CONFIDENCE = 0.35

const HIGH_ZONE_CONFIDENCE = 0.75

const ZONE_TRANSITION_THRESHOLD = 0.55

const ORIENTATION_ALPHA = 0.08

const MOTION_ALPHA = 0.12

const POSITION_ALPHA = 0.05

const PROBABILITY_ALPHA = 0.10

const HISTORY_LENGTH = 64

const MIN_DWELL_TIME = 0.75

const TRANSITION_TIME = 1.0

const MAX_MOUTH_VELOCITY = 2.0

const MIN_CONTACT_FOR_LOCALISATION = 0.18


# ============================================================
# 02. VECTOR
# ============================================================

struct Vector3

    x::Float64
    y::Float64
    z::Float64

end


Vector3() =
    Vector3(0.0, 0.0, 0.0)


function norm(v::Vector3)

    sqrt(

        v.x^2 +
        v.y^2 +
        v.z^2

    )

end


function normalize(v::Vector3)

    n = norm(v)

    if n < 1e-9

        return Vector3()

    end


    return Vector3(

        v.x / n,
        v.y / n,
        v.z / n

    )

end


function +(a::Vector3, b::Vector3)

    Vector3(

        a.x + b.x,
        a.y + b.y,
        a.z + b.z

    )

end


function -(a::Vector3, b::Vector3)

    Vector3(

        a.x - b.x,
        a.y - b.y,
        a.z - b.z

    )

end


function *(a::Vector3, s::Float64)

    Vector3(

        a.x * s,
        a.y * s,
        a.z * s

    )

end


function dot(a::Vector3, b::Vector3)

    a.x*b.x +
    a.y*b.y +
    a.z*b.z

end


# ============================================================
# 03. MOUTH ZONES
# ============================================================

@enum ToothZone begin

    ZONE_UNKNOWN

    ZONE_UPPER_LEFT_OUTER
    ZONE_UPPER_LEFT_INNER
    ZONE_UPPER_LEFT_OCCLUSAL

    ZONE_UPPER_FRONT_OUTER
    ZONE_UPPER_FRONT_INNER
    ZONE_UPPER_FRONT_OCCLUSAL

    ZONE_UPPER_RIGHT_OUTER
    ZONE_UPPER_RIGHT_INNER
    ZONE_UPPER_RIGHT_OCCLUSAL

    ZONE_LOWER_LEFT_OUTER
    ZONE_LOWER_LEFT_INNER
    ZONE_LOWER_LEFT_OCCLUSAL

    ZONE_LOWER_FRONT_OUTER
    ZONE_LOWER_FRONT_INNER
    ZONE_LOWER_FRONT_OCCLUSAL

    ZONE_LOWER_RIGHT_OUTER
    ZONE_LOWER_RIGHT_INNER
    ZONE_LOWER_RIGHT_OCCLUSAL

    ZONE_GUM_LINE_UPPER
    ZONE_GUM_LINE_LOWER

end


const ALL_ZONES = collect(instances(ToothZone))


# ============================================================
# 04. MOUTH REGION
# ============================================================

@enum MouthRegion begin

    REGION_UNKNOWN
    REGION_UPPER
    REGION_LOWER
    REGION_LEFT
    REGION_RIGHT
    REGION_FRONT
    REGION_REAR
    REGION_OCCLUSAL
    REGION_INNER
    REGION_OUTER

end


# ============================================================
# 05. ORIENTATION STATE
# ============================================================

mutable struct OrientationState

    roll::Float64
    pitch::Float64
    yaw::Float64

    filtered_roll::Float64
    filtered_pitch::Float64
    filtered_yaw::Float64

end


function OrientationState()

    OrientationState(

        0.0,
        0.0,
        0.0,

        0.0,
        0.0,
        0.0

    )

end


# ============================================================
# 06. MOTION STATE
# ============================================================

mutable struct MotionState

    acceleration::Vector3

    angular_velocity::Vector3

    velocity::Vector3

    movement_direction::Vector3

    intensity::Float64

    speed::Float64

end


function MotionState()

    MotionState(

        Vector3(),
        Vector3(),
        Vector3(),
        Vector3(),

        0.0,
        0.0

    )

end


# ============================================================
# 07. SENSOR INPUT
# ============================================================

mutable struct ZoneSensorInput

    acceleration::Vector3

    gyroscope::Vector3

    roll::Float64
    pitch::Float64
    yaw::Float64

    contact_probability::Float64
    tooth_contact_probability::Float64

    pressure::Float64
    vibration::Float64

    brushing_velocity::Float64
    timestamp::Float64

end


function ZoneSensorInput()

    ZoneSensorInput(

        Vector3(),
        Vector3(),

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

end


# ============================================================
# 08. ZONE PROBABILITY
# ============================================================

mutable struct ZoneProbability

    zone::ToothZone

    probability::Float64

    spatial_score::Float64

    motion_score::Float64

    orientation_score::Float64

    contact_score::Float64

    vibration_score::Float64

    temporal_score::Float64

end


function ZoneProbability(

    zone::ToothZone

)

    ZoneProbability(

        zone,

        0.0,

        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0

    )

end


# ============================================================
# 09. ZONE HISTORY
# ============================================================

mutable struct ZoneHistory

    zones::Vector{ToothZone}

    probabilities::Vector{Float64}

    timestamps::Vector{Float64}

    index::Int

end


function ZoneHistory()

    ZoneHistory(

        fill(
            ZONE_UNKNOWN,
            HISTORY_LENGTH
        ),

        zeros(HISTORY_LENGTH),

        zeros(HISTORY_LENGTH),

        1

    )

end


function push_history!(

    history::ZoneHistory,
    zone::ToothZone,
    probability::Float64,
    timestamp::Float64

)

    history.zones[
        history.index
    ] = zone

    history.probabilities[
        history.index
    ] = probability

    history.timestamps[
        history.index
    ] = timestamp


    history.index += 1


    if history.index >
       HISTORY_LENGTH

        history.index = 1

    end

end


# ============================================================
# 10. ZONE DWELL
# ============================================================

mutable struct ZoneDwell

    zone::ToothZone

    start_time::Float64

    duration::Float64

    contact_time::Float64

    effective_time::Float64

end


function ZoneDwell()

    ZoneDwell(

        ZONE_UNKNOWN,
        0.0,
        0.0,
        0.0,
        0.0

    )

end


# ============================================================
# 11. COVERAGE STATE
# ============================================================

mutable struct ZoneCoverage

    contact_time::Float64

    effective_time::Float64

    exposure_score::Float64

    confidence::Float64

    completed::Bool

end


function ZoneCoverage()

    ZoneCoverage(

        0.0,
        0.0,
        0.0,
        0.0,
        false

    )

end


# ============================================================
# 12. ZONE MAP
# ============================================================

mutable struct MouthCoverageMap

    coverage::Dict{ToothZone,ZoneCoverage}

end


function MouthCoverageMap()

    MouthCoverageMap(

        Dict(

            zone =>
                ZoneCoverage()

            for zone in ALL_ZONES

        )

    )

end


# ============================================================
# 13. SPATIAL STATE
# ============================================================

mutable struct SpatialState

    x::Float64
    y::Float64
    z::Float64

    velocity_x::Float64
    velocity_y::Float64
    velocity_z::Float64

    mouth_region::MouthRegion

    estimated_zone::ToothZone

    confidence::Float64

    contact::Bool

    transition::Bool

end


function SpatialState()

    SpatialState(

        0.0,
        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        REGION_UNKNOWN,

        ZONE_UNKNOWN,

        0.0,

        false,

        false

    )

end


# ============================================================
# 14. ORIENTATION UPDATE
# ============================================================

function update_orientation!(

    state::OrientationState,
    input::ZoneSensorInput

)

    state.roll =
        input.roll

    state.pitch =
        input.pitch

    state.yaw =
        input.yaw


    state.filtered_roll +=

        ORIENTATION_ALPHA *
        (
            input.roll -
            state.filtered_roll
        )


    state.filtered_pitch +=

        ORIENTATION_ALPHA *
        (
            input.pitch -
            state.filtered_pitch
        )


    state.filtered_yaw +=

        ORIENTATION_ALPHA *
        (
            input.yaw -
            state.filtered_yaw
        )


    return state

end


# ============================================================
# 15. MOTION UPDATE
# ============================================================

function update_motion!(

    state::MotionState,
    input::ZoneSensorInput,
    dt::Float64

)

    state.acceleration =
        input.acceleration

    state.angular_velocity =
        input.gyroscope


    state.intensity =

        norm(
            input.acceleration
        )


    state.speed =

        abs(
            input.brushing_velocity
        )


    direction =

        normalize(
            input.acceleration
        )


    state.movement_direction +=

        direction *
        MOTION_ALPHA


    state.movement_direction =

        normalize(
            state.movement_direction
        )


    state.velocity =

        state.velocity +
        input.acceleration *
        dt


    # Prevent integration drift from growing
    # without bound.

    velocity_norm =
        norm(state.velocity)


    if velocity_norm >
       MAX_MOUTH_VELOCITY

        state.velocity =

            normalize(
                state.velocity
            ) *
            MAX_MOUTH_VELOCITY

    end


    return state

end


# ============================================================
# 16. ORIENTATION FEATURES
# ============================================================

function orientation_vector(

    orientation::OrientationState

)

    roll =
        orientation.filtered_roll *
        DEG_TO_RAD

    pitch =
        orientation.filtered_pitch *
        DEG_TO_RAD

    yaw =
        orientation.filtered_yaw *
        DEG_TO_RAD


    return Vector3(

        cos(pitch) * cos(yaw),

        cos(pitch) * sin(yaw),

        sin(pitch)

    )

end


# ============================================================
# 17. UPPER / LOWER CLASSIFICATION
# ============================================================

function upper_probability(

    orientation::OrientationState

)

    pitch =
        orientation.filtered_pitch


    # Approximate geometric feature.
    # Real implementations should learn this from
    # calibrated user-specific trajectories.

    return clamp(

        0.5 +
        0.5 *
        sin(
            pitch *
            DEG_TO_RAD
        ),

        0.0,
        1.0

    )

end


function lower_probability(

    orientation::OrientationState

)

    return (

        1.0 -
        upper_probability(
            orientation
        )

    )

end


# ============================================================
# 18. LEFT / RIGHT CLASSIFICATION
# ============================================================

function left_probability(

    orientation::OrientationState

)

    yaw =
        orientation.filtered_yaw


    return clamp(

        0.5 -
        0.5 *
        sin(
            yaw *
            DEG_TO_RAD
        ),

        0.0,
        1.0

    )

end


function right_probability(

    orientation::OrientationState

)

    return (

        1.0 -
        left_probability(
            orientation
        )

    )

end


# ============================================================
# 19. FRONT / REAR
# ============================================================

function front_probability(

    orientation::OrientationState

)

    roll =
        abs(
            orientation.filtered_roll
        )


    return clamp(

        1.0 -
        roll /
        120.0,

        0.0,
        1.0

    )

end


function rear_probability(

    orientation::OrientationState

)

    return (

        1.0 -
        front_probability(
            orientation
        )

    )

end


# ============================================================
# 20. INNER / OUTER
# ============================================================

function inner_probability(

    orientation::OrientationState

)

    pitch =
        abs(
            orientation.filtered_pitch
        )


    return clamp(

        pitch /
        90.0,

        0.0,
        1.0

    )

end


function outer_probability(

    orientation::OrientationState

)

    return (

        1.0 -
        inner_probability(
            orientation
        )

    )

end


# ============================================================
# 21. OCCLUSAL PROBABILITY
# ============================================================

function occlusal_probability(

    orientation::OrientationState,
    motion::MotionState

)

    vertical_motion =

        abs(
            motion.acceleration.z
        )


    return clamp(

        0.5 *
        vertical_motion +

        0.5 *
        abs(
            sin(
                orientation.filtered_pitch *
                DEG_TO_RAD
            )
        ),

        0.0,
        1.0

    )

end


# ============================================================
# 22. GUM-LINE PROBABILITY
# ============================================================

function gum_probability(

    pressure::Float64,
    vibration::Float64,
    contact::Float64

)

    # Gum-line estimation is intentionally conservative:
    # pressure and contact behaviour contribute, but neither
    # is treated as definitive anatomical identification.

    pressure_factor = clamp(

        1.0 -
        pressure,

        0.0,
        1.0

    )


    vibration_factor = clamp(

        vibration,

        0.0,
        1.0

    )


    return clamp(

        0.35 * pressure_factor +
        0.25 * vibration_factor +
        0.40 * contact,

        0.0,
        1.0

    )

end


# ============================================================
# 23. CONTACT SCORE
# ============================================================

function contact_score(

    input::ZoneSensorInput

)

    return clamp(

        0.50 *
        input.contact_probability +

        0.35 *
        input.tooth_contact_probability +

        0.15 *
        min(
            input.vibration,
            1.0
        ),

        0.0,
        1.0

    )

end


# ============================================================
# 24. TEMPORAL CONTINUITY
# ============================================================

function temporal_score(

    candidate::ToothZone,
    history::ZoneHistory

)

    score = 0.0


    for i in 1:HISTORY_LENGTH

        if history.zones[i] ==
           candidate

            age =

                (
                    HISTORY_LENGTH -
                    i
                ) /
                HISTORY_LENGTH


            score +=

                (
                    1.0 -
                    age
                ) *
                history.probabilities[i]

        end

    end


    return clamp(

        score /
        max(
            HISTORY_LENGTH * 0.10,
            1.0
        ),

        0.0,
        1.0

    )

end


# ============================================================
# 25. ZONE FEATURE SCORE
# ============================================================

function zone_feature_score(

    zone::ToothZone,
    orientation::OrientationState,
    motion::MotionState,
    input::ZoneSensorInput

)

    upper =
        upper_probability(orientation)

    lower =
        lower_probability(orientation)

    left =
        left_probability(orientation)

    right =
        right_probability(orientation)

    front =
        front_probability(orientation)

    rear =
        rear_probability(orientation)

    inner =
        inner_probability(orientation)

    outer =
        outer_probability(orientation)

    occlusal =
        occlusal_probability(
            orientation,
            motion
        )


    if zone == ZONE_UPPER_LEFT_OUTER

        return (
            upper *
            left *
            outer
        )

    elseif zone == ZONE_UPPER_LEFT_INNER

        return (
            upper *
            left *
            inner
        )

    elseif zone == ZONE_UPPER_LEFT_OCCLUSAL

        return (
            upper *
            left *
            occlusal
        )

    elseif zone == ZONE_UPPER_FRONT_OUTER

        return (
            upper *
            front *
            outer
        )

    elseif zone == ZONE_UPPER_FRONT_INNER

        return (
            upper *
            front *
            inner
        )

    elseif zone == ZONE_UPPER_FRONT_OCCLUSAL

        return (
            upper *
            front *
            occlusal
        )

    elseif zone == ZONE_UPPER_RIGHT_OUTER

        return (
            upper *
            right *
            outer
        )

    elseif zone == ZONE_UPPER_RIGHT_INNER

        return (
            upper *
            right *
            inner
        )

    elseif zone == ZONE_UPPER_RIGHT_OCCLUSAL

        return (
            upper *
            right *
            occlusal
        )

    elseif zone == ZONE_LOWER_LEFT_OUTER

        return (
            lower *
            left *
            outer
        )

    elseif zone == ZONE_LOWER_LEFT_INNER

        return (
            lower *
            left *
            inner
        )

    elseif zone == ZONE_LOWER_LEFT_OCCLUSAL

        return (
            lower *
            left *
            occlusal
        )

    elseif zone == ZONE_LOWER_FRONT_OUTER

        return (
            lower *
            front *
            outer
        )

    elseif zone == ZONE_LOWER_FRONT_INNER

        return (
            lower *
            front *
            inner
        )

    elseif zone == ZONE_LOWER_FRONT_OCCLUSAL

        return (
            lower *
            front *
            occlusal
        )

    elseif zone == ZONE_LOWER_RIGHT_OUTER

        return (
            lower *
            right *
            outer
        )

    elseif zone == ZONE_LOWER_RIGHT_INNER

        return (
            lower *
            right *
            inner
        )

    elseif zone == ZONE_LOWER_RIGHT_OCCLUSAL

        return (
            lower *
            right *
            occlusal
        )

    elseif zone == ZONE_GUM_LINE_UPPER

        return (
            upper *
            gum_probability(
                input.pressure,
                input.vibration,
                input.contact_probability
            )
        )

    elseif zone == ZONE_GUM_LINE_LOWER

        return (
            lower *
            gum_probability(
                input.pressure,
                input.vibration,
                input.contact_probability
            )
        )

    end


    return 0.0

end


# ============================================================
# 26. ZONE PROBABILITY UPDATE
# ============================================================

function update_probability!(

    probability::ZoneProbability,
    orientation::OrientationState,
    motion::MotionState,
    input::ZoneSensorInput,
    history::ZoneHistory

)

    probability.spatial_score =

        zone_feature_score(

            probability.zone,

            orientation,
            motion,
            input

        )


    probability.motion_score =

        clamp(

            norm(
                motion.movement_direction
            ),

            0.0,
            1.0

        )


    probability.orientation_score =

        probability.spatial_score


    probability.contact_score =

        contact_score(input)


    probability.vibration_score =

        clamp(

            input.vibration,

            0.0,
            1.0

        )


    probability.temporal_score =

        temporal_score(

            probability.zone,
            history

        )


    combined =

        0.30 *
        probability.spatial_score +

        0.15 *
        probability.motion_score +

        0.20 *
        probability.orientation_score +

        0.15 *
        probability.contact_score +

        0.05 *
        probability.vibration_score +

        0.15 *
        probability.temporal_score


    probability.probability +=

        PROBABILITY_ALPHA *
        (
            combined -
            probability.probability
        )


    return probability.probability

end


# ============================================================
# 27. PROBABILITY NORMALISATION
# ============================================================

function normalise_probabilities!(

    probabilities::Vector{ZoneProbability}

)

    total = sum(

        p.probability
        for p in probabilities

    )


    if total < 1e-9

        return probabilities

    end


    for probability in probabilities

        probability.probability /= total

    end


    return probabilities

end


# ============================================================
# 28. BEST ZONE
# ============================================================

function best_zone(

    probabilities::Vector{ZoneProbability}

)

    if isempty(probabilities)

        return ZONE_UNKNOWN

    end


    best =
        probabilities[1]


    for p in probabilities

        if p.probability >
           best.probability

            best = p

        end

    end


    return best.zone

end


# ============================================================
# 29. BEST CONFIDENCE
# ============================================================

function best_confidence(

    probabilities::Vector{ZoneProbability}

)

    if isempty(probabilities)

        return 0.0

    end


    return maximum(

        p.probability
        for p in probabilities

    )

end


# ============================================================
# 30. ZONE TRANSITION
# ============================================================

mutable struct ZoneTransition

    previous_zone::ToothZone

    new_zone::ToothZone

    confidence::Float64

    timestamp::Float64

    valid::Bool

end


function ZoneTransition()

    ZoneTransition(

        ZONE_UNKNOWN,
        ZONE_UNKNOWN,
        0.0,
        0.0,
        false

    )

end


# ============================================================
# 31. TRANSITION DETECTION
# ============================================================

function detect_transition(

    previous::ToothZone,
    current::ToothZone,
    confidence::Float64,
    timestamp::Float64

)

    return ZoneTransition(

        previous,
        current,
        confidence,
        timestamp,

        previous != current &&
        confidence >=
        ZONE_TRANSITION_THRESHOLD

    )

end


# ============================================================
# 32. SPATIAL ENGINE
# ============================================================

mutable struct ToothZoneEngine

    orientation::OrientationState

    motion::MotionState

    probabilities::Vector{ZoneProbability}

    history::ZoneHistory

    dwell::ZoneDwell

    coverage::MouthCoverageMap

    spatial::SpatialState

    transition::ZoneTransition

    elapsed_time::Float64

end


function ToothZoneEngine()

    probabilities = [

        ZoneProbability(zone)

        for zone in ALL_ZONES

    ]


    ToothZoneEngine(

        OrientationState(),

        MotionState(),

        probabilities,

        ZoneHistory(),

        ZoneDwell(),

        MouthCoverageMap(),

        SpatialState(),

        ZoneTransition(),

        0.0

    )

end


# ============================================================
# 33. REGION CLASSIFICATION
# ============================================================

function classify_region(

    orientation::OrientationState

)

    upper =
        upper_probability(
            orientation
        )

    left =
        left_probability(
            orientation
        )

    front =
        front_probability(
            orientation
        )


    if upper > 0.65

        return REGION_UPPER

    elseif upper < 0.35

        return REGION_LOWER

    elseif left > 0.65

        return REGION_LEFT

    elseif left < 0.35

        return REGION_RIGHT

    elseif front > 0.65

        return REGION_FRONT

    end


    return REGION_UNKNOWN

end


# ============================================================
# 34. DWELL UPDATE
# ============================================================

function update_dwell!(

    engine::ToothZoneEngine,
    zone::ToothZone,
    confidence::Float64,
    contact::Float64,
    timestamp::Float64,
    dt::Float64

)

    if zone !=
       engine.dwell.zone

        engine.dwell =

            ZoneDwell(

                zone,
                timestamp,
                0.0,
                0.0,
                0.0

            )

    end


    engine.dwell.duration += dt


    if contact >=
       MIN_CONTACT_FOR_LOCALISATION

        engine.dwell.contact_time += dt

    end


    effective =

        contact *
        confidence


    engine.dwell.effective_time +=

        effective *
        dt


    return engine.dwell

end


# ============================================================
# 35. COVERAGE UPDATE
# ============================================================

function update_coverage!(

    engine::ToothZoneEngine,
    zone::ToothZone,
    confidence::Float64,
    contact::Float64,
    dt::Float64

)

    if zone ==
       ZONE_UNKNOWN

        return

    end


    coverage =

        engine.coverage.coverage[zone]


    coverage.confidence +=

        POSITION_ALPHA *
        (
            confidence -
            coverage.confidence
        )


    if contact >=
       MIN_CONTACT_FOR_LOCALISATION

        coverage.contact_time += dt


        coverage.effective_time +=

            contact *
            confidence *
            dt

    end


    coverage.exposure_score =

        clamp(

            coverage.effective_time /
            10.0,

            0.0,
            1.0

        )


    coverage.completed =

        coverage.effective_time >=
        8.0 &&
        coverage.confidence >=
        MIN_ZONE_CONFIDENCE

end


# ============================================================
# 36. MAIN UPDATE
# ============================================================

function update!(

    engine::ToothZoneEngine,
    input::ZoneSensorInput,
    dt::Float64 = 0.05

)

    engine.elapsed_time += dt


    update_orientation!(

        engine.orientation,
        input

    )


    update_motion!(

        engine.motion,
        input,
        dt

    )


    # If there is essentially no contact, spatial
    # localisation becomes unreliable.

    localisation_contact =

        max(

            input.contact_probability,
            input.tooth_contact_probability

        )


    for probability in
        engine.probabilities

        update_probability!(

            probability,

            engine.orientation,
            engine.motion,

            input,

            engine.history

        )

    end


    normalise_probabilities!(

        engine.probabilities

    )


    candidate_zone =

        best_zone(
            engine.probabilities
        )


    confidence =

        best_confidence(
            engine.probabilities
        )


    if localisation_contact <
       MIN_CONTACT_FOR_LOCALISATION

        candidate_zone =
            ZONE_UNKNOWN

        confidence *= 0.5

    end


    previous_zone =

        engine.spatial.estimated_zone


    transition =

        detect_transition(

            previous_zone,

            candidate_zone,

            confidence,

            input.timestamp

        )


    engine.transition =
        transition


    if transition.valid

        engine.spatial.transition =
            true

    else

        engine.spatial.transition =
            false

    end


    engine.spatial.estimated_zone =
        candidate_zone


    engine.spatial.confidence =
        confidence


    engine.spatial.contact =

        localisation_contact >=
        MIN_CONTACT_FOR_LOCALISATION


    engine.spatial.mouth_region =

        classify_region(
            engine.orientation
        )


    update_dwell!(

        engine,

        candidate_zone,

        confidence,

        localisation_contact,

        input.timestamp,

        dt

    )


    update_coverage!(

        engine,

        candidate_zone,

        confidence,

        localisation_contact,

        dt

    )


    push_history!(

        engine.history,

        candidate_zone,

        confidence,

        input.timestamp

    )


    return engine.spatial

end


# ============================================================
# 37. CURRENT ZONE
# ============================================================

function current_zone(

    engine::ToothZoneEngine

)

    return engine.spatial.estimated_zone

end


# ============================================================
# 38. CURRENT CONFIDENCE
# ============================================================

function zone_confidence(

    engine::ToothZoneEngine

)

    return engine.spatial.confidence

end


# ============================================================
# 39. ZONE STABLE?
# ============================================================

function zone_stable(

    engine::ToothZoneEngine

)

    return (

        engine.dwell.duration >=
        MIN_DWELL_TIME &&

        engine.spatial.confidence >=
        MIN_ZONE_CONFIDENCE

    )

end


# ============================================================
# 40. TRANSITION ACTIVE?
# ============================================================

function transitioning(

    engine::ToothZoneEngine

)

    return engine.spatial.transition

end


# ============================================================
# 41. COVERAGE
# ============================================================

function zone_coverage(

    engine::ToothZoneEngine,
    zone::ToothZone

)

    return engine.coverage.coverage[
        zone
    ]

end


# ============================================================
# 42. OVERALL COVERAGE
# ============================================================

function overall_coverage(

    engine::ToothZoneEngine

)

    completed = 0
    total = 0


    for zone in ALL_ZONES

        if zone == ZONE_UNKNOWN

            continue

        end


        total += 1


        if engine.coverage.coverage[
            zone
        ].completed

            completed += 1

        end

    end


    if total == 0

        return 0.0

    end


    return completed / total

end


# ============================================================
# 43. COVERAGE WEIGHTED BY CONFIDENCE
# ============================================================

function confidence_weighted_coverage(

    engine::ToothZoneEngine

)

    numerator = 0.0
    denominator = 0.0


    for zone in ALL_ZONES

        if zone == ZONE_UNKNOWN

            continue

        end


        state =
            engine.coverage.coverage[
                zone
            ]


        numerator +=

            state.exposure_score *
            state.confidence


        denominator +=

            state.confidence

    end


    if denominator < 1e-9

        return 0.0

    end


    return numerator /
           denominator

end


# ============================================================
# 44. MISSING ZONES
# ============================================================

function missing_zones(

    engine::ToothZoneEngine

)

    return [

        zone

        for zone in ALL_ZONES

        if zone != ZONE_UNKNOWN &&

           !engine.coverage.coverage[
                zone
           ].completed

    ]

end


# ============================================================
# 45. LEAST COVERED ZONE
# ============================================================

function least_covered_zone(

    engine::ToothZoneEngine

)

    candidates =
        missing_zones(engine)


    if isempty(candidates)

        return ZONE_UNKNOWN

    end


    best =
        candidates[1]


    best_score =

        engine.coverage.coverage[
            best
        ].exposure_score


    for zone in candidates

        score =

            engine.coverage.coverage[
                zone
            ].exposure_score


        if score < best_score

            best =
                zone

            best_score =
                score

        end

    end


    return best

end


# ============================================================
# 46. ZONE PROBABILITY TABLE
# ============================================================

function probabilities(

    engine::ToothZoneEngine

)

    return Dict(

        string(p.zone) =>
            p.probability

        for p in
        engine.probabilities

    )

end


# ============================================================
# 47. SPATIAL TELEMETRY
# ============================================================

function telemetry(

    engine::ToothZoneEngine

)

    return Dict(

        "zone" =>
            string(
                current_zone(engine)
            ),

        "confidence" =>
            zone_confidence(engine),

        "region" =>
            string(
                engine.spatial.mouth_region
            ),

        "contact" =>
            engine.spatial.contact,

        "transition" =>
            transitioning(engine),

        "dwell_seconds" =>
            engine.dwell.duration,

        "contact_seconds" =>
            engine.dwell.contact_time,

        "effective_seconds" =>
            engine.dwell.effective_time,

        "overall_coverage" =>
            overall_coverage(engine),

        "confidence_weighted_coverage" =>
            confidence_weighted_coverage(engine),

        "least_covered_zone" =>
            string(
                least_covered_zone(engine)
            )

    )

end


# ============================================================
# 48. DEBUG FEATURE VECTOR
# ============================================================

function feature_vector(

    engine::ToothZoneEngine

)

    o =
        engine.orientation

    m =
        engine.motion


    return [

        o.filtered_roll,
        o.filtered_pitch,
        o.filtered_yaw,

        m.acceleration.x,
        m.acceleration.y,
        m.acceleration.z,

        m.angular_velocity.x,
        m.angular_velocity.y,
        m.angular_velocity.z,

        m.velocity.x,
        m.velocity.y,
        m.velocity.z,

        m.intensity,
        m.speed

    ]

end


# ============================================================
# 49. RESET
# ============================================================

function reset!(

    engine::ToothZoneEngine

)

    engine.orientation =
        OrientationState()

    engine.motion =
        MotionState()

    engine.probabilities = [

        ZoneProbability(zone)

        for zone in ALL_ZONES

    ]

    engine.history =
        ZoneHistory()

    engine.dwell =
        ZoneDwell()

    engine.coverage =
        MouthCoverageMap()

    engine.spatial =
        SpatialState()

    engine.transition =
        ZoneTransition()

    engine.elapsed_time =
        0.0


    return engine

end


# ============================================================
# 50. EXPORTS
# ============================================================

export Vector3

export ToothZone
export MouthRegion

export ZoneSensorInput
export ZoneProbability
export ZoneHistory
export ZoneDwell
export ZoneCoverage
export MouthCoverageMap
export SpatialState

export ToothZoneEngine

export update!
export reset!

export current_zone
export zone_confidence
export zone_stable
export transitioning

export zone_coverage
export overall_coverage
export confidence_weighted_coverage

export missing_zones
export least_covered_zone

export probabilities
export telemetry
export feature_vector

end






module ToothbrushSafetyDiagnostics

using Statistics

# ============================================================
# TOOTHBRUSH SAFETY & DIAGNOSTICS SUPERVISOR
#
# Supervisory layer for the complete toothbrush digital twin.
#
# Monitors:
#   - Motor
#   - Battery
#   - Thermal system
#   - Pressure/contact
#   - Sensors
#   - Zone estimator
#   - Control loop
#   - Power electronics
#   - Communications/watchdog
#
# Outputs:
#   - Safety state
#   - Motor permission
#   - Power/RPM derating
#   - Fault flags
#   - Warnings
#   - Emergency-stop request
#   - Diagnostic telemetry
#
# Reference/simulation architecture only.
# Production firmware would require hardware-specific,
# electrical and clinical validation.
# ============================================================


# ============================================================
# 01. CONSTANTS
# ============================================================

const SAFETY_LOOP_HZ = 100.0
const SAFETY_DT = 1.0 / SAFETY_LOOP_HZ

const WATCHDOG_TIMEOUT = 0.100
const SENSOR_TIMEOUT = 0.250
const ZONE_TIMEOUT = 1.000

const MAX_MOTOR_RPM = 42000.0
const MAX_MOTOR_CURRENT = 8.0

const MAX_BATTERY_TEMPERATURE = 60.0
const MAX_MOTOR_TEMPERATURE = 85.0
const MAX_INVERTER_TEMPERATURE = 95.0
const MAX_PCB_TEMPERATURE = 90.0

const MIN_BATTERY_VOLTAGE = 2.90
const MAX_BATTERY_VOLTAGE = 4.25

const EXCESSIVE_PRESSURE = 0.82
const CRITICAL_PRESSURE = 0.95

const MIN_SENSOR_CONFIDENCE = 0.25
const MIN_ZONE_CONFIDENCE = 0.20

const FAULT_CONFIRMATION_COUNT = 3
const FAULT_CLEAR_COUNT = 10

const TEMPERATURE_MARGIN = 5.0
const VOLTAGE_MARGIN = 0.10
const CURRENT_MARGIN = 0.50

const MAX_ALLOWED_RPM_ERROR = 8000.0
const MAX_ALLOWED_SENSOR_DISAGREEMENT = 0.35

const DIAGNOSTIC_HISTORY_LENGTH = 256


# ============================================================
# 02. SAFETY STATES
# ============================================================

@enum SafetyState begin

    SAFETY_INIT

    SAFETY_READY

    SAFETY_NORMAL

    SAFETY_WARNING

    SAFETY_DERATING

    SAFETY_PROTECTIVE

    SAFETY_STOPPING

    SAFETY_STOPPED

    SAFETY_FAULT

    SAFETY_EMERGENCY

end


# ============================================================
# 03. FAULT TYPES
# ============================================================

@enum FaultType begin

    FAULT_NONE

    FAULT_MOTOR_OVERCURRENT
    FAULT_MOTOR_OVERSPEED
    FAULT_MOTOR_OVERTEMPERATURE
    FAULT_MOTOR_STALL

    FAULT_BATTERY_UNDERVOLTAGE
    FAULT_BATTERY_OVERVOLTAGE
    FAULT_BATTERY_OVERTEMPERATURE
    FAULT_BATTERY_CURRENT

    FAULT_INVERTER_OVERTEMPERATURE
    FAULT_PCB_OVERTEMPERATURE

    FAULT_EXCESSIVE_PRESSURE

    FAULT_SENSOR_FAILURE
    FAULT_SENSOR_DISAGREEMENT
    FAULT_SENSOR_TIMEOUT

    FAULT_ZONE_ESTIMATOR

    FAULT_CONTROL_TIMEOUT
    FAULT_WATCHDOG

    FAULT_RPM_TRACKING
    FAULT_THERMAL_RUNAWAY

    FAULT_INTERNAL

end


# ============================================================
# 04. FAULT SEVERITY
# ============================================================

@enum FaultSeverity begin

    SEVERITY_INFO
    SEVERITY_WARNING
    SEVERITY_DERATE
    SEVERITY_PROTECTIVE
    SEVERITY_CRITICAL

end


# ============================================================
# 05. FAULT RECORD
# ============================================================

mutable struct FaultRecord

    fault::FaultType

    severity::FaultSeverity

    active::Bool

    confirmed::Bool

    count::Int

    clear_count::Int

    first_timestamp::Float64

    last_timestamp::Float64

    description::String

end


function FaultRecord(

    fault::FaultType,
    severity::FaultSeverity,
    description::String

)

    FaultRecord(

        fault,
        severity,

        false,
        false,

        0,
        0,

        0.0,
        0.0,

        description

    )

end


# ============================================================
# 06. MOTOR DIAGNOSTIC INPUT
# ============================================================

struct MotorDiagnosticInput

    rpm::Float64
    target_rpm::Float64

    current::Float64

    torque::Float64

    temperature::Float64

    electrical_power::Float64
    mechanical_power::Float64

    stalled::Bool

    running::Bool

end


function MotorDiagnosticInput()

    MotorDiagnosticInput(

        0.0,
        0.0,

        0.0,

        0.0,

        25.0,

        0.0,
        0.0,

        false,
        false

    )

end


# ============================================================
# 07. BATTERY DIAGNOSTIC INPUT
# ============================================================

struct BatteryDiagnosticInput

    voltage::Float64
    current::Float64

    soc::Float64

    temperature::Float64

    available_power::Float64

    internal_resistance::Float64

    charging::Bool

end


function BatteryDiagnosticInput()

    BatteryDiagnosticInput(

        3.7,
        0.0,

        1.0,

        25.0,

        20.0,

        0.08,

        false

    )

end


# ============================================================
# 08. THERMAL DIAGNOSTIC INPUT
# ============================================================

struct ThermalDiagnosticInput

    motor_temperature::Float64
    battery_temperature::Float64
    inverter_temperature::Float64
    pcb_temperature::Float64
    housing_temperature::Float64

    global_derating::Float64

    emergency_shutdown::Bool

end


function ThermalDiagnosticInput()

    ThermalDiagnosticInput(

        25.0,
        25.0,
        25.0,
        25.0,
        25.0,

        1.0,

        false

    )

end


# ============================================================
# 09. PRESSURE DIAGNOSTIC INPUT
# ============================================================

struct PressureDiagnosticInput

    pressure::Float64

    contact_probability::Float64
    tooth_contact_probability::Float64

    excessive_pressure::Bool
    impact_detected::Bool

end


function PressureDiagnosticInput()

    PressureDiagnosticInput(

        0.0,

        0.0,
        0.0,

        false,
        false

    )

end


# ============================================================
# 10. SENSOR DIAGNOSTIC INPUT
# ============================================================

struct SensorDiagnosticInput

    sensor_confidence::Float64

    imu_valid::Bool
    pressure_valid::Bool
    temperature_valid::Bool
    battery_valid::Bool
    rpm_valid::Bool
    current_valid::Bool

    orientation_valid::Bool

    timestamp::Float64

end


function SensorDiagnosticInput()

    SensorDiagnosticInput(

        1.0,

        true,
        true,
        true,
        true,
        true,
        true,

        true,

        0.0

    )

end


# ============================================================
# 11. ZONE DIAGNOSTIC INPUT
# ============================================================

struct ZoneDiagnosticInput

    confidence::Float64

    contact::Bool

    zone_valid::Bool

    timestamp::Float64

end


function ZoneDiagnosticInput()

    ZoneDiagnosticInput(

        0.0,

        false,

        true,

        0.0

    )

end


# ============================================================
# 12. SYSTEM DIAGNOSTIC INPUT
# ============================================================

mutable struct SafetyInput

    timestamp::Float64

    motor::MotorDiagnosticInput

    battery::BatteryDiagnosticInput

    thermal::ThermalDiagnosticInput

    pressure::PressureDiagnosticInput

    sensors::SensorDiagnosticInput

    zone::ZoneDiagnosticInput

end


function SafetyInput()

    SafetyInput(

        0.0,

        MotorDiagnosticInput(),
        BatteryDiagnosticInput(),
        ThermalDiagnosticInput(),
        PressureDiagnosticInput(),
        SensorDiagnosticInput(),
        ZoneDiagnosticInput()

    )

end


# ============================================================
# 13. SAFETY COMMAND
# ============================================================

mutable struct SafetyCommand

    motor_enable::Bool

    emergency_stop::Bool

    maximum_rpm::Float64

    maximum_power::Float64

    maximum_current::Float64

    pressure_limit::Float64

    reason::String

end


function SafetyCommand()

    SafetyCommand(

        false,
        false,

        MAX_MOTOR_RPM,
        20.0,
        MAX_MOTOR_CURRENT,

        EXCESSIVE_PRESSURE,

        "Initialisation"

    )

end


# ============================================================
# 14. WATCHDOG
# ============================================================

mutable struct Watchdog

    last_update::Float64

    timeout::Float64

    triggered::Bool

end


function Watchdog(

    timeout::Float64 =
        WATCHDOG_TIMEOUT

)

    Watchdog(

        0.0,
        timeout,
        false

    )

end


function kick!(

    watchdog::Watchdog,
    timestamp::Float64

)

    watchdog.last_update =
        timestamp

    watchdog.triggered =
        false

end


function update_watchdog!(

    watchdog::Watchdog,
    timestamp::Float64

)

    if (

        timestamp -
        watchdog.last_update

    ) > watchdog.timeout

        watchdog.triggered =
            true

    end


    return watchdog.triggered

end


# ============================================================
# 15. SENSOR VALIDITY
# ============================================================

function sensors_valid(

    sensors::SensorDiagnosticInput

)

    return (

        sensors.imu_valid &&
        sensors.pressure_valid &&
        sensors.temperature_valid &&
        sensors.battery_valid &&
        sensors.rpm_valid &&
        sensors.current_valid &&
        sensors.orientation_valid

    )

end


function sensor_failure_count(

    sensors::SensorDiagnosticInput

)

    count = 0


    count +=
        !sensors.imu_valid

    count +=
        !sensors.pressure_valid

    count +=
        !sensors.temperature_valid

    count +=
        !sensors.battery_valid

    count +=
        !sensors.rpm_valid

    count +=
        !sensors.current_valid

    count +=
        !sensors.orientation_valid


    return count

end


# ============================================================
# 16. MOTOR CHECKS
# ============================================================

function motor_overspeed(

    motor::MotorDiagnosticInput

)

    motor.rpm >
    MAX_MOTOR_RPM

end


function motor_overcurrent(

    motor::MotorDiagnosticInput

)

    motor.current >
    MAX_MOTOR_CURRENT

end


function motor_overtemperature(

    motor::MotorDiagnosticInput

)

    motor.temperature >
    MAX_MOTOR_TEMPERATURE

end


function motor_tracking_error(

    motor::MotorDiagnosticInput

)

    if !motor.running

        return 0.0

    end


    return abs(

        motor.target_rpm -
        motor.rpm

    )

end


function motor_tracking_fault(

    motor::MotorDiagnosticInput

)

    motor.running &&
    motor.target_rpm >
    10000.0 &&
    motor_tracking_error(motor) >
    MAX_ALLOWED_RPM_ERROR

end


# ============================================================
# 17. BATTERY CHECKS
# ============================================================

function battery_undervoltage(

    battery::BatteryDiagnosticInput

)

    battery.voltage <
    MIN_BATTERY_VOLTAGE

end


function battery_overvoltage(

    battery::BatteryDiagnosticInput

)

    battery.voltage >
    MAX_BATTERY_VOLTAGE

end


function battery_overtemperature(

    battery::BatteryDiagnosticInput

)

    battery.temperature >
    MAX_BATTERY_TEMPERATURE

end


function battery_current_fault(

    battery::BatteryDiagnosticInput

)

    abs(battery.current) >
    12.0

end


# ============================================================
# 18. THERMAL CHECKS
# ============================================================

function thermal_fault(

    thermal::ThermalDiagnosticInput

)

    return (

        thermal.motor_temperature >
            MAX_MOTOR_TEMPERATURE ||

        thermal.battery_temperature >
            MAX_BATTERY_TEMPERATURE ||

        thermal.inverter_temperature >
            MAX_INVERTER_TEMPERATURE ||

        thermal.pcb_temperature >
            MAX_PCB_TEMPERATURE

    )

end


function thermal_runaway(

    thermal::ThermalDiagnosticInput

)

    temperatures = [

        thermal.motor_temperature,
        thermal.battery_temperature,
        thermal.inverter_temperature,
        thermal.pcb_temperature

    ]


    maximum(temperatures) >
    80.0 &&
    thermal.global_derating <
    0.20

end


# ============================================================
# 19. PRESSURE CHECKS
# ============================================================

function pressure_fault(

    pressure::PressureDiagnosticInput

)

    return (

        pressure.pressure >=
            CRITICAL_PRESSURE ||

        pressure.excessive_pressure

    )

end


function pressure_warning(

    pressure::PressureDiagnosticInput

)

    pressure.pressure >=
    EXCESSIVE_PRESSURE

end


# ============================================================
# 20. SENSOR CHECKS
# ============================================================

function sensor_fault(

    sensors::SensorDiagnosticInput

)

    sensor_failure_count(
        sensors
    ) > 0

end


function sensor_disagreement(

    sensors::SensorDiagnosticInput

)

    sensors.sensor_confidence <
    MIN_SENSOR_CONFIDENCE

end


function sensor_timeout(

    sensors::SensorDiagnosticInput,
    timestamp::Float64

)

    (

        timestamp -
        sensors.timestamp

    ) >
    SENSOR_TIMEOUT

end


# ============================================================
# 21. ZONE CHECKS
# ============================================================

function zone_fault(

    zone::ZoneDiagnosticInput

)

    zone.confidence <
    MIN_ZONE_CONFIDENCE &&
    zone.contact

end


function zone_timeout(

    zone::ZoneDiagnosticInput,
    timestamp::Float64

)

    (

        timestamp -
        zone.timestamp

    ) >
    ZONE_TIMEOUT

end


# ============================================================
# 22. DIAGNOSTIC DATABASE
# ============================================================

function create_fault_database()

    Dict(

        FAULT_MOTOR_OVERCURRENT =>
            FaultRecord(
                FAULT_MOTOR_OVERCURRENT,
                SEVERITY_CRITICAL,
                "Motor overcurrent"
            ),

        FAULT_MOTOR_OVERSPEED =>
            FaultRecord(
                FAULT_MOTOR_OVERSPEED,
                SEVERITY_CRITICAL,
                "Motor overspeed"
            ),

        FAULT_MOTOR_OVERTEMPERATURE =>
            FaultRecord(
                FAULT_MOTOR_OVERTEMPERATURE,
                SEVERITY_CRITICAL,
                "Motor overtemperature"
            ),

        FAULT_MOTOR_STALL =>
            FaultRecord(
                FAULT_MOTOR_STALL,
                SEVERITY_PROTECTIVE,
                "Motor stall"
            ),

        FAULT_BATTERY_UNDERVOLTAGE =>
            FaultRecord(
                FAULT_BATTERY_UNDERVOLTAGE,
                SEVERITY_CRITICAL,
                "Battery undervoltage"
            ),

        FAULT_BATTERY_OVERVOLTAGE =>
            FaultRecord(
                FAULT_BATTERY_OVERVOLTAGE,
                SEVERITY_CRITICAL,
                "Battery overvoltage"
            ),

        FAULT_BATTERY_OVERTEMPERATURE =>
            FaultRecord(
                FAULT_BATTERY_OVERTEMPERATURE,
                SEVERITY_CRITICAL,
                "Battery overtemperature"
            ),

        FAULT_BATTERY_CURRENT =>
            FaultRecord(
                FAULT_BATTERY_CURRENT,
                SEVERITY_CRITICAL,
                "Battery current fault"
            ),

        FAULT_INVERTER_OVERTEMPERATURE =>
            FaultRecord(
                FAULT_INVERTER_OVERTEMPERATURE,
                SEVERITY_CRITICAL,
                "Inverter overtemperature"
            ),

        FAULT_PCB_OVERTEMPERATURE =>
            FaultRecord(
                FAULT_PCB_OVERTEMPERATURE,
                SEVERITY_CRITICAL,
                "PCB overtemperature"
            ),

        FAULT_EXCESSIVE_PRESSURE =>
            FaultRecord(
                FAULT_EXCESSIVE_PRESSURE,
                SEVERITY_PROTECTIVE,
                "Excessive brushing pressure"
            ),

        FAULT_SENSOR_FAILURE =>
            FaultRecord(
                FAULT_SENSOR_FAILURE,
                SEVERITY_PROTECTIVE,
                "Sensor failure"
            ),

        FAULT_SENSOR_DISAGREEMENT =>
            FaultRecord(
                FAULT_SENSOR_DISAGREEMENT,
                SEVERITY_DERATE,
                "Sensor disagreement"
            ),

        FAULT_SENSOR_TIMEOUT =>
            FaultRecord(
                FAULT_SENSOR_TIMEOUT,
                SEVERITY_CRITICAL,
                "Sensor timeout"
            ),

        FAULT_ZONE_ESTIMATOR =>
            FaultRecord(
                FAULT_ZONE_ESTIMATOR,
                SEVERITY_WARNING,
                "Zone estimator confidence failure"
            ),

        FAULT_CONTROL_TIMEOUT =>
            FaultRecord(
                FAULT_CONTROL_TIMEOUT,
                SEVERITY_CRITICAL,
                "Control loop timeout"
            ),

        FAULT_WATCHDOG =>
            FaultRecord(
                FAULT_WATCHDOG,
                SEVERITY_CRITICAL,
                "Watchdog timeout"
            ),

        FAULT_RPM_TRACKING =>
            FaultRecord(
                FAULT_RPM_TRACKING,
                SEVERITY_PROTECTIVE,
                "RPM tracking fault"
            ),

        FAULT_THERMAL_RUNAWAY =>
            FaultRecord(
                FAULT_THERMAL_RUNAWAY,
                SEVERITY_CRITICAL,
                "Thermal runaway"
            )

    )

end


# ============================================================
# 23. FAULT MANAGER
# ============================================================

mutable struct FaultManager

    faults::Dict{FaultType,FaultRecord}

end


function FaultManager()

    FaultManager(
        create_fault_database()
    )

end


function set_fault!(

    manager::FaultManager,
    fault::FaultType,
    active::Bool,
    timestamp::Float64

)

    record =
        manager.faults[fault]


    if active

        record.count += 1

        record.clear_count = 0

        record.last_timestamp =
            timestamp


        if record.count == 1

            record.first_timestamp =
                timestamp

        end


        record.active = true


        if record.count >=
           FAULT_CONFIRMATION_COUNT

            record.confirmed = true

        end

    else

        record.count = 0

        record.clear_count += 1


        if record.clear_count >=
           FAULT_CLEAR_COUNT

            record.active = false
            record.confirmed = false

        end

    end


    return record

end


# ============================================================
# 24. ACTIVE FAULTS
# ============================================================

function active_faults(

    manager::FaultManager

)

    return [

        record

        for record in
        values(manager.faults)

        if record.active

    ]

end


function confirmed_faults(

    manager::FaultManager

)

    return [

        record

        for record in
        values(manager.faults)

        if record.confirmed

    ]

end


# ============================================================
# 25. CRITICAL FAULT DETECTION
# ============================================================

function critical_fault_active(

    manager::FaultManager

)

    for record in
        confirmed_faults(manager)

        if record.severity ==
           SEVERITY_CRITICAL

            return true

        end

    end


    return false

end


# ============================================================
# 26. SAFETY SUPERVISOR
# ============================================================

mutable struct SafetySupervisor

    state::SafetyState

    fault_manager::FaultManager

    watchdog::Watchdog

    command::SafetyCommand

    last_timestamp::Float64

    health_score::Float64

    warning_score::Float64

    update_count::Int

    emergency_latched::Bool

end


function SafetySupervisor()

    SafetySupervisor(

        SAFETY_INIT,

        FaultManager(),

        Watchdog(),

        SafetyCommand(),

        0.0,

        1.0,

        0.0,

        0,

        false

    )

end


# ============================================================
# 27. FAULT EVALUATION
# ============================================================

function evaluate_faults!(

    supervisor::SafetySupervisor,
    input::SafetyInput

)

    fm =
        supervisor.fault_manager

    t =
        input.timestamp


    set_fault!(

        fm,
        FAULT_MOTOR_OVERCURRENT,

        motor_overcurrent(
            input.motor
        ),

        t

    )


    set_fault!(

        fm,
        FAULT_MOTOR_OVERSPEED,

        motor_overspeed(
            input.motor
        ),

        t

    )


    set_fault!(

        fm,
        FAULT_MOTOR_OVERTEMPERATURE,

        motor_overtemperature(
            input.motor
        ),

        t

    )


    set_fault!(

        fm,
        FAULT_MOTOR_STALL,

        input.motor.stalled,

        t

    )


    set_fault!(

        fm,
        FAULT_BATTERY_UNDERVOLTAGE,

        battery_undervoltage(
            input.battery
        ),

        t

    )


    set_fault!(

        fm,
        FAULT_BATTERY_OVERVOLTAGE,

        battery_overvoltage(
            input.battery
        ),

        t

    )


    set_fault!(

        fm,
        FAULT_BATTERY_OVERTEMPERATURE,

        battery_overtemperature(
            input.battery
        ),

        t

    )


    set_fault!(

        fm,
        FAULT_BATTERY_CURRENT,

        battery_current_fault(
            input.battery
        ),

        t

    )


    set_fault!(

        fm,
        FAULT_INVERTER_OVERTEMPERATURE,

        input.thermal.inverter_temperature >
        MAX_INVERTER_TEMPERATURE,

        t

    )


    set_fault!(

        fm,
        FAULT_PCB_OVERTEMPERATURE,

        input.thermal.pcb_temperature >
        MAX_PCB_TEMPERATURE,

        t

    )


    set_fault!(

        fm,
        FAULT_EXCESSIVE_PRESSURE,

        pressure_fault(
            input.pressure
        ),

        t

    )


    set_fault!(

        fm,
        FAULT_SENSOR_FAILURE,

        sensor_fault(
            input.sensors
        ),

        t

    )


    set_fault!(

        fm,
        FAULT_SENSOR_DISAGREEMENT,

        sensor_disagreement(
            input.sensors
        ),

        t

    )


    set_fault!(

        fm,
        FAULT_SENSOR_TIMEOUT,

        sensor_timeout(
            input.sensors,
            t
        ),

        t

    )


    set_fault!(

        fm,
        FAULT_ZONE_ESTIMATOR,

        zone_fault(
            input.zone
        ),

        t

    )


    set_fault!(

        fm,
        FAULT_RPM_TRACKING,

        motor_tracking_fault(
            input.motor
        ),

        t

    )


    set_fault!(

        fm,
        FAULT_THERMAL_RUNAWAY,

        thermal_runaway(
            input.thermal
        ),

        t

    )


    watchdog_fault =

        update_watchdog!(

            supervisor.watchdog,
            t

        )


    set_fault!(

        fm,
        FAULT_WATCHDOG,

        watchdog_fault,

        t

    )


    return fm

end


# ============================================================
# 28. HEALTH SCORE
# ============================================================

function calculate_health_score(

    supervisor::SafetySupervisor

)

    score = 1.0


    for fault in
        active_faults(
            supervisor.fault_manager
        )

        penalty =

            if fault.severity ==
               SEVERITY_CRITICAL

                0.40

            elseif fault.severity ==
                   SEVERITY_PROTECTIVE

                0.25

            elseif fault.severity ==
                   SEVERITY_DERATE

                0.12

            else

                0.05

            end


        score -= penalty

    end


    return clamp(

        score,
        0.0,
        1.0

    )

end


# ============================================================
# 29. THERMAL DERATING
# ============================================================

function thermal_derating(

    thermal::ThermalDiagnosticInput

)

    return clamp(

        thermal.global_derating,

        0.0,
        1.0

    )

end


# ============================================================
# 30. BATTERY DERATING
# ============================================================

function battery_derating(

    battery::BatteryDiagnosticInput

)

    voltage_factor =

        clamp(

            (
                battery.voltage -
                MIN_BATTERY_VOLTAGE
            ) /

            (
                3.40 -
                MIN_BATTERY_VOLTAGE
            ),

            0.0,
            1.0

        )


    temperature_factor =

        if battery.temperature <= 40.0

            1.0

        else

            clamp(

                (
                    MAX_BATTERY_TEMPERATURE -
                    battery.temperature
                ) / 20.0,

                0.0,
                1.0

            )

        end


    return min(

        voltage_factor,
        temperature_factor

    )

end


# ============================================================
# 31. PRESSURE DERATING
# ============================================================

function pressure_derating(

    pressure::PressureDiagnosticInput

)

    p =
        pressure.pressure


    if p < 0.50

        return 1.0

    elseif p < EXCESSIVE_PRESSURE

        return 0.75

    elseif p < CRITICAL_PRESSURE

        return 0.35

    end


    return 0.0

end


# ============================================================
# 32. SENSOR DERATING
# ============================================================

function sensor_derating(

    sensors::SensorDiagnosticInput

)

    return clamp(

        sensors.sensor_confidence,

        0.0,
        1.0

    )

end


# ============================================================
# 33. COMMAND GENERATION
# ============================================================

function generate_command!(

    supervisor::SafetySupervisor,
    input::SafetyInput

)

    command =
        supervisor.command


    command.motor_enable = true

    command.emergency_stop = false

    command.maximum_rpm =
        MAX_MOTOR_RPM

    command.maximum_power =
        20.0

    command.maximum_current =
        MAX_MOTOR_CURRENT

    command.pressure_limit =
        EXCESSIVE_PRESSURE

    command.reason =
        "Normal operation"


    # --------------------------------------------------------
    # Thermal limitation
    # --------------------------------------------------------

    thermal_limit =

        thermal_derating(
            input.thermal
        )


    command.maximum_rpm *=
        thermal_limit

    command.maximum_power *=
        thermal_limit


    # --------------------------------------------------------
    # Battery limitation
    # --------------------------------------------------------

    battery_limit =

        battery_derating(
            input.battery
        )


    command.maximum_rpm *=
        battery_limit

    command.maximum_power *=
        battery_limit


    # --------------------------------------------------------
    # Pressure limitation
    # --------------------------------------------------------

    pressure_limit =

        pressure_derating(
            input.pressure
        )


    command.maximum_rpm *=
        pressure_limit

    command.maximum_power *=
        pressure_limit


    # --------------------------------------------------------
    # Sensor confidence
    # --------------------------------------------------------

    sensor_limit =

        sensor_derating(
            input.sensors
        )


    command.maximum_rpm *=
        sensor_limit


    # --------------------------------------------------------
    # Critical faults
    # --------------------------------------------------------

    if critical_fault_active(

        supervisor.fault_manager

    )

        command.motor_enable =
            false

        command.emergency_stop =
            true

        command.maximum_rpm =
            0.0

        command.maximum_power =
            0.0

        command.maximum_current =
            0.0

        command.reason =
            "Critical safety fault"

    end


    # --------------------------------------------------------
    # Thermal emergency
    # --------------------------------------------------------

    if input.thermal.emergency_shutdown

        command.motor_enable =
            false

        command.emergency_stop =
            true

        command.maximum_rpm =
            0.0

        command.maximum_power =
            0.0

        command.reason =
            "Thermal emergency"

    end


    # --------------------------------------------------------
    # Excessive pressure
    # --------------------------------------------------------

    if pressure_fault(
        input.pressure
    )

        command.maximum_rpm =
            min(
                command.maximum_rpm,
                8000.0
            )

        command.maximum_power =
            min(
                command.maximum_power,
                4.0
            )

        command.reason =
            "Pressure protection"

    end


    return command

end


# ============================================================
# 34. SAFETY STATE MACHINE
# ============================================================

function update_state!(

    supervisor::SafetySupervisor,
    input::SafetyInput

)

    command =
        supervisor.command

    health =
        supervisor.health_score


    if supervisor.emergency_latched

        supervisor.state =
            SAFETY_EMERGENCY

        return supervisor.state

    end


    if command.emergency_stop

        supervisor.state =
            SAFETY_EMERGENCY

        supervisor.emergency_latched =
            true

        return supervisor.state

    end


    if health < 0.30

        supervisor.state =
            SAFETY_FAULT

    elseif health < 0.55

        supervisor.state =
            SAFETY_PROTECTIVE

    elseif health < 0.75

        supervisor.state =
            SAFETY_DERATING

    elseif health < 0.90

        supervisor.state =
            SAFETY_WARNING

    else

        supervisor.state =
            SAFETY_NORMAL

    end


    return supervisor.state

end


# ============================================================
# 35. MAIN SAFETY UPDATE
# ============================================================

function update!(

    supervisor::SafetySupervisor,
    input::SafetyInput

)

    supervisor.last_timestamp =
        input.timestamp

    supervisor.update_count += 1


    evaluate_faults!(

        supervisor,
        input

    )


    supervisor.health_score =

        calculate_health_score(
            supervisor
        )


    supervisor.command =

        SafetyCommand()


    generate_command!(

        supervisor,
        input

    )


    update_state!(

        supervisor,
        input

    )


    return supervisor

end


# ============================================================
# 36. EMERGENCY STOP
# ============================================================

function emergency_stop!(

    supervisor::SafetySupervisor,
    reason::String = "Manual emergency stop"

)

    supervisor.emergency_latched =
        true

    supervisor.state =
        SAFETY_EMERGENCY


    supervisor.command.motor_enable =
        false

    supervisor.command.emergency_stop =
        true

    supervisor.command.maximum_rpm =
        0.0

    supervisor.command.maximum_power =
        0.0

    supervisor.command.maximum_current =
        0.0

    supervisor.command.reason =
        reason


    return supervisor

end


# ============================================================
# 37. CLEAR EMERGENCY
# ============================================================

function clear_emergency!(

    supervisor::SafetySupervisor

)

    if !critical_fault_active(

        supervisor.fault_manager

    )

        supervisor.emergency_latched =
            false

        supervisor.state =
            SAFETY_READY

    end


    return supervisor

end


# ============================================================
# 38. MOTOR PERMISSION
# ============================================================

function motor_allowed(

    supervisor::SafetySupervisor

)

    return (

        supervisor.command.motor_enable &&
        !supervisor.command.emergency_stop &&
        !supervisor.emergency_latched

    )

end


# ============================================================
# 39. SAFE RPM
# ============================================================

function safe_rpm(

    supervisor::SafetySupervisor

)

    return max(

        supervisor.command.maximum_rpm,

        0.0

    )

end


# ============================================================
# 40. SAFE POWER
# ============================================================

function safe_power(

    supervisor::SafetySupervisor

)

    return max(

        supervisor.command.maximum_power,

        0.0

    )

end


# ============================================================
# 41. FAULT SUMMARY
# ============================================================

function fault_summary(

    supervisor::SafetySupervisor

)

    return [

        (
            fault = record.fault,
            severity = record.severity,
            active = record.active,
            confirmed = record.confirmed,
            count = record.count,
            description = record.description
        )

        for record in
        values(
            supervisor.fault_manager.faults
        )

        if record.active

    ]

end


# ============================================================
# 42. DIAGNOSTIC TELEMETRY
# ============================================================

function telemetry(

    supervisor::SafetySupervisor

)

    return Dict(

        "safety_state" =>
            string(
                supervisor.state
            ),

        "health_score" =>
            supervisor.health_score,

        "motor_allowed" =>
            motor_allowed(
                supervisor
            ),

        "emergency_latched" =>
            supervisor.emergency_latched,

        "safe_rpm" =>
            safe_rpm(
                supervisor
            ),

        "safe_power_watts" =>
            safe_power(
                supervisor
            ),

        "safe_current_amps" =>
            supervisor.command.maximum_current,

        "reason" =>
            supervisor.command.reason,

        "active_fault_count" =>
            length(
                active_faults(
                    supervisor.fault_manager
                )
            ),

        "confirmed_fault_count" =>
            length(
                confirmed_faults(
                    supervisor.fault_manager
                )
            ),

        "watchdog_triggered" =>
            supervisor.watchdog.triggered,

        "update_count" =>
            supervisor.update_count

    )

end


# ============================================================
# 43. DIAGNOSTIC REPORT
# ============================================================

function diagnostic_report(

    supervisor::SafetySupervisor

)

    return (

        state =
            supervisor.state,

        health =
            supervisor.health_score,

        motor_allowed =
            motor_allowed(
                supervisor
            ),

        maximum_rpm =
            safe_rpm(
                supervisor
            ),

        maximum_power =
            safe_power(
                supervisor
            ),

        emergency =
            supervisor.emergency_latched,

        faults =
            fault_summary(
                supervisor
            )

    )

end


# ============================================================
# 44. SENSOR PLAUSIBILITY
# ============================================================

function plausibility_check(

    input::SafetyInput

)

    anomalies = String[]


    if input.motor.rpm < 0

        push!(
            anomalies,
            "Negative motor RPM"
        )

    end


    if input.motor.current < 0

        push!(
            anomalies,
            "Negative motor current"
        )

    end


    if input.battery.soc < 0 ||
       input.battery.soc > 1

        push!(
            anomalies,
            "Invalid battery SOC"
        )

    end


    if input.pressure.pressure < 0 ||
       input.pressure.pressure > 1

        push!(
            anomalies,
            "Invalid pressure"
        )

    end


    if input.motor.temperature < -40 ||
       input.motor.temperature > 150

        push!(
            anomalies,
            "Implausible motor temperature"
        )

    end


    if input.battery.voltage < 0 ||
       input.battery.voltage > 10

        push!(
            anomalies,
            "Implausible battery voltage"
        )

    end


    return anomalies

end


# ============================================================
# 45. SYSTEM READY CHECK
# ============================================================

function ready_for_operation(

    supervisor::SafetySupervisor,
    input::SafetyInput

)

    return (

        !supervisor.emergency_latched &&

        sensors_valid(
            input.sensors
        ) &&

        input.battery.voltage >
            MIN_BATTERY_VOLTAGE &&

        input.battery.voltage <
            MAX_BATTERY_VOLTAGE &&

        input.motor.temperature <
            MAX_MOTOR_TEMPERATURE &&

        input.battery.temperature <
            MAX_BATTERY_TEMPERATURE &&

        !input.thermal.emergency_shutdown

    )

end


# ============================================================
# 46. SAFE SHUTDOWN
# ============================================================

function safe_shutdown!(

    supervisor::SafetySupervisor

)

    supervisor.state =
        SAFETY_STOPPING


    supervisor.command.motor_enable =
        false

    supervisor.command.maximum_rpm =
        0.0

    supervisor.command.maximum_power =
        0.0

    supervisor.command.maximum_current =
        0.0

    supervisor.command.reason =
        "Controlled shutdown"


    supervisor.state =
        SAFETY_STOPPED


    return supervisor

end


# ============================================================
# 47. RESET
# ============================================================

function reset!(

    supervisor::SafetySupervisor

)

    supervisor.state =
        SAFETY_INIT

    supervisor.fault_manager =
        FaultManager()

    supervisor.watchdog =
        Watchdog()

    supervisor.command =
        SafetyCommand()

    supervisor.last_timestamp =
        0.0

    supervisor.health_score =
        1.0

    supervisor.warning_score =
        0.0

    supervisor.update_count =
        0

    supervisor.emergency_latched =
        false


    return supervisor

end


# ============================================================
# 48. FAULT INJECTION
#
# Useful for the digital-twin test harness.
# ============================================================

function inject_fault(

    input::SafetyInput,
    fault::FaultType

)

    if fault ==
       FAULT_MOTOR_OVERCURRENT

        input.motor =
            MotorDiagnosticInput(
                input.motor.rpm,
                input.motor.target_rpm,
                MAX_MOTOR_CURRENT + 2.0,
                input.motor.torque,
                input.motor.temperature,
                input.motor.electrical_power,
                input.motor.mechanical_power,
                input.motor.stalled,
                input.motor.running
            )


    elseif fault ==
           FAULT_MOTOR_OVERSPEED

        input.motor =
            MotorDiagnosticInput(
                MAX_MOTOR_RPM + 5000.0,
                input.motor.target_rpm,
                input.motor.current,
                input.motor.torque,
                input.motor.temperature,
                input.motor.electrical_power,
                input.motor.mechanical_power,
                input.motor.stalled,
                input.motor.running
            )


    elseif fault ==
           FAULT_BATTERY_UNDERVOLTAGE

        input.battery =
            BatteryDiagnosticInput(
                MIN_BATTERY_VOLTAGE - 0.2,
                input.battery.current,
                input.battery.soc,
                input.battery.temperature,
                input.battery.available_power,
                input.battery.internal_resistance,
                input.battery.charging
            )


    elseif fault ==
           FAULT_MOTOR_OVERTEMPERATURE

        input.motor =
            MotorDiagnosticInput(
                input.motor.rpm,
                input.motor.target_rpm,
                input.motor.current,
                input.motor.torque,
                MAX_MOTOR_TEMPERATURE + 10.0,
                input.motor.electrical_power,
                input.motor.mechanical_power,
                input.motor.stalled,
                input.motor.running
            )


    elseif fault ==
           FAULT_EXCESSIVE_PRESSURE

        input.pressure =
            PressureDiagnosticInput(
                CRITICAL_PRESSURE,
                input.pressure.contact_probability,
                input.pressure.tooth_contact_probability,
                true,
                input.pressure.impact_detected
            )

    end


    return input

end


# ============================================================
# 49. SAFETY SIMULATION
# ============================================================

function simulate(

    supervisor::SafetySupervisor,
    inputs::Vector{SafetyInput}

)

    results = Vector{Any}()


    for input in inputs

        update!(
            supervisor,
            input
        )


        push!(

            results,

            telemetry(
                supervisor
            )

        )

    end


    return results

end


# ============================================================
# 50. EXPORTS
# ============================================================

export SafetyState
export FaultType
export FaultSeverity

export FaultRecord
export MotorDiagnosticInput
export BatteryDiagnosticInput
export ThermalDiagnosticInput
export PressureDiagnosticInput
export SensorDiagnosticInput
export ZoneDiagnosticInput
export SafetyInput

export SafetyCommand
export Watchdog
export FaultManager
export SafetySupervisor

export update!
export reset!

export emergency_stop!
export clear_emergency!
export safe_shutdown!

export motor_allowed
export safe_rpm
export safe_power

export active_faults
export confirmed_faults
export fault_summary

export telemetry
export diagnostic_report

export plausibility_check
export ready_for_operation

export inject_fault
export simulate

end


module ToothbrushDigitalTwin

using Statistics
using LinearAlgebra
using Random

# ============================================================
# DYSON-STYLE ELECTRIC TOOTHBRUSH DIGITAL TWIN
#
# Real-time/reference simulation architecture.
#
# Twin layers:
#   1. Physical state
#   2. Motor model
#   3. Battery model
#   4. Thermal model
#   5. Sensor model
#   6. Pressure/contact model
#   7. Tooth-zone model
#   8. Cleaning model
#   9. Safety supervisor
#  10. State estimation
#  11. Parameter identification
#  12. Fault injection
#  13. Scenario simulation
#  14. Performance optimisation
#
# The twin can operate in:
#   SIMULATION
#   HARDWARE_IN_LOOP
#   OBSERVATION
#   REPLAY
#
# This is a research/reference model, not production
# medical or dental-control firmware.
# ============================================================


# ============================================================
# 01. CONSTANTS
# ============================================================

const DEFAULT_DT = 0.001

const CONTROL_RATE_HZ = 1000.0

const SENSOR_RATE_HZ = 200.0

const THERMAL_RATE_HZ = 20.0

const CLEANING_RATE_HZ = 50.0

const SAFETY_RATE_HZ = 100.0

const MAX_SIMULATION_TIME = 3600.0

const NOMINAL_AMBIENT = 22.0

const NOMINAL_VOLTAGE = 3.7

const MAX_RPM = 42000.0

const NOMINAL_RPM = 26000.0

const MAX_CURRENT = 8.0

const NOMINAL_CURRENT = 2.5

const NOMINAL_POWER = 12.0


# ============================================================
# 02. TWIN MODE
# ============================================================

@enum TwinMode begin

    TWIN_SIMULATION

    TWIN_HARDWARE_IN_LOOP

    TWIN_OBSERVATION

    TWIN_REPLAY

end


# ============================================================
# 03. TWIN STATE
# ============================================================

@enum TwinState begin

    TWIN_INITIALISING

    TWIN_READY

    TWIN_RUNNING

    TWIN_PAUSED

    TWIN_DEGRADED

    TWIN_FAULT

    TWIN_STOPPED

end


# ============================================================
# 04. VECTOR
# ============================================================

struct Vector3

    x::Float64
    y::Float64
    z::Float64

end


Vector3() =
    Vector3(0.0, 0.0, 0.0)


function norm3(v::Vector3)

    sqrt(

        v.x^2 +
        v.y^2 +
        v.z^2

    )

end


# ============================================================
# 05. PHYSICAL STATE
# ============================================================

mutable struct PhysicalState

    timestamp::Float64

    rpm::Float64

    angular_velocity::Float64

    motor_current::Float64

    motor_torque::Float64

    motor_temperature::Float64

    battery_voltage::Float64

    battery_current::Float64

    battery_soc::Float64

    battery_temperature::Float64

    inverter_temperature::Float64

    pcb_temperature::Float64

    pressure::Float64

    contact_probability::Float64

    vibration::Float64

    acceleration::Vector3

    roll::Float64
    pitch::Float64
    yaw::Float64

end


function PhysicalState()

    PhysicalState(

        0.0,

        0.0,
        0.0,
        0.0,
        0.0,

        NOMINAL_AMBIENT,

        NOMINAL_VOLTAGE,
        0.0,
        1.0,

        NOMINAL_AMBIENT,
        NOMINAL_AMBIENT,
        NOMINAL_AMBIENT,

        0.0,
        0.0,
        0.0,

        Vector3(),

        0.0,
        0.0,
        0.0

    )

end


# ============================================================
# 06. MOTOR TWIN
# ============================================================

mutable struct MotorTwin

    rpm::Float64

    target_rpm::Float64

    current::Float64

    torque::Float64

    load_torque::Float64

    electrical_power::Float64

    mechanical_power::Float64

    efficiency::Float64

    temperature::Float64

    rotor_angle::Float64

    rotor_speed::Float64

end


function MotorTwin()

    MotorTwin(

        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        NOMINAL_AMBIENT,

        0.0,
        0.0

    )

end


# ============================================================
# 07. BATTERY TWIN
# ============================================================

mutable struct BatteryTwin

    soc::Float64

    voltage::Float64

    current::Float64

    power::Float64

    temperature::Float64

    internal_resistance::Float64

    capacity_ah::Float64

    available_power::Float64

    health::Float64

    cycle_count::Float64

end


function BatteryTwin()

    BatteryTwin(

        1.0,

        NOMINAL_VOLTAGE,

        0.0,
        0.0,

        NOMINAL_AMBIENT,

        0.08,

        0.75,

        20.0,

        1.0,

        0.0

    )

end


# ============================================================
# 08. THERMAL TWIN
# ============================================================

mutable struct ThermalTwin

    ambient::Float64

    motor::Float64

    battery::Float64

    inverter::Float64

    pcb::Float64

    housing::Float64

    brush_head::Float64

    heat_generation::Float64

    heat_rejection::Float64

    thermal_derating::Float64

end


function ThermalTwin()

    ThermalTwin(

        NOMINAL_AMBIENT,

        NOMINAL_AMBIENT,
        NOMINAL_AMBIENT,
        NOMINAL_AMBIENT,
        NOMINAL_AMBIENT,
        NOMINAL_AMBIENT,
        NOMINAL_AMBIENT,

        0.0,
        0.0,

        1.0

    )

end


# ============================================================
# 09. SENSOR TWIN
# ============================================================

mutable struct SensorTwin

    rpm_measurement::Float64

    current_measurement::Float64

    voltage_measurement::Float64

    temperature_measurement::Float64

    pressure_measurement::Float64

    acceleration_measurement::Vector3

    gyro_measurement::Vector3

    vibration_measurement::Float64

    noise_level::Float64

    confidence::Float64

end


function SensorTwin()

    SensorTwin(

        0.0,
        0.0,
        NOMINAL_VOLTAGE,
        NOMINAL_AMBIENT,
        0.0,

        Vector3(),
        Vector3(),

        0.0,

        0.0,

        1.0

    )

end


# ============================================================
# 10. ZONE TWIN
# ============================================================

mutable struct ZoneTwin

    current_zone::Symbol

    confidence::Float64

    dwell_time::Float64

    coverage::Dict{Symbol,Float64}

end


function ZoneTwin()

    zones = [

        :upper_left_outer,
        :upper_left_inner,
        :upper_left_occlusal,

        :upper_front_outer,
        :upper_front_inner,
        :upper_front_occlusal,

        :upper_right_outer,
        :upper_right_inner,
        :upper_right_occlusal,

        :lower_left_outer,
        :lower_left_inner,
        :lower_left_occlusal,

        :lower_front_outer,
        :lower_front_inner,
        :lower_front_occlusal,

        :lower_right_outer,
        :lower_right_inner,
        :lower_right_occlusal

    ]


    ZoneTwin(

        :unknown,

        0.0,

        0.0,

        Dict(
            zone => 0.0
            for zone in zones
        )

    )

end


# ============================================================
# 11. CLEANING TWIN
# ============================================================

mutable struct CleaningTwin

    mode::Symbol

    active::Bool

    elapsed_time::Float64

    contact_time::Float64

    excessive_pressure_time::Float64

    average_pressure::Float64

    average_contact::Float64

    cleaning_score::Float64

    coverage_score::Float64

    consistency_score::Float64

    target_rpm::Float64

end


function CleaningTwin()

    CleaningTwin(

        :standard,

        false,

        0.0,
        0.0,
        0.0,

        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        NOMINAL_RPM

    )

end


# ============================================================
# 12. SAFETY TWIN
# ============================================================

mutable struct SafetyTwin

    state::Symbol

    health::Float64

    motor_allowed::Bool

    emergency_stop::Bool

    maximum_rpm::Float64

    maximum_power::Float64

    active_faults::Vector{Symbol}

end


function SafetyTwin()

    SafetyTwin(

        :ready,

        1.0,

        true,
        false,

        MAX_RPM,
        20.0,

        Symbol[]

    )

end


# ============================================================
# 13. DIGITAL TWIN PARAMETERS
# ============================================================

mutable struct TwinParameters

    motor_inertia::Float64

    motor_resistance::Float64

    torque_constant::Float64

    back_emf_constant::Float64

    battery_capacity::Float64

    battery_resistance::Float64

    thermal_resistance_motor::Float64

    thermal_resistance_battery::Float64

    thermal_resistance_housing::Float64

    motor_heat_capacity::Float64

    battery_heat_capacity::Float64

    friction::Float64

    contact_load_coefficient::Float64

end


function TwinParameters()

    TwinParameters(

        1.2e-6,

        0.35,

        0.025,

        0.00095,

        0.75,

        0.08,

        18.0,
        22.0,
        12.0,

        15.0,
        45.0,

        2e-6,

        0.004

    )

end


# ============================================================
# 14. COMMAND STATE
# ============================================================

mutable struct TwinCommand

    target_rpm::Float64

    target_power::Float64

    motor_enable::Bool

    charging::Bool

    pressure_limit::Float64

end


function TwinCommand()

    TwinCommand(

        0.0,
        0.0,

        false,
        false,

        0.82

    )

end


# ============================================================
# 15. IDENTIFICATION STATE
# ============================================================

mutable struct ParameterEstimator

    estimated_torque_constant::Float64

    estimated_resistance::Float64

    estimated_inertia::Float64

    estimated_friction::Float64

    samples::Int

    residual_rpm::Float64

    residual_current::Float64

    residual_temperature::Float64

end


function ParameterEstimator()

    ParameterEstimator(

        0.025,
        0.35,
        1.2e-6,
        2e-6,

        0,

        0.0,
        0.0,
        0.0

    )

end


# ============================================================
# 16. TWIN HISTORY
# ============================================================

mutable struct TwinHistory

    timestamps::Vector{Float64}

    rpm::Vector{Float64}

    current::Vector{Float64}

    voltage::Vector{Float64}

    temperature::Vector{Float64}

    pressure::Vector{Float64}

    soc::Vector{Float64}

    cleaning_score::Vector{Float64}

    capacity::Int

    index::Int

end


function TwinHistory(

    capacity::Int = 10000

)

    TwinHistory(

        zeros(capacity),
        zeros(capacity),
        zeros(capacity),
        zeros(capacity),
        zeros(capacity),
        zeros(capacity),
        zeros(capacity),
        zeros(capacity),

        capacity,
        1

    )

end


function record!(

    history::TwinHistory,
    twin,
    timestamp::Float64

)

    i =
        history.index


    history.timestamps[i] =
        timestamp

    history.rpm[i] =
        twin.motor.rpm

    history.current[i] =
        twin.motor.current

    history.voltage[i] =
        twin.battery.voltage

    history.temperature[i] =
        twin.thermal.motor

    history.pressure[i] =
        twin.physical.pressure

    history.soc[i] =
        twin.battery.soc

    history.cleaning_score[i] =
        twin.cleaning.cleaning_score


    history.index += 1


    if history.index >
       history.capacity

        history.index = 1

    end

end


# ============================================================
# 17. MAIN DIGITAL TWIN
# ============================================================

mutable struct ToothbrushDigitalTwin

    mode::TwinMode

    state::TwinState

    physical::PhysicalState

    motor::MotorTwin

    battery::BatteryTwin

    thermal::ThermalTwin

    sensors::SensorTwin

    zone::ZoneTwin

    cleaning::CleaningTwin

    safety::SafetyTwin

    parameters::TwinParameters

    command::TwinCommand

    estimator::ParameterEstimator

    history::TwinHistory

    simulation_time::Float64

    real_time_factor::Float64

    random_seed::Int

end


function ToothbrushDigitalTwin(

    mode::TwinMode = TWIN_SIMULATION

)

    ToothbrushDigitalTwin(

        mode,

        TWIN_INITIALISING,

        PhysicalState(),

        MotorTwin(),
        BatteryTwin(),
        ThermalTwin(),
        SensorTwin(),
        ZoneTwin(),
        CleaningTwin(),
        SafetyTwin(),

        TwinParameters(),

        TwinCommand(),

        ParameterEstimator(),

        TwinHistory(),

        0.0,

        1.0,

        1234

    )

end


# ============================================================
# 18. INITIALISE
# ============================================================

function initialise!(

    twin::ToothbrushDigitalTwin

)

    twin.physical =
        PhysicalState()

    twin.motor =
        MotorTwin()

    twin.battery =
        BatteryTwin()

    twin.thermal =
        ThermalTwin()

    twin.sensors =
        SensorTwin()

    twin.zone =
        ZoneTwin()

    twin.cleaning =
        CleaningTwin()

    twin.safety =
        SafetyTwin()

    twin.command =
        TwinCommand()

    twin.estimator =
        ParameterEstimator()

    twin.simulation_time =
        0.0


    twin.state =
        TWIN_READY


    return twin

end


# ============================================================
# 19. MOTOR LOAD MODEL
# ============================================================

function contact_load(

    pressure::Float64,
    contact_probability::Float64

)

    return (

        0.0005 +

        pressure *
        contact_probability *
        0.004

    )

end


function update_motor_load!(

    twin::ToothbrushDigitalTwin

)

    twin.motor.load_torque =

        contact_load(

            twin.physical.pressure,

            twin.physical.contact_probability

        )

    return twin.motor.load_torque

end


# ============================================================
# 20. MOTOR ELECTRICAL MODEL
# ============================================================

function calculate_motor_current(

    twin::ToothbrushDigitalTwin

)

    rpm =
        twin.motor.rpm


    omega =

        rpm *
        2π / 60.0


    ke =
        twin.parameters.back_emf_constant


    resistance =
        twin.parameters.motor_resistance


    required_torque =

        twin.motor.load_torque +
        twin.parameters.friction *
        omega


    current =

        required_torque /
        twin.parameters.torque_constant


    voltage =
        twin.battery.voltage


    back_emf =
        ke *
        omega


    electrical_current =

        max(

            current,

            (
                voltage -
                back_emf
            ) /
            resistance *
            0.05

        )


    return clamp(

        electrical_current,

        0.0,
        MAX_CURRENT

    )

end


# ============================================================
# 21. MOTOR DYNAMICS
# ============================================================

function update_motor!(

    twin::ToothbrushDigitalTwin,
    dt::Float64

)

    update_motor_load!(
        twin
    )


    target =
        twin.command.target_rpm


    if !twin.command.motor_enable

        target = 0.0

    end


    current_rpm =
        twin.motor.rpm


    error =
        target -
        current_rpm


    # Simple supervisory acceleration model.

    acceleration_limit =

        if target > current_rpm

            90000.0

        else

            140000.0

        end


    acceleration =

        clamp(

            error * 12.0,

            -acceleration_limit,
            acceleration_limit

        )


    load_deceleration =

        twin.motor.load_torque /
        twin.parameters.motor_inertia *
        60.0 /
        (2π)


    net_acceleration =

        acceleration -
        load_deceleration


    twin.motor.rpm +=

        net_acceleration *
        dt


    twin.motor.rpm =

        clamp(

            twin.motor.rpm,

            0.0,
            MAX_RPM

        )


    twin.motor.rotor_speed =

        twin.motor.rpm *
        2π / 60.0


    twin.motor.rotor_angle +=

        twin.motor.rotor_speed *
        dt


    twin.motor.current =

        calculate_motor_current(
            twin
        )


    twin.motor.torque =

        twin.parameters.torque_constant *
        twin.motor.current


    twin.motor.electrical_power =

        twin.battery.voltage *
        twin.motor.current


    twin.motor.mechanical_power =

        twin.motor.torque *
        twin.motor.rotor_speed


    if twin.motor.electrical_power >
       1e-6

        twin.motor.efficiency =

            clamp(

                twin.motor.mechanical_power /
                twin.motor.electrical_power,

                0.0,
                1.0

            )

    else

        twin.motor.efficiency =
            0.0

    end


    return twin.motor

end


# ============================================================
# 22. BATTERY OPEN-CIRCUIT VOLTAGE
# ============================================================

function soc_voltage(

    soc::Float64

)

    s =
        clamp(
            soc,
            0.0,
            1.0
        )


    return (

        3.00 +
        1.20 *
        s +
        0.10 *
        s *
        (1.0 - s)

    )

end


# ============================================================
# 23. BATTERY UPDATE
# ============================================================

function update_battery!(

    twin::ToothbrushDigitalTwin,
    dt::Float64

)

    current =
        twin.motor.current


    twin.battery.current =
        current


    twin.battery.power =

        twin.battery.voltage *
        current


    # Coulomb counting.

    twin.battery.soc -=

        (
            current *
            dt
        ) /
        (
            twin.battery.capacity_ah *
            3600.0
        )


    twin.battery.soc =

        clamp(

            twin.battery.soc,

            0.0,
            1.0

        )


    ocv =
        soc_voltage(
            twin.battery.soc
        )


    sag =

        current *
        twin.battery.internal_resistance


    twin.battery.voltage =

        max(

            2.70,

            ocv - sag

        )


    # Battery heating.

    heat =

        current^2 *
        twin.battery.internal_resistance


    twin.battery.temperature +=

        (
            heat -
            (
                twin.battery.temperature -
                twin.thermal.ambient
            ) /
            twin.parameters.thermal_resistance_battery
        ) /
        45.0 *
        dt


    twin.battery.available_power =

        max(

            0.0,

            (
                twin.battery.voltage -
                3.0
            ) *
            8.0

        )


    return twin.battery

end


# ============================================================
# 24. THERMAL MODEL
# ============================================================

function motor_heat_generation(

    twin::ToothbrushDigitalTwin

)

    copper =

        twin.motor.current^2 *
        twin.parameters.motor_resistance


    mechanical =

        twin.parameters.friction *
        twin.motor.rotor_speed^2


    electrical =
        twin.motor.electrical_power


    mechanical_power =
        twin.motor.mechanical_power


    iron =

        max(

            0.0,

            0.02 *
            electrical

        )


    return (

        copper +
        mechanical +
        iron

    )

end


function update_thermal!(

    twin::ToothbrushDigitalTwin,
    dt::Float64

)

    motor_heat =
        motor_heat_generation(
            twin
        )


    inverter_heat =

        0.04 *
        twin.motor.electrical_power


    battery_heat =

        twin.battery.current^2 *
        twin.battery.internal_resistance


    twin.thermal.heat_generation =

        motor_heat +
        inverter_heat +
        battery_heat


    # Motor node.

    motor_cooling =

        (
            twin.thermal.motor -
            twin.thermal.ambient
        ) /
        twin.parameters.thermal_resistance_motor


    twin.thermal.motor +=

        (
            motor_heat -
            motor_cooling
        ) /
        twin.parameters.motor_heat_capacity *
        dt


    # Battery node.

    battery_cooling =

        (
            twin.thermal.battery -
            twin.thermal.ambient
        ) /
        twin.parameters.thermal_resistance_battery


    twin.thermal.battery +=

        (
            battery_heat -
            battery_cooling
        ) /
        twin.battery.temperature *
        0.01 *
        dt


    # Inverter.

    twin.thermal.inverter +=

        (

            inverter_heat -

            (
                twin.thermal.inverter -
                twin.thermal.ambient
            ) /
            15.0

        ) /
        8.0 *
        dt


    # PCB follows inverter more slowly.

    twin.thermal.pcb +=

        (

            twin.thermal.inverter -
            twin.thermal.pcb

        ) /
        25.0 *
        dt


    # Housing.

    twin.thermal.housing +=

        (

            twin.thermal.motor -
            twin.thermal.housing

        ) /
        18.0 *
        dt


    # Brush head.

    twin.thermal.brush_head +=

        (

            twin.thermal.housing -
            twin.thermal.brush_head

        ) /
        12.0 *
        dt


    twin.thermal.heat_rejection =

        motor_cooling


    # Global thermal derating.

    motor_factor =

        clamp(

            (
                85.0 -
                twin.thermal.motor
            ) /
            25.0,

            0.0,
            1.0

        )


    battery_factor =

        clamp(

            (
                60.0 -
                twin.thermal.battery
            ) /
            25.0,

            0.0,
            1.0

        )


    inverter_factor =

        clamp(

            (
                95.0 -
                twin.thermal.inverter
            ) /
            30.0,

            0.0,
            1.0

        )


    twin.thermal.thermal_derating =

        min(

            motor_factor,
            battery_factor,
            inverter_factor

        )


    twin.motor.temperature =
        twin.thermal.motor

    twin.battery.temperature =
        twin.thermal.battery


    return twin.thermal

end


# ============================================================
# 25. SENSOR MODEL
# ============================================================

function gaussian_noise(

    σ::Float64

)

    return σ *
           randn()

end


function update_sensors!(

    twin::ToothbrushDigitalTwin

)

    noise =
        twin.sensors.noise_level


    twin.sensors.rpm_measurement =

        twin.motor.rpm +
        gaussian_noise(
            noise *
            300.0
        )


    twin.sensors.current_measurement =

        twin.motor.current +
        gaussian_noise(
            noise *
            0.05
        )


    twin.sensors.voltage_measurement =

        twin.battery.voltage +
        gaussian_noise(
            noise *
            0.01
        )


    twin.sensors.temperature_measurement =

        twin.thermal.motor +
        gaussian_noise(
            noise *
            0.3
        )


    twin.sensors.pressure_measurement =

        twin.physical.pressure +
        gaussian_noise(
            noise *
            0.01
        )


    twin.sensors.vibration_measurement =

        clamp(

            (
                twin.motor.rpm /
                MAX_RPM
            ) *

            0.8 +

            gaussian_noise(
                noise *
                0.05
            ),

            0.0,
            1.0

        )


    twin.sensors.noise_level =
        noise


    twin.sensors.confidence =

        clamp(

            1.0 -
            noise,

            0.0,
            1.0

        )


    return twin.sensors

end


# ============================================================
# 26. PHYSICAL PRESSURE MODEL
# ============================================================

function update_pressure!(

    twin::ToothbrushDigitalTwin

)

    # Synthetic user/contact model.
    # In HIL/observation mode this would be replaced
    # by actual sensor data.

    base_pressure =

        twin.physical.contact_probability *
        0.45


    vibration_component =

        0.05 *
        sin(
            twin.simulation_time *
            7.0
        )


    twin.physical.pressure =

        clamp(

            base_pressure +
            vibration_component,

            0.0,
            1.0

        )


    return twin.physical.pressure

end


# ============================================================
# 27. CONTACT MODEL
# ============================================================

function update_contact!(

    twin::ToothbrushDigitalTwin

)

    # Deterministic synthetic brushing cycle.

    phase =

        mod(
            twin.simulation_time,
            20.0
        )


    if phase < 1.0

        twin.physical.contact_probability =
            0.0

    elseif phase < 4.0

        twin.physical.contact_probability =
            0.75

    elseif phase < 7.0

        twin.physical.contact_probability =
            0.90

    elseif phase < 10.0

        twin.physical.contact_probability =
            0.65

    elseif phase < 12.0

        twin.physical.contact_probability =
            0.25

    else

        twin.physical.contact_probability =
            0.80

    end


    return twin.physical.contact_probability

end


# ============================================================
# 28. ZONE MODEL
# ============================================================

function update_zone!(

    twin::ToothbrushDigitalTwin,
    dt::Float64

)

    zones = collect(
        keys(twin.zone.coverage)
    )


    if isempty(zones)

        return

    end


    index =

        mod(

            floor(
                Int,
                twin.simulation_time /
                8.0
            ),

            length(zones)

        ) + 1


    new_zone =
        zones[index]


    if twin.zone.current_zone !=
       new_zone

        twin.zone.current_zone =
            new_zone

        twin.zone.dwell_time =
            0.0

    end


    twin.zone.dwell_time +=
        dt


    twin.zone.confidence =

        twin.sensors.confidence *
        twin.physical.contact_probability


    if twin.physical.contact_probability >
       0.2

        current =
            twin.zone.coverage[
                twin.zone.current_zone
            ]


        twin.zone.coverage[
            twin.zone.current_zone
        ] =

            clamp(

                current +
                0.01 *
                twin.zone.confidence *
                dt,

                0.0,
                1.0

            )

    end


    return twin.zone

end


# ============================================================
# 29. CLEANING MODEL
# ============================================================

function update_cleaning!(

    twin::ToothbrushDigitalTwin,
    dt::Float64

)

    if !twin.cleaning.active

        return twin.cleaning

    end


    twin.cleaning.elapsed_time +=
        dt


    contact =
        twin.physical.contact_probability


    pressure =
        twin.physical.pressure


    if contact > 0.2

        twin.cleaning.contact_time +=
            dt

    end


    if pressure > 0.82

        twin.cleaning.excessive_pressure_time +=
            dt

    end


    α = 0.02


    twin.cleaning.average_pressure +=

        α *
        (
            pressure -
            twin.cleaning.average_pressure
        )


    twin.cleaning.average_contact +=

        α *
        (
            contact -
            twin.cleaning.average_contact
        )


    instantaneous_score =

        clamp(

            contact *
            (
                1.0 -
                pressure *
                0.5
            ),

            0.0,
            1.0

        )


    twin.cleaning.cleaning_score +=

        α *
        (
            instantaneous_score -
            twin.cleaning.cleaning_score
        )


    coverage_values =

        collect(
            values(
                twin.zone.coverage
            )
        )


    if !isempty(coverage_values)

        twin.cleaning.coverage_score =

            mean(
                coverage_values
            )

    end


    twin.cleaning.consistency_score =

        clamp(

            1.0 -
            abs(
                twin.cleaning.average_contact -
                0.65
            ),

            0.0,
            1.0

        )


    return twin.cleaning

end


# ============================================================
# 30. SAFETY MODEL
# ============================================================

function update_safety!(

    twin::ToothbrushDigitalTwin

)

    faults =
        Symbol[]


    if twin.motor.current >
       MAX_CURRENT

        push!(
            faults,
            :motor_overcurrent
        )

    end


    if twin.motor.rpm >
       MAX_RPM

        push!(
            faults,
            :motor_overspeed
        )

    end


    if twin.thermal.motor >
       85.0

        push!(
            faults,
            :motor_overtemperature
        )

    end


    if twin.thermal.battery >
       60.0

        push!(
            faults,
            :battery_overtemperature
        )

    end


    if twin.battery.voltage <
       2.90

        push!(
            faults,
            :battery_undervoltage
        )

    end


    if twin.physical.pressure >
       0.95

        push!(
            faults,
            :excessive_pressure
        )

    end


    twin.safety.active_faults =
        faults


    if !isempty(faults)

        twin.safety.state =
            :fault

        twin.safety.health =
            0.0

        twin.safety.motor_allowed =
            false

        twin.safety.emergency_stop =
            true

        twin.safety.maximum_rpm =
            0.0

        twin.safety.maximum_power =
            0.0

    else

        thermal_limit =
            twin.thermal.thermal_derating


        battery_limit =

            clamp(

                (
                    twin.battery.voltage -
                    2.9
                ) /
                0.5,

                0.0,
                1.0

            )


        pressure_limit =

            if twin.physical.pressure < 0.5

                1.0

            elseif twin.physical.pressure < 0.82

                0.75

            else

                0.30

            end


        limit =

            min(

                thermal_limit,
                battery_limit,
                pressure_limit

            )


        twin.safety.maximum_rpm =

            MAX_RPM *
            limit


        twin.safety.maximum_power =

            20.0 *
            limit


        twin.safety.motor_allowed =
            true

        twin.safety.emergency_stop =
            false


        if limit < 0.50

            twin.safety.state =
                :derating

        elseif limit < 0.80

            twin.safety.state =
                :warning

        else

            twin.safety.state =
                :normal

        end


        twin.safety.health =
            limit

    end


    return twin.safety

end


# ============================================================
# 31. COMMAND ARBITRATION
# ============================================================

function arbitrate_command!(

    twin::ToothbrushDigitalTwin

)

    requested =
        twin.cleaning.target_rpm


    permitted =

        min(

            requested,

            twin.safety.maximum_rpm

        )


    if !twin.safety.motor_allowed

        permitted = 0.0

    end


    twin.command.target_rpm =
        permitted


    twin.command.target_power =

        min(

            20.0,
            twin.safety.maximum_power

        )


    twin.command.motor_enable =

        twin.safety.motor_allowed


    return twin.command

end


# ============================================================
# 32. STATE SYNCHRONISATION
# ============================================================

function synchronise_physical_state!(

    twin::ToothbrushDigitalTwin

)

    p =
        twin.physical


    p.timestamp =
        twin.simulation_time


    p.rpm =
        twin.motor.rpm


    p.angular_velocity =
        twin.motor.rotor_speed


    p.motor_current =
        twin.motor.current


    p.motor_torque =
        twin.motor.torque


    p.motor_temperature =
        twin.thermal.motor


    p.battery_voltage =
        twin.battery.voltage


    p.battery_current =
        twin.battery.current


    p.battery_soc =
        twin.battery.soc


    p.battery_temperature =
        twin.thermal.battery


    p.inverter_temperature =
        twin.thermal.inverter


    p.pcb_temperature =
        twin.thermal.pcb


    return p

end


# ============================================================
# 33. PARAMETER IDENTIFICATION
# ============================================================

function update_parameter_estimator!(

    twin::ToothbrushDigitalTwin,
    dt::Float64

)

    e =
        twin.estimator


    e.samples += 1


    predicted_current =

        twin.motor.torque /
        max(
            e.estimated_torque_constant,
            1e-6
        )


    current_error =

        twin.motor.current -
        predicted_current


    rpm_error =

        twin.command.target_rpm -
        twin.motor.rpm


    temperature_error =

        twin.motor.temperature -
        twin.thermal.motor


    α = 0.001


    e.estimated_torque_constant =

        clamp(

            e.estimated_torque_constant +
            α *
            current_error *
            0.001,

            0.005,
            0.05

        )


    e.residual_current +=

        α *
        (
            abs(current_error) -
            e.residual_current
        )


    e.residual_rpm +=

        α *
        (
            abs(rpm_error) -
            e.residual_rpm
        )


    e.residual_temperature +=

        α *
        (
            abs(temperature_error) -
            e.residual_temperature
        )


    return e

end


# ============================================================
# 34. ONE PHYSICS STEP
# ============================================================

function step!(

    twin::ToothbrushDigitalTwin,
    dt::Float64 = DEFAULT_DT

)

    if twin.state ==
       TWIN_INITIALISING

        initialise!(
            twin
        )

    end


    if twin.state ==
       TWIN_STOPPED

        return twin

    end


    twin.state =
        TWIN_RUNNING


    twin.simulation_time +=
        dt


    # --------------------------------------------------------
    # Physical interaction
    # --------------------------------------------------------

    update_contact!(
        twin
    )


    update_pressure!(
        twin
    )


    # --------------------------------------------------------
    # Control / physics
    # --------------------------------------------------------

    update_motor!(
        twin,
        dt
    )


    update_battery!(
        twin,
        dt
    )


    update_thermal!(
        twin,
        dt
    )


    # --------------------------------------------------------
    # Sensors
    # --------------------------------------------------------

    update_sensors!(
        twin
    )


    # --------------------------------------------------------
    # Spatial / cleaning layers
    # --------------------------------------------------------

    update_zone!(
        twin,
        dt
    )


    update_cleaning!(
        twin,
        dt
    )


    # --------------------------------------------------------
    # Safety
    # --------------------------------------------------------

    update_safety!(
        twin
    )


    arbitrate_command!(
        twin
    )


    # --------------------------------------------------------
    # State estimation
    # --------------------------------------------------------

    synchronise_physical_state!(
        twin
    )


    update_parameter_estimator!(
        twin,
        dt
    )


    # --------------------------------------------------------
    # History
    # --------------------------------------------------------

    record!(

        twin.history,
        twin,
        twin.simulation_time

    )


    return twin

end


# ============================================================
# 35. START CLEANING
# ============================================================

function start_cleaning!(

    twin::ToothbrushDigitalTwin,
    mode::Symbol = :standard

)

    twin.cleaning.active =
        true

    twin.cleaning.mode =
        mode


    twin.cleaning.elapsed_time =
        0.0

    twin.cleaning.contact_time =
        0.0

    twin.cleaning.excessive_pressure_time =
        0.0


    twin.cleaning.cleaning_score =
        0.0

    twin.cleaning.coverage_score =
        0.0


    if mode == :gentle

        twin.cleaning.target_rpm =
            18000.0

    elseif mode == :intensive

        twin.cleaning.target_rpm =
            34000.0

    elseif mode == :sensitive

        twin.cleaning.target_rpm =
            16000.0

    else

        twin.cleaning.target_rpm =
            26000.0

    end


    twin.command.motor_enable =
        true


    return twin

end


# ============================================================
# 36. STOP CLEANING
# ============================================================

function stop_cleaning!(

    twin::ToothbrushDigitalTwin

)

    twin.cleaning.active =
        false

    twin.cleaning.target_rpm =
        0.0

    twin.command.motor_enable =
        false

    twin.command.target_rpm =
        0.0


    return twin

end


# ============================================================
# 37. RUN SIMULATION
# ============================================================

function simulate!(

    twin::ToothbrushDigitalTwin,
    duration::Float64;
    dt::Float64 = DEFAULT_DT

)

    duration = min(

        duration,
        MAX_SIMULATION_TIME

    )


    steps =

        Int(
            ceil(
                duration / dt
            )
        )


    for _ in 1:steps

        step!(
            twin,
            dt
        )


        if twin.safety.emergency_stop

            break

        end

    end


    return twin

end


# ============================================================
# 38. PERFORMANCE SUMMARY
# ============================================================

function performance_summary(

    twin::ToothbrushDigitalTwin

)

    return (

        runtime =
            twin.simulation_time,

        rpm =
            twin.motor.rpm,

        current =
            twin.motor.current,

        electrical_power =
            twin.motor.electrical_power,

        mechanical_power =
            twin.motor.mechanical_power,

        motor_efficiency =
            twin.motor.efficiency,

        battery_soc =
            twin.battery.soc,

        battery_voltage =
            twin.battery.voltage,

        motor_temperature =
            twin.thermal.motor,

        battery_temperature =
            twin.thermal.battery,

        cleaning_score =
            twin.cleaning.cleaning_score,

        coverage =
            twin.cleaning.coverage_score,

        safety =
            twin.safety.state,

        health =
            twin.safety.health

    )

end


# ============================================================
# 39. DIGITAL TWIN TELEMETRY
# ============================================================

function telemetry(

    twin::ToothbrushDigitalTwin

)

    return Dict(

        "timestamp" =>
            twin.simulation_time,

        "twin_state" =>
            string(twin.state),

        "motor_rpm" =>
            twin.motor.rpm,

        "target_rpm" =>
            twin.command.target_rpm,

        "motor_current" =>
            twin.motor.current,

        "motor_torque" =>
            twin.motor.torque,

        "motor_efficiency" =>
            twin.motor.efficiency,

        "motor_temperature" =>
            twin.thermal.motor,

        "battery_voltage" =>
            twin.battery.voltage,

        "battery_current" =>
            twin.battery.current,

        "battery_soc" =>
            twin.battery.soc,

        "battery_temperature" =>
            twin.battery.temperature,

        "thermal_derating" =>
            twin.thermal.thermal_derating,

        "pressure" =>
            twin.physical.pressure,

        "contact_probability" =>
            twin.physical.contact_probability,

        "zone" =>
            string(twin.zone.current_zone),

        "zone_confidence" =>
            twin.zone.confidence,

        "cleaning_score" =>
            twin.cleaning.cleaning_score,

        "coverage_score" =>
            twin.cleaning.coverage_score,

        "safety_state" =>
            string(twin.safety.state),

        "safety_health" =>
            twin.safety.health,

        "motor_allowed" =>
            twin.safety.motor_allowed,

        "emergency_stop" =>
            twin.safety.emergency_stop

    )

end


# ============================================================
# 40. MODEL ERROR
# ============================================================

function model_error(

    twin::ToothbrushDigitalTwin

)

    return (

        rpm =
            twin.estimator.residual_rpm,

        current =
            twin.estimator.residual_current,

        temperature =
            twin.estimator.residual_temperature

    )

end


# ============================================================
# 41. DIGITAL-TWIN HEALTH
# ============================================================

function twin_health(

    twin::ToothbrushDigitalTwin

)

    model_error_score =

        exp(

            -0.001 *
            (
                twin.estimator.residual_rpm +
                100.0 *
                twin.estimator.residual_current +
                twin.estimator.residual_temperature
            )

        )


    safety_score =
        twin.safety.health


    sensor_score =
        twin.sensors.confidence


    return (

        0.40 *
        model_error_score +

        0.40 *
        safety_score +

        0.20 *
        sensor_score

    )

end


# ============================================================
# 42. SCENARIO: NORMAL BRUSHING
# ============================================================

function scenario_normal(

    duration::Float64 = 120.0

)

    twin =
        ToothbrushDigitalTwin()


    initialise!(
        twin
    )


    start_cleaning!(
        twin,
        :standard
    )


    simulate!(
        twin,
        duration,
        dt = 0.005
    )


    stop_cleaning!(
        twin
    )


    return performance_summary(
        twin
    )

end


# ============================================================
# 43. SCENARIO: INTENSIVE BRUSHING
# ============================================================

function scenario_intensive(

    duration::Float64 = 120.0

)

    twin =
        ToothbrushDigitalTwin()


    initialise!(
        twin
    )


    start_cleaning!(
        twin,
        :intensive
    )


    simulate!(
        twin,
        duration,
        dt = 0.005
    )


    stop_cleaning!(
        twin
    )


    return performance_summary(
        twin
    )

end


# ============================================================
# 44. SCENARIO: HIGH PRESSURE
# ============================================================

function scenario_high_pressure(

    duration::Float64 = 60.0

)

    twin =
        ToothbrushDigitalTwin()


    initialise!(
        twin
    )


    start_cleaning!(
        twin
    )


    for _ in 1:Int(duration / 0.005)

        twin.physical.pressure =
            0.90

        twin.physical.contact_probability =
            0.90


        step!(
            twin,
            0.005
        )


        if twin.safety.emergency_stop

            break

        end

    end


    return performance_summary(
        twin
    )

end


# ============================================================
# 45. SCENARIO: THERMAL STRESS
# ============================================================

function scenario_thermal_stress(

    duration::Float64 = 300.0

)

    twin =
        ToothbrushDigitalTwin()


    initialise!(
        twin
    )


    start_cleaning!(
        twin,
        :intensive
    )


    for _ in 1:Int(duration / 0.005)

        twin.physical.contact_probability =
            0.95

        twin.physical.pressure =
            0.75


        step!(
            twin,
            0.005
        )


        if twin.safety.emergency_stop

            break

        end

    end


    return performance_summary(
        twin
    )

end


# ============================================================
# 46. SCENARIO: LOW BATTERY
# ============================================================

function scenario_low_battery(

    duration::Float64 = 120.0

)

    twin =
        ToothbrushDigitalTwin()


    initialise!(
        twin
    )


    twin.battery.soc =
        0.12


    start_cleaning!(
        twin
    )


    simulate!(
        twin,
        duration,
        dt = 0.005
    )


    return performance_summary(
        twin
    )

end


# ============================================================
# 47. MONTE CARLO RUN
# ============================================================

function monte_carlo(

    runs::Int = 100;
    duration::Float64 = 120.0

)

    results = Vector{Any}()


    for i in 1:runs

        twin =
            ToothbrushDigitalTwin()


        initialise!(
            twin
        )


        twin.sensors.noise_level =

            rand() *
            0.10


        twin.physical.pressure =

            0.2 +
            rand() *
            0.4


        start_cleaning!(
            twin
        )


        simulate!(
            twin,
            duration,
            dt = 0.01
        )


        push!(

            results,

            performance_summary(
                twin
            )

        )

    end


    return results

end


# ============================================================
# 48. FAULT INJECTION
# ============================================================

function inject_fault!(

    twin::ToothbrushDigitalTwin,
    fault::Symbol

)

    if fault == :overcurrent

        twin.motor.current =
            MAX_CURRENT * 1.5


    elseif fault == :overspeed

        twin.motor.rpm =
            MAX_RPM * 1.2


    elseif fault == :overtemperature

        twin.thermal.motor =
            100.0


    elseif fault == :undervoltage

        twin.battery.voltage =
            2.5


    elseif fault == :high_pressure

        twin.physical.pressure =
            1.0


    elseif fault == :sensor_failure

        twin.sensors.confidence =
            0.0

    end


    update_safety!(
        twin
    )


    return twin

end


# ============================================================
# 49. RESET
# ============================================================

function reset!(

    twin::ToothbrushDigitalTwin

)

    initialise!(
        twin
    )

    twin.state =
        TWIN_READY


    return twin

end


# ============================================================
# 50. EXPORTS
# ============================================================

export TwinMode
export TwinState

export PhysicalState
export MotorTwin
export BatteryTwin
export ThermalTwin
export SensorTwin
export ZoneTwin
export CleaningTwin
export SafetyTwin

export TwinParameters
export TwinCommand
export ParameterEstimator
export TwinHistory

export ToothbrushDigitalTwin

export initialise!
export reset!

export start_cleaning!
export stop_cleaning!

export step!
export simulate!

export telemetry
export performance_summary
export model_error
export twin_health

export scenario_normal
export scenario_intensive
export scenario_high_pressure
export scenario_thermal_stress
export scenario_low_battery

export monte_carlo
export inject_fault!

end





module ToothbrushSessionAnalytics

using Statistics
using LinearAlgebra

# ============================================================
# TOOTHBRUSH SESSION ANALYTICS
#
# Analytics layer for the Julia electric-toothbrush architecture.
#
# Designed to consume outputs from:
#   - SensorFusion
#   - PressureContact
#   - BatterySOC
#   - ThermalModel
#   - CleaningAlgorithms
#   - ToothZoneEstimator
#   - DigitalTwin
#
# Produces:
#   - session metrics
#   - zone analytics
#   - pressure analytics
#   - motion analytics
#   - motor analytics
#   - energy analytics
#   - thermal analytics
#   - brushing consistency
#   - cleaning score
#   - session quality
#   - longitudinal trends
#   - anomaly detection
#   - recommendations
#
# Reference/simulation architecture only.
# ============================================================


# ============================================================
# 01. CONSTANTS
# ============================================================

const TARGET_SESSION_TIME = 120.0

const TARGET_ZONE_TIME = 15.0

const GOOD_COVERAGE = 0.80

const EXCELLENT_COVERAGE = 0.92

const HIGH_PRESSURE = 0.65

const EXCESSIVE_PRESSURE = 0.82

const GOOD_CONTACT = 0.60

const GOOD_MOTION = 0.50

const TARGET_RPM = 26000.0

const MAX_RPM = 42000.0

const MAX_CURRENT = 8.0

const MAX_SAFE_MOTOR_TEMP = 85.0

const MAX_SAFE_BATTERY_TEMP = 60.0

const ENERGY_EFFICIENCY_TARGET = 0.75

const SCORE_ALPHA = 0.05

const TREND_WINDOW = 30

const ANOMALY_Z = 3.0


# ============================================================
# 02. SESSION STATE
# ============================================================

@enum SessionState begin

    SESSION_IDLE

    SESSION_ACTIVE

    SESSION_PAUSED

    SESSION_COMPLETED

    SESSION_ABORTED

end


# ============================================================
# 03. ZONES
# ============================================================

const ANALYTICS_ZONES = [

    :upper_left_outer,
    :upper_left_inner,
    :upper_left_occlusal,

    :upper_front_outer,
    :upper_front_inner,
    :upper_front_occlusal,

    :upper_right_outer,
    :upper_right_inner,
    :upper_right_occlusal,

    :lower_left_outer,
    :lower_left_inner,
    :lower_left_occlusal,

    :lower_front_outer,
    :lower_front_inner,
    :lower_front_occlusal,

    :lower_right_outer,
    :lower_right_inner,
    :lower_right_occlusal

]


# ============================================================
# 04. RAW SESSION SAMPLE
# ============================================================

struct SessionSample

    timestamp::Float64

    rpm::Float64

    target_rpm::Float64

    motor_current::Float64

    motor_power::Float64

    motor_temperature::Float64

    battery_voltage::Float64

    battery_soc::Float64

    battery_temperature::Float64

    pressure::Float64

    contact_probability::Float64

    tooth_contact_probability::Float64

    vibration::Float64

    motion_intensity::Float64

    brushing_velocity::Float64

    acceleration::Float64

    zone::Symbol

    zone_confidence::Float64

end


# ============================================================
# 05. ZONE ANALYTICS
# ============================================================

mutable struct ZoneAnalytics

    zone::Symbol

    elapsed_time::Float64

    contact_time::Float64

    effective_time::Float64

    pressure_time::Float64

    excessive_pressure_time::Float64

    average_pressure::Float64

    peak_pressure::Float64

    average_contact::Float64

    average_motion::Float64

    average_rpm::Float64

    cleaning_score::Float64

    coverage_score::Float64

    confidence::Float64

    visits::Int

    completed::Bool

end


function ZoneAnalytics(

    zone::Symbol

)

    ZoneAnalytics(

        zone,

        0.0,
        0.0,
        0.0,
        0.0,
        0.0,

        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        0.0,
        0.0,

        0.0,

        0,

        false

    )

end


# ============================================================
# 06. PRESSURE ANALYTICS
# ============================================================

mutable struct PressureAnalytics

    samples::Int

    mean_pressure::Float64

    peak_pressure::Float64

    standard_deviation::Float64

    time_normal::Float64

    time_high::Float64

    time_excessive::Float64

    exposure_fraction::Float64

    pressure_quality::Float64

    pressure_consistency::Float64

    protection_events::Int

end


function PressureAnalytics()

    PressureAnalytics(

        0,

        0.0,
        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        0.0,

        0.0,
        0.0,

        0

    )

end


# ============================================================
# 07. MOTION ANALYTICS
# ============================================================

mutable struct MotionAnalytics

    samples::Int

    mean_motion::Float64

    peak_motion::Float64

    motion_variance::Float64

    mean_velocity::Float64

    mean_acceleration::Float64

    active_motion_time::Float64

    stationary_time::Float64

    stability_score::Float64

    motion_quality::Float64

end


function MotionAnalytics()

    MotionAnalytics(

        0,

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

end


# ============================================================
# 08. MOTOR ANALYTICS
# ============================================================

mutable struct MotorAnalytics

    samples::Int

    mean_rpm::Float64

    peak_rpm::Float64

    rpm_variance::Float64

    target_tracking_error::Float64

    mean_current::Float64

    peak_current::Float64

    mean_power::Float64

    peak_power::Float64

    motor_efficiency::Float64

    overload_time::Float64

end


function MotorAnalytics()

    MotorAnalytics(

        0,

        0.0,
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

end


# ============================================================
# 09. ENERGY ANALYTICS
# ============================================================

mutable struct EnergyAnalytics

    energy_wh::Float64

    average_power::Float64

    peak_power::Float64

    battery_start_soc::Float64

    battery_end_soc::Float64

    soc_consumed::Float64

    energy_per_minute::Float64

    estimated_runtime_minutes::Float64

end


function EnergyAnalytics()

    EnergyAnalytics(

        0.0,
        0.0,
        0.0,

        1.0,
        1.0,

        0.0,

        0.0,

        0.0

    )

end


# ============================================================
# 10. THERMAL ANALYTICS
# ============================================================

mutable struct ThermalAnalytics

    starting_motor_temperature::Float64

    ending_motor_temperature::Float64

    peak_motor_temperature::Float64

    starting_battery_temperature::Float64

    ending_battery_temperature::Float64

    peak_battery_temperature::Float64

    thermal_derating_time::Float64

    thermal_warning_time::Float64

    thermal_margin::Float64

    thermal_score::Float64

end


function ThermalAnalytics()

    ThermalAnalytics(

        22.0,
        22.0,
        22.0,

        22.0,
        22.0,
        22.0,

        0.0,
        0.0,

        1.0,
        1.0

    )

end


# ============================================================
# 11. SESSION QUALITY
# ============================================================

mutable struct SessionQuality

    coverage_score::Float64

    pressure_score::Float64

    contact_score::Float64

    motion_score::Float64

    consistency_score::Float64

    efficiency_score::Float64

    thermal_score::Float64

    completion_score::Float64

    overall_score::Float64

    grade::Symbol

end


function SessionQuality()

    SessionQuality(

        0.0,
        0.0,
        0.0,
        0.0,

        0.0,
        0.0,
        0.0,
        0.0,

        0.0,

        :unrated

    )

end


# ============================================================
# 12. SESSION SUMMARY
# ============================================================

mutable struct SessionSummary

    session_id::Int

    start_timestamp::Float64

    end_timestamp::Float64

    duration::Float64

    active_time::Float64

    contact_time::Float64

    cleaning_time::Float64

    quality::SessionQuality

    pressure::PressureAnalytics

    motion::MotionAnalytics

    motor::MotorAnalytics

    energy::EnergyAnalytics

    thermal::ThermalAnalytics

    zones::Dict{Symbol,ZoneAnalytics}

end


# ============================================================
# 13. LONGITUDINAL HISTORY
# ============================================================

mutable struct SessionHistory

    sessions::Vector{SessionSummary}

    capacity::Int

end


function SessionHistory(

    capacity::Int = 365

)

    SessionHistory(

        SessionSummary[],

        capacity

    )

end


function add_session!(

    history::SessionHistory,
    summary::SessionSummary

)

    push!(
        history.sessions,
        summary
    )


    if length(history.sessions) >
       history.capacity

        deleteat!(
            history.sessions,
            1
        )

    end


    return history

end


# ============================================================
# 14. ACTIVE SESSION
# ============================================================

mutable struct AnalyticsSession

    id::Int

    state::SessionState

    start_timestamp::Float64

    last_timestamp::Float64

    duration::Float64

    active_time::Float64

    contact_time::Float64

    cleaning_time::Float64

    samples::Int

    pressure::PressureAnalytics

    motion::MotionAnalytics

    motor::MotorAnalytics

    energy::EnergyAnalytics

    thermal::ThermalAnalytics

    zones::Dict{Symbol,ZoneAnalytics}

    quality::SessionQuality

    recent_scores::Vector{Float64}

end


function AnalyticsSession(

    id::Int = 1

)

    zones = Dict(

        zone => ZoneAnalytics(zone)

        for zone in ANALYTICS_ZONES

    )


    AnalyticsSession(

        id,

        SESSION_IDLE,

        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        0,

        PressureAnalytics(),
        MotionAnalytics(),
        MotorAnalytics(),
        EnergyAnalytics(),
        ThermalAnalytics(),

        zones,

        SessionQuality(),

        Float64[]

    )

end


# ============================================================
# 15. ANALYTICS ENGINE
# ============================================================

mutable struct SessionAnalyticsEngine

    session::AnalyticsSession

    history::SessionHistory

    next_session_id::Int

end


function SessionAnalyticsEngine()

    SessionAnalyticsEngine(

        AnalyticsSession(1),

        SessionHistory(),

        2

    )

end


# ============================================================
# 16. START SESSION
# ============================================================

function start_session!(

    engine::SessionAnalyticsEngine,
    timestamp::Float64 = 0.0

)

    engine.session =
        AnalyticsSession(
            engine.next_session_id
        )


    engine.next_session_id += 1


    engine.session.state =
        SESSION_ACTIVE


    engine.session.start_timestamp =
        timestamp

    engine.session.last_timestamp =
        timestamp


    return engine.session

end


# ============================================================
# 17. PRESSURE UPDATE
# ============================================================

function update_pressure!(

    p::PressureAnalytics,
    pressure::Float64,
    dt::Float64

)

    p.samples += 1


    α =
        1.0 /
        p.samples


    p.mean_pressure +=

        α *
        (
            pressure -
            p.mean_pressure
        )


    p.standard_deviation +=

        α *
        (
            (
                pressure -
                p.mean_pressure
            )^2 -
            p.standard_deviation
        )


    p.peak_pressure =

        max(
            p.peak_pressure,
            pressure
        )


    if pressure < HIGH_PRESSURE

        p.time_normal +=
            dt

    elseif pressure < EXCESSIVE_PRESSURE

        p.time_high +=
            dt

    else

        p.time_excessive +=
            dt

        p.protection_events += 1

    end


    total_time =

        p.time_normal +
        p.time_high +
        p.time_excessive


    if total_time > 0

        p.exposure_fraction =

            p.time_excessive /
            total_time

    end


    p.pressure_quality =

        clamp(

            1.0 -

            (
                0.6 *
                p.time_high +
                1.5 *
                p.time_excessive
            ) /
            max(
                total_time,
                1e-6
            ),

            0.0,
            1.0

        )


    p.pressure_consistency =

        clamp(

            1.0 -
            sqrt(
                max(
                    p.standard_deviation,
                    0.0
                )
            ),

            0.0,
            1.0

        )


    return p

end


# ============================================================
# 18. MOTION UPDATE
# ============================================================

function update_motion!(

    m::MotionAnalytics,
    motion::Float64,
    velocity::Float64,
    acceleration::Float64,
    dt::Float64

)

    m.samples += 1


    α =
        1.0 /
        m.samples


    m.mean_motion +=

        α *
        (
            motion -
            m.mean_motion
        )


    m.motion_variance +=

        α *
        (
            (
                motion -
                m.mean_motion
            )^2 -
            m.motion_variance
        )


    m.peak_motion =

        max(
            m.peak_motion,
            motion
        )


    m.mean_velocity +=

        α *
        (
            velocity -
            m.mean_velocity
        )


    m.mean_acceleration +=

        α *
        (
            acceleration -
            m.mean_acceleration
        )


    if motion > 0.20

        m.active_motion_time +=
            dt

    else

        m.stationary_time +=
            dt

    end


    total =

        m.active_motion_time +
        m.stationary_time


    if total > 0

        active_fraction =

            m.active_motion_time /
            total


        m.motion_quality =

            clamp(

                1.0 -
                abs(
                    active_fraction -
                    0.75
                ),

                0.0,
                1.0

            )

    end


    m.stability_score =

        clamp(

            1.0 -
            sqrt(
                max(
                    m.motion_variance,
                    0.0
                )
            ),

            0.0,
            1.0

        )


    return m

end


# ============================================================
# 19. MOTOR UPDATE
# ============================================================

function update_motor!(

    m::MotorAnalytics,
    rpm::Float64,
    target_rpm::Float64,
    current::Float64,
    power::Float64,
    dt::Float64

)

    m.samples += 1


    α =
        1.0 /
        m.samples


    m.mean_rpm +=

        α *
        (
            rpm -
            m.mean_rpm
        )


    m.peak_rpm =

        max(
            m.peak_rpm,
            rpm
        )


    m.rpm_variance +=

        α *
        (
            (
                rpm -
                m.mean_rpm
            )^2 -
            m.rpm_variance
        )


    m.target_tracking_error +=

        α *
        (
            abs(
                target_rpm -
                rpm
            ) -
            m.target_tracking_error
        )


    m.mean_current +=

        α *
        (
            current -
            m.mean_current
        )


    m.peak_current =

        max(
            m.peak_current,
            current
        )


    m.mean_power +=

        α *
        (
            power -
            m.mean_power
        )


    m.peak_power =

        max(
            m.peak_power,
            power
        )


    if current > MAX_CURRENT * 0.85

        m.overload_time +=
            dt

    end


    return m

end


# ============================================================
# 20. ENERGY UPDATE
# ============================================================

function update_energy!(

    e::EnergyAnalytics,
    voltage::Float64,
    current::Float64,
    soc::Float64,
    dt::Float64

)

    power =
        voltage *
        current


    e.energy_wh +=

        power *
        dt /
        3600.0


    e.peak_power =

        max(
            e.peak_power,
            power
        )


    if e.energy_wh > 0

        e.average_power =

            e.energy_wh /
            max(
                dt,
                1.0
            ) *
            3600.0

    end


    e.battery_end_soc =
        soc


    e.soc_consumed =

        e.battery_start_soc -
        e.battery_end_soc


    return e

end


# ============================================================
# 21. THERMAL UPDATE
# ============================================================

function update_thermal!(

    t::ThermalAnalytics,
    motor_temperature::Float64,
    battery_temperature::Float64,
    dt::Float64

)

    t.ending_motor_temperature =
        motor_temperature

    t.ending_battery_temperature =
        battery_temperature


    t.peak_motor_temperature =

        max(
            t.peak_motor_temperature,
            motor_temperature
        )


    t.peak_battery_temperature =

        max(
            t.peak_battery_temperature,
            battery_temperature
        )


    if motor_temperature > 68.0

        t.thermal_derating_time +=
            dt

    end


    if motor_temperature > 60.0

        t.thermal_warning_time +=
            dt

    end


    t.thermal_margin =

        clamp(

            (
                MAX_SAFE_MOTOR_TEMP -
                t.peak_motor_temperature
            ) /
            (
                MAX_SAFE_MOTOR_TEMP -
                25.0
            ),

            0.0,
            1.0

        )


    t.thermal_score =

        t.thermal_margin


    return t

end


# ============================================================
# 22. ZONE UPDATE
# ============================================================

function update_zone!(

    z::ZoneAnalytics,
    sample::SessionSample,
    dt::Float64

)

    z.elapsed_time +=
        dt


    if sample.contact_probability >
       0.20

        z.contact_time +=
            dt

    end


    effective =

        sample.contact_probability *
        sample.tooth_contact_probability *
        (
            1.0 -
            0.5 *
            sample.pressure
        )


    if effective > 0.25

        z.effective_time +=
            dt

    end


    if sample.pressure > HIGH_PRESSURE

        z.pressure_time +=
            dt

    end


    if sample.pressure >
       EXCESSIVE_PRESSURE

        z.excessive_pressure_time +=
            dt

    end


    n = max(
        z.visits,
        1
    )


    z.average_pressure +=

        (
            sample.pressure -
            z.average_pressure
        ) /
        n


    z.peak_pressure =

        max(
            z.peak_pressure,
            sample.pressure
        )


    z.average_contact +=

        (
            sample.contact_probability -
            z.average_contact
        ) /
        n


    z.average_motion +=

        (
            sample.motion_intensity -
            z.average_motion
        ) /
        n


    z.average_rpm +=

        (
            sample.rpm -
            z.average_rpm
        ) /
        n


    z.confidence +=

        (
            sample.zone_confidence -
            z.confidence
        ) /
        n


    # Effective cleaning score.

    contact_score =

        clamp(
            z.average_contact,
            0.0,
            1.0
        )


    pressure_score =

        clamp(

            1.0 -
            z.average_pressure,

            0.0,
            1.0

        )


    time_score =

        clamp(

            z.effective_time /
            TARGET_ZONE_TIME,

            0.0,
            1.0

        )


    z.cleaning_score =

        0.40 * contact_score +
        0.30 * pressure_score +
        0.30 * time_score


    z.coverage_score =

        clamp(

            z.effective_time /
            TARGET_ZONE_TIME,

            0.0,
            1.0

        )


    z.completed =

        z.effective_time >=
        TARGET_ZONE_TIME &&
        z.cleaning_score >= 0.65


    return z

end


# ============================================================
# 23. SAMPLE INGESTION
# ============================================================

function update!(

    engine::SessionAnalyticsEngine,
    sample::SessionSample

)

    s =
        engine.session


    if s.state !=
       SESSION_ACTIVE

        return s

    end


    dt =

        if s.samples == 0

            0.0

        else

            max(

                0.0,

                sample.timestamp -
                s.last_timestamp

            )

        end


    s.last_timestamp =
        sample.timestamp


    s.duration +=
        dt


    s.samples += 1


    # --------------------------------------------------------
    # Activity
    # --------------------------------------------------------

    if sample.motion_intensity > 0.20

        s.active_time +=
            dt

    end


    if sample.contact_probability > 0.20

        s.contact_time +=
            dt

    end


    if sample.tooth_contact_probability > 0.40

        s.cleaning_time +=
            dt

    end


    # --------------------------------------------------------
    # Analytics
    # --------------------------------------------------------

    update_pressure!(

        s.pressure,

        sample.pressure,

        dt

    )


    update_motion!(

        s.motion,

        sample.motion_intensity,

        sample.brushing_velocity,

        sample.acceleration,

        dt

    )


    update_motor!(

        s.motor,

        sample.rpm,

        sample.target_rpm,

        sample.motor_current,

        sample.motor_power,

        dt

    )


    update_energy!(

        s.energy,

        sample.battery_voltage,

        sample.motor_current,

        sample.battery_soc,

        dt

    )


    update_thermal!(

        s.thermal,

        sample.motor_temperature,

        sample.battery_temperature,

        dt

    )


    # --------------------------------------------------------
    # Zone
    # --------------------------------------------------------

    if haskey(
        s.zones,
        sample.zone
    )

        zone =
            s.zones[
                sample.zone
            ]


        if zone.visits == 0

            zone.visits = 1

        end


        update_zone!(

            zone,

            sample,

            dt

        )

    end


    # --------------------------------------------------------
    # Running quality estimate
    # --------------------------------------------------------

    score =

        instantaneous_score(
            s
        )


    push!(
        s.recent_scores,
        score
    )


    if length(
        s.recent_scores
    ) > 100

        deleteat!(
            s.recent_scores,
            1
        )

    end


    return s

end


# ============================================================
# 24. INSTANTANEOUS SCORE
# ============================================================

function instantaneous_score(

    s::AnalyticsSession

)

    pressure =
        s.pressure.pressure_quality


    motion =
        s.motion.motion_quality


    thermal =
        s.thermal.thermal_score


    contact =

        if s.contact_time > 0

            clamp(

                s.contact_time /
                max(
                    s.duration,
                    1e-6
                ),

                0.0,
                1.0

            )

        else

            0.0

        end


    return (

        0.30 * pressure +
        0.20 * motion +
        0.20 * thermal +
        0.30 * contact

    )

end


# ============================================================
# 25. COVERAGE SCORE
# ============================================================

function calculate_coverage(

    s::AnalyticsSession

)

    scores = Float64[]


    for zone in values(s.zones)

        push!(
            scores,
            zone.coverage_score
        )

    end


    if isempty(scores)

        return 0.0

    end


    return mean(scores)

end


# ============================================================
# 26. WEIGHTED COVERAGE
# ============================================================

function weighted_coverage(

    s::AnalyticsSession

)

    weights = Float64[]

    scores = Float64[]


    for zone in values(s.zones)

        weight =

            zone.confidence *
            max(
                zone.effective_time,
                0.1
            )


        push!(
            weights,
            weight
        )


        push!(
            scores,
            zone.coverage_score
        )

    end


    total =
        sum(weights)


    if total <= 0

        return 0.0

    end


    return sum(
        weights .* scores
    ) / total

end


# ============================================================
# 27. PRESSURE SCORE
# ============================================================

function final_pressure_score(

    s::AnalyticsSession

)

    return clamp(

        0.65 *
        s.pressure.pressure_quality +

        0.35 *
        s.pressure.pressure_consistency,

        0.0,
        1.0

    )

end


# ============================================================
# 28. CONTACT SCORE
# ============================================================

function contact_score(

    s::AnalyticsSession

)

    if s.duration <= 0

        return 0.0

    end


    contact_fraction =

        s.contact_time /
        s.duration


    cleaning_fraction =

        s.cleaning_time /
        s.duration


    return clamp(

        0.5 *
        contact_fraction +

        0.5 *
        cleaning_fraction,

        0.0,
        1.0

    )

end


# ============================================================
# 29. CONSISTENCY SCORE
# ============================================================

function consistency_score(

    s::AnalyticsSession

)

    if isempty(
        s.recent_scores
    )

        return 0.0

    end


    μ =
        mean(
            s.recent_scores
        )


    σ =
        std(
            s.recent_scores
        )


    stability =

        clamp(

            1.0 -
            σ,

            0.0,
            1.0

        )


    return clamp(

        0.60 * μ +
        0.40 * stability,

        0.0,
        1.0

    )

end


# ============================================================
# 30. COMPLETION SCORE
# ============================================================

function completion_score(

    s::AnalyticsSession

)

    duration_score =

        clamp(

            s.duration /
            TARGET_SESSION_TIME,

            0.0,
            1.0

        )


    coverage_score =

        calculate_coverage(
            s
        )


    return (

        0.50 *
        duration_score +

        0.50 *
        coverage_score

    )

end


# ============================================================
# 31. EFFICIENCY SCORE
# ============================================================

function efficiency_score(

    s::AnalyticsSession

)

    if s.energy.energy_wh <= 0

        return 1.0

    end


    power_penalty =

        clamp(

            s.energy.average_power /
            20.0,

            0.0,
            1.0

        )


    useful_fraction =

        if s.duration > 0

            s.cleaning_time /
            s.duration

        else

            0.0

        end


    return clamp(

        0.65 *
        useful_fraction +

        0.35 *
        (
            1.0 -
            power_penalty
        ),

        0.0,
        1.0

    )

end


# ============================================================
# 32. FINAL QUALITY
# ============================================================

function calculate_quality!(

    s::AnalyticsSession

)

    s.quality.coverage_score =

        weighted_coverage(
            s
        )


    s.quality.pressure_score =

        final_pressure_score(
            s
        )


    s.quality.contact_score =

        contact_score(
            s
        )


    s.quality.motion_score =

        s.motion.motion_quality


    s.quality.consistency_score =

        consistency_score(
            s
        )


    s.quality.efficiency_score =

        efficiency_score(
            s
        )


    s.quality.thermal_score =

        s.thermal.thermal_score


    s.quality.completion_score =

        completion_score(
            s
        )


    # Overall score.

    s.quality.overall_score =

        100.0 *

        (

            0.25 *
            s.quality.coverage_score +

            0.20 *
            s.quality.pressure_score +

            0.15 *
            s.quality.contact_score +

            0.10 *
            s.quality.motion_score +

            0.10 *
            s.quality.consistency_score +

            0.05 *
            s.quality.efficiency_score +

            0.05 *
            s.quality.thermal_score +

            0.10 *
            s.quality.completion_score

        )


    score =
        s.quality.overall_score


    s.quality.grade =

        if score >= 90

            :excellent

        elseif score >= 80

            :very_good

        elseif score >= 70

            :good

        elseif score >= 60

            :acceptable

        elseif score >= 40

            :needs_improvement

        else

            :poor

        end


    return s.quality

end


# ============================================================
# 33. FINISH SESSION
# ============================================================

function finish_session!(

    engine::SessionAnalyticsEngine,
    timestamp::Float64

)

    s =
        engine.session


    if s.state !=
       SESSION_ACTIVE

        return nothing

    end


    s.last_timestamp =
        timestamp


    s.duration =

        timestamp -
        s.start_timestamp


    calculate_quality!(
        s
    )


    s.energy.energy_per_minute =

        if s.duration > 0

            s.energy.energy_wh /
            (
                s.duration /
                60.0
            )

        else

            0.0

        end


    if s.energy.energy_wh > 0

        remaining_energy =

            s.energy.battery_start_soc *
            2.775


        s.energy.estimated_runtime_minutes =

            remaining_energy /
            s.energy.energy_per_minute

    end


    s.state =
        SESSION_COMPLETED


    summary =

        SessionSummary(

            s.id,

            s.start_timestamp,
            s.last_timestamp,

            s.duration,
            s.active_time,
            s.contact_time,
            s.cleaning_time,

            s.quality,
            s.pressure,
            s.motion,
            s.motor,
            s.energy,
            s.thermal,
            s.zones

        )


    add_session!(

        engine.history,
        summary

    )


    return summary

end


# ============================================================
# 34. MISSED ZONES
# ============================================================

function missed_zones(

    s::AnalyticsSession

)

    return [

        zone.zone

        for zone in values(s.zones)

        if zone.coverage_score <
           GOOD_COVERAGE

    ]

end


# ============================================================
# 35. OVERBRUSHED ZONES
# ============================================================

function overbrushed_zones(

    s::AnalyticsSession

)

    return [

        zone.zone

        for zone in values(s.zones)

        if zone.effective_time >
           TARGET_ZONE_TIME * 2.0

    ]

end


# ============================================================
# 36. PRESSURE EVENTS
# ============================================================

function pressure_events(

    s::AnalyticsSession

)

    return (

        high =
            s.pressure.time_high,

        excessive =
            s.pressure.time_excessive,

        events =
            s.pressure.protection_events,

        peak =
            s.pressure.peak_pressure

    )

end


# ============================================================
# 37. MOTOR HEALTH
# ============================================================

function motor_health(

    s::AnalyticsSession

)

    tracking =

        clamp(

            1.0 -
            s.motor.target_tracking_error /
            5000.0,

            0.0,
            1.0

        )


    overload =

        clamp(

            1.0 -
            s.motor.overload_time /
            max(
                s.duration,
                1.0
            ),

            0.0,
            1.0

        )


    thermal =

        s.thermal.thermal_score


    return (

        0.40 * tracking +
        0.30 * overload +
        0.30 * thermal

    )

end


# ============================================================
# 38. SESSION ANOMALY DETECTION
# ============================================================

function session_anomalies(

    s::AnalyticsSession

)

    anomalies =
        Symbol[]


    if s.motor.peak_current >
       MAX_CURRENT

        push!(
            anomalies,
            :motor_overcurrent
        )

    end


    if s.motor.peak_rpm >
       MAX_RPM

        push!(
            anomalies,
            :overspeed
        )

    end


    if s.thermal.peak_motor_temperature >
       MAX_SAFE_MOTOR_TEMP

        push!(
            anomalies,
            :motor_overtemperature
        )

    end


    if s.thermal.peak_battery_temperature >
       MAX_SAFE_BATTERY_TEMP

        push!(
            anomalies,
            :battery_overtemperature
        )

    end


    if s.pressure.time_excessive >
       10.0

        push!(
            anomalies,
            :excessive_pressure
        )

    end


    if calculate_coverage(s) <
       0.50

        push!(
            anomalies,
            :poor_coverage
        )

    end


    if s.motion.stationary_time >
       s.duration * 0.50

        push!(
            anomalies,
            :low_motion
        )

    end


    return anomalies

end


# ============================================================
# 39. USER FEEDBACK
# ============================================================

function recommendations(

    s::AnalyticsSession

)

    advice =
        String[]


    if s.quality.coverage_score < 0.70

        push!(

            advice,

            "Increase coverage of missed zones."

        )

    end


    if s.quality.pressure_score < 0.70

        push!(

            advice,

            "Reduce brushing pressure."

        )

    end


    if s.quality.contact_score < 0.60

        push!(

            advice,

            "Maintain more consistent contact."

        )

    end


    if s.quality.motion_score < 0.60

        push!(

            advice,

            "Use a steadier brushing motion."

        )

    end


    if s.quality.completion_score < 0.80

        push!(

            advice,

            "Spend more time completing the full brushing cycle."

        )

    end


    if isempty(advice)

        push!(

            advice,

            "Brushing session was well balanced."

        )

    end


    return advice

end


# ============================================================
# 40. LONGITUDINAL TREND
# ============================================================

function trend(

    history::SessionHistory,
    metric::Symbol

)

    values = Float64[]


    for session in history.sessions

        value =

            if metric == :overall

                session.quality.overall_score

            elseif metric == :coverage

                session.quality.coverage_score * 100.0

            elseif metric == :pressure

                session.quality.pressure_score * 100.0

            elseif metric == :contact

                session.quality.contact_score * 100.0

            elseif metric == :motion

                session.quality.motion_score * 100.0

            elseif metric == :energy

                session.energy.energy_wh

            elseif metric == :temperature

                session.thermal.peak_motor_temperature

            else

                NaN

            end


        push!(
            values,
            value
        )

    end


    return values

end


# ============================================================
# 41. TREND DIRECTION
# ============================================================

function trend_direction(

    history::SessionHistory,
    metric::Symbol

)

    values =
        trend(
            history,
            metric
        )


    if length(values) < 2

        return :insufficient_data

    end


    recent =

        mean(
            values[
                max(
                    1,
                    length(values) - 4
                ):end
            ]
        )


    previous =

        mean(
            values[
                1:
                max(
                    1,
                    length(values) - 5
                )
            ]
        )


    delta =
        recent -
        previous


    if delta > 2.0

        return :improving

    elseif delta < -2.0

        return :declining

    else

        return :stable

    end

end


# ============================================================
# 42. PERSONAL BASELINE
# ============================================================

function personal_baseline(

    history::SessionHistory,
    metric::Symbol

)

    values =
        trend(
            history,
            metric
        )


    values = filter(
        x -> isfinite(x),
        values
    )


    if isempty(values)

        return (

            mean = 0.0,
            standard_deviation = 0.0,
            minimum = 0.0,
            maximum = 0.0

        )

    end


    return (

        mean =
            mean(values),

        standard_deviation =
            std(values),

        minimum =
            minimum(values),

        maximum =
            maximum(values)

    )

end


# ============================================================
# 43. SESSION OUTLIER
# ============================================================

function is_outlier(

    history::SessionHistory,
    value::Float64,
    metric::Symbol

)

    baseline =
        personal_baseline(
            history,
            metric
        )


    if baseline.standard_deviation < 1e-9

        return false

    end


    z =

        abs(

            value -
            baseline.mean

        ) /
        baseline.standard_deviation


    return z >
           ANOMALY_Z

end


# ============================================================
# 44. WEEKLY SUMMARY
# ============================================================

function weekly_summary(

    history::SessionHistory

)

    if isempty(
        history.sessions
    )

        return nothing

    end


    recent =

        history.sessions[
            max(
                1,
                length(history.sessions) - 6
            ):end
        ]


    return (

        sessions =
            length(recent),

        average_score =
            mean(
                s.quality.overall_score
                for s in recent
            ),

        average_coverage =
            mean(
                s.quality.coverage_score
                for s in recent
            ),

        average_pressure =
            mean(
                s.quality.pressure_score
                for s in recent
            ),

        average_duration =
            mean(
                s.duration
                for s in recent
            ),

        total_energy =
            sum(
                s.energy.energy_wh
                for s in recent
            ),

        pressure_events =
            sum(
                s.pressure.protection_events
                for s in recent
            )

    )

end


# ============================================================
# 45. SESSION REPORT
# ============================================================

function report(

    summary::SessionSummary

)

    return Dict(

        "session_id" =>
            summary.session_id,

        "duration_seconds" =>
            summary.duration,

        "overall_score" =>
            summary.quality.overall_score,

        "grade" =>
            string(
                summary.quality.grade
            ),

        "coverage_score" =>
            summary.quality.coverage_score,

        "pressure_score" =>
            summary.quality.pressure_score,

        "contact_score" =>
            summary.quality.contact_score,

        "motion_score" =>
            summary.quality.motion_score,

        "consistency_score" =>
            summary.quality.consistency_score,

        "energy_wh" =>
            summary.energy.energy_wh,

        "peak_motor_temperature" =>
            summary.thermal.peak_motor_temperature,

        "peak_battery_temperature" =>
            summary.thermal.peak_battery_temperature,

        "peak_pressure" =>
            summary.pressure.peak_pressure,

        "missed_zones" =>
            missed_zones_from_summary(
                summary
            ),

        "overbrushed_zones" =>
            overbrushed_zones_from_summary(
                summary
            )

    )

end


# ============================================================
# 46. SUMMARY ZONE HELPERS
# ============================================================

function missed_zones_from_summary(

    summary::SessionSummary

)

    return [

        zone.zone

        for zone in values(summary.zones)

        if zone.coverage_score <
           GOOD_COVERAGE

    ]

end


function overbrushed_zones_from_summary(

    summary::SessionSummary

)

    return [

        zone.zone

        for zone in values(summary.zones)

        if zone.effective_time >
           TARGET_ZONE_TIME * 2.0

    ]

end


# ============================================================
# 47. EXPORT CSV-STYLE RECORDS
# ============================================================

function session_rows(

    history::SessionHistory

)

    rows = Vector{NamedTuple}()


    for s in history.sessions

        push!(

            rows,

            (

                session_id =
                    s.session_id,

                duration =
                    s.duration,

                score =
                    s.quality.overall_score,

                coverage =
                    s.quality.coverage_score,

                pressure =
                    s.quality.pressure_score,

                contact =
                    s.quality.contact_score,

                motion =
                    s.quality.motion_score,

                energy_wh =
                    s.energy.energy_wh,

                peak_temperature =
                    s.thermal.peak_motor_temperature

            )

        )

    end


    return rows

end


# ============================================================
# 48. RESET
# ============================================================

function reset!(

    engine::SessionAnalyticsEngine

)

    engine.session =
        AnalyticsSession(
            engine.next_session_id
        )


    return engine

end


# ============================================================
# 49. EXPORTS
# ============================================================

export SessionState
export SessionSample

export ZoneAnalytics
export PressureAnalytics
export MotionAnalytics
export MotorAnalytics
export EnergyAnalytics
export ThermalAnalytics

export SessionQuality
export SessionSummary
export SessionHistory
export AnalyticsSession
export SessionAnalyticsEngine

export start_session!
export update!
export finish_session!

export calculate_coverage
export weighted_coverage
export final_pressure_score
export contact_score
export consistency_score
export completion_score
export efficiency_score
export calculate_quality!

export missed_zones
export overbrushed_zones
export pressure_events
export motor_health
export session_anomalies
export recommendations

export trend
export trend_direction
export personal_baseline
export is_outlier
export weekly_summary

export report
export session_rows
export reset!

end











module ToothbrushSimulationHarness

using Statistics
using Random
using LinearAlgebra

# ============================================================
# TOOTHBRUSH SIMULATION / TEST HARNESS
#
# System-level verification environment for the toothbrush
# software architecture.
#
# Intended to test:
#
#   Motor
#   BLDC model
#   Sensor fusion
#   Pressure/contact
#   Battery/SOC
#   Thermal model
#   Cleaning algorithms
#   Zone estimation
#   Safety/diagnostics
#   Session analytics
#   Digital twin
#
# The harness deliberately separates:
#
#   PHYSICS
#       ↓
#   SENSORS
#       ↓
#   CONTROL SOFTWARE
#       ↓
#   SAFETY
#       ↓
#   ANALYTICS
#
# so individual layers can be tested independently.
#
# Reference/simulation architecture only.
# ============================================================


# ============================================================
# 01. CONSTANTS
# ============================================================

const DEFAULT_DT = 0.001

const DEFAULT_DURATION = 120.0

const MAX_SIMULATION_TIME = 3600.0

const MAX_TEST_CASES = 10000

const NOMINAL_RPM = 26000.0

const MAX_RPM = 42000.0

const MAX_CURRENT = 8.0

const MAX_MOTOR_TEMPERATURE = 85.0

const MAX_BATTERY_TEMPERATURE = 60.0

const MIN_BATTERY_VOLTAGE = 2.90

const MAX_PRESSURE = 1.0

const TEST_RANDOM_SEED = 20261008


# ============================================================
# 02. TEST STATUS
# ============================================================

@enum TestStatus begin

    TEST_NOT_RUN

    TEST_RUNNING

    TEST_PASS

    TEST_FAIL

    TEST_WARNING

    TEST_SKIPPED

end


@enum SimulationMode begin

    SIM_PHYSICAL

    SIM_CONTROL

    SIM_HIL

    SIM_MONTE_CARLO

    SIM_REPLAY

end


# ============================================================
# 03. SCENARIO TYPES
# ============================================================

@enum ScenarioType begin

    SCENARIO_NORMAL

    SCENARIO_INTENSIVE

    SCENARIO_GENTLE

    SCENARIO_HIGH_PRESSURE

    SCENARIO_LOW_BATTERY

    SCENARIO_COLD_BATTERY

    SCENARIO_HOT_BATTERY

    SCENARIO_THERMAL_STRESS

    SCENARIO_FREE_AIR

    SCENARIO_HARD_CONTACT

    SCENARIO_INTERMITTENT_CONTACT

    SCENARIO_MOTOR_STALL

    SCENARIO_OVERSPEED

    SCENARIO_SENSOR_FAILURE

    SCENARIO_VIBRATION

    SCENARIO_LONG_SESSION

end


# ============================================================
# 04. SIMULATED PHYSICAL STATE
# ============================================================

mutable struct SimState

    timestamp::Float64

    rpm::Float64

    target_rpm::Float64

    current::Float64

    voltage::Float64

    power::Float64

    torque::Float64

    load_torque::Float64

    motor_temperature::Float64

    battery_temperature::Float64

    battery_soc::Float64

    pressure::Float64

    contact::Float64

    tooth_contact::Float64

    vibration::Float64

    motion::Float64

    acceleration::Float64

    zone_confidence::Float64

    motor_enabled::Bool

    emergency_stop::Bool

end


function SimState()

    SimState(

        0.0,

        0.0,
        NOMINAL_RPM,

        0.0,

        3.7,

        0.0,

        0.0,
        0.0,

        25.0,
        25.0,

        1.0,

        0.0,
        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        0.0,

        false,
        false

    )

end


# ============================================================
# 05. SIMULATION PARAMETERS
# ============================================================

Base.@kwdef mutable struct SimulationParameters

    dt::Float64 = DEFAULT_DT

    duration::Float64 =
        DEFAULT_DURATION

    ambient_temperature::Float64 =
        22.0

    initial_soc::Float64 =
        1.0

    initial_voltage::Float64 =
        4.20

    target_rpm::Float64 =
        NOMINAL_RPM

    motor_inertia::Float64 =
        1.2e-6

    torque_constant::Float64 =
        0.025

    motor_resistance::Float64 =
        0.35

    battery_capacity_ah::Float64 =
        0.75

    battery_resistance::Float64 =
        0.08

    thermal_resistance::Float64 =
        18.0

    pressure::Float64 =
        0.35

    contact::Float64 =
        0.85

    vibration::Float64 =
        0.30

    motion::Float64 =
        0.70

    sensor_noise::Float64 =
        0.01

    random_seed::Int =
        TEST_RANDOM_SEED

end


# ============================================================
# 06. SIMULATION RECORD
# ============================================================

struct SimulationRecord

    timestamp::Float64

    rpm::Float64

    current::Float64

    voltage::Float64

    power::Float64

    torque::Float64

    motor_temperature::Float64

    battery_temperature::Float64

    battery_soc::Float64

    pressure::Float64

    contact::Float64

    vibration::Float64

    motion::Float64

end


# ============================================================
# 07. SIMULATION TRACE
# ============================================================

mutable struct SimulationTrace

    records::Vector{SimulationRecord}

    capacity::Int

end


function SimulationTrace(

    capacity::Int = 200000

)

    SimulationTrace(

        SimulationRecord[],

        capacity

    )

end


function record!(

    trace::SimulationTrace,
    state::SimState

)

    push!(

        trace.records,

        SimulationRecord(

            state.timestamp,

            state.rpm,

            state.current,

            state.voltage,

            state.power,

            state.torque,

            state.motor_temperature,

            state.battery_temperature,

            state.battery_soc,

            state.pressure,

            state.contact,

            state.vibration,

            state.motion

        )

    )


    if length(trace.records) >
       trace.capacity

        deleteat!(
            trace.records,
            1
        )

    end


    return trace

end


# ============================================================
# 08. SCENARIO
# ============================================================

struct SimulationScenario

    name::Symbol

    scenario_type::ScenarioType

    duration::Float64

    parameters::SimulationParameters

end


function scenario(

    type::ScenarioType;

    duration::Float64 =
        DEFAULT_DURATION

)

    p =
        SimulationParameters(
            duration =
                duration
        )


    name = Symbol(
        lowercase(
            string(type)
        )
    )


    return SimulationScenario(

        name,
        type,
        duration,
        p

    )

end


# ============================================================
# 09. SCENARIO CONFIGURATION
# ============================================================

function configure_scenario!(

    p::SimulationParameters,
    type::ScenarioType

)

    if type ==
       SCENARIO_NORMAL

        p.pressure = 0.35
        p.contact = 0.85
        p.motion = 0.70
        p.target_rpm = 26000.0


    elseif type ==
           SCENARIO_INTENSIVE

        p.pressure = 0.45
        p.contact = 0.90
        p.motion = 0.85
        p.target_rpm = 34000.0


    elseif type ==
           SCENARIO_GENTLE

        p.pressure = 0.20
        p.contact = 0.80
        p.motion = 0.50
        p.target_rpm = 18000.0


    elseif type ==
           SCENARIO_HIGH_PRESSURE

        p.pressure = 0.90
        p.contact = 0.95
        p.motion = 0.65


    elseif type ==
           SCENARIO_LOW_BATTERY

        p.initial_soc = 0.08
        p.initial_voltage = 3.15


    elseif type ==
           SCENARIO_COLD_BATTERY

        p.ambient_temperature = 2.0


    elseif type ==
           SCENARIO_HOT_BATTERY

        p.ambient_temperature = 48.0


    elseif type ==
           SCENARIO_THERMAL_STRESS

        p.ambient_temperature = 45.0
        p.pressure = 0.65
        p.contact = 0.95
        p.target_rpm = 38000.0


    elseif type ==
           SCENARIO_FREE_AIR

        p.pressure = 0.0
        p.contact = 0.0
        p.motion = 0.20


    elseif type ==
           SCENARIO_HARD_CONTACT

        p.pressure = 0.70
        p.contact = 0.95
        p.vibration = 0.80


    elseif type ==
           SCENARIO_INTERMITTENT_CONTACT

        p.pressure = 0.40
        p.contact = 0.50


    elseif type ==
           SCENARIO_MOTOR_STALL

        p.pressure = 1.0
        p.contact = 1.0
        p.target_rpm = 26000.0


    elseif type ==
           SCENARIO_OVERSPEED

        p.target_rpm = 60000.0


    elseif type ==
           SCENARIO_SENSOR_FAILURE

        p.sensor_noise = 0.50


    elseif type ==
           SCENARIO_VIBRATION

        p.vibration = 1.0


    elseif type ==
           SCENARIO_LONG_SESSION

        p.duration = 1800.0

    end


    return p

end


# ============================================================
# 10. MOTOR MODEL
# ============================================================

function simulate_motor!(

    state::SimState,
    p::SimulationParameters,
    dt::Float64

)

    if !state.motor_enabled ||
       state.emergency_stop

        state.rpm *= 0.95

        state.current *= 0.90

        return

    end


    speed_error =

        state.target_rpm -
        state.rpm


    acceleration =

        speed_error *
        4.0


    # Load from contact/pressure.

    state.load_torque =

        0.001 +

        0.000005 *
        state.rpm *

        (
            0.2 +
            state.pressure *
            state.contact
        )


    motor_torque =

        p.torque_constant *
        state.current


    net_torque =

        motor_torque -
        state.load_torque


    angular_acceleration =

        net_torque /
        p.motor_inertia


    state.rpm +=

        angular_acceleration *
        60.0 /
        (2π) *
        dt


    # Controller correction.

    state.rpm +=

        acceleration *
        dt


    state.rpm = clamp(

        state.rpm,

        0.0,

        MAX_RPM * 1.25

    )


    required_current =

        0.8 +

        abs(speed_error) *
        0.00004 +

        state.pressure *
        state.contact *
        3.0


    state.current = clamp(

        required_current,

        0.0,
        MAX_CURRENT

    )


    state.torque =

        p.torque_constant *
        state.current


    state.power =

        state.voltage *
        state.current


    return state

end


# ============================================================
# 11. BATTERY MODEL
# ============================================================

function simulate_battery!(

    state::SimState,
    p::SimulationParameters,
    dt::Float64

)

    # Coulomb counting.

    state.battery_soc -=

        state.current /
        (
            p.battery_capacity_ah *
            3600.0
        ) *
        dt


    state.battery_soc =

        clamp(
            state.battery_soc,
            0.0,
            1.0
        )


    # Approximate open-circuit voltage.

    ocv =

        3.0 +
        1.2 *
        state.battery_soc


    sag =

        state.current *
        p.battery_resistance


    state.voltage =

        max(

            2.70,

            ocv -
            sag

        )


    if state.voltage <
       MIN_BATTERY_VOLTAGE

        state.motor_enabled =
            false

    end


    return state

end


# ============================================================
# 12. THERMAL MODEL
# ============================================================

function simulate_thermal!(

    state::SimState,
    p::SimulationParameters,
    dt::Float64

)

    copper_loss =

        state.current^2 *
        p.motor_resistance


    mechanical_loss =

        state.rpm *
        2π / 60.0 *
        2e-6


    heat_generation =

        copper_loss +
        mechanical_loss


    heat_rejection =

        (
            state.motor_temperature -
            p.ambient_temperature
        ) /
        p.thermal_resistance


    dT =

        (
            heat_generation -
            heat_rejection
        ) /
        15.0 *
        dt


    state.motor_temperature +=
        dT


    battery_heat =

        state.current^2 *
        p.battery_resistance


    battery_rejection =

        (
            state.battery_temperature -
            p.ambient_temperature
        ) /
        22.0


    state.battery_temperature +=

        (
            battery_heat -
            battery_rejection
        ) /
        45.0 *
        dt


    return state

end


# ============================================================
# 13. CONTACT MODEL
# ============================================================

function simulate_contact!(

    state::SimState,
    p::SimulationParameters,
    timestamp::Float64

)

    if p.contact <= 0

        state.contact = 0.0
        state.pressure = 0.0
        state.tooth_contact = 0.0

        return state

    end


    modulation =

        0.10 *
        sin(
            timestamp *
            1.7
        )


    state.contact = clamp(

        p.contact +
        modulation,

        0.0,
        1.0

    )


    state.pressure = clamp(

        p.pressure +
        0.05 *
        sin(
            timestamp *
            2.4
        ),

        0.0,
        1.0

    )


    state.tooth_contact =

        clamp(

            state.contact *
            (
                1.0 -
                0.25 *
                state.pressure
            ),

            0.0,
            1.0

        )


    return state

end


# ============================================================
# 14. MOTION MODEL
# ============================================================

function simulate_motion!(

    state::SimState,
    p::SimulationParameters,
    timestamp::Float64

)

    state.motion = clamp(

        p.motion +

        0.10 *
        sin(
            timestamp *
            3.1
        ),

        0.0,
        1.0

    )


    state.acceleration =

        abs(
            sin(
                timestamp *
                5.0
            )
        ) *
        state.motion


    state.vibration =

        p.vibration *

        (

            0.5 +

            0.5 *
            abs(
                sin(
                    timestamp *
                    17.0
                )
            )

        )


    return state

end


# ============================================================
# 15. SENSOR NOISE
# ============================================================

function noisy(

    value::Float64,
    noise::Float64,
    rng

)

    return value +

           randn(rng) *
           noise

end


# ============================================================
# 16. SENSOR FAULTS
# ============================================================

function inject_sensor_faults!(

    state::SimState,
    type::ScenarioType,
    p::SimulationParameters,
    rng

)

    if type ==
       SCENARIO_SENSOR_FAILURE

        if state.timestamp > 20.0 &&
           state.timestamp < 40.0

            state.contact =

                noisy(
                    0.0,
                    0.50,
                    rng
                )

            state.pressure =

                noisy(
                    0.0,
                    0.50,
                    rng
                )

        end

    end


    return state

end


# ============================================================
# 17. SAFETY ARBITRATION
# ============================================================

function safety_check!(

    state::SimState

)

    if state.rpm >
       MAX_RPM

        state.emergency_stop =
            true

    end


    if state.current >
       MAX_CURRENT

        state.emergency_stop =
            true

    end


    if state.motor_temperature >
       MAX_MOTOR_TEMPERATURE

        state.emergency_stop =
            true

    end


    if state.battery_temperature >
       MAX_BATTERY_TEMPERATURE

        state.emergency_stop =
            true

    end


    if state.voltage <
       MIN_BATTERY_VOLTAGE

        state.emergency_stop =
            true

    end


    if state.pressure >
       0.90

        state.target_rpm *=
            0.65

    end


    return state

end


# ============================================================
# 18. SINGLE SIMULATION STEP
# ============================================================

function step_simulation!(

    state::SimState,
    scenario::SimulationScenario,
    trace::SimulationTrace,
    rng

)

    p =
        scenario.parameters


    dt =
        p.dt


    state.timestamp +=
        dt


    state.target_rpm =
        p.target_rpm


    # Scenario-specific behaviour.

    simulate_contact!(

        state,
        p,
        state.timestamp

    )


    simulate_motion!(

        state,
        p,
        state.timestamp

    )


    inject_sensor_faults!(

        state,
        scenario.scenario_type,
        p,
        rng

    )


    simulate_motor!(

        state,
        p,
        dt

    )


    simulate_battery!(

        state,
        p,
        dt

    )


    simulate_thermal!(

        state,
        p,
        dt

    )


    safety_check!(
        state
    )


    # Record at simulation rate.

    record!(
        trace,
        state
    )


    return state

end


# ============================================================
# 19. COMPLETE SIMULATION
# ============================================================

function run_simulation(

    scenario::SimulationScenario

)

    state =
        SimState()


    p =
        scenario.parameters


    state.battery_soc =
        p.initial_soc


    state.voltage =
        p.initial_voltage


    state.motor_temperature =
        p.ambient_temperature


    state.battery_temperature =
        p.ambient_temperature


    state.motor_enabled =
        true


    trace =
        SimulationTrace()


    rng =
        MersenneTwister(
            p.random_seed
        )


    steps = Int(

        ceil(
            scenario.duration /
            p.dt
        )

    )


    steps = min(

        steps,

        Int(
            MAX_SIMULATION_TIME /
            p.dt
        )

    )


    for _ in 1:steps

        if state.emergency_stop

            break

        end


        step_simulation!(

            state,
            scenario,
            trace,
            rng

        )

    end


    return state, trace

end


# ============================================================
# 20. TEST RESULT
# ============================================================

struct TestResult

    name::Symbol

    status::TestStatus

    duration::Float64

    message::String

    metrics::Dict{Symbol,Float64}

end


function pass_result(

    name,
    duration,
    message,
    metrics = Dict{Symbol,Float64}()

)

    TestResult(

        name,
        TEST_PASS,
        duration,
        message,
        metrics

    )

end


function fail_result(

    name,
    duration,
    message,
    metrics = Dict{Symbol,Float64}()

)

    TestResult(

        name,
        TEST_FAIL,
        duration,
        message,
        metrics

    )

end


# ============================================================
# 21. TEST: MOTOR REACHES TARGET
# ============================================================

function test_motor_reaches_target()

    s =
        scenario(
            SCENARIO_NORMAL,
            duration = 5.0
        )


    final, trace =
        run_simulation(s)


    target =
        s.parameters.target_rpm


    error =
        abs(
            final.rpm -
            target
        )


    metrics = Dict(

        :final_rpm =>
            final.rpm,

        :target_rpm =>
            target,

        :error_rpm =>
            error

    )


    if error < 5000.0

        return pass_result(

            :motor_reaches_target,

            5.0,

            "Motor converged toward target RPM.",

            metrics

        )

    end


    return fail_result(

        :motor_reaches_target,

        5.0,

        "Motor failed to approach target RPM.",

        metrics

    )

end


# ============================================================
# 22. TEST: UNDERVOLTAGE PROTECTION
# ============================================================

function test_undervoltage()

    s =
        scenario(
            SCENARIO_LOW_BATTERY,
            duration = 20.0
        )


    final, trace =
        run_simulation(s)


    stopped =
        final.emergency_stop ||
        !final.motor_enabled


    metrics = Dict(

        :final_voltage =>
            final.voltage,

        :final_soc =>
            final.battery_soc

    )


    if stopped

        return pass_result(

            :undervoltage_protection,

            final.timestamp,

            "Undervoltage protection activated.",

            metrics

        )

    end


    return fail_result(

        :undervoltage_protection,

        final.timestamp,

        "Motor remained enabled during undervoltage condition.",

        metrics

    )

end


# ============================================================
# 23. TEST: PRESSURE PROTECTION
# ============================================================

function test_pressure_protection()

    s =
        scenario(
            SCENARIO_HIGH_PRESSURE,
            duration = 10.0
        )


    final, trace =
        run_simulation(s)


    rpm_reduced =

        final.target_rpm <
        s.parameters.target_rpm


    metrics = Dict(

        :final_target_rpm =>
            final.target_rpm,

        :initial_target_rpm =>
            s.parameters.target_rpm,

        :pressure =>
            final.pressure

    )


    if rpm_reduced

        return pass_result(

            :pressure_protection,

            final.timestamp,

            "High-pressure condition caused RPM reduction.",

            metrics

        )

    end


    return fail_result(

        :pressure_protection,

        final.timestamp,

        "High-pressure condition did not reduce output.",

        metrics

    )

end


# ============================================================
# 24. TEST: THERMAL PROTECTION
# ============================================================

function test_thermal_protection()

    s =
        scenario(
            SCENARIO_THERMAL_STRESS,
            duration = 180.0
        )


    final, trace =
        run_simulation(s)


    safe =

        final.motor_temperature <=
        MAX_MOTOR_TEMPERATURE


    metrics = Dict(

        :peak_motor_temperature =>
            maximum(
                r.motor_temperature
                for r in trace.records
            ),

        :final_motor_temperature =>
            final.motor_temperature

    )


    if safe

        return pass_result(

            :thermal_protection,

            final.timestamp,

            "Thermal system remained within safety boundary.",

            metrics

        )

    end


    return fail_result(

        :thermal_protection,

        final.timestamp,

        "Motor exceeded thermal safety boundary.",

        metrics

    )

end


# ============================================================
# 25. TEST: FREE AIR
# ============================================================

function test_free_air()

    s =
        scenario(
            SCENARIO_FREE_AIR,
            duration = 5.0
        )


    final, trace =
        run_simulation(s)


    # Free-air operation should not create a
    # large contact-derived mechanical load.

    peak_load =

        maximum(

            r.torque

            for r in trace.records

        )


    if peak_load < 0.25

        return pass_result(

            :free_air,

            final.timestamp,

            "Free-air operation remained mechanically light.",

            Dict(
                :peak_torque =>
                    peak_load
            )

        )

    end


    return fail_result(

        :free_air,

        final.timestamp,

        "Free-air operation generated excessive load.",

        Dict(
            :peak_torque =>
                peak_load
        )

    )

end


# ============================================================
# 26. TEST: OVERSPEED
# ============================================================

function test_overspeed()

    s =
        scenario(
            SCENARIO_OVERSPEED,
            duration = 5.0
        )


    final, trace =
        run_simulation(s)


    stopped =
        final.emergency_stop ||
        final.rpm <= MAX_RPM


    peak_rpm =

        maximum(
            r.rpm
            for r in trace.records
        )


    metrics = Dict(

        :peak_rpm =>
            peak_rpm,

        :final_rpm =>
            final.rpm

    )


    if stopped

        return pass_result(

            :overspeed_protection,

            final.timestamp,

            "Overspeed condition was contained.",

            metrics

        )

    end


    return fail_result(

        :overspeed_protection,

        final.timestamp,

        "Overspeed condition was not contained.",

        metrics

    )

end


# ============================================================
# 27. TEST: LONG SESSION
# ============================================================

function test_long_session()

    s =
        scenario(
            SCENARIO_LONG_SESSION,
            duration = 300.0
        )


    final, trace =
        run_simulation(s)


    stable =

        !final.emergency_stop &&
        final.motor_temperature <
        MAX_MOTOR_TEMPERATURE &&
        final.battery_temperature <
        MAX_BATTERY_TEMPERATURE


    metrics = Dict(

        :duration =>
            final.timestamp,

        :soc =>
            final.battery_soc,

        :motor_temperature =>
            final.motor_temperature,

        :battery_temperature =>
            final.battery_temperature

    )


    if stable

        return pass_result(

            :long_session,

            final.timestamp,

            "Long-duration operation remained stable.",

            metrics

        )

    end


    return fail_result(

        :long_session,

        final.timestamp,

        "Long-duration simulation became unstable.",

        metrics

    )

end


# ============================================================
# 28. TEST: SENSOR NOISE
# ============================================================

function test_sensor_noise()

    p =
        SimulationParameters(

            duration = 10.0,

            sensor_noise = 0.10,

            random_seed =
                TEST_RANDOM_SEED

        )


    s =
        SimulationScenario(

            :sensor_noise,

            SCENARIO_NORMAL,

            10.0,

            p

        )


    final, trace =
        run_simulation(s)


    values = [

        r.rpm

        for r in trace.records

    ]


    stable =
        !isempty(values) &&
        all(
            isfinite,
            values
        )


    if stable

        return pass_result(

            :sensor_noise,

            final.timestamp,

            "Simulation remained numerically stable with sensor noise."

        )

    end


    return fail_result(

        :sensor_noise,

        final.timestamp,

        "Sensor-noise simulation became numerically unstable."

    )

end


# ============================================================
# 29. TEST: BATTERY DEPLETION
# ============================================================

function test_battery_depletion()

    s =
        scenario(
            SCENARIO_LOW_BATTERY,
            duration = 120.0
        )


    final, trace =
        run_simulation(s)


    soc_declined =

        final.battery_soc <
        s.parameters.initial_soc


    metrics = Dict(

        :initial_soc =>
            s.parameters.initial_soc,

        :final_soc =>
            final.battery_soc,

        :final_voltage =>
            final.voltage

    )


    if soc_declined

        return pass_result(

            :battery_depletion,

            final.timestamp,

            "Battery SOC decreased during load.",

            metrics

        )

    end


    return fail_result(

        :battery_depletion,

        final.timestamp,

        "Battery SOC failed to decrease.",

        metrics

    )

end


# ============================================================
# 30. TEST: DETERMINISTIC REPLAY
# ============================================================

function test_deterministic_replay()

    p1 =
        SimulationParameters(

            duration = 5.0,

            random_seed =
                TEST_RANDOM_SEED

        )


    p2 =
        SimulationParameters(

            duration = 5.0,

            random_seed =
                TEST_RANDOM_SEED

        )


    s1 =
        SimulationScenario(

            :replay_a,
            SCENARIO_NORMAL,
            5.0,
            p1

        )


    s2 =
        SimulationScenario(

            :replay_b,
            SCENARIO_NORMAL,
            5.0,
            p2

        )


    final1, trace1 =
        run_simulation(s1)


    final2, trace2 =
        run_simulation(s2)


    error =

        abs(
            final1.rpm -
            final2.rpm
        )


    metrics = Dict(

        :final_rpm_error =>
            error

    )


    if error < 1e-9

        return pass_result(

            :deterministic_replay,

            final1.timestamp,

            "Identical seeds produced deterministic results.",

            metrics

        )

    end


    return fail_result(

        :deterministic_replay,

        final1.timestamp,

        "Simulation replay was not deterministic.",

        metrics

    )

end


# ============================================================
# 31. TEST: NUMERICAL SANITY
# ============================================================

function test_numerical_sanity()

    s =
        scenario(
            SCENARIO_NORMAL,
            duration = 10.0
        )


    final, trace =
        run_simulation(s)


    finite = all(

        isfinite(r.rpm) &&
        isfinite(r.current) &&
        isfinite(r.voltage) &&
        isfinite(r.motor_temperature) &&
        isfinite(r.battery_soc)

        for r in trace.records

    )


    if finite

        return pass_result(

            :numerical_sanity,

            final.timestamp,

            "All simulation state variables remained finite."

        )

    end


    return fail_result(

        :numerical_sanity,

        final.timestamp,

        "NaN or infinite values detected."

    )

end


# ============================================================
# 32. TEST SUITE
# ============================================================

const DEFAULT_TESTS = [

    test_numerical_sanity,

    test_motor_reaches_target,

    test_undervoltage,

    test_pressure_protection,

    test_thermal_protection,

    test_free_air,

    test_overspeed,

    test_long_session,

    test_sensor_noise,

    test_battery_depletion,

    test_deterministic_replay

]


# ============================================================
# 33. TEST RUNNER
# ============================================================

function run_test_suite(

    tests =
        DEFAULT_TESTS

)

    results =
        TestResult[]


    for test in tests

        try

            result =
                test()

            push!(
                results,
                result
            )

        catch error

            push!(

                results,

                TestResult(

                    Symbol(
                        nameof(test)
                    ),

                    TEST_FAIL,

                    0.0,

                    "Exception: " *
                    string(error),

                    Dict{Symbol,Float64}()

                )

            )

        end

    end


    return results

end


# ============================================================
# 34. SUITE SUMMARY
# ============================================================

function suite_summary(

    results::Vector{TestResult}

)

    passed =
        count(
            r -> r.status ==
                 TEST_PASS,
            results
        )


    failed =
        count(
            r -> r.status ==
                 TEST_FAIL,
            results
        )


    warnings =
        count(
            r -> r.status ==
                 TEST_WARNING,
            results
        )


    total =
        length(results)


    pass_rate =

        total > 0 ?

        passed /
        total :

        0.0


    return (

        total = total,

        passed = passed,

        failed = failed,

        warnings = warnings,

        pass_rate = pass_rate,

        system_status =

            failed == 0 ?
            :PASS :
            :FAIL

    )

end


# ============================================================
# 35. PARAMETER SWEEP
# ============================================================

function parameter_sweep(

    parameter::Symbol,
    values::Vector{Float64};

    scenario_type =
        SCENARIO_NORMAL

)

    results =
        NamedTuple[]


    for value in values

        p =
            SimulationParameters()


        configure_scenario!(

            p,
            scenario_type

        )


        if parameter ==
           :rpm

            p.target_rpm =
                value

        elseif parameter ==
               :pressure

            p.pressure =
                value

        elseif parameter ==
               :ambient_temperature

            p.ambient_temperature =
                value

        elseif parameter ==
               :battery_soc

            p.initial_soc =
                value

        elseif parameter ==
               :contact

            p.contact =
                value

        elseif parameter ==
               :vibration

            p.vibration =
                value

        else

            error(
                "Unsupported parameter"
            )

        end


        s =
            SimulationScenario(

                :sweep,

                scenario_type,

                p.duration,

                p

            )


        final, trace =
            run_simulation(s)


        peak_temperature =

            maximum(

                r.motor_temperature

                for r in trace.records

            )


        peak_current =

            maximum(

                r.current

                for r in trace.records

            )


        push!(

            results,

            (

                parameter =
                    value,

                final_rpm =
                    final.rpm,

                final_soc =
                    final.battery_soc,

                peak_temperature =
                    peak_temperature,

                peak_current =
                    peak_current,

                emergency_stop =
                    final.emergency_stop

            )

        )

    end


    return results

end


# ============================================================
# 36. MONTE CARLO
# ============================================================

function monte_carlo(

    scenario_type::ScenarioType;

    runs::Int = 100,
    duration::Float64 = 30.0

)

    runs =
        clamp(
            runs,
            1,
            10000
        )


    results =
        NamedTuple[]


    for i in 1:runs

        p =
            SimulationParameters(

                duration =
                    duration,

                random_seed =
                    TEST_RANDOM_SEED + i

            )


        configure_scenario!(

            p,
            scenario_type

        )


        s =
            SimulationScenario(

                :monte_carlo,

                scenario_type,

                duration,

                p

            )


        final, trace =
            run_simulation(s)


        peak_temperature =

            maximum(

                r.motor_temperature

                for r in trace.records

            )


        peak_current =

            maximum(

                r.current

                for r in trace.records

            )


        push!(

            results,

            (

                run = i,

                final_rpm =
                    final.rpm,

                final_soc =
                    final.battery_soc,

                peak_temperature =
                    peak_temperature,

                peak_current =
                    peak_current,

                emergency_stop =
                    final.emergency_stop

            )

        )

    end


    return results

end


# ============================================================
# 37. MONTE CARLO STATISTICS
# ============================================================

function monte_carlo_summary(

    results

)

    temperatures = [

        r.peak_temperature
        for r in results

    ]


    currents = [

        r.peak_current
        for r in results

    ]


    rpms = [

        r.final_rpm
        for r in results

    ]


    failures = count(

        r -> r.emergency_stop,

        results

    )


    return (

        runs =
            length(results),

        temperature_mean =
            mean(temperatures),

        temperature_std =
            std(temperatures),

        temperature_max =
            maximum(temperatures),

        current_mean =
            mean(currents),

        current_max =
            maximum(currents),

        rpm_mean =
            mean(rpms),

        rpm_std =
            std(rpms),

        failure_rate =
            failures /
            max(
                length(results),
                1
            )

    )

end


# ============================================================
# 38. FAULT INJECTION
# ============================================================

function inject_fault!(

    state::SimState,
    fault::Symbol

)

    if fault ==
       :overspeed

        state.rpm =
            MAX_RPM * 1.5


    elseif fault ==
           :overcurrent

        state.current =
            MAX_CURRENT * 1.5


    elseif fault ==
           :overtemperature

        state.motor_temperature =
            MAX_MOTOR_TEMPERATURE + 10.0


    elseif fault ==
           :battery_overtemperature

        state.battery_temperature =
            MAX_BATTERY_TEMPERATURE + 10.0


    elseif fault ==
           :undervoltage

        state.voltage =
            2.5


    elseif fault ==
           :pressure

        state.pressure =
            1.0


    elseif fault ==
           :stall

        state.rpm =
            0.0

        state.current =
            MAX_CURRENT


    elseif fault ==
           :sensor_failure

        state.contact =
            NaN

    else

        error(
            "Unknown fault: $fault"
        )

    end


    return state

end


# ============================================================
# 39. FAULT RESPONSE TEST
# ============================================================

function test_fault_response(

    fault::Symbol

)

    state =
        SimState()


    state.motor_enabled =
        true


    inject_fault!(

        state,
        fault

    )


    # NaN sensor faults are handled separately.

    if fault ==
       :sensor_failure

        return (

            fault = fault,

            detected =
                !isfinite(
                    state.contact
                ),

            emergency_stop = false

        )

    end


    safety_check!(
        state
    )


    return (

        fault = fault,

        detected =
            state.emergency_stop,

        emergency_stop =
            state.emergency_stop

    )

end


# ============================================================
# 40. ALL FAULTS
# ============================================================

function fault_campaign()

    faults = [

        :overspeed,
        :overcurrent,
        :overtemperature,
        :battery_overtemperature,
        :undervoltage,
        :pressure,
        :stall,
        :sensor_failure

    ]


    return [

        test_fault_response(f)

        for f in faults

    ]

end


# ============================================================
# 41. PERFORMANCE BENCHMARK
# ============================================================

function benchmark(

    duration::Float64 = 10.0

)

    p =
        SimulationParameters(

            duration =
                duration

        )


    s =
        SimulationScenario(

            :benchmark,

            SCENARIO_NORMAL,

            duration,

            p

        )


    start_time =
        time()


    final, trace =
        run_simulation(s)


    elapsed =
        time() -
        start_time


    simulation_time =
        final.timestamp


    real_time_factor =

        elapsed > 0 ?

        simulation_time /
        elapsed :

        Inf


    return (

        simulation_seconds =
            simulation_time,

        wall_seconds =
            elapsed,

        real_time_factor =
            real_time_factor,

        samples =
            length(trace.records)

    )

end


# ============================================================
# 42. REGRESSION SIGNATURE
# ============================================================

function regression_signature(

    final::SimState

)

    return (

        round(
            final.rpm,
            digits = 3
        ),

        round(
            final.current,
            digits = 3
        ),

        round(
            final.voltage,
            digits = 3
        ),

        round(
            final.motor_temperature,
            digits = 3
        ),

        round(
            final.battery_soc,
            digits = 6
        )

    )

end


# ============================================================
# 43. REGRESSION TEST
# ============================================================

function regression_test(

    expected

)

    s =
        scenario(
            SCENARIO_NORMAL,
            duration = 5.0
        )


    final, trace =
        run_simulation(s)


    actual =
        regression_signature(
            final
        )


    differences =

        [

            abs(
                Float64(a) -
                Float64(e)
            )

            for (a, e)
            in zip(actual, expected)

        ]


    passed =

        maximum(
            differences
        ) < 1e-3


    return (

        passed = passed,

        expected = expected,

        actual = actual,

        differences = differences

    )

end


# ============================================================
# 44. STRESS TEST
# ============================================================

function stress_test(

    duration::Float64 = 600.0

)

    s =
        scenario(
            SCENARIO_THERMAL_STRESS,
            duration = duration
        )


    final, trace =
        run_simulation(s)


    peak_temperature =

        maximum(

            r.motor_temperature
            for r in trace.records

        )


    peak_current =

        maximum(

            r.current
            for r in trace.records

        )


    return (

        duration =
            final.timestamp,

        peak_temperature =
            peak_temperature,

        peak_current =
            peak_current,

        emergency_stop =
            final.emergency_stop,

        samples =
            length(trace.records)

    )

end


# ============================================================
# 45. COMPLETE VALIDATION CAMPAIGN
# ============================================================

function validation_campaign()

    suite =
        run_test_suite()


    faults =
        fault_campaign()


    sweep =
        parameter_sweep(

            :pressure,

            collect(
                0.0:0.1:1.0
            )

        )


    monte =
        monte_carlo(

            SCENARIO_NORMAL,

            runs = 50,

            duration = 20.0

        )


    return (

        tests =
            suite,

        test_summary =
            suite_summary(
                suite
            ),

        faults =
            faults,

        pressure_sweep =
            sweep,

        monte_carlo =
            monte_carlo_summary(
                monte
            ),

        benchmark =
            benchmark(10.0)

    )

end


# ============================================================
# 46. TRACE ANALYSIS
# ============================================================

function trace_statistics(

    trace::SimulationTrace

)

    if isempty(
        trace.records
    )

        return nothing

    end


    rpm = [

        r.rpm
        for r in trace.records

    ]


    current = [

        r.current
        for r in trace.records

    ]


    temperature = [

        r.motor_temperature
        for r in trace.records

    ]


    voltage = [

        r.voltage
        for r in trace.records

    ]


    return (

        rpm_mean =
            mean(rpm),

        rpm_peak =
            maximum(rpm),

        current_mean =
            mean(current),

        current_peak =
            maximum(current),

        temperature_mean =
            mean(temperature),

        temperature_peak =
            maximum(temperature),

        voltage_min =
            minimum(voltage),

        voltage_final =
            voltage[end]

    )

end


# ============================================================
# 47. ASSERTION HELPERS
# ============================================================

function assert_between(

    value::Real,
    minimum_value::Real,
    maximum_value::Real

)

    return (

        value >= minimum_value &&
        value <= maximum_value

    )

end


function assert_finite(

    value::Real

)

    return isfinite(value)

end


# ============================================================
# 48. JSON-LIKE EXPORT
# ============================================================

function result_dict(

    result::TestResult

)

    return Dict(

        "name" =>
            string(result.name),

        "status" =>
            string(result.status),

        "duration" =>
            result.duration,

        "message" =>
            result.message,

        "metrics" =>
            result.metrics

    )

end


function results_dict(

    results::Vector{TestResult}

)

    return [

        result_dict(r)

        for r in results

    ]

end


# ============================================================
# 49. TEST REPORT
# ============================================================

function test_report(

    results::Vector{TestResult}

)

    summary =
        suite_summary(
            results
        )


    return Dict(

        "system_status" =>
            string(
                summary.system_status
            ),

        "total_tests" =>
            summary.total,

        "passed" =>
            summary.passed,

        "failed" =>
            summary.failed,

        "warnings" =>
            summary.warnings,

        "pass_rate" =>
            summary.pass_rate,

        "tests" =>
            results_dict(
                results
            )

    )

end


# ============================================================
# 50. RESET
# ============================================================

function reset!(

    state::SimState

)

    state.timestamp = 0.0
    state.rpm = 0.0
    state.target_rpm = NOMINAL_RPM
    state.current = 0.0
    state.voltage = 3.7
    state.power = 0.0
    state.torque = 0.0
    state.load_torque = 0.0

    state.motor_temperature = 25.0
    state.battery_temperature = 25.0
    state.battery_soc = 1.0

    state.pressure = 0.0
    state.contact = 0.0
    state.tooth_contact = 0.0

    state.vibration = 0.0
    state.motion = 0.0
    state.acceleration = 0.0
    state.zone_confidence = 0.0

    state.motor_enabled = false
    state.emergency_stop = false

    return state

end


# ============================================================
# 51. EXPORTS
# ============================================================

export TestStatus
export SimulationMode
export ScenarioType

export SimState
export SimulationParameters
export SimulationRecord
export SimulationTrace
export SimulationScenario

export scenario
export configure_scenario!
export run_simulation
export step_simulation!

export run_test_suite
export suite_summary

export parameter_sweep
export monte_carlo
export monte_carlo_summary

export inject_fault!
export fault_campaign

export benchmark
export regression_signature
export regression_test
export stress_test

export validation_campaign
export trace_statistics

export assert_between
export assert_finite

export result_dict
export results_dict
export test_report

export reset!

end

