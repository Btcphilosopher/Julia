# Withnail.OS

## Pure Julia Micro-Distillery Control & Digital-Twin Platform

```julia
module DistilleryOS

using Dates
using Printf
using Statistics


# ============================================================
# DISTILLERY.OS
# ============================================================
#
# DIGITAL PROCESS-CONTROL PLATFORM FOR A MICRO-DISTILLERY
#
# PROCESS MODEL
#
# RAW MATERIAL
#      │
#      ▼
#   MASHING
#      │
#      ▼
# FERMENTATION
#      │
#      ▼
# CHARGE PREPARATION
#      │
#      ▼
# DISTILLATION
#      │
#      ├── HEADS
#      ├── HEARTS
#      └── TAILS
#      │
#      ▼
# SPIRIT MANAGEMENT
#      │
#      ▼
# CONDITIONING
#      │
#      ▼
# BOTTLING
#
# Pure Julia / standard library only.
#
# IMPORTANT:
# This is a simulation and control-system architecture.
# Real distillation equipment must use independently certified
# safety systems and hardware interlocks.
#
# ============================================================


# ============================================================
# PROCESS STATES
# ============================================================

@enum DistilleryState begin

    IDLE

    WATER_PREP

    MASHING

    COOLING

    FERMENTATION

    CHARGE_PREPARATION

    PRE_DISTILLATION_CHECK

    DISTILLATION

    HEADS_COLLECTION

    HEARTS_COLLECTION

    TAILS_COLLECTION

    RUN_COMPLETE

    CONDITIONING

    BOTTLING

    CLEANING

    FAULT

    EMERGENCY_STOP

end


# ============================================================
# RECIPE / BATCH CONFIGURATION
# ============================================================

struct SpiritRecipe

    name::String

    batch_volume_l::Float64

    target_fermentation_temperature_c::Float64

    target_fermentation_hours::Float64

    target_spirit_abv::Float64

    target_final_volume_l::Float64

end


function SpiritRecipe(;

    name="HOUSE SPIRIT",

    batch_volume_l=25.0,

    target_fermentation_temperature_c=20.0,

    target_fermentation_hours=96.0,

    target_spirit_abv=40.0,

    target_final_volume_l=10.0

)

    SpiritRecipe(

        name,

        batch_volume_l,

        target_fermentation_temperature_c,

        target_fermentation_hours,

        target_spirit_abv,

        target_final_volume_l

    )

end


# ============================================================
# SENSOR SYSTEM
# ============================================================

mutable struct Sensors

    liquid_temperature_c::Float64

    vapour_temperature_c::Float64

    ambient_temperature_c::Float64

    vessel_level_l::Float64

    vapour_pressure_bar::Float64

    ethanol_vapour_index::Float64

    condenser_temperature_c::Float64

    condenser_flow_l_min::Float64

    collected_volume_l::Float64

    collected_abv_percent::Float64

end


function Sensors()

    Sensors(

        20.0,
        20.0,
        20.0,

        25.0,

        1.0,

        0.0,

        20.0,

        0.0,

        0.0,

        0.0

    )

end


# ============================================================
# SAFETY SYSTEM
# ============================================================

mutable struct SafetySystem

    emergency_stop::Bool

    vapour_alarm::Bool

    overtemperature::Bool

    overpressure::Bool

    condenser_failure::Bool

    low_level::Bool

    enclosure_open::Bool

    ventilation_ok::Bool

    interlock_ok::Bool

end


function SafetySystem()

    SafetySystem(

        false,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        true

    )

end


function evaluate_safety!(

    safety::SafetySystem,

    sensors::Sensors

)

    safety.overtemperature =

        sensors.liquid_temperature_c > 110.0


    safety.overpressure =

        sensors.vapour_pressure_bar > 1.8


    safety.vapour_alarm =

        sensors.ethanol_vapour_index > 0.8


    safety.condenser_failure =

        (

            sensors.ethanol_vapour_index > 0.3 &&

            sensors.condenser_flow_l_min < 0.5

        )


    safety.low_level =

        sensors.vessel_level_l < 2.0


    safety.interlock_ok =

        !safety.emergency_stop &&

        !safety.vapour_alarm &&

        !safety.overtemperature &&

        !safety.overpressure &&

        !safety.condenser_failure &&

        !safety.low_level &&

        !safety.enclosure_open &&

        safety.ventilation_ok


    return safety.interlock_ok

end


# ============================================================
# THERMAL CONTROL
# ============================================================

mutable struct ThermalController

    target_temperature_c::Float64

    heater_percent::Float64

    cooler_percent::Float64

    kp::Float64

    ki::Float64

    kd::Float64

    integral::Float64

    previous_error::Float64

end


function ThermalController()

    ThermalController(

        20.0,

        0.0,

        0.0,

        8.0,

        0.01,

        1.5,

        0.0,

        0.0

    )

end


function set_target!(

    controller::ThermalController,

    temperature_c::Float64

)

    controller.target_temperature_c =

        temperature_c

end


function update_pid!(

    controller::ThermalController,

    measured::Float64,

    dt::Float64

)

    error =

        controller.target_temperature_c -
        measured


    controller.integral +=

        error * dt


    derivative =

        (

            error -
            controller.previous_error

        ) /

        max(dt, 0.001)


    output =

        controller.kp * error +

        controller.ki *
        controller.integral +

        controller.kd *
        derivative


    controller.previous_error = error


    if output >= 0

        controller.heater_percent =

            clamp(

                output,

                0.0,
                100.0

            )

        controller.cooler_percent = 0.0

    else

        controller.heater_percent = 0.0

        controller.cooler_percent =

            clamp(

                -output,

                0.0,
                100.0

            )

    end

end


# ============================================================
# PUMP
# ============================================================

mutable struct Pump

    enabled::Bool

    speed_percent::Float64

    flow_l_min::Float64

end


Pump() = Pump(

    false,

    0.0,

    0.0

)


function set_pump!(

    pump::Pump,

    speed_percent::Float64

)

    pump.speed_percent =

        clamp(

            speed_percent,

            0.0,
            100.0

        )


    pump.enabled =

        speed_percent > 0


    pump.flow_l_min =

        pump.speed_percent * 0.08

end


# ============================================================
# VALVES
# ============================================================

mutable struct Valves

    feed::Bool

    distillation_outlet::Bool

    heads::Bool

    hearts::Bool

    tails::Bool

    condenser::Bool

    drain::Bool

end


function Valves()

    Valves(

        false,
        false,
        false,
        false,
        false,
        false,
        false

    )

end


function close_all!(

    valves::Valves

)

    valves.feed = false
    valves.distillation_outlet = false
    valves.heads = false
    valves.hearts = false
    valves.tails = false
    valves.condenser = false
    valves.drain = false

end


# ============================================================
# FERMENTATION MODEL
# ============================================================

mutable struct FermentationModel

    initial_sg::Float64

    current_sg::Float64

    final_sg::Float64

    temperature_c::Float64

    yeast_activity::Float64

    co2_generation::Float64

    elapsed_hours::Float64

end


function FermentationModel()

    FermentationModel(

        1.060,

        1.060,

        1.010,

        20.0,

        1.0,

        0.0,

        0.0

    )

end


function fermentation_step!(

    fermentation::FermentationModel,

    dt_seconds::Float64

)

    dt_hours =

        dt_seconds / 3600.0


    temperature_factor =

        clamp(

            1.0 -

            abs(

                fermentation.temperature_c -
                20.0

            ) / 15.0,

            0.0,
            1.0

        )


    fermentation.yeast_activity =

        temperature_factor


    gravity_difference =

        max(

            fermentation.current_sg -
            fermentation.final_sg,

            0.0

        )


    fermentation.current_sg -=

        0.00015 *

        gravity_difference *

        fermentation.yeast_activity *

        dt_hours


    fermentation.current_sg =

        max(

            fermentation.current_sg,

            fermentation.final_sg

        )


    fermentation.co2_generation =

        gravity_difference *

        fermentation.yeast_activity *


        100.0


    fermentation.elapsed_hours +=

        dt_hours

end


# ============================================================
# DISTILLATION MODEL
# ============================================================
#
# This model is intentionally abstract.
# It does not prescribe real-world operating settings.
#
# ============================================================

mutable struct DistillationModel

    feed_abv_percent::Float64

    vapour_abv_percent::Float64

    condenser_efficiency::Float64

    collected_volume_l::Float64

    fraction_index::Float64

    separation_quality::Float64

end


function DistillationModel()

    DistillationModel(

        8.0,

        0.0,

        0.95,

        0.0,

        0.0,

        0.0

    )

end


function update_distillation!(

    distillation::DistillationModel,

    machine_temperature_c::Float64,

    heater_percent::Float64,

    dt::Float64

)

    # Abstract vapour model.

    thermal_factor =

        clamp(

            (

                machine_temperature_c -
                70.0

            ) / 30.0,

            0.0,
            1.0

        )


    distillation.vapour_abv_percent =

        clamp(

            distillation.feed_abv_percent *

            (

                1.0 +
                thermal_factor

            ) *

            distillation.separation_quality +

            10.0,

            0.0,
            95.0

        )


    production_rate =

        0.0008 *

        heater_percent *


        distillation.condenser_efficiency


    distillation.collected_volume_l +=

        production_rate *
        dt


    distillation.fraction_index +=

        dt / 1000.0

end


# ============================================================
# FRACTION CLASSIFIER
# ============================================================

@enum Fraction begin

    UNCLASSIFIED

    HEADS

    HEARTS

    TAILS

end


function classify_fraction(

    abv::Float64,

    progress::Float64

)

    # Generic software classification.
    #
    # Production equipment should use validated analytical
    # measurements rather than relying on this demonstration.

    if progress < 0.15

        return HEADS

    elseif progress < 0.75

        return HEARTS

    else

        return TAILS

    end

end


# ============================================================
# QUALITY ENGINE
# ============================================================

mutable struct QualityMetrics

    estimated_abv::Float64

    estimated_yield_l::Float64

    batch_efficiency::Float64

    consistency_score::Float64

    temperature_stability::Float64

    process_score::Float64

end


QualityMetrics() =

    QualityMetrics(

        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0

    )


function calculate_abv(

    initial_sg::Float64,

    final_sg::Float64

)

    return (

        initial_sg -
        final_sg

    ) * 131.25

end


# ============================================================
# TELEMETRY
# ============================================================

struct TelemetryPoint

    timestamp::DateTime

    state::DistilleryState

    liquid_temperature_c::Float64

    vapour_temperature_c::Float64

    pressure_bar::Float64

    vapour_index::Float64

    collected_volume_l::Float64

    collected_abv_percent::Float64

    heater_percent::Float64

    condenser_flow_l_min::Float64

end


mutable struct Telemetry

    points::Vector{TelemetryPoint}

end


Telemetry() =

    Telemetry(

        TelemetryPoint[]

    )


function record_telemetry!(

    machine

)

    push!(

        machine.telemetry.points,

        TelemetryPoint(

            now(),

            machine.state,

            machine.sensors.liquid_temperature_c,

            machine.sensors.vapour_temperature_c,

            machine.sensors.vapour_pressure_bar,

            machine.sensors.ethanol_vapour_index,

            machine.sensors.collected_volume_l,

            machine.sensors.collected_abv_percent,

            machine.thermal.heater_percent,

            machine.sensors.condenser_flow_l_min

        )

    )

end


# ============================================================
# BATCH
# ============================================================

struct Batch

    id::String

    recipe_name::String

    created::DateTime

end


function new_batch(

    recipe::SpiritRecipe

)

    Batch(

        "DIST-" *

        Dates.format(

            now(),

            "yyyymmdd-HHMMSS"

        ),

        recipe.name,

        now()

    )

end


# ============================================================
# DISTILLERY MACHINE
# ============================================================

mutable struct Distillery

    name::String

    state::DistilleryState

    recipe::SpiritRecipe

    batch::Union{Nothing,Batch}

    sensors::Sensors

    safety::SafetySystem

    thermal::ThermalController

    pump::Pump

    valves::Valves

    fermentation::FermentationModel

    distillation::DistillationModel

    quality::QualityMetrics

    telemetry::Telemetry

    elapsed_s::Float64

    state_elapsed_s::Float64

    fraction::Fraction

end


function Distillery(

    name="DISTILLERY-001",

    recipe=SpiritRecipe()

)

    Distillery(

        name,

        IDLE,

        recipe,

        nothing,

        Sensors(),

        SafetySystem(),

        ThermalController(),

        Pump(),

        Valves(),

        FermentationModel(),

        DistillationModel(),

        QualityMetrics(),

        Telemetry(),

        0.0,

        0.0,

        UNCLASSIFIED

    )

end


# ============================================================
# START BATCH
# ============================================================

function start_batch!(

    machine::Distillery

)

    machine.state == IDLE ||

        error(

            "Distillery is not idle."

        )


    machine.batch =

        new_batch(

            machine.recipe

        )


    machine.state =

        WATER_PREP


    machine.elapsed_s = 0.0

    machine.state_elapsed_s = 0.0

end


# ============================================================
# WATER PREPARATION
# ============================================================

function water_prep_step!(

    machine,

    dt

)

    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >= 120.0

        machine.state =
            MASHING

        machine.state_elapsed_s = 0.0

    end

end


# ============================================================
# MASHING
# ============================================================

function mashing_step!(

    machine,

    dt

)

    set_target!(

        machine.thermal,

        67.0

    )


    update_pid!(

        machine.thermal,

        machine.sensors.liquid_temperature_c,

        dt

    )


    machine.sensors.liquid_temperature_c +=

        machine.thermal.heater_percent *
        0.0015 *
        dt


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >= 1800.0

        machine.state =
            COOLING

        machine.state_elapsed_s = 0.0

    end

end


# ============================================================
# COOLING
# ============================================================

function cooling_step!(

    machine,

    dt

)

    set_target!(

        machine.thermal,

        machine.recipe.
        target_fermentation_temperature_c

    )


    update_pid!(

        machine.thermal,

        machine.sensors.liquid_temperature_c,

        dt

    )


    machine.sensors.liquid_temperature_c -=

        machine.thermal.cooler_percent *
        0.002 *
        dt


    machine.state_elapsed_s += dt


    if machine.sensors.liquid_temperature_c <=

       machine.recipe.
       target_fermentation_temperature_c + 0.5

        machine.state =
            FERMENTATION

        machine.state_elapsed_s = 0.0

    end

end


# ============================================================
# FERMENTATION
# ============================================================

function fermentation_step!(

    machine,

    dt

)

    machine.fermentation.temperature_c =

        machine.recipe.
        target_fermentation_temperature_c


    fermentation_step!(

        machine.fermentation,

        dt

    )


    machine.sensors.liquid_temperature_c =

        machine.fermentation.temperature_c


    machine.state_elapsed_s += dt


    complete =

        machine.fermentation.elapsed_hours >=

        machine.recipe.
        target_fermentation_hours


    gravity_complete =

        machine.fermentation.current_sg <=

        machine.fermentation.final_sg + 0.001


    if complete && gravity_complete

        machine.state =
            CHARGE_PREPARATION

        machine.state_elapsed_s = 0.0

    end

end


# ============================================================
# CHARGE PREPARATION
# ============================================================

function charge_preparation_step!(

    machine,

    dt

)

    machine.state_elapsed_s += dt


    machine.distillation.feed_abv_percent =

        calculate_abv(

            machine.fermentation.initial_sg,

            machine.fermentation.current_sg

        )


    if machine.state_elapsed_s >= 60.0

        machine.state =
            PRE_DISTILLATION_CHECK

        machine.state_elapsed_s = 0.0

    end

end


# ============================================================
# PRE-DISTILLATION SAFETY CHECK
# ============================================================

function pre_distillation_check!(

    machine

)

    evaluate_safety!(

        machine.safety,

        machine.sensors

    )


    if !machine.safety.interlock_ok

        machine.state =
            FAULT

        return

    end


    machine.sensors.condenser_flow_l_min = 1.0

    machine.valves.condenser = true

    machine.state =
        DISTILLATION

    machine.state_elapsed_s = 0.0

end


# ============================================================
# DISTILLATION
# ============================================================

function distillation_step!(

    machine,

    dt

)

    evaluate_safety!(

        machine.safety,

        machine.sensors

    )


    if !machine.safety.interlock_ok

        emergency_stop!(

            machine

        )

        return

    end


    # Closed-loop heating control.

    set_target!(

        machine.thermal,

        78.0

    )


    update_pid!(

        machine.thermal,

        machine.sensors.vapour_temperature_c,

        dt

    )


    # Abstract simulation dynamics.

    machine.sensors.vapour_temperature_c +=

        (

            machine.thermal.heater_percent *
            0.001

        ) *

        dt


    machine.sensors.vapour_temperature_c -=

        (

            machine.sensors.vapour_temperature_c -
            machine.sensors.ambient_temperature_c

        ) *

        0.00005 *
        dt


    machine.sensors.ethanol_vapour_index =

        clamp(

            (

                machine.sensors.vapour_temperature_c -
                60.0

            ) / 40.0,

            0.0,
            1.0

        )


    machine.sensors.vapour_pressure_bar =

        1.0 +

        0.003 *

        machine.thermal.heater_percent


    machine.sensors.condenser_flow_l_min =

        machine.valves.condenser ?

        1.0 :

        0.0


    update_distillation!(

        machine.distillation,

        machine.sensors.vapour_temperature_c,

        machine.thermal.heater_percent,

        dt

    )


    machine.sensors.collected_volume_l =

        machine.distillation.collected_volume_l


    machine.sensors.collected_abv_percent =

        machine.distillation.vapour_abv_percent


    machine.state_elapsed_s += dt


    # Generic fraction classification.

    progress =

        clamp(

            machine.state_elapsed_s /
            3600.0,

            0.0,
            1.0

        )


    machine.fraction =

        classify_fraction(

            machine.sensors.collected_abv_percent,

            progress

        )


    if machine.fraction == HEADS

        machine.state =
            HEADS_COLLECTION

    elseif machine.fraction == HEARTS

        machine.state =
            HEARTS_COLLECTION

    elseif machine.fraction == TAILS

        machine.state =
            TAILS_COLLECTION

    end


    if machine.state_elapsed_s >= 5400.0

        machine.state =
            RUN_COMPLETE

        machine.state_elapsed_s = 0.0

    end

end


# ============================================================
# FRACTION COLLECTION STATES
# ============================================================

function fraction_step!(

    machine,

    dt

)

    evaluate_safety!(

        machine.safety,

        machine.sensors

    )


    if !machine.safety.interlock_ok

        emergency_stop!(

            machine

        )

        return

    end


    machine.state_elapsed_s += dt


    if machine.state == HEADS_COLLECTION

        machine.valves.heads = true

        machine.valves.hearts = false

        machine.valves.tails = false


    elseif machine.state == HEARTS_COLLECTION

        machine.valves.heads = false

        machine.valves.hearts = true

        machine.valves.tails = false


    elseif machine.state == TAILS_COLLECTION

        machine.valves.heads = false

        machine.valves.hearts = false

        machine.valves.tails = true

    end


    # Return to process controller.

    if machine.state_elapsed_s >= 10.0

        machine.state =
            DISTILLATION

        machine.state_elapsed_s = 0.0

    end

end


# ============================================================
# RUN COMPLETE
# ============================================================

function run_complete_step!(

    machine,

    dt

)

    machine.thermal.heater_percent = 0.0

    machine.valves.heads = false
    machine.valves.hearts = false
    machine.valves.tails = false


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >= 30.0

        machine.state =
            CONDITIONING

        machine.state_elapsed_s = 0.0

    end

end


# ============================================================
# CONDITIONING
# ============================================================

function conditioning_step!(

    machine,

    dt

)

    machine.thermal.heater_percent = 0.0

    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >= 600.0

        machine.state =
            BOTTLING

        machine.state_elapsed_s = 0.0

    end

end


# ============================================================
# BOTTLING
# ============================================================

function bottling_step!(

    machine,

    dt

)

    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >= 120.0

        machine.state =
            CLEANING

        machine.state_elapsed_s = 0.0

    end

end


# ============================================================
# CLEANING
# ============================================================

function cleaning_step!(

    machine,

    dt

)

    machine.thermal.heater_percent = 0.0

    machine.valves.drain = true


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >= 300.0

        close_all!(

            machine.valves

        )

        machine.state =
            IDLE

        machine.state_elapsed_s = 0.0

    end

end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(

    machine::Distillery

)

    machine.thermal.heater_percent = 0.0

    machine.thermal.cooler_percent = 0.0

    set_pump!(

        machine.pump,

        0.0

    )

    close_all!(

        machine.valves

    )


    machine.safety.emergency_stop =
        true


    machine.state =
        EMERGENCY_STOP

end


# ============================================================
# MASTER CONTROL LOOP
# ============================================================

function control_step!(

    machine::Distillery,

    dt::Float64=1.0

)

    if machine.state == WATER_PREP

        water_prep_step!(
            machine,
            dt
        )


    elseif machine.state == MASHING

        mashing_step!(
            machine,
            dt
        )


    elseif machine.state == COOLING

        cooling_step!(
            machine,
            dt
        )


    elseif machine.state == FERMENTATION

        fermentation_step!(
            machine,
            dt
        )


    elseif machine.state == CHARGE_PREPARATION

        charge_preparation_step!(
            machine,
            dt
        )


    elseif machine.state == PRE_DISTILLATION_CHECK

        pre_distillation_check!(
            machine
        )


    elseif machine.state == DISTILLATION

        distillation_step!(
            machine,
            dt
        )


    elseif machine.state in (

        HEADS_COLLECTION,

        HEARTS_COLLECTION,

        TAILS_COLLECTION

    )

        fraction_step!(
            machine,
            dt
        )


    elseif machine.state == RUN_COMPLETE

        run_complete_step!(
            machine,
            dt
        )


    elseif machine.state == CONDITIONING

        conditioning_step!(
            machine,
            dt
        )


    elseif machine.state == BOTTLING

        bottling_step!(
            machine,
            dt
        )


    elseif machine.state == CLEANING

        cleaning_step!(
            machine,
            dt
        )

    end


    machine.elapsed_s += dt


    record_telemetry!(
        machine
    )

end


# ============================================================
# STATUS DISPLAY
# ============================================================

function status!(

    machine::Distillery

)

    println(

        @sprintf(

            "%-22s | TEMP %6.1f°C | VAP %6.1f°C | PRESS %5.2f bar | VOL %6.2f L | ABV %5.1f%% | HEAT %5.1f%%",

            string(machine.state),

            machine.sensors.liquid_temperature_c,

            machine.sensors.vapour_temperature_c,

            machine.sensors.vapour_pressure_bar,

            machine.sensors.collected_volume_l,

            machine.sensors.collected_abv_percent,

            machine.thermal.heater_percent

        )

    )

end


# ============================================================
# BATCH REPORT
# ============================================================

function batch_report(

    machine::Distillery

)

    return (

        batch_id =

            machine.batch === nothing ?

            "NONE" :

            machine.batch.id,

        spirit =

            machine.recipe.name,

        fermentation_sg =

            machine.fermentation.initial_sg,

        final_sg =

            machine.fermentation.current_sg,

        fermentation_abv =

            calculate_abv(

                machine.fermentation.initial_sg,

                machine.fermentation.current_sg

            ),

        collected_volume_l =

            machine.sensors.collected_volume_l,

        collected_abv_percent =

            machine.sensors.collected_abv_percent,

        estimated_pure_alcohol_l =

            machine.sensors.collected_volume_l *

            machine.sensors.collected_abv_percent /
            100.0,

        telemetry_points =

            length(

                machine.telemetry.points

            ),

        runtime_hours =

            machine.elapsed_s / 3600.0

    )

end


# ============================================================
# DIGITAL DASHBOARD
# ============================================================

function dashboard(

    machine::Distillery

)

    println()

    println("="^100)

    println(

        "                       DISTILLERY.OS"

    )

    println(

        "                MICRO-DISTILLERY CONTROL"

    )

    println("="^100)

    println()

    println(

        "MACHINE       : ",
        machine.name

    )

    println(

        "STATE         : ",
        machine.state

    )

    println(

        "BATCH         : ",

        machine.batch === nothing ?

        "NONE" :

        machine.batch.id

    )

    println()

    println(

        "LIQUID TEMP   : ",

        round(

            machine.sensors.liquid_temperature_c,

            digits=2

        ),

        " °C"

    )

    println(

        "VAPOUR TEMP   : ",

        round(

            machine.sensors.vapour_temperature_c,

            digits=2

        ),

        " °C"

    )

    println(

        "PRESSURE      : ",

        round(

            machine.sensors.vapour_pressure_bar,

            digits=3

        ),

        " bar"

    )

    println(

        "VAPOUR INDEX  : ",

        round(

            machine.sensors.ethanol_vapour_index,

            digits=3

        )

    )

    println(

        "COLLECTED     : ",

        round(

            machine.sensors.collected_volume_l,

            digits=2

        ),

        " L"

    )

    println(

        "ABV           : ",

        round(

            machine.sensors.collected_abv_percent,

            digits=2

        ),

        " %"

    )

    println()

    println(

        "FRACTION      : ",
        machine.fraction

    )

    println(

        "HEATER        : ",

        round(

            machine.thermal.heater_percent,

            digits=1

        ),

        " %"

    )

    println(

        "CONDENSER     : ",

        machine.valves.condenser ?

        "ONLINE" :

        "OFFLINE"

    )

    println()

    println(

        "SAFETY        : ",

        machine.safety.interlock_ok ?

        "ALL INTERLOCKS GREEN" :

        "FAULT"

    )

    println("="^100)

end


# ============================================================
# SIMULATION
# ============================================================

function simulate()

    recipe =

        SpiritRecipe(

            name="HOUSE SPIRIT"

        )


    machine =

        Distillery(

            "MICRO-DISTILLERY-001",

            recipe

        )


    println()

    println(

        "INITIALISING DISTILLERY.OS..."

    )


    start_batch!(

        machine

    )


    println(

        "BATCH: ",

        machine.batch.id

    )


    println()

    println(

        "RUNNING DIGITAL-TWIN SIMULATION..."

    )


    for tick in 1:20000

        control_step!(

            machine,

            10.0

        )


        if tick % 250 == 0

            status!(

                machine

            )

        end


        if machine.state == IDLE &&

           machine.elapsed_s > 1000

            break

        end


        if machine.state == EMERGENCY_STOP

            println()

            println(

                "!!! EMERGENCY STOP !!!"

            )

            break

        end

    end


    report =

        batch_report(

            machine

        )


    dashboard(

        machine

    )


    println()

    println("="^100)

    println(

        "                      BATCH REPORT"

    )

    println("="^100)

    println(

        "Batch ID                 : ",
        report.batch_id
    )

    println(

        "Spirit                   : ",
        report.spirit
    )

    println(

        "Fermentation ABV         : ",

        round(

            report.fermentation_abv,

            digits=2

        ),

        "%"
    )

    println(

        "Collected volume         : ",

        round(

            report.collected_volume_l,

            digits=2

        ),

        " L"
    )

    println(

        "Collected strength       : ",

        round(

            report.collected_abv_percent,

            digits=2

        ),

        "%"
    )

    println(

        "Estimated pure alcohol   : ",

        round(

            report.estimated_pure_alcohol_l,

            digits=2

        ),

        " L"
    )

    println(

        "Telemetry records        : ",

        report.telemetry_points
    )

    println(

        "Total runtime            : ",

        round(

            report.runtime_hours,

            digits=2

        ),

        " hours"
    )

    println("="^100)

end


# ============================================================
# PUBLIC API
# ============================================================

export DistilleryState
export SpiritRecipe
export Distillery
export Sensors
export SafetySystem

export start_batch!
export control_step!
export emergency_stop!
export dashboard
export status!
export batch_report
export simulate

end


# ============================================================
# APPLICATION ENTRY POINT
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .DistilleryOS

    DistilleryOS.simulate()

end
```

