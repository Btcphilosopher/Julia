# COCKTAIL.OS

## Intelligent Home Cocktail-Maker Control System

### Pure Julia — Dosing, Mixing, Chilling, Recipes & Safety

```julia
module CocktailOS

using Dates
using Printf
using Statistics


# ============================================================
# COCKTAIL.OS
# ============================================================
#
# HOME AUTOMATED COCKTAIL-MAKER CONTROL PLATFORM
#
# FEATURES
#
#   • Multi-cartridge ingredient system
#   • Precision liquid dosing
#   • Pump calibration
#   • Recipe engine
#   • Water / dilution control
#   • Ice / chilling control
#   • Mixing control
#   • Pour sequencing
#   • Inventory tracking
#   • Cleaning / purge cycle
#   • Leak detection
#   • Pump fault detection
#   • Temperature monitoring
#   • Digital telemetry
#   • Recipe scaling
#
# This is a digital-twin/control-system reference architecture.
#
# ============================================================


# ============================================================
# STATES
# ============================================================

@enum MachineState begin
    OFF
    BOOT
    READY
    DISPENSING
    MIXING
    CHILLING
    POURING
    CLEANING
    PAUSED
    FAULT
    EMERGENCY_STOP
end


@enum PumpState begin
    PUMP_OFF
    PUMP_RUNNING
    PUMP_FAULT
end


@enum MixingMode begin
    STIR
    SHAKE_SIMULATION
    AGITATE
end


# ============================================================
# INGREDIENT CARTRIDGE
# ============================================================

mutable struct Ingredient

    name::String

    capacity_ml::Float64
    remaining_ml::Float64

    density_g_ml::Float64

    pump_flow_ml_s::Float64

    temperature_c::Float64

    enabled::Bool

end


function Ingredient(

    name::String,
    capacity_ml::Float64;

    flow_ml_s=20.0,
    density=1.0,
    temperature_c=20.0

)

    Ingredient(

        name,
        capacity_ml,
        capacity_ml,
        density,
        flow_ml_s,
        temperature_c,
        true

    )

end


# ============================================================
# PUMP
# ============================================================

mutable struct Pump

    id::Int

    state::PumpState

    commanded_flow_ml_s::Float64

    actual_flow_ml_s::Float64

    total_volume_ml::Float64

    calibration_factor::Float64

end


function Pump(id::Int)

    Pump(

        id,

        PUMP_OFF,

        0.0,

        0.0,

        0.0,

        1.0

    )

end


function start_pump!(

    pump::Pump,

    flow_ml_s::Float64

)

    pump.commanded_flow_ml_s =

        max(flow_ml_s, 0.0)


    pump.actual_flow_ml_s =

        pump.commanded_flow_ml_s *

        pump.calibration_factor


    pump.state =

        PUMP_RUNNING

end


function stop_pump!(

    pump::Pump

)

    pump.commanded_flow_ml_s = 0.0

    pump.actual_flow_ml_s = 0.0

    pump.state = PUMP_OFF

end


# ============================================================
# INGREDIENT SYSTEM
# ============================================================

mutable struct IngredientSystem

    ingredients::Dict{String,Ingredient}

    pumps::Dict{String,Pump}

end


function IngredientSystem()

    IngredientSystem(

        Dict{String,Ingredient}(),

        Dict{String,Pump}()

    )

end


function add_ingredient!(

    system::IngredientSystem,

    ingredient::Ingredient

)

    system.ingredients[ingredient.name] =

        ingredient


    system.pumps[ingredient.name] =

        Pump(

            length(system.pumps) + 1

        )

end


# ============================================================
# RECIPE COMPONENT
# ============================================================

struct RecipeComponent

    ingredient::String

    volume_ml::Float64

end


# ============================================================
# RECIPE
# ============================================================

struct Recipe

    name::String

    components::Vector{RecipeComponent}

    dilution_ml::Float64

    ice_mass_g::Float64

    mixing_time_s::Float64

    mixing_mode::MixingMode

    serving_temperature_c::Float64

end


# ============================================================
# RECIPE SCALING
# ============================================================

function scale_recipe(

    recipe::Recipe,

    multiplier::Float64

)

    components =

        [

            RecipeComponent(

                component.ingredient,

                component.volume_ml *

                multiplier

            )

            for component in recipe.components

        ]


    Recipe(

        recipe.name,

        components,

        recipe.dilution_ml * multiplier,

        recipe.ice_mass_g * multiplier,

        recipe.mixing_time_s,

        recipe.mixing_mode,

        recipe.serving_temperature_c

    )

end


# ============================================================
# ICE SYSTEM
# ============================================================

mutable struct IceSystem

    available_g::Float64

    target_g::Float64

    dispensed_g::Float64

    enabled::Bool

end


IceSystem(

    available_g=5000.0

) =

    IceSystem(

        available_g,

        0.0,

        0.0,

        true

    )


function dispense_ice!(

    ice::IceSystem,

    mass_g::Float64

)

    quantity =

        min(

            mass_g,

            ice.available_g

        )


    ice.available_g -= quantity

    ice.dispensed_g += quantity

    ice.target_g = mass_g


    return quantity

end


# ============================================================
# CHILLING SYSTEM
# ============================================================

mutable struct Chiller

    temperature_c::Float64

    target_temperature_c::Float64

    power_percent::Float64

    cooling_rate_c_s::Float64

end


Chiller() =

    Chiller(

        20.0,

        5.0,

        0.0,

        0.10

    )


function update_chiller!(

    chiller::Chiller,

    dt::Float64

)

    if chiller.temperature_c >

       chiller.target_temperature_c

        chiller.power_percent =

            clamp(

                (

                    chiller.temperature_c -

                    chiller.target_temperature_c

                ) * 20.0,

                0.0,

                100.0

            )


        chiller.temperature_c -=

            chiller.cooling_rate_c_s *

            (

                chiller.power_percent /
                100.0

            ) *

            dt

    else

        chiller.power_percent = 0.0
    end

end


# ============================================================
# MIXING MOTOR
# ============================================================

mutable struct Mixer

    mode::MixingMode

    target_rpm::Float64

    actual_rpm::Float64

    torque_percent::Float64

end


Mixer() =

    Mixer(

        STIR,

        0.0,

        0.0,

        0.0

    )


function start_mixer!(

    mixer::Mixer,

    mode::MixingMode,

    rpm::Float64

)

    mixer.mode = mode

    mixer.target_rpm =

        max(rpm, 0.0)

end


function stop_mixer!(

    mixer::Mixer

)

    mixer.target_rpm = 0.0

end


function update_mixer!(

    mixer::Mixer,

    dt::Float64

)

    mixer.actual_rpm +=

        (

            mixer.target_rpm -
            mixer.actual_rpm

        ) *

        min(

            dt * 8.0,

            1.0

        )


    mixer.torque_percent =

        clamp(

            (

                mixer.actual_rpm /
                max(mixer.target_rpm, 1.0)

            ) * 40.0,

            0.0,

            100.0

        )

end


# ============================================================
# LIQUID RESERVOIR
# ============================================================

mutable struct DrinkBatch

    volume_ml::Float64

    temperature_c::Float64

    ingredient_volumes::Dict{String,Float64}

    ice_mass_g::Float64

    mixed::Bool

end


DrinkBatch() =

    DrinkBatch(

        0.0,

        20.0,

        Dict{String,Float64}(),

        0.0,

        false

    )


# ============================================================
# DISPENSING ENGINE
# ============================================================

mutable struct DosingOperation

    active::Bool

    ingredient::String

    target_ml::Float64

    delivered_ml::Float64

end


DosingOperation() =

    DosingOperation(

        false,

        "",

        0.0,

        0.0

    )


function begin_dosing!(

    operation::DosingOperation,

    ingredient::String,

    target_ml::Float64

)

    operation.active = true

    operation.ingredient = ingredient

    operation.target_ml = target_ml

    operation.delivered_ml = 0.0

end


function dose_step!(

    operation::DosingOperation,

    ingredient::Ingredient,

    pump::Pump,

    batch::DrinkBatch,

    dt::Float64

)

    if !operation.active

        return true
    end


    remaining =

        operation.target_ml -

        operation.delivered_ml


    if remaining <= 0.0

        operation.active = false

        stop_pump!(pump)

        return true

    end


    start_pump!(

        pump,

        ingredient.pump_flow_ml_s

    )


    delivered =

        min(

            pump.actual_flow_ml_s * dt,

            remaining,

            ingredient.remaining_ml

        )


    ingredient.remaining_ml -= delivered

    operation.delivered_ml += delivered

    pump.total_volume_ml += delivered


    batch.volume_ml += delivered


    batch.ingredient_volumes[

        ingredient.name

    ] =

        get(

            batch.ingredient_volumes,

            ingredient.name,

            0.0

        ) + delivered


    if ingredient.remaining_ml <= 0.0

        ingredient.enabled = false

    end


    return false

end


# ============================================================
# DILUTION
# ============================================================

function add_dilution!(

    batch::DrinkBatch,

    water_ml::Float64

)

    batch.volume_ml +=

        max(water_ml, 0.0)


    batch.ingredient_volumes["WATER"] =

        get(

            batch.ingredient_volumes,

            "WATER",

            0.0

        ) + water_ml

end


# ============================================================
# LEAK SENSOR
# ============================================================

mutable struct LeakSensor

    detected::Bool
    liquid_detected_ml::Float64

end


LeakSensor() =

    LeakSensor(

        false,

        0.0

    )


function update_leak!(

    sensor::LeakSensor,

    measured_ml::Float64

)

    sensor.liquid_detected_ml =

        measured_ml


    sensor.detected =

        measured_ml > 1.0

end


# ============================================================
# SAFETY
# ============================================================

mutable struct SafetySystem

    leak_fault::Bool
    pump_fault::Bool
    temperature_fault::Bool

    emergency_stop::Bool

    maximum_temperature_c::Float64

    message::String

end


SafetySystem() =

    SafetySystem(

        false,
        false,
        false,

        false,

        45.0,

        ""

    )


function safety_check!(

    safety::SafetySystem,

    leak::LeakSensor,

    ingredients::IngredientSystem,

    chiller::Chiller

)

    safety.leak_fault =

        leak.detected


    safety.temperature_fault =

        chiller.temperature_c >

        safety.maximum_temperature_c


    safety.pump_fault =

        any(

            pump.state == PUMP_FAULT

            for pump in

            values(ingredients.pumps)

        )


    if safety.emergency_stop

        safety.message =

            "EMERGENCY STOP"

        return false

    elseif safety.leak_fault

        safety.message =

            "LIQUID LEAK DETECTED"

        return false

    elseif safety.pump_fault

        safety.message =

            "PUMP FAULT"

        return false

    elseif safety.temperature_fault

        safety.message =

            "TEMPERATURE FAULT"

        return false

    end


    safety.message = ""

    return true

end


# ============================================================
# CLEANING
# ============================================================

mutable struct CleaningSystem

    active::Bool
    progress::Float64
    purge_volume_ml::Float64

end


CleaningSystem() =

    CleaningSystem(

        false,
        0.0,
        250.0

    )


function start_cleaning!(

    cleaning::CleaningSystem

)

    cleaning.active = true

    cleaning.progress = 0.0

end


function update_cleaning!(

    cleaning::CleaningSystem,

    dt::Float64

)

    if !cleaning.active

        return
    end


    cleaning.progress +=

        dt / 30.0


    if cleaning.progress >= 1.0

        cleaning.progress = 1.0

        cleaning.active = false

    end

end


# ============================================================
# TELEMETRY
# ============================================================

struct TelemetryPoint

    timestamp::DateTime

    state::MachineState

    volume_ml::Float64

    drink_temperature_c::Float64

    chiller_temperature_c::Float64

    mixer_rpm::Float64

    mixer_torque_percent::Float64

    ice_g::Float64

end


mutable struct Telemetry

    points::Vector{TelemetryPoint}

end


Telemetry() =

    Telemetry(

        TelemetryPoint[]

    )


# ============================================================
# COCKTAIL MACHINE
# ============================================================

mutable struct CocktailMachine

    name::String

    state::MachineState

    ingredients::IngredientSystem

    ice::IceSystem

    chiller::Chiller

    mixer::Mixer

    batch::DrinkBatch

    dosing::DosingOperation

    leak::LeakSensor

    safety::SafetySystem

    cleaning::CleaningSystem

    telemetry::Telemetry

    current_recipe::Union{Recipe,Nothing}

    recipe_index::Int

    elapsed_s::Float64

    mixing_elapsed_s::Float64

end


function CocktailMachine(

    name="COCKTAIL.OS-001"

)

    CocktailMachine(

        name,

        OFF,

        IngredientSystem(),

        IceSystem(),

        Chiller(),

        Mixer(),

        DrinkBatch(),

        DosingOperation(),

        LeakSensor(),

        SafetySystem(),

        CleaningSystem(),

        Telemetry(),

        nothing,

        1,

        0.0,

        0.0

    )

end


# ============================================================
# POWER
# ============================================================

function power_on!(

    machine::CocktailMachine

)

    machine.state = BOOT

    machine.elapsed_s = 0.0

    machine.state = READY

end


# ============================================================
# LOAD RECIPE
# ============================================================

function load_recipe!(

    machine::CocktailMachine,

    recipe::Recipe

)

    machine.current_recipe =

        recipe


    machine.recipe_index = 1

    machine.batch =

        DrinkBatch()

    machine.mixing_elapsed_s = 0.0

end


# ============================================================
# START RECIPE
# ============================================================

function start_recipe!(

    machine::CocktailMachine

)

    recipe =

        machine.current_recipe


    recipe === nothing &&

        error(

            "No recipe loaded."

        )


    machine.state =

        DISPENSING


    machine.recipe_index = 1

    machine.batch =

        DrinkBatch()

end


# ============================================================
# DISPENSE CURRENT INGREDIENT
# ============================================================

function process_dosing!(

    machine::CocktailMachine,

    dt::Float64

)

    recipe =

        machine.current_recipe


    recipe === nothing &&

        return


    # All ingredients completed.

    if machine.recipe_index >

       length(recipe.components)

        add_dilution!(

            machine.batch,

            recipe.dilution_ml

        )


        machine.batch.ice_mass_g =

            dispense_ice!(

                machine.ice,

                recipe.ice_mass_g

            )


        machine.chiller.target_temperature_c =

            recipe.serving_temperature_c


        machine.state =

            CHILLING


        return

    end


    component =

        recipe.components[

            machine.recipe_index

        ]


    ingredient =

        get(

            machine.ingredients.ingredients,

            component.ingredient,

            nothing

        )


    ingredient === nothing &&

        error(

            "Missing ingredient: " *

            component.ingredient

        )


    if !machine.dosing.active

        begin_dosing!(

            machine.dosing,

            component.ingredient,

            component.volume_ml

        )

    end


    finished =

        dose_step!(

            machine.dosing,

            ingredient,

            machine.ingredients.pumps[

                component.ingredient

            ],

            machine.batch,

            dt

        )


    if finished

        machine.recipe_index += 1
    end

end


# ============================================================
# MIXING
# ============================================================

function begin_mixing!(

    machine::CocktailMachine

)

    recipe =

        machine.current_recipe


    recipe === nothing &&

        return


    machine.state =

        MIXING


    machine.mixing_elapsed_s = 0.0


    start_mixer!(

        machine.mixer,

        recipe.mixing_mode,

        recipe.mixing_mode == STIR ?

        120.0 :

        300.0

    )

end


function update_mixing!(

    machine::CocktailMachine,

    dt::Float64

)

    recipe =

        machine.current_recipe


    recipe === nothing &&

        return


    machine.mixing_elapsed_s += dt


    if machine.mixing_elapsed_s >=

       recipe.mixing_time_s

        stop_mixer!(

            machine.mixer

        )

        machine.batch.mixed = true

        machine.state = POURING

    end

end


# ============================================================
# POUR
# ============================================================

function pour!(

    machine::CocktailMachine

)

    machine.state =

        POURING

end


function complete_pour!(

    machine::CocktailMachine

)

    machine.state =

        READY

end


# ============================================================
# CONTROL LOOP
# ============================================================

function control_step!(

    machine::CocktailMachine,

    dt::Float64=0.01

)

    machine.elapsed_s += dt


    # --------------------------------------------------------
    # SAFETY
    # --------------------------------------------------------

    if !safety_check!(

        machine.safety,

        machine.leak,

        machine.ingredients,

        machine.chiller

    )

        machine.state =

            FAULT


        for pump in

            values(machine.ingredients.pumps)

            stop_pump!(pump)

        end


        stop_mixer!(

            machine.mixer

        )


        return

    end


    # --------------------------------------------------------
    # CHILLER
    # --------------------------------------------------------

    update_chiller!(

        machine.chiller,

        dt

    )


    # --------------------------------------------------------
    # MIXER
    # --------------------------------------------------------

    update_mixer!(

        machine.mixer,

        dt

    )


    # --------------------------------------------------------
    # RECIPE ENGINE
    # --------------------------------------------------------

    if machine.state == DISPENSING

        process_dosing!(

            machine,

            dt

        )

    elseif machine.state == CHILLING

        if machine.chiller.temperature_c <=

           machine.chiller.target_temperature_c +

           0.5

            begin_mixing!(

                machine

            )

        end

    elseif machine.state == MIXING

        update_mixing!(

            machine,

            dt

        )

    elseif machine.state == POURING

        # Simulate automatic pour completion.

        if machine.mixer.actual_rpm < 1.0

            complete_pour!(

                machine

            )

        end

    elseif machine.state == CLEANING

        update_cleaning!(

            machine.cleaning,

            dt

        )


        if !machine.cleaning.active

            machine.state =

                READY

        end

    end


    # --------------------------------------------------------
    # TELEMETRY
    # --------------------------------------------------------

    push!(

        machine.telemetry.points,

        TelemetryPoint(

            now(),

            machine.state,

            machine.batch.volume_ml,

            machine.batch.temperature_c,

            machine.chiller.temperature_c,

            machine.mixer.actual_rpm,

            machine.mixer.torque_percent,

            machine.batch.ice_mass_g

        )

    )

end


# ============================================================
# CLEANING
# ============================================================

function clean!(

    machine::CocktailMachine

)

    machine.state = CLEANING

    start_cleaning!(

        machine.cleaning

    )

end


# ============================================================
# INVENTORY
# ============================================================

function inventory(

    machine::CocktailMachine

)

    println()

    println("="^70)

    println(

        "                  INGREDIENT INVENTORY"

    )

    println("="^70)


    for (

        name,

        ingredient

    ) in machine.ingredients.ingredients

        percentage =

            100.0 *

            ingredient.remaining_ml /

            ingredient.capacity_ml


        println(

            @sprintf(

                "%-25s %8.1f ml  %6.1f %%",

                name,

                ingredient.remaining_ml,

                percentage

            )

        )

    end


    println()

    println(

        @sprintf(

            "ICE                       %8.1f g",

            machine.ice.available_g

        )

    )


    println("="^70)

end


# ============================================================
# DASHBOARD
# ============================================================

function dashboard(

    machine::CocktailMachine

)

    println()

    println("="^82)

    println(

        "                         COCKTAIL.OS"

    )

    println(

        "             INTELLIGENT HOME COCKTAIL SYSTEM"

    )

    println("="^82)

    println()


    println(

        "DEVICE          : ",

        machine.name

    )


    println(

        "STATE           : ",

        machine.state

    )


    if machine.current_recipe !== nothing

        println(

            "RECIPE          : ",

            machine.current_recipe.name

        )

    end


    println()


    println(

        @sprintf(

            "DRINK VOLUME    : %8.1f ml",

            machine.batch.volume_ml

        )

    )


    println(

        @sprintf(

            "DRINK TEMP      : %8.2f °C",

            machine.batch.temperature_c

        )

    )


    println(

        @sprintf(

            "CHILLER TEMP    : %8.2f °C",

            machine.chiller.temperature_c

        )

    )


    println()


    println(

        @sprintf(

            "MIXER RPM       : %8.1f",

            machine.mixer.actual_rpm

        )

    )


    println(

        @sprintf(

            "MIXER TORQUE    : %8.1f %%",

            machine.mixer.torque_percent

        )

    )


    println()


    println(

        @sprintf(

            "ICE USED        : %8.1f g",

            machine.batch.ice_mass_g

        )

    )


    println(

        "MIXED           : ",

        machine.batch.mixed

    )


    println()


    println(

        "SAFETY          : ",

        machine.safety.message == "" ?

        "OK" :

        machine.safety.message

    )


    println()

    println("="^82)

end


# ============================================================
# SIMULATION
# ============================================================

function simulate()

    machine =

        CocktailMachine(

            "COCKTAILOS-LAB-001"

        )


    # --------------------------------------------------------
    # INGREDIENT CARTRIDGES
    # --------------------------------------------------------

    add_ingredient!(

        machine.ingredients,

        Ingredient(

            "VODKA",

            1000.0;

            flow_ml_s=25.0

        )

    )


    add_ingredient!(

        machine.ingredients,

        Ingredient(

            "VERMOUTH",

            500.0;

            flow_ml_s=20.0

        )

    )


    add_ingredient!(

        machine.ingredients,

        Ingredient(

            "BITTERS",

            100.0;

            flow_ml_s=5.0

        )

    )


    # --------------------------------------------------------
    # RECIPE
    # --------------------------------------------------------

    martini =

        Recipe(

            "AUTOMATED MARTINI",

            [

                RecipeComponent(

                    "VODKA",

                    60.0

                ),

                RecipeComponent(

                    "VERMOUTH",

                    10.0

                ),

                RecipeComponent(

                    "BITTERS",

                    2.0

                )

            ],

            5.0,

            120.0,

            8.0,

            STIR,

            6.0

        )


    # --------------------------------------------------------
    # START
    # --------------------------------------------------------

    println()

    println(

        "BOOTING COCKTAIL.OS..."

    )


    power_on!(

        machine

    )


    load_recipe!(

        machine,

        martini

    )


    start_recipe!(

        machine

    )


    # --------------------------------------------------------
    # RUN DIGITAL TWIN
    # --------------------------------------------------------

    for tick in 1:20000

        control_step!(

            machine,

            0.01

        )


        if tick % 2000 == 0

            dashboard(

                machine

            )

        end


        if machine.state == READY &&

           tick > 1000

            break

        end

    end


    dashboard(

        machine

    )


    inventory(

        machine

    )


    println()

    println(

        "COCKTAIL.OS CYCLE COMPLETE."

    )

end


# ============================================================
# EXPORTS
# ============================================================

export CocktailMachine
export Ingredient
export Recipe
export RecipeComponent

export HeatProfile
export MixingMode

export add_ingredient!
export load_recipe!
export start_recipe!
export control_step!
export clean!

export dashboard
export inventory
export simulate


end


# ============================================================
# APPLICATION ENTRY
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .CocktailOS

    CocktailOS.simulate()

end
```

