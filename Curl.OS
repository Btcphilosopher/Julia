# CURL.OS

## Intelligent Hair Curler & Styler Control System

### Pure Julia — Thermal, Rotation, Timing & Safety Engine

```julia
module CurlOS

using Dates
using Printf
using Statistics


# ============================================================
# CURL.OS
# INTELLIGENT CURLER / MULTI-STYLER CONTROL SYSTEM
# ============================================================
#
# SYSTEMS
#
#   • Heated barrel control
#   • Closed-loop temperature regulation
#   • Adjustable styling temperature
#   • Barrel rotation
#   • Curl direction control
#   • Hair-contact detection
#   • Styling timer
#   • Adaptive heat compensation
#   • Heat-soak management
#   • Cool-shot mode
#   • Automatic sleep
#   • Thermal protection
#   • Motor protection
#   • Sensor fault detection
#   • Digital telemetry
#
# This is a control-system simulation/reference architecture.
# A production mains appliance requires independently validated
# hardware safety systems, thermal fuses, isolation, EMC testing,
# motor protection and applicable appliance certification.
#
# ============================================================


# ============================================================
# ENUMERATIONS
# ============================================================

@enum StylerState begin
    OFF
    BOOT
    READY
    HEATING
    STYLING
    ROTATING
    COOLING
    COOL_SHOT
    SLEEP
    FAULT
    OVERHEAT
    EMERGENCY_STOP
end


@enum HeatProfile begin
    GENTLE
    NORMAL
    FAST_STYLE
    HIGH_HEAT
end


@enum CurlDirection begin
    NONE
    CLOCKWISE
    COUNTERCLOCKWISE
    ALTERNATING
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

    initial_temperature::Float64 = 22.0

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
    temperature::Float64,
    dt::Float64

)

    sensor.previous_temperature_c =

        sensor.temperature_c


    sensor.temperature_c =

        temperature


    sensor.rate_c_s =

        (

            temperature -
            sensor.previous_temperature_c

        ) /

        max(dt, 0.0001)


    sensor.valid =

        isfinite(temperature)

end


# ============================================================
# BARREL
# ============================================================

mutable struct Barrel

    diameter_mm::Float64

    sensor::TemperatureSensor

    target_temperature_c::Float64

    heater_power_percent::Float64

    thermal_mass::Float64

    thermal_loss::Float64

    maximum_temperature_c::Float64

end


function Barrel(

    diameter_mm::Float64 = 25.0

)

    Barrel(

        diameter_mm,

        TemperatureSensor(),

        180.0,

        0.0,

        1.0,

        0.014,

        230.0

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


PIDController() =

    PIDController(

        3.0,
        0.10,
        0.40,

        0.0,
        0.0

    )


function pid!(

    controller::PIDController,

    target::Float64,

    measured::Float64,

    dt::Float64

)

    error =

        target -
        measured


    controller.integral +=

        error * dt


    controller.integral =

        clamp(

            controller.integral,

            -100.0,
            100.0

        )


    derivative =

        (

            error -
            controller.previous_error

        ) /

        max(dt, 0.0001)


    output =

        controller.kp * error +

        controller.ki * controller.integral +

        controller.kd * derivative


    controller.previous_error =

        error


    clamp(

        output,

        0.0,
        100.0

    )

end


# ============================================================
# ROTATION MOTOR
# ============================================================

mutable struct RotationMotor

    direction::CurlDirection

    target_rpm::Float64
    actual_rpm::Float64

    current_a::Float64

    maximum_rpm::Float64

end


function RotationMotor()

    RotationMotor(

        NONE,

        0.0,
        0.0,

        0.0,

        30.0

    )

end


function set_rotation!(

    motor::RotationMotor,

    direction::CurlDirection,

    rpm::Float64

)

    motor.direction = direction

    motor.target_rpm =

        clamp(

            rpm,

            0.0,

            motor.maximum_rpm

        )

end


function update_motor!(

    motor::RotationMotor,

    dt::Float64

)

    motor.actual_rpm +=

        (

            motor.target_rpm -
            motor.actual_rpm

        ) *

        min(

            dt * 10.0,

            1.0

        )


    motor.current_a =

        0.25 +

        (

            motor.actual_rpm /
            motor.maximum_rpm

        )^2 *

        1.5


    if motor.direction == NONE

        motor.actual_rpm *=

            max(

                0.0,

                1.0 - dt * 15.0

            )

    end

end


# ============================================================
# HAIR CONTACT SENSOR
# ============================================================

mutable struct ContactSensor

    pressure_n::Float64
    contact::Bool

    contact_time_s::Float64

    strand_detected::Bool

end


function ContactSensor()

    ContactSensor(

        0.0,
        false,
        0.0,
        false

    )

end


function update_contact!(

    sensor::ContactSensor,

    pressure_n::Float64,

    dt::Float64

)

    sensor.pressure_n =

        max(

            pressure_n,

            0.0

        )


    sensor.contact =

        pressure_n > 0.8


    sensor.strand_detected =

        pressure_n > 1.2


    if sensor.contact

        sensor.contact_time_s += dt

    else

        sensor.contact_time_s = 0.0
    end

end


# ============================================================
# STYLING TIMER
# ============================================================

mutable struct StyleTimer

    target_time_s::Float64
    elapsed_s::Float64

    complete::Bool

end


StyleTimer() =

    StyleTimer(

        8.0,
        0.0,
        false

    )


function reset!(

    timer::StyleTimer

)

    timer.elapsed_s = 0.0

    timer.complete = false

end


function update_timer!(

    timer::StyleTimer,

    active::Bool,

    dt::Float64

)

    if active

        timer.elapsed_s += dt
    end


    timer.complete =

        timer.elapsed_s >=

        timer.target_time_s

end


# ============================================================
# STYLE PROFILE
# ============================================================

function temperature_for_profile(

    profile::HeatProfile

)

    if profile == GENTLE

        return 150.0

    elseif profile == NORMAL

        return 180.0

    elseif profile == FAST_STYLE

        return 195.0

    elseif profile == HIGH_HEAT

        return 205.0

    end


    return 180.0

end


function style_time_for_profile(

    profile::HeatProfile

)

    if profile == GENTLE

        return 10.0

    elseif profile == NORMAL

        return 8.0

    elseif profile == FAST_STYLE

        return 6.0

    elseif profile == HIGH_HEAT

        return 5.0

    end


    return 8.0

end


# ============================================================
# ADAPTIVE STYLING ENGINE
# ============================================================

mutable struct AdaptiveStyler

    heat_demand::Float64
    contact_factor::Float64

    thermal_recovery::Float64

    curl_progress::Float64

    strand_load::Float64

end


function AdaptiveStyler()

    AdaptiveStyler(

        0.0,
        0.0,
        0.0,
        0.0,
        0.0

    )

end


function update_adaptive!(

    adaptive::AdaptiveStyler,

    barrel::Barrel,

    contact::ContactSensor,

    motor::RotationMotor,

    dt::Float64

)

    adaptive.contact_factor =

        clamp(

            contact.pressure_n / 8.0,

            0.0,
            1.0

        )


    adaptive.strand_load =

        adaptive.contact_factor


    temperature_factor =

        clamp(

            (

                barrel.sensor.temperature_c -
                100.0

            ) / 100.0,

            0.0,
            1.0

        )


    adaptive.heat_demand =

        adaptive.contact_factor *

        (

            1.0 -
            temperature_factor

        )


    adaptive.thermal_recovery =

        clamp(

            -

            barrel.sensor.rate_c_s,

            0.0,
            20.0

        )


    if contact.contact

        adaptive.curl_progress +=

            (

                0.0005 +

                0.0005 *
                adaptive.contact_factor

            ) * dt

    end


    adaptive.curl_progress =

        clamp(

            adaptive.curl_progress,

            0.0,
            1.0

        )

end


# ============================================================
# SAFETY
# ============================================================

mutable struct SafetyController

    maximum_temperature_c::Float64
    maximum_motor_current_a::Float64
    maximum_motor_rpm::Float64

    thermal_fault::Bool
    motor_fault::Bool
    sensor_fault::Bool

    emergency_stop::Bool

    message::String

end


function SafetyController()

    SafetyController(

        225.0,
        3.0,
        35.0,

        false,
        false,
        false,

        false,

        ""

    )

end


function safety_check!(

    safety::SafetyController,

    barrel::Barrel,

    motor::RotationMotor

)

    safety.thermal_fault =

        barrel.sensor.temperature_c >=
        safety.maximum_temperature_c


    safety.motor_fault =

        motor.current_a >
        safety.maximum_motor_current_a ||

        motor.actual_rpm >
        safety.maximum_motor_rpm


    safety.sensor_fault =

        !barrel.sensor.valid


    if safety.emergency_stop

        safety.message =

            "EMERGENCY STOP"

        return false

    elseif safety.thermal_fault

        safety.message =

            "OVER-TEMPERATURE"

        return false

    elseif safety.motor_fault

        safety.message =

            "MOTOR FAULT"

        return false

    elseif safety.sensor_fault

        safety.message =

            "TEMPERATURE SENSOR FAULT"

        return false

    end


    safety.message = ""

    return true

end


# ============================================================
# SLEEP SYSTEM
# ============================================================

mutable struct SleepSystem

    timeout_s::Float64
    inactive_s::Float64
    enabled::Bool

end


SleepSystem() =

    SleepSystem(

        600.0,
        0.0,
        true

    )


function update_sleep!(

    sleep_system::SleepSystem,

    activity::Bool,

    dt::Float64

)

    if activity

        sleep_system.inactive_s = 0.0

    else

        sleep_system.inactive_s += dt
    end


    sleep_system.enabled &&

    sleep_system.inactive_s >=

    sleep_system.timeout_s

end


# ============================================================
# TELEMETRY
# ============================================================

struct TelemetryPoint

    timestamp::DateTime

    state::StylerState

    barrel_temperature_c::Float64
    target_temperature_c::Float64

    heater_power_percent::Float64

    motor_rpm::Float64
    motor_current_a::Float64

    contact_pressure_n::Float64
    style_time_s::Float64

    curl_progress::Float64

end


mutable struct Telemetry

    points::Vector{TelemetryPoint}

end


Telemetry() =

    Telemetry(

        TelemetryPoint[]

    )


# ============================================================
# CURLER
# ============================================================

mutable struct HairStyler

    name::String

    state::StylerState

    heat_profile::HeatProfile

    direction::CurlDirection

    barrel::Barrel
    pid::PIDController
    motor::RotationMotor

    contact::ContactSensor
    timer::StyleTimer
    adaptive::AdaptiveStyler

    safety::SafetyController
    sleep::SleepSystem

    telemetry::Telemetry

    elapsed_s::Float64

end


function HairStyler(

    name="CURLOS-001",

    barrel_diameter_mm=25.0

)

    HairStyler(

        name,

        OFF,

        NORMAL,

        CLOCKWISE,

        Barrel(barrel_diameter_mm),
        PIDController(),
        RotationMotor(),

        ContactSensor(),
        StyleTimer(),
        AdaptiveStyler(),

        SafetyController(),
        SleepSystem(),

        Telemetry(),

        0.0

    )

end


# ============================================================
# POWER ON
# ============================================================

function power_on!(

    device::HairStyler

)

    device.state = BOOT

    device.elapsed_s = 0.0

    device.state = HEATING

end


# ============================================================
# PROFILE
# ============================================================

function set_profile!(

    device::HairStyler,

    profile::HeatProfile

)

    device.heat_profile = profile

    device.barrel.target_temperature_c =

        temperature_for_profile(profile)


    device.timer.target_time_s =

        style_time_for_profile(profile)

end


# ============================================================
# ROTATION
# ============================================================

function rotate!(

    device::HairStyler,

    direction::CurlDirection,

    rpm::Float64=12.0

)

    device.direction = direction

    set_rotation!(

        device.motor,

        direction,

        rpm

    )


    device.state = ROTATING

end


# ============================================================
# COOL SHOT
# ============================================================

function cool_shot!(

    device::HairStyler

)

    device.state = COOL_SHOT

    device.barrel.target_temperature_c =

        30.0

    device.motor.target_rpm = 0.0

end


# ============================================================
# SHUTDOWN
# ============================================================

function shutdown!(

    device::HairStyler

)

    device.barrel.heater_power_percent =

        0.0

    device.motor.target_rpm =

        0.0

    device.motor.direction =

        NONE

    device.state =

        OFF

end


# ============================================================
# CONTACT INPUT
# ============================================================

function set_hair_contact!(

    device::HairStyler,

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
# MAIN CONTROL LOOP
# ============================================================

function control_step!(

    device::HairStyler,

    dt::Float64=0.01

)

    device.elapsed_s += dt


    # --------------------------------------------------------
    # SAFETY
    # --------------------------------------------------------

    if !safety_check!(

        device.safety,

        device.barrel,

        device.motor

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
    # TEMPERATURE CONTROL
    # --------------------------------------------------------

    if device.state != OFF &&

       device.state != FAULT &&

       device.state != OVERHEAT

        device.barrel.heater_power_percent =

            pid!(

                device.pid,

                device.barrel.target_temperature_c,

                device.barrel.sensor.temperature_c,

                dt

            )

    end


    # --------------------------------------------------------
    # BARREL THERMAL MODEL
    # --------------------------------------------------------

    heat_input =

        device.barrel.heater_power_percent *

        0.42


    thermal_loss =

        max(

            device.barrel.sensor.temperature_c -
            22.0,

            0.0

        ) *

        device.barrel.thermal_loss


    thermal_rate =

        (

            heat_input -
            thermal_loss

        ) /

        device.barrel.thermal_mass


    new_temperature =

        device.barrel.sensor.temperature_c +

        thermal_rate * dt


    update_sensor!(

        device.barrel.sensor,

        new_temperature,

        dt

    )


    # --------------------------------------------------------
    # MOTOR
    # --------------------------------------------------------

    update_motor!(

        device.motor,

        dt

    )


    # --------------------------------------------------------
    # READY
    # --------------------------------------------------------

    temperature_error =

        abs(

            device.barrel.sensor.temperature_c -

            device.barrel.target_temperature_c

        )


    if device.state == HEATING &&

       temperature_error < 2.0

        device.state = READY

    end


    # --------------------------------------------------------
    # CONTACT
    # --------------------------------------------------------

    if device.contact.contact &&

       (

           device.state == READY ||

           device.state == ROTATING

       )

        device.state = STYLING

    end


    # --------------------------------------------------------
    # TIMER
    # --------------------------------------------------------

    update_timer!(

        device.timer,

        device.contact.contact,

        dt

    )


    # --------------------------------------------------------
    # ADAPTIVE ENGINE
    # --------------------------------------------------------

    update_adaptive!(

        device.adaptive,

        device.barrel,

        device.contact,

        device.motor,

        dt

    )


    # --------------------------------------------------------
    # AUTOMATIC CURL COMPLETION
    # --------------------------------------------------------

    if device.timer.complete &&

       device.state == STYLING

        device.state = COOLING

        device.barrel.target_temperature_c =

            40.0

        device.motor.target_rpm =

            0.0

    end


    # --------------------------------------------------------
    # SLEEP
    # --------------------------------------------------------

    sleeping =

        update_sleep!(

            device.sleep,

            device.contact.contact,

            dt

        )


    if sleeping

        device.state = SLEEP

        device.barrel.target_temperature_c =

            30.0

        device.motor.target_rpm =

            0.0

    end


    # --------------------------------------------------------
    # TELEMETRY
    # --------------------------------------------------------

    push!(

        device.telemetry.points,

        TelemetryPoint(

            now(),

            device.state,

            device.barrel.sensor.temperature_c,

            device.barrel.target_temperature_c,

            device.barrel.heater_power_percent,

            device.motor.actual_rpm,

            device.motor.current_a,

            device.contact.pressure_n,

            device.timer.elapsed_s,

            device.adaptive.curl_progress

        )

    )

end


# ============================================================
# DASHBOARD
# ============================================================

function dashboard(

    device::HairStyler

)

    println()

    println("="^86)

    println(

        "                            CURL.OS"

    )

    println(

        "              INTELLIGENT HAIR CURLER / STYLER"

    )

    println("="^86)

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

        "PROFILE         : ",

        device.heat_profile

    )


    println(

        "DIRECTION       : ",

        device.direction

    )


    println()


    println(

        @sprintf(

            "BARREL TEMP     : %8.2f °C",

            device.barrel.sensor.temperature_c

        )

    )


    println(

        @sprintf(

            "TARGET TEMP     : %8.2f °C",

            device.barrel.target_temperature_c

        )

    )


    println(

        @sprintf(

            "HEATER          : %8.1f %%",

            device.barrel.heater_power_percent

        )

    )


    println()


    println(

        @sprintf(

            "MOTOR RPM       : %8.2f",

            device.motor.actual_rpm

        )

    )


    println(

        @sprintf(

            "MOTOR CURRENT   : %8.2f A",

            device.motor.current_a

        )

    )


    println()


    println(

        @sprintf(

            "HAIR PRESSURE   : %8.2f N",

            device.contact.pressure_n

        )

    )


    println(

        @sprintf(

            "STYLE TIMER     : %8.2f s",

            device.timer.elapsed_s

        )

    )


    println(

        @sprintf(

            "STYLE PROGRESS  : %8.1f %%",

            device.adaptive.curl_progress * 100.0

        )

    )


    println()


    println(

        "SAFETY          : ",

        device.safety.message == "" ?

        "OK" :

        device.safety.message

    )


    println()

    println("="^86)

end


# ============================================================
# PERFORMANCE REPORT
# ============================================================

function performance_report(

    device::HairStyler

)

    points =

        device.telemetry.points


    isempty(points) &&

        return nothing


    temperatures =

        [

            p.barrel_temperature_c

            for p in points

        ]


    motor_rpm =

        [

            p.motor_rpm

            for p in points

        ]


    (

        runtime_s =

            device.elapsed_s,

        average_temperature_c =

            mean(temperatures),

        maximum_temperature_c =

            maximum(temperatures),

        average_motor_rpm =

            mean(motor_rpm),

        maximum_motor_rpm =

            maximum(motor_rpm),

        final_curl_progress =

            device.adaptive.curl_progress * 100.0,

        final_state =

            device.state

    )

end


# ============================================================
# DIGITAL-TWIN SIMULATION
# ============================================================

function simulate()

    device =

        HairStyler(

            "CURLOS-LAB-001",

            25.0

        )


    println()

    println(

        "BOOTING CURL.OS..."

    )


    power_on!(

        device

    )


    set_profile!(

        device,

        NORMAL

    )


    # --------------------------------------------------------
    # HEATING
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
    # CURL PASSES
    # --------------------------------------------------------

    for curl in 1:8

        reset!(

            device.timer

        )


        rotate!(

            device,

            curl % 2 == 0 ?

            CLOCKWISE :

            COUNTERCLOCKWISE,

            12.0

        )


        for tick in 1:1200

            pressure =

                4.0 +

                1.0 *

                sin(

                    tick / 80.0

                )


            set_hair_contact!(

                device,

                pressure,

                0.01

            )


            control_step!(

                device,

                0.01

            )

        end


        set_hair_contact!(

            device,

            0.0,

            0.01

        )


        control_step!(

            device,

            0.01

        )

    end


    # --------------------------------------------------------
    # COOL DOWN
    # --------------------------------------------------------

    cool_shot!(

        device

    )


    for tick in 1:5000

        control_step!(

            device,

            0.01

        )

    end


    dashboard(

        device

    )


    result =

        performance_report(

            device

        )


    println()

    println("="^86)

    println(

        "                       PERFORMANCE REPORT"

    )

    println("="^86)

    println()


    println(

        @sprintf(

            "Runtime                 : %.1f s",

            result.runtime_s

        )

    )


    println(

        @sprintf(

            "Average barrel temp    : %.2f °C",

            result.average_temperature_c

        )

    )


    println(

        @sprintf(

            "Maximum barrel temp    : %.2f °C",

            result.maximum_temperature_c

        )

    )


    println(

        @sprintf(

            "Average motor speed    : %.2f RPM",

            result.average_motor_rpm

        )

    )


    println(

        @sprintf(

            "Maximum motor speed    : %.2f RPM",

            result.maximum_motor_rpm

        )

    )


    println(

        @sprintf(

            "Curl progress           : %.2f %%",

            result.final_curl_progress

        )

    )


    println(

        "Final state             : ",

        result.final_state

    )


    println()

    println("="^86)

end


# ============================================================
# EXPORTS
# ============================================================

export HairStyler
export HeatProfile
export CurlDirection

export power_on!
export set_profile!
export rotate!
export cool_shot!
export shutdown!

export set_hair_contact!
export control_step!

export dashboard
export performance_report
export simulate


end


# ============================================================
# APPLICATION ENTRY
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .CurlOS

    CurlOS.simulate()

end
```

