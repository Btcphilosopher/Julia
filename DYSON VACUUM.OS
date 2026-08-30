# DYSON VACUUM.OS

## Pure Julia Intelligent Cordless Vacuum Control System

```julia
module VacuumOS

using Dates
using Printf
using Statistics


# ============================================================
# VACUUM.OS
# ============================================================
#
# Intelligent cordless vacuum control / simulation platform
#
# CORE SYSTEMS
#
#   Motor control
#   Suction optimisation
#   Brush-bar control
#   Battery management
#   Dust-bin monitoring
#   Filter monitoring
#   Blockage detection
#   Thermal protection
#   Surface detection
#   Auto power mode
#   Telemetry
#   Predictive maintenance
#   Digital dashboard
#
# Pure Julia — standard library only.
#
# ============================================================


# ============================================================
# MACHINE STATES
# ============================================================

@enum VacuumState begin
    OFF
    STARTING
    AUTO
    ECO
    BOOST
    PAUSED
    OVERHEAT
    BLOCKAGE
    LOW_BATTERY
    FILTER_SERVICE
    BIN_FULL
    ERROR
end


# ============================================================
# SURFACE CLASSIFICATION
# ============================================================

@enum SurfaceType begin
    UNKNOWN
    HARD_FLOOR
    CARPET
    DEEP_CARPET
    FABRIC
end


# ============================================================
# SENSORS
# ============================================================

mutable struct Sensors

    motor_rpm::Float64
    motor_current_a::Float64
    motor_temperature_c::Float64

    inlet_pressure_kpa::Float64
    outlet_pressure_kpa::Float64

    airflow_l_s::Float64
    suction_kpa::Float64

    brush_load::Float64
    brush_rpm::Float64

    dust_density::Float64
    bin_fill_percent::Float64

    filter_pressure_drop_kpa::Float64
    filter_efficiency::Float64

    battery_voltage_v::Float64
    battery_current_a::Float64
    battery_temperature_c::Float64
    battery_percent::Float64

    ambient_temperature_c::Float64

    surface::SurfaceType

end


function Sensors()

    Sensors(

        0.0,
        0.0,
        22.0,

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

        25.2,
        0.0,
        22.0,
        100.0,

        21.0,

        UNKNOWN
    )

end


# ============================================================
# BATTERY MANAGEMENT SYSTEM
# ============================================================

mutable struct Battery

    capacity_wh::Float64
    remaining_wh::Float64

    voltage_v::Float64
    current_a::Float64

    temperature_c::Float64

    cycle_count::Int

    state_of_charge::Float64
    state_of_health::Float64

    charging::Bool

end


function Battery(;

    capacity_wh=100.0

)

    Battery(

        capacity_wh,
        capacity_wh,

        25.2,
        0.0,

        22.0,

        0,

        100.0,
        100.0,

        false

    )

end


function battery_update!(

    battery::Battery,

    power_w::Float64,

    dt::Float64

)

    energy_used =

        max(power_w, 0.0) *

        dt / 3600.0


    battery.remaining_wh -=

        energy_used


    battery.remaining_wh =

        clamp(

            battery.remaining_wh,

            0.0,

            battery.capacity_wh

        )


    battery.state_of_charge =

        100.0 *

        battery.remaining_wh /
        battery.capacity_wh


    battery.current_a =

        power_w /
        max(battery.voltage_v, 1.0)


end


# ============================================================
# MOTOR CONTROLLER
# ============================================================

mutable struct MotorController

    target_rpm::Float64
    actual_rpm::Float64

    power_percent::Float64

    kp::Float64
    ki::Float64
    kd::Float64

    integral::Float64
    previous_error::Float64

end


function MotorController()

    MotorController(

        0.0,
        0.0,

        0.0,

        0.08,
        0.002,
        0.01,

        0.0,
        0.0

    )

end


function set_motor_target!(

    motor::MotorController,

    rpm::Float64

)

    motor.target_rpm =

        clamp(

            rpm,

            0.0,

            125000.0

        )

end


function motor_control!(

    motor::MotorController,

    dt::Float64

)

    error =

        motor.target_rpm -
        motor.actual_rpm


    motor.integral +=

        error * dt


    derivative =

        (

            error -
            motor.previous_error

        ) /

        max(dt, 0.001)


    output =

        motor.kp * error +

        motor.ki * motor.integral +

        motor.kd * derivative


    motor.power_percent =

        clamp(

            output,

            0.0,
            100.0

        )


    motor.previous_error =

        error


    motor.actual_rpm +=

        (

            motor.target_rpm -
            motor.actual_rpm

        ) *

        min(

            dt * 4.0,

            1.0

        )

end


# ============================================================
# SUCTION MODEL
# ============================================================

mutable struct SuctionSystem

    target_suction_kpa::Float64

    actual_suction_kpa::Float64

    target_airflow_l_s::Float64

    actual_airflow_l_s::Float64

    efficiency::Float64

end


function SuctionSystem()

    SuctionSystem(

        8.0,
        0.0,

        30.0,
        0.0,

        1.0

    )

end


function calculate_suction!(

    suction::SuctionSystem,

    motor::MotorController,

    sensors::Sensors

)

    motor_factor =

        motor.actual_rpm /
        125000.0


    filter_factor =

        clamp(

            1.0 -

            sensors.filter_pressure_drop_kpa /
            15.0,

            0.2,
            1.0

        )


    blockage_factor =

        clamp(

            1.0 -

            sensors.brush_load * 0.3,

            0.5,
            1.0

        )


    suction.actual_suction_kpa =

        30.0 *

        motor_factor *

        filter_factor *

        blockage_factor


    suction.actual_airflow_l_s =

        55.0 *

        motor_factor *

        filter_factor *

        blockage_factor

end


# ============================================================
# BRUSH BAR
# ============================================================

mutable struct BrushBar

    enabled::Bool

    target_rpm::Float64
    actual_rpm::Float64

    load::Float64

    anti_tangle::Bool

    jam_detected::Bool

end


function BrushBar()

    BrushBar(

        false,

        0.0,
        0.0,

        0.0,

        true,
        false

    )

end


function update_brush!(

    brush::BrushBar,

    surface::SurfaceType,

    dt::Float64

)

    if !brush.enabled

        brush.target_rpm = 0.0

    elseif surface == HARD_FLOOR

        brush.target_rpm = 4200.0

    elseif surface == CARPET

        brush.target_rpm = 5200.0

    elseif surface == DEEP_CARPET

        brush.target_rpm = 5800.0

    elseif surface == FABRIC

        brush.target_rpm = 3500.0

    else

        brush.target_rpm = 4000.0

    end


    brush.actual_rpm +=

        (

            brush.target_rpm -
            brush.actual_rpm

        ) *

        min(

            dt * 3.0,

            1.0

        )


    # Simulated brush load.

    brush.load =

        if surface == DEEP_CARPET
            0.75
        elseif surface == CARPET
            0.50
        elseif surface == HARD_FLOOR
            0.20
        else
            0.30
        end


    brush.jam_detected =

        brush.enabled &&

        brush.actual_rpm <

        brush.target_rpm * 0.35 &&

        brush.target_rpm > 0

end


# ============================================================
# DUST / BIN SYSTEM
# ============================================================

mutable struct DustSystem

    bin_capacity_l::Float64
    dust_mass_g::Float64

    intake_rate_g_s::Float64

    dust_concentration::Float64

end


function DustSystem()

    DustSystem(

        0.76,

        0.0,

        0.0,

        0.0

    )

end


function update_dust!(

    dust::DustSystem,

    sensors::Sensors,

    dt::Float64

)

    dust.intake_rate_g_s =

        sensors.dust_density *

        sensors.airflow_l_s *

        0.002


    dust.dust_mass_g +=

        dust.intake_rate_g_s *

        dt


    dust.dust_mass_g =

        min(

            dust.dust_mass_g,

            dust.bin_capacity_l * 600.0

        )


    dust.dust_concentration =

        sensors.dust_density

end


function bin_fill_percent(

    dust::DustSystem

)

    return clamp(

        100.0 *

        dust.dust_mass_g /
        (dust.bin_capacity_l * 600.0),

        0.0,
        100.0

    )

end


# ============================================================
# FILTER SYSTEM
# ============================================================

mutable struct FilterSystem

    efficiency::Float64

    pressure_drop_kpa::Float64

    contamination::Float64

    service_threshold::Float64

end


function FilterSystem()

    FilterSystem(

        99.97,

        0.0,

        0.0,

        0.85

    )

end


function update_filter!(

    filter::FilterSystem,

    dust::DustSystem,

    airflow::Float64

)

    filter.contamination =

        clamp(

            dust.dust_mass_g /
            300.0,

            0.0,
            1.0

        )


    filter.pressure_drop_kpa =

        0.5 +

        8.0 *

        filter.contamination *


        clamp(

            airflow / 50.0,

            0.0,
            1.0

        )


    filter.efficiency =

        99.97 -

        2.0 *

        filter.contamination

end


# ============================================================
# THERMAL MANAGEMENT
# ============================================================

mutable struct ThermalManager

    motor_limit_c::Float64
    battery_limit_c::Float64

    cooling_factor::Float64

    fan_cooling::Float64

end


ThermalManager() =

    ThermalManager(

        90.0,

        60.0,

        1.0,

        0.0

    )


function update_thermal!(

    thermal::ThermalManager,

    sensors::Sensors,

    motor_power::Float64,

    dt::Float64

)

    heating =

        motor_power *
        0.012


    cooling =

        thermal.cooling_factor *

        thermal.fan_cooling *


        max(

            sensors.motor_temperature_c -
            sensors.ambient_temperature_c,

            0.0

        ) *

        0.01


    sensors.motor_temperature_c +=

        (

            heating -
            cooling

        ) *

        dt


    sensors.motor_temperature_c =

        max(

            sensors.motor_temperature_c,

            sensors.ambient_temperature_c

        )

end


# ============================================================
# SURFACE INTELLIGENCE
# ============================================================

function classify_surface(

    dust_density::Float64,

    brush_load::Float64

)

    if brush_load > 0.65

        return DEEP_CARPET

    elseif brush_load > 0.40

        return CARPET

    elseif dust_density < 0.10

        return HARD_FLOOR

    else

        return FABRIC

    end

end


# ============================================================
# AUTO POWER ALGORITHM
# ============================================================

function auto_power_target(

    surface::SurfaceType,

    dust_density::Float64,

    battery_percent::Float64

)

    base =

        if surface == HARD_FLOOR
            35000.0

        elseif surface == CARPET
            65000.0

        elseif surface == DEEP_CARPET
            90000.0

        elseif surface == FABRIC
            45000.0

        else
            45000.0
        end


    dust_boost =

        25000.0 *

        clamp(

            dust_density,

            0.0,
            1.0

        )


    battery_limit =

        if battery_percent < 15.0
            30000.0
        elseif battery_percent < 30.0
            55000.0
        else
            Inf
        end


    return min(

        base + dust_boost,

        battery_limit

    )

end


# ============================================================
# BLOCKAGE DETECTION
# ============================================================

function detect_blockage(

    sensors::Sensors

)

    pressure_ratio =

        sensors.filter_pressure_drop_kpa /
        max(

            sensors.airflow_l_s,

            1.0

        )


    return (

        pressure_ratio > 0.35 ||

        (

            sensors.motor_current_a > 12.0 &&

            sensors.airflow_l_s < 10.0

        )

    )

end


# ============================================================
# TELEMETRY
# ============================================================

struct TelemetryPoint

    timestamp::DateTime

    state::VacuumState

    surface::SurfaceType

    motor_rpm::Float64

    suction_kpa::Float64

    airflow_l_s::Float64

    battery_percent::Float64

    motor_temperature_c::Float64

    bin_fill_percent::Float64

    filter_pressure_drop_kpa::Float64

    dust_density::Float64

end


mutable struct Telemetry

    points::Vector{TelemetryPoint}

end


Telemetry() =

    Telemetry(

        TelemetryPoint[]

    )


function record!(

    telemetry::Telemetry,

    machine

)

    push!(

        telemetry.points,

        TelemetryPoint(

            now(),

            machine.state,

            machine.sensors.surface,

            machine.sensors.motor_rpm,

            machine.sensors.suction_kpa,

            machine.sensors.airflow_l_s,

            machine.sensors.battery_percent,

            machine.sensors.motor_temperature_c,

            machine.sensors.bin_fill_percent,

            machine.sensors.filter_pressure_drop_kpa,

            machine.sensors.dust_density

        )

    )

end


# ============================================================
# MAINTENANCE ANALYTICS
# ============================================================

mutable struct MaintenanceAnalytics

    motor_hours::Float64
    brush_hours::Float64
    blockage_events::Int
    thermal_events::Int
    filter_service_score::Float64
    estimated_motor_health::Float64

end


MaintenanceAnalytics() =

    MaintenanceAnalytics(

        0.0,
        0.0,
        0,
        0,
        0.0,
        100.0

    )


function update_maintenance!(

    analytics::MaintenanceAnalytics,

    machine,

    dt

)

    if machine.motor.actual_rpm > 1000

        analytics.motor_hours +=

            dt / 3600.0

    end


    if machine.brush.actual_rpm > 1000

        analytics.brush_hours +=

            dt / 3600.0

    end


    analytics.filter_service_score =

        machine.filter.contamination


    analytics.estimated_motor_health =

        clamp(

            100.0 -

            analytics.motor_hours *
            0.05 -

            analytics.blockage_events *
            0.5 -

            analytics.thermal_events *
            1.0,

            0.0,
            100.0

        )

end


# ============================================================
# MAIN MACHINE
# ============================================================

mutable struct Vacuum

    name::String

    state::VacuumState

    sensors::Sensors

    battery::Battery

    motor::MotorController

    suction::SuctionSystem

    brush::BrushBar

    dust::DustSystem

    filter::FilterSystem

    thermal::ThermalManager

    maintenance::MaintenanceAnalytics

    telemetry::Telemetry

    target_power_mode::Symbol

    elapsed_s::Float64

end


function Vacuum(

    name="VACUUM-001"

)

    Vacuum(

        name,

        OFF,

        Sensors(),

        Battery(),

        MotorController(),

        SuctionSystem(),

        BrushBar(),

        DustSystem(),

        FilterSystem(),

        ThermalManager(),

        MaintenanceAnalytics(),

        Telemetry(),

        :AUTO,

        0.0

    )

end


# ============================================================
# POWER ON
# ============================================================

function power_on!(

    vacuum::Vacuum

)

    if vacuum.state == OFF

        vacuum.state = STARTING

        vacuum.motor.target_rpm = 30000.0

        vacuum.brush.enabled = true

    end

end


# ============================================================
# POWER OFF
# ============================================================

function power_off!(

    vacuum::Vacuum

)

    vacuum.motor.target_rpm = 0.0

    vacuum.brush.enabled = false

    vacuum.state = OFF

end


# ============================================================
# BOOST
# ============================================================

function boost!(

    vacuum::Vacuum

)

    if vacuum.battery.state_of_charge > 5.0

        vacuum.state = BOOST

        vacuum.motor.target_rpm = 115000.0

        vacuum.brush.enabled = true

    end

end


# ============================================================
# ECO
# ============================================================

function eco!(

    vacuum::Vacuum

)

    vacuum.state = ECO

    vacuum.motor.target_rpm = 40000.0

    vacuum.brush.enabled = true

end


# ============================================================
# AUTO
# ============================================================

function auto!(

    vacuum::Vacuum

)

    vacuum.state = AUTO

    vacuum.brush.enabled = true

end


# ============================================================
# SAFETY
# ============================================================

function safety_check!(

    vacuum::Vacuum

)

    if vacuum.sensors.motor_temperature_c >=

       vacuum.thermal.motor_limit_c

        vacuum.maintenance.thermal_events += 1

        vacuum.state = OVERHEAT

        vacuum.motor.target_rpm = 0.0

        return false

    end


    if vacuum.sensors.battery_temperature_c >=

       vacuum.thermal.battery_limit_c

        vacuum.state = OVERHEAT

        vacuum.motor.target_rpm = 0.0

        return false

    end


    if vacuum.sensors.battery_percent <= 2.0

        vacuum.state = LOW_BATTERY

        vacuum.motor.target_rpm = 0.0

        return false

    end


    if detect_blockage(vacuum.sensors)

        vacuum.maintenance.blockage_events += 1

        vacuum.state = BLOCKAGE

        vacuum.motor.target_rpm = 0.0

        return false

    end


    if vacuum.sensors.bin_fill_percent >= 95.0

        vacuum.state = BIN_FULL

        vacuum.motor.target_rpm = 0.0

        return false

    end


    if vacuum.filter.contamination >=

       vacuum.filter.service_threshold

        vacuum.state = FILTER_SERVICE

        vacuum.motor.target_rpm = 0.0

        return false

    end


    return true

end


# ============================================================
# CONTROL LOOP
# ============================================================

function control_step!(

    vacuum::Vacuum,

    dt::Float64=0.1

)

    vacuum.elapsed_s += dt


    # --------------------------------------------------------
    # SAFETY
    # --------------------------------------------------------

    if vacuum.state != OFF &&

       vacuum.state != STARTING

        if !safety_check!(vacuum)

            record!(

                vacuum.telemetry,

                vacuum

            )

            return

        end

    end


    # --------------------------------------------------------
    # STARTUP
    # --------------------------------------------------------

    if vacuum.state == STARTING

        if vacuum.motor.actual_rpm >

           25000.0

            vacuum.state = AUTO

        end

    end


    # --------------------------------------------------------
    # AUTO CONTROL
    # --------------------------------------------------------

    if vacuum.state == AUTO

        target =

            auto_power_target(

                vacuum.sensors.surface,

                vacuum.sensors.dust_density,

                vacuum.sensors.battery_percent

            )


        set_motor_target!(

            vacuum.motor,

            target

        )


    elseif vacuum.state == ECO

        set_motor_target!(

            vacuum.motor,

            40000.0

        )


    elseif vacuum.state == BOOST

        set_motor_target!(

            vacuum.motor,

            115000.0

        )


    elseif vacuum.state == STARTING

        set_motor_target!(

            vacuum.motor,

            30000.0

        )

    end


    # --------------------------------------------------------
    # MOTOR
    # --------------------------------------------------------

    motor_control!(

        vacuum.motor,

        dt

    )


    vacuum.sensors.motor_rpm =

        vacuum.motor.actual_rpm


    vacuum.sensors.motor_current_a =

        vacuum.motor.power_percent *
        0.15


    # --------------------------------------------------------
    # BRUSH
    # --------------------------------------------------------

    update_brush!(

        vacuum.brush,

        vacuum.sensors.surface,

        dt

    )


    vacuum.sensors.brush_rpm =

        vacuum.brush.actual_rpm


    vacuum.sensors.brush_load =

        vacuum.brush.load


    # --------------------------------------------------------
    # SUCTION
    # --------------------------------------------------------

    calculate_suction!(

        vacuum.suction,

        vacuum.motor,

        vacuum.sensors

    )


    vacuum.sensors.suction_kpa =

        vacuum.suction.actual_suction_kpa


    vacuum.sensors.airflow_l_s =

        vacuum.suction.actual_airflow_l_s


    # --------------------------------------------------------
    # DUST
    # --------------------------------------------------------

    update_dust!(

        vacuum.dust,

        vacuum.sensors,

        dt

    )


    vacuum.sensors.bin_fill_percent =

        bin_fill_percent(

            vacuum.dust

        )


    # --------------------------------------------------------
    # FILTER
    # --------------------------------------------------------

    update_filter!(

        vacuum.filter,

        vacuum.dust,

        vacuum.sensors.airflow_l_s

    )


    vacuum.sensors.filter_pressure_drop_kpa =

        vacuum.filter.pressure_drop_kpa


    vacuum.sensors.filter_efficiency =

        vacuum.filter.efficiency


    # --------------------------------------------------------
    # THERMAL
    # --------------------------------------------------------

    update_thermal!(

        vacuum.thermal,

        vacuum.sensors,

        vacuum.motor.power_percent,

        dt

    )


    # --------------------------------------------------------
    # BATTERY
    # --------------------------------------------------------

    motor_power =

        650.0 *

        vacuum.motor.power_percent /
        100.0


    battery_update!(

        vacuum.battery,

        motor_power,

        dt

    )


    vacuum.sensors.battery_percent =

        vacuum.battery.state_of_charge


    vacuum.sensors.battery_current_a =

        vacuum.battery.current_a


    vacuum.sensors.battery_voltage_v =

        vacuum.battery.voltage_v


    # --------------------------------------------------------
    # MAINTENANCE
    # --------------------------------------------------------

    update_maintenance!(

        vacuum.maintenance,

        vacuum,

        dt

    )


    # --------------------------------------------------------
    # TELEMETRY
    # --------------------------------------------------------

    record!(

        vacuum.telemetry,

        vacuum

    )

end


# ============================================================
# SURFACE SIMULATOR
# ============================================================

function simulate_surface!(

    vacuum::Vacuum,

    surface::SurfaceType,

    dust::Float64

)

    vacuum.sensors.surface =

        surface


    vacuum.sensors.dust_density =

        clamp(

            dust,

            0.0,
            1.0

        )

end


# ============================================================
# DASHBOARD
# ============================================================

function dashboard(

    vacuum::Vacuum

)

    println()

    println("="^88)

    println(

        "                         VACUUM.OS"

    )

    println(

        "              INTELLIGENT CORDLESS CLEANING SYSTEM"

    )

    println("="^88)

    println()

    println(

        "MACHINE       : ",
        vacuum.name

    )

    println(

        "STATE         : ",
        vacuum.state

    )

    println(

        "SURFACE       : ",
        vacuum.sensors.surface

    )

    println()

    println(

        @sprintf(

            "MOTOR         : %8.0f RPM",

            vacuum.sensors.motor_rpm

        )

    )

    println(

        @sprintf(

            "SUCTION       : %8.2f kPa",

            vacuum.sensors.suction_kpa

        )

    )

    println(

        @sprintf(

            "AIRFLOW       : %8.2f L/s",

            vacuum.sensors.airflow_l_s

        )

    )

    println()

    println(

        @sprintf(

            "BATTERY       : %8.1f %%",

            vacuum.sensors.battery_percent

        )

    )

    println(

        @sprintf(

            "MOTOR TEMP    : %8.1f °C",

            vacuum.sensors.motor_temperature_c

        )

    )

    println(

        @sprintf(

            "BIN           : %8.1f %%",

            vacuum.sensors.bin_fill_percent

        )

    )

    println(

        @sprintf(

            "FILTER DROP   : %8.2f kPa",

            vacuum.sensors.filter_pressure_drop_kpa

        )

    )

    println(

        @sprintf(

            "FILTER EFF.   : %8.2f %%",

            vacuum.sensors.filter_efficiency

        )

    )

    println()

    println(

        "BRUSH         : ",

        vacuum.brush.enabled ?

        "RUNNING" :

        "STOPPED"

    )

    println(

        "MOTOR HEALTH  : ",

        round(

            vacuum.maintenance.
            estimated_motor_health,

            digits=1

        ),

        "%"

    )

    println()

    println("="^88)

end


# ============================================================
# PERFORMANCE REPORT
# ============================================================

function performance_report(

    vacuum::Vacuum

)

    points =

        vacuum.telemetry.points


    isempty(points) &&

        return nothing


    mean_suction =

        mean(

            p.suction_kpa

            for p in points

        )


    mean_airflow =

        mean(

            p.airflow_l_s

            for p in points

        )


    mean_motor_temp =

        mean(

            p.motor_temperature_c

            for p in points

        )


    energy_used =

        vacuum.battery.capacity_wh -

        vacuum.battery.remaining_wh


    return (

        runtime_minutes =

            vacuum.elapsed_s / 60.0,

        average_suction_kpa =

            mean_suction,

        average_airflow_l_s =

            mean_airflow,

        average_motor_temperature_c =

            mean_motor_temp,

        battery_remaining_percent =

            vacuum.battery.state_of_charge,

        energy_used_wh =

            energy_used,

        dust_collected_g =

            vacuum.dust.dust_mass_g,

        motor_hours =

            vacuum.maintenance.motor_hours,

        blockage_events =

            vacuum.maintenance.blockage_events,

        motor_health =

            vacuum.maintenance.
            estimated_motor_health

    )

end


# ============================================================
# DIGITAL-TWIN DEMONSTRATION
# ============================================================

function simulate()

    vacuum =

        Vacuum(

            "DYSON-LAB-001"

        )


    println()

    println(

        "INITIALISING VACUUM.OS..."

    )


    power_on!(

        vacuum

    )


    # --------------------------------------------------------
    # HARD FLOOR
    # --------------------------------------------------------

    println()

    println(

        "SURFACE: HARD FLOOR"

    )


    simulate_surface!(

        vacuum,

        HARD_FLOOR,

        0.15

    )


    for i in 1:300

        control_step!(

            vacuum,

            0.1

        )

    end


    dashboard(

        vacuum

    )


    # --------------------------------------------------------
    # CARPET
    # --------------------------------------------------------

    println()

    println(

        "SURFACE: CARPET"

    )


    simulate_surface!(

        vacuum,

        CARPET,

        0.55

    )


    for i in 1:500

        control_step!(

            vacuum,

            0.1

        )

    end


    dashboard(

        vacuum

    )


    # --------------------------------------------------------
    # DEEP CARPET
    # --------------------------------------------------------

    println()

    println(

        "SURFACE: DEEP CARPET"

    )


    simulate_surface!(

        vacuum,

        DEEP_CARPET,

        0.85

    )


    for i in 1:700

        control_step!(

            vacuum,

            0.1

        )

    end


    dashboard(

        vacuum

    )


    # --------------------------------------------------------
    # REPORT
    # --------------------------------------------------------

    report =

        performance_report(

            vacuum

        )


    println()

    println("="^88)

    println(

        "                    CLEANING REPORT"

    )

    println("="^88)

    println()

    println(

        "Runtime                 : ",

        round(

            report.runtime_minutes,

            digits=1

        ),

        " minutes"

    )

    println(

        "Average suction        : ",

        round(

            report.average_suction_kpa,

            digits=2

        ),

        " kPa"

    )

    println(

        "Average airflow        : ",

        round(

            report.average_airflow_l_s,

            digits=2

        ),

        " L/s"

    )

    println(

        "Average motor temp     : ",

        round(

            report.average_motor_temperature_c,

            digits=1

        ),

        " °C"

    )

    println(

        "Battery remaining      : ",

        round(

            report.battery_remaining_percent,

            digits=1

        ),

        " %"

    )

    println(

        "Energy consumed        : ",

        round(

            report.energy_used_wh,

            digits=2

        ),

        " Wh"

    )

    println(

        "Dust collected         : ",

        round(

            report.dust_collected_g,

            digits=2

        ),

        " g"

    )

    println(

        "Blockage events        : ",

        report.blockage_events

    )

    println(

        "Motor health           : ",

        round(

            report.motor_health,

            digits=1

        ),

        " %"

    )

    println()

    println("="^88)

end


# ============================================================
# EXPORTS
# ============================================================

export Vacuum
export VacuumState
export SurfaceType

export power_on!
export power_off!
export auto!
export eco!
export boost!

export control_step!
export simulate_surface!
export dashboard
export performance_report
export simulate

end


# ============================================================
# APPLICATION ENTRY POINT
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .VacuumOS

    VacuumOS.simulate()

end
```

