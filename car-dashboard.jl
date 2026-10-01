# ============================================================
# AUREOM REAL-TIME VEHICLE DASHBOARD
# Julia telemetry / dashboard engine
#
# Research / simulation implementation.
#
# Designed around:
#   Vehicle ECU / CAN data
#          ↓
#   VehicleState
#          ↓
#   Derived statistics
#          ↓
#   DashboardState
#          ↓
#   Display renderer
# ============================================================

using Dates
using Printf


# ------------------------------------------------------------
# VEHICLE STATE
# ------------------------------------------------------------

mutable struct VehicleState

    timestamp::DateTime

    # Drivetrain
    speed_kmh::Float64
    rpm::Float64
    gear::Int
    throttle::Float64
    engine_load::Float64

    # Battery / electrical
    battery_soc::Float64
    battery_voltage::Float64
    battery_current::Float64
    battery_power_kw::Float64
    battery_temperature::Float64

    # Thermal
    coolant_temperature::Float64
    oil_temperature::Float64

    # Chassis
    steering_angle::Float64
    lateral_acceleration::Float64
    longitudinal_acceleration::Float64
    yaw_rate::Float64

    # Brakes
    brake_pressure::Float64
    brake_temperature::Float64
    regenerative_power_kw::Float64

    # Tyres
    tyre_fl::Float64
    tyre_fr::Float64
    tyre_rl::Float64
    tyre_rr::Float64

    # Range / energy
    range_km::Float64
    energy_consumption_kwh100::Float64

end


# ------------------------------------------------------------
# DASHBOARD STATE
# ------------------------------------------------------------

mutable struct DashboardState

    speed::Float64
    rpm::Float64
    gear::Int

    battery_soc::Float64
    battery_power::Float64
    battery_temperature::Float64

    coolant_temperature::Float64
    oil_temperature::Float64

    range_km::Float64

    lateral_g::Float64
    longitudinal_g::Float64

    steering_angle::Float64

    brake_pressure::Float64
    regen_power::Float64

    tyre_pressure::Vector{Float64}

    warning::String

    update_counter::Int

    last_update::DateTime

end


# ------------------------------------------------------------
# CONSTRUCTOR
# ------------------------------------------------------------

function create_dashboard()

    return DashboardState(
        0.0,
        0.0,
        0,

        100.0,
        0.0,
        25.0,

        90.0,
        90.0,

        0.0,

        0.0,
        0.0,

        0.0,

        0.0,
        0.0,

        [2.4, 2.4, 2.4, 2.4],

        "OK",

        0,

        now()
    )

end


# ------------------------------------------------------------
# CONVERT VEHICLE STATE → DASHBOARD STATE
# ------------------------------------------------------------

function update_dashboard!(
    dashboard::DashboardState,
    vehicle::VehicleState
)

    dashboard.speed =
        vehicle.speed_kmh

    dashboard.rpm =
        vehicle.rpm

    dashboard.gear =
        vehicle.gear

    dashboard.battery_soc =
        vehicle.battery_soc

    dashboard.battery_power =
        vehicle.battery_power_kw

    dashboard.battery_temperature =
        vehicle.battery_temperature

    dashboard.coolant_temperature =
        vehicle.coolant_temperature

    dashboard.oil_temperature =
        vehicle.oil_temperature

    dashboard.range_km =
        vehicle.range_km

    dashboard.lateral_g =
        vehicle.lateral_acceleration /
        9.80665

    dashboard.longitudinal_g =
        vehicle.longitudinal_acceleration /
        9.80665

    dashboard.steering_angle =
        vehicle.steering_angle

    dashboard.brake_pressure =
        vehicle.brake_pressure

    dashboard.regen_power =
        vehicle.regenerative_power_kw

    dashboard.tyre_pressure = [
        vehicle.tyre_fl,
        vehicle.tyre_fr,
        vehicle.tyre_rl,
        vehicle.tyre_rr
    ]

    dashboard.warning =
        calculate_warning(
            vehicle
        )

    dashboard.update_counter += 1

    dashboard.last_update =
        vehicle.timestamp

end


# ------------------------------------------------------------
# WARNING ENGINE
# ------------------------------------------------------------

function calculate_warning(
    vehicle::VehicleState
)

    if vehicle.battery_temperature > 48

        return "BATTERY TEMP"

    elseif vehicle.coolant_temperature > 110

        return "COOLANT TEMP"

    elseif vehicle.oil_temperature > 125

        return "OIL TEMP"

    elseif minimum(
        vehicle.tyre_fl,
        vehicle.tyre_fr,
        vehicle.tyre_rl,
        vehicle.tyre_rr
    ) < 1.8

        return "TYRE PRESSURE"

    elseif vehicle.battery_soc < 10

        return "LOW BATTERY"

    elseif vehicle.brake_temperature > 500

        return "BRAKE TEMP"

    else

        return "OK"
    end

end


# ------------------------------------------------------------
# TELEMETRY SIMULATION
# ------------------------------------------------------------

function simulated_vehicle(
    t
)

    speed =
        80.0 +
        15.0 *
        sin(t / 5.0)

    rpm =
        2200.0 +
        800.0 *
        sin(t / 4.0)

    battery_soc =
        72.0 -
        t * 0.015

    battery_power =
        35.0 +
        20.0 *
        sin(t / 3.0)

    battery_temperature =
        28.0 +
        4.0 *
        sin(t / 10.0)

    coolant =
        88.0 +
        4.0 *
        sin(t / 8.0)

    oil =
        94.0 +
        6.0 *
        sin(t / 7.0)

    steering =
        4.0 *
        sin(t / 3.0)

    lateral =
        1.5 *
        sin(t / 3.0)

    longitudinal =
        0.8 *
        cos(t / 4.0)

    regen =
        max(
            0.0,
            -battery_power
        )

    VehicleState(

        now(),

        speed,
        rpm,
        7,

        0.45,
        0.0,
        battery_power,
        battery_power * 1000 / 800,
        battery_temperature,

        coolant,
        oil,

        steering,
        lateral,
        longitudinal,
        0.1,

        0.0,
        80.0,
        regen,

        2.4,
        2.4,
        2.4,
        2.4,

        420.0,
        18.5
    )

end


# ------------------------------------------------------------
# DASHBOARD CONSOLE RENDERER
#
# This is intentionally simple. Replace this function
# with your graphical renderer.
# ------------------------------------------------------------

function render_dashboard(
    dashboard::DashboardState
)

    print("\033[2J")
    print("\033[H")

    println(
        "=========================================================="
    )

    println(
        "                 AUREOM VEHICLE SYSTEM"
    )

    println(
        "=========================================================="
    )

    @printf(
        "\n SPEED       %6.1f km/h\n",
        dashboard.speed
    )

    @printf(
        " RPM         %6.0f\n",
        dashboard.rpm
    )

    @printf(
        " GEAR        %6d\n",
        dashboard.gear
    )

    println(
        "----------------------------------------------------------"
    )

    @printf(
        " BATTERY     %6.1f %%\n",
        dashboard.battery_soc
    )

    @printf(
        " POWER       %6.1f kW\n",
        dashboard.battery_power
    )

    @printf(
        " BATTERY TEMP%5.1f °C\n",
        dashboard.battery_temperature
    )

    @printf(
        " RANGE       %6.0f km\n",
        dashboard.range_km
    )

    println(
        "----------------------------------------------------------"
    )

    @printf(
        " COOLANT     %6.1f °C\n",
        dashboard.coolant_temperature
    )

    @printf(
        " OIL         %6.1f °C\n",
        dashboard.oil_temperature
    )

    @printf(
        " STEERING    %6.1f °\n",
        dashboard.steering_angle
    )

    @printf(
        " LATERAL     %6.2f G\n",
        dashboard.lateral_g
    )

    @printf(
        " LONGITUDINAL%6.2f G\n",
        dashboard.longitudinal_g
    )

    println(
        "----------------------------------------------------------"
    )

    println(" TYRES")

    @printf(
        " FL %.2f bar    FR %.2f bar\n",
        dashboard.tyre_pressure[1],
        dashboard.tyre_pressure[2]
    )

    @printf(
        " RL %.2f bar    RR %.2f bar\n",
        dashboard.tyre_pressure[3],
        dashboard.tyre_pressure[4]
    )

    println(
        "----------------------------------------------------------"
    )

    @printf(
        " REGEN        %6.1f kW\n",
        dashboard.regen_power
    )

    println()

    if dashboard.warning == "OK"

        println(" SYSTEM STATUS: OK")

    else

        println(
            " ⚠ WARNING: ",
            dashboard.warning
        )

    end

    println()

    println(
        " UPDATE #",
        dashboard.update_counter
    )

    println(
        "=========================================================="
    )

end


# ------------------------------------------------------------
# REAL-TIME LOOP
# ------------------------------------------------------------

function run_dashboard(
    duration_seconds = 30.0
)

    dashboard =
        create_dashboard()

    start_time =
        time()

    while (
        time() -
        start_time
    ) < duration_seconds

        elapsed =
            time() -
            start_time

        # Replace this with actual CAN/ECU telemetry.
        vehicle =
            simulated_vehicle(
                elapsed
            )

        update_dashboard!(
            dashboard,
            vehicle
        )

        render_dashboard(
            dashboard
        )

        # 20 Hz dashboard update
        sleep(0.05)

    end

end


# ------------------------------------------------------------
# START
# ------------------------------------------------------------

run_dashboard(30.0)
