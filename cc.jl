using JuMP
using HiGHS

# ============================================================
# CO₂ GENERATION + CARBON CAPTURE OPTIMIZER
# ============================================================

model = Model(HiGHS.Optimizer)

# ------------------------------------------------------------
# Parameters
# ------------------------------------------------------------

# Maximum process-gas flow (kg/hour)
MAX_GAS_FLOW = 100_000.0

# Maximum CO₂ concentration permitted in simulated/process gas
MAX_CO2_FRACTION = 0.20

# Capture plant capacity (kg CO₂/hour)
MAX_CAPTURE = 25_000.0

# Maximum energy available to the process (kWh/hour)
MAX_ENERGY = 50_000.0

# Energy required per kg CO₂ processed
ENERGY_PER_KG_CO2 = 0.35

# Energy required to move/process gas
ENERGY_PER_KG_GAS = 0.015

# ------------------------------------------------------------
# Decision variables
# ------------------------------------------------------------

# Total process gas
@variable(model, 0 <= gas_flow <= MAX_GAS_FLOW)

# CO₂ fraction of process gas
@variable(model, 0 <= co2_fraction <= MAX_CO2_FRACTION)

# CO₂ entering capture system
@variable(model, 0 <= co2_feed <= MAX_CAPTURE)

# CO₂ captured
@variable(model, 0 <= co2_captured <= MAX_CAPTURE)

# ------------------------------------------------------------
# Mass balance
# ------------------------------------------------------------

@constraint(
    model,
    co2_feed == gas_flow * co2_fraction
)

# Capture cannot exceed available CO₂
@constraint(
    model,
    co2_captured <= co2_feed
)

# ------------------------------------------------------------
# Energy constraint
# ------------------------------------------------------------

@constraint(
    model,
    ENERGY_PER_KG_CO2 * co2_feed +
    ENERGY_PER_KG_GAS * gas_flow
    <= MAX_ENERGY
)

# ------------------------------------------------------------
# Objective
# ------------------------------------------------------------

# Maximize useful CO₂ supplied to the capture process
@objective(
    model,
    Max,
    co2_feed
)

optimize!(model)

# ------------------------------------------------------------
# Results
# ------------------------------------------------------------

println("\n===== CO₂ CAPTURE SYSTEM =====")

println(
    "Process gas: ",
    round(value(gas_flow), digits=2),
    " kg/h"
)

println(
    "CO₂ concentration: ",
    round(value(co2_fraction) * 100, digits=2),
    "%"
)

println(
    "CO₂ feed: ",
    round(value(co2_feed), digits=2),
    " kg/h"
)

println(
    "Potential capture: ",
    round(value(co2_captured), digits=2),
    " kg/h"
)

println(
    "Energy consumption: ",
    round(
        ENERGY_PER_KG_CO2 * value(co2_feed) +
        ENERGY_PER_KG_GAS * value(gas_flow),
        digits=2
    ),
    " kWh/h"
)
