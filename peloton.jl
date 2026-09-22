using .TreadOptimizer
using Dates

config =
    TreadConfig(

        1.0,
        12.5,

        0.0,
        12.5,

        0.3,
        1.0,

        5.0,

        0.01
    )


model =
    TreadMLModel(
        config
    )


state =
    TreadState(

        7.2,        # mph
        2.0,        # incline

        151.0,      # HR

        170.0,      # cadence

        8.33,       # pace

        1_200.0,    # elapsed

        2.8,        # km

        21.0,       # temperature

        now()
    )


target =
    WorkoutTarget(

        7.5,        # target speed

        3.0,        # target incline

        155.0,      # target HR

        0.65,       # target effort

        1_800.0
    )


result =
    control_cycle(
        model,
        state,
        target,
        config
    )


println(
    "Recommended speed: ",
    result.speed,
    " mph"
)

println(
    "Recommended incline: ",
    result.incline,
    "%"
)

println(
    "Predicted fatigue: ",
    result.predicted_fatigue
)











module GymRegenerativeBike

using Dates
using Statistics
using LinearAlgebra

export BikeConfig,
       RiderState,
       ElectricalState,
       EnergyLedger,
       BikeOptimizer,
       estimate_mechanical_power,
       estimate_electrical_power,
       optimize_resistance,
       update_energy!,
       financial_value,
       system_status


# ============================================================
# CONFIGURATION
# ============================================================

struct BikeConfig

    # Physical limits
    min_cadence::Float64
    max_cadence::Float64

    min_resistance::Float64
    max_resistance::Float64

    max_generator_power::Float64

    # Generator/converter
    generator_efficiency::Float64
    converter_efficiency::Float64
    inverter_efficiency::Float64

    # Electrical economics
    electricity_price_per_kwh::Float64

    # Control
    target_dc_voltage::Float64
    target_battery_soc::Float64

    # Thermal protection
    max_generator_temperature::Float64

end


# ============================================================
# RIDER STATE
# ============================================================

mutable struct RiderState

    cadence_rpm::Float64

    torque_nm::Float64

    resistance_level::Float64

    heart_rate::Float64

    elapsed_seconds::Float64

    body_mass_kg::Float64

end


# ============================================================
# ELECTRICAL STATE
# ============================================================

mutable struct ElectricalState

    generator_voltage::Float64
    generator_current::Float64

    dc_voltage::Float64
    dc_current::Float64

    battery_voltage::Float64
    battery_current::Float64

    battery_soc::Float64

    generator_temperature::Float64

end


# ============================================================
# ENERGY LEDGER
# ============================================================

mutable struct EnergyLedger

    mechanical_wh::Float64

    generator_wh::Float64

    converter_wh::Float64

    inverter_wh::Float64

    exported_wh::Float64

    grid_offset_wh::Float64

    financial_value_gbp::Float64

    operating_seconds::Float64

end


function EnergyLedger()

    return EnergyLedger(
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0
    )

end


# ============================================================
# OPTIMISER
# ============================================================

mutable struct BikeOptimizer

    current_resistance::Float64

    target_power_w::Float64

    target_voltage::Float64

    last_power_w::Float64

    ledger::EnergyLedger

end


function BikeOptimizer(
    target_power_w::Float64,
    target_voltage::Float64
)

    return BikeOptimizer(

        1.0,

        target_power_w,

        target_voltage,

        0.0,

        EnergyLedger()

    )

end


# ============================================================
# MECHANICAL POWER
#
# P = torque × angular velocity
#
# angular velocity =
# rpm × 2π / 60
# ============================================================

function estimate_mechanical_power(
    rider::RiderState
)

    angular_velocity =
        rider.cadence_rpm *
        2π /
        60.0

    power =
        rider.torque_nm *
        angular_velocity

    return max(
        power,
        0.0
    )

end


# ============================================================
# GENERATOR POWER
# ============================================================

function estimate_generator_power(
    mechanical_power::Float64,
    config::BikeConfig
)

    return min(

        mechanical_power *
        config.generator_efficiency,

        config.max_generator_power

    )

end


# ============================================================
# ELECTRICAL POWER
# ============================================================

function estimate_electrical_power(
    mechanical_power::Float64,
    config::BikeConfig
)

    generator_power =
        estimate_generator_power(
            mechanical_power,
            config
        )

    converter_power =
        generator_power *
        config.converter_efficiency

    inverter_power =
        converter_power *
        config.inverter_efficiency

    return (

        generator=generator_power,

        dc=converter_power,

        usable=inverter_power

    )

end


# ============================================================
# EFFICIENCY MODEL
# ============================================================

function system_efficiency(
    config::BikeConfig
)

    return (

        config.generator_efficiency *

        config.converter_efficiency *

        config.inverter_efficiency

    )

end


# ============================================================
# POWER TARGET
#
# Estimate how much electrical power can be harvested without
# simply forcing maximum resistance on the rider.
# ============================================================

function calculate_target_power(

    rider::RiderState,

    config::BikeConfig

)

    mechanical =
        estimate_mechanical_power(
            rider
        )

    electrical =
        estimate_electrical_power(
            mechanical,
            config
        )

    # Avoid requesting more generation than the rider
    # is currently supplying.

    return min(

        electrical.usable,

        config.max_generator_power

    )

end


# ============================================================
# RESISTANCE → TORQUE MODEL
#
# Simplified engineering model.
# A real machine would calibrate this against measured
# torque/cadence/power curves.
# ============================================================

function resistance_torque(
    resistance::Float64,
    cadence::Float64
)

    cadence_factor =
        max(
            cadence / 60.0,
            0.1
        )

    return (

        resistance *
        3.0 *
        cadence_factor

    )

end


# ============================================================
# PREDICT POWER AT A RESISTANCE
# ============================================================

function predicted_power_at_resistance(

    resistance::Float64,

    cadence::Float64,

    config::BikeConfig

)

    torque =
        resistance_torque(
            resistance,
            cadence
        )

    angular_velocity =
        cadence *
        2π /
        60.0

    mechanical_power =
        torque *
        angular_velocity

    electrical =
        estimate_electrical_power(
            mechanical_power,
            config
        )

    return electrical.usable

end


# ============================================================
# RESISTANCE OPTIMISER
#
# Searches for the resistance producing the desired
# electrical output.
# ============================================================

function optimize_resistance(

    rider::RiderState,

    optimizer::BikeOptimizer,

    config::BikeConfig

)

    target =
        optimizer.target_power_w

    best_resistance =
        rider.resistance_level

    best_error =
        Inf


    candidates =
        range(

            config.min_resistance,

            config.max_resistance,

            length=50

        )


    for resistance in candidates

        predicted =
            predicted_power_at_resistance(

                resistance,

                rider.cadence_rpm,

                config

            )

        error =
            abs(
                predicted -
                target
            )

        if error <
           best_error

            best_error =
                error

            best_resistance =
                resistance

        end

    end


    optimizer.current_resistance =
        best_resistance


    return (

        resistance =
            best_resistance,

        predicted_power =
            predicted_power_at_resistance(

                best_resistance,

                rider.cadence_rpm,

                config
            ),

        error =
            best_error

    )

end


# ============================================================
# ENERGY ACCOUNTING
# ============================================================

function update_energy!(

    optimizer::BikeOptimizer,

    rider::RiderState,

    config::BikeConfig,

    timestep_seconds::Float64

)

    mechanical_power =
        estimate_mechanical_power(
            rider
        )

    electrical =
        estimate_electrical_power(

            mechanical_power,

            config

        )


    # Convert W × seconds → Wh

    mechanical_wh =
        mechanical_power *
        timestep_seconds /
        3600.0

    generator_wh =
        electrical.generator *
        timestep_seconds /
        3600.0

    dc_wh =
        electrical.dc *
        timestep_seconds /
        3600.0

    usable_wh =
        electrical.usable *
        timestep_seconds /
        3600.0


    ledger =
        optimizer.ledger


    ledger.mechanical_wh +=
        mechanical_wh

    ledger.generator_wh +=
        generator_wh

    ledger.converter_wh +=
        dc_wh

    ledger.inverter_wh +=
        usable_wh

    ledger.exported_wh +=
        usable_wh

    ledger.operating_seconds +=
        timestep_seconds


    # £ value

    ledger.financial_value_gbp =

        (
            ledger.exported_wh /
            1000.0
        ) *

        config.electricity_price_per_kwh


    optimizer.last_power_w =
        electrical.usable


    return ledger

end


# ============================================================
# FINANCIAL VALUE
# ============================================================

function financial_value(

    ledger::EnergyLedger,

    electricity_price_per_kwh::Float64

)

    kwh =
        ledger.exported_wh /
        1000.0

    return (

        kwh=kwh,

        gbp=
            kwh *
            electricity_price_per_kwh

    )

end


# ============================================================
# CO2 / ENERGY METRICS
# ============================================================

function system_status(

    optimizer::BikeOptimizer,

    config::BikeConfig

)

    ledger =
        optimizer.ledger

    kwh =
        ledger.exported_wh /
        1000.0

    value =
        financial_value(
            ledger,
            config.electricity_price_per_kwh
        )

    return (

        electrical_kwh =
            kwh,

        value_gbp =
            value.gbp,

        average_power_w =
            if ledger.operating_seconds > 0

                ledger.exported_wh /
                (
                    ledger.operating_seconds /
                    3600.0
                )

            else

                0.0

            end,

        efficiency =
            system_efficiency(config)

    )

end


end



using .GymRegenerativeBike

config = BikeConfig(

    40.0,       # minimum cadence
    130.0,      # maximum cadence

    1.0,        # minimum resistance
    20.0,       # maximum resistance

    300.0,      # generator limit

    0.90,       # generator efficiency
    0.95,       # converter efficiency
    0.95,       # inverter efficiency

    0.2632,      # £/kWh

    48.0,        # target DC voltage
    0.80,        # target battery SOC

    80.0         # maximum generator temperature
)


optimizer =
    BikeOptimizer(
        120.0,
        48.0
    )


rider =
    RiderState(

        85.0,       # cadence RPM

        20.0,       # torque Nm

        8.0,        # resistance

        145.0,      # heart rate

        1800.0,     # elapsed seconds

        80.0        # body mass
    )
    
    
    
    mechanical =
    estimate_mechanical_power(
        rider
    )

println(
    "Mechanical power: ",
    round(mechanical, digits=1),
    " W"
)




result =
    optimize_resistance(
        rider,
        optimizer,
        config
    )

println(
    "Optimal resistance: ",
    round(
        result.resistance,
        digits=2
    )
)

println(
    "Predicted electrical output: ",
    round(
        result.predicted_power,
        digits=1
    ),
    " W"
)


for second in 1:3600

    update_energy!(
        optimizer,
        rider,
        config,
        1.0
    )

end

status =
    system_status(
        optimizer,
        config
    )

println(
    "Energy recovered: ",
    round(
        status.electrical_kwh,
        digits=3
    ),
    " kWh"
)

println(
    "Electricity value: £",
    round(
        status.value_gbp,
        digits=2
    )
)




But:

Strategy B

180 W generation
40 minute session

gives:

$$ 180 \times 0.667 = 120Wh $$

So they're equal.

If B actually causes the rider to quit after 30 minutes:

$$ 180 \times 0.5 = 90Wh $$

You've lost 25% of the energy.

3. Julia implementation

I'd build the core like this:

module WeightedRegenOptimizer

using Statistics

export RiderState,
       SystemState,
       EconomicState,
       OptimizerConfig,
       OptimizationResult,
       weighted_objective,
       optimise_braking,
       update_economics

# ---------------------------------------------------------
# Rider
# ---------------------------------------------------------

struct RiderState
    cadence_rpm::Float64
    rider_power_w::Float64
    heart_rate_bpm::Float64
    resistance::Float64
    fatigue::Float64
    workout_target_w::Float64
    session_minutes_remaining::Float64
end

# ---------------------------------------------------------
# Electrical system
# ---------------------------------------------------------

struct SystemState
    generator_rpm::Float64
    generator_efficiency::Float64
    converter_efficiency::Float64
    inverter_efficiency::Float64

    generator_temperature_c::Float64
    max_temperature_c::Float64

    battery_soc::Float64
    battery_max_soc::Float64

    max_generator_power_w::Float64
end

# ---------------------------------------------------------
# Economics
# ---------------------------------------------------------

struct EconomicState
    electricity_price_gbp_kwh::Float64
    export_price_gbp_kwh::Float64

    grid_import_avoided::Bool
    battery_value_multiplier::Float64
end

# ---------------------------------------------------------
# Optimiser weights
# ---------------------------------------------------------

struct OptimizerConfig

    energy_weight::Float64
    economic_weight::Float64

    rider_penalty_weight::Float64
    fatigue_penalty_weight::Float64

    thermal_penalty_weight::Float64
    discomfort_penalty_weight::Float64

    min_cadence_rpm::Float64
    max_cadence_rpm::Float64

    max_extra_resistance_w::Float64

    optimisation_resolution::Int
end

# ---------------------------------------------------------
# Result
# ---------------------------------------------------------

struct OptimizationResult

    braking_power_w::Float64
    generated_power_w::Float64

    recovered_energy_wh::Float64
    economic_value_gbp::Float64

    rider_penalty::Float64
    fatigue_penalty::Float64
    thermal_penalty::Float64
    discomfort_penalty::Float64

    objective_value::Float64
end


# ---------------------------------------------------------
# System efficiency
# ---------------------------------------------------------

function total_efficiency(sys::SystemState)

    return sys.generator_efficiency *
           sys.converter_efficiency *
           sys.inverter_efficiency

end


# ---------------------------------------------------------
# Generator output
# ---------------------------------------------------------

function generated_power(
    mechanical_power::Float64,
    sys::SystemState
)

    η = total_efficiency(sys)

    electrical = mechanical_power * η

    return min(
        electrical,
        sys.max_generator_power_w
    )

end


# ---------------------------------------------------------
# Economic value
# ---------------------------------------------------------

function energy_value(
    energy_wh::Float64,
    econ::EconomicState
)

    kwh = energy_wh / 1000.0

    if econ.grid_import_avoided

        return kwh *
               econ.electricity_price_gbp_kwh *
               econ.battery_value_multiplier

    else

        return kwh *
               econ.export_price_gbp_kwh

    end

end


# ---------------------------------------------------------
# Rider penalty
# ---------------------------------------------------------

function rider_penalty(
    braking_power::Float64,
    rider::RiderState
)

    relative =
        braking_power /
        max(rider.rider_power_w, 1.0)

    return relative^2

end


# ---------------------------------------------------------
# Fatigue penalty
# ---------------------------------------------------------

function fatigue_penalty(
    braking_power::Float64,
    rider::RiderState
)

    fatigue =
        clamp(rider.fatigue, 0.0, 1.0)

    load =
        braking_power /
        max(rider.workout_target_w, 1.0)

    return fatigue * load^2

end


# ---------------------------------------------------------
# Thermal penalty
# ---------------------------------------------------------

function thermal_penalty(
    sys::SystemState
)

    temperature_ratio =
        sys.generator_temperature_c /
        sys.max_temperature_c

    if temperature_ratio < 0.7
        return 0.0
    end

    return ((temperature_ratio - 0.7) / 0.3)^2

end


# ---------------------------------------------------------
# Discomfort penalty
# ---------------------------------------------------------

function discomfort_penalty(
    braking_power::Float64,
    rider::RiderState
)

    # Don't make the generator dominate
    # the rider's own exercise effort.

    ratio =
        braking_power /
        max(rider.rider_power_w, 1.0)

    if ratio <= 0.30
        return 0.0
    end

    return (ratio - 0.30)^2

end


# ---------------------------------------------------------
# Weighted objective
# ---------------------------------------------------------

function weighted_objective(
    braking_power::Float64,
    rider::RiderState,
    sys::SystemState,
    econ::EconomicState,
    cfg::OptimizerConfig,
    horizon_minutes::Float64
)

    electrical =
        generated_power(
            braking_power,
            sys
        )

    energy =
        electrical *
        horizon_minutes /
        60.0

    value =
        energy_value(
            energy,
            econ
        )

    rider_cost =
        rider_penalty(
            braking_power,
            rider
        )

    fatigue_cost =
        fatigue_penalty(
            braking_power,
            rider
        )

    thermal_cost =
        thermal_penalty(sys)

    discomfort_cost =
        discomfort_penalty(
            braking_power,
            rider
        )

    objective =
        cfg.energy_weight * energy +
        cfg.economic_weight * value -

        cfg.rider_penalty_weight *
        rider_cost -

        cfg.fatigue_penalty_weight *
        fatigue_cost -

        cfg.thermal_penalty_weight *
        thermal_cost -

        cfg.discomfort_penalty_weight *
        discomfort_cost

    return (
        objective,
        energy,
        value,
        rider_cost,
        fatigue_cost,
        thermal_cost,
        discomfort_cost
    )

end


# ---------------------------------------------------------
# Braking optimisation
# ---------------------------------------------------------

function optimise_braking(
    rider::RiderState,
    sys::SystemState,
    econ::EconomicState,
    cfg::OptimizerConfig;
    horizon_minutes=1.0
)

    maximum =
        min(
            cfg.max_extra_resistance_w,
            sys.max_generator_power_w
        )

    best_objective = -Inf
    best_result = nothing

    for braking in range(
        0.0,
        maximum,
        length=cfg.optimisation_resolution
    )

        # Cadence protection
        predicted_cadence =
            rider.cadence_rpm -
            0.08 * braking

        if predicted_cadence <
           cfg.min_cadence_rpm

            continue

        end

        if predicted_cadence >
           cfg.max_cadence_rpm

            continue

        end

        result =
            weighted_objective(
                braking,
                rider,
                sys,
                econ,
                cfg,
                horizon_minutes
            )

        (
            objective,
            energy,
            value,
            rider_cost,
            fatigue_cost,
            thermal_cost,
            discomfort_cost
        ) = result

        if objective > best_objective

            best_objective = objective

            best_result =
                OptimizationResult(
                    braking,
                    generated_power(
                        braking,
                        sys
                    ),
                    energy,
                    value,
                    rider_cost,
                    fatigue_cost,
                    thermal_cost,
                    discomfort_cost,
                    objective
                )

        end

    end

    return best_result

end


# ---------------------------------------------------------
# Dynamic economic weighting
# ---------------------------------------------------------

function update_economics(
    econ::EconomicState,
    battery_soc::Float64
)

    # Higher value when stored electricity
    # can directly displace grid consumption.

    multiplier =
        if battery_soc < 0.50
            1.20
        elseif battery_soc < 0.80
            1.00
        else
            0.65
        end

    return EconomicState(
        econ.electricity_price_gbp_kwh,
        econ.export_price_gbp_kwh,
        econ.grid_import_avoided,
        multiplier
    )

end

end


