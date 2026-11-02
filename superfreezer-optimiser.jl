```julia
# ============================================================
# SUPERMARKET FREEZER OPTIMISATION ENGINE
# Predictive Thermal Control & Energy Management
#
# Language: Julia
# Solver: HiGHS
# Framework: JuMP
# Horizon: 24 hours
# Resolution: 15 minutes
#
# Features:
# - Multi-freezer optimisation
# - Predictive temperature control
# - Dynamic electricity tariffs
# - Compressor efficiency optimisation
# - Defrost scheduling
# - Energy consumption reporting
# ============================================================

using JuMP
using HiGHS
import MathOptInterface as MOI
using Statistics
using Printf

# ============================================================
# 1. SYSTEM CONFIGURATION
# ============================================================

const INTERVAL = 0.25
const HOURS = 24
const N = Int(HOURS / INTERVAL)

# Example supermarket freezer installation

struct Freezer

    name::String

    target_temp::Float64
    min_temp::Float64
    max_temp::Float64

    thermal_capacity::Float64
    heat_transfer::Float64

    max_power::Float64
    cop::Float64

end

freezers = [

    Freezer(
        "Frozen Food Cabinet 1",
        -21.0, -24.0, -18.0,
        12.0, 0.12,
        8.0, 2.2
    ),

    Freezer(
        "Frozen Food Cabinet 2",
        -21.0, -24.0, -18.0,
        14.0, 0.14,
        9.0, 2.3
    ),

    Freezer(
        "Frozen Food Cabinet 3",
        -20.0, -23.0, -18.0,
        10.0, 0.10,
        7.0, 2.1
    ),

    Freezer(
        "Cold Storage Room",
        -20.0, -23.0, -18.0,
        35.0, 0.22,
        15.0, 2.5
    )

]

F = length(freezers)

# ============================================================
# 2. ELECTRICITY AND ENVIRONMENT DATA
# ============================================================

ambient = [
    23.0 + 4.0 * sin(2π * (k * INTERVAL - 8) / 24)
    for k in 1:N
]

# Electricity tariff (£/kWh)

prices = [

    (k * INTERVAL >= 16 &&
     k * INTERVAL <= 21) ? 0.32 :

    (k * INTERVAL >= 0 &&
     k * INTERVAL <= 6) ? 0.11 :

    0.19

    for k in 1:N
]

# ============================================================
# 3. HEAT LOAD PROFILE
# ============================================================

heat_load = zeros(F, N)

for f in 1:F
    for k in 1:N

        hour = k * INTERVAL

        # Increased thermal load during supermarket activity

        if 8 <= hour <= 10 || 16 <= hour <= 19

            heat_load[f,k] = 1.5

        else

            heat_load[f,k] = 0.4

        end

    end
end

# ============================================================
# 4. DEFROST SCHEDULING
# ============================================================

# Example scheduled defrost intervals.
# Defrost is represented as additional thermal load.
#
# Actual equipment should use its manufacturer's
# defrost controls and verified safety logic.

defrost_load = zeros(F, N)

for f in 1:F

    # Example defrost at 03:00

    k = Int(3 / INTERVAL) + 1

    defrost_load[f,k] = 3.0

end

# ============================================================
# 5. OPTIMISATION MODEL
# ============================================================

function optimise_supermarket(
    freezers,
    ambient,
    prices,
    heat_load,
    defrost_load
)

    F = length(freezers)
    N = length(prices)

    model = Model(HiGHS.Optimizer)

    set_silent(model)

    # --------------------------------------------------------
    # Decision variables
    # --------------------------------------------------------

    @variable(
        model,
        temperature[1:F,1:N+1]
    )

    @variable(
        model,
        compressor[1:F,1:N] >= 0
    )

    @variable(
        model,
        temperature_deviation[1:F,1:N] >= 0
    )

    @variable(
        model,
        compressor_ramp[1:F,1:N] >= 0
    )

    # --------------------------------------------------------
    # Initial temperatures
    # --------------------------------------------------------

    initial = [-21.0, -21.0, -20.0, -20.0]

    for f in 1:F

        @constraint(
            model,
            temperature[f,1] == initial[f]
        )

    end

    # --------------------------------------------------------
    # Temperature limits
    # --------------------------------------------------------

    for f in 1:F

        for k in 1:N+1

            @constraint(
                model,
                temperature[f,k] >= freezers[f].min_temp
            )

            @constraint(
                model,
                temperature[f,k] <= freezers[f].max_temp
            )

        end

    end

    # --------------------------------------------------------
    # Compressor power limits
    # --------------------------------------------------------

    for f in 1:F

        for k in 1:N

            @constraint(
                model,
                compressor[f,k] <= freezers[f].max_power
            )

        end

    end

    # --------------------------------------------------------
    # THERMAL DYNAMICS
    # --------------------------------------------------------

    for f in 1:F

        freezer = freezers[f]

        for k in 1:N

            total_heat =
                heat_load[f,k] +
                defrost_load[f,k]

            @constraint(
                model,

                temperature[f,k+1] ==

                temperature[f,k] +

                (INTERVAL / freezer.thermal_capacity) *

                (
                    freezer.heat_transfer *
                    (ambient[k] - temperature[f,k])

                    +

                    total_heat

                    -

                    freezer.cop *
                    compressor[f,k]
                )

            )

        end

    end

    # --------------------------------------------------------
    # TEMPERATURE TARGET
    # --------------------------------------------------------

    for f in 1:F

        for k in 1:N

            @constraint(
                model,

                temperature_deviation[f,k] >=

                temperature[f,k] -
                freezers[f].target_temp

            )

            @constraint(
                model,

                temperature_deviation[f,k] >=

                freezers[f].target_temp -
                temperature[f,k]

            )

        end

    end

    # --------------------------------------------------------
    # COMPRESSOR RAMPING
    # --------------------------------------------------------

    for f in 1:F

        @constraint(
            model,
            compressor_ramp[f,1] >= compressor[f,1]
        )

        for k in 2:N

            @constraint(
                model,

                compressor_ramp[f,k] >=

                compressor[f,k] -
                compressor[f,k-1]

            )

            @constraint(
                model,

                compressor_ramp[f,k] >=

                compressor[f,k-1] -
                compressor[f,k]

            )

        end

    end

    # --------------------------------------------------------
    # OPTIMISATION OBJECTIVE
    # --------------------------------------------------------

    energy_cost = sum(

        prices[k] *
        compressor[f,k] *
        INTERVAL

        for f in 1:F, k in 1:N

    )

    temperature_cost = 0.5 * sum(
        temperature_deviation[f,k]
        for f in 1:F, k in 1:N
    )

    compressor_cost = 0.03 * sum(
        compressor_ramp[f,k]
        for f in 1:F, k in 1:N
    )

    @objective(
        model,
        Min,

        energy_cost +
        temperature_cost +
        compressor_cost

    )

    # --------------------------------------------------------
    # SOLVE
    # --------------------------------------------------------

    optimize!(model)

    if termination_status(model) != MOI.OPTIMAL

        error(
            "Optimisation failed: " *
            string(termination_status(model))
        )

    end

    # --------------------------------------------------------
    # RETURN RESULTS
    # --------------------------------------------------------

    return (

        temperature = value.(temperature),

        compressor = value.(compressor),

        energy_cost = value(energy_cost),

        total_energy = sum(
            value(compressor[f,k]) * INTERVAL
            for f in 1:F, k in 1:N
        ),

        objective = objective_value(model)

    )

end

# ============================================================
# 6. RUN THE OPTIMISATION
# ============================================================

results = optimise_supermarket(
    freezers,
    ambient,
    prices,
    heat_load,
    defrost_load
)

# ============================================================
# 7. PERFORMANCE REPORT
# ============================================================

println()
println("============================================")
println(" SUPERMARKET REFRIGERATION OPTIMISATION")
println("============================================")

println(
    "Total electricity: ",
    round(results.total_energy, digits=2),
    " kWh"
)

println(
    "Total electricity cost: £",
    round(results.energy_cost, digits=2)
)

println()

for f in 1:F

    println("--------------------------------------------")

    println(freezers[f].name)

    println(
        "Average temperature: ",
        round(
            mean(results.temperature[f,1:N]),
            digits=2
        ),
        " °C"
    )

    println(
        "Minimum temperature: ",
        round(
            minimum(results.temperature[f,:]),
            digits=2
        ),
        " °C"
    )

    println(
        "Maximum temperature: ",
        round(
            maximum(results.temperature[f,:]),
            digits=2
        ),
        " °C"
    )

    println(
        "Energy consumption: ",
        round(
            sum(results.compressor[f,:]) * INTERVAL,
            digits=2
        ),
        " kWh"
    )

end

# ============================================================
# 8. HOURLY COMPRESSOR CONTROL SCHEDULE
# ============================================================

println()
println("HOURLY COMPRESSOR SCHEDULE")
println("============================================")

for hour in 1:HOURS

    k = Int((hour-1) / INTERVAL) + 1

    println()
    println("Hour: ", hour)

    for f in 1:F

        @printf(
            "%-25s | Temp: %7.2f C | Power: %6.2f kW\n",
            freezers[f].name,
            results.temperature[f,k],
            results.compressor[f,k]
        )

    end

end

println()
println("OPTIMISATION COMPLETE")
```

