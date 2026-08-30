# ICECREAM.OS

## Intelligent Automated Ice-Cream Appliance

### Pure Julia — Full Control-System Prototype

```julia
module IceCreamOS

using Dates
using Printf
using Statistics


# ============================================================
# ICECREAM.OS
# ============================================================
#
# Automated ice-cream appliance controller / digital twin.
#
# PROCESS:
#
# INGREDIENT LOADING
#       ↓
# DOSING
#       ↓
# MIXING
#       ↓
# THERMAL TREATMENT
#       ↓
# RAPID COOLING
#       ↓
# AGEING
#       ↓
# FREEZING
#       ↓
# OVERRUN CONTROL
#       ↓
# HARDNESS CONTROL
#       ↓
# FINISHING
#       ↓
# DISPENSE / COMPLETE
#       ↓
# CLEANING
#
# This is a software simulation/control architecture.
# Real food equipment requires independently validated
# thermal, electrical, refrigeration and safety systems.
#
# ============================================================


# ============================================================
# MACHINE STATES
# ============================================================

@enum IceCreamState begin
    IDLE
    DOSING
    MIXING
    HEATING
    COOLING
    AGEING
    FREEZING
    OVERRUN_CONTROL
    HARDNESS_CONTROL
    FINISHING
    DISPENSING
    COMPLETE
    CLEANING
    FAULT
    EMERGENCY_STOP
end


# ============================================================
# RECIPE
# ============================================================

struct IceCreamRecipe

    name::String

    target_mass_g::Float64

    target_temperature_c::Float64

    heating_temperature_c::Float64

    cooling_temperature_c::Float64

    ageing_temperature_c::Float64

    freezing_temperature_c::Float64

    target_overrun_percent::Float64

    target_hardness::Float64

    mixing_time_s::Float64

    heating_time_s::Float64

    ageing_time_s::Float64

    maximum_freezing_time_s::Float64

end


function IceCreamRecipe(;

    name="VANILLA",

    target_mass_g=1000.0,

    target_temperature_c=-5.0,

    heating_temperature_c=82.0,

    cooling_temperature_c=4.0,

    ageing_temperature_c=4.0,

    freezing_temperature_c=-8.0,

    target_overrun_percent=25.0,

    target_hardness=0.88,

    mixing_time_s=180.0,

    heating_time_s=300.0,

    ageing_time_s=900.0,

    maximum_freezing_time_s=1800.0

)

    IceCreamRecipe(

        name,

        target_mass_g,

        target_temperature_c,

        heating_temperature_c,

        cooling_temperature_c,

        ageing_temperature_c,

        freezing_temperature_c,

        target_overrun_percent,

        target_hardness,

        mixing_time_s,

        heating_time_s,

        ageing_time_s,

        maximum_freezing_time_s

    )

end


# ============================================================
# INGREDIENT SYSTEM
# ============================================================

mutable struct IngredientSystem

    milk_g::Float64

    cream_g::Float64

    sugar_g::Float64

    milk_solids_g::Float64

    stabilizer_g::Float64

    flavour_g::Float64

    total_mass_g::Float64

    loaded::Bool

end


function IngredientSystem()

    IngredientSystem(

        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        false

    )

end


function load_ingredients!(

    ingredients::IngredientSystem;

    milk_g=500.0,
    cream_g=300.0,
    sugar_g=150.0,
    milk_solids_g=40.0,
    stabilizer_g=2.0,
    flavour_g=1.0

)

    ingredients.milk_g =
        milk_g

    ingredients.cream_g =
        cream_g

    ingredients.sugar_g =
        sugar_g

    ingredients.milk_solids_g =
        milk_solids_g

    ingredients.stabilizer_g =
        stabilizer_g

    ingredients.flavour_g =
        flavour_g

    ingredients.total_mass_g =

        milk_g +
        cream_g +
        sugar_g +
        milk_solids_g +
        stabilizer_g +
        flavour_g

    ingredients.loaded = true

end


# ============================================================
# PRODUCT MODEL
# ============================================================

mutable struct IceCreamProduct

    mass_g::Float64

    temperature_c::Float64

    fat_fraction::Float64

    sugar_fraction::Float64

    solids_fraction::Float64

    viscosity::Float64

    overrun_percent::Float64

    hardness::Float64

    ice_fraction::Float64

    texture_score::Float64

    smoothness::Float64

    flavour_intensity::Float64

end


function IceCreamProduct()

    IceCreamProduct(

        0.0,
        20.0,
        0.0,
        0.0,
        0.0,
        0.05,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0

    )

end


function initialise_product!(

    product::IceCreamProduct,

    ingredients::IngredientSystem

)

    product.mass_g =
        ingredients.total_mass_g


    product.temperature_c =
        20.0


    product.fat_fraction =

        ingredients.cream_g /
        max(
            product.mass_g,
            1.0
        ) *
        0.35


    product.sugar_fraction =

        ingredients.sugar_g /
        max(
            product.mass_g,
            1.0
        )


    product.solids_fraction =

        (

            ingredients.sugar_g +
            ingredients.milk_solids_g +
            ingredients.stabilizer_g

        ) /

        max(
            product.mass_g,
            1.0
        )


    product.viscosity =
        0.05


    product.overrun_percent =
        0.0


    product.hardness =
        0.0


    product.ice_fraction =
        0.0


    product.texture_score =
        0.0


    product.smoothness =
        0.0


    product.flavour_intensity =
        clamp(

            ingredients.flavour_g /
            max(product.mass_g, 1.0) *
            100.0,

            0.0,
            1.0

        )

end


# ============================================================
# THERMAL SYSTEM
# ============================================================

mutable struct ThermalSystem

    product_temperature_c::Float64

    target_temperature_c::Float64

    heater_power_percent::Float64

    cooling_power_percent::Float64

    heater_enabled::Bool

    refrigeration_enabled::Bool

    ambient_temperature_c::Float64

    minimum_temperature_c::Float64

    maximum_temperature_c::Float64

end


function ThermalSystem()

    ThermalSystem(

        20.0,
        20.0,
        0.0,
        0.0,
        false,
        false,
        20.0,
        -25.0,
        100.0

    )

end


function set_thermal_target!(

    thermal::ThermalSystem,

    target::Float64

)

    thermal.target_temperature_c =

        clamp(

            target,

            thermal.minimum_temperature_c,

            thermal.maximum_temperature_c

        )

end


function update_thermal!(

    thermal::ThermalSystem,

    dt::Float64,

    mass_g::Float64

)

    error =

        thermal.target_temperature_c -
        thermal.product_temperature_c


    if error > 0

        thermal.heater_power_percent =

            clamp(

                55.0 +
                8.0 * error,

                0.0,
                100.0

            )

        thermal.cooling_power_percent = 0.0

        thermal.heater_enabled = true
        thermal.refrigeration_enabled = false

    else

        thermal.cooling_power_percent =

            clamp(

                -error * 15.0,

                0.0,
                100.0

            )

        thermal.heater_power_percent = 0.0

        thermal.heater_enabled = false
        thermal.refrigeration_enabled = true

    end


    mass_factor =

        1000.0 /
        max(mass_g, 250.0)


    heating_effect =

        0.010 *
        thermal.heater_power_percent *
        mass_factor


    cooling_effect =

        0.025 *
        thermal.cooling_power_percent *
        mass_factor


    environmental_loss =

        (

            thermal.product_temperature_c -
            thermal.ambient_temperature_c

        ) * 0.0008


    thermal.product_temperature_c +=

        (

            heating_effect -
            cooling_effect -
            environmental_loss

        ) * dt


    thermal.product_temperature_c =

        clamp(

            thermal.product_temperature_c,

            thermal.minimum_temperature_c,

            thermal.maximum_temperature_c

        )

end


# ============================================================
# MIXER
# ============================================================

mutable struct MixerSystem

    enabled::Bool

    speed_percent::Float64

    torque_nm::Float64

    current_a::Float64

    maximum_current_a::Float64

    overload::Bool

end


function MixerSystem()

    MixerSystem(

        false,
        0.0,
        0.0,
        0.0,
        10.0,
        false

    )

end


function set_mixer_speed!(

    mixer::MixerSystem,

    speed::Float64

)

    mixer.speed_percent =

        clamp(

            speed,
            0.0,
            100.0

        )


    mixer.enabled =
        mixer.speed_percent > 0.0

end


function update_mixer!(

    mixer::MixerSystem,

    viscosity::Float64

)

    mixer.torque_nm =

        0.4 +
        viscosity *
        mixer.speed_percent /
        100.0 *
        6.0


    mixer.current_a =

        0.5 +
        mixer.torque_nm *
        0.8


    mixer.overload =

        mixer.current_a >
        mixer.maximum_current_a

end


# ============================================================
# FREEZER / COMPRESSOR
# ============================================================

mutable struct FreezerSystem

    compressor_enabled::Bool

    compressor_power_percent::Float64

    evaporator_temperature_c::Float64

    compressor_current_a::Float64

    suction_pressure_bar::Float64

end


function FreezerSystem()

    FreezerSystem(

        false,
        0.0,
        -10.0,
        0.0,
        2.0

    )

end


function set_freezer_power!(

    freezer::FreezerSystem,

    power::Float64

)

    freezer.compressor_power_percent =

        clamp(

            power,
            0.0,
            100.0

        )


    freezer.compressor_enabled =

        power > 0.0

end


function update_freezer!(

    freezer::FreezerSystem,

    product_temperature_c::Float64,

    dt::Float64

)

    if !freezer.compressor_enabled

        freezer.compressor_current_a = 0.0

        return

    end


    freezer.evaporator_temperature_c =

        -8.0 -
        15.0 *
        freezer.compressor_power_percent /
        100.0


    freezer.compressor_current_a =

        1.0 +
        4.0 *
        freezer.compressor_power_percent /
        100.0


    freezer.suction_pressure_bar =

        3.0 -
        1.0 *
        freezer.compressor_power_percent /
        100.0

end


# ============================================================
# AIR / OVERRUN SYSTEM
# ============================================================

mutable struct OverrunSystem

    air_pump_enabled::Bool

    air_rate_percent::Float64

    injected_air_volume_ml::Float64

end


function OverrunSystem()

    OverrunSystem(

        false,
        0.0,
        0.0

    )

end


function set_air_rate!(

    air::OverrunSystem,

    rate::Float64

)

    air.air_rate_percent =

        clamp(

            rate,
            0.0,
            100.0

        )


    air.air_pump_enabled =
        rate > 0.0

end


function update_overrun!(

    air::OverrunSystem,

    product::IceCreamProduct,

    target_overrun::Float64,

    dt::Float64

)

    current =

        product.overrun_percent


    error =

        target_overrun -
        current


    if error > 1.0

        set_air_rate!(

            air,

            clamp(

                error * 4.0,

                0.0,
                100.0

            )

        )

    else

        set_air_rate!(

            air,
            0.0

        )

    end


    if air.air_pump_enabled

        product.overrun_percent +=

            0.015 *
            air.air_rate_percent *
            dt

    end


    product.overrun_percent =

        clamp(

            product.overrun_percent,

            0.0,
            150.0

        )


    air.injected_air_volume_ml +=

        air.air_rate_percent *
        0.2 *
        dt

end


# ============================================================
# HARDNESS MODEL
# ============================================================

function update_hardness!(

    product::IceCreamProduct,

    dt::Float64

)

    # Simplified digital-twin relationship.

    thermal_factor =

        clamp(

            (

                -product.temperature_c

            ) / 12.0,

            0.0,
            1.0

        )


    overrun_factor =

        clamp(

            product.overrun_percent /
            40.0,

            0.0,
            1.0

        )


    solids_factor =

        clamp(

            product.solids_fraction /
            0.30,

            0.0,
            1.0

        )


    product.ice_fraction =

        clamp(

            0.70 *
            thermal_factor +
            0.30 *
            solids_factor,

            0.0,
            1.0

        )


    product.hardness =

        clamp(

            0.65 *
            product.ice_fraction +

            0.20 *
            solids_factor +

            0.15 *
            overrun_factor,

            0.0,
            1.0

        )


    # Texture improves during controlled freezing.

    product.smoothness +=

        0.0007 *
        (

            1.0 -
            abs(

                product.overrun_percent -
                25.0

            ) / 25.0

        ) *
        dt


    product.smoothness =

        clamp(

            product.smoothness,

            0.0,
            1.0

        )


    product.texture_score =

        0.5 *
        product.smoothness +

        0.5 *
        (

            1.0 -
            abs(

                product.hardness -
                0.88

            )

        )

end


# ============================================================
# QUALITY MODEL
# ============================================================

function quality_score(

    product::IceCreamProduct,

    recipe::IceCreamRecipe

)

    overrun_score =

        1.0 -

        min(

            abs(

                product.overrun_percent -
                recipe.target_overrun_percent

            ) / 50.0,

            1.0

        )


    hardness_score =

        1.0 -

        min(

            abs(

                product.hardness -
                recipe.target_hardness

            ),

            1.0

        )


    temperature_score =

        1.0 -

        min(

            abs(

                product.temperature_c -
                recipe.target_temperature_c

            ) / 15.0,

            1.0

        )


    score =

        100.0 *

        (

            0.30 *
            overrun_score +

            0.30 *
            hardness_score +

            0.20 *
            temperature_score +

            0.20 *
            product.texture_score

        )


    clamp(

        score,
        0.0,
        100.0

    )

end


# ============================================================
# SAFETY SYSTEM
# ============================================================

mutable struct SafetySystem

    lid_closed::Bool

    vessel_locked::Bool

    agitator_guard_closed::Bool

    compressor_safe::Bool

    thermal_safe::Bool

    motor_overload::Bool

    emergency_stop::Bool

    maximum_temperature_c::Float64

end


function SafetySystem()

    SafetySystem(

        true,
        true,
        true,
        true,
        true,
        false,
        false,
        100.0

    )

end


function check_safety!(

    safety::SafetySystem,

    mixer::MixerSystem,

    thermal::ThermalSystem

)

    safety.motor_overload =
        mixer.overload


    safety.thermal_safe =

        thermal.product_temperature_c <
        safety.maximum_temperature_c


    return (

        safety.lid_closed &&

        safety.vessel_locked &&

        safety.agitator_guard_closed &&

        safety.compressor_safe &&

        safety.thermal_safe &&

        !safety.motor_overload &&

        !safety.emergency_stop

    )

end


# ============================================================
# TELEMETRY
# ============================================================

struct TelemetryPoint

    timestamp::DateTime

    state::IceCreamState

    temperature_c::Float64

    hardness::Float64

    overrun_percent::Float64

    viscosity::Float64

    ice_fraction::Float64

    texture_score::Float64

    mixer_current_a::Float64

    compressor_current_a::Float64

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

struct BatchRecord

    batch_id::String

    started_at::DateTime

    recipe::String

    starting_mass_g::Float64

end


function new_batch(

    recipe::IceCreamRecipe,

    mass_g::Float64

)

    BatchRecord(

        "ICE-" *

        Dates.format(

            now(),

            "yyyymmdd-HHMMSS"

        ),

        now(),

        recipe.name,

        mass_g

    )

end


# ============================================================
# MACHINE
# ============================================================

mutable struct IceCreamMachine

    name::String

    state::IceCreamState

    recipe::IceCreamRecipe

    ingredients::IngredientSystem

    product::IceCreamProduct

    thermal::ThermalSystem

    mixer::MixerSystem

    freezer::FreezerSystem

    overrun::OverrunSystem

    safety::SafetySystem

    telemetry::Telemetry

    batch::Union{Nothing,BatchRecord}

    elapsed_s::Float64

    state_elapsed_s::Float64

end


function IceCreamMachine(

    name="ICECREAM-001",

    recipe=IceCreamRecipe()

)

    IceCreamMachine(

        name,

        IDLE,

        recipe,

        IngredientSystem(),

        IceCreamProduct(),

        ThermalSystem(),

        MixerSystem(),

        FreezerSystem(),

        OverrunSystem(),

        SafetySystem(),

        Telemetry(),

        nothing,

        0.0,

        0.0

    )

end


# ============================================================
# START BATCH
# ============================================================

function start_batch!(

    machine::IceCreamMachine

)

    machine.state == IDLE ||

        error(

            "Machine must be idle."

        )


    load_ingredients!(

        machine.ingredients

    )


    initialise_product!(

        machine.product,

        machine.ingredients

    )


    machine.batch =

        new_batch(

            machine.recipe,

            machine.product.mass_g

        )


    machine.state =
        DOSING


    machine.elapsed_s =
        0.0


    machine.state_elapsed_s =
        0.0

end


# ============================================================
# DOSING
# ============================================================

function dosing_step!(

    machine::IceCreamMachine,

    dt

)

    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >= 10.0

        machine.state =
            MIXING

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# MIXING
# ============================================================

function mixing_step!(

    machine::IceCreamMachine,

    dt

)

    set_mixer_speed!(

        machine.mixer,

        45.0

    )


    update_mixer!(

        machine.mixer,

        machine.product.viscosity

    )


    machine.product.viscosity +=

        0.0005 *
        dt


    machine.product.viscosity =

        clamp(

            machine.product.viscosity,

            0.0,
            1.0

        )


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >=

       machine.recipe.mixing_time_s

        machine.state =
            HEATING

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# HEATING
# ============================================================

function heating_step!(

    machine::IceCreamMachine,

    dt

)

    set_thermal_target!(

        machine.thermal,

        machine.recipe.heating_temperature_c

    )


    update_thermal!(

        machine.thermal,

        dt,

        machine.product.mass_g

    )


    machine.product.temperature_c =

        machine.thermal.product_temperature_c


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >=

       machine.recipe.heating_time_s &&

       machine.product.temperature_c >=

       machine.recipe.heating_temperature_c - 2.0

        machine.state =
            COOLING

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# COOLING
# ============================================================

function cooling_step!(

    machine::IceCreamMachine,

    dt

)

    set_thermal_target!(

        machine.thermal,

        machine.recipe.cooling_temperature_c

    )


    update_thermal!(

        machine.thermal,

        dt,

        machine.product.mass_g

    )


    machine.product.temperature_c =

        machine.thermal.product_temperature_c


    machine.state_elapsed_s += dt


    if machine.product.temperature_c <=

       machine.recipe.cooling_temperature_c + 0.5

        machine.state =
            AGEING

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# AGEING
# ============================================================

function ageing_step!(

    machine::IceCreamMachine,

    dt

)

    set_mixer_speed!(

        machine.mixer,

        15.0

    )


    update_mixer!(

        machine.mixer,

        machine.product.viscosity

    )


    machine.product.viscosity +=

        0.0002 *
        dt


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >=

       machine.recipe.ageing_time_s

        machine.state =
            FREEZING

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# FREEZING
# ============================================================

function freezing_step!(

    machine::IceCreamMachine,

    dt

)

    set_freezer_power!(

        machine.freezer,

        90.0

    )


    update_freezer!(

        machine.freezer,

        machine.product.temperature_c,

        dt

    )


    # Refrigeration effect.

    cooling_rate =

        0.0025 *
        machine.freezer.compressor_power_percent


    machine.product.temperature_c -=

        cooling_rate *
        dt


    machine.product.temperature_c =

        max(

            machine.product.temperature_c,

            -15.0

        )


    update_hardness!(

        machine.product,

        dt

    )


    machine.state_elapsed_s += dt


    if machine.product.temperature_c <=

       machine.recipe.freezing_temperature_c

        machine.state =
            OVERRUN_CONTROL

        machine.state_elapsed_s =
            0.0

    elseif machine.state_elapsed_s >=

           machine.recipe.maximum_freezing_time_s

        machine.state =
            OVERRUN_CONTROL

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# OVERRUN CONTROL
# ============================================================

function overrun_step!(

    machine::IceCreamMachine,

    dt

)

    update_overrun!(

        machine.overrun,

        machine.product,

        machine.recipe.target_overrun_percent,

        dt

    )


    update_hardness!(

        machine.product,

        dt

    )


    machine.state_elapsed_s += dt


    if abs(

        machine.product.overrun_percent -
        machine.recipe.target_overrun_percent

    ) <= 1.0

        machine.state =
            HARDNESS_CONTROL

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# HARDNESS CONTROL
# ============================================================

function hardness_step!(

    machine::IceCreamMachine,

    dt

)

    hardness_error =

        machine.recipe.target_hardness -
        machine.product.hardness


    if hardness_error > 0.03

        set_freezer_power!(

            machine.freezer,

            100.0

        )

    else

        set_freezer_power!(

            machine.freezer,

            35.0

        )

    end


    update_freezer!(

        machine.freezer,

        machine.product.temperature_c,

        dt

    )


    machine.product.temperature_c -=

        0.0015 *
        machine.freezer.compressor_power_percent *
        dt


    machine.product.temperature_c =

        max(

            machine.product.temperature_c,

            -18.0

        )


    update_hardness!(

        machine.product,

        dt

    )


    machine.state_elapsed_s += dt


    if abs(hardness_error) <= 0.03

        machine.state =
            FINISHING

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# FINISHING
# ============================================================

function finishing_step!(

    machine::IceCreamMachine,

    dt

)

    set_mixer_speed!(

        machine.mixer,

        20.0

    )


    update_mixer!(

        machine.mixer,

        machine.product.viscosity

    )


    update_hardness!(

        machine.product,

        dt

    )


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >= 60.0

        machine.state =
            DISPENSING

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# DISPENSING
# ============================================================

function dispensing_step!(

    machine::IceCreamMachine,

    dt

)

    set_mixer_speed!(

        machine.mixer,

        25.0

    )


    machine.state_elapsed_s += dt


    if machine.state_elapsed_s >= 15.0

        machine.state =
            COMPLETE

        machine.state_elapsed_s =
            0.0

    end

end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(

    machine::IceCreamMachine

)

    set_mixer_speed!(
        machine.mixer,
        0.0
    )

    set_freezer_power!(
        machine.freezer,
        0.0
    )


    machine.thermal.heater_enabled =
        false

    machine.thermal.refrigeration_enabled =
        false


    machine.thermal.heater_power_percent =
        0.0

    machine.thermal.cooling_power_percent =
        0.0


    machine.safety.emergency_stop =
        true


    machine.state =
        EMERGENCY_STOP

end


# ============================================================
# TELEMETRY
# ============================================================

function record_telemetry!(

    machine::IceCreamMachine

)

    push!(

        machine.telemetry.points,

        TelemetryPoint(

            now(),

            machine.state,

            machine.product.temperature_c,

            machine.product.hardness,

            machine.product.overrun_percent,

            machine.product.viscosity,

            machine.product.ice_fraction,

            machine.product.texture_score,

            machine.mixer.current_a,

            machine.freezer.compressor_current_a

        )

    )

end


# ============================================================
# MASTER CONTROL LOOP
# ============================================================

function control_step!(

    machine::IceCreamMachine,

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


    # ----------------------------
    # Safety interlock
    # ----------------------------

    if !check_safety!(

        machine.safety,

        machine.mixer,

        machine.thermal

    )

        emergency_stop!(
            machine
        )

        return

    end


    # ----------------------------
    # State machine
    # ----------------------------

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


    elseif machine.state == HEATING

        heating_step!(
            machine,
            dt
        )


    elseif machine.state == COOLING

        cooling_step!(
            machine,
            dt
        )


    elseif machine.state == AGEING

        ageing_step!(
            machine,
            dt
        )


    elseif machine.state == FREEZING

        freezing_step!(
            machine,
            dt
        )


    elseif machine.state == OVERRUN_CONTROL

        overrun_step!(
            machine,
            dt
        )


    elseif machine.state == HARDNESS_CONTROL

        hardness_step!(
            machine,
            dt
        )


    elseif machine.state == FINISHING

        finishing_step!(
            machine,
            dt
        )


    elseif machine.state == DISPENSING

        dispensing_step!(
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
# CLEANING
# ============================================================

function cleaning_cycle!(

    machine::IceCreamMachine

)

    machine.state in (

        IDLE,
        COMPLETE

    ) || error(

        "Machine must be stopped before cleaning."

    )


    machine.state =
        CLEANING


    println()
    println("ICECREAM.OS CLEANING CYCLE")
    println("----------------------------------------")

    println("STEP 1  : Product drain")

    println("STEP 2  : Warm-water flush")

    println("STEP 3  : Mixing chamber wash")

    println("STEP 4  : Scraper wash")

    println("STEP 5  : Refrigeration isolation")

    println("STEP 6  : Rinse")

    println("STEP 7  : Sanitation verification")

    println("STEP 8  : Drain")

    println("STEP 9  : Ready-state verification")

    println("----------------------------------------")


    machine.state =
        IDLE

end


# ============================================================
# STATUS
# ============================================================

function display_status!(

    machine::IceCreamMachine

)

    println(

        @sprintf(

            "%-20s | TEMP %7.2f°C | HARDNESS %5.1f%% | OVERRUN %6.1f%% | VISC %5.1f%% | ICE %5.1f%% | TEXTURE %5.1f%%",

            string(machine.state),

            machine.product.temperature_c,

            machine.product.hardness * 100,

            machine.product.overrun_percent,

            machine.product.viscosity * 100,

            machine.product.ice_fraction * 100,

            machine.product.texture_score * 100

        )

    )

end


# ============================================================
# BATCH REPORT
# ============================================================

function batch_report(

    machine::IceCreamMachine

)

    return (

        batch_id =
            machine.batch === nothing ?

            "NONE" :

            machine.batch.batch_id,

        recipe =
            machine.recipe.name,

        final_mass_g =
            machine.product.mass_g,

        temperature_c =
            machine.product.temperature_c,

        hardness =
            machine.product.hardness,

        overrun_percent =
            machine.product.overrun_percent,

        viscosity =
            machine.product.viscosity,

        ice_fraction =
            machine.product.ice_fraction,

        smoothness =
            machine.product.smoothness,

        texture_score =
            machine.product.texture_score,

        quality_score =
            quality_score(

                machine.product,

                machine.recipe

            ),

        compressor_current_a =
            machine.freezer.compressor_current_a,

        mixer_current_a =
            machine.mixer.current_a,

        processing_time_min =
            machine.elapsed_s / 60.0,

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

    "VANILLA" => IceCreamRecipe(

        name="VANILLA",

        target_mass_g=1000.0,

        heating_temperature_c=82.0,

        cooling_temperature_c=4.0,

        ageing_temperature_c=4.0,

        freezing_temperature_c=-8.0,

        target_overrun_percent=25.0,

        target_hardness=0.88

    ),


    "CHOCOLATE" => IceCreamRecipe(

        name="CHOCOLATE",

        target_mass_g=1000.0,

        heating_temperature_c=82.0,

        cooling_temperature_c=4.0,

        ageing_temperature_c=4.0,

        freezing_temperature_c=-9.0,

        target_overrun_percent=20.0,

        target_hardness=0.90

    ),


    "STRAWBERRY" => IceCreamRecipe(

        name="STRAWBERRY",

        target_mass_g=1000.0,

        heating_temperature_c=80.0,

        cooling_temperature_c=4.0,

        ageing_temperature_c=4.0,

        freezing_temperature_c=-8.0,

        target_overrun_percent=30.0,

        target_hardness=0.84

    )

)


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println()
    println("="^120)

    println(
        "                         ICECREAM.OS"
    )

    println(
        "              INTELLIGENT ICE-CREAM APPLIANCE"
    )

    println("="^120)


    recipe =
        RECIPES["VANILLA"]


    machine =

        IceCreamMachine(

            "ICECREAM-HOME-001",

            recipe

        )


    println()

    println(
        "RECIPE              : ",
        recipe.name
    )

    println(
        "TARGET OVERRUN      : ",
        recipe.target_overrun_percent,
        "%"
    )

    println(
        "TARGET HARDNESS     : ",
        recipe.target_hardness * 100,
        "%"
    )

    println()


    println(
        "STARTING BATCH..."
    )


    start_batch!(
        machine
    )


    println(
        "BATCH ID            : ",
        machine.batch.batch_id
    )


    println()

    println(
        "PROCESSING..."
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
        batch_report(machine)


    println()

    println("="^120)

    println(
        "                         ICE CREAM COMPLETE"
    )

    println("="^120)


    println(
        "Batch ID             : ",
        report.batch_id
    )

    println(
        "Final temperature    : ",
        round(
            report.temperature_c,
            digits=2
        ),
        " °C"
    )

    println(
        "Hardness             : ",
        round(
            report.hardness * 100,
            digits=1
        ),
        "%"
    )

    println(
        "Overrun              : ",
        round(
            report.overrun_percent,
            digits=1
        ),
        "%"
    )

    println(
        "Viscosity            : ",
        round(
            report.viscosity * 100,
            digits=1
        ),
        "%"
    )

    println(
        "Ice fraction         : ",
        round(
            report.ice_fraction * 100,
            digits=1
        ),
        "%"
    )

    println(
        "Smoothness           : ",
        round(
            report.smoothness * 100,
            digits=1
        ),
        "%"
    )

    println(
        "Texture score        : ",
        round(
            report.texture_score * 100,
            digits=1
        ),
        "%"
    )

    println(
        "QUALITY SCORE        : ",
        round(
            report.quality_score,
            digits=1
        ),
        " / 100"
    )

    println(
        "Processing time      : ",
        round(
            report.processing_time_min,
            digits=1
        ),
        " minutes"
    )

    println(
        "Telemetry points     : ",
        report.telemetry_points
    )

    println("="^120)

end


# ============================================================
# EXPORTS
# ============================================================

export IceCreamState
export IceCreamRecipe
export IceCreamMachine
export RECIPES

export IDLE
export DOSING
export MIXING
export HEATING
export COOLING
export AGEING
export FREEZING
export OVERRUN_CONTROL
export HARDNESS_CONTROL
export FINISHING
export DISPENSING
export COMPLETE
export CLEANING
export FAULT
export EMERGENCY_STOP

export start_batch!
export control_step!
export emergency_stop!
export cleaning_cycle!
export display_status!
export batch_report
export quality_score
export demo


end # module


# ============================================================
# APPLICATION ENTRY POINT
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .IceCreamOS

    IceCreamOS.demo()

end
```


