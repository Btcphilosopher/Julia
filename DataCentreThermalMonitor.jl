module DataCentreThermalMonitor

using Statistics
using Printf
using Dates

# ============================================================
# DATA CENTRE THERMAL ENERGY / SENSOR MONITOR
#
# Pure Julia
#
# Designed as a supervisory analytics layer for temperature
# and thermal-energy sensors in a data centre.
#
# Features:
#   - Sensor ingestion
#   - Temperature monitoring
#   - Rack / zone aggregation
#   - Thermal load estimation
#   - Hotspot detection
#   - Rate-of-change detection
#   - Moving averages
#   - Thermal headroom
#   - Cooling demand estimation
#   - Anomaly detection
#   - Predictive thresholding
#   - Alert generation
#
# Sensor interfaces can be connected separately to:
#   Modbus / MQTT / OPC-UA / REST / serial / BMS / DCIM
#
# This code is the analytics/control layer, not a replacement
# for independent safety systems.
# ============================================================


# ============================================================
# SENSOR
# ============================================================

mutable struct ThermalSensor

    id::String
    rack::String
    zone::String

    temperature_c::Float64

    humidity_percent::Float64

    inlet_temperature_c::Float64
    outlet_temperature_c::Float64

    power_kw::Float64

    timestamp::DateTime

    online::Bool

    history::Vector{Float64}
end


# ============================================================
# THERMAL ZONE
# ============================================================

mutable struct ThermalZone

    id::String

    sensor_ids::Vector{String}

    average_temperature_c::Float64
    maximum_temperature_c::Float64
    minimum_temperature_c::Float64

    total_power_kw::Float64

    estimated_heat_kw::Float64

    cooling_demand_kw::Float64

    thermal_headroom_c::Float64

    hotspot_count::Int

    risk_score::Float64
end


# ============================================================
# ALERT
# ============================================================

struct ThermalAlert

    timestamp::DateTime

    severity::Symbol

    sensor_id::String

    zone::String

    message::String

    temperature_c::Float64
end


# ============================================================
# DATA CENTRE
# ============================================================

mutable struct DataCentreThermalSystem

    sensors::Dict{String,ThermalSensor}

    zones::Dict{String,ThermalZone}

    alerts::Vector{ThermalAlert}

    ambient_temperature_c::Float64

    target_temperature_c::Float64

    warning_temperature_c::Float64

    critical_temperature_c::Float64

    maximum_temperature_c::Float64

    cooling_capacity_kw::Float64

    total_power_kw::Float64

    total_heat_kw::Float64

    total_cooling_demand_kw::Float64

    thermal_efficiency::Float64

    sampling_interval_seconds::Float64
end


# ============================================================
# CREATE SYSTEM
# ============================================================

function create_system(;
    target_temperature=24.0,
    warning_temperature=27.0,
    critical_temperature=30.0,
    maximum_temperature=35.0,
    cooling_capacity_kw=5000.0,
    sampling_interval_seconds=5.0
)

    return DataCentreThermalSystem(

        Dict{String,ThermalSensor}(),

        Dict{String,ThermalZone}(),

        ThermalAlert[],

        20.0,

        target_temperature,
        warning_temperature,
        critical_temperature,
        maximum_temperature,

        cooling_capacity_kw,

        0.0,
        0.0,
        0.0,

        1.0,

        sampling_interval_seconds
    )
end


# ============================================================
# REGISTER SENSOR
# ============================================================

function register_sensor!(
    system::DataCentreThermalSystem,
    id::String,
    rack::String,
    zone::String;
    temperature_c=22.0,
    humidity_percent=45.0,
    inlet_temperature_c=22.0,
    outlet_temperature_c=28.0,
    power_kw=10.0
)

    sensor =
        ThermalSensor(

            id,
            rack,
            zone,

            temperature_c,

            humidity_percent,

            inlet_temperature_c,
            outlet_temperature_c,

            power_kw,

            now(),

            true,

            Float64[]
        )

    push!(
        sensor.history,
        temperature_c
    )

    system.sensors[id] =
        sensor

    if !haskey(
        system.zones,
        zone
    )

        system.zones[zone] =
            ThermalZone(

                zone,

                String[],

                temperature_c,
                temperature_c,
                temperature_c,

                0.0,

                0.0,
                0.0,

                system.maximum_temperature_c -
                temperature_c,

                0,

                0.0
            )
    end

    push!(
        system.zones[zone].sensor_ids,
        id
    )

    return id
end


# ============================================================
# SENSOR UPDATE
# ============================================================

function update_sensor!(
    system::DataCentreThermalSystem,
    id::String;

    temperature_c=nothing,
    humidity_percent=nothing,
    inlet_temperature_c=nothing,
    outlet_temperature_c=nothing,
    power_kw=nothing
)

    if !haskey(
        system.sensors,
        id
    )

        return false
    end

    sensor =
        system.sensors[id]

    if temperature_c !== nothing

        sensor.temperature_c =
            Float64(temperature_c)

        push!(
            sensor.history,
            sensor.temperature_c
        )

        # Keep rolling history bounded.

        if length(sensor.history) > 300

            deleteat!(
                sensor.history,
                1
            )
        end
    end

    if humidity_percent !== nothing

        sensor.humidity_percent =
            Float64(humidity_percent)
    end

    if inlet_temperature_c !== nothing

        sensor.inlet_temperature_c =
            Float64(inlet_temperature_c)
    end

    if outlet_temperature_c !== nothing

        sensor.outlet_temperature_c =
            Float64(outlet_temperature_c)
    end

    if power_kw !== nothing

        sensor.power_kw =
            Float64(power_kw)
    end

    sensor.timestamp =
        now()

    sensor.online =
        true

    return true
end


# ============================================================
# MOVING AVERAGE
# ============================================================

function moving_average(
    values::Vector{Float64},
    window::Int
)

    isempty(values) &&
        return 0.0

    n =
        min(
            length(values),
            window
        )

    return mean(
        @view values[
            end-n+1:end
        ]
    )
end


# ============================================================
# TEMPERATURE TREND
# ============================================================

function temperature_rate(
    sensor::ThermalSensor
)

    if length(sensor.history) < 2

        return 0.0
    end

    previous =
        sensor.history[
            end-1
        ]

    current =
        sensor.history[
            end
        ]

    return current -
           previous
end


# ============================================================
# ESTIMATE SERVER HEAT
# ============================================================

function estimate_heat_output(
    sensor::ThermalSensor
)

    # Most electrical power consumed by IT equipment eventually
    # becomes heat within the facility.

    return max(
        sensor.power_kw *
        0.98,
        0.0
    )
end


# ============================================================
# COOLING DEMAND
# ============================================================

function estimate_cooling_demand(
    system::DataCentreThermalSystem,
    zone::ThermalZone
)

    temperature_error =
        max(
            zone.average_temperature_c -
            system.target_temperature_c,
            0.0
        )

    proportional_cooling =
        temperature_error *
        zone.total_power_kw *
        0.8

    return max(
        zone.estimated_heat_kw +
        proportional_cooling,
        0.0
    )
end


# ============================================================
# ZONE ANALYTICS
# ============================================================

function analyse_zone!(
    system::DataCentreThermalSystem,
    zone::ThermalZone
)

    temperatures =
        Float64[]

    powers =
        Float64[]

    heat =
        0.0

    for id in zone.sensor_ids

        if !haskey(
            system.sensors,
            id
        )

            continue
        end

        sensor =
            system.sensors[id]

        if !sensor.online

            continue
        end

        push!(
            temperatures,
            sensor.temperature_c
        )

        push!(
            powers,
            sensor.power_kw
        )

        heat +=
            estimate_heat_output(
                sensor
            )
    end

    if isempty(temperatures)

        return
    end

    zone.average_temperature_c =
        mean(temperatures)

    zone.maximum_temperature_c =
        maximum(temperatures)

    zone.minimum_temperature_c =
        minimum(temperatures)

    zone.total_power_kw =
        sum(powers)

    zone.estimated_heat_kw =
        heat

    zone.cooling_demand_kw =
        estimate_cooling_demand(
            system,
            zone
        )

    zone.thermal_headroom_c =
        system.maximum_temperature_c -
        zone.maximum_temperature_c

    zone.hotspot_count =
        count(
            t ->
                t >=
                system.warning_temperature_c,
            temperatures
        )

    temperature_risk =
        clamp(
            (
                zone.maximum_temperature_c -
                system.target_temperature_c
            ) /
            (
                system.maximum_temperature_c -
                system.target_temperature_c
            ),
            0.0,
            1.0
        )

    cooling_risk =
        clamp(
            zone.cooling_demand_kw /
            system.cooling_capacity_kw,
            0.0,
            1.0
        )

    zone.risk_score =
        max(
            temperature_risk,
            cooling_risk
        )
end


# ============================================================
# GLOBAL ANALYTICS
# ============================================================

function analyse!(
    system::DataCentreThermalSystem
)

    system.total_power_kw =
        0.0

    system.total_heat_kw =
        0.0

    system.total_cooling_demand_kw =
        0.0

    for zone in
        values(system.zones)

        analyse_zone!(
            system,
            zone
        )

        system.total_power_kw +=
            zone.total_power_kw

        system.total_heat_kw +=
            zone.estimated_heat_kw

        system.total_cooling_demand_kw +=
            zone.cooling_demand_kw
    end

    if system.total_power_kw > 0

        system.thermal_efficiency =
            system.total_heat_kw /
            system.total_power_kw
    else

        system.thermal_efficiency =
            0.0
    end
end


# ============================================================
# ALERT GENERATION
# ============================================================

function generate_alert!(
    system::DataCentreThermalSystem,
    severity::Symbol,
    sensor::ThermalSensor,
    message::String
)

    alert =
        ThermalAlert(

            now(),

            severity,

            sensor.id,

            sensor.zone,

            message,

            sensor.temperature_c
        )

    push!(
        system.alerts,
        alert
    )
end


# ============================================================
# SENSOR SAFETY ANALYSIS
# ============================================================

function check_sensor!(
    system::DataCentreThermalSystem,
    sensor::ThermalSensor
)

    t =
        sensor.temperature_c

    if !isfinite(t)

        sensor.online =
            false

        generate_alert!(
            system,
            :CRITICAL,
            sensor,
            "Invalid temperature sensor value"
        )

        return
    end

    # Critical threshold.

    if t >=
       system.critical_temperature_c

        generate_alert!(
            system,
            :CRITICAL,
            sensor,
            "Critical thermal condition"
        )

    elseif t >=
           system.warning_temperature_c

        generate_alert!(
            system,
            :WARNING,
            sensor,
            "Thermal warning"
        )
    end

    # Temperature trend.

    rate =
        temperature_rate(
            sensor
        )

    if rate >= 1.0

        generate_alert!(
            system,
            :WARNING,
            sensor,
            "Rapid temperature increase"
        )
    end

    # Sensor sanity.

    if t <
       -10.0 ||
       t >
       100.0

        generate_alert!(
            system,
            :FAULT,
            sensor,
            "Temperature outside expected sensor range"
        )
    end
end


# ============================================================
# HOTSPOT DETECTION
# ============================================================

function find_hotspots(
    system::DataCentreThermalSystem
)

    hotspots =
        ThermalSensor[]

    for sensor in
        values(system.sensors)

        if sensor.online &&
           sensor.temperature_c >=
           system.warning_temperature_c

            push!(
                hotspots,
                sensor
            )
        end
    end

    sort!(
        hotspots,
        by=s -> s.temperature_c,
        rev=true
    )

    return hotspots
end


# ============================================================
# THERMAL HEADROOM
# ============================================================

function thermal_headroom(
    system::DataCentreThermalSystem
)

    if isempty(system.sensors)

        return 0.0
    end

    maximum_temperature =
        maximum(
            s.temperature_c
            for s in values(system.sensors)
            if s.online
        )

    return max(
        system.maximum_temperature_c -
        maximum_temperature,
        0.0
    )
end


# ============================================================
# PREDICT TEMPERATURE
# ============================================================

function predict_temperature(
    sensor::ThermalSensor,
    minutes::Float64
)

    if length(sensor.history) < 2

        return sensor.temperature_c
    end

    rate =
        temperature_rate(
            sensor
        )

    return sensor.temperature_c +
           rate *
           minutes
end


# ============================================================
# PREDICTIVE ALERT
# ============================================================

function predictive_check!(
    system::DataCentreThermalSystem,
    sensor::ThermalSensor;
    horizon_minutes=10.0
)

    predicted =
        predict_temperature(
            sensor,
            horizon_minutes
        )

    if predicted >=
       system.critical_temperature_c

        generate_alert!(
            system,
            :PREDICTIVE_CRITICAL,
            sensor,
            "Predicted critical temperature within forecast horizon"
        )

    elseif predicted >=
           system.warning_temperature_c

        generate_alert!(
            system,
            :PREDICTIVE_WARNING,
            sensor,
            "Predicted thermal warning within forecast horizon"
        )
    end
end


# ============================================================
# COOLING CAPACITY
# ============================================================

function cooling_headroom(
    system::DataCentreThermalSystem
)

    return max(
        system.cooling_capacity_kw -
        system.total_cooling_demand_kw,
        0.0
    )
end


# ============================================================
# THERMAL UTILISATION
# ============================================================

function thermal_utilisation(
    system::DataCentreThermalSystem
)

    if system.cooling_capacity_kw <= 0

        return 1.0
    end

    return clamp(
        system.total_cooling_demand_kw /
        system.cooling_capacity_kw,
        0.0,
        1.0
    )
end


# ============================================================
# MAIN PROCESS CYCLE
# ============================================================

function process_cycle!(
    system::DataCentreThermalSystem
)

    empty!(
        system.alerts
    )

    for sensor in
        values(system.sensors)

        check_sensor!(
            system,
            sensor
        )

        predictive_check!(
            system,
            sensor
        )
    end

    analyse!(
        system
    )

    return system
end


# ============================================================
# SIMULATED SENSOR NETWORK
# ============================================================

function simulate_sensor_noise(
    sensor::ThermalSensor
)

    noise =
        randn() *
        0.08

    load_effect =
        sensor.power_kw *
        0.002

    sensor.temperature_c +=
        noise +
        load_effect
end


# ============================================================
# DIGITAL TWIN SIMULATION
# ============================================================

function simulate!(
    system::DataCentreThermalSystem,
    minutes::Int
)

    cycles =
        Int(
            minutes *
            60 /
            system.sampling_interval_seconds
        )

    for i in 1:cycles

        # Simulate sensor behaviour.

        for sensor in
            values(system.sensors)

            simulate_sensor_noise(
                sensor
            )

            update_sensor!(
                system,
                sensor.id;
                temperature_c=
                    sensor.temperature_c
            )
        end

        process_cycle!(
            system
        )
    end

    return system
end


# ============================================================
# REPORT
# ============================================================

function report(
    system::DataCentreThermalSystem
)

    println()
    println(
        "=========================================================="
    )

    println(
        "             DATA CENTRE THERMAL MONITOR"
    )

    println(
        "=========================================================="
    )

    @printf(
        "Sensors:                 %d\n",
        length(system.sensors)
    )

    @printf(
        "Zones:                   %d\n",
        length(system.zones)
    )

    @printf(
        "IT power:                %.1f kW\n",
        system.total_power_kw
    )

    @printf(
        "Estimated heat:          %.1f kW\n",
        system.total_heat_kw
    )

    @printf(
        "Cooling demand:          %.1f kW\n",
        system.total_cooling_demand_kw
    )

    @printf(
        "Cooling headroom:        %.1f kW\n",
        cooling_headroom(system)
    )

    @printf(
        "Cooling utilisation:     %.1f %%\n",
        thermal_utilisation(system) * 100
    )

    @printf(
        "Thermal headroom:        %.1f °C\n",
        thermal_headroom(system)
    )

    println()

    println(
        "ZONES"
    )

    for zone in
        values(system.zones)

        @printf(
            "%-12s | Avg %.1f°C | Max %.1f°C | Power %.1f kW | Heat %.1f kW | Risk %.1f%%\n",

            zone.id,

            zone.average_temperature_c,

            zone.maximum_temperature_c,

            zone.total_power_kw,

            zone.estimated_heat_kw,

            zone.risk_score * 100
        )
    end

    println()

    println(
        "HOTSPOTS"
    )

    hotspots =
        find_hotspots(
            system
        )

    if isempty(hotspots)

        println(
            "  NONE"
        )

    else

        for sensor in hotspots

            @printf(
                "  %-10s | Rack %-8s | %.1f°C\n",

                sensor.id,

                sensor.rack,

                sensor.temperature_c
            )
        end
    end

    println()

    println(
        "ALERTS"
    )

    if isempty(system.alerts)

        println(
            "  NONE"
        )

    else

        for alert in
            system.alerts

            println(
                "  [",
                alert.severity,
                "] ",
                alert.sensor_id,
                " — ",
                alert.message
            )
        end
    end

    println(
        "=========================================================="
    )
end


# ============================================================
# DEMO DATA CENTRE
# ============================================================

function demo()

    system =
        create_system(
            target_temperature=24.0,
            warning_temperature=27.0,
            critical_temperature=30.0,
            maximum_temperature=35.0,
            cooling_capacity_kw=5000.0
        )

    # Row A

    register_sensor!(
        system,
        "T-A01",
        "RACK-A01",
        "ZONE-A";
        temperature_c=23.2,
        power_kw=18.0
    )

    register_sensor!(
        system,
        "T-A02",
        "RACK-A02",
        "ZONE-A";
        temperature_c=24.0,
        power_kw=22.0
    )

    register_sensor!(
        system,
        "T-A03",
        "RACK-A03",
        "ZONE-A";
        temperature_c=25.1,
        power_kw=30.0
    )

    # Row B

    register_sensor!(
        system,
        "T-B01",
        "RACK-B01",
        "ZONE-B";
        temperature_c=24.3,
        power_kw=35.0
    )

    register_sensor!(
        system,
        "T-B02",
        "RACK-B02",
        "ZONE-B";
        temperature_c=28.2,
        power_kw=42.0
    )

    register_sensor!(
        system,
        "T-B03",
        "RACK-B03",
        "ZONE-B";
        temperature_c=26.0,
        power_kw=28.0
    )

    # High-density AI/HPC zone.

    register_sensor!(
        system,
        "T-H01",
        "RACK-H01",
        "AI-HPC";
        temperature_c=29.0,
        power_kw=80.0
    )

    register_sensor!(
        system,
        "T-H02",
        "RACK-H02",
        "AI-HPC";
        temperature_c=30.5,
        power_kw=95.0
    )

    register_sensor!(
        system,
        "T-H03",
        "RACK-H03",
        "AI-HPC";
        temperature_c=27.8,
        power_kw=75.0
    )

    # Analyse initial state.

    process_cycle!(
        system
    )

    report(
        system
    )

    return system
end


end # module


# ============================================================
# RUN
# ============================================================

using .DataCentreThermalMonitor

DataCentreThermalMonitor.demo()
