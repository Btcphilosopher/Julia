# KILNOS — INDUSTRIAL KILN AUTOMATION

## Pure Julia

```julia
module KilnOS

using Dates
using Printf


# ============================================================
# KILNOS
#
# Industrial kiln-control simulator.
#
# Features:
#   - programmable firing schedules
#   - ramp/soak control
#   - PID temperature control
#   - thermocouple simulation
#   - heater control
#   - cooling phase
#   - batch management
#   - alarm handling
#   - emergency shutdown
#   - telemetry
#
# The thermal model is intentionally a simulation.
# Real hardware requires independent safety controls.
# ============================================================


# ============================================================
# TEMPERATURE
# ============================================================

struct Temperature

    celsius::Float64

end


Temperature(x::Real) =
    Temperature(Float64(x))


fahrenheit(t::Temperature) =
    t.celsius * 9.0 / 5.0 + 32.0


# ============================================================
# KILN STATES
# ============================================================

@enum KilnState begin

    IDLE

    PREHEAT

    RAMPING

    SOAKING

    COOLING

    COMPLETE

    FAULT

    EMERGENCY_STOP

end


# ============================================================
# ALARM TYPES
# ============================================================

@enum AlarmType begin

    HIGH_TEMPERATURE

    SENSOR_FAILURE

    HEATER_FAILURE

    PROGRAM_ERROR

    DOOR_OPEN

    EMERGENCY

end


struct Alarm

    type::AlarmType

    message::String

    timestamp::DateTime

end


# ============================================================
# THERMOCOUPLE
# ============================================================

mutable struct Thermocouple

    name::String

    temperature::Temperature

    minimum::Float64

    maximum::Float64

    healthy::Bool

end


function Thermocouple(

    name::String;

    initial=20.0,

    minimum=0.0,

    maximum=1400.0

)

    Thermocouple(

        name,

        Temperature(initial),

        minimum,

        maximum,

        true

    )

end


function read(
    sensor::Thermocouple
)

    sensor.healthy ||
        error(
            "Thermocouple failure."
        )

    sensor.temperature

end


# ============================================================
# HEATER
# ============================================================

mutable struct Heater

    name::String

    enabled::Bool

    power::Float64

    maximum_power::Float64

end


function Heater(

    name::String="Main Heater";

    maximum_power=100.0

)

    Heater(

        name,

        false,

        0.0,

        Float64(maximum_power)

    )

end


function shutdown!(
    heater::Heater
)

    heater.enabled =
        false

    heater.power =
        0.0

end


# ============================================================
# PID
# ============================================================

mutable struct PID

    kp::Float64

    ki::Float64

    kd::Float64

    integral::Float64

    previous_error::Float64

end


function PID(

    kp::Real=0.8,

    ki::Real=0.015,

    kd::Real=0.1

)

    PID(

        Float64(kp),

        Float64(ki),

        Float64(kd),

        0.0,

        0.0

    )

end


function reset!(
    pid::PID
)

    pid.integral =
        0.0

    pid.previous_error =
        0.0

end


function update!(

    pid::PID,

    target::Float64,

    actual::Float64,

    dt::Float64

)

    error =
        target - actual

    pid.integral +=
        error * dt

    derivative =
        dt > 0 ?
        (error - pid.previous_error) / dt :
        0.0

    pid.previous_error =
        error

    output =
        pid.kp * error +
        pid.ki * pid.integral +
        pid.kd * derivative

    clamp(
        output,
        0.0,
        100.0
    )

end


# ============================================================
# FIRING STAGE
# ============================================================

struct FiringStage

    name::String

    target::Temperature

    ramp_rate::Float64

    soak_minutes::Float64

end


# ============================================================
# FIRING PROGRAM
# ============================================================

mutable struct FiringProgram

    name::String

    stages::Vector{FiringStage}

    current_stage::Int

    soak_elapsed::Float64

end


function FiringProgram(

    name::String,

    stages::Vector{FiringStage}

)

    isempty(stages) &&
        error(
            "Kiln programme cannot be empty."
        )

    FiringProgram(

        name,

        stages,

        1,

        0.0

    )

end


function current_stage(
    program::FiringProgram
)

    if program.current_stage >
       length(program.stages)

        return nothing

    end

    program.stages[
        program.current_stage
    ]

end


# ============================================================
# BATCH
# ============================================================

mutable struct Batch

    id::String

    material::String

    quantity::Float64

    started::Union{Nothing,DateTime}

    completed::Union{Nothing,DateTime}

end


function Batch(

    id::String,

    material::String,

    quantity::Real

)

    Batch(

        id,

        material,

        Float64(quantity),

        nothing,

        nothing

    )

end


# ============================================================
# KILN
# ============================================================

mutable struct Kiln

    name::String

    sensor::Thermocouple

    heater::Heater

    pid::PID

    program::FiringProgram

    batch::Union{Nothing,Batch}

    state::KilnState

    alarms::Vector{Alarm}

    ambient_temperature::Float64

    maximum_safe_temperature::Float64

    thermal_mass::Float64

    cooling_rate::Float64

    elapsed::Float64

end


# ============================================================
# CONSTRUCTOR
# ============================================================

function Kiln(

    name::String,

    program::FiringProgram;

    ambient_temperature=20.0,

    maximum_safe_temperature=1300.0,

    thermal_mass=1.0,

    cooling_rate=0.8

)

    Kiln(

        name,

        Thermocouple(
            "TC-01";
            initial=ambient_temperature
        ),

        Heater(
            "Heating Elements"
        ),

        PID(),

        program,

        nothing,

        IDLE,

        Alarm[],

        Float64(ambient_temperature),

        Float64(maximum_safe_temperature),

        Float64(thermal_mass),

        Float64(cooling_rate),

        0.0

    )

end


# ============================================================
# BATCH LOADING
# ============================================================

function load_batch!(

    kiln::Kiln,

    batch::Batch

)

    kiln.state == IDLE ||
        error(
            "Kiln must be idle to load a batch."
        )

    kiln.batch =
        batch

end


# ============================================================
# ALARM
# ============================================================

function raise_alarm!(

    kiln::Kiln,

    alarm_type::AlarmType,

    message::String

)

    alarm =
        Alarm(

            alarm_type,

            message,

            now()

        )

    push!(
        kiln.alarms,
        alarm
    )

    alarm

end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(
    kiln::Kiln
)

    shutdown!(
        kiln.heater
    )

    kiln.state =
        EMERGENCY_STOP

    raise_alarm!(
        kiln,
        EMERGENCY,
        "Emergency stop activated."
    )

end


# ============================================================
# START
# ============================================================

function start!(
    kiln::Kiln
)

    kiln.state == IDLE ||
        error(
            "Kiln is not idle."
        )

    kiln.program.current_stage =
        1

    kiln.program.soak_elapsed =
        0.0

    kiln.elapsed =
        0.0

    reset!(
        kiln.pid
    )

    kiln.heater.enabled =
        true

    kiln.state =
        PREHEAT

    if kiln.batch !== nothing

        kiln.batch.started =
            now()

    end

end


# ============================================================
# STOP
# ============================================================

function stop!(
    kiln::Kiln
)

    shutdown!(
        kiln.heater
    )

    kiln.state =
        IDLE

end


# ============================================================
# SAFETY
# ============================================================

function safety_check!(
    kiln::Kiln
)

    temperature =
        kiln.sensor.temperature.celsius


    # --------------------------------------------------------
    # Sensor range
    # --------------------------------------------------------

    if !kiln.sensor.healthy

        raise_alarm!(
            kiln,

            SENSOR_FAILURE,

            "Thermocouple reported failure."

        )

        emergency_stop!(
            kiln

        )

        return false

    end


    # --------------------------------------------------------
    # Maximum temperature
    # --------------------------------------------------------

    if temperature >=
       kiln.maximum_safe_temperature

        raise_alarm!(
            kiln,

            HIGH_TEMPERATURE,

            "Maximum safe temperature exceeded."

        )

        emergency_stop!(
            kiln
        )

        return false

    end


    # --------------------------------------------------------
    # Sensor plausibility
    # --------------------------------------------------------

    if temperature <
       kiln.sensor.minimum ||
       temperature >
       kiln.sensor.maximum

        raise_alarm!(
            kiln,

            SENSOR_FAILURE,

            "Temperature outside sensor range."

        )

        emergency_stop!(
            kiln
        )

        return false

    end


    true

end


# ============================================================
# THERMAL SIMULATION
# ============================================================

function thermal_model!(
    kiln::Kiln,

    dt::Float64

)

    temperature =
        kiln.sensor.temperature.celsius

    ambient =
        kiln.ambient_temperature


    if kiln.state in
        (
            PREHEAT,
            RAMPING,
            SOAKING
        )

        heating =
            kiln.heater.enabled ?
            kiln.heater.power *
            7.5 /
            kiln.thermal_mass :
            0.0

        losses =
            0.012 *
            (temperature - ambient)

        delta =
            (
                heating -
                losses
            ) * dt

        temperature +=
            delta


    elseif kiln.state ==
           COOLING

        temperature -=
            kiln.cooling_rate *
            dt

        temperature =
            max(
                ambient,
                temperature
            )

    end


    kiln.sensor.temperature =
        Temperature(
            temperature
        )

end


# ============================================================
# STAGE CONTROL
# ============================================================

function update_stage!(
    kiln::Kiln,

    dt::Float64

)

    stage =
        current_stage(
            kiln.program
        )


    # --------------------------------------------------------
    # Programme complete
    # --------------------------------------------------------

    if stage === nothing

        kiln.heater.enabled =
            false

        kiln.heater.power =
            0.0

        kiln.state =
            COOLING

        return

    end


    actual =
        kiln.sensor.temperature.celsius

    target =
        stage.target.celsius


    # --------------------------------------------------------
    # Ramp
    # --------------------------------------------------------

    tolerance =
        3.0


    if abs(
        actual - target
    ) <= tolerance

        kiln.state =
            SOAKING

        kiln.program.soak_elapsed +=
            dt

    else

        kiln.state =
            RAMPING

        kiln.program.soak_elapsed =
            0.0

    end


    # --------------------------------------------------------
    # Soak completed
    # --------------------------------------------------------

    required_seconds =
        stage.soak_minutes *
        60.0


    if kiln.program.soak_elapsed >=
       required_seconds

        kiln.program.current_stage +=
            1

        kiln.program.soak_elapsed =
            0.0

        reset!(
            kiln.pid
        )

    end

end


# ============================================================
# COOLING CONTROL
# ============================================================

function update_cooling!(
    kiln::Kiln
)

    temperature =
        kiln.sensor.temperature.celsius


    if temperature <=
       kiln.ambient_temperature + 5.0

        kiln.state =
            COMPLETE

        if kiln.batch !== nothing

            kiln.batch.completed =
                now()

        end

    end

end


# ============================================================
# CONTROL LOOP
# ============================================================

function control_step!(

    kiln::Kiln,

    dt::Float64

)

    kiln.state in
        (
            PREHEAT,
            RAMPING,
            SOAKING
        ) || begin

        if kiln.state ==
           COOLING

            thermal_model!(
                kiln,
                dt
            )

            update_cooling!(
                kiln
            )

        end

        return

    end


    stage =
        current_stage(
            kiln.program
        )


    stage === nothing &&
        return


    actual =
        kiln.sensor.temperature.celsius

    target =
        stage.target.celsius


    # --------------------------------------------------------
    # PID
    # --------------------------------------------------------

    power =
        update!(
            kiln.pid,

            target,

            actual,

            dt

        )


    kiln.heater.power =
        power

    kiln.heater.enabled =
        power > 0.0


    # --------------------------------------------------------
    # Thermal system
    # --------------------------------------------------------

    thermal_model!(
        kiln,
        dt
    )


    kiln.elapsed +=
        dt


    # --------------------------------------------------------
    # Programme
    # --------------------------------------------------------

    update_stage!(
        kiln,
        dt
    )


    # --------------------------------------------------------
    # Safety
    # --------------------------------------------------------

    safety_check!(
        kiln
    )

end


# ============================================================
# TELEMETRY
# ============================================================

function telemetry(
    kiln::Kiln
)

    stage =
        current_stage(
            kiln.program
        )


    (

        kiln = kiln.name,

        state = kiln.state,

        temperature =
            kiln.sensor.temperature.celsius,

        target =
            stage === nothing ?
            nothing :
            stage.target.celsius,

        heater =
            kiln.heater.power,

        stage =
            kiln.program.current_stage,

        soak_seconds =
            kiln.program.soak_elapsed,

        elapsed =
            kiln.elapsed,

        batch =
            kiln.batch === nothing ?
            nothing :
            kiln.batch.id,

        alarms =
            length(
                kiln.alarms
            )

    )

end


# ============================================================
# CONSOLE DISPLAY
# ============================================================

function display!(
    kiln::Kiln
)

    t =
        telemetry(
            kiln
        )


    target =
        t.target === nothing ?
        0.0 :
        t.target


    println(
        @sprintf(

            "KILN %-12s | TEMP %7.1f°C | TARGET %7.1f°C | HEAT %6.1f%% | %-12s | STAGE %02d",

            t.kiln,

            t.temperature,

            target,

            t.heater,

            string(t.state),

            t.stage

        )
    )

end


# ============================================================
# FIRING LOG
# ============================================================

mutable struct TelemetryPoint

    timestamp::DateTime

    temperature::Float64

    target::Float64

    heater_power::Float64

    state::KilnState

end


mutable struct TelemetryLog

    points::Vector{TelemetryPoint}

end


TelemetryLog() =
    TelemetryLog(
        TelemetryPoint[]
    )


function record!(
    log::TelemetryLog,

    kiln::Kiln

)

    stage =
        current_stage(
            kiln.program
        )

    target =
        stage === nothing ?
        kiln.sensor.temperature.celsius :
        stage.target.celsius


    push!(
        log.points,

        TelemetryPoint(

            now(),

            kiln.sensor.temperature.celsius,

            target,

            kiln.heater.power,

            kiln.state

        )

    )

end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println()
    println("="^105)
    println("                         KILNOS")
    println("                  INDUSTRIAL KILN CONTROL")
    println("="^105)


    # --------------------------------------------------------
    # Firing programme
    # --------------------------------------------------------

    programme =
        FiringProgram(

            "Ceramic Firing",

            [

                FiringStage(

                    "Preheat",

                    Temperature(200),

                    100.0,

                    1.0

                ),

                FiringStage(

                    "Ramp",

                    Temperature(600),

                    150.0,

                    1.0

                ),

                FiringStage(

                    "High Fire",

                    Temperature(1100),

                    200.0,

                    2.0

                ),

                FiringStage(

                    "Peak Soak",

                    Temperature(1200),

                    100.0,

                    2.0

                )

            ]

        )


    # --------------------------------------------------------
    # Kiln
    # --------------------------------------------------------

    kiln =
        Kiln(

            "KILN-01",

            programme;

            maximum_safe_temperature=1250.0

        )


    # --------------------------------------------------------
    # Batch
    # --------------------------------------------------------

    batch =
        Batch(

            "BATCH-2026-001",

            "Stoneware",

            42.0

        )


    load_batch!(
        kiln,
        batch
    )


    println()
    println(
        "Batch loaded: ",
        batch.id
    )

    println(
        "Material: ",
        batch.material
    )

    println(
        "Quantity: ",
        batch.quantity
    )


    # --------------------------------------------------------
    # Start
    # --------------------------------------------------------

    start!(
        kiln
    )


    log =
        TelemetryLog()


    # --------------------------------------------------------
    # Simulation
    # --------------------------------------------------------

    for second in 1:5000

        control_step!(
            kiln,
            1.0
        )

        record!(
            log,
            kiln
        )


        if second % 30 == 0

            display!(
                kiln
            )

        end


        if kiln.state in
            (
                COMPLETE,
                FAULT,
                EMERGENCY_STOP
            )

            break

        end

    end


    println()
    println(
        "-----------------------------------------------"
    )

    println(
        "FINAL STATE: ",
        kiln.state
    )

    println(
        "FINAL TEMPERATURE: ",
        round(
            kiln.sensor.temperature.celsius,
            digits=1
        ),
        " °C"
    )

    println(
        "TELEMETRY POINTS: ",
        length(
            log.points
        )
    )

    println(
        "ALARMS: ",
        length(
            kiln.alarms
        )
    )


    if kiln.batch !== nothing

        println(
            "BATCH: ",
            kiln.batch.id
        )

    end


    println(
        "-----------------------------------------------"
    )

end


# ============================================================
# EXPORTS
# ============================================================

export Temperature

export KilnState
export IDLE
export PREHEAT
export RAMPING
export SOAKING
export COOLING
export COMPLETE
export FAULT
export EMERGENCY_STOP

export AlarmType
export HIGH_TEMPERATURE
export SENSOR_FAILURE
export HEATER_FAILURE
export PROGRAM_ERROR
export DOOR_OPEN
export EMERGENCY

export Alarm

export Thermocouple
export Heater
export PID

export FiringStage
export FiringProgram

export Batch

export Kiln

export TelemetryPoint
export TelemetryLog

export load_batch!
export start!
export stop!
export emergency_stop!

export safety_check!
export control_step!

export telemetry
export record!
export display!

export demo


end # module


# ============================================================
# RUN
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .KilnOS

    KilnOS.demo()

end
```

