# COCKTAIL.OS — AI RECIPE GATEWAY

## Pure Julia

### AI → JSON → Validation → Recipe Compiler → Local Recipe Registry

```julia
module CocktailAI

using Dates
using SHA
using Printf


# ============================================================
# COCKTAIL.OS — AI RECIPE GATEWAY
# ============================================================
#
# PURPOSE
#
# Receive structured cocktail recipes from an AI service and
# convert them into validated machine-executable recipes.
#
# PIPELINE
#
#       AI SERVICE
#           │
#           ▼
#     RECIPE PAYLOAD
#           │
#           ▼
#     PARSER / NORMALISER
#           │
#           ▼
#     SCHEMA VALIDATOR
#           │
#           ▼
#     MACHINE SAFETY VALIDATOR
#           │
#           ▼
#     RECIPE COMPILER
#           │
#           ▼
#     LOCAL REGISTRY
#           │
#           ▼
#       COCKTAIL.OS
#
# IMPORTANT:
#
# The AI never directly controls pumps, heaters, valves or
# motors. It produces a declarative recipe. Julia validates
# that recipe and turns it into a constrained machine plan.
#
# ============================================================


# ============================================================
# RECIPE DATA MODEL
# ============================================================

struct AIIngredient

    name::String
    volume_ml::Float64

end


struct AIRecipe

    id::String
    name::String
    description::String

    ingredients::Vector{AIIngredient}

    dilution_ml::Float64
    ice_g::Float64

    mixing_mode::Symbol
    mixing_time_s::Float64

    serving_temperature_c::Float64

    servings::Int

    generated_at::DateTime
    source::String

end


# ============================================================
# COMPILED MACHINE RECIPE
# ============================================================

struct MachineIngredient

    cartridge::String
    volume_ml::Float64

end


struct MachineRecipe

    id::String
    name::String

    ingredients::Vector{MachineIngredient}

    dilution_ml::Float64
    ice_g::Float64

    mixing_mode::Symbol
    mixing_time_s::Float64

    serving_temperature_c::Float64

    total_volume_ml::Float64

    compiled_at::DateTime

end


# ============================================================
# RECIPE VALIDATION RESULT
# ============================================================

struct ValidationResult

    valid::Bool
    errors::Vector{String}
    warnings::Vector{String}

end


ValidationResult() =

    ValidationResult(

        true,
        String[],
        String[]

    )


# ============================================================
# AI PAYLOAD
# ============================================================
#
# In production, the AI endpoint should return structured
# JSON matching this schema.
#
# Example:
#
# {
#   "name": "Garden Martini",
#   "description": "...",
#   "ingredients": [
#       {"name": "VODKA", "volume_ml": 60},
#       {"name": "VERMOUTH", "volume_ml": 10}
#   ],
#   "dilution_ml": 5,
#   "ice_g": 120,
#   "mixing_mode": "STIR",
#   "mixing_time_s": 8,
#   "serving_temperature_c": 6,
#   "servings": 1
# }
#
# ============================================================


# ============================================================
# SIMPLE JSON-LIKE PARSER CONTRACT
# ============================================================
#
# To keep this module pure Julia and dependency-light, the
# network layer is deliberately separated from the recipe
# compiler.
#
# The function below expects a Dict produced by whatever
# transport/parser is used by the host application.
# ============================================================

function recipe_from_dict(

    payload::Dict

)

    required = [

        "name",
        "ingredients",
        "dilution_ml",
        "ice_g",
        "mixing_mode",
        "mixing_time_s",
        "serving_temperature_c",
        "servings"

    ]


    for field in required

        haskey(payload, field) ||

            error(

                "AI recipe missing field: $field"

            )

    end


    ingredients = AIIngredient[]


    for item in payload["ingredients"]

        push!(

            ingredients,

            AIIngredient(

                String(item["name"]),

                Float64(item["volume_ml"])

            )

        )

    end


    recipe_id =

        bytes2hex(

            sha256(

                string(

                    payload["name"],

                    now(),

                    rand()

                )

            )

        )[1:16]


    AIRecipe(

        recipe_id,

        String(payload["name"]),

        String(

            get(

                payload,

                "description",

                ""

            )

        ),

        ingredients,

        Float64(payload["dilution_ml"]),

        Float64(payload["ice_g"]),

        Symbol(

            uppercase(

                String(

                    payload["mixing_mode"]

                )

            )

        ),

        Float64(

            payload["mixing_time_s"]

        ),

        Float64(

            payload["serving_temperature_c"]

        ),

        Int(

            payload["servings"]

        ),

        now(),

        String(

            get(

                payload,

                "source",

                "AI"

            )

        )

    )

end


# ============================================================
# MACHINE LIMITS
# ============================================================

struct MachineLimits

    minimum_dose_ml::Float64
    maximum_dose_ml::Float64

    maximum_total_volume_ml::Float64

    maximum_ice_g::Float64

    minimum_temperature_c::Float64
    maximum_temperature_c::Float64

    maximum_mixing_time_s::Float64

    supported_mixing_modes::Set{Symbol}

    maximum_servings::Int

end


function MachineLimits()

    MachineLimits(

        0.5,
        250.0,

        750.0,

        1000.0,

        0.0,
        20.0,

        120.0,

        Set(

            [

                :STIR,
                :AGITATE,
                :SHAKE_SIMULATION

            ]

        ),

        4

    )

end


# ============================================================
# RECIPE VALIDATOR
# ============================================================

function validate_recipe(

    recipe::AIRecipe,

    limits::MachineLimits,

    available_cartridges::Set{String}

)

    errors = String[]

    warnings = String[]


    # --------------------------------------------------------
    # NAME
    # --------------------------------------------------------

    isempty(

        strip(recipe.name)

    ) && push!(

        errors,

        "Recipe has no name."

    )


    # --------------------------------------------------------
    # INGREDIENTS
    # --------------------------------------------------------

    isempty(recipe.ingredients) && push!(

        errors,

        "Recipe contains no ingredients."

    )


    total_volume = 0.0


    for ingredient in recipe.ingredients

        name =

            uppercase(

                strip(

                    ingredient.name

                )

            )


        if !haskey(

            Dict(

                c => true

                for c in available_cartridges

            ),

            name

        )

            push!(

                warnings,

                "Ingredient $name is not currently loaded."

            )

        end


        if ingredient.volume_ml <

           limits.minimum_dose_ml

            push!(

                errors,

                "$name dose is below machine minimum."

            )

        end


        if ingredient.volume_ml >

           limits.maximum_dose_ml

            push!(

                errors,

                "$name dose exceeds machine maximum."

            )

        end


        total_volume +=

            ingredient.volume_ml

    end


    # --------------------------------------------------------
    # TOTAL VOLUME
    # --------------------------------------------------------

    total_volume +=

        recipe.dilution_ml


    if total_volume >

       limits.maximum_total_volume_ml

        push!(

            errors,

            "Total recipe volume exceeds machine capacity."

        )

    end


    # --------------------------------------------------------
    # DILUTION
    # --------------------------------------------------------

    if recipe.dilution_ml < 0.0

        push!(

            errors,

            "Dilution cannot be negative."

        )

    end


    # --------------------------------------------------------
    # ICE
    # --------------------------------------------------------

    if recipe.ice_g < 0.0

        push!(

            errors,

            "Ice quantity cannot be negative."

        )

    elseif recipe.ice_g >

           limits.maximum_ice_g

        push!(

            errors,

            "Ice quantity exceeds machine capacity."

        )

    end


    # --------------------------------------------------------
    # TEMPERATURE
    # --------------------------------------------------------

    if recipe.serving_temperature_c <

       limits.minimum_temperature_c ||

       recipe.serving_temperature_c >

       limits.maximum_temperature_c

        push!(

            errors,

            "Serving temperature outside machine range."

        )

    end


    # --------------------------------------------------------
    # MIXING
    # --------------------------------------------------------

    if !(

        recipe.mixing_mode in

        limits.supported_mixing_modes

    )

        push!(

            errors,

            "Unsupported mixing mode."

        )

    end


    if recipe.mixing_time_s < 0.0 ||

       recipe.mixing_time_s >

       limits.maximum_mixing_time_s

        push!(

            errors,

            "Mixing time outside machine limits."

        )

    end


    # --------------------------------------------------------
    # SERVINGS
    # --------------------------------------------------------

    if recipe.servings < 1 ||

       recipe.servings >

       limits.maximum_servings

        push!(

            errors,

            "Invalid serving count."

        )

    end


    # --------------------------------------------------------
    # WARNINGS
    # --------------------------------------------------------

    if total_volume < 30.0

        push!(

            warnings,

            "Recipe volume is unusually small."

        )

    end


    ValidationResult(

        isempty(errors),

        errors,

        warnings

    )

end


# ============================================================
# CARTRIDGE MATCHING
# ============================================================

function normalise_name(

    name::String

)

    uppercase(

        replace(

            strip(name),

            "-" => "_",

            " " => "_"

        )

    )

end


function resolve_cartridge(

    requested::String,

    cartridges::Set{String}

)

    requested_normalised =

        normalise_name(requested)


    for cartridge in cartridges

        if normalise_name(cartridge) ==

           requested_normalised

            return cartridge

        end
    end


    return nothing

end


# ============================================================
# RECIPE COMPILER
# ============================================================

function compile_recipe(

    recipe::AIRecipe,

    available_cartridges::Set{String},

    limits::MachineLimits

)

    validation =

        validate_recipe(

            recipe,

            limits,

            available_cartridges

        )


    if !validation.valid

        error(

            "Recipe compilation failed:\n" *

            join(

                validation.errors,

                "\n"

            )

        )

    end


    machine_ingredients =

        MachineIngredient[]


    for ingredient in recipe.ingredients

        cartridge =

            resolve_cartridge(

                ingredient.name,

                available_cartridges

            )


        cartridge === nothing &&

            error(

                "Cartridge unavailable: " *

                ingredient.name

            )


        push!(

            machine_ingredients,

            MachineIngredient(

                cartridge,

                ingredient.volume_ml

            )

        )

    end


    total_volume =

        sum(

            x.volume_ml

            for x in machine_ingredients

        ) +

        recipe.dilution_ml


    MachineRecipe(

        recipe.id,

        recipe.name,

        machine_ingredients,

        recipe.dilution_ml,

        recipe.ice_g,

        recipe.mixing_mode,

        recipe.mixing_time_s,

        recipe.serving_temperature_c,

        total_volume,

        now()

    )

end


# ============================================================
# RECIPE REGISTRY
# ============================================================

mutable struct RecipeRegistry

    recipes::Dict{String,MachineRecipe}

end


RecipeRegistry() =

    RecipeRegistry(

        Dict{String,MachineRecipe}()

    )


function install_recipe!(

    registry::RecipeRegistry,

    recipe::MachineRecipe

)

    registry.recipes[recipe.id] =

        recipe

end


function remove_recipe!(

    registry::RecipeRegistry,

    recipe_id::String

)

    pop!(

        registry.recipes,

        recipe_id,

        nothing

    )

end


function get_recipe(

    registry::RecipeRegistry,

    recipe_id::String

)

    get(

        registry.recipes,

        recipe_id,

        nothing

    )

end


# ============================================================
# AI RECIPE RECEIVER
# ============================================================

mutable struct AIRecipeGateway

    limits::MachineLimits

    cartridges::Set{String}

    registry::RecipeRegistry

    received::Int
    accepted::Int
    rejected::Int

end


function AIRecipeGateway(

    cartridges::Vector{String}

)

    AIRecipeGateway(

        MachineLimits(),

        Set(

            uppercase.(cartridges)

        ),

        RecipeRegistry(),

        0,
        0,
        0

    )

end


# ============================================================
# RECEIVE RECIPE
# ============================================================

function receive_recipe!(

    gateway::AIRecipeGateway,

    payload::Dict

)

    gateway.received += 1


    try

        # ----------------------------------------------------
        # STEP 1 — PARSE
        # ----------------------------------------------------

        recipe =

            recipe_from_dict(

                payload

            )


        # ----------------------------------------------------
        # STEP 2 — VALIDATE
        # ----------------------------------------------------

        validation =

            validate_recipe(

                recipe,

                gateway.limits,

                gateway.cartridges

            )


        if !validation.valid

            gateway.rejected += 1


            return (

                accepted = false,

                recipe = nothing,

                errors = validation.errors,

                warnings = validation.warnings

            )

        end


        # ----------------------------------------------------
        # STEP 3 — COMPILE
        # ----------------------------------------------------

        compiled =

            compile_recipe(

                recipe,

                gateway.cartridges,

                gateway.limits

            )


        # ----------------------------------------------------
        # STEP 4 — INSTALL
        # ----------------------------------------------------

        install_recipe!(

            gateway.registry,

            compiled

        )


        gateway.accepted += 1


        (

            accepted = true,

            recipe = compiled,

            errors = String[],

            warnings = validation.warnings

        )


    catch error

        gateway.rejected += 1


        (

            accepted = false,

            recipe = nothing,

            errors = [

                sprint(showerror, error)

            ],

            warnings = String[]

        )

    end

end


# ============================================================
# AI PROMPT GENERATOR
# ============================================================
#
# This produces a strict instruction that can be sent to an
# external AI system.
#
# ============================================================

function recipe_generation_prompt(

    request::String,

    cartridges::Set{String}

)

    cartridge_list =

        join(

            sort(

                collect(cartridges)

            ),

            ", "

        )


    """

You are the recipe-generation engine for COCKTAIL.OS.

Create a machine-executable cocktail recipe for:

$request

AVAILABLE INGREDIENT CARTRIDGES:

$cartridge_list

Return ONLY structured recipe data.

Required fields:

name
description
ingredients
dilution_ml
ice_g
mixing_mode
mixing_time_s
serving_temperature_c
servings

Each ingredient must contain:

name
volume_ml

Do not invent unavailable ingredients.

Do not provide instructions for controlling pumps,
motors, valves, heaters or electrical hardware.

The receiving COCKTAIL.OS controller will independently
validate all physical machine constraints.

"""

end


# ============================================================
# RECIPE SEARCH
# ============================================================

function search_recipes(

    registry::RecipeRegistry,

    query::String

)

    q =

        lowercase(query)


    [

        recipe

        for recipe in

        values(registry.recipes)

        if occursin(

            q,

            lowercase(recipe.name)

        )

    ]

end


# ============================================================
# REGISTRY REPORT
# ============================================================

function registry_report(

    gateway::AIRecipeGateway

)

    println()

    println("="^78)

    println(

        "                     COCKTAIL.OS"

    )

    println(

        "                     AI RECIPE GATEWAY"

    )

    println("="^78)

    println()


    println(

        "RECEIVED        : ",

        gateway.received

    )


    println(

        "ACCEPTED        : ",

        gateway.accepted

    )


    println(

        "REJECTED        : ",

        gateway.rejected

    )


    println()


    println(

        "INSTALLED RECIPES"

    )


    println("-"^78)


    for recipe in

        values(gateway.registry.recipes)

        println(

            @sprintf(

                "%-30s %8.1f ml   %s",

                recipe.name,

                recipe.total_volume_ml,

                recipe.id

            )

        )

    end


    println()

    println("="^78)

end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    gateway =

        AIRecipeGateway(

            [

                "VODKA",

                "GIN",

                "VERMOUTH",

                "RUM",

                "WHISKY",

                "BITTERS",

                "LEMON_JUICE",

                "LIME_JUICE",

                "SIMPLE_SYRUP",

                "TONIC",

                "WATER"

            ]

        )


    println()

    println(

        recipe_generation_prompt(

            "a cold citrus gin cocktail",

            gateway.cartridges

        )

    )


    # --------------------------------------------------------
    # Simulated AI response
    # --------------------------------------------------------

    ai_response = Dict(

        "name" =>

            "AI Citrus Gin",

        "description" =>

            "A cold citrus-forward gin cocktail.",

        "ingredients" =>

            [

                Dict(

                    "name" => "GIN",

                    "volume_ml" => 50

                ),

                Dict(

                    "name" => "LEMON_JUICE",

                    "volume_ml" => 20

                ),

                Dict(

                    "name" => "SIMPLE_SYRUP",

                    "volume_ml" => 10

                )

            ],

        "dilution_ml" => 5,

        "ice_g" => 120,

        "mixing_mode" => "STIR",

        "mixing_time_s" => 8,

        "serving_temperature_c" => 6,

        "servings" => 1,

        "source" => "AI"

    )


    result =

        receive_recipe!(

            gateway,

            ai_response

        )


    println()

    println(

        "AI RECIPE RECEIVED"

    )


    println(

        "ACCEPTED: ",

        result.accepted

    )


    if !isempty(result.warnings)

        println()

        println("WARNINGS:")

        for warning in result.warnings

            println(

                "  ⚠ ",

                warning

            )

        end

    end


    if !isempty(result.errors)

        println()

        println("ERRORS:")

        for error in result.errors

            println(

                "  ✗ ",

                error

            )

        end

    end


    registry_report(

        gateway

    )

end


# ============================================================
# EXPORTS
# ============================================================

export AIIngredient
export AIRecipe
export MachineRecipe

export MachineLimits
export ValidationResult

export RecipeRegistry
export AIRecipeGateway

export recipe_from_dict
export validate_recipe
export compile_recipe

export receive_recipe!
export install_recipe!
export remove_recipe!
export get_recipe

export search_recipes
export recipe_generation_prompt

export registry_report
export demo


end


# ============================================================
# APPLICATION ENTRY
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .CocktailAI

    CocktailAI.demo()

end
```

