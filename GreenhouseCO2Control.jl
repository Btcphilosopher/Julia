module GreenhouseCO2Control

using Printf
using Statistics

# ============================================================
# GREENHOUSE CO₂ CONTROL / DIGITAL TWIN
# Pure Julia
#
# Models:
#   - CO₂ concentration
#   - Ventilation
#   - Natural CO₂ generation
#   - CO₂ injection
#   - Plant uptake
#   - Temperature
#   - Humidity
#   - Day/night cycle
#   - Energy / CO₂ consumption
#   - PID-style control
#
# This is a simulation/supervisory-control model.
# Production greenhouse equipment should use independently
# validated safety controls and atmospheric monitoring.
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

mutable struct GreenhouseConfig

    volume_m3::Float64

    target_co2_ppm::Float64
    minimum_co2_ppm::Float64
    maximum_co2_ppm::Float64

    outside_co2_ppm::Float64

    target_temperature_c::Float64
    maximum_temperature_c::Float64

    target_humidity_percent::Float64

    maximum_injection_rate_g_h::Float64
    maximum_ventilation_rate_m3_h::Float64

    plant_uptake_max_g_h::Float64

    sunrise_hour::Float64
    sunset_hour::Float64
end


# ============================================================
# GREENHOUSE STATE
# ============================================================

mutable struct GreenhouseState

    time_hours::Float64

    co2_ppm::Float64
    temperature_c::Float64
    humidity_percent::Float64

    light_level::Float64

    ventilation_percent::Float64
    co2_injection_percent::Float64

    plant_uptake_g_h::Float64
    co2_injection_g_h::Float64
    co2_loss_g_h::Float64

    accumulated_co2_g::Float64
    accumulated_water_loss_l::Float64

    alarm_high_co2::Bool
    alarm_low_co2::Bool
    alarm_high_temperature::Bool
end


# ============================================================
# CONTROLLER
# ============================================================

mutable struct CO2Controller

    kp::Float64
    ki::Float64
    kd::Float64

    integral_error::Float64
    previous_error::Float64

    minimum_output::Float64
    maximum_output::Float64
end


# ============================================================
# GREENHOUSE
# ============================================================

mutable struct Greenhouse

    config::GreenhouseConfig

    state::GreenhouseState

    controller::CO2Controller

    total_injected_kg::Float64
    total_uptake_kg::Float64
    total_vented_kg::Float64

    energy_estimate_kwh::Float64

    alarms::Vector{Symbol}
end


# ============================================================
# CREATE CONFIGURATION
# ============================================================

function default_config()

    return GreenhouseConfig(

        10_000.0,

        900.0,
        400.0,
        1_500.0,

        420.0,

        23.0,
        32.0,

        70.0,

        50_000.0,
        150_000.0,

        12_000.0,

        6.0,
        20.0
    )
end


# ============================================================
# CREATE CONTROLLER
# ============================================================

function create_controller()

    return CO2Controller(

        0.002,
        0.00001,
        0.001,

        0.0,
        0.0,

        0.0,
        1.0
    )
end


# ============================================================
# CREATE GREENHOUSE
# ============================================================

function create_greenhouse()

    config =
        default_config()

    state =
        GreenhouseState(

            0.0,

            config.outside_co2_ppm,
            18.0,
            70.0,

            0.0,

            0.0,
            0.0,

            0.0,
            0.0,
            0.0,

            0.0,
            0.0,

            false,
            false,
            false
        )

    return Greenhouse(

        config,

        state,

        create_controller(),

        0.0,
        0.0,
        0.0,

        0.0,

        Symbol[]
    )
end


# ============================================================
# DAY / NIGHT MODEL
# ============================================================

function light_level(
    greenhouse::Greenhouse
)

    t =
        mod(
            greenhouse.state.time_hours,
            24.0
        )

    sunrise =
        greenhouse.config.sunrise_hour

    sunset =
        greenhouse.config.sunset_hour

    if t < sunrise ||
       t > sunset

        return 0.0
    end

    day_length =
        sunset - sunrise

    phase =
        (
            t -
            sunrise
        ) /
        day_length

    # Smooth sunrise/sunset curve.

    return sin(
        π * phase
    )
end


# ============================================================
# PLANT CO₂ UPTAKE
# ============================================================

function calculate_plant_uptake(
    greenhouse::Greenhouse
)

    config =
        greenhouse.config

    state =
        greenhouse.state

    light =
        state.light_level

    if light <= 0.0

        return 0.0
    end

    co2_factor =
        clamp(
            state.co2_ppm /
            config.target_co2_ppm,
            0.0,
            1.5
        )

    temperature_factor =
        exp(
            -(
                state.temperature_c -
                config.target_temperature_c
            )^2 /
            30.0
        )

    uptake =
        config.plant_uptake_max_g_h *
        light *
        co2_factor *
        temperature_factor

    return max(
        uptake,
        0.0
    )
end


# ============================================================
# CO₂ CONCENTRATION CONVERSION
# ============================================================

function ppm_to_grams(
    ppm::Float64,
    volume_m3::Float64
)

    # Approximate air density / CO₂ relationship.
    #
    # At normal greenhouse conditions this gives a useful
    # simulation approximation.

    air_mass_kg =
        volume_m3 *
        1.2

    return air_mass_kg *
           ppm /
           1_000_000.0 *
           44.01 /
           28.97 *
           1000.0
end


function grams_to_ppm(
    grams::Float64,
    volume_m3::Float64
)

    air_mass_kg =
        volume_m3 *
        1.2

    return (
        grams /
        1000.0 /
        air_mass_kg
    ) *
    1_000_000.0 *
    28.97 /
    44.01
end


# ============================================================
# CO₂ LOSS THROUGH VENTILATION
# ============================================================

function ventilation_loss(
    greenhouse::Greenhouse
)

    config =
        greenhouse.config

    state =
        greenhouse.state

    air_exchange =
        config.maximum_ventilation_rate_m3_h *
        state.ventilation_percent

    concentration_difference =
        max(
            state.co2_ppm -
            config.outside_co2_ppm,
            0.0
        )

    return ppm_to_grams(
        concentration_difference,
        air_exchange
    )
end


# ============================================================
# TEMPERATURE MODEL
# ============================================================

function outside_temperature(
    hour::Float64
)

    phase =
        (
            hour -
            8.0
        ) /
        24.0 *
        2π

    return 12.0 +
           7.0 *
           sin(phase)
end


function update_temperature!(
    greenhouse::Greenhouse,
    dt_hours::Float64
)

    state =
        greenhouse.state

    outside =
        outside_temperature(
            state.time_hours
        )

    solar_gain =
        state.light_level *
        6.0

    ventilation_cooling =
        state.ventilation_percent *
        (
            state.temperature_c -
            outside
        ) *
        0.5

    natural_change =
        (
            outside -
            state.temperature_c
        ) *
        0.08

    state.temperature_c +=
        (
            natural_change +
            solar_gain -
            ventilation_cooling
        ) *
        dt_hours

    state.temperature_c =
        clamp(
            state.temperature_c,
            -20.0,
            60.0
        )
end


# ============================================================
# HUMIDITY MODEL
# ============================================================

function update_humidity!(
    greenhouse::Greenhouse,
    dt_hours::Float64
)

    state =
        greenhouse.state

    plant_transpiration =
        state.light_level *
        0.5

    ventilation_drying =
        state.ventilation_percent *
        5.0

    state.humidity_percent +=
        (
            plant_transpiration -
            ventilation_drying
        ) *
        dt_hours

    state.humidity_percent +=
        (
            70.0 -
            state.humidity_percent
        ) *
        0.01 *
        dt_hours

    state.humidity_percent =
        clamp(
            state.humidity_percent,
            0.0,
            100.0
        )
end


# ============================================================
# CO₂ PID CONTROLLER
# ============================================================

function controller_output!(
    controller::CO2Controller,
    target::Float64,
    measured::Float64,
    dt_hours::Float64
)

    error =
        target -
        measured

    controller.integral_error +=
        error *
        dt_hours

    # Anti-windup.

    controller.integral_error =
        clamp(
            controller.integral_error,
            -100_000.0,
            100_000.0
        )

    derivative =
        (
            error -
            controller.previous_error
        ) /
        max(
            dt_hours,
            0.001
        )

    output =
        controller.kp *
        error +

        controller.ki *
        controller.integral_error +

        controller.kd *
        derivative

    controller.previous_error =
        error

    return clamp(
        output,
        controller.minimum_output,
        controller.maximum_output
    )
end


# ============================================================
# VENTILATION CONTROL
# ============================================================

function calculate_ventilation(
    greenhouse::Greenhouse
)

    state =
        greenhouse.state

    config =
        greenhouse.config

    ventilation =
        0.0

    # Temperature override.

    if state.temperature_c >
       config.maximum_temperature_c

        ventilation =
            1.0

    elseif state.temperature_c >
           config.target_temperature_c

        ventilation =
            clamp(
                (
                    state.temperature_c -
                    config.target_temperature_c
                ) /
                8.0,
                0.0,
                1.0
            )
    end

    # Humidity control.

    if state.humidity_percent >
       config.target_humidity_percent +
       10.0

        ventilation =
            max(
                ventilation,
                0.5
            )
    end

    return ventilation
end


# ============================================================
# SAFETY LIMITS
# ============================================================

function safety_control!(
    greenhouse::Greenhouse
)

    state =
        greenhouse.state

    config =
        greenhouse.config

    # High CO₂.

    if state.co2_ppm >=
       config.maximum_co2_ppm

        state.alarm_high_co2 =
            true

        state.co2_injection_percent =
            0.0

        state.ventilation_percent =
            1.0

        push!(
            greenhouse.alarms,
            :HIGH_CO2
        )

    else

        state.alarm_high_co2 =
            false
    end

    # Low CO₂.

    if state.co2_ppm <
       config.minimum_co2_ppm

        state.alarm_low_co2 =
            true

        push!(
            greenhouse.alarms,
            :LOW_CO2
        )

    else

        state.alarm_low_co2 =
            false
    end

    # High temperature.

    if state.temperature_c >=
       config.maximum_temperature_c

        state.alarm_high_temperature =
            true

        state.ventilation_percent =
            1.0

        push!(
            greenhouse.alarms,
            :HIGH_TEMPERATURE
        )

    else

        state.alarm_high_temperature =
            false
    end
end


# ============================================================
# CO₂ MASS BALANCE
# ============================================================

function update_co2!(
    greenhouse::Greenhouse,
    dt_hours::Float64
)

    config =
        greenhouse.config

    state =
        greenhouse.state

    # Plant consumption.

    uptake =
        calculate_plant_uptake(
            greenhouse
        )

    # Controller.

    controller =
        controller_output!(
            greenhouse.controller,

            config.target_co2_ppm,

            state.co2_ppm,

            dt_hours
        )

    state.co2_injection_percent =
        controller

    injection =
        config.maximum_injection_rate_g_h *
        state.co2_injection_percent

    loss =
        ventilation_loss(
            greenhouse
        )

    net_change_g =
        (
            injection -
            uptake -
            loss
        ) *
        dt_hours

    current_mass =
        ppm_to_grams(
            state.co2_ppm,
            config.volume_m3
        )

    new_mass =
        max(
            0.0,
            current_mass +
            net_change_g
        )

    state.co2_ppm =
        grams_to_ppm(
            new_mass,
            config.volume_m3
        )

    state.plant_uptake_g_h =
        uptake

    state.co2_injection_g_h =
        injection

    state.co2_loss_g_h =
        loss

    greenhouse.total_injected_kg +=
        injection *
        dt_hours /
        1000.0

    greenhouse.total_uptake_kg +=
        uptake *
        dt_hours /
        1000.0

    greenhouse.total_vented_kg +=
        loss *
        dt_hours /
        1000.0

    state.accumulated_co2_g +=
        injection *
        dt_hours
end


# ============================================================
# ENERGY MODEL
# ============================================================

function update_energy!(
    greenhouse::Greenhouse,
    dt_hours::Float64
)

    state =
        greenhouse.state

    fan_power_kw =
        state.ventilation_percent *
        15.0

    injection_system_kw =
        state.co2_injection_percent *
        2.0

    greenhouse.energy_estimate_kwh +=
        (
            fan_power_kw +
            injection_system_kw
        ) *
        dt_hours
end


# ============================================================
# MAIN CONTROL LOOP
# ============================================================

function update!(
    greenhouse::Greenhouse,
    dt_hours::Float64
)

    state =
        greenhouse.state

    state.time_hours +=
        dt_hours

    # Light.

    state.light_level =
        light_level(
            greenhouse
        )

    # Ventilation.

    state.ventilation_percent =
        calculate_ventilation(
            greenhouse
        )

    # Environment.

    update_temperature!(
        greenhouse,
        dt_hours
    )

    update_humidity!(
        greenhouse,
        dt_hours
    )

    # CO₂ control.

    update_co2!(
        greenhouse,
        dt_hours
    )

    # Safety.

    safety_control!(
        greenhouse
    )

    # Energy.

    update_energy!(
        greenhouse,
        dt_hours
    )
end


# ============================================================
# PREDICTIVE CONTROL
# ============================================================

function predict_co2(
    greenhouse::Greenhouse,
    future_hours::Float64
)

    state =
        greenhouse.state

    config =
        greenhouse.config

    injection =
        state.co2_injection_g_h

    uptake =
        state.plant_uptake_g_h

    loss =
        state.co2_loss_g_h

    current =
        ppm_to_grams(
            state.co2_ppm,
            config.volume_m3
        )

    predicted =
        current +
        (
            injection -
            uptake -
            loss
        ) *
        future_hours

    return grams_to_ppm(
        max(predicted, 0.0),
        config.volume_m3
    )
end


# ============================================================
# OPTIMAL CO₂ TARGET
# ============================================================

function optimise_target(
    greenhouse::Greenhouse
)

    config =
        greenhouse.config

    state =
        greenhouse.state

    # Higher CO₂ target during strong light.
    #
    # In a production greenhouse this would normally be
    # calibrated against crop-specific photosynthesis,
    # economics, outside weather and ventilation state.

    if state.light_level < 0.05

        return config.minimum_co2_ppm
    end

    light_bonus =
        300.0 *
        state.light_level

    temperature_penalty =
        max(
            0.0,
            state.temperature_c -
            config.target_temperature_c
        ) *
        30.0

    return clamp(
        600.0 +
        light_bonus -
        temperature_penalty,

        config.minimum_co2_ppm,

        config.maximum_co2_ppm
    )
end


# ============================================================
# ADAPTIVE CONTROL
# ============================================================

function adaptive_control!(
    greenhouse::Greenhouse
)

    target =
        optimise_target(
            greenhouse
        )

    greenhouse.config.target_co2_ppm =
        target
end


# ============================================================
# REPORT
# ============================================================

function report(
    greenhouse::Greenhouse
)

    state =
        greenhouse.state

    println()
    println(
        "=========================================================="
    )

    println(
        "             GREENHOUSE CO₂ CONTROL"
    )

    println(
        "=========================================================="
    )

    @printf(
        "Time:                    %.2f h\n",
        state.time_hours
    )

    @printf(
        "CO₂:                     %.0f ppm\n",
        state.co2_ppm
    )

    @printf(
        "Target CO₂:              %.0f ppm\n",
        greenhouse.config.target_co2_ppm
    )

    @printf(
        "Temperature:             %.1f °C\n",
        state.temperature_c
    )

    @printf(
        "Humidity:                %.1f %%\n",
        state.humidity_percent
    )

    @printf(
        "Light:                   %.2f\n",
        state.light_level
    )

    println()

    @printf(
        "CO₂ injection:            %.1f g/h\n",
        state.co2_injection_g_h
    )

    @printf(
        "Plant uptake:             %.1f g/h\n",
        state.plant_uptake_g_h
    )

    @printf(
        "Ventilation loss:         %.1f g/h\n",
        state.co2_loss_g_h
    )

    println()

    @printf(
        "Total CO₂ injected:       %.2f kg\n",
        greenhouse.total_injected_kg
    )

    @printf(
        "Total estimated uptake:   %.2f kg\n",
        greenhouse.total_uptake_kg
    )

    @printf(
        "Total vented:             %.2f kg\n",
        greenhouse.total_vented_kg
    )

    @printf(
        "Energy estimate:          %.2f kWh\n",
        greenhouse.energy_estimate_kwh
    )

    println()

    println(
        "ALARMS"
    )

    alarms =
        unique(
            greenhouse.alarms
        )

    if isempty(alarms)

        println(
            "  NONE"
        )

    else

        for alarm in alarms

            println(
                "  ⚠ ",
                alarm
            )
        end
    end

    println(
        "=========================================================="
    )
end


# ============================================================
# SIMULATION
# ============================================================

function demo()

    greenhouse =
        create_greenhouse()

    timestep =
        1.0 / 60.0

    simulation_hours =
        48.0

    steps =
        Int(
            simulation_hours /
            timestep
        )

    for _ in 1:steps

        adaptive_control!(
            greenhouse
        )

        update!(
            greenhouse,
            timestep
        )
    end

    report(
        greenhouse
    )

    println()

    @printf(
        "Predicted CO₂ after 1 hour: %.0f ppm\n",
        predict_co2(
            greenhouse,
            1.0
        )
    )

    return greenhouse
end


end # module


# ============================================================
# RUN
# ============================================================

using .GreenhouseCO2Control

GreenhouseCO2Control.demo()
