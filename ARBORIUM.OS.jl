ARBORIUM.OS


# ARBORIUM.OS

## Fertiliser + Tree Growth Analytics Engine

### Pure Julia

```julia
module Arborium

using Dates
using Statistics
using Random
using Printf


# ============================================================
# UNITS
# ============================================================

struct Nutrients

    nitrogen::Float64
    phosphorus::Float64
    potassium::Float64

end


Nutrients() =
    Nutrients(
        0.0,
        0.0,
        0.0
    )


Base.:+(
    a::Nutrients,
    b::Nutrients
) =
    Nutrients(
        a.nitrogen + b.nitrogen,
        a.phosphorus + b.phosphorus,
        a.potassium + b.potassium
    )


Base.:-( 
    a::Nutrients,
    b::Nutrients
) =
    Nutrients(
        a.nitrogen - b.nitrogen,
        a.phosphorus - b.phosphorus,
        a.potassium - b.potassium
    )


Base.:*(
    x::Real,
    n::Nutrients
) =
    Nutrients(
        x * n.nitrogen,
        x * n.phosphorus,
        x * n.potassium
    )


# ============================================================
# SOIL
# ============================================================

mutable struct Soil

    nitrogen::Float64

    phosphorus::Float64

    potassium::Float64

    water::Float64

    ph::Float64

    organic_matter::Float64

end


function Soil(;

    nitrogen=50.0,

    phosphorus=25.0,

    potassium=50.0,

    water=0.30,

    ph=6.5,

    organic_matter=3.0

)

    Soil(

        Float64(nitrogen),

        Float64(phosphorus),

        Float64(potassium),

        Float64(water),

        Float64(ph),

        Float64(organic_matter)

    )

end


# ============================================================
# TREE
# ============================================================

mutable struct Tree

    id::String

    species::String

    age_years::Float64

    height_m::Float64

    diameter_cm::Float64

    canopy_m2::Float64

    biomass_kg::Float64

    health::Float64

end


function Tree(

    id::String,

    species::String;

    age_years=1.0,

    height_m=1.0,

    diameter_cm=2.0,

    canopy_m2=1.0,

    biomass_kg=2.0,

    health=1.0

)

    Tree(

        id,

        species,

        Float64(age_years),

        Float64(height_m),

        Float64(diameter_cm),

        Float64(canopy_m2),

        Float64(biomass_kg),

        Float64(health)

    )

end


# ============================================================
# ENVIRONMENT
# ============================================================

struct Environment

    temperature_c::Float64

    rainfall_mm::Float64

    radiation_mj::Float64

    humidity::Float64

    co2_ppm::Float64

end


function Environment(;

    temperature_c=18.0,

    rainfall_mm=2.0,

    radiation_mj=15.0,

    humidity=0.65,

    co2_ppm=420.0

)

    Environment(

        Float64(temperature_c),

        Float64(rainfall_mm),

        Float64(radiation_mj),

        Float64(humidity),

        Float64(co2_ppm)

    )

end


# ============================================================
# FERTILISER
# ============================================================

struct Fertiliser

    name::String

    nitrogen_fraction::Float64

    phosphorus_fraction::Float64

    potassium_fraction::Float64

    cost_per_kg::Float64

end


function Fertiliser(

    name::String,

    n::Real,

    p::Real,

    k::Real,

    cost::Real

)

    Fertiliser(

        name,

        Float64(n),

        Float64(p),

        Float64(k),

        Float64(cost)

    )

end


function nutrient_content(

    fertiliser::Fertiliser,

    kg::Float64

)

    Nutrients(

        kg * fertiliser.nitrogen_fraction,

        kg * fertiliser.phosphorus_fraction,

        kg * fertiliser.potassium_fraction

    )

end


# ============================================================
# APPLICATION
# ============================================================

struct FertiliserApplication

    date::Date

    fertiliser::Fertiliser

    kilograms::Float64

end


# ============================================================
# WEATHER RECORD
# ============================================================

struct WeatherRecord

    date::Date

    environment::Environment

end


# ============================================================
# GROWTH RECORD
# ============================================================

struct GrowthRecord

    date::Date

    height_m::Float64

    diameter_cm::Float64

    canopy_m2::Float64

    biomass_kg::Float64

    health::Float64

end


# ============================================================
# GROWTH MODEL
# ============================================================

struct GrowthModel

    base_growth::Float64

    nutrient_sensitivity::Float64

    water_sensitivity::Float64

    temperature_sensitivity::Float64

    radiation_sensitivity::Float64

end


function GrowthModel(;

    base_growth=0.005,

    nutrient_sensitivity=0.5,

    water_sensitivity=0.3,

    temperature_sensitivity=0.4,

    radiation_sensitivity=0.2

)

    GrowthModel(

        base_growth,

        nutrient_sensitivity,

        water_sensitivity,

        temperature_sensitivity,

        radiation_sensitivity

    )

end


# ============================================================
# NUTRIENT LIMITATION
# ============================================================

function nutrient_factor(
    soil::Soil
)

    n =
        clamp(
            soil.nitrogen / 100.0,
            0.0,
            1.0
        )

    p =
        clamp(
            soil.phosphorus / 50.0,
            0.0,
            1.0
        )

    k =
        clamp(
            soil.potassium / 100.0,
            0.0,
            1.0
        )

    # Liebig-style limiting nutrient
    # approximation.

    min(
        n,
        p,
        k
    )

end


# ============================================================
# WATER FACTOR
# ============================================================

function water_factor(
    soil::Soil
)

    clamp(

        1.0 -
        abs(
            soil.water - 0.30
        ) / 0.30,

        0.0,

        1.0

    )

end


# ============================================================
# TEMPERATURE FACTOR
# ============================================================

function temperature_factor(
    environment::Environment
)

    t =
        environment.temperature_c

    # Simplified optimum-temperature curve.

    optimum =
        20.0

    width =
        15.0

    factor =
        1.0 -
        (
            abs(
                t - optimum
            ) /
            width
        )

    clamp(
        factor,
        0.0,
        1.0
    )

end


# ============================================================
# RADIATION FACTOR
# ============================================================

function radiation_factor(
    environment::Environment
)

    clamp(

        environment.radiation_mj /
        20.0,

        0.0,

        1.0

    )

end


# ============================================================
# APPLY FERTILISER
# ============================================================

function apply_fertiliser!(

    soil::Soil,

    application::FertiliserApplication

)

    nutrients =
        nutrient_content(

            application.fertiliser,

            application.kilograms

        )


    soil.nitrogen +=
        nutrients.nitrogen

    soil.phosphorus +=
        nutrients.phosphorus

    soil.potassium +=
        nutrients.potassium


    application

end


# ============================================================
# SOIL DYNAMICS
# ============================================================

function soil_daily_update!(

    soil::Soil,

    environment::Environment

)

    # Mineralisation / depletion approximation.

    soil.nitrogen *=
        0.999

    soil.phosphorus *=
        0.9995

    soil.potassium *=
        0.999

    # Rainfall contribution.

    soil.water +=
        environment.rainfall_mm /
        1000.0

    # Evapotranspiration approximation.

    soil.water -=
        max(
            0.0,
            environment.temperature_c - 10.0
        ) *
        0.0005


    soil.water =
        clamp(
            soil.water,
            0.0,
            1.0
        )

end


# ============================================================
# TREE GROWTH
# ============================================================

function grow_tree!(

    tree::Tree,

    soil::Soil,

    environment::Environment,

    model::GrowthModel

)

    nf =
        nutrient_factor(
            soil
        )

    wf =
        water_factor(
            soil
        )

    tf =
        temperature_factor(
            environment
        )

    rf =
        radiation_factor(
            environment
        )


    environmental_factor =
        (
            nf *
            model.nutrient_sensitivity
        ) +
        (
            wf *
            model.water_sensitivity
        ) +
        (
            tf *
            model.temperature_sensitivity
        ) +
        (
            rf *
            model.radiation_sensitivity
        )


    environmental_factor /=
        (
            model.nutrient_sensitivity +
            model.water_sensitivity +
            model.temperature_sensitivity +
            model.radiation_sensitivity
        )


    growth =
        model.base_growth *
        environmental_factor *
        tree.health


    # --------------------------------------------------------
    # Growth
    # --------------------------------------------------------

    tree.height_m +=
        growth


    tree.diameter_cm +=
        growth *
        2.0


    tree.canopy_m2 +=
        growth *
        5.0


    tree.biomass_kg +=
        growth *
        tree.biomass_kg *
        0.10


    tree.age_years +=
        1.0 / 365.0


    # --------------------------------------------------------
    # Health
    # --------------------------------------------------------

    tree.health =
        clamp(

            0.90 * tree.health +
            0.10 * environmental_factor,

            0.0,

            1.0

        )


    # --------------------------------------------------------
    # Nutrient uptake
    # --------------------------------------------------------

    soil.nitrogen =
        max(
            0.0,
            soil.nitrogen -
            growth * 2.0
        )

    soil.phosphorus =
        max(
            0.0,
            soil.phosphorus -
            growth * 0.5
        )

    soil.potassium =
        max(
            0.0,
            soil.potassium -
            growth * 1.5
        )


    tree

end


# ============================================================
# DAILY SIMULATION
# ============================================================

function simulate_day!(

    tree::Tree,

    soil::Soil,

    environment::Environment,

    model::GrowthModel

)

    soil_daily_update!(
        soil,
        environment
    )

    grow_tree!(
        tree,
        soil,
        environment,
        model
    )

end


# ============================================================
# FERTILISER OPTIMISATION
# ============================================================

function fertiliser_cost(

    fertiliser::Fertiliser,

    kilograms::Float64

)

    fertiliser.cost_per_kg *
    kilograms

end


function evaluate_application(

    tree::Tree,

    soil::Soil,

    environment::Environment,

    model::GrowthModel,

    fertiliser::Fertiliser,

    kilograms::Float64

)

    original_tree =
        deepcopy(tree)

    original_soil =
        deepcopy(soil)


    # Baseline

    grow_tree!(
        tree,
        soil,
        environment,
        model
    )

    baseline =
        tree.biomass_kg


    # Restore

    tree =
        original_tree

    soil =
        original_soil


    # Treatment

    application =
        FertiliserApplication(

            today(),

            fertiliser,

            kilograms

        )


    apply_fertiliser!(
        soil,
        application
    )


    grow_tree!(
        tree,
        soil,
        environment,
        model
    )


    treated =
        tree.biomass_kg


    gain =
        treated -
        baseline


    cost =
        fertiliser_cost(
            fertiliser,
            kilograms
        )


    (

        kilograms = kilograms,

        biomass_gain = gain,

        cost = cost,

        biomass_per_currency =
            cost > 0 ?
            gain / cost :
            0.0

    )

end


# ============================================================
# OPTIMISE APPLICATION RATE
# ============================================================

function optimise_fertiliser(

    tree::Tree,

    soil::Soil,

    environment::Environment,

    model::GrowthModel,

    fertiliser::Fertiliser,

    rates::Vector{Float64}

)

    results = [

        evaluate_application(

            tree,

            soil,

            environment,

            model,

            fertiliser,

            rate

        )

        for rate in rates

    ]


    sort!(
        results,

        by =
            x -> x.biomass_per_currency,

        rev=true

    )


    results

end


# ============================================================
# CARBON / BIOMASS
# ============================================================

function carbon_estimate(
    tree::Tree
)

    # Simplified dry-biomass carbon assumption.

    tree.biomass_kg *
    0.47

end


# ============================================================
# HEALTH INDEX
# ============================================================

function tree_health_index(
    tree::Tree
)

    clamp(
        tree.health * 100.0,
        0.0,
        100.0
    )

end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println()
    println("="^80)
    println(
        "                    ARBORIUM.OS"
    )
    println(
        "          TREE + FERTILISER ANALYTICS"
    )
    println("="^80)


    # --------------------------------------------------------
    # Soil
    # --------------------------------------------------------

    soil =
        Soil(

            nitrogen=60,

            phosphorus=30,

            potassium=55,

            water=0.35,

            ph=6.5,

            organic_matter=4.0

        )


    # --------------------------------------------------------
    # Tree
    # --------------------------------------------------------

    tree =
        Tree(

            "TREE-001",

            "Oak";

            age_years=5,

            height_m=3.5,

            diameter_cm=7.0,

            canopy_m2=8.0,

            biomass_kg=35.0

        )


    # --------------------------------------------------------
    # Environment
    # --------------------------------------------------------

    environment =
        Environment(

            temperature_c=19,

            rainfall_mm=4,

            radiation_mj=18,

            humidity=0.65,

            co2_ppm=425

        )


    model =
        GrowthModel()


    # --------------------------------------------------------
    # Fertiliser
    # --------------------------------------------------------

    fertiliser =
        Fertiliser(

            "NPK 15-10-15",

            0.15,

            0.10,

            0.15,

            0.80

        )


    # --------------------------------------------------------
    # Optimisation
    # --------------------------------------------------------

    rates =
        collect(
            0.0:2.0:40.0
        )


    results =
        optimise_fertiliser(

            tree,

            soil,

            environment,

            model,

            fertiliser,

            rates

        )


    println()
    println(
        "FERTILISER OPTIMISATION"
    )

    println(
        "-"^80
    )


    for r in results[1:min(5, length(results))]

        println(

            @sprintf(

                "%6.1f kg | biomass gain %8.4f kg | cost £%7.2f | gain/£ %.6f",

                r.kilograms,

                r.biomass_gain,

                r.cost,

                r.biomass_per_currency

            )

        )

    end


    # --------------------------------------------------------
    # Growth simulation
    # --------------------------------------------------------

    println()
    println(
        "365-DAY TREE SIMULATION"
    )

    println(
        "-"^80
    )


    records =
        GrowthRecord[]


    for day in 1:365

        # Example periodic fertilisation.

        if day in
            (
                30,
                90,
                150,
                210,
                270
            )

            application =
                FertiliserApplication(

                    today(),

                    fertiliser,

                    10.0

                )

            apply_fertiliser!(
                soil,
                application
            )

        end


        # Simple seasonal environment.

        seasonal_temperature =
            12.0 +
            10.0 *
            sin(
                2π *
                day /
                365.0
            )


        seasonal_radiation =
            12.0 +
            8.0 *
            sin(
                2π *
                (day - 80) /
                365.0
            )


        env =
            Environment(

                temperature_c =
                    seasonal_temperature,

                rainfall_mm =
                    2.0,

                radiation_mj =
                    max(
                        4.0,
                        seasonal_radiation
                    )

            )


        simulate_day!(
            tree,
            soil,
            env,
            model
        )


        push!(
            records,

            GrowthRecord(

                today(),

                tree.height_m,

                tree.diameter_cm,

                tree.canopy_m2,

                tree.biomass_kg,

                tree.health

            )

        )


        if day % 30 == 0

            println(

                @sprintf(

                    "Day %3d | height %7.3fm | diameter %7.2fcm | biomass %9.2fkg | health %6.1f%%",

                    day,

                    tree.height_m,

                    tree.diameter_cm,

                    tree.biomass_kg,

                    tree_health_index(tree)

                )

            )

        end

    end


    println()
    println(
        "FINAL TREE"
    )

    println(
        "Species: ",
        tree.species
    )

    println(
        "Height: ",
        round(
            tree.height_m,
            digits=3
        ),
        " m"
    )

    println(
        "Diameter: ",
        round(
            tree.diameter_cm,
            digits=2
        ),
        " cm"
    )

    println(
        "Biomass: ",
        round(
            tree.biomass_kg,
            digits=2
        ),
        " kg"
    )

    println(
        "Estimated carbon: ",
        round(
            carbon_estimate(tree),
            digits=2
        ),
        " kg C"
    )

    println(
        "Health: ",
        round(
            tree_health_index(tree),
            digits=1
        ),
        "%"
    )

    println()
    println(
        "FINAL SOIL"
    )

    println(
        "N: ",
        round(soil.nitrogen, digits=2)
    )

    println(
        "P: ",
        round(soil.phosphorus, digits=2)
    )

    println(
        "K: ",
        round(soil.potassium, digits=2)
    )

    println(
        "Water: ",
        round(soil.water, digits=3)
    )

    println(
        "pH: ",
        round(soil.ph, digits=2)
    )


    println()
    println("="^80)

end


# ============================================================
# EXPORTS
# ============================================================

export Nutrients
export Soil
export Tree
export Environment
export Fertiliser
export FertiliserApplication
export WeatherRecord
export GrowthRecord
export GrowthModel

export apply_fertiliser!
export nutrient_factor
export water_factor
export temperature_factor
export radiation_factor

export grow_tree!
export simulate_day!

export fertiliser_cost
export evaluate_application
export optimise_fertiliser

export carbon_estimate
export tree_health_index

export demo


end


# ============================================================
# RUN
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .Arborium

    Arborium.demo()

end
```





# ARBORIUM.OS

## R Statistical Analytics Layer

```r
# ============================================================
# ARBORIUM.OS
# TREE + FERTILISER STATISTICS
# ============================================================

library(stats)


# ============================================================
# GROWTH METRICS
# ============================================================

growth_rate <- function(
    height,
    time
) {

    if (length(height) < 2) {
        return(NA_real_)
    }

    (
        tail(height, 1) -
        head(height, 1)
    ) /
    (
        tail(time, 1) -
        head(time, 1)
    )
}


biomass_growth_rate <- function(
    biomass,
    time
) {

    if (length(biomass) < 2) {
        return(NA_real_)
    }

    (
        tail(biomass, 1) -
        head(biomass, 1)
    ) /
    (
        tail(time, 1) -
        head(time, 1)
    )
}


# ============================================================
# FERTILISER RESPONSE
# ============================================================

fertiliser_response <- function(
    biomass_gain,
    fertiliser_rate
) {

    model <- lm(
        biomass_gain ~
            fertiliser_rate +
            I(fertiliser_rate^2)
    )

    model
}


# ============================================================
# RESPONSE CURVE
# ============================================================

predict_response <- function(
    model,
    rates
) {

    newdata <- data.frame(
        fertiliser_rate = rates
    )

    predict(
        model,
        newdata
    )

}


# ============================================================
# OPTIMAL RATE
# ============================================================

optimal_rate <- function(
    model,
    min_rate = 0,
    max_rate = 100,
    resolution = 1000
) {

    rates <- seq(
        min_rate,
        max_rate,
        length.out = resolution
    )

    predictions <- predict_response(
        model,
        rates
    )

    rates[
        which.max(
            predictions
        )
    ]

}


# ============================================================
# ECONOMIC OPTIMUM
# ============================================================

economic_optimum <- function(
    model,
    fertiliser_price,
    biomass_value,
    min_rate = 0,
    max_rate = 100,
    resolution = 1000
) {

    rates <- seq(
        min_rate,
        max_rate,
        length.out = resolution
    )

    biomass <- predict_response(
        model,
        rates
    )

    revenue <-
        biomass *
        biomass_value

    cost <-
        rates *
        fertiliser_price

    profit <-
        revenue -
        cost

    index <- which.max(
        profit
    )

    list(
        rate = rates[index],
        biomass = biomass[index],
        revenue = revenue[index],
        cost = cost[index],
        profit = profit[index]
    )
}


# ============================================================
# GROWTH REGRESSION
# ============================================================

growth_model <- function(
    data
) {

    lm(
        biomass ~
            age +
            nitrogen +
            phosphorus +
            potassium +
            water +
            temperature +
            radiation,
        data = data
    )

}


# ============================================================
# HEALTH MODEL
# ============================================================

health_model <- function(
    data
) {

    lm(
        health ~
            nitrogen +
            phosphorus +
            potassium +
            water +
            temperature,
        data = data
    )

}


# ============================================================
# NUTRIENT LIMITATION
# ============================================================

limiting_nutrient <- function(
    nitrogen,
    phosphorus,
    potassium
) {

    values <- c(
        nitrogen,
        phosphorus,
        potassium
    )

    names(values) <- c(
        "Nitrogen",
        "Phosphorus",
        "Potassium"
    )

    names(
        which.min(values)
    )

}


# ============================================================
# GROWTH SUMMARY
# ============================================================

growth_summary <- function(
    data
) {

    list(

        initial_height =
            head(data$height, 1),

        final_height =
            tail(data$height, 1),

        height_gain =
            tail(data$height, 1) -
            head(data$height, 1),

        initial_biomass =
            head(data$biomass, 1),

        final_biomass =
            tail(data$biomass, 1),

        biomass_gain =
            tail(data$biomass, 1) -
            head(data$biomass, 1),

        mean_health =
            mean(
                data$health,
                na.rm = TRUE
            )

    )

}


# ============================================================
# DEMONSTRATION DATA
# ============================================================

set.seed(42)

n <- 200

data <- data.frame(

    day = 1:n,

    age = seq(
        1,
        1 + n / 365,
        length.out = n
    ),

    nitrogen =
        runif(
            n,
            30,
            100
        ),

    phosphorus =
        runif(
            n,
            15,
            50
        ),

    potassium =
        runif(
            n,
            30,
            100
        ),

    water =
        runif(
            n,
            0.15,
            0.45
        ),

    temperature =
        rnorm(
            n,
            18,
            4
        ),

    radiation =
        rnorm(
            n,
            16,
            3
        ),

    fertiliser_rate =
        runif(
            n,
            0,
            40
        )

)


# ============================================================
# SYNTHETIC RESPONSE
# ============================================================

data$biomass <-

    20 +

    0.08 *
    data$age +

    0.04 *
    data$nitrogen +

    0.03 *
    data$phosphorus +

    0.02 *
    data$potassium +

    4 *
    data$water +

    0.5 *
    data$temperature +

    0.3 *
    data$radiation +

    0.20 *
    data$fertiliser_rate -

    0.003 *
    data$fertiliser_rate^2 +

    rnorm(
        n,
        0,
        1
    )


data$height <-

    2 +

    0.05 *
    data$age +

    0.01 *
    data$nitrogen +

    rnorm(
        n,
        0,
        0.05
    )


data$health <-

    pmin(

        1,

        pmax(

            0,

            0.4 +

            0.003 *
            data$nitrogen +

            0.002 *
            data$phosphorus +

            0.001 *
            data$potassium -

            0.3 *
            abs(
                data$water -
                0.30
            ) +

            rnorm(
                n,
                0,
                0.03
            )

        )

    )


# ============================================================
# MODELS
# ============================================================

growth <- growth_model(
    data
)

health <- health_model(
    data
)

fertiliser <- fertiliser_response(
    data$biomass,
    data$fertiliser_rate
)


# ============================================================
# RESULTS
# ============================================================

cat("\n")
cat("========================================\n")
cat("       ARBORIUM.OS R ANALYTICS\n")
cat("========================================\n\n")


cat("GROWTH MODEL\n")
print(
    summary(growth)
)


cat("\nHEALTH MODEL\n")
print(
    summary(health)
)


cat("\nFERTILISER RESPONSE\n")
print(
    summary(fertiliser)
)


# ============================================================
# OPTIMAL FERTILISER RATE
# ============================================================

rate <- optimal_rate(
    fertiliser,
    min_rate = 0,
    max_rate = 50
)


cat(
    "\nStatistical optimum fertiliser rate:",
    round(rate, 2),
    "kg\n"
)


# ============================================================
# ECONOMIC OPTIMUM
# ============================================================

economic <- economic_optimum(

    fertiliser,

    fertiliser_price = 0.80,

    biomass_value = 2.50,

    min_rate = 0,

    max_rate = 50

)


cat(
    "\nEconomic optimum:\n"
)

print(
    economic
)


# ============================================================
# LIMITING NUTRIENT
# ============================================================

cat(
    "\nExample limiting nutrient:"
)

print(
    limiting_nutrient(
        mean(data$nitrogen),
        mean(data$phosphorus),
        mean(data$potassium)
    )
)


# ============================================================
# SUMMARY
# ============================================================

cat(
    "\nGrowth summary:\n"
)

print(
    growth_summary(
        data
    )
)
```




