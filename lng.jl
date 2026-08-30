```julia
# ================================================================
# LNGCORE
# Julia LNG Combustion & Energy Optimisation Engine
#
# Conceptual engineering simulator
#
# Models:
#   LNG / methane fuel
#   Air supply
#   Equivalence ratio
#   Combustion efficiency
#   Heat release
#   Adiabatic temperature estimate
#   Exhaust CO2 / H2O / O2
#   Thermal efficiency
#   Fuel consumption
#   Heat exchanger losses
#   Combustion optimisation
#
# This is NOT a certified burner-control algorithm.
# Real combustion equipment requires validated chemistry,
# instrumentation, flame detection, interlocks and independent
# safety systems.
# ================================================================

using Printf
using Statistics

# ================================================================
# CONSTANTS
# ================================================================

const R = 8.314462618          # J/mol/K
const MW_CH4 = 0.016043        # kg/mol
const MW_O2  = 0.031998
const MW_N2  = 0.028014
const MW_CO2 = 0.0440095
const MW_H2O = 0.01801528

const AIR_O2_MOLAR = 0.21
const AIR_N2_MOLAR = 0.79

const LHV_LNG = 50.0e6         # J/kg, representative LNG value

const STOICH_AFR =
    17.2                       # kg air / kg methane

const T_AMBIENT = 298.15       # K

# ================================================================
# LNG FUEL
# ================================================================

struct LNGFuel

    methane_fraction::Float64

    ethane_fraction::Float64

    nitrogen_fraction::Float64

    lower_heating_value_Jkg::Float64
end


const LNG = LNGFuel(

    0.90,

    0.07,

    0.03,

    LHV_LNG
)

# ================================================================
# COMBUSTOR
# ================================================================

mutable struct Combustor

    fuel_flow_kg_s::Float64

    air_flow_kg_s::Float64

    pressure_Pa::Float64

    inlet_temperature_K::Float64

    target_temperature_K::Float64

    combustion_efficiency::Float64

    heat_loss_fraction::Float64

    flame_temperature_K::Float64

    thermal_power_MW::Float64

    useful_power_MW::Float64

    co2_kg_s::Float64

    h2o_kg_s::Float64

    o2_excess_fraction::Float64

    stable::Bool
end

# ================================================================
# CREATE COMBUSTOR
# ================================================================

function create_combustor()

    return Combustor(

        0.10,       # LNG flow

        1.72,       # air flow

        101325.0,   # pressure

        298.15,     # inlet temperature

        1800.0,     # target

        0.98,       # combustion efficiency

        0.08,       # heat losses

        0.0,

        0.0,

        0.0,

        0.0,

        0.0,

        0.0,

        false
    )
end

# ================================================================
# STOICHIOMETRIC AIR/FUEL
# ================================================================

function stoichiometric_air_fuel()

    return STOICH_AFR
end

# ================================================================
# AIR/FUEL RATIO
# ================================================================

function air_fuel_ratio(
    c::Combustor
)

    return (
        c.air_flow_kg_s /
        max(
            c.fuel_flow_kg_s,
            1e-12
        )
    )
end

# ================================================================
# EQUIVALENCE RATIO
#
# φ < 1 : lean
# φ = 1 : stoichiometric
# φ > 1 : rich
# ================================================================

function equivalence_ratio(
    c::Combustor
)

    actual =
        air_fuel_ratio(c)

    return (
        stoichiometric_air_fuel() /
        actual
    )
end

# ================================================================
# COMBUSTION POWER
# ================================================================

function fuel_energy_rate(
    c::Combustor,
    fuel::LNGFuel
)

    return (
        c.fuel_flow_kg_s *
        fuel.lower_heating_value_Jkg
    )
end

# ================================================================
# APPROXIMATE ADIABATIC FLAME TEMPERATURE
#
# This is a reduced-order engineering approximation.
#
# Detailed equilibrium / finite-rate chemistry should be used
# for high-fidelity predictions.
# ================================================================

function estimate_flame_temperature(
    c::Combustor,
    fuel::LNGFuel
)

    ϕ =
        equivalence_ratio(c)

    T_in =
        c.inlet_temperature_K

    # Approximate maximum temperature around
    # moderately lean combustion.

    ideal_rise =
        2050.0 *
        exp(
            -1.8 *
            (ϕ - 0.95)^2
        )

    # Inlet temperature contribution

    T_ideal =
        T_in +
        ideal_rise

    # Efficiency

    T_after_efficiency =
        T_in +
        (
            T_ideal -
            T_in
        ) *
        c.combustion_efficiency

    # Heat losses

    T_final =
        T_in +
        (
            T_after_efficiency -
            T_in
        ) *
        (
            1.0 -
            c.heat_loss_fraction
        )

    return T_final
end

# ================================================================
# EXHAUST MASS BALANCE
# ================================================================

function exhaust_products(
    c::Combustor,
    fuel::LNGFuel
)

    fuel =
        c.fuel_flow_kg_s *
        fuel.methane_fraction

    # CH4 + 2O2 -> CO2 + 2H2O

    methane_mol_s =
        fuel /
        MW_CH4

    co2_mol_s =
        methane_mol_s *
        c.combustion_efficiency

    h2o_mol_s =
        2.0 *
        co2_mol_s

    co2_mass =
        co2_mol_s *
        MW_CO2

    h2o_mass =
        h2o_mol_s *
        MW_H2O

    return (
        co2_mass,
        h2o_mass
    )
end

# ================================================================
# EXCESS OXYGEN
# ================================================================

function excess_oxygen(
    c::Combustor
)

    actual =
        air_fuel_ratio(c)

    return max(
        0.0,
        (
            actual -
            STOICH_AFR
        ) /
        STOICH_AFR
    )
end

# ================================================================
# COMBUSTION STABILITY
# ================================================================

function combustion_stability(
    c::Combustor
)

    ϕ =
        equivalence_ratio(c)

    # Reduced-order stability envelope

    if ϕ < 0.45
        return false
    end

    if ϕ > 1.40
        return false
    end

    if c.combustion_efficiency <
       0.85

        return false
    end

    return true
end

# ================================================================
# HEAT OUTPUT
# ================================================================

function calculate_heat_output!(
    c::Combustor,
    fuel::LNGFuel
)

    fuel_power =
        fuel_energy_rate(
            c,
            fuel
        )

    c.thermal_power_MW =
        fuel_power /
        1e6 *
        c.combustion_efficiency

    c.useful_power_MW =
        c.thermal_power_MW *
        (
            1.0 -
            c.heat_loss_fraction
        )

    return c.useful_power_MW
end

# ================================================================
# UPDATE COMBUSTOR
# ================================================================

function update!(
    c::Combustor,
    fuel::LNGFuel
)

    c.flame_temperature_K =
        estimate_flame_temperature(
            c,
            fuel
        )

    calculate_heat_output!(
        c,
        fuel
    )

    co2,
    h2o =
        exhaust_products(
            c,
            fuel
        )

    c.co2_kg_s =
        co2

    c.h2o_kg_s =
        h2o

    c.o2_excess_fraction =
        excess_oxygen(c)

    c.stable =
        combustion_stability(c)

    return c
end

# ================================================================
# PERFORMANCE REPORT
# ================================================================

function report(
    c::Combustor
)

    println()
    println(
        "================================================"
    )

    println(
        " LNGCORE COMBUSTION ENGINE"
    )

    println(
        "================================================"
    )

    @printf(
        "LNG flow:              %.4f kg/s\n",
        c.fuel_flow_kg_s
    )

    @printf(
        "Air flow:              %.4f kg/s\n",
        c.air_flow_kg_s
    )

    @printf(
        "Air/Fuel ratio:        %.3f\n",
        air_fuel_ratio(c)
    )

    @printf(
        "Equivalence ratio:     %.4f\n",
        equivalence_ratio(c)
    )

    @printf(
        "Flame temperature:     %.1f K\n",
        c.flame_temperature_K
    )

    @printf(
        "Thermal power:         %.3f MW\n",
        c.thermal_power_MW
    )

    @printf(
        "Useful heat:           %.3f MW\n",
        c.useful_power_MW
    )

    @printf(
        "CO₂ production:        %.5f kg/s\n",
        c.co2_kg_s
    )

    @printf(
        "H₂O production:        %.5f kg/s\n",
        c.h2o_kg_s
    )

    @printf(
        "Excess O₂ fraction:    %.3f\n",
        c.o2_excess_fraction
    )

    println(
        "Combustion stable:     ",
        c.stable
    )

    println(
        "================================================"
    )
end

# ================================================================
# PARAMETRIC OPTIMISATION
#
# Search across fuel/air ratios for useful thermal performance.
# ================================================================

struct OptimisationResult

    fuel_flow::Float64

    air_flow::Float64

    equivalence_ratio::Float64

    flame_temperature::Float64

    useful_power_MW::Float64

    score::Float64
end


function optimise_combustion(

    fuel_flow::Float64,

    target_temperature::Float64

)

    best =
        nothing

    best_score =
        Inf

    # Search across air flow

    for air_flow in
        range(
            fuel_flow * 8.0,
            fuel_flow * 30.0,
            length=250
        )

        c =
            create_combustor()

        c.fuel_flow_kg_s =
            fuel_flow

        c.air_flow_kg_s =
            air_flow

        c.target_temperature_K =
            target_temperature

        update!(
            c,
            LNG
        )

        if !c.stable
            continue
        end

        # Temperature tracking

        temperature_error =
            abs(
                c.flame_temperature_K -
                target_temperature
            )

        # Penalise excessive air

        excess_air_penalty =
            max(
                0.0,
                air_fuel_ratio(c) -
                22.0
            ) *
            10.0

        score =
            temperature_error +
            excess_air_penalty

        if score <
           best_score

            best_score =
                score

            best =
                OptimisationResult(

                    fuel_flow,

                    air_flow,

                    equivalence_ratio(c),

                    c.flame_temperature_K,

                    c.useful_power_MW,

                    score
                )
        end
    end

    return best
end

# ================================================================
# FUEL-RATE SWEEP
# ================================================================

function fuel_sweep()

    println()
    println(
        "================================================"
    )

    println(
        " LNG THERMAL POWER SWEEP"
    )

    println(
        "================================================"
    )

    println(
        "Fuel kg/s | Power MW | Flame K | φ"
    )

    for fuel_flow in
        range(
            0.02,
            0.50,
            length=20
        )

        c =
            create_combustor()

        c.fuel_flow_kg_s =
            fuel_flow

        c.air_flow_kg_s =
            fuel_flow *
            17.2

        update!(
            c,
            LNG
        )

        @printf(
            "%8.3f | %8.3f | %8.1f | %5.3f\n",

            fuel_flow,

            c.useful_power_MW,

            c.flame_temperature_K,

            equivalence_ratio(c)
        )
    end
end

# ================================================================
# RUN
# ================================================================

println(
    "Starting LNGCORE..."
)

combustor =
    create_combustor()

update!(
    combustor,
    LNG
)

report(
    combustor
)

# ------------------------------------------------
# Optimise for a desired thermal regime
# ------------------------------------------------

println()

println(
    "Searching for an optimised air/fuel condition..."
)

result =
    optimise_combustion(
        0.10,
        1800.0
    )

println()

println(
    "OPTIMUM"
)

if result !== nothing

    @printf(
        "Fuel flow:          %.4f kg/s\n",
        result.fuel_flow
    )

    @printf(
        "Air flow:           %.4f kg/s\n",
        result.air_flow
    )

    @printf(
        "Equivalence ratio:  %.4f\n",
        result.equivalence_ratio
    )

    @printf(
        "Flame temperature:  %.1f K\n",
        result.flame_temperature
    )

    @printf(
        "Useful power:       %.3f MW\n",
        result.useful_power_MW
    )

    @printf(
        "Optimisation score: %.3f\n",
        result.score
    )

else

    println(
        "No feasible operating point found."
    )
end

# ------------------------------------------------
# Sweep
# ------------------------------------------------

fuel_sweep()
```

