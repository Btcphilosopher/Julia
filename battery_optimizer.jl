battery_optimizer.jl




module BatteryOptimizer

export BatteryConfig,
       ChargingResult,
       optimise_ev_charging,
       print_result,
       charging_dataframe

# ============================================================
# Battery Optimizer
# Pure Julia — no external packages
# ============================================================

"""
Configuration for a battery / EV.
"""
struct BatteryConfig
    capacity_kwh::Float64
    initial_soc_kwh::Float64
    target_soc_kwh::Float64
    min_soc_kwh::Float64
    max_soc_kwh::Float64
    max_charge_power_kw::Float64
    charge_efficiency::Float64
    timestep_hours::Float64
end

"""
Convenience constructor where max SOC = battery capacity.
"""
function BatteryConfig(
    capacity_kwh::Real,
    initial_soc_kwh::Real,
    target_soc_kwh::Real,
    min_soc_kwh::Real,
    max_charge_power_kw::Real,
    charge_efficiency::Real,
    timestep_hours::Real
)
    return BatteryConfig(
        Float64(capacity_kwh),
        Float64(initial_soc_kwh),
        Float64(target_soc_kwh),
        Float64(min_soc_kwh),
        Float64(capacity_kwh),
        Float64(max_charge_power_kw),
        Float64(charge_efficiency),
        Float64(timestep_hours)
    )
end


"""
Result returned by the optimisation engine.
"""
struct ChargingResult
    status::Symbol
    total_cost::Float64
    total_energy_kwh::Float64
    battery_energy_added_kwh::Float64
    average_price::Float64
    peak_power_kw::Float64

    charge_power_kw::Vector{Float64}
    grid_energy_kwh::Vector{Float64}
    battery_energy_added::Vector{Float64}
    soc_kwh::Vector{Float64}
    interval_cost::Vector{Float64}
end


# ============================================================
# Validation
# ============================================================

function validate_battery(b::BatteryConfig)

    b.capacity_kwh > 0 ||
        throw(ArgumentError("Battery capacity must be > 0"))

    b.initial_soc_kwh >= 0 ||
        throw(ArgumentError("Initial SOC cannot be negative"))

    b.initial_soc_kwh <= b.capacity_kwh ||
        throw(ArgumentError("Initial SOC exceeds battery capacity"))

    b.target_soc_kwh >= 0 ||
        throw(ArgumentError("Target SOC cannot be negative"))

    b.target_soc_kwh <= b.capacity_kwh ||
        throw(ArgumentError("Target SOC exceeds battery capacity"))

    b.min_soc_kwh >= 0 ||
        throw(ArgumentError("Minimum SOC cannot be negative"))

    b.min_soc_kwh <= b.capacity_kwh ||
        throw(ArgumentError("Minimum SOC exceeds battery capacity"))

    b.max_soc_kwh >= b.min_soc_kwh ||
        throw(ArgumentError("Maximum SOC is below minimum SOC"))

    b.max_soc_kwh <= b.capacity_kwh ||
        throw(ArgumentError("Maximum SOC exceeds capacity"))

    b.max_charge_power_kw >= 0 ||
        throw(ArgumentError("Maximum charging power cannot be negative"))

    0 < b.charge_efficiency <= 1 ||
        throw(ArgumentError("Charging efficiency must be > 0 and <= 1"))

    b.timestep_hours > 0 ||
        throw(ArgumentError("Timestep must be > 0"))

    return nothing
end


# ============================================================
# Core optimiser
# ============================================================

"""
    optimise_ev_charging(prices, battery; kwargs...)

Find the minimum-cost charging schedule for an EV/battery.

`prices`:
    Electricity price for each timestep in £/kWh.

The optimiser is exact for the single-battery linear problem:
    - no discharge
    - no battery degradation
    - no coupled loads
    - no demand charges
    - fixed charging efficiency
    - fixed maximum charging power

Keyword arguments:

    start_time
        First available charging interval.

    departure_time
        Last available charging interval.

    house_load_kw
        Optional existing household load.

    max_grid_power_kw
        Maximum total grid import.

    reserve_soc_kwh
        Additional SOC required at departure.

    timestamps
        Optional labels for the intervals.
"""
function optimise_ev_charging(
    prices::AbstractVector{<:Real},
    battery::BatteryConfig;
    start_time::Int = 1,
    departure_time::Int = length(prices),
    house_load_kw::AbstractVector{<:Real} = zeros(length(prices)),
    max_grid_power_kw::Real = Inf,
    reserve_soc_kwh::Real = 0.0,
    timestamps = nothing
)

    validate_battery(battery)

    T = length(prices)

    T > 0 ||
        throw(ArgumentError("Price vector cannot be empty"))

    length(house_load_kw) == T ||
        throw(ArgumentError("house_load_kw must have same length as prices"))

    1 <= start_time <= T ||
        throw(ArgumentError("Invalid start_time"))

    1 <= departure_time <= T ||
        throw(ArgumentError("Invalid departure_time"))

    start_time <= departure_time ||
        throw(ArgumentError("start_time must be <= departure_time"))

    max_grid_power_kw >= 0 ||
        throw(ArgumentError("max_grid_power_kw cannot be negative"))

    reserve_soc_kwh >= 0 ||
        throw(ArgumentError("reserve_soc_kwh cannot be negative"))

    for p in prices
        isfinite(p) ||
            throw(ArgumentError("Prices must be finite"))
    end

    for load in house_load_kw
        load >= 0 ||
            throw(ArgumentError("House load cannot be negative"))
    end

    # --------------------------------------------------------
    # Required SOC
    # --------------------------------------------------------

    required_soc = min(
        battery.target_soc_kwh + reserve_soc_kwh,
        battery.max_soc_kwh
    )

    # If already sufficiently charged, no optimisation needed.
    if battery.initial_soc_kwh >= required_soc - 1e-9

        charge = zeros(Float64, T)
        grid = zeros(Float64, T)
        added = zeros(Float64, T)
        soc = fill(battery.initial_soc_kwh, T)
        costs = zeros(Float64, T)

        return ChargingResult(
            :already_sufficient,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            charge,
            grid,
            added,
            soc,
            costs
        )
    end

    # --------------------------------------------------------
    # Determine available charging power
    # --------------------------------------------------------

    charge_power = zeros(Float64, T)

    for t in start_time:departure_time

        available_grid_power =
            max_grid_power_kw - Float64(house_load_kw[t])

        available_grid_power = max(
            0.0,
            available_grid_power
        )

        charge_power[t] = min(
            battery.max_charge_power_kw,
            available_grid_power
        )
    end

    # --------------------------------------------------------
    # Determine how much battery energy is required.
    # --------------------------------------------------------

    required_battery_energy =
        required_soc - battery.initial_soc_kwh

    required_battery_energy =
        max(0.0, required_battery_energy)

    # --------------------------------------------------------
    # Maximum possible battery energy
    # --------------------------------------------------------

    max_possible_battery_energy = 0.0

    for t in start_time:departure_time

        max_possible_battery_energy +=
            charge_power[t] *
            battery.timestep_hours *
            battery.charge_efficiency
    end

    if max_possible_battery_energy + 1e-9 <
       required_battery_energy

        return ChargingResult(
            :infeasible,
            Inf,
            0.0,
            0.0,
            NaN,
            0.0,
            zeros(Float64, T),
            zeros(Float64, T),
            zeros(Float64, T),
            fill(battery.initial_soc_kwh, T),
            zeros(Float64, T)
        )
    end

    # --------------------------------------------------------
    # CHEAPEST-FIRST OPTIMISATION
    #
    # For this linear single-battery problem this is optimal.
    #
    # Sort only the available intervals by electricity price.
    # --------------------------------------------------------

    available = collect(start_time:departure_time)

    sort!(
        available,
        by = t -> Float64(prices[t])
    )

    remaining_battery_energy = required_battery_energy

    for t in available

        remaining_battery_energy <= 1e-10 &&
            break

        maximum_grid_energy =
            charge_power[t] *
            battery.timestep_hours

        maximum_battery_energy =
            maximum_grid_energy *
            battery.charge_efficiency

        energy_to_battery = min(
            maximum_battery_energy,
            remaining_battery_energy
        )

        if energy_to_battery > 0

            grid_energy =
                energy_to_battery /
                battery.charge_efficiency

            charge_power[t] =
                grid_energy /
                battery.timestep_hours

            remaining_battery_energy -=
                energy_to_battery
        end
    end

    # --------------------------------------------------------
    # Construct SOC trajectory
    # --------------------------------------------------------

    soc = zeros(Float64, T)
    grid_energy = zeros(Float64, T)
    battery_energy_added = zeros(Float64, T)
    interval_cost = zeros(Float64, T)

    current_soc = battery.initial_soc_kwh

    for t in 1:T

        grid_energy[t] =
            charge_power[t] *
            battery.timestep_hours

        battery_energy_added[t] =
            grid_energy[t] *
            battery.charge_efficiency

        current_soc += battery_energy_added[t]

        current_soc = min(
            current_soc,
            battery.max_soc_kwh
        )

        soc[t] = current_soc

        interval_cost[t] =
            grid_energy[t] *
            Float64(prices[t])
    end

    total_cost = sum(interval_cost)

    total_grid_energy = sum(grid_energy)

    total_battery_energy =
        sum(battery_energy_added)

    average_price =
        total_grid_energy > 0 ?
        total_cost / total_grid_energy :
        0.0

    peak_power =
        isempty(charge_power) ?
        0.0 :
        maximum(charge_power)

    final_soc = soc[departure_time]

    status =
        final_soc + 1e-7 >= required_soc ?
        :optimal :
        :infeasible

    return ChargingResult(
        status,
        total_cost,
        total_grid_energy,
        total_battery_energy,
        average_price,
        peak_power,
        charge_power,
        grid_energy,
        battery_energy_added,
        soc,
        interval_cost
    )
end


# ============================================================
# Human-readable reporting
# ============================================================

function print_result(
    result::ChargingResult,
    prices::AbstractVector{<:Real}
)

    println()
    println("======================================================")
    println("        BATTERY CHARGING OPTIMISATION")
    println("======================================================")
    println()

    println("Status:                 ", result.status)
    println("Total electricity cost: £", round(result.total_cost, digits=2))
    println("Grid energy:            ", round(result.total_energy_kwh, digits=2), " kWh")
    println("Battery energy added:   ", round(result.battery_energy_added_kwh, digits=2), " kWh")
    println("Average electricity:    £", round(result.average_price, digits=4), "/kWh")
    println("Peak charging power:    ", round(result.peak_power_kw, digits=2), " kW")

    println()
    println("------------------------------------------------------")
    println("TIMESTEP     PRICE       CHARGE       SOC       COST")
    println("             £/kWh       kW           kWh       £")
    println("------------------------------------------------------")

    for t in eachindex(prices)

        if result.charge_power_kw[t] > 1e-8

            println(
                lpad(string(t), 5),
                "      ",
                lpad(string(round(Float64(prices[t]), digits=3)), 6),
                "      ",
                lpad(string(round(result.charge_power_kw[t], digits=2)), 6),
                "      ",
                lpad(string(round(result.soc_kwh[t], digits=2)), 7),
                "      ",
                lpad(string(round(result.interval_cost[t], digits=3)), 6)
            )
        end
    end

    println("------------------------------------------------------")
    println()
end


# ============================================================
# Lightweight tabular output
# ============================================================

"""
Return the schedule as a Vector of NamedTuples.

No DataFrames dependency is required.
"""
function charging_dataframe(
    result::ChargingResult,
    prices::AbstractVector{<:Real}
)

    T = length(prices)

    return [
        (
            timestep = t,
            price_gbp_per_kwh = Float64(prices[t]),
            charge_power_kw = result.charge_power_kw[t],
            grid_energy_kwh = result.grid_energy_kwh[t],
            battery_energy_added_kwh =
                result.battery_energy_added[t],
            soc_kwh = result.soc_kwh[t],
            cost_gbp = result.interval_cost[t]
        )
        for t in 1:T
    ]
end

end # module
