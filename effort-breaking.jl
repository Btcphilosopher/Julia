module PedalChargeOptimizer

export RiderState, BatteryState, ChargeCommand,
       estimate_human_power,
       estimate_charge_power,
       optimise_charge,
       update_system

# ---------------------------------------------------------
# Rider state
# ---------------------------------------------------------

struct RiderState
    cadence_rpm::Float64
    pedal_torque_nm::Float64
    wheel_speed_ms::Float64
end

# ---------------------------------------------------------
# Battery state
# ---------------------------------------------------------

struct BatteryState
    soc::Float64
    voltage_v::Float64
    temperature_c::Float64
    capacity_wh::Float64
    max_charge_current_a::Float64
end

# ---------------------------------------------------------
# Motor / electrical command
# ---------------------------------------------------------

struct ChargeCommand
    charge_current_a::Float64
    charge_power_w::Float64
    human_power_w::Float64
    accepted_power_w::Float64
end

# ---------------------------------------------------------
# Constants
# ---------------------------------------------------------

const MIN_SOC = 0.05
const MAX_SOC = 0.98
const MAX_BATTERY_TEMP = 45.0
const NOMINAL_CHARGE_EFFICIENCY = 0.92

# ---------------------------------------------------------
# Human mechanical power
#
# P = torque × angular velocity
# ---------------------------------------------------------

function estimate_human_power(rider::RiderState)

    ω = rider.cadence_rpm * 2π / 60

    power = rider.pedal_torque_nm * ω

    return max(power, 0.0)
end

# ---------------------------------------------------------
# Estimate how much of rider power can become
# electrical charging power.
# ---------------------------------------------------------

function estimate_charge_power(
    rider::RiderState,
    efficiency::Float64 = NOMINAL_CHARGE_EFFICIENCY
)

    human_power = estimate_human_power(rider)

    electrical_power = human_power * efficiency

    return max(electrical_power, 0.0)
end

# ---------------------------------------------------------
# Battery charge acceptance
#
# Reduce charging near full SOC or high temperature.
# ---------------------------------------------------------

function battery_acceptance_factor(battery::BatteryState)

    soc_factor =
        if battery.soc >= MAX_SOC
            0.0
        elseif battery.soc > 0.90
            (MAX_SOC - battery.soc) / 0.08
        else
            1.0
        end

    temperature_factor =
        if battery.temperature_c >= MAX_BATTERY_TEMP
            0.0
        elseif battery.temperature_c > 40.0
            (MAX_BATTERY_TEMP - battery.temperature_c) / 5.0
        else
            1.0
        end

    return clamp(min(soc_factor, temperature_factor), 0.0, 1.0)
end

# ---------------------------------------------------------
# Optimise charging
# ---------------------------------------------------------

function optimise_charge(
    rider::RiderState,
    battery::BatteryState
)

    human_power = estimate_human_power(rider)

    available_power =
        estimate_charge_power(rider)

    acceptance =
        battery_acceptance_factor(battery)

    accepted_power =
        available_power * acceptance

    # Battery current limit
    maximum_power =
        battery.voltage_v *
        battery.max_charge_current_a

    accepted_power =
        min(accepted_power, maximum_power)

    # Don't charge a nearly full battery
    if battery.soc >= MAX_SOC
        accepted_power = 0.0
    end

    charge_current =
        accepted_power / max(battery.voltage_v, 1.0)

    return ChargeCommand(
        charge_current,
        accepted_power,
        human_power,
        accepted_power
    )
end

# ---------------------------------------------------------
# Main control update
# ---------------------------------------------------------

function update_system(
    rider::RiderState,
    battery::BatteryState
)

    command = optimise_charge(rider, battery)

    return command
end

end

