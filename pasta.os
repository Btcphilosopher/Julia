# PASTAOS

## Intelligent Home Pasta-Making Appliance

### Pure Julia — Standard Library Only

```julia
module PastaOS

using Dates
using Printf
using Statistics


# ============================================================
# PASTAOS
#
# Intelligent automated fresh-pasta appliance
#
# PROCESS
#
#   FLOUR ─────┐
#              │
#   WATER ─────┼──► DOSING
#              │
#   EGG ───────┘
#                    │
#                    ▼
#                 MIXING
#                    │
#                    ▼
#                 KNEADING
#                    │
#                    ▼
#                  REST
#                    │
#                    ▼
#                EXTRUSION
#                    │
#                    ▼
#                 CUTTING
#                    │
#                    ▼
#                COMPLETE
#
# Sensors / estimated signals:
#
#   - hopper mass
#   - water flow
#   - motor current
#   - dough consistency
#   - dough temperature
#   - extrusion pressure
#   - cutter position
#   - door/interlock state
#
# Pure Julia / simulation-oriented controller.
#
# ============================================================


# ============================================================
# MACHINE STATES
# ============================================================

@enum PastaState begin

    IDLE
    DOSING
    MIXING
    KNEADING
    HYDRATION
    RESTING
    PRE_EXTRUSION
    EXTRUSION
    CUTTING
    FINISHED
    CLEANING
    FAULT
    EMERGENCY_STOP

end


# ============================================================
# RECIPE
# ============================================================

struct PastaRecipe

    name::String

    flour_g::Float64

    water_g::Float64

    egg_g::Float64

    salt_g::Float64

    hydration_ratio::Float64

    mixing_time_s::Float64

    kneading_time_s::Float64

    resting_time_s::Float64

    extrusion_speed_mm_s::Float64

    target_dough_consistency::Float64

    target_dough_temperature_c::Float64

end


function PastaRecipe(;

    name="CLASSIC EGG PASTA",

    flour_g=400.0,

    water_g=40.0,

    egg_g=200.0,

    salt_g=4.0,

    mixing_time_s=180.0,

    kneading_time_s=300.0,

    resting_time_s=600.0,

    extrusion_speed_mm_s=12.0,

    target_dough_consistency=0.78,

    target_dough_temperature_c=24.0

)

    hydration =

        (water_g + 0.74 * egg_g) /
        flour_g


    PastaRecipe(

        name,

        flour_g,

        water_g,

        egg_g,

        salt_g,

        hydration,

        mixing_time_s,

        kneading_time_s,

        resting_time_s,

        extrusion_speed_mm_s,

        target_dough_consistency,

        target_dough_temperature_c

    )

end


# ============================================================
# DOSING SYSTEM
# ============================================================

mutable struct IngredientSystem

    flour_available_g::Float64

    water_available_g::Float64

    egg_available_g::Float64

    salt_available_g::Float64

    flour_dosed_g::Float64

    water_dosed_g::Float64

    egg_dosed_g::Float64

    salt_dosed_g::Float64

end


function IngredientSystem()

    IngredientSystem(

        5000.0,
        5000.0,
        3000.0,
        500.0,

        0.0,
        0.0,
        0.0,
        0.0

    )

end


function dose!(

    ingredients::IngredientSystem,

    recipe::PastaRecipe

)

    recipe.flour_g <= ingredients.flour_available_g ||
        error("Insufficient flour.")


    recipe.water_g <= ingredients.water_available_g ||
        error("Insufficient water.")


    recipe.egg_g <= ingredients.egg_available_g ||
        error("Insufficient egg.")


    recipe.salt_g <= ingredients.salt_available_g ||
        error("Insufficient salt.")


    ingredients.flour_available_g -= recipe.flour_g
    ingredients.water_available_g -= recipe.water_g
    ingredients.egg_available_g -= recipe.egg_g
    ingredients.salt_available_g -= recipe.salt_g


    ingredients.flour_dosed_g = recipe.flour_g
    ingredients.water_dosed_g = recipe.water_g
    ingredients.egg_dosed_g = recipe.egg_g
    ingredients.salt_dosed_g = recipe.salt_g

end


# ============================================================
# DOUGH MODEL
# ============================================================

mutable struct DoughModel

    mass_g::Float64

    hydration::Float64

    consistency::Float64

    elasticity::Float64

    gluten_development::Float64

    temperature_c::Float64

    surface_dryness::Float64

    homogeneous::Float64

end


function DoughModel()

    DoughModel(

        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        20.0,
        1.0,
        0.0

    )

end


function initialize_dough!(

    dough::DoughModel,

    recipe::PastaRecipe

)

    dough.mass_g =

        recipe.flour_g +
        recipe.water_g +
        recipe.egg_g +
        recipe.salt_g


    dough.hydration =
        recipe.hydration_ratio


    dough.consistency =
        0.20


    dough.elasticity =
        0.05


    dough.gluten_development =
        0.0


    dough.temperature_c =
        20.0


    dough.surface_dryness =
        0.0


    dough.homogeneous =
        0.0

end


# ============================================================
# MIXING MODEL
# ============================================================

function mix_dough!(

    dough::DoughModel,

    recipe::PastaRecipe,

    dt::Float64,

    motor_speed::Float64

)

    mixing_factor =

        motor_speed /
        100.0


    dough.homogeneous +=

        0.003 *
        mixing_factor *
        dt


    dough.homogeneous =

        clamp(

            dough.homogeneous,

            0.0,
            1.0

        )


    dough.consistency +=

        0.0012 *
        mixing_factor *
        dt


    dough.consistency =

        clamp(

            dough.consistency,

            0.0,
            1.0

        )


    dough.temperature_c +=

        0.0008 *
        motor_speed *
        dt /
        100.0


end


# ============================================================
# KNEADING MODEL
# ============================================================

function knead_dough!(

    dough::DoughModel,

    dt::Float64,

    motor_speed::Float64

)

    kneading_factor =

        motor_speed /
        100.0


    dough.gluten_development +=

        0.0025 *
        kneading_factor *
        dt


    dough.gluten_development =

        clamp(

            dough.gluten_development,

            0.0,
            1.0

        )


    dough.elasticity =

        clamp(

            0.10 +
            0.90 *
            dough.gluten_development,

            0.0,
            1.0

        )


    dough.consistency +=

        0.0005 *
        dough.gluten_development *
        dt


    dough.consistency =

        clamp(

            dough.consistency,

            0.0,
            1.0

        )


    dough.temperature_c +=

        0.001 *
        motor_speed /
        100.0 *
        dt

end


# ============================================================
# REST / HYDRATION
# ============================================================

function rest_dough!(

    dough::DoughModel,

    dt::Float64

)

    hydration_rate =

        0.0008 *
        (1.0 - dough.homogeneous)


    dough.homogeneous +=

        hydration_rate *
        dt


    dough.consistency +=

        0.00015 *
        dt


    dough.consistency =

        clamp(

            dough.consistency,

            0.0,
            1.0

        )


    dough.surface_dryness =

        max(

            0.0,

            dough.surface_dryness -
            0.0002 *
            dt

        )

end


# ============================================================
# EXTRUSION SYSTEM
# ============================================================

mutable struct Extruder

    motor_on::Bool

    motor_speed_percent::Float64

    screw_position_mm::Float64

    extrusion_pressure_bar::Float64

    output_length_mm::Float64

    target_length_mm::Float64

end


function Extruder()

    Extruder(

        false,
        0.0,
        0.0,
        0.0,
        0.0,
        1000.0

    )

end


function set_speed!(

    extruder::Extruder,

    speed::Float64

)

    extruder.motor_speed_percent =

        clamp(

            speed,

            0.0,
            100.0

        )


    extruder.motor_on =

        speed > 0.0

end


function update_extrusion!(

    extruder::Extruder,

    dough::DoughModel,

    dt::Float64

)

    if !extruder.motor_on

        extruder.extrusion_pressure_bar *= 0.90

        return

    end


    speed_factor =

        extruder.motor_speed_percent /
        100.0


    # Pressure rises when dough is too stiff.

    stiffness =

        1.0 -
        dough.consistency


    extruder.extrusion_pressure_bar =

        0.6 +
        2.0 *
        stiffness +
        1.5 *
        speed_factor


    extruder.output_length_mm +=

        8.0 *
        speed_factor *
        dt


    extruder.screw_position_mm +=

        5.0 *
        speed_factor *
        dt

end


# ============================================================
# CUTTER
# ============================================================

mutable struct Cutter

    enabled::Bool

    blade_position_deg::Float64

    cut_count::Int

    cut_interval_mm::Float64

    distance_since_cut_mm::Float64

end


function Cutter(;

    cut_interval_mm=250.0

)

    Cutter(

        false,
        0.0,
        0,
        cut_interval_mm,
        0.0

    )

end


function update!(

    cutter::Cutter,

    extruder::Extruder

)

    cutter.enabled || return


    cutter.distance_since_cut_mm +=

        extruder.output_length_mm


    if cutter.distance_since_cut_mm >=
       cutter.cut_interval_mm

        cutter.cut_count += 1

        cutter.blade_position_deg =

            mod(

                cutter.blade_position_deg +
                360.0,

                360.0

            )


        cutter.distance_since_cut_mm = 0.0

    end

end


# ============================================================
# MOTOR SYSTEM
# ============================================================

mutable struct MotorSystem

    speed_percent::Float64

    current_a::Float64

    torque_nm::Float64

    overloaded::Bool

    maximum_current_a::Float64

end


function MotorSystem()

    MotorSystem(

        0.0,
        0.0,
        0.0,
        false,
        5.0

    )

end


function update!(

    motor::MotorSystem,

    dough::DoughModel,

    speed_percent::Float64

)

    motor.speed_percent =
        speed_percent


    dough_resistance =

        dough.consistency *
        (1.0 + dough.gluten_development)


    motor.torque_nm =

        0.4 *
        dough_resistance


    motor.current_a =

        0.5 +
        3.0 *
        dough_resistance


    motor.overloaded =

        motor.current_a >
        motor.maximum_current_a

end


# ============================================================
# SAFETY
# ============================================================

mutable struct SafetySystem

    lid_closed::Bool

    hopper_closed::Bool

    cutter_guard_closed::Bool

    motor_overload::Bool

    emergency_stop::Bool

    maximum_pressure_bar::Float64

end


function SafetySystem()

    SafetySystem(

        true,
        true,
        true,
        false,
        false,
        5.0

    )

end


function check_safety!(

    safety::SafetySystem,

    motor::MotorSystem,

    extruder::Extruder

)

    safety.motor_overload =
        motor.overloaded


    if !safety.lid_closed ||
       !safety.hopper_closed ||
       !safety.cutter_guard_closed ||
       safety.motor_overload ||
       safety.emergency_stop ||
       extruder.extrusion_pressure_bar >
       safety.maximum_pressure_bar

        return false

    end


    true

end


# ============================================================
# TELEMETRY
# ============================================================

struct TelemetryPoint

    timestamp::DateTime

    state::PastaState

    dough_mass_g::Float64

    dough_temperature_c::Float64

    consistency::Float64

    elasticity::Float64

    gluten_development::Float64

    motor_current_a::Float64

    extrusion_pressure_bar::Float64

    output_length_mm::Float64

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

            machine.dough.mass_g,

            machine.dough.temperature_c,

            machine.dough.consistency,

            machine.dough.elasticity,

            machine.dough.gluten_development,

            machine.motor.current_a,

            machine.extruder.extrusion_pressure_bar,

            machine.extruder.output_length_mm

        )

    )

end


# ============================================================
# PASTA MACHINE
# ============================================================

mutable struct PastaMachine

    name::String

    state::PastaState

    recipe::PastaRecipe

    ingredients::IngredientSystem

    dough::DoughModel

    extruder::Extruder

    cutter::Cutter

    motor::MotorSystem

    safety::SafetySystem

    telemetry::Telemetry

    elapsed::Float64

    state_elapsed::Float64

    adaptive_extra_kneading_s::Float64

end


# ============================================================
# CONSTRUCTOR
# ============================================================

function PastaMachine(

    name::String="PASTAOS-001",

    recipe::PastaRecipe=PastaRecipe()

)

    PastaMachine(

        name,

        IDLE,

        recipe,

        IngredientSystem(),

        DoughModel(),

        Extruder(),

        Cutter(),

        MotorSystem(),

        SafetySystem(),

        Telemetry(),

        0.0,

        0.0,

        0.0

    )

end


# ============================================================
# START CYCLE
# ============================================================

function start!(

    machine::PastaMachine

)

    machine.state == IDLE ||
        error(
            "Machine must be idle."
        )


    dose!(

        machine.ingredients,

        machine.recipe

    )


    initialize_dough!(

        machine.dough,

        machine.recipe

    )


    machine.state =
        DOSING


    machine.elapsed =
        0.0


    machine.state_elapsed =
        0.0


    machine.adaptive_extra_kneading_s =
        0.0

end


# ============================================================
# DOSING
# ============================================================

function dosing_step!(

    machine::PastaMachine,

    dt::Float64

)

    machine.state_elapsed += dt


    if machine.state_elapsed >= 5.0

        machine.state =
            MIXING

        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# MIXING
# ============================================================

function mixing_step!(

    machine::PastaMachine,

    dt::Float64

)

    motor_speed =

        55.0


    mix_dough!(

        machine.dough,

        machine.recipe,

        dt,

        motor_speed

    )


    update!(

        machine.motor,

        machine.dough,

        motor_speed

    )


    machine.state_elapsed +=
        dt


    if machine.state_elapsed >=
       machine.recipe.mixing_time_s

        machine.state =
            KNEADING

        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# KNEADING
# ============================================================

function kneading_step!(

    machine::PastaMachine,

    dt::Float64

)

    motor_speed =

        70.0


    knead_dough!(

        machine.dough,

        dt,

        motor_speed

    )


    update!(

        machine.motor,

        machine.dough,

        motor_speed

    )


    # Adaptive kneading:
    #
    # If dough has not developed enough structure,
    # automatically extend the kneading stage.

    target =
        machine.recipe.target_dough_consistency


    if machine.state_elapsed >=
       machine.recipe.kneading_time_s

        if machine.dough.consistency <
           target

            machine.adaptive_extra_kneading_s +=
                dt

        else

            machine.state =
                HYDRATION

            machine.state_elapsed =
                0.0

        end

    end


    if machine.adaptive_extra_kneading_s >=
       180.0

        machine.state =
            HYDRATION

        machine.state_elapsed =
            0.0

    end


    machine.state_elapsed +=
        dt

end


# ============================================================
# HYDRATION
# ============================================================

function hydration_step!(

    machine::PastaMachine,

    dt::Float64

)

    rest_dough!(

        machine.dough,

        dt

    )


    machine.state_elapsed +=
        dt


    if machine.state_elapsed >=
       60.0

        machine.state =
            RESTING

        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# RESTING
# ============================================================

function resting_step!(

    machine::PastaMachine,

    dt::Float64

)

    rest_dough!(

        machine.dough,

        dt

    )


    machine.state_elapsed +=
        dt


    if machine.state_elapsed >=
       machine.recipe.resting_time_s

        machine.state =
            PRE_EXTRUSION

        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# PRE-EXTRUSION
# ============================================================

function pre_extrusion_step!(

    machine::PastaMachine,

    dt::Float64

)

    machine.extruder.output_length_mm =
        0.0


    machine.cutter.cut_count =
        0


    machine.cutter.distance_since_cut_mm =
        0.0


    machine.cutter.enabled =
        true


    set_speed!(

        machine.extruder,

        machine.recipe.extrusion_speed_mm_s

    )


    machine.state =
        EXTRUSION


    machine.state_elapsed =
        0.0

end


# ============================================================
# EXTRUSION
# ============================================================

function extrusion_step!(

    machine::PastaMachine,

    dt::Float64

)

    # Adaptive extrusion:
    #
    # Too stiff → slow down.
    # Too soft → increase speed.

    target =
        machine.recipe.target_dough_consistency


    error =
        machine.dough.consistency -
        target


    speed =

        machine.recipe.extrusion_speed_mm_s *

        (

            1.0 +
            0.40 *
            error

        )


    speed =

        clamp(

            speed,

            5.0,
            20.0

        )


    set_speed!(

        machine.extruder,

        speed

    )


    update_extrusion!(

        machine.extruder,

        machine.dough,

        dt

    )


    update!(

        machine.cutter,

        machine.extruder

    )


    update!(

        machine.motor,

        machine.dough,

        speed

    )


    machine.state_elapsed +=
        dt


    # Produce approximately one metre.

    if machine.extruder.output_length_mm >=
       machine.extruder.target_length_mm

        machine.state =
            CUTTING

        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# CUTTING
# ============================================================

function cutting_step!(

    machine::PastaMachine,

    dt::Float64

)

    set_speed!(

        machine.extruder,

        0.0

    )


    machine.cutter.enabled =
        false


    machine.state_elapsed +=
        dt


    if machine.state_elapsed >= 2.0

        machine.state =
            FINISHED

        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(

    machine::PastaMachine

)

    set_speed!(
        machine.extruder,
        0.0
    )


    machine.motor.speed_percent =
        0.0


    machine.safety.emergency_stop =
        true


    machine.state =
        EMERGENCY_STOP

end


# ============================================================
# MASTER CONTROL LOOP
# ============================================================

function control_step!(

    machine::PastaMachine,

    dt::Float64=1.0

)

    machine.state in
        (
            IDLE,
            FINISHED,
            FAULT,
            EMERGENCY_STOP
        ) &&
        return


    # Safety first.

    if !check_safety!(

        machine.safety,

        machine.motor,

        machine.extruder

    )

        emergency_stop!(
            machine
        )

        return

    end


    if machine.state == DOSING

        dosing_step!(
            machine,
            dt
        )


    elseif machine.state == MIXING

        mixing_step!(
            machine,
            dt
        )


    elseif machine.state == KNEADING

        kneading_step!(
            machine,
            dt
        )


    elseif machine.state == HYDRATION

        hydration_step!(
            machine,
            dt
        )


    elseif machine.state == RESTING

        resting_step!(
            machine,
            dt
        )


    elseif machine.state == PRE_EXTRUSION

        pre_extrusion_step!(
            machine,
            dt
        )


    elseif machine.state == EXTRUSION

        extrusion_step!(
            machine,
            dt
        )


    elseif machine.state == CUTTING

        cutting_step!(
            machine,
            dt
        )

    end


    record!(
        machine.telemetry,
        machine
    )


    machine.elapsed +=
        dt

end


# ============================================================
# QUALITY SCORE
# ============================================================

function quality_score(

    machine::PastaMachine

)

    consistency_score =

        1.0 -

        abs(

            machine.dough.consistency -
            machine.recipe.target_dough_consistency

        )


    elasticity_score =

        machine.dough.elasticity


    gluten_score =

        machine.dough.gluten_development


    temperature_score =

        1.0 -

        min(

            abs(

                machine.dough.temperature_c -
                machine.recipe.target_dough_temperature_c

            ) / 20.0,

            1.0

        )


    score =

        100.0 *

        (

            0.35 *
            consistency_score +

            0.30 *
            elasticity_score +

            0.25 *
            gluten_score +

            0.10 *
            temperature_score

        )


    clamp(
        score,
        0.0,
        100.0
    )

end


# ============================================================
# STATUS
# ============================================================

function display_status!(

    machine::PastaMachine

)

    println(

        @sprintf(

            "%-14s | DOUGH %6.1f%% | GLUTEN %6.1f%% | ELASTIC %6.1f%% | MOTOR %4.1f A | PRESS %4.2f bar | OUT %6.0f mm",

            string(machine.state),

            machine.dough.consistency * 100,

            machine.dough.gluten_development * 100,

            machine.dough.elasticity * 100,

            machine.motor.current_a,

            machine.extruder.extrusion_pressure_bar,

            machine.extruder.output_length_mm

        )

    )

end


# ============================================================
# FINAL REPORT
# ============================================================

function report(

    machine::PastaMachine

)

    return (

        recipe =
            machine.recipe.name,

        dough_mass_g =
            machine.dough.mass_g,

        hydration =
            machine.dough.hydration,

        consistency =
            machine.dough.consistency,

        elasticity =
            machine.dough.elasticity,

        gluten_development =
            machine.dough.gluten_development,

        dough_temperature_c =
            machine.dough.temperature_c,

        extrusion_pressure_bar =
            machine.extruder.extrusion_pressure_bar,

        pasta_length_mm =
            machine.extruder.output_length_mm,

        cuts =
            machine.cutter.cut_count,

        quality_score =
            quality_score(machine),

        total_time_min =
            machine.elapsed / 60.0,

        telemetry_points =
            length(
                machine.telemetry.points
            )

    )

end


# ============================================================
# PRESET RECIPES
# ============================================================

const RECIPES = Dict(

    "EGG" => PastaRecipe(

        name="CLASSIC EGG PASTA",

        flour_g=400.0,

        water_g=40.0,

        egg_g=200.0,

        salt_g=4.0

    ),

    "WATER" => PastaRecipe(

        name="DURUM WATER PASTA",

        flour_g=400.0,

        water_g=155.0,

        egg_g=0.0,

        salt_g=4.0

    ),

    "RICH" => PastaRecipe(

        name="RICH EGG PASTA",

        flour_g=400.0,

        water_g=20.0,

        egg_g=240.0,

        salt_g=4.0

    )

)


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println()
    println("="^120)

    println(
        "                           PASTAOS"
    )

    println(
        "              INTELLIGENT HOME PASTA APPLIANCE"
    )

    println("="^120)


    recipe =
        RECIPES["EGG"]


    machine =

        PastaMachine(

            "PASTAOS-HOME-001",

            recipe

        )


    println()
    println(
        "RECIPE: ",
        recipe.name
    )


    println(
        "FLOUR: ",
        recipe.flour_g,
        " g"
    )


    println(
        "EGG: ",
        recipe.egg_g,
        " g"
    )


    println(
        "WATER: ",
        recipe.water_g,
        " g"
    )


    println(
        "HYDRATION: ",

        round(

            recipe.hydration_ratio * 100,

            digits=1

        ),

        "%"
    )


    println()
    println(
        "STARTING PASTAOS..."
    )


    start!(
        machine
    )


    for second in 1:10000

        control_step!(
            machine,
            1.0
        )


        if second % 60 == 0

            display_status!(
                machine
            )

        end


        if machine.state ==
           FINISHED

            break

        end


        if machine.state ==
           EMERGENCY_STOP

            println(
                "EMERGENCY STOP"
            )

            break

        end

    end


    final =
        report(machine)


    println()
    println("="^120)

    println(
        "                         PASTA COMPLETE"
    )

    println("="^120)


    println(
        "Quality score: ",

        round(
            final.quality_score,
            digits=1
        ),

        " / 100"
    )


    println(
        "Dough mass: ",
        round(
            final.dough_mass_g,
            digits=1
        ),
        " g"
    )


    println(
        "Consistency: ",

        round(
            final.consistency * 100,
            digits=1
        ),
        "%"
    )


    println(
        "Elasticity: ",

        round(
            final.elasticity * 100,
            digits=1
        ),
        "%"
    )


    println(
        "Gluten development: ",

        round(
            final.gluten_development * 100,
            digits=1
        ),
        "%"
    )


    println(
        "Extrusion pressure: ",

        round(
            final.extrusion_pressure_bar,
            digits=2
        ),

        " bar"
    )


    println(
        "Pasta produced: ",

        round(
            final.pasta_length_mm / 1000,
            digits=2
        ),

        " m"
    )


    println(
        "Cuts: ",
        final.cuts
    )


    println(
        "Cycle time: ",

        round(
            final.total_time_min,
            digits=1
        ),

        " min"
    )


    println(
        "Telemetry samples: ",
        final.telemetry_points
    )


    println("="^120)

end


# ============================================================
# EXPORTS
# ============================================================

export PastaState

export IDLE
export DOSING
export MIXING
export KNEADING
export HYDRATION
export RESTING
export PRE_EXTRUSION
export EXTRUSION
export CUTTING
export FINISHED
export CLEANING
export FAULT
export EMERGENCY_STOP

export PastaRecipe
export IngredientSystem
export DoughModel
export Extruder
export Cutter
export MotorSystem
export SafetySystem
export Telemetry
export TelemetryPoint
export PastaMachine

export RECIPES

export start!
export control_step!
export emergency_stop!
export quality_score
export report
export display_status!
export demo


end # module


# ============================================================
# APPLICATION ENTRY POINT
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .PastaOS

    PastaOS.demo()

end
```

