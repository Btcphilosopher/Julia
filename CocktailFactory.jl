module CocktailFactory

using Dates
using Printf
using Random

# ============================================================
# COCKTAIL FACTORY
# Industry 4.0 Automated Cocktail Mixing Platform
#
# Pure Julia
#
# Architecture:
#
#     RECIPE / ORDER
#           │
#           ▼
#     BATCH PLANNER
#           │
#     ├── INVENTORY
#     ├── DOSING
#     ├── MIXING
#     ├── QUALITY
#     └── CLEANING
#           │
#           ▼
#     MACHINE CONTROLLER
#           │
#     ├── PUMPS
#     ├── VALVES
#     ├── SENSORS
#     └── MIXER
#           │
#           ▼
#       FINISHED DRINK
#
# This is a digital-twin / simulation controller.
# It is not a certified food-processing controller.
# ============================================================


# ============================================================
# ENUMERATIONS
# ============================================================

@enum MachineState begin
    OFF
    IDLE
    READY
    DOSING
    MIXING
    DISPENSING
    CLEANING
    COMPLETE
    FAULT
    EMERGENCY_STOP
end

@enum IngredientType begin
    SPIRIT
    LIQUEUR
    SYRUP
    JUICE
    CARBONATED
    WATER
    GARNISH
    OTHER
end

@enum PumpState begin
    PUMP_OFF
    PUMP_RUNNING
    PUMP_FAULT
end


# ============================================================
# INGREDIENT
# ============================================================

mutable struct Ingredient

    id::Int

    name::String

    kind::IngredientType

    volume_ml::Float64

    density_g_ml::Float64

    temperature_C::Float64

    batch_lot::String

    expiry::Date

    enabled::Bool
end


function Ingredient(
    id::Int,
    name::String,
    kind::IngredientType,
    volume_ml::Float64;
    density_g_ml=1.0,
    temperature_C=5.0,
    batch_lot="UNKNOWN",
    expiry=today() + Day(30)
)

    Ingredient(
        id,
        name,
        kind,
        volume_ml,
        density_g_ml,
        temperature_C,
        batch_lot,
        expiry,
        true
    )
end


# ============================================================
# RECIPE COMPONENT
# ============================================================

struct RecipeComponent

    ingredient_id::Int

    volume_ml::Float64

    dosing_tolerance_ml::Float64

    sequence::Int
end


# ============================================================
# RECIPE
# ============================================================

struct CocktailRecipe

    id::Int

    name::String

    components::Vector{RecipeComponent}

    target_temperature_C::Float64

    mixing_time_s::Float64

    mixing_speed_rpm::Float64

    final_volume_ml::Float64
end


# ============================================================
# INVENTORY
# ============================================================

mutable struct Inventory

    ingredients::Dict{Int,Ingredient}
end


Inventory() =
    Inventory(
        Dict{Int,Ingredient}()
    )


function add_ingredient!(
    inventory::Inventory,
    ingredient::Ingredient
)

    inventory.ingredients[
        ingredient.id
    ] = ingredient

    return ingredient.id
end


function ingredient_available(
    inventory::Inventory,
    id::Int,
    volume_ml::Float64
)

    haskey(
        inventory.ingredients,
        id
    ) || return false

    ingredient =
        inventory.ingredients[id]

    ingredient.enabled &&
    ingredient.volume_ml >= volume_ml &&
    ingredient.expiry >= today()
end


function consume!(
    inventory::Inventory,
    id::Int,
    volume_ml::Float64
)

    ingredient =
        inventory.ingredients[id]

    ingredient.volume_ml -=
        volume_ml

    ingredient.volume_ml =
        max(
            ingredient.volume_ml,
            0.0
        )
end


# ============================================================
# PUMP
# ============================================================

mutable struct Pump

    id::Int

    ingredient_id::Int

    state::PumpState

    flow_rate_ml_s::Float64

    total_volume_ml::Float64

    runtime_s::Float64

    calibration_factor::Float64
end


function Pump(
    id::Int,
    ingredient_id::Int;
    flow_rate_ml_s=10.0,
    calibration_factor=1.0
)

    Pump(
        id,
        ingredient_id,
        PUMP_OFF,
        flow_rate_ml_s,
        0.0,
        0.0,
        calibration_factor
    )
end


# ============================================================
# VALVE
# ============================================================

mutable struct Valve

    id::Int

    open::Bool

    state::Symbol
end


Valve(id::Int) =
    Valve(
        id,
        false,
        :CLOSED
    )


function open!(
    valve::Valve
)

    valve.open = true
    valve.state = :OPEN
end


function close!(
    valve::Valve
)

    valve.open = false
    valve.state = :CLOSED
end


# ============================================================
# MIXER
# ============================================================

mutable struct Mixer

    rpm::Float64

    target_rpm::Float64

    running::Bool

    runtime_s::Float64

    temperature_C::Float64
end


Mixer() =
    Mixer(
        0.0,
        0.0,
        false,
        0.0,
        5.0
    )


# ============================================================
# QUALITY SENSOR
# ============================================================

mutable struct QualitySensor

    measured_volume_ml::Float64

    measured_temperature_C::Float64

    estimated_abv_percent::Float64

    turbidity::Float64

    quality_score::Float64
end


QualitySensor() =
    QualitySensor(
        0.0,
        5.0,
        0.0,
        0.0,
        100.0
    )


# ============================================================
# BATCH
# ============================================================

mutable struct Batch

    id::Int

    recipe_id::Int

    started::DateTime

    completed::Union{DateTime,Nothing}

    target_volume_ml::Float64

    actual_volume_ml::Float64

    target_temperature_C::Float64

    actual_temperature_C::Float64

    estimated_abv_percent::Float64

    status::Symbol

    errors::Vector{String}
end


# ============================================================
# EVENT LOG
# ============================================================

struct Event

    timestamp::DateTime

    event::Symbol

    message::String
end


mutable struct EventLog

    events::Vector{Event}
end


EventLog() =
    EventLog(
        Event[]
    )


function log_event!(
    log::EventLog,
    event::Symbol,
    message::String
)

    push!(
        log.events,
        Event(
            now(),
            event,
            message
        )
    )
end


# ============================================================
# FACTORY
# ============================================================

mutable struct CocktailFactory

    state::MachineState

    inventory::Inventory

    recipes::Dict{Int,CocktailRecipe}

    pumps::Dict{Int,Pump}

    valves::Dict{Int,Valve}

    mixer::Mixer

    quality::QualitySensor

    active_batch::Union{Batch,Nothing}

    next_batch_id::Int

    eventlog::EventLog

    emergency_stop::Bool
end


function CocktailFactory()

    CocktailFactory(
        OFF,
        Inventory(),
        Dict{Int,CocktailRecipe}(),
        Dict{Int,Pump}(),
        Dict{Int,Valve}(),
        Mixer(),
        QualitySensor(),
        nothing,
        1,
        EventLog(),
        false
    )
end


# ============================================================
# MACHINE CONTROL
# ============================================================

function power_on!(
    factory::CocktailFactory
)

    factory.emergency_stop &&
        return false

    factory.state =
        READY

    log_event!(
        factory.eventlog,
        :POWER_ON,
        "Cocktail factory powered on"
    )

    true
end


function power_off!(
    factory::CocktailFactory
)

    factory.state =
        OFF

    factory.mixer.running =
        false

    for pump in values(factory.pumps)

        pump.state =
            PUMP_OFF
    end

    log_event!(
        factory.eventlog,
        :POWER_OFF,
        "Cocktail factory powered off"
    )
end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(
    factory::CocktailFactory
)

    factory.emergency_stop =
        true

    factory.state =
        EMERGENCY_STOP

    factory.mixer.running =
        false

    factory.mixer.rpm =
        0.0

    for pump in values(factory.pumps)

        pump.state =
            PUMP_OFF
    end

    for valve in values(factory.valves)

        close!(valve)
    end

    log_event!(
        factory.eventlog,
        :EMERGENCY_STOP,
        "All machine outputs stopped"
    )
end


function reset_emergency!(
    factory::CocktailFactory
)

    factory.emergency_stop =
        false

    factory.state =
        READY

    log_event!(
        factory.eventlog,
        :ESTOP_RESET,
        "Emergency stop reset"
    )
end


# ============================================================
# RECIPE MANAGEMENT
# ============================================================

function add_recipe!(
    factory::CocktailFactory,
    recipe::CocktailRecipe
)

    factory.recipes[
        recipe.id
    ] = recipe

    log_event!(
        factory.eventlog,
        :RECIPE_ADDED,
        recipe.name
    )

    recipe.id
end


# ============================================================
# RECIPE VALIDATION
# ============================================================

function validate_recipe(
    factory::CocktailFactory,
    recipe::CocktailRecipe
)

    errors =
        String[]

    for component in
        recipe.components

        if !haskey(
            factory.inventory.ingredients,
            component.ingredient_id
        )

            push!(
                errors,
                "Missing ingredient ID $(component.ingredient_id)"
            )

            continue
        end

        if !ingredient_available(
            factory.inventory,
            component.ingredient_id,
            component.volume_ml
        )

            ingredient =
                factory.inventory.ingredients[
                    component.ingredient_id
                ]

            push!(
                errors,
                "Insufficient or expired ingredient: " *
                ingredient.name
            )
        end
    end

    return errors
end


# ============================================================
# BATCH CREATION
# ============================================================

function create_batch!(
    factory::CocktailFactory,
    recipe_id::Int
)

    haskey(
        factory.recipes,
        recipe_id
    ) ||
        error(
            "Recipe not found."
        )

    recipe =
        factory.recipes[
            recipe_id
        ]

    errors =
        validate_recipe(
            factory,
            recipe
        )

    if !isempty(errors)

        log_event!(
            factory.eventlog,
            :BATCH_REJECTED,
            join(errors, "; ")
        )

        return nothing
    end

    batch =
        Batch(
            factory.next_batch_id,
            recipe.id,
            now(),
            nothing,
            recipe.final_volume_ml,
            0.0,
            recipe.target_temperature_C,
            0.0,
            0.0,
            :CREATED,
            String[]
        )

    factory.next_batch_id += 1

    factory.active_batch =
        batch

    log_event!(
        factory.eventlog,
        :BATCH_CREATED,
        "Batch $(batch.id): $(recipe.name)"
    )

    batch
end


# ============================================================
# PUMP LOOKUP
# ============================================================

function pump_for_ingredient(
    factory::CocktailFactory,
    ingredient_id::Int
)

    for pump in values(factory.pumps)

        if pump.ingredient_id ==
           ingredient_id

            return pump
        end
    end

    return nothing
end


# ============================================================
# DOSING
# ============================================================

function dose_component!(
    factory::CocktailFactory,
    component::RecipeComponent
)

    factory.emergency_stop &&
        return false

    pump =
        pump_for_ingredient(
            factory,
            component.ingredient_id
        )

    pump === nothing &&
        error(
            "No pump assigned to ingredient."
        )

    ingredient =
        factory.inventory.ingredients[
            component.ingredient_id
        ]

    target =
        component.volume_ml

    calibrated_rate =
        pump.flow_rate_ml_s *
        pump.calibration_factor

    calibrated_rate > 0 ||
        error(
            "Invalid pump calibration."
        )

    duration =
        target /
        calibrated_rate

    factory.state =
        DOSING

    pump.state =
        PUMP_RUNNING

    # Simulated dosing

    delivered =
        calibrated_rate *
        duration

    delivered =
        min(
            delivered,
            ingredient.volume_ml
        )

    consume!(
        factory.inventory,
        component.ingredient_id,
        delivered
    )

    pump.total_volume_ml +=
        delivered

    pump.runtime_s +=
        duration

    pump.state =
        PUMP_OFF

    log_event!(
        factory.eventlog,
        :DOSE,
        @sprintf(
            "%s: %.2f ml",
            ingredient.name,
            delivered
        )
    )

    delivered
end


# ============================================================
# FULL DOSING SEQUENCE
# ============================================================

function dose_recipe!(
    factory::CocktailFactory,
    recipe::CocktailRecipe
)

    factory.active_batch === nothing &&
        error(
            "No active batch."
        )

    components =
        sort(
            recipe.components,
            by = x -> x.sequence
        )

    total =
        0.0

    for component in components

        delivered =
            dose_component!(
                factory,
                component
            )

        total +=
            delivered
    end

    factory.active_batch.actual_volume_ml =
        total

    total
end


# ============================================================
# ABV ESTIMATION
# ============================================================

function estimate_abv(
    factory::CocktailFactory,
    recipe::CocktailRecipe
)

    alcohol_volume =
        0.0

    total_volume =
        0.0

    for component in recipe.components

        ingredient =
            factory.inventory.ingredients[
                component.ingredient_id
            ]

        # Simplified classification.
        # A production system should use a certified
        # ingredient database containing actual ABV.

        abv =
            if ingredient.kind ==
               SPIRIT

                0.40

            elseif ingredient.kind ==
                   LIQUEUR

                0.20

            else

                0.0
            end

        alcohol_volume +=
            component.volume_ml *
            abv

        total_volume +=
            component.volume_ml
    end

    total_volume > 0 ?
        100.0 *
        alcohol_volume /
        total_volume :
        0.0
end


# ============================================================
# MIXER
# ============================================================

function start_mixer!(
    factory::CocktailFactory,
    rpm::Float64
)

    factory.emergency_stop &&
        return false

    factory.mixer.target_rpm =
        rpm

    factory.mixer.running =
        true

    factory.mixer.rpm =
        rpm

    factory.state =
        MIXING

    log_event!(
        factory.eventlog,
        :MIXER_START,
        @sprintf(
            "Mixer %.1f RPM",
            rpm
        )
    )

    true
end


function stop_mixer!(
    factory::CocktailFactory
)

    factory.mixer.running =
        false

    factory.mixer.rpm =
        0.0

    log_event!(
        factory.eventlog,
        :MIXER_STOP,
        "Mixer stopped"
    )
end


function mix!(
    factory::CocktailFactory,
    duration_s::Float64
)

    factory.mixer.running ||
        error(
            "Mixer is not running."
        )

    factory.mixer.runtime_s +=
        duration_s

    log_event!(
        factory.eventlog,
        :MIXING,
        @sprintf(
            "Mixed for %.2f seconds",
            duration_s
        )
    )

    stop_mixer!(
        factory
    )
end


# ============================================================
# TEMPERATURE MODEL
# ============================================================

function calculate_temperature(
    factory::CocktailFactory,
    recipe::CocktailRecipe
)

    total =
        0.0

    volume =
        0.0

    for component in recipe.components

        ingredient =
            factory.inventory.ingredients[
                component.ingredient_id
            ]

        total +=
            ingredient.temperature_C *
            component.volume_ml

        volume +=
            component.volume_ml
    end

    volume > 0 ?
        total / volume :
        0.0
end


# ============================================================
# QUALITY CHECK
# ============================================================

function quality_check!(
    factory::CocktailFactory,
    recipe::CocktailRecipe
)

    batch =
        factory.active_batch

    batch === nothing &&
        error(
            "No active batch."
        )

    factory.quality.measured_volume_ml =
        batch.actual_volume_ml

    factory.quality.measured_temperature_C =
        calculate_temperature(
            factory,
            recipe
        )

    factory.quality.estimated_abv_percent =
        estimate_abv(
            factory,
            recipe
        )

    volume_error =
        abs(
            batch.actual_volume_ml -
            recipe.final_volume_ml
        )

    temperature_error =
        abs(
            factory.quality.measured_temperature_C -
            recipe.target_temperature_C
        )

    volume_score =
        max(
            0.0,
            100.0 -
            volume_error * 5.0
        )

    temperature_score =
        max(
            0.0,
            100.0 -
            temperature_error * 5.0
        )

    factory.quality.quality_score =
        0.5 *
        volume_score +
        0.5 *
        temperature_score

    passed =
        factory.quality.quality_score >=
        90.0

    if passed

        batch.status =
            :QUALITY_PASSED

        log_event!(
            factory.eventlog,
            :QUALITY_PASS,
            @sprintf(
                "Quality %.1f/100",
                factory.quality.quality_score
            )
        )

    else

        batch.status =
            :QUALITY_FAILED

        push!(
            batch.errors,
            "Quality score below threshold"
        )

        log_event!(
            factory.eventlog,
            :QUALITY_FAIL,
            @sprintf(
                "Quality %.1f/100",
                factory.quality.quality_score
            )
        )
    end

    passed
end


# ============================================================
# DISPENSE
# ============================================================

function dispense!(
    factory::CocktailFactory
)

    batch =
        factory.active_batch

    batch === nothing &&
        error(
            "No active batch."
        )

    factory.state =
        DISPENSING

    log_event!(
        factory.eventlog,
        :DISPENSE,
        "Finished cocktail dispensed"
    )

    batch.status =
        :DISPENSED

    batch.completed =
        now()

    factory.state =
        COMPLETE

    true
end


# ============================================================
# CLEANING / CIP
# ============================================================

function clean!(
    factory::CocktailFactory;
    duration_s=30.0
)

    factory.state =
        CLEANING

    log_event!(
        factory.eventlog,
        :CLEANING_START,
        "Cleaning cycle started"
    )

    # Simulated cleaning cycle.

    sleep(
        min(
            duration_s,
            0.01
        )
    )

    log_event!(
        factory.eventlog,
        :CLEANING_COMPLETE,
        "Cleaning cycle completed"
    )

    factory.state =
        READY
end


# ============================================================
# COMPLETE COCKTAIL PRODUCTION
# ============================================================

function produce!(
    factory::CocktailFactory,
    recipe_id::Int
)

    factory.state ==
        READY ||
        error(
            "Factory is not ready."
        )

    recipe =
        factory.recipes[
            recipe_id
        ]

    batch =
        create_batch!(
            factory,
            recipe_id
        )

    batch === nothing &&
        return false

    batch.status =
        :DOSING

    dose_recipe!(
        factory,
        recipe
    )

    if factory.emergency_stop

        return false
    end

    batch.status =
        :MIXING

    start_mixer!(
        factory,
        recipe.mixing_speed_rpm
    )

    mix!(
        factory,
        recipe.mixing_time_s
    )

    batch.actual_temperature_C =
        calculate_temperature(
            factory,
            recipe
        )

    batch.estimated_abv_percent =
        estimate_abv(
            factory,
            recipe
        )

    quality_check!(
        factory,
        recipe
    ) ||
        return false

    dispense!(
        factory
    )

    true
end


# ============================================================
# FACTORY TELEMETRY
# ============================================================

function telemetry(
    factory::CocktailFactory
)

    batch =
        factory.active_batch

    return (
        timestamp = now(),

        machine_state =
            factory.state,

        mixer_rpm =
            factory.mixer.rpm,

        mixer_runtime_s =
            factory.mixer.runtime_s,

        batch_id =
            batch === nothing ?
            nothing :
            batch.id,

        batch_volume_ml =
            batch === nothing ?
            0.0 :
            batch.actual_volume_ml,

        estimated_abv =
            factory.quality.estimated_abv_percent,

        temperature_C =
            factory.quality.measured_temperature_C,

        quality_score =
            factory.quality.quality_score,

        emergency_stop =
            factory.emergency_stop
    )
end


# ============================================================
# STATUS DISPLAY
# ============================================================

function print_status(
    factory::CocktailFactory
)

    t =
        telemetry(factory)

    println()
    println(
        "="^60
    )

    println(
        "       COCKTAIL FACTORY — INDUSTRY 4.0"
    )

    println(
        "="^60
    )

    println(
        "Machine:          ",
        t.machine_state
    )

    println(
        "Batch:            ",
        t.batch_id
    )

    @printf(
        "Volume:           %.2f ml\n",
        t.batch_volume_ml
    )

    @printf(
        "Temperature:      %.2f °C\n",
        t.temperature_C
    )

    @printf(
        "Estimated ABV:    %.2f %%\n",
        t.estimated_abv
    )

    @printf(
        "Quality score:    %.1f / 100\n",
        t.quality_score
    )

    @printf(
        "Mixer RPM:        %.1f\n",
        t.mixer_rpm
    )

    println(
        "Emergency stop:   ",
        t.emergency_stop
    )

    println(
        "="^60
    )
end


# ============================================================
# EVENT REPORT
# ============================================================

function print_events(
    factory::CocktailFactory
)

    println()
    println(
        "EVENT LOG"
    )

    println(
        "-"^70
    )

    for event in
        factory.eventlog.events

        println(
            event.timestamp,
            " | ",
            event.event,
            " | ",
            event.message
        )
    end
end


# ============================================================
# DEMONSTRATION FACTORY
# ============================================================

function demo()

    factory =
        CocktailFactory()

    # --------------------------------------------------------
    # Ingredients
    # --------------------------------------------------------

    vodka =
        Ingredient(
            1,
            "Vodka",
            SPIRIT,
            2000.0;
            density_g_ml=0.95,
            temperature_C=5.0,
            batch_lot="VOD-2026-001"
        )

    lime =
        Ingredient(
            2,
            "Lime Juice",
            JUICE,
            2000.0;
            temperature_C=4.0,
            batch_lot="LIM-2026-001"
        )

    syrup =
        Ingredient(
            3,
            "Simple Syrup",
            SYRUP,
            1000.0;
            temperature_C=4.0,
            batch_lot="SYR-2026-001"
        )

    factory.inventory.ingredients[1] =
        vodka

    factory.inventory.ingredients[2] =
        lime

    factory.inventory.ingredients[3] =
        syrup

    # --------------------------------------------------------
    # Pumps
    # --------------------------------------------------------

    factory.pumps[1] =
        Pump(
            1,
            1;
            flow_rate_ml_s=20.0
        )

    factory.pumps[2] =
        Pump(
            2,
            2;
            flow_rate_ml_s=15.0
        )

    factory.pumps[3] =
        Pump(
            3,
            3;
            flow_rate_ml_s=10.0
        )

    # --------------------------------------------------------
    # Recipe
    # --------------------------------------------------------

    recipe =
        CocktailRecipe(
            1,
            "Automated Gimlet",
            [
                RecipeComponent(
                    1,
                    60.0,
                    1.0,
                    1
                ),

                RecipeComponent(
                    2,
                    30.0,
                    1.0,
                    2
                ),

                RecipeComponent(
                    3,
                    15.0,
                    1.0,
                    3
                )
            ],
            5.0,
            8.0,
            300.0,
            105.0
        )

    add_recipe!(
        factory,
        recipe
    )

    # --------------------------------------------------------
    # Start
    # --------------------------------------------------------

    power_on!(
        factory
    )

    # --------------------------------------------------------
    # Production
    # --------------------------------------------------------

    produce!(
        factory,
        1
    )

    # --------------------------------------------------------
    # Status
    # --------------------------------------------------------

    print_status(
        factory
    )

    print_events(
        factory
    )

    return factory
end


# ============================================================
# EXPORTS
# ============================================================

export CocktailFactory
export CocktailRecipe
export RecipeComponent
export Ingredient
export IngredientType
export Inventory
export Pump
export Valve
export Mixer
export QualitySensor
export Batch
export MachineState

export power_on!
export power_off!

export add_recipe!
export add_ingredient!

export create_batch!
export dose_component!
export dose_recipe!

export start_mixer!
export stop_mixer!
export mix!

export quality_check!
export dispense!
export clean!

export produce!

export emergency_stop!
export reset_emergency!

export telemetry
export print_status
export print_events

export demo

end # module


# ============================================================
# RUN DEMO
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .CocktailFactory

    CocktailFactory.demo()

end
