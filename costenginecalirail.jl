# ================================================================
# CALRAIL COST ENGINE
# Julia Infrastructure Cost + Schedule Digital Twin
#
# PURPOSE
#   Large-scale railway cost modelling at a mid-construction point.
#
# FEATURES
#   - Work breakdown structure
#   - Installed / remaining quantities
#   - Labour
#   - Materials
#   - Plant & equipment
#   - Contractor overhead
#   - Engineering / design
#   - Project management
#   - Land / utilities
#   - Inflation
#   - Productivity
#   - Schedule
#   - Contingency
#   - Risk registers
#   - Scenario analysis
#   - Monte Carlo simulation
#   - Completion-cost forecasting
#   - Acceleration optimisation
#
# IMPORTANT:
#   Values below are illustrative model inputs.
#   Replace with validated programme data before decision-making.
# ================================================================


using Random
using Statistics
using Printf
using LinearAlgebra


# ================================================================
# 1. BASIC TYPES
# ================================================================

struct CostRate

    labour_per_unit::Float64
    material_per_unit::Float64
    equipment_per_unit::Float64

end


mutable struct WorkPackage

    id::String
    name::String
    category::String

    total_quantity::Float64
    installed_quantity::Float64

    unit::String

    rate::CostRate

    duration_months::Float64

    productivity::Float64

    inflation::Float64

    contractor_overhead::Float64

    design_rate::Float64
    management_rate::Float64

    contingency::Float64

end


struct Risk

    name::String

    probability::Float64

    impact_low::Float64
    impact_mode::Float64
    impact_high::Float64

end


struct Programme

    name::String

    current_month::Int
    base_year::Int

    inflation_rate::Float64

    packages::Vector{WorkPackage}
    risks::Vector{Risk}

end


# ================================================================
# 2. QUANTITY ENGINE
# ================================================================

function remaining_quantity(
    package::WorkPackage
)

    return max(
        0.0,

        package.total_quantity -
        package.installed_quantity
    )

end


function completion_fraction(
    package::WorkPackage
)

    return (
        package.installed_quantity /
        max(
            package.total_quantity,
            1e-9
        )
    )

end


# ================================================================
# 3. BASE DIRECT COST
# ================================================================

function direct_cost(
    package::WorkPackage
)

    q =
        remaining_quantity(
            package
        )

    labour =
        q *
        package.rate.labour_per_unit

    materials =
        q *
        package.rate.material_per_unit

    equipment =
        q *
        package.rate.equipment_per_unit

    return (
        labour +
        materials +
        equipment
    )

end


# ================================================================
# 4. COST COMPONENTS
# ================================================================

function labour_cost(
    package
)

    return (
        remaining_quantity(package) *
        package.rate.labour_per_unit
    )

end


function material_cost(
    package
)

    return (
        remaining_quantity(package) *
        package.rate.material_per_unit
    )

end


function equipment_cost(
    package
)

    return (
        remaining_quantity(package) *
        package.rate.equipment_per_unit
    )

end


# ================================================================
# 5. PRODUCTIVITY EFFECT
#
# Productivity < 1.0  → inefficient
# Productivity = 1.0  → baseline
# Productivity > 1.0  → improved
# ================================================================

function productivity_adjustment(
    package
)

    return (
        1.0 /
        max(
            package.productivity,
            0.10
        )
    )

end


# ================================================================
# 6. INFLATION
# ================================================================

function escalation_factor(
    package,
    months_remaining
)

    years =
        months_remaining /
        12.0

    return (
        1.0 +
        package.inflation
    ) ^ years

end


# ================================================================
# 7. FULL PACKAGE FORECAST
# ================================================================

function forecast_package(
    package::WorkPackage
)

    remaining =
        remaining_quantity(
            package
        )

    base =
        direct_cost(
            package
        )

    productivity_factor =
        productivity_adjustment(
            package
        )

    inflation_factor =
        escalation_factor(
            package,
            package.duration_months
        )

    adjusted_direct =
        base *
        productivity_factor *
        inflation_factor


    contractor =
        adjusted_direct *
        package.contractor_overhead


    design =
        adjusted_direct *
        package.design_rate


    management =
        adjusted_direct *
        package.management_rate


    subtotal =
        adjusted_direct +
        contractor +
        design +
        management


    contingency =
        subtotal *
        package.contingency


    total =
        subtotal +
        contingency


    return (
        quantity=remaining,
        direct=adjusted_direct,
        contractor=contractor,
        design=design,
        management=management,
        contingency=contingency,
        total=total
    )

end


# ================================================================
# 8. PROGRAMME COST
# ================================================================

function programme_cost(
    programme::Programme
)

    totals = Dict(

        :direct => 0.0,
        :contractor => 0.0,
        :design => 0.0,
        :management => 0.0,
        :contingency => 0.0,
        :total => 0.0
    )


    for package in programme.packages

        result =
            forecast_package(
                package
            )

        totals[:direct] +=
            result.direct

        totals[:contractor] +=
            result.contractor

        totals[:design] +=
            result.design

        totals[:management] +=
            result.management

        totals[:contingency] +=
            result.contingency

        totals[:total] +=
            result.total

    end


    return totals

end


# ================================================================
# 9. COST BREAKDOWN REPORT
# ================================================================

function print_cost_report(
    programme
)

    totals =
        programme_cost(
            programme
        )


    println()
    println(
        "=============================================================="
    )

    println(
        "                 CALRAIL COST ENGINE"
    )

    println(
        "          MID-CONSTRUCTION COST FORECAST"
    )

    println(
        "=============================================================="
    )


    @printf(
        "Direct construction:      $%,15.2f\n",
        totals[:direct]
    )

    @printf(
        "Contractor overhead:      $%,15.2f\n",
        totals[:contractor]
    )

    @printf(
        "Engineering / design:     $%,15.2f\n",
        totals[:design]
    )

    @printf(
        "Programme management:     $%,15.2f\n",
        totals[:management]
    )

    @printf(
        "Contingency:              $%,15.2f\n",
        totals[:contingency]
    )

    println(
        "--------------------------------------------------------------"
    )

    @printf(
        "FORECAST REMAINING:       $%,15.2f\n",
        totals[:total]
    )

    println(
        "=============================================================="
    )

end


# ================================================================
# 10. PACKAGE REPORT
# ================================================================

function package_report(
    programme
)

    println()
    println(
        "WORK PACKAGE COSTS"
    )

    println(
        "--------------------------------------------------------------"
    )


    for package in
        programme.packages

        result =
            forecast_package(
                package
            )

        @printf(
            "%-28s %12.2f %-8s $%,15.0f\n",

            package.name,

            result.quantity,

            package.unit,

            result.total
        )

    end

end


# ================================================================
# 11. RISK ENGINE
# ================================================================

function triangular_sample(
    low,
    mode,
    high
)

    u =
        rand()

    f =
        (
            mode -
            low
        ) /
        (
            high -
            low
        )


    if u < f

        return low +
            sqrt(
                u *
                (
                    high -
                    low
                ) *
                (
                    mode -
                    low
                )
            )

    else

        return high -
            sqrt(
                (
                    1.0 - u
                ) *
                (
                    high -
                    low
                ) *
                (
                    high -
                    mode
                )
            )

    end

end


function simulate_risk(
    risk::Risk
)

    if rand() >
       risk.probability

        return 0.0

    end


    return triangular_sample(
        risk.impact_low,
        risk.impact_mode,
        risk.impact_high
    )

end


# ================================================================
# 12. MONTE CARLO COST FORECAST
# ================================================================

function monte_carlo(
    programme;
    iterations=10_000
)

    base =
        programme_cost(
            programme
        )[:total]


    outcomes =
        Vector{Float64}(
            undef,
            iterations
        )


    for i in
        1:iterations

        risk_cost = 0.0


        for risk in
            programme.risks

            risk_cost +=
                simulate_risk(
                    risk
                )

        end


        # Package-level uncertainty

        package_multiplier =
            exp(
                0.08 *
                randn()
            )


        outcomes[i] =
            base *
            package_multiplier +
            risk_cost

    end


    return outcomes

end


# ================================================================
# 13. MONTE CARLO REPORT
# ================================================================

function monte_carlo_report(
    outcomes
)

    println()
    println(
        "MONTE CARLO FORECAST"
    )

    println(
        "--------------------------------------------------------------"
    )


    @printf(
        "P10:       $%,15.2f\n",
        quantile(
            outcomes,
            0.10
        )
    )


    @printf(
        "P25:       $%,15.2f\n",
        quantile(
            outcomes,
            0.25
        )
    )


    @printf(
        "P50:       $%,15.2f\n",
        quantile(
            outcomes,
            0.50
        )
    )


    @printf(
        "P75:       $%,15.2f\n",
        quantile(
            outcomes,
            0.75
        )
    )


    @printf(
        "P90:       $%,15.2f\n",
        quantile(
            outcomes,
            0.90
        )
    )


    @printf(
        "Mean:      $%,15.2f\n",
        mean(outcomes)
    )

end


# ================================================================
# 14. ACCELERATION MODEL
# ================================================================

function acceleration_cost(
    package,
    acceleration_fraction
)

    base =
        direct_cost(
            package
        )


    # Accelerating construction creates
    # overtime, additional crews,
    # equipment mobilisation and logistics costs.

    premium =
        1.0 +
        0.35 *
        acceleration_fraction^1.7


    return (
        base *
        premium
    )

end


function acceleration_savings(
    package,
    acceleration_fraction
)

    baseline =
        package.duration_months


    accelerated =
        baseline *
        (
            1.0 -
            0.50 *
            acceleration_fraction
        )


    return max(
        0.0,
        baseline -
        accelerated
    )

end


# ================================================================
# 15. ACCELERATION OPTIMISATION
# ================================================================

function optimise_acceleration(
    programme;
    steps=20
)

    best_cost =
        Inf

    best_time =
        Inf

    best_fraction =
        0.0


    for x in
        range(
            0.0,
            1.0,
            length=steps
        )

        total_cost =
            0.0

        total_time =
            0.0


        for package in
            programme.packages

            total_cost +=
                acceleration_cost(
                    package,
                    x
                )

            total_time +=
                acceleration_savings(
                    package,
                    x
                )

        end


        # Objective:
        # cost + monetary value
        # assigned to schedule delay.

        delay_penalty =
            total_time *
            2_000_000.0


        objective =
            total_cost +
            delay_penalty


        if objective <
           best_cost

            best_cost =
                objective

            best_time =
                total_time

            best_fraction =
                x

        end

    end


    return (
        acceleration=best_fraction,
        objective=best_cost,
        time_saved_months=best_time
    )

end


# ================================================================
# 16. SENSITIVITY ANALYSIS
# ================================================================

function sensitivity(
    programme
)

    baseline =
        programme_cost(
            programme
        )[:total]


    println()
    println(
        "COST SENSITIVITY"
    )

    println(
        "--------------------------------------------------------------"
    )


    for variable in
        [
            "Inflation",
            "Labour",
            "Materials",
            "Productivity"
        ]

        if variable == "Inflation"

            multiplier =
                1.20

        elseif variable == "Labour"

            multiplier =
                1.20

        elseif variable == "Materials"

            multiplier =
                1.20

        else

            multiplier =
                0.80

        end


        @printf(
            "%-15s +20%% shock → $%,15.2f\n",
            variable,
            baseline *
            multiplier
        )

    end

end


# ================================================================
# 17. EXAMPLE LARGE RAIL PROGRAMME
#
# Illustrative quantities only.
# ================================================================

packages = WorkPackage[

    WorkPackage(

        "CIV-001",
        "Guideway / Earthworks",
        "Civil",

        120.0,
        82.0,

        "route-km",

        CostRate(
            2_500_000,
            7_000_000,
            1_500_000
        ),

        48.0,
        0.95,
        0.035,

        0.12,
        0.08,
        0.06,
        0.15
    ),


    WorkPackage(

        "BRG-001",
        "Bridges / Viaducts",
        "Structures",

        85.0,
        55.0,

        "structure-km",

        CostRate(
            5_000_000,
            18_000_000,
            4_000_000
        ),

        60.0,
        0.90,
        0.035,

        0.14,
        0.10,
        0.07,
        0.20
    ),


    WorkPackage(

        "TRK-001",
        "High-Speed Track",
        "Rail",

        240.0,
        0.0,

        "track-km",

        CostRate(
            1_500_000,
            5_500_000,
            1_000_000
        ),

        36.0,
        1.00,
        0.035,

        0.10,
        0.07,
        0.05,
        0.15
    ),


    WorkPackage(

        "OCS-001",
        "Overhead Electrification",
        "Systems",

        240.0,
        0.0,

        "track-km",

        CostRate(
            1_000_000,
            3_500_000,
            800_000
        ),

        30.0,
        1.00,
        0.035,

        0.10,
        0.08,
        0.05,
        0.18
    ),


    WorkPackage(

        "SIG-001",
        "Train Control / Signalling",
        "Systems",

        240.0,
        0.0,

        "track-km",

        CostRate(
            800_000,
            2_500_000,
            300_000
        ),

        34.0,
        0.95,
        0.035,

        0.12,
        0.10,
        0.06,
        0.20
    ),


    WorkPackage(

        "STA-001",
        "Stations",
        "Buildings",

        10.0,
        3.0,

        "stations",

        CostRate(
            20_000_000,
            80_000_000,
            15_000_000
        ),

        48.0,
        0.90,
        0.035,

        0.15,
        0.10,
        0.07,
        0.20
    ),


    WorkPackage(

        "SUB-001",
        "Traction Power Substations",
        "Power",

        12.0,
        2.0,

        "substations",

        CostRate(
            8_000_000,
            30_000_000,
            5_000_000
        ),

        42.0,
        0.90,
        0.035,

        0.12,
        0.09,
        0.06,
        0.18
    )
]


# ================================================================
# 18. RISK REGISTER
# ================================================================

risks = Risk[

    Risk(
        "Utility relocation",
        0.35,
        10_000_000,
        35_000_000,
        100_000_000
    ),

    Risk(
        "Design interface changes",
        0.30,
        5_000_000,
        25_000_000,
        80_000_000
    ),

    Risk(
        "Material escalation",
        0.45,
        15_000_000,
        60_000_000,
        150_000_000
    ),

    Risk(
        "Contractor productivity",
        0.40,
        10_000_000,
        40_000_000,
        120_000_000
    ),

    Risk(
        "Environmental / permitting",
        0.20,
        5_000_000,
        20_000_000,
        75_000_000
    ),

    Risk(
        "Systems integration",
        0.25,
        10_000_000,
        50_000_000,
        200_000_000
    )
]


# ================================================================
# 19. CREATE PROGRAMME
# ================================================================

programme =
    Programme(

        "CALIFORNIA HSR",
        48,
        2026,

        0.035,

        packages,
        risks
    )


# ================================================================
# 20. RUN ENGINE
# ================================================================

print_cost_report(
    programme
)

package_report(
    programme
)


# ================================================================
# 21. RISK SIMULATION
# ================================================================

println()
println(
    "Running Monte Carlo..."
)

outcomes =
    monte_carlo(
        programme,
        iterations=50_000
    )


monte_carlo_report(
    outcomes
)


# ================================================================
# 22. ACCELERATION
# ================================================================

acceleration =
    optimise_acceleration(
        programme
    )


println()
println(
    "ACCELERATION OPTIMISATION"
)

println(
    "--------------------------------------------------------------"
)

@printf(
    "Recommended acceleration: %.1f%%\n",
    acceleration.acceleration * 100
)

@printf(
    "Schedule saving:          %.1f months\n",
    acceleration.time_saved_months
)

@printf(
    "Objective value:          $%,.2f\n",
    acceleration.objective
)


# ================================================================
# 23. SENSITIVITY
# ================================================================

sensitivity(
    programme
)


println()
println(
    "=============================================================="
)

println(
    "CALRAIL COST ENGINE COMPLETE"
)

println(
    "=============================================================="
)
