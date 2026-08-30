# ============================================================
# SMARTPICK INDUSTRY 4.0
# Digital Twin + Telemetry Simulator for a Smart Mining Pickaxe
# Julia
# ============================================================

using Random
using Statistics
using Dates

# ------------------------------------------------------------
# 1. PICKAXE CONFIGURATION
# ------------------------------------------------------------

struct PickaxeConfig
    model::String
    mass_kg::Float64
    head_mass_kg::Float64
    nominal_impact_energy_J::Float64
    max_impact_energy_J::Float64
    nominal_rpm::Float64
    battery_Wh::Float64
    sensor_count::Int
end

const SMART_PICKAXE = PickaxeConfig(
    "SPX-4000",
    4.8,
    2.1,
    850.0,
    1400.0,
    120.0,
    180.0,
    12
)

# ------------------------------------------------------------
# 2. ROCK / ORE MODEL
# ------------------------------------------------------------

struct RockMaterial
    name::String
    hardness::Float64
    density_kg_m3::Float64
    fragmentation_factor::Float64
    ore_grade::Float64
end

const ROCK_TYPES = [
    RockMaterial("Soft Sandstone", 2.5, 2200.0, 1.25, 0.02),
    RockMaterial("Limestone",       3.5, 2600.0, 1.00, 0.04),
    RockMaterial("Granite",         6.5, 2750.0, 0.72, 0.01),
    RockMaterial("Quartzite",      7.0, 2700.0, 0.55, 0.008),
    RockMaterial("Iron Ore",       6.0, 5000.0, 0.85, 0.35),
    RockMaterial("Copper Ore",     5.0, 4300.0, 0.92, 0.025)
]

# ------------------------------------------------------------
# 3. SENSOR TELEMETRY
# ------------------------------------------------------------

mutable struct Telemetry
    timestamp::DateTime

    acceleration_g::Float64
    vibration_rms::Float64
    impact_energy_J::Float64

    temperature_C::Float64
    motor_temperature_C::Float64

    battery_pct::Float64
    current_A::Float64
    voltage_V::Float64

    rpm::Float64
    force_kN::Float64

    tool_wear_pct::Float64
    impacts::Int

    productivity_kg::Float64
    ore_recovered_kg::Float64

    gps_x::Float64
    gps_y::Float64
    gps_z::Float64
end

# ------------------------------------------------------------
# 4. DIGITAL TWIN STATE
# ------------------------------------------------------------

mutable struct PickaxeTwin
    config::PickaxeConfig
    material::RockMaterial
    telemetry::Telemetry

    operating_hours::Float64
    cumulative_energy_Wh::Float64
    cumulative_material_kg::Float64

    maintenance_required::Bool
    fault_state::String
end

function initialise_twin(config, material)

    telemetry = Telemetry(
        now(),

        0.0,       # acceleration
        0.0,       # vibration
        0.0,       # impact energy

        25.0,      # ambient temperature
        30.0,      # motor temperature

        100.0,     # battery
        0.0,       # current
        48.0,      # voltage

        0.0,       # rpm
        0.0,       # force

        0.0,       # wear
        0,         # impacts

        0.0,       # productivity
        0.0,       # ore

        0.0, 0.0, 0.0
    )

    return PickaxeTwin(
        config,
        material,
        telemetry,
        0.0,
        0.0,
        0.0,
        false,
        "NORMAL"
    )
end

# ------------------------------------------------------------
# 5. IMPACT PHYSICS
# ------------------------------------------------------------

function calculate_impact_energy(twin::PickaxeTwin)

    base = twin.config.nominal_impact_energy_J

    hardness_penalty =
        1.0 + 0.06 * twin.material.hardness

    randomness =
        rand(0.90:0.01:1.10)

    energy =
        base * randomness * min(hardness_penalty, 1.45)

    return min(
        energy,
        twin.config.max_impact_energy_J
    )
end

# ------------------------------------------------------------
# 6. ROCK FRAGMENTATION
# ------------------------------------------------------------

function calculate_fragmentation(
    twin::PickaxeTwin,
    impact_energy::Float64
)

    hardness = twin.material.hardness

    efficiency =
        (impact_energy / 1000.0) *
        twin.material.fragmentation_factor /
        hardness

    # Approximate fragmented mass per impact
    mass =
        0.12 *
        efficiency *
        1000.0

    return max(mass, 0.0)
end

# ------------------------------------------------------------
# 7. TOOL WEAR
# ------------------------------------------------------------

function calculate_wear(
    twin::PickaxeTwin,
    impact_energy::Float64
)

    hardness_factor =
        twin.material.hardness / 7.0

    wear =
        0.000025 *
        impact_energy *
        hardness_factor

    return wear
end

# ------------------------------------------------------------
# 8. ENERGY CONSUMPTION
# ------------------------------------------------------------

function calculate_power(
    twin::PickaxeTwin,
    impact_energy::Float64
)

    mechanical_power =
        impact_energy * 2.0

    electrical_efficiency = 0.82

    electrical_power =
        mechanical_power /
        electrical_efficiency

    return electrical_power
end

# ------------------------------------------------------------
# 9. PREDICTIVE MAINTENANCE
# ------------------------------------------------------------

function evaluate_condition(twin::PickaxeTwin)

    t = twin.telemetry

    if t.tool_wear_pct > 85

        twin.maintenance_required = true
        twin.fault_state = "TOOL WEAR CRITICAL"

    elseif t.motor_temperature_C > 90

        twin.maintenance_required = true
        twin.fault_state = "MOTOR OVERHEATING"

    elseif t.vibration_rms > 9.0

        twin.maintenance_required = true
        twin.fault_state = "ABNORMAL VIBRATION"

    elseif t.battery_pct < 10

        twin.maintenance_required = true
        twin.fault_state = "LOW BATTERY"

    else

        twin.maintenance_required = false
        twin.fault_state = "NORMAL"
    end
end

# ------------------------------------------------------------
# 10. SINGLE IMPACT
# ------------------------------------------------------------

function perform_impact!(twin::PickaxeTwin)

    energy = calculate_impact_energy(twin)

    fragmented =
        calculate_fragmentation(
            twin,
            energy
        )

    wear =
        calculate_wear(
            twin,
            energy
        )

    power =
        calculate_power(
            twin,
            energy
        )

    t = twin.telemetry

    # Sensor simulation
    t.timestamp = now()

    t.impact_energy_J = energy

    t.acceleration_g =
        5.0 +
        energy / 250.0 +
        randn() * 0.4

    t.vibration_rms =
        2.0 +
        twin.material.hardness / 2.0 +
        randn() * 0.25

    t.force_kN =
        sqrt(energy) * 0.45

    t.rpm =
        twin.config.nominal_rpm +
        randn() * 4.0

    # Thermal behaviour
    t.motor_temperature_C +=
        power / 3000.0

    t.temperature_C +=
        0.002 * power

    # Electrical system
    t.voltage_V =
        48.0 - rand() * 1.5

    t.current_A =
        power / t.voltage_V

    battery_consumption =
        power / 3600.0

    t.battery_pct -=
        100.0 *
        battery_consumption /
        twin.config.battery_Wh

    # Wear
    t.tool_wear_pct += wear

    # Production
    t.impacts += 1

    t.productivity_kg = fragmented

    t.ore_recovered_kg =
        fragmented *
        twin.material.ore_grade

    twin.cumulative_material_kg +=
        fragmented

    twin.cumulative_energy_Wh +=
        battery_consumption

    twin.operating_hours +=
        1.0 / 3600.0

    # Position simulation
    t.gps_x += randn() * 0.02
    t.gps_y += randn() * 0.02
    t.gps_z += randn() * 0.005

    evaluate_condition(twin)
end

# ------------------------------------------------------------
# 11. DIGITAL TWIN SIMULATION
# ------------------------------------------------------------

function simulate!(
    twin::PickaxeTwin,
    impacts::Int
)

    println()
    println("==============================================")
    println(" SMARTPICK DIGITAL TWIN")
    println("==============================================")
    println("Model:       ", twin.config.model)
    println("Material:    ", twin.material.name)
    println("Hardness:    ", twin.material.hardness)
    println()

    for i in 1:impacts

        if twin.telemetry.battery_pct <= 0
            println("BATTERY DEPLETED")
            break
        end

        if twin.telemetry.tool_wear_pct >= 100
            println("TOOL FAILURE")
            break
        end

        perform_impact!(twin)

        if i % 100 == 0

            println(
                "Impact ", i,
                " | Energy ",
                round(twin.telemetry.impact_energy_J, digits=1),
                " J",
                " | Wear ",
                round(twin.telemetry.tool_wear_pct, digits=2),
                "%",
                " | Battery ",
                round(twin.telemetry.battery_pct, digits=1),
                "%",
                " | Material ",
                round(twin.cumulative_material_kg, digits=1),
                " kg"
            )

        end
    end

    println()
    println("--------------- FINAL STATE ----------------")

    println(
        "Total impacts: ",
        twin.telemetry.impacts
    )

    println(
        "Material mined: ",
        round(
            twin.cumulative_material_kg,
            digits=2
        ),
        " kg"
    )

    println(
        "Ore recovered: ",
        round(
            twin.telemetry.ore_recovered_kg,
            digits=2
        ),
        " kg"
    )

    println(
        "Energy consumed: ",
        round(
            twin.cumulative_energy_Wh,
            digits=2
        ),
        " Wh"
    )

    println(
        "Tool wear: ",
        round(
            twin.telemetry.tool_wear_pct,
            digits=2
        ),
        "%"
    )

    println(
        "Battery: ",
        round(
            twin.telemetry.battery_pct,
            digits=2
        ),
        "%"
    )

    println(
        "Condition: ",
        twin.fault_state
    )

    println("==============================================")
end

# ------------------------------------------------------------
# 12. RUN THE DIGITAL TWIN
# ------------------------------------------------------------

rock = ROCK_TYPES[5]   # Iron Ore

twin =
    initialise_twin(
        SMART_PICKAXE,
        rock
    )

simulate!(
    twin,
    5000
)
