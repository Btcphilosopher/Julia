# BUTTEROS

## Smart Home Butter-Making Appliance

### Pure Julia

```julia
module ButterOS

using Dates
using Printf
using Statistics


# ============================================================
# BUTTEROS
#
# Smart domestic butter-making appliance.
#
# Process:
#
#   CREAM
#      ↓
#   TEMPERATURE CONTROL
#      ↓
#   CHURN
#      ↓
#   FAT COALESCENCE
#      ↓
#   BUTTER GRAINS
#      ↓
#   BUTTERMILK SEPARATION
#      ↓
#   WASH
#      ↓
#   WORK
#      ↓
#   COMPLETE
#
# This implementation contains a simulated process model.
# Real appliances require independent electrical, thermal,
# mechanical and food-safety protection.
# ============================================================


# ============================================================
# STATES
# ============================================================

@enum ButterState begin

    IDLE

    PREPARE

    COOLING

    CHURNING

    SEPARATING

    WASHING

    WORKING

    COMPLETE

    FAULT

    EMERGENCY_STOP

end


# ============================================================
# CREAM
# ============================================================

mutable struct Cream

    mass_g::Float64

    fat_fraction::Float64

    temperature_c::Float64

end


function Cream(

    mass_g::Real,

    fat_fraction::Real;

    temperature_c=8.0

)

    Cream(

        Float64(mass_g),

        Float64(fat_fraction),

        Float64(temperature_c)

    )

end


# ============================================================
# BUTTER
# ============================================================

mutable struct Butter

    mass_g::Float64

    water_fraction::Float64

    fat_fraction::Float64

    salt_g::Float64

end


function Butter()

    Butter(

        0.0,

        0.0,

        0.0,

        0.0

    )

end


# ============================================================
# MOTOR
# ============================================================

mutable struct Motor

    enabled::Bool

    rpm::Float64

    target_rpm::Float64

    maximum_rpm::Float64

    current_a::Float64

end


function Motor(;

    maximum_rpm=300.0

)

    Motor(

        false,

        0.0,

        0.0,

        Float64(maximum_rpm),

        0.0

    )

end


function stop!(
    motor::Motor
)

    motor.enabled =
        false

    motor.rpm =
        0.0

    motor.target_rpm =
        0.0

    motor.current_a =
        0.0

end


function set_speed!(

    motor::Motor,

    rpm::Real

)

    motor.target_rpm =
        clamp(

            Float64(rpm),

            0.0,

            motor.maximum_rpm

        )

    motor.enabled =
        motor.target_rpm > 0.0

end


# ============================================================
# TEMPERATURE SENSOR
# ============================================================

mutable struct TemperatureSensor

    temperature_c::Float64

    minimum_c::Float64

    maximum_c::Float64

    healthy::Bool

end


function TemperatureSensor(;

    initial=8.0,

    minimum=0.0,

    maximum=100.0

)

    TemperatureSensor(

        Float64(initial),

        Float64(minimum),

        Float64(maximum),

        true

    )

end


# ============================================================
# COOLING SYSTEM
# ============================================================

mutable struct CoolingSystem

    enabled::Bool

    target_temperature::Float64

    power::Float64

end


function CoolingSystem()

    CoolingSystem(

        false,

        8.0,

        0.0

    )

end


# ============================================================
# WATER SYSTEM
# ============================================================

mutable struct WaterSystem

    enabled::Bool

    flow_rate_ml_s::Float64

    water_temperature_c::Float64

end


function WaterSystem()

    WaterSystem(

        false,

        0.0,

        8.0

    )

end


# ============================================================
# PROGRAMME
# ============================================================

struct ButterProgramme

    target_temperature::Float64

    churn_rpm::Float64

    wash_temperature::Float64

    wash_seconds::Float64

    work_rpm::Float64

    work_seconds::Float64

end


function ButterProgramme(;

    target_temperature=8.0,

    churn_rpm=180.0,

    wash_temperature=8.0,

    wash_seconds=30.0,

    work_rpm=60.0,

    work_seconds=45.0

)

    ButterProgramme(

        Float64(target_temperature),

        Float64(churn_rpm),

        Float64(wash_temperature),

        Float64(wash_seconds),

        Float64(work_rpm),

        Float64(work_seconds)

    )

end


# ============================================================
# APPLIANCE
# ============================================================

mutable struct ButterMachine

    name::String

    state::ButterState

    cream::Union{Nothing,Cream}

    butter::Butter

    motor::Motor

    temperature::TemperatureSensor

    cooling::CoolingSystem

    water::WaterSystem

    programme::ButterProgramme

    elapsed::Float64

    state_elapsed::Float64

    separation_index::Float64

    butter_grain_index::Float64

    buttermilk_volume_ml::Float64

    emergency::Bool

end


# ============================================================
# CONSTRUCTOR
# ============================================================

function ButterMachine(

    name::String;

    programme=ButterProgramme()

)

    ButterMachine(

        name,

        IDLE,

        nothing,

        Butter(),

        Motor(),

        TemperatureSensor(),

        CoolingSystem(),

        WaterSystem(),

        programme,

        0.0,

        0.0,

        0.0,

        0.0,

        0.0,

        false

    )

end


# ============================================================
# LOAD CREAM
# ============================================================

function load_cream!(

    machine::ButterMachine,

    cream::Cream

)

    machine.state == IDLE ||
        error(
            "Machine must be idle."
        )

    cream.mass_g > 0 ||
        error(
            "Cream mass must be positive."
        )

    cream.fat_fraction > 0 ||
        error(
            "Cream must contain milkfat."
        )

    machine.cream =
        cream

    machine.temperature.temperature_c =
        cream.temperature_c

end


# ============================================================
# START
# ============================================================

function start!(
    machine::ButterMachine
)

    machine.cream === nothing &&
        error(
            "No cream loaded."
        )

    machine.state =
        PREPARE

    machine.elapsed =
        0.0

    machine.state_elapsed =
        0.0

    machine.separation_index =
        0.0

    machine.butter_grain_index =
        0.0

    machine.buttermilk_volume_ml =
        0.0

    machine.butter =
        Butter()

    machine.emergency =
        false

end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(
    machine::ButterMachine
)

    stop!(
        machine.motor
    )

    machine.cooling.enabled =
        false

    machine.water.enabled =
        false

    machine.emergency =
        true

    machine.state =
        EMERGENCY_STOP

end


# ============================================================
# TEMPERATURE CONTROL
# ============================================================

function update_temperature!(

    machine::ButterMachine,

    dt::Float64

)

    machine.cream === nothing &&
        return


    current =
        machine.temperature.temperature_c


    target =
        machine.programme.target_temperature


    # --------------------------------------------------------
    # Cooling
    # --------------------------------------------------------

    if machine.cooling.enabled

        difference =
            current - target

        cooling_rate =
            0.08 *
            machine.cooling.power

        current -=
            cooling_rate *
            max(
                difference,
                0.0
            ) *
            dt

    end


    # --------------------------------------------------------
    # Churning generates some heat.
    # --------------------------------------------------------

    if machine.motor.enabled

        motor_heat =
            0.002 *
            machine.motor.rpm

        current +=
            motor_heat *
            dt

    end


    # Ambient heat exchange.

    ambient =
        20.0

    current +=
        (
            ambient -
            current
        ) *
        0.002 *
        dt


    current =
        clamp(
            current,
            0.0,
            100.0
        )


    machine.temperature.temperature_c =
        current

    machine.cream.temperature_c =
        current

end


# ============================================================
# MOTOR MODEL
# ============================================================

function update_motor!(

    machine::ButterMachine,

    dt::Float64

)

    motor =
        machine.motor


    if !motor.enabled

        motor.rpm *=
            max(
                0.0,
                1.0 -
                5.0 * dt
            )

        motor.current_a =
            0.0

        return

    end


    # Smooth acceleration.

    difference =
        motor.target_rpm -
        motor.rpm


    motor.rpm +=
        clamp(
            difference *
            0.15,
            -50.0,
            50.0
        )


    # --------------------------------------------------------
    # Simulated mechanical load.
    # --------------------------------------------------------

    separation_load =
        machine.separation_index *
        0.015

    motor.current_a =
        0.5 +
        motor.rpm *
        0.005 +
        separation_load

end


# ============================================================
# CHURN PHYSICS
# ============================================================

function update_churning!(

    machine::ButterMachine,

    dt::Float64

)

    cream =
        machine.cream

    cream === nothing &&
        return


    temperature =
        cream.temperature_c


    target =
        machine.programme.target_temperature


    # Temperature suitability.

    temperature_factor =
        exp(
            -(
                (temperature - target)^2
            ) /
            8.0
        )


    # Mechanical agitation.

    rpm =
        machine.motor.rpm


    rpm_factor =
        clamp(
            rpm /
            machine.programme.churn_rpm,
            0.0,
            1.2
        )


    # Coalescence.

    coalescence =
        0.0025 *
        temperature_factor *
        rpm_factor


    machine.separation_index +=
        coalescence *
        dt


    machine.separation_index =
        clamp(
            machine.separation_index,
            0.0,
            1.0
        )


    # --------------------------------------------------------
    # Grain formation
    # --------------------------------------------------------

    if machine.separation_index > 0.25

        machine.butter_grain_index +=
            0.004 *
            temperature_factor *
            rpm_factor *
            dt

    end


    machine.butter_grain_index =
        clamp(
            machine.butter_grain_index,
            0.0,
            1.0
        )


    # --------------------------------------------------------
    # Detect separation
    # --------------------------------------------------------

    if machine.separation_index >=
       0.85

        machine.state =
            SEPARATING

        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# SEPARATION
# ============================================================

function separate_butter!(

    machine::ButterMachine

)

    cream =
        machine.cream

    cream === nothing &&
        return


    total_fat =
        cream.mass_g *
        cream.fat_fraction


    # Simplified process yield.

    butter_mass =
        total_fat *
        0.96


    buttermilk_mass =
        max(
            0.0,
            cream.mass_g -
            butter_mass
        )


    machine.butter.mass_g =
        butter_mass


    machine.butter.fat_fraction =
        0.80


    machine.butter.water_fraction =
        0.16


    machine.buttermilk_volume_ml =
        buttermilk_mass


    machine.state =
        WASHING

    machine.state_elapsed =
        0.0


    stop!(
        machine.motor
    )

end


# ============================================================
# WASHING
# ============================================================

function update_washing!(

    machine::ButterMachine,

    dt::Float64

)

    machine.water.enabled =
        true

    machine.water.flow_rate_ml_s =
        50.0


    machine.state_elapsed +=
        dt


    if machine.state_elapsed >=
       machine.programme.wash_seconds

        machine.water.enabled =
            false

        machine.water.flow_rate_ml_s =
            0.0

        machine.state =
            WORKING

        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# WORKING
# ============================================================

function update_working!(

    machine::ButterMachine,

    dt::Float64

)

    set_speed!(

        machine.motor,

        machine.programme.work_rpm

    )


    machine.state_elapsed +=
        dt


    # Working redistributes the butter phase.

    if machine.butter.mass_g > 0

        machine.butter.water_fraction =
            max(
                0.15,
                machine.butter.water_fraction -
                0.0005 *
                dt
            )

        machine.butter.fat_fraction =
            1.0 -
            machine.butter.water_fraction

    end


    if machine.state_elapsed >=
       machine.programme.work_seconds

        stop!(
            machine.motor
        )

        machine.state =
            COMPLETE

        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# SAFETY
# ============================================================

function safety_check!(
    machine::ButterMachine
)

    sensor =
        machine.temperature


    if !sensor.healthy

        emergency_stop!(
            machine
        )

        return false

    end


    if sensor.temperature_c <
       sensor.minimum_c

        emergency_stop!(
            machine
        )

        return false

    end


    if sensor.temperature_c >
       sensor.maximum_c

        emergency_stop!(
            machine
        )

        return false

    end


    # Motor overcurrent protection.

    if machine.motor.current_a >
       8.0

        emergency_stop!(
            machine
        )

        return false

    end


    true

end


# ============================================================
# STATE MACHINE
# ============================================================

function update_state!(

    machine::ButterMachine,

    dt::Float64

)

    machine.state_elapsed +=
        dt


    if machine.state ==
       PREPARE

        machine.cooling.enabled =
            true

        machine.cooling.power =
            1.0


        if machine.temperature.temperature_c <=
           machine.programme.target_temperature + 0.5

            machine.cooling.enabled =
                false

            set_speed!(

                machine.motor,

                machine.programme.churn_rpm

            )

            machine.state =
                CHURNING

            machine.state_elapsed =
                0.0

        end


    elseif machine.state ==
           CHURNING

        update_churning!(
            machine,
            dt
        )


    elseif machine.state ==
           SEPARATING

        separate_butter!(
            machine
        )


    elseif machine.state ==
           WASHING

        update_washing!(
            machine,
            dt
        )


    elseif machine.state ==
           WORKING

        update_working!(
            machine,
            dt
        )

    end

end


# ============================================================
# MAIN CONTROL LOOP
# ============================================================

function control_step!(

    machine::ButterMachine,

    dt::Float64

)

    machine.state in
        (
            IDLE,
            COMPLETE,
            FAULT,
            EMERGENCY_STOP
        ) &&
        return


    update_temperature!(
        machine,
        dt
    )


    update_motor!(
        machine,
        dt
    )


    update_state!(
        machine,
        dt
    )


    safety_check!(
        machine
    )


    machine.elapsed +=
        dt

end


# ============================================================
# QUALITY METRICS
# ============================================================

function butter_yield(
    machine::ButterMachine
)

    machine.cream === nothing &&
        return 0.0


    machine.butter.mass_g /
    machine.cream.mass_g

end


function butterfat_percentage(
    machine::ButterMachine
)

    machine.butter.fat_fraction *
    100.0

end


function butter_quality_score(
    machine::ButterMachine
)

    yield_score =
        clamp(
            butter_yield(machine) /
            0.45,
            0.0,
            1.0
        )


    fat_score =
        clamp(

            1.0 -
            abs(
                machine.butter.fat_fraction -
                0.82
            ) /
            0.20,

            0.0,

            1.0

        )


    temperature_score =
        exp(

            -(
                machine.temperature.temperature_c -
                machine.programme.target_temperature
            )^2 /
            10.0

        )


    (
        0.40 * yield_score +
        0.40 * fat_score +
        0.20 * temperature_score
    ) * 100.0

end


# ============================================================
# STATUS
# ============================================================

function status(
    machine::ButterMachine
)

    (

        machine =
            machine.name,

        state =
            machine.state,

        temperature =
            machine.temperature.temperature_c,

        rpm =
            machine.motor.rpm,

        motor_current =
            machine.motor.current_a,

        separation =
            machine.separation_index,

        grain =
            machine.butter_grain_index,

        butter_mass =
            machine.butter.mass_g,

        buttermilk =
            machine.buttermilk_volume_ml,

        yield =
            butter_yield(machine),

        quality =
            butter_quality_score(machine)

    )

end


# ============================================================
# DISPLAY
# ============================================================

function display_status!(
    machine::ButterMachine
)

    s =
        status(
            machine
        )


    println(

        @sprintf(

            "TEMP %5.1f°C | RPM %6.1f | CURRENT %4.1fA | SEP %5.1f%% | %-14s",

            s.temperature,

            s.rpm,

            s.motor_current,

            s.separation * 100.0,

            string(s.state)

        )

    )

end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println()
    println("="^90)
    println(
        "                       BUTTEROS"
    )
    println(
        "             SMART HOME BUTTER APPLIANCE"
    )
    println("="^90)


    programme =
        ButterProgramme(

            target_temperature=8.0,

            churn_rpm=180.0,

            wash_temperature=8.0,

            wash_seconds=30.0,

            work_rpm=60.0,

            work_seconds=45.0

        )


    machine =
        ButterMachine(

            "BUTTEROS-01";

            programme=programme

        )


    # --------------------------------------------------------
    # Load cream
    # --------------------------------------------------------

    cream =
        Cream(

            1000.0,

            0.40;

            temperature_c=12.0

        )


    load_cream!(
        machine,
        cream
    )


    println()
    println(
        "Cream loaded:"
    )

    println(
        "Mass: ",
        cream.mass_g,
        " g"
    )

    println(
        "Fat: ",
        cream.fat_fraction * 100,
        "%"
    )


    # --------------------------------------------------------
    # Start
    # --------------------------------------------------------

    start!(
        machine
    )


    println()
    println(
        "Starting automatic programme..."
    )


    # --------------------------------------------------------
    # Simulation
    # --------------------------------------------------------

    for second in 1:3000

        control_step!(
            machine,
            1.0
        )


        if second % 25 == 0

            display_status!(
                machine

            )

        end


        if machine.state in
            (
                COMPLETE,
                FAULT,
                EMERGENCY_STOP
            )

            break

        end

    end


    # --------------------------------------------------------
    # Results
    # --------------------------------------------------------

    s =
        status(
            machine
        )


    println()
    println("="^90)
    println(
        "                     FINAL PRODUCT"
    )
    println("="^90)


    println(
        "State: ",
        s.state
    )

    println(
        "Butter mass: ",
        round(
            s.butter_mass,
            digits=1
        ),
        " g"
    )

    println(
        "Buttermilk: ",
        round(
            s.buttermilk,
            digits=1
        ),
        " ml"
    )

    println(
        "Butter yield: ",
        round(
            s.yield * 100.0,
            digits=1
        ),
        "%"
    )

    println(
        "Estimated fat: ",
        round(
            butterfat_percentage(machine),
            digits=1
        ),
        "%"
    )

    println(
        "Quality score: ",
        round(
            s.quality,
            digits=1
        ),
        "/ 100"
    )

    println("="^90)

end


# ============================================================
# EXPORTS
# ============================================================

export ButterState
export IDLE
export PREPARE
export COOLING
export CHURNING
export SEPARATING
export WASHING
export WORKING
export COMPLETE
export FAULT
export EMERGENCY_STOP

export Cream
export Butter
export Motor
export TemperatureSensor
export CoolingSystem
export WaterSystem
export ButterProgramme
export ButterMachine

export load_cream!
export start!
export stop!
export emergency_stop!

export control_step!
export safety_check!

export butter_yield
export butterfat_percentage
export butter_quality_score

export status
export display_status!

export demo


end # module


# ============================================================
# EXECUTE
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .ButterOS

    ButterOS.demo()

end
```

