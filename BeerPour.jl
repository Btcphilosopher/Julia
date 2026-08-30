module BeerPour

using Statistics
using Printf

# ============================================================
# BEER POUR OPTIMISATION ENGINE
# Pure Julia — no external packages
#
# Purpose:
#   Optimise beer dispensing for:
#     - pour time
#     - flow rate
#     - beer temperature
#     - dispense pressure
#     - foam/head
#     - waste
#     - fill level
#     - consistency
#
# This is a simulation/control model, not a substitute for
# brewery/manufacturer dispensing specifications.
# ============================================================


# ============================================================
# PHYSICAL CONSTANTS
# ============================================================

const PINT_L = 0.568261
const ATM_PA = 101325.0


# ============================================================
# BEER PROFILE
# ============================================================

struct BeerProfile

    name::String

    target_temperature_C::Float64

    target_flow_L_s::Float64

    target_head_fraction::Float64

    density_kg_L::Float64

    viscosity_mPa_s::Float64

    carbonation_volumes::Float64

    ideal_pour_time_s::Float64
end


# ============================================================
# DISPENSE SYSTEM
# ============================================================

struct DispenseSystem

    line_length_m::Float64

    line_diameter_mm::Float64

    line_restriction::Float64

    keg_pressure_kPa::Float64

    ambient_temperature_C::Float64

    cooler_temperature_C::Float64

    tap_restriction::Float64

    cooling_efficiency::Float64
end


# ============================================================
# GLASS
# ============================================================

struct Glass

    capacity_L::Float64

    initial_temperature_C::Float64

    wetness::Float64

    cleanliness::Float64
end


# ============================================================
# POUR REQUEST
# ============================================================

struct PourRequest

    beer_volume_L::Float64

    target_head_fraction::Float64

    target_temperature_C::Float64

    target_flow_L_s::Float64
end


# ============================================================
# POUR RESULT
# ============================================================

struct PourResult

    beer_volume_L::Float64

    foam_volume_L::Float64

    total_volume_L::Float64

    final_temperature_C::Float64

    average_flow_L_s::Float64

    pour_time_s::Float64

    waste_L::Float64

    quality_score::Float64

    temperature_score::Float64

    flow_score::Float64

    head_score::Float64

    cleanliness_score::Float64

    pressure_score::Float64

    recommendation::String
end


# ============================================================
# FLOW MODEL
# ============================================================

function hydraulic_flow(
    pressure_kPa::Float64,
    diameter_mm::Float64,
    restriction::Float64,
    viscosity_mPa_s::Float64
)

    pressure =
        pressure_kPa * 1000.0

    diameter =
        diameter_mm / 1000.0

    area =
        π * (diameter / 2)^2

    # Simplified pressure-to-flow relationship.
    #
    # Real dispense systems require empirical calibration
    # against the specific line, coupler, keg and tap.

    viscosity_factor =
        1.0 /
        (1.0 + 0.025 *
         viscosity_mPa_s)

    flow =
        area *
        sqrt(
            2.0 * pressure /
            1000.0
        )

    flow *=
        restriction *
        viscosity_factor

    return max(flow, 0.0001)
end


# ============================================================
# TEMPERATURE MODEL
# ============================================================

function beer_temperature(
    system::DispenseSystem,
    beer_temperature_C::Float64,
    flow_L_s::Float64,
    pour_time_s::Float64
)

    # Approximate thermal exchange through the line.

    exposure =
        system.line_length_m /
        max(flow_L_s, 0.001)

    cooling =
        system.cooling_efficiency *
        (system.cooler_temperature_C -
         beer_temperature_C) *
        (1.0 -
         exp(-exposure / 20.0))

    final_temperature =
        beer_temperature_C +
        cooling

    return final_temperature
end


# ============================================================
# CARBONATION / FOAM MODEL
# ============================================================

function foam_fraction(
    pressure_kPa::Float64,
    target_temperature_C::Float64,
    carbonation_volumes::Float64,
    flow_L_s::Float64,
    glass::Glass
)

    # Higher flow and excessive pressure increase turbulence.
    # Temperature and carbonation influence foam formation.

    pressure_effect =
        abs(
            pressure_kPa - 80.0
        ) / 80.0

    flow_effect =
        max(
            flow_L_s - 0.15,
            0.0
        ) / 0.15

    temperature_effect =
        max(
            target_temperature_C - 5.0,
            0.0
        ) / 8.0

    carbonation_effect =
        max(
            carbonation_volumes - 2.3,
            0.0
        )

    glass_effect =
        1.0 -
        glass.cleanliness

    foam =
        0.025 +
        0.020 * pressure_effect +
        0.035 * flow_effect +
        0.015 * temperature_effect +
        0.020 * carbonation_effect +
        0.030 * glass_effect

    return clamp(
        foam,
        0.01,
        0.25
    )
end


# ============================================================
# QUALITY SCORING
# ============================================================

function gaussian_score(
    value::Float64,
    target::Float64,
    tolerance::Float64
)

    return exp(
        -0.5 *
        ((value - target) /
         tolerance)^2
    )
end


function quality_score(
    temperature_C,
    target_temperature_C,
    flow_L_s,
    target_flow_L_s,
    head_fraction,
    target_head_fraction,
    cleanliness,
    pressure_kPa
)

    temperature_score =
        gaussian_score(
            temperature_C,
            target_temperature_C,
            1.5
        )

    flow_score =
        gaussian_score(
            flow_L_s,
            target_flow_L_s,
            0.04
        )

    head_score =
        gaussian_score(
            head_fraction,
            target_head_fraction,
            0.025
        )

    cleanliness_score =
        clamp(
            cleanliness,
            0.0,
            1.0
        )

    pressure_score =
        gaussian_score(
            pressure_kPa,
            80.0,
            25.0
        )

    score =
        100.0 *
        (
            0.30 * temperature_score +
            0.25 * flow_score +
            0.25 * head_score +
            0.10 * cleanliness_score +
            0.10 * pressure_score
        )

    return (
        score,
        temperature_score,
        flow_score,
        head_score,
        cleanliness_score,
        pressure_score
    )
end


# ============================================================
# POUR SIMULATOR
# ============================================================

function simulate_pour(
    beer::BeerProfile,
    system::DispenseSystem,
    glass::Glass,
    request::PourRequest
)

    flow =
        hydraulic_flow(
            system.keg_pressure_kPa,
            system.line_diameter_mm,
            system.line_restriction *
            system.tap_restriction,
            beer.viscosity_mPa_s
        )

    # Prevent unrealistic flow values.

    flow =
        clamp(
            flow,
            0.03,
            0.50
        )

    pour_time =
        request.beer_volume_L /
        flow

    final_temperature =
        beer_temperature(
            system,
            system.cooler_temperature_C,
            flow,
            pour_time
        )

    head =
        foam_fraction(
            system.keg_pressure_kPa,
            final_temperature,
            beer.carbonation_volumes,
            flow,
            glass
        )

    foam_volume =
        request.beer_volume_L *
        head

    total_volume =
        request.beer_volume_L +
        foam_volume

    # Waste rises when foam exceeds useful head.

    useful_head =
        request.target_head_fraction

    excessive_foam =
        max(
            foam_volume -
            request.beer_volume_L *
            useful_head,
            0.0
        )

    waste =
        excessive_foam * 0.75

    (
        score,
        temperature_score,
        flow_score,
        head_score,
        cleanliness_score,
        pressure_score
    ) =
        quality_score(
            final_temperature,
            request.target_temperature_C,
            flow,
            request.target_flow_L_s,
            head,
            request.target_head_fraction,
            glass.cleanliness,
            system.keg_pressure_kPa
        )

    recommendation =
        generate_recommendation(
            beer,
            system,
            glass,
            final_temperature,
            flow,
            head,
            score
        )

    PourResult(
        request.beer_volume_L,
        foam_volume,
        total_volume,
        final_temperature,
        flow,
        pour_time,
        waste,
        score,
        temperature_score,
        flow_score,
        head_score,
        cleanliness_score,
        pressure_score,
        recommendation
    )
end


# ============================================================
# AUTOMATIC RECOMMENDATIONS
# ============================================================

function generate_recommendation(
    beer,
    system,
    glass,
    temperature,
    flow,
    head,
    score
)

    recommendations = String[]

    if temperature >
       beer.target_temperature_C + 1.5

        push!(
            recommendations,
            "Reduce dispense temperature / improve cooling."
        )

    elseif temperature <
           beer.target_temperature_C - 1.5

        push!(
            recommendations,
            "Increase beer temperature slightly."
        )
    end

    if flow >
       beer.target_flow_L_s + 0.05

        push!(
            recommendations,
            "Reduce flow rate."
        )

    elseif flow <
           beer.target_flow_L_s - 0.05

        push!(
            recommendations,
            "Increase flow rate."
        )
    end

    if head >
       beer.target_head_fraction + 0.025

        push!(
            recommendations,
            "Reduce turbulence or dispense pressure."
        )

    elseif head <
           beer.target_head_fraction - 0.025

        push!(
            recommendations,
            "Increase controlled agitation / optimise dispense."
        )
    end

    if glass.cleanliness < 0.90

        push!(
            recommendations,
            "Clean or replace glass."
        )
    end

    if isempty(recommendations)

        return score > 90 ?
            "Excellent pour. Maintain current settings." :
            "Good pour. Minor optimisation recommended."
    end

    return join(
        recommendations,
        " "
    )
end


# ============================================================
# AUTOMATIC PRESSURE OPTIMISER
# ============================================================

function optimise_pressure(
    beer::BeerProfile,
    system::DispenseSystem,
    glass::Glass,
    request::PourRequest
)

    best_pressure =
        system.keg_pressure_kPa

    best_score =
        -Inf

    best_result =
        nothing

    for pressure in
        40.0:1.0:120.0

        candidate =
            DispenseSystem(
                system.line_length_m,
                system.line_diameter_mm,
                system.line_restriction,
                pressure,
                system.ambient_temperature_C,
                system.cooler_temperature_C,
                system.tap_restriction,
                system.cooling_efficiency
            )

        result =
            simulate_pour(
                beer,
                candidate,
                glass,
                request
            )

        if result.quality_score >
           best_score

            best_score =
                result.quality_score

            best_pressure =
                pressure

            best_result =
                result
        end
    end

    return (
        best_pressure,
        best_result
    )
end


# ============================================================
# AUTOMATIC FLOW OPTIMISER
# ============================================================

function optimise_system(
    beer::BeerProfile,
    system::DispenseSystem,
    glass::Glass,
    request::PourRequest
)

    best_score =
        -Inf

    best_system =
        system

    best_result =
        nothing

    for pressure in
        40.0:2.0:120.0

        for restriction in
            0.50:0.05:1.20

            candidate =
                DispenseSystem(
                    system.line_length_m,
                    system.line_diameter_mm,
                    system.line_restriction,
                    pressure,
                    system.ambient_temperature_C,
                    system.cooler_temperature_C,
                    system.tap_restriction,
                    system.cooling_efficiency
                )

            candidate =
                DispenseSystem(
                    candidate.line_length_m,
                    candidate.line_diameter_mm,
                    restriction,
                    candidate.keg_pressure_kPa,
                    candidate.ambient_temperature_C,
                    candidate.cooler_temperature_C,
                    candidate.tap_restriction,
                    candidate.cooling_efficiency
                )

            result =
                simulate_pour(
                    beer,
                    candidate,
                    glass,
                    request
                )

            if result.quality_score >
               best_score

                best_score =
                    result.quality_score

                best_system =
                    candidate

                best_result =
                    result
            end
        end
    end

    return (
        best_system,
        best_result
    )
end


# ============================================================
# PUB POUR CONTROLLER
# ============================================================

mutable struct PourController

    target_temperature_C::Float64
    target_flow_L_s::Float64
    target_head_fraction::Float64

    last_quality_score::Float64

    pours::Int

    cumulative_waste_L::Float64

    cumulative_volume_L::Float64
end


function PourController(
    beer::BeerProfile
)

    PourController(
        beer.target_temperature_C,
        beer.target_flow_L_s,
        beer.target_head_fraction,
        0.0,
        0,
        0.0,
        0.0
    )
end


function update!(
    controller::PourController,
    result::PourResult
)

    controller.last_quality_score =
        result.quality_score

    controller.pours += 1

    controller.cumulative_waste_L +=
        result.waste_L

    controller.cumulative_volume_L +=
        result.beer_volume_L

    return controller
end


function waste_percentage(
    controller::PourController
)

    if controller.cumulative_volume_L <= 0
        return 0.0
    end

    100.0 *
    controller.cumulative_waste_L /
    controller.cumulative_volume_L
end


# ============================================================
# SHIFT SIMULATION
# ============================================================

function simulate_shift(
    beer::BeerProfile,
    system::DispenseSystem,
    glass::Glass,
    controller::PourController;
    pours=100
)

    results =
        PourResult[]

    for i in 1:pours

        # Small realistic variation in each pour.

        request =
            PourRequest(
                PINT_L,
                beer.target_head_fraction,
                beer.target_temperature_C,
                beer.target_flow_L_s
            )

        result =
            simulate_pour(
                beer,
                system,
                glass,
                request
            )

        push!(
            results,
            result
        )

        update!(
            controller,
            result
        )
    end

    return results
end


# ============================================================
# REPORTING
# ============================================================

function print_result(
    result::PourResult
)

    println()
    println("="^60)
    println(" BEER POUR QUALITY REPORT")
    println("="^60)

    @printf(
        "Beer volume:             %.3f L\n",
        result.beer_volume_L
    )

    @printf(
        "Foam/head volume:        %.3f L\n",
        result.foam_volume_L
    )

    @printf(
        "Total volume:            %.3f L\n",
        result.total_volume_L
    )

    @printf(
        "Temperature:             %.2f °C\n",
        result.final_temperature_C
    )

    @printf(
        "Flow rate:               %.3f L/s\n",
        result.average_flow_L_s
    )

    @printf(
        "Pour time:               %.2f s\n",
        result.pour_time_s
    )

    @printf(
        "Waste:                   %.3f L\n",
        result.waste_L
    )

    @printf(
        "Quality score:           %.1f / 100\n",
        result.quality_score
    )

    println()
    println("Recommendation:")
    println(result.recommendation)

    println("="^60)
    println()
end


# ============================================================
# EXAMPLE BEER
# ============================================================

function example_beer()

    BeerProfile(
        "House Lager",
        4.0,
        0.18,
        0.12,
        1.01,
        1.5,
        2.5,
        3.15
    )
end


# ============================================================
# EXAMPLE DISPENSE SYSTEM
# ============================================================

function example_system()

    DispenseSystem(
        3.5,       # line length m
        8.0,       # line diameter mm
        0.80,      # line restriction
        70.0,      # keg pressure kPa
        22.0,      # ambient temperature
        3.0,       # cooler temperature
        0.85,      # tap restriction
        0.90       # cooling efficiency
    )
end


# ============================================================
# EXAMPLE GLASS
# ============================================================

function example_glass()

    Glass(
        0.568,
        20.0,
        0.90,
        0.98
    )
end


# ============================================================
# DEMO
# ============================================================

function demo()

    beer =
        example_beer()

    system =
        example_system()

    glass =
        example_glass()

    request =
        PourRequest(
            PINT_L,
            beer.target_head_fraction,
            beer.target_temperature_C,
            beer.target_flow_L_s
        )

    println()
    println("PUB BEER POUR OPTIMISATION ENGINE")
    println("Pure Julia")
    println()

    result =
        simulate_pour(
            beer,
            system,
            glass,
            request
        )

    print_result(result)

    println("Searching for optimal pressure...")

    (
        pressure,
        optimal_result
    ) =
        optimise_pressure(
            beer,
            system,
            glass,
            request
        )

    @printf(
        "Optimal pressure: %.1f kPa\n",
        pressure
    )

    print_result(
        optimal_result
    )

    println(
        "Running 100-pour shift simulation..."
    )

    controller =
        PourController(beer)

    results =
        simulate_shift(
            beer,
            system,
            glass,
            controller;
            pours=100
        )

    scores =
        [r.quality_score for r in results]

    @printf(
        "Average quality: %.1f / 100\n",
        mean(scores)
    )

    @printf(
        "Best quality: %.1f / 100\n",
        maximum(scores)
    )

    @printf(
        "Worst quality: %.1f / 100\n",
        minimum(scores)
    )

    @printf(
        "Total waste: %.3f L\n",
        controller.cumulative_waste_L
    )

    @printf(
        "Waste rate: %.2f %%\n",
        waste_percentage(controller)
    )

    return results
end


# ============================================================
# EXPORTS
# ============================================================

export BeerProfile
export DispenseSystem
export Glass
export PourRequest
export PourResult
export PourController

export simulate_pour
export optimise_pressure
export optimise_system
export simulate_shift

export hydraulic_flow
export beer_temperature
export foam_fraction

export update!
export waste_percentage

export print_result

export example_beer
export example_system
export example_glass

export demo


end # module BeerPour


# ============================================================
# EXECUTE DEMO
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .BeerPour

    BeerPour.demo()

end
