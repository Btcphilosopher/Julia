module IroningOS

# ============================================================
# IRONING.OS
#
# Pure Julia — Automated Ironing Appliance
#
# SYSTEM
#
#     FABRIC SENSOR
#          │
#          ▼
#     FABRIC PROFILE
#          │
#          ├──────► TEMPERATURE
#          ├──────► STEAM
#          ├──────► PRESSURE
#          └──────► SPEED
#                    │
#                    ▼
#              IRONING ENGINE
#                    │
#          ┌─────────┼─────────┐
#          ▼         ▼         ▼
#       WRINKLE   MOISTURE   HEAT
#       MODEL     MODEL      MODEL
#          │         │         │
#          └─────────┼─────────┘
#                    ▼
#                 FINISH
#                    │
#                    ▼
#                 COOLING
#
# NOTE:
# Real appliances require independent thermal cutoffs,
# over-temperature protection, electrical protection,
# mechanical interlocks and validated fabric-temperature
# limits. This software is a control/simulation model.
# ============================================================


const SOFTWARE = "Ironing.OS"
const VERSION = v"1.0.0"


# ============================================================
# FABRIC TYPES
# ============================================================

@enum Fabric begin
    COTTON
    LINEN
    WOOL
    SILK
    POLYESTER
    NYLON
    DENIM
    SYNTHETIC
    UNKNOWN
end


# ============================================================
# IRONING STATES
# ============================================================

@enum State begin
    OFF
    INITIALISING
    HEATING
    READY
    IRONING
    STEAMING
    PAUSED
    COOLING
    COMPLETE
    WATER_LOW
    FAULT
end


# ============================================================
# FABRIC PROFILE
# ============================================================

struct FabricProfile

    fabric::Fabric

    target_temperature_c::Float64

    maximum_temperature_c::Float64

    steam_level::Float64

    pressure_level::Float64

    movement_speed_mm_s::Float64

end


# ============================================================
# DEFAULT FABRIC DATABASE
# ============================================================

const FABRICS = Dict(

    COTTON =>
        FabricProfile(
            COTTON,
            180.0,
            200.0,
            0.70,
            0.75,
            80.0
        ),

    LINEN =>
        FabricProfile(
            LINEN,
            190.0,
            210.0,
            0.90,
            0.85,
            70.0
        ),

    WOOL =>
        FabricProfile(
            WOOL,
            150.0,
            165.0,
            0.45,
            0.45,
            60.0
        ),

    SILK =>
        FabricProfile(
            SILK,
            120.0,
            135.0,
            0.10,
            0.20,
            100.0
        ),

    POLYESTER =>
        FabricProfile(
            POLYESTER,
            135.0,
            150.0,
            0.15,
            0.25,
            100.0
        ),

    NYLON =>
        FabricProfile(
            NYLON,
            125.0,
            140.0,
            0.10,
            0.20,
            110.0
        ),

    DENIM =>
        FabricProfile(
            DENIM,
            175.0,
            195.0,
            0.80,
            0.90,
            65.0
        ),

    SYNTHETIC =>
        FabricProfile(
            SYNTHETIC,
            130.0,
            145.0,
            0.10,
            0.25,
            100.0
        ),

    UNKNOWN =>
        FabricProfile(
            UNKNOWN,
            100.0,
            110.0,
            0.0,
            0.10,
            120.0
        )
)


# ============================================================
# SENSORS
# ============================================================

Base.@kwdef mutable struct Sensors

    soleplate_temperature_c::Float64 = 20.0

    fabric_temperature_c::Float64 = 20.0

    fabric_detected::Bool = false

    fabric_type::Fabric = UNKNOWN

    water_level::Float64 = 1.0

    steam_available::Bool = true

    motion_detected::Bool = false

    tilt_detected::Bool = false

    thermal_sensor_ok::Bool = true

    pressure_sensor_ok::Bool = true

end


# ============================================================
# ACTUATORS
# ============================================================

Base.@kwdef mutable struct Outputs

    heater_enabled::Bool = false

    steam_enabled::Bool = false

    pump_enabled::Bool = false

    pressure_level::Float64 = 0.0

    movement_command_mm_s::Float64 = 0.0

    state::State = OFF

end


# ============================================================
# FAIL-SAFE OUTPUT
# ============================================================

function safe_outputs!(
    output::Outputs
)

    output.heater_enabled = false
    output.steam_enabled = false
    output.pump_enabled = false
    output.pressure_level = 0.0
    output.movement_command_mm_s = 0.0

end


# ============================================================
# GARMENT MODEL
# ============================================================

mutable struct Garment

    fabric::Fabric

    area_m2::Float64

    wrinkle_level::Float64

    moisture_level::Float64

    processed_area_m2::Float64

    quality_score::Float64

end


# ============================================================
# IRON CONTROLLER
# ============================================================

mutable struct IronController

    state::State

    sensors::Sensors

    outputs::Outputs

    profile::FabricProfile

    garment::Union{Nothing,Garment}

    elapsed_s::Float64

    heating_energy::Float64

    fault_message::String

end


# ============================================================
# CONSTRUCTOR
# ============================================================

function IronController()

    IronController(

        OFF,

        Sensors(),

        Outputs(),

        FABRICS[UNKNOWN],

        nothing,

        0.0,

        0.0,

        ""

    )

end


# ============================================================
# FABRIC SELECTION
# ============================================================

function select_fabric!(
    iron::IronController,
    fabric::Fabric
)

    if iron.state ∉ (
        OFF,
        READY
    )

        return false

    end


    iron.profile =
        FABRICS[fabric]


    iron.sensors.fabric_type =
        fabric


    true

end


# ============================================================
# SAFETY
# ============================================================

function safe(
    iron::IronController
)

    iron.sensors.thermal_sensor_ok &&
    iron.sensors.pressure_sensor_ok &&
    iron.sensors.water_level >= 0.0

end


# ============================================================
# START
# ============================================================

function start!(
    iron::IronController
)

    if iron.state != OFF

        return false

    end


    if !safe(iron)

        iron.state =
            FAULT

        iron.fault_message =
            "Safety sensor fault"

        return false

    end


    iron.state =
        INITIALISING


    iron.outputs.state =
        INITIALISING


    iron.elapsed_s =
        0.0


    iron.state =
        HEATING


    iron.outputs.state =
        HEATING


    iron.outputs.heater_enabled =
        true


    true

end


# ============================================================
# TEMPERATURE CONTROL
# ============================================================

function regulate_temperature!(
    iron::IronController,
    dt::Float64
)

    current =
        iron.sensors.soleplate_temperature_c


    target =
        iron.profile.target_temperature_c


    difference =
        target - current


    # Simplified thermal plant model.

    heating_rate =
        difference > 0 ?
        min(
            difference * 0.05 * dt,
            5.0
        ) :
        difference * 0.01 * dt


    iron.sensors.soleplate_temperature_c +=
        heating_rate


    iron.heating_energy +=
        max(
            heating_rate,
            0.0
        )


    iron.outputs.heater_enabled =
        current < target - 2.0


end


# ============================================================
# READY CHECK
# ============================================================

function ready(
    iron::IronController
)

    iron.sensors.soleplate_temperature_c >=
    iron.profile.target_temperature_c - 2.0

end


# ============================================================
# LOAD GARMENT
# ============================================================

function load_garment!(
    iron::IronController,
    garment::Garment
)

    if iron.state != READY

        return false

    end


    iron.garment =
        garment


    iron.sensors.fabric_detected =
        true


    iron.sensors.fabric_type =
        garment.fabric


    select_fabric!(
        iron,
        garment.fabric
    )


    iron.state =
        IRONING


    iron.outputs.state =
        IRONING


    true

end


# ============================================================
# WRINKLE MODEL
# ============================================================

function reduce_wrinkles!(
    iron::IronController,
    dt::Float64
)

    garment =
        iron.garment


    garment === nothing &&
        return


    profile =
        iron.profile


    temperature_factor =
        clamp(
            iron.sensors.soleplate_temperature_c /
            profile.maximum_temperature_c,
            0.0,
            1.0
        )


    pressure_factor =
        profile.pressure_level


    steam_factor =
        profile.steam_level *
        (iron.sensors.steam_available ? 1.0 : 0.0)


    effectiveness =
        (
            0.40 *
            temperature_factor
            +
            0.30 *
            pressure_factor
            +
            0.30 *
            steam_factor
        )


    reduction =
        effectiveness *
        0.012 *
        dt


    garment.wrinkle_level =
        max(
            0.0,
            garment.wrinkle_level -
            reduction
        )


    garment.moisture_level +=
        steam_factor *
        0.001 *
        dt


    garment.moisture_level =
        clamp(
            garment.moisture_level,
            0.0,
            1.0
        )

end


# ============================================================
# STEAM SYSTEM
# ============================================================

function control_steam!(
    iron::IronController,
    dt::Float64
)

    if iron.profile.steam_level <= 0.0

        iron.outputs.steam_enabled =
            false

        iron.outputs.pump_enabled =
            false

        return

    end


    if iron.sensors.water_level <= 0.05

        iron.outputs.steam_enabled =
            false

        iron.outputs.pump_enabled =
            false

        iron.state =
            WATER_LOW

        iron.outputs.state =
            WATER_LOW

        return

    end


    iron.outputs.steam_enabled =
        true


    iron.outputs.pump_enabled =
        true


    iron.sensors.water_level -=
        0.00005 *
        iron.profile.steam_level *
        dt


    iron.sensors.water_level =
        max(
            iron.sensors.water_level,
            0.0
        )

end


# ============================================================
# QUALITY ESTIMATION
# ============================================================

function calculate_quality!(
    iron::IronController
)

    garment =
        iron.garment


    garment === nothing &&
        return


    wrinkle_score =
        100.0 *
        (1.0 -
        garment.wrinkle_level)


    coverage =
        clamp(
            garment.processed_area_m2 /
            garment.area_m2,
            0.0,
            1.0
        )


    garment.quality_score =
        0.75 *
        wrinkle_score
        +
        25.0 *
        coverage

end


# ============================================================
# MAIN LOOP
# ============================================================

function update!(
    iron::IronController,
    dt_s::Real
)

    dt =
        max(
            Float64(dt_s),
            0.0
        )


    # --------------------------------------------------------
    # GLOBAL SAFETY
    # --------------------------------------------------------

    if !safe(iron)

        safe_outputs!(
            iron.outputs
        )


        iron.state =
            FAULT


        iron.outputs.state =
            FAULT


        iron.fault_message =
            "Safety sensor fault"


        return iron.state

    end


    # --------------------------------------------------------
    # HARD TEMPERATURE LIMIT
    # --------------------------------------------------------

    if iron.sensors.soleplate_temperature_c >
       iron.profile.maximum_temperature_c

        safe_outputs!(
            iron.outputs
        )


        iron.state =
            FAULT


        iron.outputs.state =
            FAULT


        iron.fault_message =
            "Temperature limit exceeded"


        return iron.state

    end


    # --------------------------------------------------------
    # STATE MACHINE
    # --------------------------------------------------------

    if iron.state == HEATING

        regulate_temperature!(
            iron,
            dt
        )


        if ready(iron)

            iron.state =
                READY


            iron.outputs.state =
                READY

        end


    elseif iron.state == READY

        regulate_temperature!(
            iron,
            dt
        )


    elseif iron.state == IRONING

        regulate_temperature!(
            iron,
            dt
        )


        if !iron.sensors.fabric_detected

            iron.state =
                PAUSED

            iron.outputs.state =
                PAUSED

            return iron.state

        end


        control_steam!(
            iron,
            dt
        )


        if iron.state == WATER_LOW

            safe_outputs!(
                iron.outputs
            )

            return iron.state

        end


        reduce_wrinkles!(
            iron,
            dt
        )


        garment =
            iron.garment


        garment.processed_area_m2 +=
            iron.profile.movement_speed_mm_s *
            dt /
            1_000_000.0


        garment.processed_area_m2 =
            min(
                garment.processed_area_m2,
                garment.area_m2
            )


        iron.outputs.pressure_level =
            iron.profile.pressure_level


        iron.outputs.movement_command_mm_s =
            iron.profile.movement_speed_mm_s


        calculate_quality!(
            iron
        )


        if garment.wrinkle_level <= 0.02 ||
           garment.processed_area_m2 >=
           garment.area_m2

            iron.state =
                COMPLETE


            iron.outputs.state =
                COMPLETE


            safe_outputs!(
                iron.outputs
            )

        end


    elseif iron.state == PAUSED

        safe_outputs!(
            iron.outputs
        )


        if iron.sensors.fabric_detected

            iron.state =
                IRONING

            iron.outputs.state =
                IRONING

        end


    elseif iron.state == WATER_LOW

        safe_outputs!(
            iron.outputs
        )


        if iron.sensors.water_level > 0.10

            iron.state =
                IRONING

            iron.outputs.state =
                IRONING

        end


    elseif iron.state == COMPLETE

        safe_outputs!(
            iron.outputs
        )


        iron.state =
            COOLING


        iron.outputs.state =
            COOLING


    elseif iron.state == COOLING

        safe_outputs!(
            iron.outputs
        )


        if iron.sensors.soleplate_temperature_c < 50.0

            iron.state =
                READY

            iron.outputs.state =
                READY

        end


    elseif iron.state == FAULT

        safe_outputs!(
            iron.outputs
        )

    end


    iron.elapsed_s +=
        dt


    iron.state

end


# ============================================================
# FAULT RESET
# ============================================================

function reset_fault!(
    iron::IronController
)

    if iron.state != FAULT

        return true

    end


    if !safe(iron)

        return false

    end


    iron.fault_message =
        ""


    iron.state =
        COOLING


    iron.outputs.state =
        COOLING


    safe_outputs!(
        iron.outputs
    )


    true

end


# ============================================================
# STATUS
# ============================================================

function status(
    iron::IronController
)

    println()
    println("==========================================")
    println("              IRONING.OS")
    println("              VERSION ", VERSION)
    println("==========================================")

    println(
        "STATE       : ",
        iron.state
    )

    println(
        "FABRIC      : ",
        iron.profile.fabric
    )

    println(
        "SOLEPLATE   : ",
        round(
            iron.sensors.soleplate_temperature_c,
            digits = 1
        ),
        " °C"
    )

    println(
        "TARGET      : ",
        iron.profile.target_temperature_c,
        " °C"
    )

    println(
        "STEAM       : ",
        round(
            iron.profile.steam_level * 100,
            digits = 0
        ),
        "%"
    )

    println(
        "WATER       : ",
        round(
            iron.sensors.water_level * 100,
            digits = 1
        ),
        "%"
    )


    if iron.garment !== nothing

        garment =
            iron.garment


        println(
            "WRINKLES    : ",
            round(
                garment.wrinkle_level * 100,
                digits = 1
            ),
            "%"
        )

        println(
            "COVERAGE    : ",
            round(
                100.0 *
                garment.processed_area_m2 /
                garment.area_m2,
                digits = 1
            ),
            "%"
        )

        println(
            "QUALITY     : ",
            round(
                garment.quality_score,
                digits = 1
            ),
            "%"
        )

    end


    if iron.state == FAULT

        println(
            "FAULT       : ",
            iron.fault_message
        )

    end


    println("==========================================")

end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    iron =
        IronController()


    # --------------------------------------------------------
    # SELECT FABRIC
    # --------------------------------------------------------

    select_fabric!(
        iron,
        COTTON
    )


    # --------------------------------------------------------
    # START
    # --------------------------------------------------------

    start!(
        iron
    )


    # --------------------------------------------------------
    # PREHEAT
    # --------------------------------------------------------

    for _ in 1:300

        update!(
            iron,
            0.5
        )


        if iron.state == READY

            break

        end

    end


    # --------------------------------------------------------
    # GARMENT
    # --------------------------------------------------------

    shirt =
        Garment(

            COTTON,

            1.2,       # m²

            0.85,      # initial wrinkles

            0.05,      # moisture

            0.0,

            0.0

        )


    load_garment!(
        iron,
        shirt
    )


    # --------------------------------------------------------
    # AUTOMATIC IRONING
    # --------------------------------------------------------

    for _ in 1:2000

        update!(
            iron,
            0.5
        )


        if iron.state in (
            COMPLETE,
            FAULT
        )

            break

        end

    end


    status(
        iron
    )

end


# ============================================================
# SELF TEST
# ============================================================

function self_test()

    iron =
        IronController()


    select_fabric!(
        iron,
        COTTON
    )


    @assert start!(
        iron
    )


    # Preheat.

    for _ in 1:300

        update!(
            iron,
            0.5
        )


        if iron.state == READY

            break

        end

    end


    @assert iron.state ==
        READY


    garment =
        Garment(

            COTTON,

            1.0,

            0.50,

            0.05,

            0.0,

            0.0

        )


    @assert load_garment!(
        iron,
        garment
    )


    for _ in 1:2000

        update!(
            iron,
            0.5
        )


        if iron.state in (
            COMPLETE,
            FAULT
        )

            break

        end

    end


    @assert iron.state ==
        COMPLETE


    @assert iron.garment !==
        nothing


    @assert iron.garment.quality_score >
        0.0


    println(
        "Ironing.OS SELF TEST: PASS"
    )

end


end # module


# ============================================================
# RUN
# ============================================================

using .IroningOS

IroningOS.self_test()

IroningOS.demo()
