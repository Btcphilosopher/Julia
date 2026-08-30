# AIRFLOW.OS

## Intelligent Hairdryer Control System

### Pure Julia — Embedded Thermal & Airflow Controller

```julia
module AirflowOS

using Dates
using Printf
using Statistics


# ============================================================
# AIRFLOW.OS
# INTELLIGENT HAIRDRYER CONTROL SYSTEM
# ============================================================
#
# CONTROL DOMAINS
#
#   • Heater control
#   • Fan / BLDC control
#   • Temperature regulation
#   • Airflow estimation
#   • Motor-load monitoring
#   • Thermal protection
#   • Cool-shot operation
#   • Ioniser control
#   • Adaptive drying
#   • Fault detection
#   • Telemetry
#
# This is a simulation/control architecture.
# A real mains-powered appliance requires certified hardware
# protection, thermal fuses, isolation, EMC compliance and
# independently validated firmware.
#
# ============================================================


# ============================================================
# STATES
# ============================================================

@enum DryerState begin
    OFF
    BOOT
    READY
    DRYING
    BOOST
    COOL_SHOT
    ECO
    FAULT
    OVERHEAT
    EMERGENCY_STOP
end


@enum HeaterLevel begin
    HEATER_OFF
    HEATER_LOW
    HEATER_MEDIUM
    HEATER_HIGH
end


@enum FanLevel begin
    FAN_OFF
    FAN_LOW
    FAN_MEDIUM
    FAN_HIGH
    FAN_MAX
end


# ============================================================
# SENSOR ARRAY
# ============================================================

mutable struct Sensors

    inlet_temperature_c::Float64
    heater_temperature_c::Float64
    outlet_temperature_c::Float64

    motor_temperature_c::Float64

    motor_rpm::Float64
    motor_current_a::Float64

    airflow_l_s::Float64

    ambient_temperature_c::Float64

    humidity_percent::Float64

    nozzle_temperature_c::Float64

end


function Sensors()

    Sensors(

        22.0,
        25.0,
        22.0,

        25.0,

        0.0,
        0.0,

        0.0,

        22.0,

        55.0,

        22.0

    )

end


# ============================================================
# HEATER
# ============================================================

mutable struct Heater

    level::HeaterLevel

    power_percent::Float64

    electrical_power_w::Float64

    temperature_limit_c::Float64

    thermal_mass::Float64

end


function Heater()

    Heater(

        HEATER_OFF,
        0.0,
        0.0,
        140.0,
        1.0

    )

end


function heater_power(level::HeaterLevel)

    if level == HEATER_OFF
        return 0.0

    elseif level == HEATER_LOW
        return 30.0

    elseif level == HEATER_MEDIUM
        return 60.0

    elseif level == HEATER_HIGH
        return 100.0
    end

    return 0.0

end


function update_heater!(

    heater::Heater,
    sensors::Sensors,
    dt::Float64

)

    heater.power_percent =

        heater_power(

            heater.level

        )


    heater.electrical_power_w =

        1800.0 *

        heater.power_percent /
        100.0


    # Simplified thermal model.

    heating_rate =

        heater.power_percent /
        100.0 *

        18.0


    cooling_rate =

        max(

            sensors.heater_temperature_c -
            sensors.inlet_temperature_c,

            0.0

        ) *

        0.025


    sensors.heater_temperature_c +=

        (

            heating_rate -
            cooling_rate

        ) * dt


    sensors.heater_temperature_c =

        max(

            sensors.heater_temperature_c,

            sensors.inlet_temperature_c

        )

end


# ============================================================
# BLDC FAN
# ============================================================

mutable struct Fan

    level::FanLevel

    target_rpm::Float64

    actual_rpm::Float64

    current_a::Float64

    electrical_power_w::Float64

    efficiency::Float64

end


function Fan()

    Fan(

        FAN_OFF,

        0.0,
        0.0,
        0.0,
        0.0,
        0.88

    )

end


function fan_target_rpm(level::FanLevel)

    if level == FAN_OFF
        return 0.0

    elseif level == FAN_LOW
        return 7000.0

    elseif level == FAN_MEDIUM
        return 11000.0

    elseif level == FAN_HIGH
        return 15000.0

    elseif level == FAN_MAX
        return 18000.0
    end

    return 0.0

end


function update_fan!(

    fan::Fan,
    sensors::Sensors,
    dt::Float64

)

    fan.target_rpm =

        fan_target_rpm(

            fan.level

        )


    # Motor acceleration.

    fan.actual_rpm +=

        (

            fan.target_rpm -
            fan.actual_rpm

        ) *

        min(

            dt * 8.0,

            1.0

        )


    # Simplified load model.

    aerodynamic_load =

        (

            fan.actual_rpm /
            18000.0

        )^2


    fan.current_a =

        0.8 +

        aerodynamic_load * 4.5


    fan.electrical_power_w =

        120.0 *

        fan.current_a


    sensors.motor_rpm =

        fan.actual_rpm


    sensors.motor_current_a =

        fan.current_a


    # Approximate airflow curve.

    sensors.airflow_l_s =

        8.0 +

        42.0 *

        (

            fan.actual_rpm /
            18000.0

        )


end


# ============================================================
# AIR / HEAT TRANSFER MODEL
# ============================================================

function calculate_outlet_temperature!(

    sensors::Sensors,
    heater::Heater,
    fan::Fan,
    dt::Float64

)

    airflow =

        max(

            sensors.airflow_l_s,

            1.0

        )


    heat_gain =

        (

            heater.power_percent /
            100.0

        ) *

        95.0


    airflow_cooling =

        35.0 *

        (

            airflow /
            50.0

        )


    target =

        sensors.inlet_temperature_c +

        heat_gain -

        airflow_cooling


    sensors.outlet_temperature_c +=

        (

            target -
            sensors.outlet_temperature_c

        ) *

        min(

            dt * 5.0,

            1.0

        )


    sensors.nozzle_temperature_c =

        sensors.outlet_temperature_c

end


# ============================================================
# HUMIDITY / DRYING MODEL
# ============================================================

mutable struct DryingModel

    initial_humidity_percent::Float64

    moisture_removed_percent::Float64

    drying_rate::Float64

    dryness_index::Float64

end


function DryingModel()

    DryingModel(

        60.0,
        0.0,
        0.0,
        0.0

    )

end


function update_drying!(

    drying::DryingModel,
    sensors::Sensors,
    fan::Fan,
    dt::Float64

)

    temperature_factor =

        clamp(

            (

                sensors.outlet_temperature_c -
                30.0

            ) / 60.0,

            0.0,
            1.0

        )


    airflow_factor =

        clamp(

            sensors.airflow_l_s / 50.0,

            0.0,
            1.0

        )


    drying.drying_rate =

        0.00008 *

        (

            0.25 +
            0.75 * temperature_factor

        ) *

        (

            0.30 +
            0.70 * airflow_factor

        )


    drying.moisture_removed_percent +=

        drying.drying_rate *

        dt *


        100.0


    drying.moisture_removed_percent =

        clamp(

            drying.moisture_removed_percent,

            0.0,

            drying.initial_humidity_percent

        )


    drying.dryness_index =

        clamp(

            drying.moisture_removed_percent /
            drying.initial_humidity_percent,

            0.0,
            1.0

        )

end


# ============================================================
# IONISER
# ============================================================

mutable struct Ioniser

    enabled::Bool

    output_percent::Float64

    estimated_output::Float64

end


function Ioniser()

    Ioniser(

        false,

        0.0,
        0.0

    )

end


function update_ioniser!(

    ioniser::Ioniser

)

    if ioniser.enabled

        ioniser.output_percent = 100.0

    else

        ioniser.output_percent = 0.0

    end


    ioniser.estimated_output =

        ioniser.output_percent *

        1.0

end


# ============================================================
# SAFETY CONTROLLER
# ============================================================

mutable struct SafetyController

    thermal_cutoff_c::Float64

    motor_cutoff_c::Float64

    maximum_current_a::Float64

    airflow_minimum_l_s::Float64

    thermal_fault::Bool
    motor_fault::Bool
    airflow_fault::Bool
    overcurrent_fault::Bool

    emergency_stop::Bool

    fault_message::String

end


function SafetyController()

    SafetyController(

        125.0,
        90.0,
        9.0,
        3.0,

        false,
        false,
        false,
        false,

        false,

        ""

    )

end


function safety_check!(

    safety::SafetyController,
    sensors::Sensors

)

    safety.thermal_fault =

        sensors.outlet_temperature_c >=
        safety.thermal_cutoff_c


    safety.motor_fault =

        sensors.motor_temperature_c >=
        safety.motor_cutoff_c


    safety.airflow_fault =

        sensors.motor_rpm > 3000.0 &&

        sensors.airflow_l_s <
        safety.airflow_minimum_l_s


    safety.overcurrent_fault =

        sensors.motor_current_a >
        safety.maximum_current_a


    if safety.emergency_stop

        safety.fault_message =

            "EMERGENCY STOP"

        return false

    elseif safety.thermal_fault

        safety.fault_message =

            "OVER-TEMPERATURE"

        return false

    elseif safety.motor_fault

        safety.fault_message =

            "MOTOR OVER-TEMPERATURE"

        return false

    elseif safety.airflow_fault

        safety.fault_message =

            "INSUFFICIENT AIRFLOW"

        return false

    elseif safety.overcurrent_fault

        safety.fault_message =

            "MOTOR OVERCURRENT"

        return false
    end


    safety.fault_message = ""

    return true

end


# ============================================================
# ADAPTIVE CONTROLLER
# ============================================================

mutable struct AdaptiveController

    target_outlet_temperature_c::Float64

    temperature_error::Float64

    recommended_heater::HeaterLevel

    recommended_fan::FanLevel

end


function AdaptiveController()

    AdaptiveController(

        70.0,

        0.0,

        HEATER_MEDIUM,

        FAN_HIGH

    )

end


function adaptive_control!(

    controller::AdaptiveController,
    sensors::Sensors,
    drying::DryingModel

)

    controller.temperature_error =

        controller.target_outlet_temperature_c -

        sensors.outlet_temperature_c


    # Maintain airflow aggressively while
    # adjusting thermal output.

    if sensors.outlet_temperature_c < 55.0

        controller.recommended_heater =

            HEATER_HIGH

    elseif sensors.outlet_temperature_c < 70.0

        controller.recommended_heater =

            HEATER_MEDIUM

    elseif sensors.outlet_temperature_c < 80.0

        controller.recommended_heater =

            HEATER_LOW

    else

        controller.recommended_heater =

            HEATER_OFF

    end


    # Automatically increase airflow if
    # thermal load rises.

    if sensors.outlet_temperature_c > 75.0

        controller.recommended_fan =

            FAN_MAX

    elseif sensors.outlet_temperature_c > 65.0

        controller.recommended_fan =

            FAN_HIGH

    else

        controller.recommended_fan =

            FAN_MEDIUM

    end

end


# ============================================================
# TELEMETRY
# ============================================================

struct TelemetryPoint

    timestamp::DateTime

    state::DryerState

    outlet_temperature_c::Float64

    heater_power_percent::Float64

    fan_rpm::Float64

    airflow_l_s::Float64

    motor_current_a::Float64

    dryness_index::Float64

    ioniser_enabled::Bool

end


mutable struct Telemetry

    points::Vector{TelemetryPoint}

end


Telemetry() =

    Telemetry(

        TelemetryPoint[]

    )


# ============================================================
# HAIRDRYER
# ============================================================

mutable struct HairDryer

    name::String

    state::DryerState

    sensors::Sensors
    heater::Heater
    fan::Fan
    drying::DryingModel
    ioniser::Ioniser
    safety::SafetyController
    adaptive::AdaptiveController
    telemetry::Telemetry

    elapsed_s::Float64

end


function HairDryer(

    name="AIRFLOWOS-001"

)

    HairDryer(

        name,

        OFF,

        Sensors(),
        Heater(),
        Fan(),
        DryingModel(),
        Ioniser(),
        SafetyController(),
        AdaptiveController(),
        Telemetry(),

        0.0

    )

end


# ============================================================
# POWER ON
# ============================================================

function power_on!(

    dryer::HairDryer

)

    dryer.state = BOOT

    sleep(0.01)

    dryer.state = READY

end


# ============================================================
# DRY MODE
# ============================================================

function start_drying!(

    dryer::HairDryer

)

    dryer.state = DRYING

    dryer.heater.level =

        HEATER_MEDIUM

    dryer.fan.level =

        FAN_HIGH

    dryer.ioniser.enabled =

        true

end


# ============================================================
# BOOST MODE
# ============================================================

function boost!(

    dryer::HairDryer

)

    dryer.state = BOOST

    dryer.heater.level =

        HEATER_HIGH

    dryer.fan.level =

        FAN_MAX

end


# ============================================================
# COOL SHOT
# ============================================================

function cool_shot!(

    dryer::HairDryer

)

    dryer.state = COOL_SHOT

    dryer.heater.level =

        HEATER_OFF

    dryer.fan.level =

        FAN_MAX

end


# ============================================================
# ECO MODE
# ============================================================

function eco_mode!(

    dryer::HairDryer

)

    dryer.state = ECO

    dryer.heater.level =

        HEATER_LOW

    dryer.fan.level =

        FAN_HIGH

end


# ============================================================
# SHUTDOWN
# ============================================================

function shutdown!(

    dryer::HairDryer

)

    dryer.heater.level =

        HEATER_OFF

    dryer.fan.level =

        FAN_OFF

    dryer.ioniser.enabled =

        false

    dryer.state =

        OFF

end


# ============================================================
# CONTROL LOOP
# ============================================================

function control_step!(

    dryer::HairDryer,

    dt::Float64=0.02

)

    dryer.elapsed_s += dt


    # --------------------------------------------------------
    # SENSOR / SAFETY
    # --------------------------------------------------------

    if !safety_check!(

        dryer.safety,

        dryer.sensors

    )

        dryer.state =

            dryer.safety.thermal_fault ?

            OVERHEAT :

            FAULT


        dryer.heater.level =

            HEATER_OFF

        dryer.fan.level =

            FAN_OFF

        dryer.ioniser.enabled =

            false


        return

    end


    # --------------------------------------------------------
    # ADAPTIVE MODE
    # --------------------------------------------------------

    if dryer.state == DRYING ||

       dryer.state == ECO

        adaptive_control!(

            dryer.adaptive,

            dryer.sensors,

            dryer.drying

        )


        dryer.heater.level =

            dryer.adaptive.recommended_heater


        dryer.fan.level =

            dryer.adaptive.recommended_fan

    end


    # --------------------------------------------------------
    # HEATER
    # --------------------------------------------------------

    update_heater!(

        dryer.heater,

        dryer.sensors,

        dt

    )


    # --------------------------------------------------------
    # FAN
    # --------------------------------------------------------

    update_fan!(

        dryer.fan,

        dryer.sensors,

        dt

    )


    # --------------------------------------------------------
    # HEAT TRANSFER
    # --------------------------------------------------------

    calculate_outlet_temperature!(

        dryer.sensors,

        dryer.heater,

        dryer.fan,

        dt

    )


    # --------------------------------------------------------
    # DRYING
    # --------------------------------------------------------

    if dryer.state == DRYING ||

       dryer.state == BOOST ||

       dryer.state == ECO

        update_drying!(

            dryer.drying,

            dryer.sensors,

            dryer.fan,

            dt

        )

    end


    # --------------------------------------------------------
    # IONISER
    # --------------------------------------------------------

    update_ioniser!(

        dryer.ioniser

    )


    # --------------------------------------------------------
    # MOTOR TEMPERATURE
    # --------------------------------------------------------

    motor_heat =

        dryer.fan.current_a^2 *

        0.08


    motor_cooling =

        (

            dryer.sensors.motor_temperature_c -
            dryer.sensors.ambient_temperature_c

        ) *

        0.02


    dryer.sensors.motor_temperature_c +=

        (

            motor_heat -
            motor_cooling

        ) * dt


    # --------------------------------------------------------
    # TELEMETRY
    # --------------------------------------------------------

    push!(

        dryer.telemetry.points,

        TelemetryPoint(

            now(),

            dryer.state,

            dryer.sensors.outlet_temperature_c,

            dryer.heater.power_percent,

            dryer.sensors.motor_rpm,

            dryer.sensors.airflow_l_s,

            dryer.sensors.motor_current_a,

            dryer.drying.dryness_index,

            dryer.ioniser.enabled

        )

    )

end


# ============================================================
# DASHBOARD
# ============================================================

function dashboard(

    dryer::HairDryer

)

    println()

    println("="^82)

    println(

        "                         AIRFLOW.OS"

    )

    println(

        "                 INTELLIGENT HAIRDRYER"

    )

    println("="^82)

    println()


    println(

        "DEVICE          : ",

        dryer.name

    )


    println(

        "STATE           : ",

        dryer.state

    )


    println()


    println(

        @sprintf(

            "OUTLET TEMP     : %8.2f °C",

            dryer.sensors.outlet_temperature_c

        )

    )


    println(

        @sprintf(

            "HEATER POWER    : %8.1f %%",

            dryer.heater.power_percent

        )

    )


    println(

        @sprintf(

            "FAN SPEED       : %8.0f RPM",

            dryer.sensors.motor_rpm

        )

    )


    println(

        @sprintf(

            "AIRFLOW         : %8.2f L/s",

            dryer.sensors.airflow_l_s

        )

    )


    println(

        @sprintf(

            "MOTOR CURRENT   : %8.2f A",

            dryer.sensors.motor_current_a

        )

    )


    println(

        @sprintf(

            "MOTOR TEMP      : %8.2f °C",

            dryer.sensors.motor_temperature_c

        )

    )


    println()


    println(

        @sprintf(

            "DRYNESS INDEX   : %8.2f %%",

            dryer.drying.dryness_index * 100.0

        )

    )


    println(

        "IONISER         : ",

        dryer.ioniser.enabled ?

        "ACTIVE" :

        "OFF"

    )


    println()


    println(

        "SAFETY          : ",

        dryer.safety.fault_message == "" ?

        "OK" :

        dryer.safety.fault_message

    )


    println()

    println("="^82)

end


# ============================================================
# PERFORMANCE REPORT
# ============================================================

function performance_report(

    dryer::HairDryer

)

    points =

        dryer.telemetry.points


    isempty(points) &&

        return nothing


    temperatures =

        [

            p.outlet_temperature_c

            for p in points

        ]


    airflow =

        [

            p.airflow_l_s

            for p in points

        ]


    power =

        [

            p.heater_power_percent

            for p in points

        ]


    (

        runtime_s =

            dryer.elapsed_s,

        average_temperature_c =

            mean(temperatures),

        maximum_temperature_c =

            maximum(temperatures),

        average_airflow_l_s =

            mean(airflow),

        average_heater_power_percent =

            mean(power),

        final_dryness_percent =

            dryer.drying.dryness_index * 100.0,

        final_state =

            dryer.state

    )

end


# ============================================================
# DIGITAL-TWIN DEMO
# ============================================================

function simulate()

    dryer =

        HairDryer(

            "AIRFLOWOS-LAB-001"

        )


    println()

    println(

        "BOOTING AIRFLOW.OS..."

    )


    power_on!(

        dryer

    )


    println(

        "SYSTEM READY."

    )


    start_drying!(

        dryer

    )


    # 10-minute simulated drying cycle.

    for tick in 1:30000

        control_step!(

            dryer,

            0.02

        )


        if tick % 5000 == 0

            dashboard(

                dryer

            )

        end


        if dryer.state == FAULT ||

           dryer.state == OVERHEAT

            break

        end

    end


    dashboard(

        dryer

    )


    result =

        performance_report(

            dryer

        )


    println()

    println("="^82)

    println(

        "                    PERFORMANCE REPORT"

    )

    println("="^82)

    println()


    println(

        @sprintf(

            "Runtime                 : %.1f seconds",

            result.runtime_s

        )

    )


    println(

        @sprintf(

            "Average outlet temp     : %.2f °C",

            result.average_temperature_c

        )

    )


    println(

        @sprintf(

            "Maximum outlet temp     : %.2f °C",

            result.maximum_temperature_c

        )

    )


    println(

        @sprintf(

            "Average airflow         : %.2f L/s",

            result.average_airflow_l_s

        )

    )


    println(

        @sprintf(

            "Average heater power    : %.2f %%",

            result.average_heater_power_percent

        )

    )


    println(

        @sprintf(

            "Final drying index      : %.2f %%",

            result.final_dryness_percent

        )

    )


    println(

        "Final state             : ",

        result.final_state

    )


    println()

    println("="^82)

end


# ============================================================
# EXPORTS
# ============================================================

export HairDryer

export power_on!
export start_drying!
export boost!
export cool_shot!
export eco_mode!
export shutdown!

export control_step!
export dashboard
export performance_report
export simulate


end


# ============================================================
# APPLICATION ENTRY
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .AirflowOS

    AirflowOS.simulate()

end
```

