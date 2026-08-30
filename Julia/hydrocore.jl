hydrocore.jl


# ================================================================
# HYDROCORE
# Industry 4.0 Autonomous Hydroponic Farm Digital Twin
#
# Julia prototype
#
# Models:
#   - Hydroponic growing trays
#   - Motorised rail carriages
#   - Rail traffic
#   - Crop growth
#   - Lighting
#   - Irrigation
#   - Nutrients / EC / pH
#   - Harvest scheduling
#   - Energy consumption
#   - Equipment wear
#   - Predictive maintenance
#   - Autonomous supervisory control
#
# IMPORTANT:
# This is a simulation/supervisory prototype.
# Real machinery should use certified industrial safety
# controllers/PLCs for hard real-time safety functions.
# ================================================================

using Random
using Statistics
using Dates

Random.seed!(42)

# ================================================================
# CONFIGURATION
# ================================================================

const SIMULATION_STEP_MINUTES = 1.0

const MAX_RAIL_SPEED = 0.8          # m/s
const MAX_RAIL_ACCEL = 0.25         # m/s²
const SAFE_DISTANCE = 1.5           # metres

const LIGHT_TARGET_HOURS = 16.0

const MIN_PH = 5.5
const MAX_PH = 6.5

const MIN_EC = 1.2
const MAX_EC = 2.2

const TARGET_TEMPERATURE = 21.0

# ================================================================
# ENUMERATIONS / STATES
# ================================================================

@enum TrayStatus begin
    GROWING
    MOVING
    IRRIGATION
    LIGHTING
    HARVEST_READY
    HARVESTING
    MAINTENANCE
end

@enum RailState begin
    IDLE
    MOVING
    FAULT
    EMERGENCY_STOP
end

# ================================================================
# CROP MODEL
# ================================================================

struct CropProfile

    name::String

    optimal_temp::Float64
    optimal_ph::Float64
    optimal_ec::Float64

    max_biomass_kg::Float64

    growth_rate::Float64

    water_requirement::Float64
    light_requirement::Float64

    harvest_threshold::Float64
end


const LETTUCE = CropProfile(
    "Lettuce",
    20.0,
    6.0,
    1.6,
    0.45,
    0.0018,
    0.015,
    16.0,
    0.90
)

const BASIL = CropProfile(
    "Basil",
    22.0,
    5.9,
    1.8,
    0.35,
    0.0015,
    0.012,
    16.0,
    0.90
)

const TOMATO = CropProfile(
    "Tomato",
    23.0,
    6.1,
    2.2,
    2.50,
    0.0012,
    0.035,
    18.0,
    0.92
)

const CROPS = [
    LETTUCE,
    BASIL,
    TOMATO
]

# ================================================================
# RAIL INFRASTRUCTURE
# ================================================================

mutable struct Rail

    id::Int

    length_m::Float64

    state::RailState

    energy_kwh::Float64

    motor_temperature::Float64

    wear_pct::Float64

    current_tray::Union{Nothing,Int}

    maintenance_due::Bool
end


mutable struct RailCarriage

    id::Int

    rail_id::Int

    position_m::Float64

    velocity_mps::Float64

    target_position_m::Float64

    acceleration_mps2::Float64

    state::RailState

    energy_kwh::Float64

    motor_temperature::Float64

    motor_wear_pct::Float64
end

# ================================================================
# GROWING TRAY
# ================================================================

mutable struct GrowingTray

    id::Int

    crop::CropProfile

    age_hours::Float64

    biomass_kg::Float64

    health_pct::Float64

    temperature_C::Float64

    humidity_pct::Float64

    ph::Float64

    ec::Float64

    light_hours::Float64

    water_stress::Float64

    nutrient_stress::Float64

    growth_rate::Float64

    location_rail::Int

    location_position::Float64

    destination::Union{Nothing,Symbol}

    status::TrayStatus

    priority::Float64

    harvest_progress::Float64

    irrigation_required::Bool

    lighting_required::Bool

    inspection_required::Bool
end

# ================================================================
# FARM STATE
# ================================================================

mutable struct Farm

    rails::Vector{Rail}

    carriages::Vector{RailCarriage}

    trays::Vector{GrowingTray}

    simulation_minutes::Float64

    total_energy_kwh::Float64

    total_water_litres::Float64

    total_harvest_kg::Float64

    harvested_trays::Int

    rail_energy_kwh::Float64

    lighting_energy_kwh::Float64

    irrigation_energy_kwh::Float64

    production_energy_kwh::Float64

    alarms::Vector{String}
end

# ================================================================
# CREATE FARM
# ================================================================

function create_farm(
    number_of_rails::Int = 6,
    trays_per_rail::Int = 20
)

    rails = Rail[]

    carriages = RailCarriage[]

    trays = GrowingTray[]

    for r in 1:number_of_rails

        push!(
            rails,
            Rail(
                r,
                100.0,
                IDLE,
                0.0,
                25.0,
                0.0,
                nothing,
                false
            )
        )

        push!(
            carriages,
            RailCarriage(
                r,
                r,
                0.0,
                0.0,
                0.0,
                0.0,
                IDLE,
                0.0,
                25.0,
                0.0
            )
        )

        for i in 1:trays_per_rail

            crop = rand(CROPS)

            position =
                (i - 1) *
                (100.0 / trays_per_rail)

            tray = GrowingTray(

                length(trays) + 1,

                crop,

                rand(10.0:0.5:120.0),

                rand(
                    0.05:
                    0.01:
                    crop.max_biomass_kg * 0.8
                ),

                rand(85.0:0.5:100.0),

                rand(19.0:0.2:23.0),

                rand(55.0:1.0:75.0),

                rand(5.7:0.05:6.3),

                rand(1.3:0.05:2.0),

                rand(4.0:0.5:15.0),

                0.0,

                0.0,

                crop.growth_rate,

                r,

                position,

                nothing,

                GROWING,

                0.0,

                0.0,

                false,

                false,

                false
            )

            push!(trays, tray)
        end
    end

    return Farm(
        rails,
        carriages,
        trays,
        0.0,
        0.0,
        0.0,
        0,
        0.0,
        0.0,
        0.0,
        0.0,
        String[]
    )
end

# ================================================================
# ENVIRONMENT MODEL
# ================================================================

function environment_temperature(
    farm::Farm
)

    hour =
        mod(
            farm.simulation_minutes / 60.0,
            24.0
        )

    # Simple greenhouse temperature cycle
    base =
        20.0 +
        4.0 *
        sin(
            2π *
            (hour - 6.0) /
            24.0
        )

    return base
end

# ================================================================
# CROP HEALTH MODEL
# ================================================================

function evaluate_crop_environment!(
    tray::GrowingTray,
    farm::Farm
)

    ambient =
        environment_temperature(farm)

    tray.temperature_C =
        0.9 * tray.temperature_C +
        0.1 * ambient

    # Temperature stress

    temperature_error =
        abs(
            tray.temperature_C -
            tray.crop.optimal_temp
        )

    temperature_stress =
        clamp(
            temperature_error / 10.0,
            0.0,
            1.0
        )

    # pH stress

    ph_stress =
        if tray.ph < MIN_PH
            (MIN_PH - tray.ph) / 1.0
        elseif tray.ph > MAX_PH
            (tray.ph - MAX_PH) / 1.0
        else
            0.0
        end

    # EC stress

    ec_stress =
        if tray.ec < MIN_EC
            (MIN_EC - tray.ec) / 1.0
        elseif tray.ec > MAX_EC
            (tray.ec - MAX_EC) / 1.0
        else
            0.0
        end

    tray.water_stress =
        clamp(
            tray.water_stress +
            0.001 -
            0.003,
            0.0,
            1.0
        )

    tray.nutrient_stress =
        clamp(
            ph_stress * 0.5 +
            ec_stress * 0.5,
            0.0,
            1.0
        )

    health_penalty =
        temperature_stress * 0.15 +
        ph_stress * 0.30 +
        ec_stress * 0.30 +
        tray.water_stress * 0.25

    tray.health_pct =
        clamp(
            tray.health_pct -
            health_penalty * 0.01,
            0.0,
            100.0
        )

end

# ================================================================
# CROP GROWTH
# ================================================================

function grow_crop!(
    tray::GrowingTray,
    farm::Farm
)

    evaluate_crop_environment!(
        tray,
        farm
    )

    light_factor =
        clamp(
            tray.light_hours /
            tray.crop.light_requirement,
            0.0,
            1.0
        )

    temperature_factor =
        exp(
            -(
                tray.temperature_C -
                tray.crop.optimal_temp
            )^2 / 20.0
        )

    water_factor =
        1.0 -
        tray.water_stress

    nutrient_factor =
        1.0 -
        tray.nutrient_stress

    health_factor =
        tray.health_pct / 100.0

    growth_factor =
        light_factor *
        temperature_factor *
        water_factor *
        nutrient_factor *
        health_factor

    # Growth per simulation hour

    growth =
        tray.crop.growth_rate *
        growth_factor

    tray.biomass_kg =
        min(
            tray.biomass_kg + growth,
            tray.crop.max_biomass_kg
        )

    tray.growth_rate = growth

    tray.age_hours +=
        SIMULATION_STEP_MINUTES / 60.0

    # Lighting requirement

    if tray.light_hours <
       tray.crop.light_requirement

        tray.lighting_required = true
    else
        tray.lighting_required = false
    end

    # Irrigation requirement

    if tray.water_stress > 0.35

        tray.irrigation_required = true
    else
        tray.irrigation_required = false
    end

end

# ================================================================
# LIGHTING SYSTEM
# ================================================================

function operate_lighting!(
    farm::Farm,
    tray::GrowingTray
)

    if !tray.lighting_required
        return
    end

    # LED energy consumption

    led_power_kw = 0.15

    energy =
        led_power_kw *
        SIMULATION_STEP_MINUTES /
        60.0

    farm.lighting_energy_kwh += energy
    farm.total_energy_kwh += energy

    tray.light_hours +=
        SIMULATION_STEP_MINUTES / 60.0

end

# ================================================================
# IRRIGATION SYSTEM
# ================================================================

function irrigate!(
    farm::Farm,
    tray::GrowingTray
)

    if !tray.irrigation_required
        return
    end

    water_litres = 0.75

    pump_power_kw = 0.4

    energy =
        pump_power_kw *
        0.01

    tray.water_stress =
        max(
            0.0,
            tray.water_stress -
            0.25
        )

    # Nutrient solution moves EC
    tray.ec =
        0.95 * tray.ec +
        0.05 * tray.crop.optimal_ec

    tray.ph =
        0.98 * tray.ph +
        0.02 * tray.crop.optimal_ph

    farm.total_water_litres +=
        water_litres

    farm.irrigation_energy_kwh +=
        energy

    farm.total_energy_kwh +=
        energy

    tray.irrigation_required = false

end

# ================================================================
# HARVEST PRIORITY
# ================================================================

function calculate_priority(
    tray::GrowingTray
)

    maturity =
        tray.biomass_kg /
        tray.crop.max_biomass_kg

    health_penalty =
        (100.0 -
         tray.health_pct) /
        100.0

    harvest_pressure =
        maturity

    stress_pressure =
        tray.water_stress +
        tray.nutrient_stress

    return (
        60.0 * harvest_pressure +
        20.0 * stress_pressure +
        10.0 * health_penalty
    )
end

# ================================================================
# FIND BEST TRAYS FOR MOVEMENT
# ================================================================

function update_priorities!(
    farm::Farm
)

    for tray in farm.trays

        tray.priority =
            calculate_priority(tray)

        maturity =
            tray.biomass_kg /
            tray.crop.max_biomass_kg

        if maturity >=
           tray.crop.harvest_threshold

            tray.status =
                HARVEST_READY

            tray.destination =
                :harvest

        elseif tray.irrigation_required

            tray.destination =
                :irrigation

        elseif tray.lighting_required

            tray.destination =
                :lighting

        end
    end
end

# ================================================================
# SELECT NEXT MOVEMENT
# ================================================================

function select_movement!(
    farm::Farm
)

    candidates =
        filter(
            t ->
                t.destination !== nothing &&
                t.status != MOVING &&
                t.status != HARVESTING,
            farm.trays
        )

    if isempty(candidates)
        return nothing
    end

    sort!(
        candidates,
        by = t -> t.priority,
        rev = true
    )

    return first(candidates)
end

# ================================================================
# STATION POSITIONS
# ================================================================

const STATIONS = Dict(

    :irrigation => 10.0,

    :lighting => 40.0,

    :harvest => 90.0
)

# ================================================================
# RAIL SAFETY
# ================================================================

function rail_safe_to_move(
    farm::Farm,
    carriage::RailCarriage,
    target::Float64
)

    for other in farm.carriages

        if other.id == carriage.id
            continue
        end

        if other.rail_id !=
           carriage.rail_id

            continue
        end

        projected =
            abs(
                other.position_m -
                carriage.position_m
            )

        if projected <
           SAFE_DISTANCE

            return false
        end
    end

    return true
end

# ================================================================
# MOTION CONTROLLER
# ================================================================

function update_carriage!(
    farm::Farm,
    carriage::RailCarriage,
    tray::GrowingTray
)

    if carriage.state ==
       EMERGENCY_STOP

        carriage.velocity_mps = 0.0
        return
    end

    distance =
        carriage.target_position_m -
        carriage.position_m

    direction =
        sign(distance)

    stopping_distance =
        carriage.velocity_mps^2 /
        (2.0 * MAX_RAIL_ACCEL)

    if abs(distance) < 0.05

        carriage.position_m =
            carriage.target_position_m

        carriage.velocity_mps =
            0.0

        carriage.acceleration_mps2 =
            0.0

        carriage.state =
            IDLE

        tray.location_position =
            carriage.position_m

        tray.status =
            GROWING

        return
    end

    # Safety check

    if !rail_safe_to_move(
        farm,
        carriage,
        carriage.target_position_m
    )

        carriage.acceleration_mps2 = 0.0
        carriage.velocity_mps *= 0.5

        return
    end

    # Trapezoidal motion profile

    if abs(distance) <=
       stopping_distance

        carriage.acceleration_mps2 =
            -direction *
            MAX_RAIL_ACCEL

    else

        carriage.acceleration_mps2 =
            direction *
            MAX_RAIL_ACCEL

    end

    carriage.velocity_mps +=
        carriage.acceleration_mps2 *
        SIMULATION_STEP_MINUTES *
        60.0

    carriage.velocity_mps =
        clamp(
            carriage.velocity_mps,
            -MAX_RAIL_SPEED,
            MAX_RAIL_SPEED
        )

    carriage.position_m +=
        carriage.velocity_mps *
        SIMULATION_STEP_MINUTES *
        60.0

    tray.location_position =
        carriage.position_m

    tray.status =
        MOVING

    # Motor energy

    motor_power_kw =
        0.15 +
        0.25 *
        abs(carriage.velocity_mps)

    energy =
        motor_power_kw *
        SIMULATION_STEP_MINUTES /
        60.0

    carriage.energy_kwh +=
        energy

    farm.rail_energy_kwh +=
        energy

    farm.total_energy_kwh +=
        energy

    # Motor thermal model

    carriage.motor_temperature =
        0.995 *
        carriage.motor_temperature +
        0.005 *
        (
            25.0 +
            motor_power_kw * 30.0
        )

    # Mechanical wear

    carriage.motor_wear_pct +=
        abs(
            carriage.acceleration_mps2
        ) *
        0.00001
end

# ================================================================
# ASSIGN TRAY TO RAIL CARRIAGE
# ================================================================

function dispatch_tray!(
    farm::Farm,
    tray::GrowingTray
)

    carriage =
        farm.carriages[
            tray.location_rail
        ]

    if carriage.state ==
       MOVING

        return false
    end

    if tray.destination === nothing

        return false
    end

    destination =
        STATIONS[
            tray.destination
        ]

    carriage.target_position_m =
        destination

    carriage.state =
        MOVING

    tray.status =
        MOVING

    return true
end

# ================================================================
# HARVEST PROCESS
# ================================================================

function harvest_tray!(
    farm::Farm,
    tray::GrowingTray
)

    maturity =
        tray.biomass_kg /
        tray.crop.max_biomass_kg

    if maturity <
       tray.crop.harvest_threshold

        return false
    end

    tray.status =
        HARVESTING

    # Saleable yield

    yield =
        tray.biomass_kg *
        (tray.health_pct / 100.0)

    farm.total_harvest_kg +=
        yield

    farm.harvested_trays +=
        1

    # Reset tray for next crop

    tray.biomass_kg =
        0.01

    tray.age_hours =
        0.0

    tray.health_pct =
        100.0

    tray.light_hours =
        0.0

    tray.water_stress =
        0.0

    tray.nutrient_stress =
        0.0

    tray.status =
        GROWING

    tray.destination =
        nothing

    tray.priority =
        0.0

    return true
end

# ================================================================
# PREDICTIVE MAINTENANCE
# ================================================================

function predictive_maintenance!(
    farm::Farm
)

    for carriage in farm.carriages

        if carriage.motor_temperature >
           75.0

            push!(
                farm.alarms,
                "Rail $(carriage.id): motor temperature elevated"
            )
        end

        if carriage.motor_wear_pct >
           70.0

            push!(
                farm.alarms,
                "Rail $(carriage.id): predictive maintenance required"
            )
        end

    end

    for rail in farm.rails

        carriage =
            farm.carriages[rail.id]

        rail.motor_temperature =
            carriage.motor_temperature

        rail.wear_pct =
            carriage.motor_wear_pct

        if rail.wear_pct >
           80.0

            rail.maintenance_due =
                true
        end
    end
end

# ================================================================
# FARM OPTIMISER
# ================================================================

function optimise_farm!(
    farm::Farm
)

    update_priorities!(
        farm
    )

    tray =
        select_movement!(
            farm
        )

    if tray === nothing
        return
    end

    dispatched =
        dispatch_tray!(
            farm,
            tray
        )

    if dispatched

        println(
            "DISPATCH | Tray ",
            tray.id,
            " | ",
            tray.crop.name,
            " | Destination: ",
            tray.destination,
            " | Priority: ",
            round(
                tray.priority,
                digits=2
            )
        )
    end
end

# ================================================================
# PROCESS STATIONS
# ================================================================

function process_stations!(
    farm::Farm
)

    for tray in farm.trays

        # Find whether tray has arrived at a station

        if tray.status != MOVING
            continue
        end

        position =
            tray.location_position

        if tray.destination === nothing
            continue
        end

        target =
            STATIONS[
                tray.destination
            ]

        if abs(position - target) < 0.1

            if tray.destination ==
               :irrigation

                tray.status =
                    IRRIGATION

                irrigate!(
                    farm,
                    tray
                )

                tray.destination =
                    nothing

                tray.status =
                    GROWING

            elseif tray.destination ==
                   :lighting

                tray.status =
                    LIGHTING

                operate_lighting!(
                    farm,
                    tray
                )

                tray.destination =
                    nothing

                tray.status =
                    GROWING

            elseif tray.destination ==
                   :harvest

                harvest_tray!(
                    farm,
                    tray
                )

                tray.destination =
                    nothing
            end
        end
    end
end

# ================================================================
# SIMULATION STEP
# ================================================================

function simulation_step!(
    farm::Farm
)

    # ------------------------------------------------------------
    # 1. Crop biology
    # ------------------------------------------------------------

    for tray in farm.trays

        if tray.status ==
           GROWING

            grow_crop!(
                tray,
                farm
            )
        end
    end

    # ------------------------------------------------------------
    # 2. Optimisation
    # ------------------------------------------------------------

    optimise_farm!(
        farm
    )

    # ------------------------------------------------------------
    # 3. Motion
    # ------------------------------------------------------------

    for carriage in farm.carriages

        tray =
            findfirst(
                t ->
                    t.location_rail ==
                    carriage.rail_id &&
                    t.status ==
                    MOVING,
                farm.trays
            )

        if tray !== nothing

            update_carriage!(
                farm,
                carriage,
                farm.trays[tray]
            )
        end
    end

    # ------------------------------------------------------------
    # 4. Stations
    # ------------------------------------------------------------

    process_stations!(
        farm
    )

    # ------------------------------------------------------------
    # 5. Maintenance
    # ------------------------------------------------------------

    predictive_maintenance!(
        farm
    )

    # ------------------------------------------------------------
    # 6. Clock
    # ------------------------------------------------------------

    farm.simulation_minutes +=
        SIMULATION_STEP_MINUTES
end

# ================================================================
# FARM DASHBOARD
# ================================================================

function dashboard(
    farm::Farm
)

    println()
    println("╔══════════════════════════════════════════════════════════╗")
    println("║                 HYDROCORE CONTROL ROOM                  ║")
    println("╠══════════════════════════════════════════════════════════╣")

    hours =
        farm.simulation_minutes / 60.0

    println(
        "║ Simulation time: ",
        lpad(
            round(hours, digits=2),
            10
        ),
        " h                              ║"
    )

    println(
        "║ Total trays:     ",
        lpad(
            length(farm.trays),
            10
        ),
        "                                  ║"
    )

    println(
        "║ Harvested:       ",
        lpad(
            farm.harvested_trays,
            10
        ),
        " trays                             ║"
    )

    println(
        "║ Harvest mass:    ",
        lpad(
            round(
                farm.total_harvest_kg,
                digits=2
            ),
            10
        ),
        " kg                              ║"
    )

    println(
        "║ Water:           ",
        lpad(
            round(
                farm.total_water_litres,
                digits=2
            ),
            10
        ),
        " litres                          ║"
    )

    println(
        "║ Total energy:    ",
        lpad(
            round(
                farm.total_energy_kwh,
                digits=3
            ),
            10
        ),
        " kWh                             ║"
    )

    println(
        "║ Rail energy:     ",
        lpad(
            round(
                farm.rail_energy_kwh,
                digits=3
            ),
            10
        ),
        " kWh                             ║"
    )

    println(
        "║ Lighting energy: ",
        lpad(
            round(
                farm.lighting_energy_kwh,
                digits=3
            ),
            10
        ),
        " kWh                             ║"
    )

    println(
        "║ Irrigation:      ",
        lpad(
            round(
                farm.irrigation_energy_kwh,
                digits=3
            ),
            10
        ),
        " kWh                             ║"
    )

    println("╠══════════════════════════════════════════════════════════╣")

    for carriage in farm.carriages

        println(
            "║ Rail ",
            lpad(
                carriage.id,
                2
            ),
            " | Position ",
            lpad(
                round(
                    carriage.position_m,
                    digits=1
                ),
                6
            ),
            " m | Velocity ",
            lpad(
                round(
                    carriage.velocity_mps,
                    digits=2
                ),
                5
            ),
            " m/s ║"
        )
    end

    println("╚══════════════════════════════════════════════════════════╝")

end

# ================================================================
# CROP STATISTICS
# ================================================================

function crop_statistics(
    farm::Farm
)

    println()
    println("--------------- CROP ANALYTICS ----------------")

    for crop in CROPS

        crop_trays =
            filter(
                t ->
                    t.crop.name ==
                    crop.name,
                farm.trays
            )

        if isempty(crop_trays)
            continue
        end

        mean_biomass =
            mean(
                t.biomass_kg
                for t in crop_trays
            )

        mean_health =
            mean(
                t.health_pct
                for t in crop_trays
            )

        mean_ph =
            mean(
                t.ph
                for t in crop_trays
            )

        mean_ec =
            mean(
                t.ec
                for t in crop_trays
            )

        println(
            crop.name,
            " | trays=",
            length(crop_trays),
            " | biomass=",
            round(
                mean_biomass,
                digits=3
            ),
            " kg",
            " | health=",
            round(
                mean_health,
                digits=1
            ),
            "%",
            " | pH=",
            round(
                mean_ph,
                digits=2
            ),
            " | EC=",
            round(
                mean_ec,
                digits=2
            )
        )
    end
end

# ================================================================
# ALARM SYSTEM
# ================================================================

function show_alarms(
    farm::Farm
)

    println()
    println("--------------- SYSTEM ALARMS ----------------")

    if isempty(farm.alarms)

        println("SYSTEM STATUS: NOMINAL")

        return
    end

    # Display unique alarms

    unique_alarms =
        unique(
            farm.alarms
        )

    for alarm in unique_alarms

        println(
            "⚠ ",
            alarm
        )
    end
end

# ================================================================
# MAIN SIMULATION
# ================================================================

function run_simulation(
    hours::Float64 = 24.0
)

    farm =
        create_farm(
            6,
            20
        )

    total_steps =
        Int(
            hours *
            60.0 /
            SIMULATION_STEP_MINUTES
        )

    println()
    println("================================================")
    println(" HYDROCORE INDUSTRY 4.0 DIGITAL TWIN")
    println("================================================")
    println(
        "Rails: ",
        length(farm.rails)
    )
    println(
        "Growing trays: ",
        length(farm.trays)
    )
    println(
        "Simulation: ",
        hours,
        " hours"
    )
    println("================================================")

    for step in 1:total_steps

        simulation_step!(
            farm
        )

        # Dashboard every simulated hour

        if mod(
            step,
            Int(
                60 /
                SIMULATION_STEP_MINUTES
            )
        ) == 0

            dashboard(
                farm
            )

        end
    end

    println()
    println("================================================")
    println(" FINAL FARM REPORT")
    println("================================================")

    dashboard(
        farm
    )

    crop_statistics(
        farm
    )

    show_alarms(
        farm
    )

    return farm
end

# ================================================================
# START
# ================================================================

farm =
    run_simulation(
        24.0
    )
