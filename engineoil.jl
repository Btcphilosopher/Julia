# ============================================================
# ENGINE OIL CONTROL / OPTIMISATION
# Julia prototype
#
# Variables:
#   oil temperature
#   oil pressure
#   oil pump speed
#   engine speed
#   engine load
# ============================================================

struct OilSystem
    oil_mass::Float64
    oil_specific_heat::Float64
    target_pressure::Float64
    minimum_pressure::Float64
    maximum_pressure::Float64
    target_temperature::Float64
    maximum_temperature::Float64
    minimum_pump_speed::Float64
    maximum_pump_speed::Float64
end

struct EngineState
    rpm::Float64
    load::Float64
    oil_temperature::Float64
    oil_pressure::Float64
    pump_speed::Float64
end


# ============================================================
# SYSTEM
# ============================================================

oil = OilSystem(
    4.5,       # kg oil
    2000.0,    # J/(kg K)
    3.5,       # target bar
    1.5,       # minimum bar
    6.0,       # maximum bar
    100.0,     # target °C
    130.0,     # maximum °C
    800.0,      # minimum pump RPM
    5000.0     # maximum pump RPM
)


# ============================================================
# TARGET OIL PRESSURE
# ============================================================

function target_oil_pressure(
    rpm,
    load,
    system
)

    # Base pressure increases with engine speed/load.
    pressure =
        1.5 +
        0.0007 * rpm +
        1.5 * load

    return clamp(
        pressure,
        system.minimum_pressure,
        system.maximum_pressure
    )
end


# ============================================================
# OIL PUMP CONTROLLER
# ============================================================

function optimise_pump_speed(
    state::EngineState,
    system::OilSystem
)

    target =
        target_oil_pressure(
            state.rpm,
            state.load,
            system
        )

    pressure_error =
        target -
        state.oil_pressure

    # Proportional controller
    gain = 800.0

    pump_change =
        gain * pressure_error

    new_pump_speed =
        state.pump_speed +
        pump_change

    return clamp(
        new_pump_speed,
        system.minimum_pump_speed,
        system.maximum_pump_speed
    )
end


# ============================================================
# OIL TEMPERATURE MODEL
# ============================================================

function update_oil_temperature!(
    state::EngineState,
    system::OilSystem,
    dt
)

    # Simplified engine heat generation
    heat_generation =
        state.load *
        state.rpm *
        0.15

    # Cooling increases with pump speed
    # and temperature difference.
    cooling =
        0.8 *
        (state.oil_temperature - 80.0) *
        (state.pump_speed / 3000.0)

    net_heat =
        heat_generation -
        cooling

    temperature_change =
        net_heat /
        (
            system.oil_mass *
            system.oil_specific_heat
        )

    state.oil_temperature +=
        temperature_change * dt

    return state.oil_temperature
end


# ============================================================
# COMPLETE OIL CONTROL LOOP
# ============================================================

function oil_control!(
    state::EngineState,
    system::OilSystem;
    dt = 0.1
)

    # Determine required pump speed
    state.pump_speed =
        optimise_pump_speed(
            state,
            system
        )

    # Update thermal state
    update_oil_temperature!(
        state,
        system,
        dt
    )

    # Simplified pressure model
    state.oil_pressure =
        0.001 *
        state.pump_speed *
        (
            0.5 +
            state.load
        )

    state.oil_pressure =
        clamp(
            state.oil_pressure,
            0.0,
            system.maximum_pressure
        )

    return state
end


# ============================================================
# EXAMPLE
# ============================================================

engine =
    EngineState(
        2500.0,    # RPM
        0.45,      # engine load
        95.0,      # oil temperature
        2.8,       # oil pressure
        2200.0     # pump RPM
    )


# ============================================================
# SIMULATION
# ============================================================

for t in 0.0:0.1:20.0

    oil_control!(
        engine,
        oil
    )

    println(
        "t=",
        round(t, digits=1),
        "s | RPM=",
        round(engine.rpm),
        " | Load=",
        round(engine.load, digits=2),
        " | Oil T=",
        round(engine.oil_temperature, digits=1),
        "°C | Pressure=",
        round(engine.oil_pressure, digits=2),
        " bar | Pump=",
        round(engine.pump_speed),
        " rpm"
    )
end
