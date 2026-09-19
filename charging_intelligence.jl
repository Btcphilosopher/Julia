iPhone charger / battery
        ↓
 Swift telemetry
        ↓
 ┌──────────────────────────┐
 │      Julia Battery AI    │
 │                          │
 │ SOC estimation           │
 │ SOH estimation           │
 │ temperature model        │
 │ charge-rate optimisation │
 │ ageing prediction        │
 │ cycle modelling          │
 │ anomaly detection        │
 │ energy forecasting       │
 └────────────┬─────────────┘
              ↓
       charging policy
              ↓
      Swift application
A harder Julia implementation
module AureomCharging

using LinearAlgebra
using Statistics

export BatteryState,
       ChargingState,
       update!,
       estimate_soc,
       estimate_soh,
       optimise_charge,
       predict_temperature,
       charging_policy

# ---------------------------------------------------------
# Battery observation
# ---------------------------------------------------------

struct BatteryObservation
    timestamp::Float64

    voltage::Float64
    current::Float64

    temperature::Float64

    capacity_nominal::Float64
    energy_in::Float64

    external_power::Bool
end


# ---------------------------------------------------------
# Internal battery state
# ---------------------------------------------------------

mutable struct BatteryState

    soc::Float64
    soh::Float64

    voltage::Float64
    current::Float64
    temperature::Float64

    internal_resistance::Float64

    accumulated_energy::Float64
    cycle_equivalent::Float64

    temperature_rate::Float64
    voltage_rate::Float64

    last_timestamp::Float64

    history::Vector{BatteryObservation}
end


function BatteryState(;
    initial_soc = 0.50,
    initial_soh = 1.00,
    resistance = 0.08
)

    BatteryState(
        initial_soc,
        initial_soh,

        3.8,
        0.0,
        25.0,

        resistance,

        0.0,
        0.0,

        0.0,
        0.0,

        0.0,

        BatteryObservation[]
    )
end


# ---------------------------------------------------------
# SOC
# ---------------------------------------------------------

function estimate_soc(
    state::BatteryState,
    observation::BatteryObservation
)

    dt = observation.timestamp -
         state.last_timestamp

    if dt <= 0
        return state.soc
    end

    # Coulomb counting.
    #
    # Current is assumed positive during charging.
    # Capacity is expressed in Ah.

    capacity =
        observation.capacity_nominal *
        state.soh

    ΔAh =
        observation.current *
        dt / 3600.0

    ΔSOC =
        ΔAh / max(capacity, 0.001)

    predicted =
        state.soc + ΔSOC

    # Voltage correction.
    #
    # This is deliberately conservative rather
    # than treating voltage as a direct SOC meter.

    voltage_soc =
        clamp(
            (observation.voltage - 3.2) /
            (4.2 - 3.2),
            0.0,
            1.0
        )

    α = 0.92

    soc =
        α * predicted +
        (1.0 - α) * voltage_soc

    return clamp(soc, 0.0, 1.0)
end


# ---------------------------------------------------------
# Temperature model
# ---------------------------------------------------------

function predict_temperature(
    state::BatteryState,
    current::Float64,
    ambient::Float64,
    dt::Float64
)

    # Simplified Joule heating.
    heat =
        current^2 *
        state.internal_resistance

    # Simplified thermal loss.
    cooling =
        0.08 *
        (state.temperature - ambient)

    thermal_capacity = 55.0

    dT =
        (heat - cooling) /
        thermal_capacity

    return state.temperature +
           dT * dt
end


# ---------------------------------------------------------
# SOH estimation
# ---------------------------------------------------------

function estimate_soh(
    state::BatteryState
)

    # Equivalent full cycles.
    cycles = state.cycle_equivalent

    # Simplified degradation model.
    #
    # Real production estimation would use
    # experimentally fitted cell chemistry models.

    calendar_loss =
        0.015 *
        (cycles / 365.0)

    thermal_penalty =
        max(
            state.temperature - 30.0,
            0.0
        ) * 0.00008

    soh =
        1.0 -
        calendar_loss -
        thermal_penalty

    return clamp(soh, 0.70, 1.0)
end


# ---------------------------------------------------------
# State update
# ---------------------------------------------------------

function update!(
    state::BatteryState,
    observation::BatteryObservation
)

    push!(
        state.history,
        observation
    )

    if length(state.history) > 1000
        popfirst!(state.history)
    end

    state.voltage =
        observation.voltage

    state.current =
        observation.current

    previous_temperature =
        state.temperature

    state.soc =
        estimate_soc(
            state,
            observation
        )

    dt =
        observation.timestamp -
        state.last_timestamp

    if dt > 0

        state.temperature =
            predict_temperature(
                state,
                observation.current,
                22.0,
                dt
            )

        state.temperature_rate =
            (
                state.temperature -
                previous_temperature
            ) / dt

        state.voltage_rate =
            if length(state.history) >= 2

                previous =
                    state.history[end-1]

                (
                    observation.voltage -
                    previous.voltage
                ) / dt

            else
                0.0
            end
    end

    # Accumulated charging energy.

    state.accumulated_energy +=
        abs(
            observation.voltage *
            observation.current *
            dt
        ) / 3600.0

    # Equivalent full cycle accumulation.

    state.cycle_equivalent +=
        abs(
            observation.current *
            dt /
            3600.0
        ) /
        observation.capacity_nominal

    state.soh =
        estimate_soh(state)

    state.last_timestamp =
        observation.timestamp

    return state
end

Then make Julia actually choose a charging strategy.

struct ChargingState

    target_current::Float64
    target_soc::Float64

    thermal_limit::Float64

    predicted_temperature::Float64

    reason::Symbol
end

And:

function optimise_charge(
    state::BatteryState;

    charger_power::Float64,
    ambient_temperature::Float64 = 22.0,
    target_soc::Float64 = 0.80
)

    voltage = max(
        state.voltage,
        3.5
    )

    maximum_current =
        charger_power / voltage

    current =
        maximum_current

    predicted =
        predict_temperature(
            state,
            current,
            ambient_temperature,
            60.0
        )

    reason = :maximum_safe_rate

    # Thermal management.

    if predicted > 38.0

        current *= 0.70
        reason = :thermal_reduction

    elseif predicted > 35.0

        current *= 0.85
        reason = :thermal_prevention
    end

    # Protect high SOC region.

    if state.soc > 0.80

        current *=
            1.0 -
            ((state.soc - 0.80) / 0.20) * 0.70

        reason = :high_soc_taper
    end

    if state.soh < 0.85

        current *= 0.85
        reason = :battery_age_protection
    end

    ChargingState(
        max(current, 0.0),
        target_soc,
        38.0,
        predicted,
        reason
    )
end

So instead of a dumb:

CHARGE
100%

you get something like:

AUREOM CHARGING INTELLIGENCE

SOC                    67.4%
SOH                    96.8%

Battery temperature    31.2°C
Predicted temperature  34.1°C

Charger                27 W

Recommended current    5.8 A
Target SOC             80%

Strategy               THERMAL PREVENTION
The really powerful version

I'd eventually make the Julia system optimise three competing objectives:

              CHARGING OPTIMISER

                    ↓

       ┌────────────┼────────────┐
       ↓            ↓            ↓
    SPEED        BATTERY       HEAT
                  LIFE
       ↓            ↓            ↓
       └────────────┼────────────┘
                    ↓
             OPTIMAL POLICY

Mathematically:

function charging_cost(
    current,
    soc,
    temperature,
    soh
)

    speed_cost =
        -current

    thermal_cost =
        max(temperature - 30.0, 0.0)^2

    ageing_cost =
        (current^2) *
        (1.0 - soh)

    high_soc_cost =
        max(soc - 0.80, 0.0)^3 * 100.0

    return (
        0.45 * speed_cost +
        0.30 * thermal_cost +
        0.20 * ageing_cost +
        0.05 * high_soc_cost
    )
end

You could then search across possible charging currents:

function find_optimal_current(
    state::BatteryState,
    charger_power::Float64
)

    voltage = max(state.voltage, 3.5)

    maximum_current =
        charger_power / voltage

    candidates =
        range(
            0.1,
            maximum_current,
            length = 100
        )

    costs = Float64[]

    for current in candidates

        predicted =
            predict_temperature(
                state,
                current,
                22.0,
                300.0
            )

        push!(
            costs,
            charging_cost(
                current,
                state.soc,
                predicted,
                state.soh
            )
        )
    end

    index =
        argmin(costs)

    return candidates[index]
end

