# BREWERY.OS

## Automated Home Micro-Brewery Controller

### Pure Julia — Single-File Control & Digital-Twin Prototype

```julia
module BreweryOS

using Dates
using Printf
using Statistics


# ============================================================
# BREWERY.OS
# ============================================================
#
# AUTOMATED SMALL-BATCH BREWING PLATFORM
#
# PROCESS:
#
# WATER
#   ↓
# MASH-IN
#   ↓
# SACCHARIFICATION
#   ↓
# MASH-OUT
#   ↓
# LAUTER
#   ↓
# BOIL
#   ↓
# HOP SCHEDULE
#   ↓
# WHIRLPOOL
#   ↓
# RAPID CHILL
#   ↓
# FERMENTATION
#   ↓
# CONDITIONING
#   ↓
# PACKAGING
#
# Pure Julia.
# No external packages required.
#
# NOTE:
# This is a control-system / simulation architecture.
# Real brewing equipment requires independently validated
# electrical, pressure, thermal, sanitation and food-safety
# systems.
#
# ============================================================


# ============================================================
# STATE MACHINE
# ============================================================

@enum BrewState begin
    IDLE
    WATER_HEAT
    MASH_IN
    MASH
    MASH_OUT
    LAUTER
    BOIL
    HOP_ADDITION
    WHIRLPOOL
    CHILLING
    TRANSFER
    FERMENTATION
    CONDITIONING
    PACKAGING
    CLEANING
    COMPLETE
    FAULT
    EMERGENCY_STOP
end


# ============================================================
# RECIPE
# ============================================================

struct BrewRecipe

    name::String

    batch_volume_l::Float64

    grain_mass_kg::Float64

    strike_temperature_c::Float64

    mash_temperature_c::Float64

    mash_time_s::Float64

    mashout_temperature_c::Float64

    mashout_time_s::Float64

    boil_temperature_c::Float64

    boil_time_s::Float64

    whirlpool_temperature_c::Float64

    whirlpool_time_s::Float64

    fermentation_temperature_c::Float64

    fermentation_time_s::Float64

    conditioning_temperature_c::Float64

    conditioning_time_s::Float64

    target_og::Float64

    target_fg::Float64

    target_abv::Float64

    target_ibu::Float64

end


function BrewRecipe(;

    name="HOUSE PALE ALE",

    batch_volume_l=20.0,

    grain_mass_kg=4.5,

    strike_temperature_c=72.0,

    mash_temperature_c=67.0,

    mash_time_s=3600.0,

    mashout_temperature_c=76.0,

    mashout_time_s=600.0,

    boil_temperature_c=100.0,

    boil_time_s=3600.0,

    whirlpool_temperature_c=80.0,

    whirlpool_time_s=900.0,

    fermentation_temperature_c=19.0,

    fermentation_time_s=604800.0,

    conditioning_temperature_c=4.0,

    conditioning_time_s=172800.0,

    target_og=1.050,

    target_fg=1.010,

    target_abv=5.2,

    target_ibu=35.0

)

    BrewRecipe(

        name,
        batch_volume_l,
        grain_mass_kg,
        strike_temperature_c,
        mash_temperature_c,
        mash_time_s,
        mashout_temperature_c,
        mashout_time_s,
        boil_temperature_c,
        boil_time_s,
        whirlpool_temperature_c,
        whirlpool_time_s,
        fermentation_temperature_c,
        fermentation_time_s,
        conditioning_temperature_c,
        conditioning_time_s,
        target_og,
        target_fg,
        target_abv,
        target_ibu

    )

end


# ============================================================
# HOP ADDITION
# ============================================================

struct HopAddition

    name::String
    mass_g::Float64
    alpha_acid_percent::Float64
    addition_time_min::Float64

end


# ============================================================
# MACHINE SENSORS
# ============================================================

mutable struct Sensors

    liquid_temperature_c::Float64

    heater_temperature_c::Float64

    ambient_temperature_c::Float64

    liquid_level_l::Float64

    flow_rate_l_min::Float64

    specific_gravity::Float64

    pressure_bar::Float64

    pump_current_a::Float64

    heater_current_a::Float64

    fermentation_activity::Float64

    dissolved_co2::Float64

end


function Sensors()

    Sensors(

        20.0,
        20.0,
        20.0,
        20.0,
        0.0,
        1.040,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0

    )

end


# ============================================================
# THERMAL SYSTEM
# ============================================================

mutable struct ThermalSystem

    target_c::Float64

    heater_power::Float64

    cooling_power::Float64

    heater_enabled::Bool

    cooler_enabled::Bool

    kp::Float64

    ki::Float64

    kd::Float64

    integral::Float64

    previous_error::Float64

end


function ThermalSystem()

    ThermalSystem(

        20.0,
        0.0,
        0.0,
        false,
        false,
        12.0,
        0.02,
        2.0,
        0.0,
        0.0

    )

end


function set_temperature_target!(

    thermal::ThermalSystem,

    target::Float64

)

    thermal.target_c = target

end


function thermal_controller!(

    thermal::ThermalSystem,

    measured::Float64,

    dt::Float64

)

    error =

        thermal.target_c -
        measured


    thermal.integral +=

        error * dt


    derivative =

        (

            error -
            thermal.previous_error

        ) /

        max(dt, 0.001)


    output =

        thermal.kp * error +

        thermal.ki *
        thermal.integral +

        thermal.kd *
        derivative


    thermal.previous_error =
        error


    if error > 0

        thermal.heater_power =

            clamp(

                output,

                0.0,
                100.0

            )

        thermal.cooling_power = 0.0

        thermal.heater_enabled = true
        thermal.cooler_enabled = false

    else

        thermal.cooling_power =

            clamp(

                -output,

                0.0,
                100.0

            )

        thermal.heater_power = 0.0

        thermal.heater_enabled = false
        thermal.cooler_enabled = true

    end

end


# ============================================================
# PUMP SYSTEM
# ============================================================

mutable struct PumpSystem

    enabled::Bool

    speed_percent::Float64

    flow_rate_l_min::Float64

    current_a::Float64

end


function PumpSystem()

    PumpSystem(

        false,
        0.0,
        0.0,
        0.0

    )

end


function set_pump!(

    pump::PumpSystem,

    speed::Float64

)

    pump.speed_percent =

        clamp(

            speed,
            0.0,
            100.0

        )


    pump.enabled =
        speed > 0.0


    pump.flow_rate_l_min =

        0.10 *
        pump.speed_percent


    pump.current_a =

        0.02 *
        pump.speed_percent

end


# ============================================================
# VALVES
# ============================================================

mutable struct ValveSystem

    water_inlet::Bool

    mash_loop::Bool

    lauter_outlet::Bool

    kettle_outlet::Bool

    fermenter_inlet::Bool

    drain::Bool

end


function ValveSystem()

    ValveSystem(

        false,
        false,
        false,
        false,
        false,
        false

    )

end


function close_all!(

    valves::ValveSystem

)

    valves.water_inlet = false
    valves.mash_loop = false
    valves.lauter_outlet = false
    valves.kettle_outlet = false
    valves.fermenter_inlet = false
    valves.drain = false

end


# ============================================================
# MASH MODEL
# ============================================================

mutable struct MashModel

    conversion_percent::Float64

    enzyme_activity::Float64

    viscosity::Float64

    ph::Float64

    extraction_efficiency::Float64

end


function MashModel()

    MashModel(

        0.0,
        1.0,
        1.0,
        5.3,
        0.0

    )

end


function update_mash!(

    mash::MashModel,

    temperature_c::Float64,

    dt::Float64

)

    beta_activity =

        exp(

            -((temperature_c - 63.0)^2) /
            (2.0 * 7.0^2)

        )


    alpha_activity =

        exp(

            -((temperature_c - 70.0)^2) /
            (2.0 * 6.0^2)

        )


    mash.enzyme_activity =

        clamp(

            0.45 *
            beta_activity +

            0.55 *
            alpha_activity,

            0.0,
            1.0

        )


    mash.conversion_percent +=

        0.004 *
        mash.enzyme_activity *
        dt


    mash.conversion_percent =

        clamp(

            mash.conversion_percent,

            0.0,
            100.0

        )


    mash.viscosity =

        max(

            0.5,

            1.5 -
            mash.conversion_percent /
            100.0

        )


    mash.extraction_efficiency =

        0.55 +

        0.40 *
        mash.conversion_percent /
        100.0

end


# ============================================================
# BOIL MODEL
# ============================================================

mutable struct BoilModel

    evaporation_rate_l_h::Float64

    volume_l::Float64

    gravity_concentration_factor::Float64

    boil_intensity::Float64

end


function BoilModel(

    volume_l=20.0

)

    BoilModel(

        2.5,

        volume_l,

        1.0,

        0.0

    )

end


function update_boil!(

    boil::BoilModel,

    dt::Float64,

    heater_power::Float64

)

    boil.boil_intensity =

        clamp(

            heater_power /
            100.0,

            0.0,
            1.0

        )


    evaporation =

        boil.evaporation_rate_l_h *

        boil.boil_intensity *

        dt / 3600.0


    boil.volume_l =

        max(

            boil.volume_l -
            evaporation,

            1.0

        )


    boil.gravity_concentration_factor =

        20.0 /
        boil.volume_l

end


# ============================================================
# FERMENTATION MODEL
# ============================================================

mutable struct FermentationModel

    gravity::Float64

    original_gravity::Float64

    final_gravity::Float64

    attenuation_percent::Float64

    yeast_activity::Float64

    temperature_c::Float64

    co2_rate::Float64

end


function FermentationModel()

    FermentationModel(

        1.050,

        1.050,

        1.010,

        0.0,

        1.0,

        20.0,

        0.0

    )

end


function update_fermentation!(

    fermentation::FermentationModel,

    dt::Float64

)

    gravity_error =

        fermentation.gravity -
        fermentation.final_gravity


    fermentation.yeast_activity =

        clamp(

            1.0 -
            abs(

                fermentation.temperature_c -
                20.0

            ) / 15.0,

            0.0,
            1.0

        )


    fermentation.gravity -=

        0.00000012 *
        fermentation.yeast_activity *
        max(gravity_error, 0.0) *
        dt


    fermentation.gravity =

        max(

            fermentation.gravity,
            fermentation.final_gravity

        )


    fermentation.attenuation_percent =

        (

            fermentation.original_gravity -
            fermentation.gravity

        ) /

        (

            fermentation.original_gravity -
            1.000

        ) *

        100.0


    fermentation.co2_rate =

        fermentation.yeast_activity *

        max(

            fermentation.original_gravity -
            fermentation.gravity,

            0.0

        ) *

        10000.0

end


# ============================================================
# BREWING QUALITY MODEL
# ============================================================

function estimate_abv(

    og::Float64,

    fg::Float64

)

    return (

        og - fg

    ) * 131.25

end


function estimate_ibu(

    hops::Vector{HopAddition},

    volume_l::Float64

)

    total = 0.0


    for hop in hops

        utilization =

            0.231 *

            (

                1.0 -
                exp(

                    -0.04 *
                    hop.addition_time_min

                )

            )


        ibu =

            (

                hop.mass_g *
                (

                    hop.alpha_acid_percent /
                    100.0

                ) *
                utilization *
                1000.0

            ) /

            max(

                volume_l,

                1.0

            )


        total += ibu

    end


    return total

end


# ============================================================
# SAFETY SYSTEM
# ============================================================

mutable struct SafetySystem

    lid_closed::Bool

    vessel_locked::Bool

    overtemperature::Bool

    overpressure::Bool

    low_level::Bool

    emergency_stop::Bool

end


function SafetySystem()

    SafetySystem(

        true,
        true,
        false,
        false,
        false,
        false

    )

end


function safety_ok(

    safety::SafetySystem,

    sensors::Sensors

)

    safety.overtemperature =

        sensors.liquid_temperature_c >
        105.0


    safety.overpressure =

        sensors.pressure_bar >
        2.0


    safety.low_level =

        sensors.liquid_level_l <
        2.0


    return (

        safety.lid_closed &&

        safety.vessel_locked &&

        !safety.overtemperature &&

        !safety.overpressure &&

        !safety.emergency_stop

    )

end


# ============================================================
# TELEMETRY
# ============================================================

struct TelemetryPoint

    timestamp::DateTime

    state::BrewState

    temperature_c::Float64

    volume_l::Float64

    gravity::Float64

    mash_conversion::Float64

    fermentation_activity::Float64

    heater_power::Float64

    pump_speed::Float64

    pressure_bar::Float64

end


mutable struct Telemetry

    points::Vector{TelemetryPoint}

end


Telemetry() =

    Telemetry(

        TelemetryPoint[]

    )


# ============================================================
# BATCH
# ============================================================

struct Batch

    id::String

    recipe::String

    start_time::DateTime

end


function create_batch(

    recipe::BrewRecipe

)

    Batch(

        "BREW-" *

        Dates.format(

            now(),

            "yyyymmdd-HHMMSS"

        ),

        recipe.name,

        now()

    )

end


# ============================================================
# BREWERY MACHINE
# ============================================================

mutable struct BreweryMachine

    name::String

    state::BrewState

    recipe::BrewRecipe

    hops::Vector{HopAddition}

    sensors::Sensors

    thermal::ThermalSystem

    pump::PumpSystem

    valves::ValveSystem

    mash::MashModel

    boil::BoilModel

    fermentation::FermentationModel

    safety::SafetySystem

    telemetry::Telemetry

    batch::Union{Nothing,Batch}

    elapsed_s::Float64

    state_elapsed_s::Float64

end


function BreweryMachine(

    name="BREWERY-001",

    recipe=BrewRecipe()

)

    hops = [

        HopAddition(

            "Cascade",

            25.0,

            5.5,

            60.0

        ),

        HopAddition(

            "Cascade",

            20.0,

            5.5,

            10.0

        ),

        HopAddition(

            "Citra",

            25.0,

            12.0,

            5.0

        )

    ]


    BreweryMachine(

        name,

        IDLE,

        recipe,

        hops,

        Sensors(),

        ThermalSystem(),

        PumpSystem(),

        ValveSystem(),

        MashModel(),

        BoilModel(

            recipe.batch_volume_l

        ),

        FermentationModel(),

        SafetySystem(),

        Telemetry(),

        nothing,

        0.0,

        0.0

    )

end


# ============================================================
# START
# ============================================================

function start_batch!(

    machine::BreweryMachine

)

    machine.state == IDLE ||

        error(

            "Brewery must be idle."

        )


    machine.batch =

        create_batch(

            machine.recipe

        )


    machine.state =
        WATER_HEAT


    machine.elapsed_s =
        0.0


    machine.state_elapsed_s =
        0.0


    machine.sensors.liquid_level_l =

        machine.recipe.batch_volume_l

end


# ============================================================
# WATER HEAT
# ============================================================

function water_heat_step!(

    machine::BreweryMachine,

    dt

)

    target =

        machine.recipe.strike_temperature_c


    set_temperature_target!(

        machine.thermal,

        target

    )


    thermal_controller!(

        machine.thermal,

        machine.sensors.liquid_temperature_c,

        dt

    )


    # Simplified thermal model.

    machine.sensors.liquid_temperature_c +=

        0.003 *
        machine.thermal.heater_power *
        dt


    machine.sensors.liquid_temperature_c -=

        0.0005 *

        (

            machine.sensors.liquid_temperature_c -
            machine.sensors.ambient_temperature_c

        ) *

        dt


    machine.state_elapsed_s += dt


    if machine.sensors.liquid_temperature_c >=

       target - 0.5

        machine.state =
            MASH_IN

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# MASH IN
# ============================================================

function mash_in_step!(

    machine::BreweryMachine,

    dt

)

    set_temperature_target!(

        machine.thermal,

        machine.recipe.mash_temperature_c

    )


    thermal_controller!(

        machine.thermal,

        machine.sensors.liquid_temperature_c,

        dt

    )


    machine.sensors.liquid_temperature_c +=

        (

            0.002 *
            machine.thermal.heater_power -

            0.002 *
            machine.thermal.cooling_power

        ) *

        dt


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >= 120.0

        machine.state =
            MASH

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# MASH
# ============================================================

function mash_step!(

    machine::BreweryMachine,

    dt

)

    set_temperature_target!(

        machine.thermal,

        machine.recipe.mash_temperature_c

    )


    thermal_controller!(

        machine.thermal,

        machine.sensors.liquid_temperature_c,

        dt

    )


    machine.sensors.liquid_temperature_c +=

        (

            0.0015 *
            machine.thermal.heater_power -

            0.001 *
            machine.thermal.cooling_power

        ) *

        dt


    set_pump!(

        machine.pump,

        30.0

    )


    update_mash!(

        machine.mash,

        machine.sensors.liquid_temperature_c,

        dt

    )


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >=

       machine.recipe.mash_time_s

        machine.state =
            MASH_OUT

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# MASH OUT
# ============================================================

function mash_out_step!(

    machine::BreweryMachine,

    dt

)

    set_temperature_target!(

        machine.thermal,

        machine.recipe.mashout_temperature_c

    )


    thermal_controller!(

        machine.thermal,

        machine.sensors.liquid_temperature_c,

        dt

    )


    machine.sensors.liquid_temperature_c +=

        0.002 *
        machine.thermal.heater_power *
        dt


    machine.state_elapsed_s += dt


    if machine.sensors.liquid_temperature_c >=

       machine.recipe.mashout_temperature_c - 0.5 &&

       machine.state_elapsed_s >=

       machine.recipe.mashout_time_s

        machine.state =
            LAUTER

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# LAUTER
# ============================================================

function lauter_step!(

    machine::BreweryMachine,

    dt

)

    set_pump!(

        machine.pump,

        35.0

    )


    machine.valves.mash_loop =
        false

    machine.valves.lauter_outlet =
        true


    # Extract sugars into kettle.

    extraction =

        machine.mash.extraction_efficiency


    machine.sensors.specific_gravity =

        machine.recipe.target_og *

        (

            0.85 +
            0.15 * extraction

        )


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >= 900.0

        set_pump!(

            machine.pump,
            0.0

        )


        machine.state =
            BOIL

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# BOIL
# ============================================================

function boil_step!(

    machine::BreweryMachine,

    dt

)

    set_temperature_target!(

        machine.thermal,

        machine.recipe.boil_temperature_c

    )


    thermal_controller!(

        machine.thermal,

        machine.sensors.liquid_temperature_c,

        dt

    )


    machine.sensors.liquid_temperature_c +=

        0.003 *
        machine.thermal.heater_power *
        dt


    if machine.sensors.liquid_temperature_c >= 99.0

        machine.thermal.heater_power =

            max(

                machine.thermal.heater_power,

                65.0

            )

    end


    update_boil!(

        machine.boil,

        dt,

        machine.thermal.heater_power

    )


    machine.sensors.liquid_level_l =

        machine.boil.volume_l


    machine.state_elapsed_s += dt


    # Hop schedule is handled by the next state.

    if machine.state_elapsed_s >=

       machine.recipe.boil_time_s

        machine.state =
            WHIRLPOOL

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# WHIRLPOOL / HOPS
# ============================================================

function whirlpool_step!(

    machine::BreweryMachine,

    dt

)

    set_temperature_target!(

        machine.thermal,

        machine.recipe.whirlpool_temperature_c

    )


    thermal_controller!(

        machine.thermal,

        machine.sensors.liquid_temperature_c,

        dt

    )


    set_pump!(

        machine.pump,

        45.0

    )


    machine.sensors.liquid_temperature_c +=

        (

            0.001 *
            machine.thermal.heater_power -

            0.0015 *
            machine.thermal.cooling_power

        ) *

        dt


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >=

       machine.recipe.whirlpool_time_s

        set_pump!(

            machine.pump,

            0.0

        )


        machine.state =
            CHILLING

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# CHILLING
# ============================================================

function chilling_step!(

    machine::BreweryMachine,

    dt

)

    set_temperature_target!(

        machine.thermal,

        machine.recipe.fermentation_temperature_c

    )


    thermal_controller!(

        machine.thermal,

        machine.sensors.liquid_temperature_c,

        dt

    )


    machine.sensors.liquid_temperature_c -=

        0.003 *
        machine.thermal.cooling_power *
        dt


    machine.state_elapsed_s += dt


    if machine.sensors.liquid_temperature_c <=

       machine.recipe.fermentation_temperature_c + 0.5

        machine.state =
            TRANSFER

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# TRANSFER
# ============================================================

function transfer_step!(

    machine::BreweryMachine,

    dt

)

    set_pump!(

        machine.pump,

        60.0

    )


    machine.valves.kettle_outlet =
        true

    machine.valves.fermenter_inlet =
        true


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >= 180.0

        set_pump!(

            machine.pump,
            0.0

        )


        machine.fermentation.original_gravity =

            machine.recipe.target_og


        machine.fermentation.gravity =

            machine.recipe.target_og


        machine.fermentation.final_gravity =

            machine.recipe.target_fg


        machine.fermentation.temperature_c =

            machine.recipe.fermentation_temperature_c


        machine.state =
            FERMENTATION

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# FERMENTATION
# ============================================================

function fermentation_step!(

    machine::BreweryMachine,

    dt

)

    machine.fermentation.temperature_c =

        machine.recipe.fermentation_temperature_c


    update_fermentation!(

        machine.fermentation,

        dt

    )


    machine.sensors.specific_gravity =

        machine.fermentation.gravity


    machine.sensors.fermentation_activity =

        machine.fermentation.yeast_activity


    machine.sensors.dissolved_co2 =

        machine.fermentation.co2_rate


    machine.state_elapsed_s += dt


    gravity_complete =

        machine.fermentation.gravity <=

        machine.recipe.target_fg + 0.001


    if gravity_complete &&

       machine.state_elapsed_s >=

       machine.recipe.fermentation_time_s

        machine.state =
            CONDITIONING

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# CONDITIONING
# ============================================================

function conditioning_step!(

    machine::BreweryMachine,

    dt

)

    set_temperature_target!(

        machine.thermal,

        machine.recipe.conditioning_temperature_c

    )


    thermal_controller!(

        machine.thermal,

        machine.fermentation.temperature_c,

        dt

    )


    machine.fermentation.temperature_c -=

        0.001 *
        machine.thermal.cooling_power *
        dt


    machine.fermentation.temperature_c =

        max(

            machine.fermentation.temperature_c,

            machine.recipe.conditioning_temperature_c

        )


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >=

       machine.recipe.conditioning_time_s

        machine.state =
            PACKAGING

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# PACKAGING
# ============================================================

function packaging_step!(

    machine::BreweryMachine,

    dt

)

    machine.sensors.pressure_bar =

        1.0


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >= 120.0

        machine.state =
            COMPLETE

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# MASTER CONTROL LOOP
# ============================================================

function control_step!(

    machine::BreweryMachine,

    dt::Float64=1.0

)

    if machine.state in (

        IDLE,
        COMPLETE,
        FAULT,
        EMERGENCY_STOP

    )

        return

    end


    # Safety interlock.

    if !safety_ok(

        machine.safety,

        machine.sensors

    )

        emergency_stop!(
            machine
        )

        return

    end


    if machine.state == WATER_HEAT

        water_heat_step!(
            machine,
            dt
        )


    elseif machine.state == MASH_IN

        mash_in_step!(
            machine,
            dt
        )


    elseif machine.state == MASH

        mash_step!(
            machine,
            dt
        )


    elseif machine.state == MASH_OUT

        mash_out_step!(
            machine,
            dt
        )


    elseif machine.state == LAUTER

        lauter_step!(
            machine,
            dt
        )


    elseif machine.state == BOIL

        boil_step!(
            machine,
            dt
        )


    elseif machine.state == WHIRLPOOL

        whirlpool_step!(
            machine,
            dt
        )


    elseif machine.state == CHILLING

        chilling_step!(
            machine,
            dt
        )


    elseif machine.state == TRANSFER

        transfer_step!(
            machine,
            dt
        )


    elseif machine.state == FERMENTATION

        fermentation_step!(
            machine,
            dt
        )


    elseif machine.state == CONDITIONING

        conditioning_step!(
            machine,
            dt
        )


    elseif machine.state == PACKAGING

        packaging_step!(
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
# EMERGENCY STOP
# ============================================================

function emergency_stop!(

    machine::BreweryMachine

)

    machine.thermal.heater_enabled =
        false

    machine.thermal.cooler_enabled =
        false

    machine.thermal.heater_power =
        0.0

    machine.thermal.cooling_power =
        0.0


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
# TELEMETRY
# ============================================================

function record_telemetry!(

    machine::BreweryMachine

)

    push!(

        machine.telemetry.points,

        TelemetryPoint(

            now(),

            machine.state,

            machine.sensors.liquid_temperature_c,

            machine.sensors.liquid_level_l,

            machine.sensors.specific_gravity,

            machine.mash.conversion_percent,

            machine.fermentation.yeast_activity,

            machine.thermal.heater_power,

            machine.pump.speed_percent,

            machine.sensors.pressure_bar

        )

    )

end


# ============================================================
# CLEANING
# ============================================================

function cleaning_cycle!(

    machine::BreweryMachine

)

    machine.state in (

        IDLE,
        COMPLETE

    ) || error(

        "Brewery must be idle before cleaning."

    )


    machine.state =
        CLEANING


    println()
    println("="^70)
    println("BREWERY.OS CLEAN-IN-PLACE")
    println("="^70)

    println("1. Drain product")

    println("2. Warm-water flush")

    println("3. Recirculation wash")

    println("4. Rinse")

    println("5. Sanitation verification")

    println("6. Final drain")

    println("7. Vessel-ready verification")

    println("="^70)


    close_all!(

        machine.valves

    )


    machine.state =
        IDLE

end


# ============================================================
# STATUS
# ============================================================

function display_status!(

    machine::BreweryMachine

)

    println(

        @sprintf(

            "%-16s | %7.2f°C | VOL %6.2f L | SG %.3f | MASH %6.1f%% | YEAST %5.1f%% | HEAT %5.1f%% | PUMP %5.1f%%",

            string(machine.state),

            machine.sensors.liquid_temperature_c,

            machine.sensors.liquid_level_l,

            machine.sensors.specific_gravity,

            machine.mash.conversion_percent,

            machine.fermentation.yeast_activity * 100.0,

            machine.thermal.heater_power,

            machine.pump.speed_percent

        )

    )

end


# ============================================================
# BATCH REPORT
# ============================================================

function batch_report(

    machine::BreweryMachine

)

    og =
        machine.fermentation.original_gravity


    fg =
        machine.fermentation.gravity


    abv =
        estimate_abv(

            og,
            fg

        )


    ibu =
        estimate_ibu(

            machine.hops,

            machine.boil.volume_l

        )


    return (

        batch_id =
            machine.batch === nothing ?

            "NONE" :

            machine.batch.id,

        recipe =
            machine.recipe.name,

        volume_l =
            machine.boil.volume_l,

        og =
            og,

        fg =
            fg,

        abv =
            abv,

        ibu =
            ibu,

        mash_conversion =
            machine.mash.conversion_percent,

        extraction_efficiency =
            machine.mash.extraction_efficiency,

        fermentation_attenuation =
            machine.fermentation.attenuation_percent,

        processing_hours =
            machine.elapsed_s / 3600.0,

        telemetry_points =
            length(

                machine.telemetry.points

            )

    )

end


# ============================================================
# RECIPE LIBRARY
# ============================================================

const RECIPES = Dict(

    "PALE_ALE" =>

        BrewRecipe(

            name="HOUSE PALE ALE",

            batch_volume_l=20.0,

            grain_mass_kg=4.5,

            target_og=1.050,

            target_fg=1.010,

            target_abv=5.2,

            target_ibu=35.0

        ),


    "IPA" =>

        BrewRecipe(

            name="HOUSE IPA",

            batch_volume_l=20.0,

            grain_mass_kg=5.5,

            mash_temperature_c=65.0,

            target_og=1.060,

            target_fg=1.010,

            target_abv=6.6,

            target_ibu=55.0

        ),


    "STOUT" =>

        BrewRecipe(

            name="HOUSE STOUT",

            batch_volume_l=20.0,

            grain_mass_kg=5.0,

            mash_temperature_c=68.0,

            target_og=1.055,

            target_fg=1.012,

            target_abv=5.6,

            target_ibu=32.0

        )

)


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println()
    println("="^110)

    println(
        "                         BREWERY.OS"
    )

    println(
        "              AUTOMATED HOME MICRO-BREWERY"
    )

    println("="^110)


    recipe =
        RECIPES["PALE_ALE"]


    machine =

        BreweryMachine(

            "BREWERY-HOME-001",

            recipe

        )


    println()

    println(
        "RECIPE             : ",
        recipe.name
    )

    println(
        "BATCH VOLUME       : ",
        recipe.batch_volume_l,
        " L"
    )

    println(
        "GRAIN              : ",
        recipe.grain_mass_kg,
        " kg"
    )

    println(
        "TARGET OG          : ",
        recipe.target_og
    )

    println(
        "TARGET FG          : ",
        recipe.target_fg
    )

    println(
        "TARGET ABV         : ",
        recipe.target_abv,
        "%"
    )

    println(
        "TARGET IBU         : ",
        recipe.target_ibu
    )

    println()


    println(
        "STARTING BATCH..."
    )


    start_batch!(
        machine
    )


    println(

        "BATCH ID           : ",

        machine.batch.id

    )


    println()

    println(
        "BREWERY CONTROL LOOP ACTIVE"
    )

    println("-"^110)


    # Demonstration uses accelerated simulation time.

    for tick in 1:200000

        control_step!(

            machine,

            10.0

        )


        if tick % 100 == 0

            display_status!(
                machine
            )

        end


        if machine.state == COMPLETE

            break

        end


        if machine.state == EMERGENCY_STOP

            println(
                "EMERGENCY STOP"
            )

            break

        end

    end


    report =
        batch_report(

            machine

        )


    println()

    println("="^110)

    println(
        "                         BREW COMPLETE"
    )

    println("="^110)


    println(
        "Batch ID             : ",
        report.batch_id
    )

    println(
        "Final volume         : ",
        round(
            report.volume_l,
            digits=2
        ),
        " L"
    )

    println(
        "Original gravity     : ",
        round(
            report.og,
            digits=3
        )
    )

    println(
        "Final gravity        : ",
        round(
            report.fg,
            digits=3
        )
    )

    println(
        "Estimated ABV        : ",
        round(
            report.abv,
            digits=2
        ),
        "%"
    )

    println(
        "Estimated IBU        : ",
        round(
            report.ibu,
            digits=1
        )
    )

    println(
        "Mash conversion      : ",
        round(
            report.mash_conversion,
            digits=1
        ),
        "%"
    )

    println(
        "Extraction efficiency: ",
        round(
            report.extraction_efficiency * 100,
            digits=1
        ),
        "%"
    )

    println(
        "Attenuation          : ",
        round(
            report.fermentation_attenuation,
            digits=1
        ),
        "%"
    )

    println(
        "Processing time      : ",
        round(
            report.processing_hours,
            digits=2
        ),
        " h"
    )

    println(
        "Telemetry points     : ",
        report.telemetry_points
    )

    println("="^110)

end


# ============================================================
# PUBLIC API
# ============================================================

export BrewState
export BrewRecipe
export HopAddition
export BreweryMachine
export RECIPES

export start_batch!
export control_step!
export emergency_stop!
export cleaning_cycle!
export display_status!
export batch_report

export IDLE
export WATER_HEAT
export MASH_IN
export MASH
export MASH_OUT
export LAUTER
export BOIL
export HOP_ADDITION
export WHIRLPOOL
export CHILLING
export TRANSFER
export FERMENTATION
export CONDITIONING
export PACKAGING
export CLEANING
export COMPLETE
export FAULT
export EMERGENCY_STOP

export demo


end # module


# ============================================================
# APPLICATION ENTRY POINT
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .BreweryOS

    BreweryOS.demo()

end
```


