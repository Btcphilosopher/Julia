SMITHING OVEN AUTOMATION




# FORGEOS — SMITHING OVEN AUTOMATION

## Pure Julia Industrial Temperature Controller

```julia
module ForgeOS

using Dates
using Printf


# ============================================================
# TEMPERATURE
# ============================================================

struct Temperature

    celsius::Float64

end


Temperature(x::Real) =
    Temperature(Float64(x))


fahrenheit(t::Temperature) =
    t.celsius * 9 / 5 + 32


# ============================================================
# FURNACE STATES
# ============================================================

@enum FurnaceState begin

    IDLE
    HEATING
    SOAKING
    COOLING
    COMPLETE
    FAULT
    EMERGENCY_STOP

end


# ============================================================
# THERMOCOUPLE
# ============================================================

mutable struct Thermocouple

    temperature::Temperature

    noise::Float64

    minimum::Float64

    maximum::Float64

end


function Thermocouple(;

    initial=20.0,

    noise=1.0,

    minimum=0.0,

    maximum=1500.0

)

    Thermocouple(

        Temperature(initial),

        noise,

        minimum,

        maximum

    )

end


function read_temperature(
    sensor::Thermocouple
)

    sensor.temperature

end


# ============================================================
# HEATING ELEMENT
# ============================================================

mutable struct Heater

    power::Float64

    maximum_power::Float64

    enabled::Bool

end


function Heater(

    maximum_power::Real=100.0

)

    Heater(

        0.0,

        Float64(maximum_power),

        false

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

    kp::Real,

    ki::Real,

    kd::Real

)

    PIDController(

        Float64(kp),

        Float64(ki),

        Float64(kd),

        0.0,

        0.0

    )

end


function reset!(
    pid::PIDController
)

    pid.integral =
        0.0

    pid.previous_error =
        0.0

end


function calculate!(
    pid::PIDController,

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
# FORGE PROGRAM STEP
# ============================================================

struct ProgramStep

    name::String

    target::Temperature

    ramp_rate::Float64

    soak_seconds::Float64

end


# ============================================================
# PROGRAM
# ============================================================

mutable struct ForgeProgram

    steps::Vector{ProgramStep}

    current_step::Int

    soak_elapsed::Float64

end


function ForgeProgram(
    steps::Vector{ProgramStep}
)

    ForgeProgram(

        steps,

        1,

        0.0

    )

end


function current_step(
    program::ForgeProgram
)

    if program.current_step >
       length(program.steps)

        return nothing

    end

    program.steps[
        program.current_step
    ]

end


# ============================================================
# FORGE
# ============================================================

mutable struct Forge

    name::String

    sensor::Thermocouple

    heater::Heater

    pid::PIDController

    program::ForgeProgram

    state::FurnaceState

    ambient::Temperature

    maximum_safe_temperature::Float64

    elapsed::Float64

end


# ============================================================
# CONSTRUCTOR
# ============================================================

function Forge(

    name::String,

    program::ForgeProgram;

    ambient=20.0,

    maximum_safe_temperature=1300.0

)

    Forge(

        name,

        Thermocouple(
            initial=ambient
        ),

        Heater(),

        PIDController(
            0.8,
            0.02,
            0.1
        ),

        program,

        IDLE,

        Temperature(
            ambient
        ),

        maximum_safe_temperature,

        0.0

    )

end


# ============================================================
# START
# ============================================================

function start!(
    forge::Forge
)

    forge.state ==
        IDLE ||
        error(
            "Forge cannot be started."
        )

    forge.heater.enabled =
        true

    forge.state =
        HEATING

    reset!(
        forge.pid
    )

end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(
    forge::Forge
)

    forge.heater.enabled =
        false

    forge.heater.power =
        0.0

    forge.state =
        EMERGENCY_STOP

end


# ============================================================
# RESET
# ============================================================

function reset!(
    forge::Forge
)

    forge.heater.enabled =
        false

    forge.heater.power =
        0.0

    forge.state =
        IDLE

    forge.elapsed =
        0.0

    forge.program.current_step =
        1

    forge.program.soak_elapsed =
        0.0

    reset!(
        forge.pid
    )

end


# ============================================================
# THERMAL MODEL
# ============================================================
#
# This is a simplified simulation model.
#
# It is NOT a physical furnace model and must not be used
# as a safety model for a real furnace.
#
# ============================================================

function thermal_step!(
    forge::Forge,
    dt::Float64
)

    temperature =
        forge.sensor.temperature.celsius

    ambient =
        forge.ambient.celsius

    heater_effect =
        forge.heater.enabled ?
        forge.heater.power * 8.0 :
        0.0

    cooling_effect =
        0.015 *
        (temperature - ambient)

    delta =
        (
            heater_effect -
            cooling_effect
        ) * dt

    new_temperature =
        temperature + delta

    forge.sensor.temperature =
        Temperature(
            max(
                ambient,
                new_temperature
            )
        )

end


# ============================================================
# SAFETY CHECKS
# ============================================================

function safety_check!(
    forge::Forge
)

    temperature =
        forge.sensor.temperature.celsius

    if temperature >=
       forge.maximum_safe_temperature

        emergency_stop!(
            forge
        )

        return false

    end


    if temperature <
       forge.sensor.minimum

        emergency_stop!(
            forge
        )

        return false

    end


    if temperature >
       forge.sensor.maximum

        emergency_stop!(
            forge
        )

        return false

    end

    true

end


# ============================================================
# PROGRAM CONTROL
# ============================================================

function update_program!(
    forge::Forge,
    dt::Float64
)

    step =
        current_step(
            forge.program
        )

    if step === nothing

        forge.heater.enabled =
            false

        forge.heater.power =
            0.0

        forge.state =
            COMPLETE

        return

    end


    actual =
        forge.sensor.temperature.celsius

    target =
        step.target.celsius


    # --------------------------------------------------------
    # Determine programme state
    # --------------------------------------------------------

    if abs(
        actual - target
    ) <= 5.0

        forge.state =
            SOAKING

        forge.program.soak_elapsed +=
            dt

    else

        forge.state =
            HEATING

        forge.program.soak_elapsed =
            0.0

    end


    # --------------------------------------------------------
    # Advance programme
    # --------------------------------------------------------

    if forge.program.soak_elapsed >=
       step.soak_seconds

        forge.program.current_step +=
            1

        forge.program.soak_elapsed =
            0.0

        reset!(
            forge.pid
        )

    end

end


# ============================================================
# CONTROL LOOP
# ============================================================

function control_step!(
    forge::Forge,
    dt::Float64
)

    forge.state in
        (
            HEATING,
            SOAKING
        ) ||
        return


    step =
        current_step(
            forge.program
        )

    step === nothing &&
        return


    actual =
        forge.sensor.temperature.celsius

    target =
        step.target.celsius


    # --------------------------------------------------------
    # PID
    # --------------------------------------------------------

    power =
        calculate!(
            forge.pid,

            target,

            actual,

            dt

        )


    forge.heater.power =
        power


    forge.heater.enabled =
        power > 0.0


    # --------------------------------------------------------
    # Thermal simulation
    # --------------------------------------------------------

    thermal_step!(
        forge,
        dt
    )


    forge.elapsed +=
        dt


    # --------------------------------------------------------
    # Programme
    # --------------------------------------------------------

    update_program!(
        forge,
        dt
    )


    # --------------------------------------------------------
    # Safety
    # --------------------------------------------------------

    safety_check!(
        forge
    )

end


# ============================================================
# STATUS
# ============================================================

function status(
    forge::Forge
)

    step =
        current_step(
            forge.program
        )

    (

        name =
            forge.name,

        state =
            forge.state,

        temperature =
            forge.sensor.temperature.celsius,

        target =
            step === nothing ?
            nothing :
            step.target.celsius,

        heater_power =
            forge.heater.power,

        step =
            forge.program.current_step,

        soak =
            forge.program.soak_elapsed,

        elapsed =
            forge.elapsed

    )

end


# ============================================================
# DISPLAY
# ============================================================

function display_status(
    forge::Forge
)

    s =
        status(
            forge
        )

    println(
        @sprintf(
            "TEMP %7.1f °C | TARGET %7.1f °C | POWER %6.1f%% | %-14s | STEP %d",
            s.temperature,
            something(s.target, 0.0),
            s.heater_power,
            string(s.state),
            s.step
        )
    )

end


# ============================================================
# DEMO PROGRAM
# ============================================================

function demo()

    program =
        ForgeProgram(

            [

                ProgramStep(

                    "Preheat",

                    Temperature(200),

                    100.0,

                    30

                ),

                ProgramStep(

                    "Heat",

                    Temperature(800),

                    100.0,

                    60

                ),

                ProgramStep(

                    "Forge",

                    Temperature(1100),

                    100.0,

                    120

                ),

                ProgramStep(

                    "Soak",

                    Temperature(1100),

                    100.0,

                    60

                )

            ]

        )


    forge =
        Forge(
            "Forge-01",
            program;
            maximum_safe_temperature=1200
        )


    println()
    println("="^100)
    println("                    FORGEOS")
    println("              SMITHING OVEN CONTROL")
    println("="^100)
    println()


    start!(
        forge
    )


    # --------------------------------------------------------
    # Simulated industrial control loop
    # --------------------------------------------------------

    for i in 1:2000

        control_step!(
            forge,
            1.0
        )


        if i % 20 == 0

            display_status(
                forge
            )

        end


        if forge.state in
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
        "Final state: ",
        forge.state
    )

end


# ============================================================
# EXPORTS
# ============================================================

export Temperature

export IDLE
export HEATING
export SOAKING
export COOLING
export COMPLETE
export FAULT
export EMERGENCY_STOP

export Thermocouple
export Heater
export PIDController

export ProgramStep
export ForgeProgram
export Forge

export start!
export emergency_stop!
export reset!

export control_step!
export safety_check!

export status
export display_status

export demo


end # module


# ============================================================
# RUN
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .ForgeOS

    ForgeOS.demo()

end
```

