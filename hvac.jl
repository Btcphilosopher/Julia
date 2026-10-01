using Dates

# ============================================================
# AUREOM VEHICLE AI
# Predictive Automotive HVAC Optimiser
#
# Simulation / controller research prototype
# ============================================================

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

struct HVACConfig
    cabin_mass::Float64              # effective thermal mass [kg]
    cabin_heat_capacity::Float64     # J/(kg K)

    max_cooling_kw::Float64
    max_heating_kw::Float64

    max_blower::Float64
    min_blower::Float64

    compressor_efficiency::Float64
    heater_efficiency::Float64

    target_temperature::Float64
    target_humidity::Float64

    minimum_temperature::Float64
    maximum_temperature::Float64

    solar_gain_coeff::Float64
    ambient_gain_coeff::Float64

    occupant_heat_w::Float64
    occupant_moisture_g_s::Float64

    window_loss_coeff::Float64

    dt::Float64
end


# ------------------------------------------------------------
# CABIN STATE
# ------------------------------------------------------------

mutable struct CabinState
    temperature::Float64             # °C
    humidity::Float64                # relative humidity 0..1

    outside_temperature::Float64     # °C
    solar_load::Float64              # W/m²

    occupants::Int

    vehicle_speed::Float64           # m/s

    cabin_pressure::Float64          # Pa

    blower_speed::Float64             # 0..1
    compressor_power_kw::Float64
    heater_power_kw::Float64

    vent_temperature::Float64
    vent_flow::Float64

    battery_power_kw::Float64

    energy_used_kwh::Float64

    windshield_fog_risk::Float64

    timestamp::DateTime
end


# ------------------------------------------------------------
# HVAC COMMAND
# ------------------------------------------------------------

struct HVACCommand
    cooling_power_kw::Float64
    heating_power_kw::Float64

    blower_speed::Float64

    recirculation::Float64
    fresh_air::Float64

    target_temperature::Float64

    battery_power_kw::Float64

    mode::Symbol
end


# ------------------------------------------------------------
# DEFAULT SYSTEM
# ------------------------------------------------------------

function create_hvac_config()

    HVACConfig(
        450.0,       # effective cabin thermal mass
        1005.0,      # air/material heat capacity

        8.0,         # max cooling
        7.0,         # max heating

        1.0,
        0.15,

        0.72,
        0.92,

        21.5,
        0.45,

        16.0,
        28.0,

        0.0025,
        0.020,

        90.0,
        0.08,

        0.003,

        0.05
    )
end


# ------------------------------------------------------------
# UTILITIES
# ------------------------------------------------------------

clamp01(x) = clamp(x, 0.0, 1.0)

function smoothstep(x)
    x = clamp01(x)
    return x * x * (3.0 - 2.0 * x)
end


# ------------------------------------------------------------
# THERMAL LOAD MODEL
# ------------------------------------------------------------

function calculate_thermal_load(
    cabin::CabinState,
    cfg::HVACConfig
)

    # Difference between outside and cabin
    ambient_load =
        cfg.ambient_gain_coeff *
        (cabin.outside_temperature - cabin.temperature)

    # Solar radiation
    solar_load =
        cfg.solar_gain_coeff *
        cabin.solar_load

    # Occupant heat
    occupant_load =
        cabin.occupants *
        cfg.occupant_heat_w

    # Vehicle motion / air exchange
    ventilation_load =
        cfg.window_loss_coeff *
        cabin.vehicle_speed *
        (cabin.outside_temperature - cabin.temperature)

    return (
        ambient_load +
        solar_load +
        occupant_load +
        ventilation_load
    )
end


# ------------------------------------------------------------
# COMFORT ERROR
# ------------------------------------------------------------

function temperature_error(
    cabin::CabinState,
    cfg::HVACConfig
)

    return cfg.target_temperature -
           cabin.temperature
end


function humidity_error(
    cabin::CabinState,
    cfg::HVACConfig
)

    return cfg.target_humidity -
           cabin.humidity
end


# ------------------------------------------------------------
# PREDICTIVE COOLING DEMAND
# ------------------------------------------------------------

function cooling_demand(
    cabin::CabinState,
    cfg::HVACConfig
)

    error = cabin.temperature -
            cfg.target_temperature

    # Solar and occupant heat are included
    thermal_load =
        max(
            calculate_thermal_load(cabin, cfg),
            0.0
        )

    proportional =
        1.8 * error

    feedforward =
        thermal_load / 1000.0

    demand =
        proportional +
        feedforward

    return clamp(
        demand,
        0.0,
        cfg.max_cooling_kw
    )
end


# ------------------------------------------------------------
# PREDICTIVE HEATING DEMAND
# ------------------------------------------------------------

function heating_demand(
    cabin::CabinState,
    cfg::HVACConfig
)

    error =
        cfg.target_temperature -
        cabin.temperature

    thermal_loss =
        max(
            -calculate_thermal_load(cabin, cfg),
            0.0
        )

    proportional =
        1.8 * error

    feedforward =
        thermal_loss / 1000.0

    demand =
        proportional +
        feedforward

    return clamp(
        demand,
        0.0,
        cfg.max_heating_kw
    )
end


# ------------------------------------------------------------
# BLOWER OPTIMISATION
# ------------------------------------------------------------

function optimise_blower(
    cabin::CabinState,
    cooling_kw::Float64,
    heating_kw::Float64,
    cfg::HVACConfig
)

    temp_error =
        abs(
            cabin.temperature -
            cfg.target_temperature
        )

    thermal_demand =
        max(cooling_kw, heating_kw)

    # More demand -> more airflow
    demand_factor =
        clamp01(
            thermal_demand /
            max(
                cfg.max_cooling_kw,
                cfg.max_heating_kw
            )
        )

    # Avoid excessive airflow when already comfortable
    comfort_factor =
        clamp01(temp_error / 5.0)

    blower =
        cfg.min_blower +
        0.75 * demand_factor +
        0.25 * comfort_factor

    return clamp(
        blower,
        cfg.min_blower,
        cfg.max_blower
    )
end


# ------------------------------------------------------------
# RECIRCULATION OPTIMISATION
# ------------------------------------------------------------

function optimise_recirculation(
    cabin::CabinState,
    cooling_kw::Float64,
    heating_kw::Float64
)

    temperature_difference =
        abs(
            cabin.outside_temperature -
            cabin.temperature
        )

    demand =
        max(cooling_kw, heating_kw)

    # Large thermal difference -> more recirculation
    recirculation =
        0.35 +
        0.55 *
        clamp01(temperature_difference / 20.0) +
        0.10 *
        clamp01(demand / 8.0)

    # Occupants require fresh air
    occupancy_penalty =
        min(
            cabin.occupants * 0.08,
            0.35
        )

    recirculation =
        clamp01(
            recirculation -
            occupancy_penalty
        )

    return recirculation
end


# ------------------------------------------------------------
# FRESH AIR
# ------------------------------------------------------------

function calculate_fresh_air(
    cabin::CabinState,
    recirculation::Float64
)

    base_fresh =
        1.0 - recirculation

    # More occupants require greater fresh-air fraction
    occupancy_boost =
        min(
            cabin.occupants * 0.05,
            0.25
        )

    return clamp01(
        base_fresh +
        occupancy_boost
    )
end


# ------------------------------------------------------------
# FOG PREVENTION
# ------------------------------------------------------------

function calculate_fog_risk(
    cabin::CabinState
)

    # Simplified proxy model:
    # high humidity + low cabin temperature
    humidity_factor =
        cabin.humidity

    temperature_factor =
        clamp01(
            (12.0 - cabin.temperature) /
            12.0
        )

    return clamp01(
        0.65 * humidity_factor +
        0.35 * temperature_factor
    )
end


# ------------------------------------------------------------
# FOG RESPONSE
# ------------------------------------------------------------

function anti_fog_adjustment(
    command::HVACCommand,
    cabin::CabinState
)

    risk =
        calculate_fog_risk(cabin)

    if risk < 0.45
        return command
    end

    # Increase fresh air and airflow
    new_blower =
        min(
            command.blower_speed +
            0.25 * risk,
            1.0
        )

    new_fresh =
        min(
            command.fresh_air +
            0.30 * risk,
            1.0
        )

    new_recirculation =
        max(
            0.0,
            1.0 - new_fresh
        )

    HVACCommand(
        command.cooling_power_kw,
        command.heating_power_kw,
        new_blower,
        new_recirculation,
        new_fresh,
        command.target_temperature,
        command.battery_power_kw,
        :ANTI_FOG
    )
end


# ------------------------------------------------------------
# HVAC ELECTRICAL POWER
# ------------------------------------------------------------

function calculate_electrical_power(
    cooling_kw::Float64,
    heating_kw::Float64,
    blower::Float64,
    cfg::HVACConfig
)

    # Simplified COP model
    cooling_cop =
        2.5 +
        1.2 * (1.0 - cooling_kw / cfg.max_cooling_kw)

    cooling_cop =
        max(cooling_cop, 1.8)

    compressor_electric =
        cooling_kw /
        cooling_cop

    heater_electric =
        heating_kw /
        cfg.heater_efficiency

    blower_electric =
        0.25 *
        blower^3

    return (
        compressor_electric +
        heater_electric +
        blower_electric
    )
end


# ------------------------------------------------------------
# MAIN HVAC OPTIMISER
# ------------------------------------------------------------

function optimise_hvac(
    cabin::CabinState,
    cfg::HVACConfig
)

    temp_error =
        temperature_error(cabin, cfg)

    cooling_kw = 0.0
    heating_kw = 0.0

    mode = :IDLE

    if temp_error < -0.25

        cooling_kw =
            cooling_demand(
                cabin,
                cfg
            )

        mode = :COOLING

    elseif temp_error > 0.25

        heating_kw =
            heating_demand(
                cabin,
                cfg
            )

        mode = :HEATING

    else

        # Maintain temperature
        mode = :HOLD
    end

    blower =
        optimise_blower(
            cabin,
            cooling_kw,
            heating_kw,
            cfg
        )

    recirculation =
        optimise_recirculation(
            cabin,
            cooling_kw,
            heating_kw
        )

    fresh_air =
        calculate_fresh_air(
            cabin,
            recirculation
        )

    electrical_power =
        calculate_electrical_power(
            cooling_kw,
            heating_kw,
            blower,
            cfg
        )

    command =
        HVACCommand(
            cooling_kw,
            heating_kw,
            blower,
            recirculation,
            fresh_air,
            cfg.target_temperature,
            electrical_power,
            mode
        )

    return anti_fog_adjustment(
        command,
        cabin
    )
end


# ------------------------------------------------------------
# CABIN THERMAL MODEL
# ------------------------------------------------------------

function update_cabin!(
    cabin::CabinState,
    command::HVACCommand,
    cfg::HVACConfig
)

    thermal_load =
        calculate_thermal_load(
            cabin,
            cfg
        )

    # HVAC thermal effect
    cooling_effect =
        command.cooling_power_kw *
        1000.0

    heating_effect =
        command.heating_power_kw *
        1000.0

    net_heat =
        thermal_load +
        heating_effect -
        cooling_effect

    # Effective thermal mass
    thermal_mass =
        cfg.cabin_mass *
        cfg.cabin_heat_capacity

    temperature_rate =
        net_heat /
        thermal_mass

    cabin.temperature +=
        temperature_rate *
        cfg.dt

    # Simplified humidity dynamics
    moisture_generation =
        cabin.occupants *
        cfg.occupant_moisture_g_s

    dehumidification =
        command.cooling_power_kw *
        0.015

    humidity_rate =
        (
            moisture_generation -
            dehumidification
        ) / 100.0

    cabin.humidity +=
        humidity_rate *
        cfg.dt

    cabin.humidity =
        clamp(
            cabin.humidity,
            0.20,
            0.90
        )

    # Vent temperature
    if command.cooling_power_kw > 0

        cabin.vent_temperature =
            cabin.temperature -
            12.0 *
            command.cooling_power_kw /
            cfg.max_cooling_kw

    elseif command.heating_power_kw > 0

        cabin.vent_temperature =
            cabin.temperature +
            25.0 *
            command.heating_power_kw /
            cfg.max_heating_kw

    else

        cabin.vent_temperature =
            cabin.temperature
    end

    cabin.vent_flow =
        command.blower_speed

    cabin.battery_power_kw =
        command.battery_power_kw

    cabin.energy_used_kwh +=
        command.battery_power_kw *
        cfg.dt /
        3600.0

    cabin.windshield_fog_risk =
        calculate_fog_risk(cabin)

    cabin.timestamp =
        now()

    return cabin
end


# ------------------------------------------------------------
# PREDICTIVE COST FUNCTION
# ------------------------------------------------------------

function hvac_cost(
    cabin::CabinState,
    command::HVACCommand,
    cfg::HVACConfig
)

    temperature_error =
        cabin.temperature -
        cfg.target_temperature

    humidity_error =
        cabin.humidity -
        cfg.target_humidity

    comfort_cost =
        100.0 *
        temperature_error^2 +
        30.0 *
        humidity_error^2

    energy_cost =
        8.0 *
        command.battery_power_kw^2

    blower_cost =
        2.0 *
        command.blower_speed^2

    fog_cost =
        200.0 *
        cabin.windshield_fog_risk^2

    return (
        comfort_cost +
        energy_cost +
        blower_cost +
        fog_cost
    )
end


# ------------------------------------------------------------
# PREDICTIVE SETPOINT OPTIMISATION
# ------------------------------------------------------------

function optimise_temperature_setpoint(
    cabin::CabinState,
    cfg::HVACConfig
)

    candidates =
        collect(
            19.0:0.5:24.0
        )

    best_temperature =
        cfg.target_temperature

    best_cost =
        Inf

    for target in candidates

        test_cfg =
            HVACConfig(
                cfg.cabin_mass,
                cfg.cabin_heat_capacity,
                cfg.max_cooling_kw,
                cfg.max_heating_kw,
                cfg.max_blower,
                cfg.min_blower,
                cfg.compressor_efficiency,
                cfg.heater_efficiency,
                target,
                cfg.target_humidity,
                cfg.minimum_temperature,
                cfg.maximum_temperature,
                cfg.solar_gain_coeff,
                cfg.ambient_gain_coeff,
                cfg.occupant_heat_w,
                cfg.occupant_moisture_g_s,
                cfg.window_loss_coeff,
                cfg.dt
            )

        command =
            optimise_hvac(
                cabin,
                test_cfg
            )

        cost =
            hvac_cost(
                cabin,
                command,
                test_cfg
            )

        if cost < best_cost

            best_cost =
                cost

            best_temperature =
                target
        end
    end

    return best_temperature
end


# ------------------------------------------------------------
# VEHICLE INTEGRATION
# ------------------------------------------------------------

struct VehicleHVACInput
    vehicle_speed::Float64
    battery_soc::Float64
    battery_temperature::Float64

    navigation_distance_km::Float64
    ambient_temperature::Float64
    solar_load::Float64

    occupants::Int
end


# ------------------------------------------------------------
# RANGE-AWARE HVAC POWER LIMIT
# ------------------------------------------------------------

function range_aware_power_limit(
    battery_soc::Float64,
    required_energy_kwh::Float64
)

    if battery_soc < 0.10

        return 0.50

    elseif battery_soc < 0.20

        return 0.70

    elseif required_energy_kwh > 20.0

        return 0.80

    else

        return 1.00
    end
end


# ------------------------------------------------------------
# HIGH-LEVEL AUREOM CLIMATE CONTROLLER
# ------------------------------------------------------------

function aureom_climate_controller(
    cabin::CabinState,
    vehicle::VehicleHVACInput,
    cfg::HVACConfig
)

    # Update environment
    cabin.outside_temperature =
        vehicle.ambient_temperature

    cabin.solar_load =
        vehicle.solar_load

    cabin.vehicle_speed =
        vehicle.vehicle_speed

    cabin.occupants =
        vehicle.occupants

    # Predictive setpoint
    optimal_setpoint =
        optimise_temperature_setpoint(
            cabin,
            cfg
        )

    predictive_cfg =
        HVACConfig(
            cfg.cabin_mass,
            cfg.cabin_heat_capacity,
            cfg.max_cooling_kw,
            cfg.max_heating_kw,
            cfg.max_blower,
            cfg.min_blower,
            cfg.compressor_efficiency,
            cfg.heater_efficiency,
            optimal_setpoint,
            cfg.target_humidity,
            cfg.minimum_temperature,
            cfg.maximum_temperature,
            cfg.solar_gain_coeff,
            cfg.ambient_gain_coeff,
            cfg.occupant_heat_w,
            cfg.occupant_moisture_g_s,
            cfg.window_loss_coeff,
            cfg.dt
        )

    command =
        optimise_hvac(
            cabin,
            predictive_cfg
        )

    # Battery/range awareness
    power_limit =
        range_aware_power_limit(
            vehicle.battery_soc,
            vehicle.navigation_distance_km
        )

    if command.battery_power_kw >
       8.0 * power_limit

        scale =
            power_limit

        command =
            HVACCommand(
                command.cooling_power_kw * scale,
                command.heating_power_kw * scale,
                command.blower_speed,
                command.recirculation,
                command.fresh_air,
                command.target_temperature,
                command.battery_power_kw * scale,
                :ENERGY_SAVE
            )
    end

    return command
end


# ------------------------------------------------------------
# SIMULATION
# ------------------------------------------------------------

cfg =
    create_hvac_config()

cabin =
    CabinState(
        29.0,       # cabin temperature
        0.58,       # humidity

        32.0,       # outside temperature
        750.0,      # solar load

        2,          # occupants

        25.0,       # vehicle speed

        101325.0,

        0.0,
        0.0,
        0.0,

        29.0,
        0.0,

        0.0,

        0.0,

        0.0,

        now()
    )


vehicle =
    VehicleHVACInput(
        25.0,
        0.72,
        29.0,

        180.0,

        32.0,
        750.0,

        2
    )


println("==============================================")
println(" AUREOM ADAPTIVE HVAC CONTROLLER")
println("==============================================")


for step in 1:600

    command =
        aureom_climate_controller(
            cabin,
            vehicle,
            cfg
        )

    update_cabin!(
        cabin,
        command,
        cfg
    )

    if step % 20 == 0

        println()
        println(
            "t = ",
            round(step * cfg.dt, digits=1),
            " s"
        )

        println(
            "Cabin: ",
            round(cabin.temperature, digits=2),
            " °C"
        )

        println(
            "Humidity: ",
            round(cabin.humidity * 100, digits=1),
            " %"
        )

        println(
            "Cooling: ",
            round(command.cooling_power_kw, digits=2),
            " kW"
        )

        println(
            "Heating: ",
            round(command.heating_power_kw, digits=2),
            " kW"
        )

        println(
            "Blower: ",
            round(command.blower_speed * 100, digits=1),
            " %"
        )

        println(
            "Recirculation: ",
            round(command.recirculation * 100, digits=1),
            " %"
        )

        println(
            "Fresh air: ",
            round(command.fresh_air * 100, digits=1),
            " %"
        )

        println(
            "HVAC battery power: ",
            round(command.battery_power_kw, digits=2),
            " kW"
        )

        println(
            "Fog risk: ",
            round(cabin.windshield_fog_risk * 100, digits=1),
            " %"
        )

        println(
            "Mode: ",
            command.mode
        )

        println(
            "Energy: ",
            round(cabin.energy_used_kwh, digits=3),
            " kWh"
        )
    end

    sleep(cfg.dt)
end
