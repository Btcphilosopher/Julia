# STRAIGHT.OS

## Intelligent Hair Straightener Control System

### Pure Julia — Thermal Control, Plate Balancing & Safety Engine

```julia
module StraightOS

using Dates
using Printf
using Statistics


# ============================================================
# STRAIGHT.OS
# ============================================================
#
# Intelligent heated hair-styling appliance controller.
#
# CORE SYSTEMS
#
#   • Dual plate temperature control
#   • Independent left/right thermal zones
#   • PID-style closed-loop control
#   • Temperature ramp management
#   • Thermal balancing
#   • Contact/load estimation
#   • Hair-pass detection
#   • Adaptive heat management
#   • Boost mode
#   • Sleep mode
#   • Cool-down controller
#   • Over-temperature protection
#   • Sensor-fault detection
#   • Telemetry
#
# This is a simulation/control architecture.
# A real mains-powered appliance requires independently
# certified thermal protection, isolation, fusing and
# hardware-level safety cutoffs.
#
# ============================================================


# ============================================================
# STATES
# ============================================================

@enum StraightenerState begin

    OFF
    BOOT
    READY
    HEATING
    STANDBY
    STYLING
    BOOST
    COOLING
    SLEEP
    FAULT
    OVERHEAT
    EMERGENCY_STOP

end


@enum HeatMode begin

    LOW_HEAT
    NORMAL_HEAT
    HIGH_HEAT
    BOOST_HEAT

end


# ============================================================
# TEMPERATURE SENSOR
# ============================================================

mutable struct TemperatureSensor

    temperature_c::Float64

    previous_temperature_c::Float64

    rate_c_s::Float64

    valid::Bool

end


function TemperatureSensor(

    initial_temperature=22.0

)

    TemperatureSensor(

        initial_temperature,

        initial_temperature,

        0.0,

        true

    )

end


function update_sensor!(

    sensor::TemperatureSensor,

    actual_temperature::Float64,

    dt::Float64

)

    sensor.previous_temperature_c =

        sensor.temperature_c


    sensor.temperature_c =

        actual_temperature


    sensor.rate_c_s =

        (

            sensor.temperature_c -

            sensor.previous_temperature_c

        ) /

        max(

            dt,

            0.0001

        )


    sensor.valid =

        isfinite(

            sensor.temperature_c

        )

end


# ============================================================
# HEATED PLATE
# ============================================================

mutable struct HeatingPlate

    name::String

    sensor::TemperatureSensor

    target_temperature_c::Float64

    heater_power_percent::Float64

    maximum_temperature_c::Float64

    thermal_mass::Float64

    thermal_loss::Float64

end


function HeatingPlate(

    name::String

)

    HeatingPlate(

        name,

        TemperatureSensor(),

        180.0,

        0.0,

        240.0,

        1.0,

        0.015

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

end


function PIDController(

    kp=2.8,

    ki=0.12,

    kd=0.35

)

    PIDController(

        kp,

        ki,

        kd,

        0.0,

        0.0

    )

end


function pid_update!(

    pid::PIDController,

    target::Float64,

    measured::Float64,

    dt::Float64

)

    error =

        target -
        measured


    pid.integral +=

        error * dt


    pid.integral =

        clamp(

            pid.integral,

            -100.0,
            100.0

        )


    derivative =

        (

            error -
            pid.previous_error

        ) /

        max(

            dt,

            0.0001

        )


    output =

        pid.kp * error +

        pid.ki * pid.integral +

        pid.kd * derivative


    pid.previous_error =

        error


    return clamp(

        output,

        0.0,
        100.0

    )

end


# ============================================================
# THERMAL SYSTEM
# ============================================================

mutable struct ThermalSystem

    left_plate::HeatingPlate

    right_plate::HeatingPlate

    left_pid::PIDController

    right_pid::PIDController

    target_temperature_c::Float64

    temperature_balance_c::Float64

end


function ThermalSystem()

    ThermalSystem(

        HeatingPlate("LEFT PLATE"),

        HeatingPlate("RIGHT PLATE"),

        PIDController(),

        PIDController(),

        180.0,

        0.0

    )

end


# ============================================================
# HEATER PHYSICS
# ============================================================

function update_plate_temperature!(

    plate::HeatingPlate,

    dt::Float64

)

    heat_input =

        plate.heater_power_percent *

        0.42


    thermal_loss =

        max(

            plate.sensor.temperature_c -
            22.0,

            0.0

        ) *

        plate.thermal_loss


    rate =

        (

            heat_input -
            thermal_loss

        ) /

        plate.thermal_mass


    new_temperature =

        plate.sensor.temperature_c +

        rate * dt


    update_sensor!(

        plate.sensor,

        new_temperature,

        dt

    )

end


# ============================================================
# THERMAL BALANCING
# ============================================================

function balance_plates!(

    thermal::ThermalSystem

)

    left =

        thermal.left_plate.sensor.temperature_c


    right =

        thermal.right_plate.sensor.temperature_c


    thermal.temperature_balance_c =

        abs(

            left -
            right

        )


    # Cross-correction keeps the two plates
    # thermally matched.

    correction =

        clamp(

            (

                left -
                right

            ) * 1.5,

            -10.0,
            10.0

        )


    thermal.left_plate.heater_power_percent -=

        correction


    thermal.right_plate.heater_power_percent +=

        correction


    thermal.left_plate.heater_power_percent =

        clamp(

            thermal.left_plate.heater_power_percent,

            0.0,
            100.0

        )


    thermal.right_plate.heater_power_percent =

        clamp(

            thermal.right_plate.heater_power_percent,

            0.0,
            100.0

        )

end


# ============================================================
# CONTACT / PRESSURE SENSOR
# ============================================================

mutable struct ContactSystem

    pressure_n::Float64

    contact_detected::Bool

    contact_duration_s::Float64

    pass_count::Int

    previous_contact::Bool

end


function ContactSystem()

    ContactSystem(

        0.0,

        false,

        0.0,

        0,

        false

    )

end


function update_contact!(

    contact::ContactSystem,

    pressure_n::Float64,

    dt::Float64

)

    contact.pressure_n =

        max(

            pressure_n,

            0.0

        )


    contact.contact_detected =

        pressure_n > 1.5


    if contact.contact_detected

        contact.contact_duration_s += dt

    end


    # Detect beginning of a new pass.

    if contact.contact_detected &&

       !contact.previous_contact

        contact.pass_count += 1

    end


    contact.previous_contact =

        contact.contact_detected

end


# ============================================================
# HAIR-PASS MODEL
# ============================================================

mutable struct StylingModel

    pass_active::Bool

    estimated_hair_load::Float64

    estimated_moisture::Float64

    heat_demand::Float64

    styling_progress::Float64

end


function StylingModel()

    StylingModel(

        false,

        0.0,

        0.50,

        0.0,

        0.0

    )

end


function update_styling!(

    styling::StylingModel,

    contact::ContactSystem,

    thermal::ThermalSystem,

    dt::Float64

)

    styling.pass_active =

        contact.contact_detected


    if styling.pass_active

        styling.estimated_hair_load =

            clamp(

                contact.pressure_n /
                10.0,

                0.0,
                1.0

            )


        thermal_temperature =

            (

                thermal.left_plate.sensor.temperature_c +

                thermal.right_plate.sensor.temperature_c

            ) / 2.0


        temperature_factor =

            clamp(

                (

                    thermal_temperature -
                    100.0

                ) / 100.0,

                0.0,
                1.0

            )


        styling.heat_demand =

            styling.estimated_hair_load *

            (

                1.0 -
                temperature_factor

            )


        styling.styling_progress +=

            0.0005 *

            (

                0.5 +
                temperature_factor

            ) *

            dt


        styling.styling_progress =

            clamp(

                styling.styling_progress,

                0.0,
                1.0

            )

    end

end


# ============================================================
# TEMPERATURE PROFILE
# ============================================================

function target_for_mode(

    mode::HeatMode

)

    if mode == LOW_HEAT

        return 150.0

    elseif mode == NORMAL_HEAT

        return 180.0

    elseif mode == HIGH_HEAT

        return 205.0

    elseif mode == BOOST_HEAT

        return 220.0

    end

    return 180.0

end


# ============================================================
# SAFETY CONTROLLER
# ============================================================

mutable struct SafetySystem

    maximum_plate_temperature_c::Float64

    maximum_temperature_difference_c::Float64

    sensor_fault::Bool

    thermal_fault::Bool

    imbalance_fault::Bool

    emergency_stop::Bool

    fault_message::String

end


function SafetySystem()

    SafetySystem(

        230.0,

        20.0,

        false,

        false,

        false,

        false,

        ""

    )

end


function check_safety!(

    safety::SafetySystem,

    thermal::ThermalSystem

)

    left =

        thermal.left_plate.sensor


    right =

        thermal.right_plate.sensor


    safety.sensor_fault =

        !left.valid ||

        !right.valid


    safety.thermal_fault =

        left.temperature_c >=
        safety.maximum_plate_temperature_c ||

        right.temperature_c >=
        safety.maximum_plate_temperature_c


    safety.imbalance_fault =

        abs(

            left.temperature_c -
            right.temperature_c

        ) >

        safety.maximum_temperature_difference_c


    if safety.emergency_stop

        safety.fault_message =

            "EMERGENCY STOP"

        return false

    elseif safety.sensor_fault

        safety.fault_message =

            "TEMPERATURE SENSOR FAULT"

        return false

    elseif safety.thermal_fault

        safety.fault_message =

            "OVER-TEMPERATURE"

        return false

    elseif safety.imbalance_fault

        safety.fault_message =

            "PLATE TEMPERATURE IMBALANCE"

        return false

    end


    safety.fault_message = ""

    return true

end


# ============================================================
# SLEEP TIMER
# ============================================================

mutable struct SleepController

    timeout_s::Float64

    inactive_s::Float64

    enabled::Bool

end


SleepController() =

    SleepController(

        600.0,

        0.0,

        true

    )


function update_sleep!(

    sleep_controller::SleepController,

    activity::Bool,

    dt::Float64

)

    if activity

        sleep_controller.inactive_s = 0.0

    else

        sleep_controller.inactive_s += dt
    end


    return (

        sleep_controller.enabled &&

        sleep_controller.inactive_s >=

        sleep_controller.timeout_s

    )

end


# ============================================================
# TELEMETRY
# ============================================================

struct TelemetryPoint

    timestamp::DateTime

    state::StraightenerState

    left_temperature_c::Float64

    right_temperature_c::Float64

    temperature_difference_c::Float64

    left_power_percent::Float64

    right_power_percent::Float64

    pressure_n::Float64

    styling_progress::Float64

end


mutable struct Telemetry

    points::Vector{TelemetryPoint}

end


Telemetry() =

    Telemetry(

        TelemetryPoint[]

    )


# ============================================================
# STRAIGHTENER
# ============================================================

mutable struct HairStraightener

    name::String

    state::StraightenerState

    heat_mode::HeatMode

    thermal::ThermalSystem

    contact::ContactSystem
    styling::StylingModel

    safety::SafetySystem
    sleep_controller::SleepController

    telemetry::Telemetry

    elapsed_s::Float64

end


function HairStraightener(

    name="STRAIGHTOS-001"

)

    HairStraightener(

        name,

        OFF,

        NORMAL_HEAT,

        ThermalSystem(),

        ContactSystem(),
        StylingModel(),

        SafetySystem(),
        SleepController(),

        Telemetry(),

        0.0

    )

end


# ============================================================
# POWER ON
# ============================================================

function power_on!(

    device::HairStraightener

)

    device.state = BOOT

    device.elapsed_s = 0.0

    device.state = HEATING

end


# ============================================================
# SET HEAT MODE
# ============================================================

function set_heat_mode!(

    device::HairStraightener,

    mode::HeatMode

)

    device.heat_mode = mode

    device.thermal.target_temperature_c =

        target_for_mode(

            mode

        )

end


# ============================================================
# BOOST
# ============================================================

function boost!(

    device::HairStraightener

)

    device.state = BOOST

    set_heat_mode!(

        device,

        BOOST_HEAT

    )

end


# ============================================================
# COOL DOWN
# ============================================================

function cool_down!(

    device::HairStraightener

)

    device.state = COOLING

    device.thermal.target_temperature_c =

        30.0

end


# ============================================================
# SHUTDOWN
# ============================================================

function shutdown!(

    device::HairStraightener

)

    device.thermal.left_plate.heater_power_percent = 0.0

    device.thermal.right_plate.heater_power_percent = 0.0

    device.state = OFF

end


# ============================================================
# CONTROL LOOP
# ============================================================

function control_step!(

    device::HairStraightener,

    dt::Float64=0.01

)

    device.elapsed_s += dt


    # --------------------------------------------------------
    # SAFETY FIRST
    # --------------------------------------------------------

    if !check_safety!(

        device.safety,

        device.thermal

    )

        device.state =

            device.safety.thermal_fault ?

            OVERHEAT :

            FAULT


        shutdown!(

            device

        )

        return

    end


    # --------------------------------------------------------
    # TEMPERATURE TARGET
    # --------------------------------------------------------

    if device.state == HEATING ||

       device.state == READY ||

       device.state == STYLING ||

       device.state == BOOST

        device.thermal.target_temperature_c =

            target_for_mode(

                device.heat_mode

            )

    elseif device.state == COOLING ||

           device.state == SLEEP

        device.thermal.target_temperature_c =

            30.0
    end


    # --------------------------------------------------------
    # PID — LEFT PLATE
    # --------------------------------------------------------

    device.thermal.left_plate.
        heater_power_percent =

        pid_update!(

            device.thermal.left_pid,

            device.thermal.target_temperature_c,

            device.thermal.left_plate.
                sensor.temperature_c,

            dt

        )


    # --------------------------------------------------------
    # PID — RIGHT PLATE
    # --------------------------------------------------------

    device.thermal.right_plate.
        heater_power_percent =

        pid_update!(

            device.thermal.right_pid,

            device.thermal.target_temperature_c,

            device.thermal.right_plate.
                sensor.temperature_c,

            dt

        )


    # --------------------------------------------------------
    # THERMAL UPDATE
    # --------------------------------------------------------

    update_plate_temperature!(

        device.thermal.left_plate,

        dt

    )


    update_plate_temperature!(

        device.thermal.right_plate,

        dt

    )


    # --------------------------------------------------------
    # PLATE BALANCING
    # --------------------------------------------------------

    balance_plates!(

        device.thermal

    )


    # --------------------------------------------------------
    # READY DETECTION
    # --------------------------------------------------------

    average_temperature =

        (

            device.thermal.left_plate.
                sensor.temperature_c +

            device.thermal.right_plate.
                sensor.temperature_c

        ) / 2.0


    if device.state == HEATING &&

       abs(

           average_temperature -

           device.thermal.target_temperature_c

       ) < 2.0

        device.state = READY

    end


    # --------------------------------------------------------
    # STYLING
    # --------------------------------------------------------

    if device.state == READY &&

       device.contact.contact_detected

        device.state = STYLING

    end


    update_styling!(

        device.styling,

        device.contact,

        device.thermal,

        dt

    )


    # --------------------------------------------------------
    # SLEEP
    # --------------------------------------------------------

    sleep_triggered =

        update_sleep!(

            device.sleep_controller,

            device.contact.contact_detected,

            dt

        )


    if sleep_triggered &&

       device.state != COOLING

        device.state = SLEEP

    end


    # --------------------------------------------------------
    # TELEMETRY
    # --------------------------------------------------------

    push!(

        device.telemetry.points,

        TelemetryPoint(

            now(),

            device.state,

            device.thermal.left_plate.
                sensor.temperature_c,

            device.thermal.right_plate.
                sensor.temperature_c,

            device.thermal.temperature_balance_c,

            device.thermal.left_plate.
                heater_power_percent,

            device.thermal.right_plate.
                heater_power_percent,

            device.contact.pressure_n,

            device.styling.styling_progress

        )

    )

end


# ============================================================
# CONTACT INPUT
# ============================================================

function set_contact_pressure!(

    device::HairStraightener,

    pressure_n::Float64,

    dt::Float64=0.01

)

    update_contact!(

        device.contact,

        pressure_n,

        dt

    )

end


# ============================================================
# USER DASHBOARD
# ============================================================

function dashboard(

    device::HairStraightener

)

    left =

        device.thermal.left_plate.sensor.temperature_c


    right =

        device.thermal.right_plate.sensor.temperature_c


    println()

    println("="^84)

    println(

        "                         STRAIGHT.OS"

    )

    println(

        "              INTELLIGENT HAIR STRAIGHTENER"

    )

    println("="^84)

    println()


    println(

        "DEVICE          : ",

        device.name

    )


    println(

        "STATE           : ",

        device.state

    )


    println(

        "HEAT MODE       : ",

        device.heat_mode

    )


    println()


    println(

        @sprintf(

            "LEFT PLATE      : %8.2f °C",

            left

        )

    )


    println(

        @sprintf(

            "RIGHT PLATE     : %8.2f °C",

            right

        )

    )


    println(

        @sprintf(

            "TARGET          : %8.2f °C",

            device.thermal.target_temperature_c

        )

    )


    println(

        @sprintf(

            "PLATE DELTA     : %8.2f °C",

            abs(left - right)

        )

    )


    println()


    println(

        @sprintf(

            "LEFT HEATER     : %8.1f %%",

            device.thermal.left_plate.
                heater_power_percent

        )

    )


    println(

        @sprintf(

            "RIGHT HEATER    : %8.1f %%",

            device.thermal.right_plate.
                heater_power_percent

        )

    )


    println()


    println(

        @sprintf(

            "CONTACT         : %8.2f N",

            device.contact.pressure_n

        )

    )


    println(

        "PASS COUNT      : ",

        device.contact.pass_count

    )


    println(

        @sprintf(

            "STYLE PROGRESS  : %8.1f %%",

            device.styling.styling_progress * 100.0

        )

    )


    println()


    println(

        "SAFETY          : ",

        device.safety.fault_message == "" ?

        "OK" :

        device.safety.fault_message

    )


    println()

    println("="^84)

end


# ============================================================
# PERFORMANCE REPORT
# ============================================================

function performance_report(

    device::HairStraightener

)

    points =

        device.telemetry.points


    isempty(points) &&

        return nothing


    left_temps =

        [

            p.left_temperature_c

            for p in points

        ]


    right_temps =

        [

            p.right_temperature_c

            for p in points

        ]


    deltas =

        [

            p.temperature_difference_c

            for p in points

        ]


    (

        runtime_s =

            device.elapsed_s,

        average_left_temperature =

            mean(left_temps),

        average_right_temperature =

            mean(right_temps),

        maximum_temperature =

            max(

                maximum(left_temps),

                maximum(right_temps)

            ),

        maximum_plate_difference =

            maximum(deltas),

        passes =

            device.contact.pass_count,

        styling_progress =

            device.styling.styling_progress * 100.0,

        final_state =

            device.state

    )

end


# ============================================================
# DIGITAL-TWIN DEMONSTRATION
# ============================================================

function simulate()

    device =

        HairStraightener(

            "STRAIGHTOS-LAB-001"

        )


    println()

    println(

        "BOOTING STRAIGHT.OS..."

    )


    power_on!(

        device

    )


    set_heat_mode!(

        device,

        NORMAL_HEAT

    )


    # --------------------------------------------------------
    # HEATING PHASE
    # --------------------------------------------------------

    for tick in 1:25000

        control_step!(

            device,

            0.01

        )


        if tick % 5000 == 0

            dashboard(

                device

            )

        end

    end


    # --------------------------------------------------------
    # SIMULATED HAIR PASSES
    # --------------------------------------------------------

    for pass in 1:6

        for tick in 1:1500

            pressure =

                5.0 +

                1.5 *

                sin(

                    tick / 100.0

                )


            set_contact_pressure!(

                device,

                pressure,

                0.01

            )


            control_step!(

                device,

                0.01

            )

        end


        for tick in 1:500

            set_contact_pressure!(

                device,

                0.0,

                0.01

            )


            control_step!(

                device,

                0.01

            )

        end

    end


    dashboard(

        device

    )


    result =

        performance_report(

            device

        )


    println()

    println("="^84)

    println(

        "                    PERFORMANCE REPORT"

    )

    println("="^84)

    println()


    println(

        @sprintf(

            "Runtime                  : %.1f s",

            result.runtime_s

        )

    )


    println(

        @sprintf(

            "Average left temperature : %.2f °C",

            result.average_left_temperature

        )

    )


    println(

        @sprintf(

            "Average right temperature: %.2f °C",

            result.average_right_temperature

        )

    )


    println(

        @sprintf(

            "Maximum temperature      : %.2f °C",

            result.maximum_temperature

        )

    )


    println(

        @sprintf(

            "Maximum plate delta      : %.2f °C",

            result.maximum_plate_difference

        )

    )


    println(

        "Detected passes          : ",

        result.passes

    )


    println(

        @sprintf(

            "Styling progress         : %.2f %%",

            result.styling_progress

        )

    )


    println(

        "Final state              : ",

        result.final_state

    )


    println()

    println("="^84)

end


# ============================================================
# EXPORTS
# ============================================================

export HairStraightener
export HeatMode

export power_on!
export set_heat_mode!
export boost!
export cool_down!
export shutdown!

export set_contact_pressure!
export control_step!

export dashboard
export performance_report
export simulate


end


# ============================================================
# APPLICATION ENTRY
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .StraightOS

    StraightOS.simulate()

end
```

