module WineCellarOS

using Dates
using Statistics

# ============================================================
# WINECELLAR.OS
#
# Deterministic wine-cellar environmental control system
#
# Pure Julia
#
# CONTROLLED VARIABLES
#   Temperature
#   Relative Humidity
#   Lighting
#   Ventilation
#   Dehumidification
#   Humidification
#   Cooling
#   Heating
#   Vibration monitoring
#
# DESIGN PRINCIPLES
#   - Fail-safe outputs
#   - Stable environmental targets
#   - Hysteresis to prevent rapid cycling
#   - Sensor validation
#   - Alarm management
#   - Historical telemetry
#   - Energy-aware control
#   - Hardware abstraction
# ============================================================


# ============================================================
# VERSION
# ============================================================

const SOFTWARE_NAME = "WineCellar.OS"
const SOFTWARE_VERSION = v"1.0.0"


# ============================================================
# OPERATING MODES
# ============================================================

@enum CellarMode begin
    NORMAL
    ENERGY_SAVE
    RECOVERY
    MAINTENANCE
    FAULT
end


# ============================================================
# ENVIRONMENTAL STATES
# ============================================================

@enum EnvironmentState begin
    OPTIMAL
    COOLING
    HEATING
    HUMIDIFYING
    DEHUMIDIFYING
    VENTILATING
    STABILISING
    WARNING
    CRITICAL
end


# ============================================================
# SENSOR SNAPSHOT
# ============================================================

struct SensorSnapshot

    timestamp::DateTime

    temperature_c::Float64
    humidity_pct::Float64

    vibration_g::Float64
    light_lux::Float64

    door_open::Bool

    compressor_temperature_c::Float64

    sensor_ok::Bool

end


# ============================================================
# SENSOR LIMITS
# ============================================================

struct SensorLimits

    minimum_temperature_c::Float64
    maximum_temperature_c::Float64

    minimum_humidity_pct::Float64
    maximum_humidity_pct::Float64

    maximum_vibration_g::Float64
    maximum_light_lux::Float64

end


SensorLimits() = SensorLimits(

    0.0,
    40.0,

    0.0,
    100.0,

    1.0,
    10000.0
)


# ============================================================
# CELLAR TARGET PROFILE
# ============================================================

struct CellarProfile

    target_temperature_c::Float64

    temperature_low_c::Float64
    temperature_high_c::Float64

    target_humidity_pct::Float64

    humidity_low_pct::Float64
    humidity_high_pct::Float64

    critical_temperature_low_c::Float64
    critical_temperature_high_c::Float64

    critical_humidity_low_pct::Float64
    critical_humidity_high_pct::Float64

end


"""
Default long-term wine-storage profile.

The centre point is approximately 12.5°C / 65% RH.
"""
function DefaultCellarProfile()

    CellarProfile(

        12.5,

        11.5,
        13.5,

        65.0,

        60.0,
        70.0,

        8.0,
        18.0,

        45.0,
        80.0
    )

end


# ============================================================
# ACTUATORS
# ============================================================

mutable struct Actuators

    cooling::Bool
    heating::Bool

    humidifier::Bool
    dehumidifier::Bool

    ventilation::Bool

    lights::Bool

    alarm::Bool

end


function Actuators()

    Actuators(

        false,
        false,

        false,
        false,

        false,

        false,

        false
    )

end


# ============================================================
# HARD SHUTDOWN
# ============================================================

function shutdown!(a::Actuators)

    a.cooling = false
    a.heating = false

    a.humidifier = false
    a.dehumidifier = false

    a.ventilation = false

    a.lights = false

end


# ============================================================
# ALARM
# ============================================================

@enum AlarmSeverity begin
    INFO
    NOTICE
    WARNING_ALARM
    CRITICAL_ALARM
end


struct Alarm

    timestamp::DateTime

    severity::AlarmSeverity

    code::Symbol

    message::String

end


# ============================================================
# TELEMETRY
# ============================================================

struct Telemetry

    timestamp::DateTime

    temperature_c::Float64
    humidity_pct::Float64

    vibration_g::Float64
    light_lux::Float64

    state::EnvironmentState
    mode::CellarMode

    cooling::Bool
    heating::Bool

    humidifying::Bool
    dehumidifying::Bool

    ventilation::Bool

end


# ============================================================
# CONTROLLER
# ============================================================

mutable struct WineCellarController

    profile::CellarProfile

    limits::SensorLimits

    mode::CellarMode

    state::EnvironmentState

    sensors::SensorSnapshot

    actuators::Actuators

    alarms::Vector{Alarm}

    telemetry::Vector{Telemetry}

    control_cycles::UInt64

    cooling_cycles::UInt64
    heating_cycles::UInt64

    humidity_cycles::UInt64

end


# ============================================================
# CONSTRUCTOR
# ============================================================

function WineCellarController(;
    profile = DefaultCellarProfile(),
    limits = SensorLimits()
)

    initial_sensor = SensorSnapshot(

        now(),

        profile.target_temperature_c,
        profile.target_humidity_pct,

        0.0,
        0.0,

        false,

        20.0,

        true
    )


    WineCellarController(

        profile,

        limits,

        NORMAL,

        OPTIMAL,

        initial_sensor,

        Actuators(),

        Alarm[],

        Telemetry[],

        UInt64(0),

        UInt64(0),
        UInt64(0),

        UInt64(0)
    )

end


# ============================================================
# SENSOR VALIDATION
# ============================================================

function valid_sensor_data(
    controller::WineCellarController,
    sensor::SensorSnapshot
)

    limits = controller.limits


    if !sensor.sensor_ok
        return false
    end


    if sensor.temperature_c <
       limits.minimum_temperature_c

        return false
    end


    if sensor.temperature_c >
       limits.maximum_temperature_c

        return false
    end


    if sensor.humidity_pct <
       limits.minimum_humidity_pct

        return false
    end


    if sensor.humidity_pct >
       limits.maximum_humidity_pct

        return false
    end


    if sensor.vibration_g < 0
        return false
    end


    if sensor.light_lux < 0
        return false
    end


    true

end


# ============================================================
# UPDATE SENSOR SNAPSHOT
# ============================================================

function update_sensors!(
    controller::WineCellarController,
    sensor::SensorSnapshot
)

    controller.sensors = sensor

    return valid_sensor_data(
        controller,
        sensor
    )

end


# ============================================================
# TARGET ERROR
# ============================================================

function temperature_error(
    controller::WineCellarController
)

    controller.profile.target_temperature_c -
    controller.sensors.temperature_c

end


function humidity_error(
    controller::WineCellarController
)

    controller.profile.target_humidity_pct -
    controller.sensors.humidity_pct

end


# ============================================================
# TEMPERATURE CONTROL
# ============================================================

function control_temperature!(
    controller::WineCellarController
)

    p = controller.profile
    s = controller.sensors
    a = controller.actuators


    # --------------------------------------------------------
    # Too warm
    # --------------------------------------------------------

    if s.temperature_c > p.temperature_high_c

        a.heating = false
        a.cooling = true

        controller.state = COOLING

        controller.cooling_cycles += 1

        return :cooling
    end


    # --------------------------------------------------------
    # Too cold
    # --------------------------------------------------------

    if s.temperature_c < p.temperature_low_c

        a.cooling = false
        a.heating = true

        controller.state = HEATING

        controller.heating_cycles += 1

        return :heating
    end


    # --------------------------------------------------------
    # Inside hysteresis band
    # --------------------------------------------------------

    a.cooling = false
    a.heating = false

    return :stable

end


# ============================================================
# HUMIDITY CONTROL
# ============================================================

function control_humidity!(
    controller::WineCellarController
)

    p = controller.profile
    s = controller.sensors
    a = controller.actuators


    # --------------------------------------------------------
    # Dry cellar
    # --------------------------------------------------------

    if s.humidity_pct <
       p.humidity_low_pct

        a.dehumidifier = false

        a.humidifier = true

        controller.state =
            HUMIDIFYING

        controller.humidity_cycles += 1

        return :humidifying
    end


    # --------------------------------------------------------
    # Wet cellar
    # --------------------------------------------------------

    if s.humidity_pct >
       p.humidity_high_pct

        a.humidifier = false

        a.dehumidifier = true

        controller.state =
            DEHUMIDIFYING

        controller.humidity_cycles += 1

        return :dehumidifying
    end


    a.humidifier = false
    a.dehumidifier = false

    return :stable

end


# ============================================================
# VENTILATION
# ============================================================

function control_ventilation!(
    controller::WineCellarController
)

    s = controller.sensors
    a = controller.actuators


    # Ventilation can help remove excess heat,
    # but should not blindly fight the humidity controller.

    if s.temperature_c >
       controller.profile.temperature_high_c + 1.0

        a.ventilation = true

        controller.state =
            VENTILATING

        return true
    end


    a.ventilation = false

    false

end


# ============================================================
# LIGHT CONTROL
# ============================================================

function control_lighting!(
    controller::WineCellarController
)

    s = controller.sensors
    a = controller.actuators


    # Wine storage should normally remain dark.

    if s.light_lux > 5.0

        a.lights = false

        return :dark
    end


    a.lights = false

    :dark

end


# ============================================================
# VIBRATION MONITORING
# ============================================================

function vibration_status(
    controller::WineCellarController
)

    vibration =
        controller.sensors.vibration_g


    if vibration >
       controller.limits.maximum_vibration_g

        return :critical
    end


    if vibration >
       controller.limits.maximum_vibration_g * 0.5

        return :elevated
    end


    :normal

end


# ============================================================
# CRITICAL ENVIRONMENT CHECK
# ============================================================

function critical_environment!(
    controller::WineCellarController
)

    p = controller.profile
    s = controller.sensors


    if s.temperature_c <
       p.critical_temperature_low_c

        return (
            true,
            :TEMPERATURE_LOW,
            "Critical low cellar temperature"
        )
    end


    if s.temperature_c >
       p.critical_temperature_high_c

        return (
            true,
            :TEMPERATURE_HIGH,
            "Critical high cellar temperature"
        )
    end


    if s.humidity_pct <
       p.critical_humidity_low_pct

        return (
            true,
            :HUMIDITY_LOW,
            "Critical low humidity"
        )
    end


    if s.humidity_pct >
       p.critical_humidity_high_pct

        return (
            true,
            :HUMIDITY_HIGH,
            "Critical high humidity"
        )
    end


    if !valid_sensor_data(
        controller,
        s
    )

        return (
            true,
            :SENSOR_FAILURE,
            "Invalid environmental sensor data"
        )
    end


    false, :NONE, ""

end


# ============================================================
# ALARM GENERATION
# ============================================================

function raise_alarm!(
    controller::WineCellarController,
    severity::AlarmSeverity,
    code::Symbol,
    message::String
)

    push!(
        controller.alarms,

        Alarm(
            now(),
            severity,
            code,
            message
        )
    )

end


# ============================================================
# ALARM PROCESSING
# ============================================================

function process_alarms!(
    controller::WineCellarController
)

    critical,
    code,
    message =
        critical_environment!(
            controller
        )


    if critical

        controller.mode = FAULT

        controller.state = CRITICAL

        controller.actuators.alarm = true

        raise_alarm!(
            controller,
            CRITICAL_ALARM,
            code,
            message
        )

        return false
    end


    # --------------------------------------------------------
    # Vibration warning
    # --------------------------------------------------------

    if vibration_status(controller) ==
       :critical

        raise_alarm!(
            controller,
            WARNING_ALARM,
            :VIBRATION,
            "Elevated cellar vibration detected"
        )
    end


    # --------------------------------------------------------
    # Door warning
    # --------------------------------------------------------

    if controller.sensors.door_open

        raise_alarm!(
            controller,
            NOTICE,
            :DOOR_OPEN,
            "Cellar access door is open"
        )
    end


    true

end


# ============================================================
# NORMAL CONTROL CYCLE
# ============================================================

function control_cycle!(
    controller::WineCellarController
)

    controller.control_cycles += 1


    # --------------------------------------------------------
    # Safety gate
    # --------------------------------------------------------

    if !process_alarms!(controller)

        shutdown!(
            controller.actuators
        )

        return :fault
    end


    if controller.mode == MAINTENANCE

        shutdown!(
            controller.actuators
        )

        controller.state =
            STABILISING

        return :maintenance
    end


    # --------------------------------------------------------
    # Temperature
    # --------------------------------------------------------

    control_temperature!(
        controller
    )


    # --------------------------------------------------------
    # Humidity
    # --------------------------------------------------------

    control_humidity!(
        controller
    )


    # --------------------------------------------------------
    # Ventilation
    # --------------------------------------------------------

    control_ventilation!(
        controller
    )


    # --------------------------------------------------------
    # Lighting
    # --------------------------------------------------------

    control_lighting!(
        controller
    )


    # --------------------------------------------------------
    # Energy-save mode
    # --------------------------------------------------------

    if controller.mode ==
       ENERGY_SAVE

        # Don't actively heat unless outside
        # the acceptable storage envelope.

        if controller.sensors.temperature_c >=
           controller.profile.temperature_low_c

            controller.actuators.heating = false
        end
    end


    # --------------------------------------------------------
    # Determine overall condition
    # --------------------------------------------------------

    if !controller.actuators.cooling &&
       !controller.actuators.heating &&
       !controller.actuators.humidifier &&
       !controller.actuators.dehumidifier

        controller.state = OPTIMAL
    end


    :ok

end


# ============================================================
# TELEMETRY RECORD
# ============================================================

function record_telemetry!(
    controller::WineCellarController
)

    s = controller.sensors
    a = controller.actuators


    push!(
        controller.telemetry,

        Telemetry(

            now(),

            s.temperature_c,
            s.humidity_pct,

            s.vibration_g,
            s.light_lux,

            controller.state,
            controller.mode,

            a.cooling,
            a.heating,

            a.humidifier,
            a.dehumidifier,

            a.ventilation
        )
    )

end


# ============================================================
# MAIN TICK
# ============================================================

function tick!(
    controller::WineCellarController,
    sensor::SensorSnapshot
)

    update_sensors!(
        controller,
        sensor
    )


    control_cycle!(
        controller
    )


    record_telemetry!(
        controller
    )


    return controller.state

end


# ============================================================
# MODE CONTROL
# ============================================================

function set_mode!(
    controller::WineCellarController,
    mode::CellarMode
)

    controller.mode = mode


    if mode == FAULT

        shutdown!(
            controller.actuators
        )

        controller.state = CRITICAL
    end


    mode

end


# ============================================================
# MAINTENANCE
# ============================================================

function enter_maintenance!(
    controller::WineCellarController
)

    controller.mode =
        MAINTENANCE

    shutdown!(
        controller.actuators
    )

    controller.state =
        STABILISING

end


function exit_maintenance!(
    controller::WineCellarController
)

    controller.mode =
        NORMAL

end


# ============================================================
# FAULT RESET
# ============================================================

function reset_fault!(
    controller::WineCellarController
)

    if controller.mode != FAULT
        return true
    end


    if !valid_sensor_data(
        controller,
        controller.sensors
    )

        return false
    end


    critical, _, _ =
        critical_environment!(
            controller
        )


    if critical
        return false
    end


    controller.actuators.alarm = false

    controller.mode = NORMAL

    controller.state = STABILISING

    true

end


# ============================================================
# CELLAR HEALTH SCORE
# ============================================================

function health_score(
    controller::WineCellarController
)

    s = controller.sensors
    p = controller.profile


    temperature_penalty =
        abs(
            s.temperature_c -
            p.target_temperature_c
        )


    humidity_penalty =
        abs(
            s.humidity_pct -
            p.target_humidity_pct
        )


    vibration_penalty =
        s.vibration_g * 20.0


    score =
        100.0 -
        temperature_penalty * 12.0 -
        humidity_penalty * 0.5 -
        vibration_penalty


    clamp(
        score,
        0.0,
        100.0
    )

end


# ============================================================
# AGEING ENVIRONMENT INDEX
# ============================================================

"""
A relative environmental stability metric.

This is NOT a wine-chemistry model. It measures how closely
the cellar environment is being maintained around its target.
"""
function stability_index(
    controller::WineCellarController
)

    if isempty(controller.telemetry)

        return 100.0
    end


    temperatures =
        [x.temperature_c
         for x in controller.telemetry]


    humidities =
        [x.humidity_pct
         for x in controller.telemetry]


    temp_variation =
        std(temperatures)


    humidity_variation =
        std(humidities)


    score =
        100.0 -
        temp_variation * 25.0 -
        humidity_variation * 1.5


    clamp(
        score,
        0.0,
        100.0
    )

end


# ============================================================
# ENERGY REPORT
# ============================================================

struct EnergyReport

    cooling_cycles::UInt64
    heating_cycles::UInt64
    humidity_cycles::UInt64

    estimated_cooling_runtime::Float64
    estimated_heating_runtime::Float64

end


function energy_report(
    controller::WineCellarController
)

    EnergyReport(

        controller.cooling_cycles,

        controller.heating_cycles,

        controller.humidity_cycles,

        Float64(
            controller.cooling_cycles
        ),

        Float64(
            controller.heating_cycles
        )
    )

end


# ============================================================
# STATUS REPORT
# ============================================================

function status(
    controller::WineCellarController
)

    s = controller.sensors
    a = controller.actuators


    println()
    println("==============================================")
    println("          ", SOFTWARE_NAME)
    println("          VERSION ", SOFTWARE_VERSION)
    println("==============================================")

    println()

    println("MODE        : ", controller.mode)
    println("STATE       : ", controller.state)

    println()

    println(
        "TEMPERATURE : ",
        round(s.temperature_c, digits=2),
        " °C"
    )

    println(
        "TARGET      : ",
        round(
            controller.profile.target_temperature_c,
            digits=2
        ),
        " °C"
    )

    println(
        "HUMIDITY    : ",
        round(s.humidity_pct, digits=2),
        " %RH"
    )

    println(
        "TARGET      : ",
        round(
            controller.profile.target_humidity_pct,
            digits=2
        ),
        " %RH"
    )

    println()

    println(
        "VIBRATION   : ",
        round(s.vibration_g, digits=4),
        " g"
    )

    println(
        "LIGHT       : ",
        round(s.light_lux, digits=2),
        " lux"
    )

    println()

    println("COOLING     : ", a.cooling)
    println("HEATING     : ", a.heating)

    println("HUMIDIFIER  : ", a.humidifier)
    println("DEHUMIDIFIER: ", a.dehumidifier)

    println("VENTILATION : ", a.ventilation)

    println()

    println(
        "HEALTH      : ",
        round(
            health_score(controller),
            digits=1
        ),
        "%"
    )

    println(
        "STABILITY   : ",
        round(
            stability_index(controller),
            digits=1
        ),
        "%"
    )

    println()

    println("ALARMS      : ", length(controller.alarms))
    println("CYCLES      : ", controller.control_cycles)

    println("==============================================")
    println()

end


# ============================================================
# SIMULATED SENSOR
# ============================================================

function simulated_sensor(
    temperature_c::Real,
    humidity_pct::Real;
    vibration_g = 0.01,
    light_lux = 0.0,
    door_open = false
)

    SensorSnapshot(

        now(),

        Float64(temperature_c),

        Float64(humidity_pct),

        Float64(vibration_g),

        Float64(light_lux),

        door_open,

        20.0,

        true
    )

end


# ============================================================
# SIMULATION ENGINE
# ============================================================

function simulate!(
    controller::WineCellarController;
    steps::Integer = 24,
    temperature_start = 12.5,
    humidity_start = 65.0
)

    temperature =
        Float64(temperature_start)


    humidity =
        Float64(humidity_start)


    for step in 1:steps

        # ----------------------------------------------------
        # Simulated environmental drift
        # ----------------------------------------------------

        temperature +=
            sin(step / 3.0) * 0.25


        humidity +=
            cos(step / 4.0) * 0.8


        sensor =
            simulated_sensor(
                temperature,
                humidity
            )


        tick!(
            controller,
            sensor
        )


        # ----------------------------------------------------
        # Simulated actuator effect
        # ----------------------------------------------------

        if controller.actuators.cooling

            temperature -= 0.25

        elseif controller.actuators.heating

            temperature += 0.15
        end


        if controller.actuators.humidifier

            humidity += 0.8

        elseif controller.actuators.dehumidifier

            humidity -= 0.8
        end

    end


    controller

end


# ============================================================
# WINE STORAGE ZONES
# ============================================================

@enum WineZoneType begin
    GENERAL_STORAGE
    RED_STORAGE
    WHITE_STORAGE
    SPARKLING_STORAGE
    SERVICE_ZONE
end


struct WineZone

    name::String

    zone_type::WineZoneType

    target_temperature_c::Float64

    target_humidity_pct::Float64

end


# ============================================================
# ZONE FACTORIES
# ============================================================

function general_storage_zone()

    WineZone(
        "General Cellar",
        GENERAL_STORAGE,
        12.5,
        65.0
    )

end


function red_zone()

    WineZone(
        "Red Wine",
        RED_STORAGE,
        13.0,
        65.0
    )

end


function white_zone()

    WineZone(
        "White Wine",
        WHITE_STORAGE,
        12.0,
        65.0
    )

end


function sparkling_zone()

    WineZone(
        "Sparkling",
        SPARKLING_STORAGE,
        10.0,
        65.0
    )

end


# ============================================================
# ZONE MANAGER
# ============================================================

mutable struct ZoneManager

    zones::Vector{WineZone}

end


ZoneManager() =
    ZoneManager(WineZone[])


function add_zone!(
    manager::ZoneManager,
    zone::WineZone
)

    push!(
        manager.zones,
        zone
    )

end


# ============================================================
# COLLECTION
# ============================================================

struct BottleRecord

    id::String

    producer::String

    wine_name::String

    vintage::Union{Int,Nothing}

    zone::String

    rack::String

    position::String

end


mutable struct CellarInventory

    bottles::Dict{String,BottleRecord}

end


CellarInventory() =
    CellarInventory(
        Dict{String,BottleRecord}()
    )


function add_bottle!(
    inventory::CellarInventory,
    bottle::BottleRecord
)

    inventory.bottles[bottle.id] =
        bottle

end


function remove_bottle!(
    inventory::CellarInventory,
    id::String
)

    pop!(
        inventory.bottles,
        id,
        nothing
    )

end


function bottle_count(
    inventory::CellarInventory
)

    length(
        inventory.bottles
    )

end


# ============================================================
# COLLECTION VALUE TRACKING
# ============================================================

struct Valuation

    bottle_id::String

    value_gbp::Float64

end


mutable struct CollectionLedger

    values::Dict{String,Float64}

end


CollectionLedger() =
    CollectionLedger(
        Dict{String,Float64}()
    )


function set_value!(
    ledger::CollectionLedger,
    bottle_id::String,
    value_gbp::Real
)

    ledger.values[bottle_id] =
        Float64(value_gbp)

end


function collection_value(
    ledger::CollectionLedger
)

    sum(
        values(ledger.values)
    )

end


# ============================================================
# HIGH-VALUE COLLECTION MODE
# ============================================================

function high_value_mode!(
    controller::WineCellarController
)

    # More conservative operating mode.

    controller.mode =
        NORMAL

    controller.profile =
        CellarProfile(

            12.5,

            11.8,
            13.2,

            65.0,

            60.0,
            70.0,

            8.0,
            18.0,

            45.0,
            80.0
        )

end


# ============================================================
# EXPORT TELEMETRY
# ============================================================

function telemetry_matrix(
    controller::WineCellarController
)

    n =
        length(
            controller.telemetry
        )


    matrix =
        Matrix{Float64}(
            undef,
            n,
            5
        )


    for (i, record)
        in enumerate(
            controller.telemetry
        )

        matrix[i,1] =
            record.temperature_c

        matrix[i,2] =
            record.humidity_pct

        matrix[i,3] =
            record.vibration_g

        matrix[i,4] =
            record.light_lux

        matrix[i,5] =
            record.ventilation ? 1.0 : 0.0

    end


    matrix

end


# ============================================================
# SELF DIAGNOSTICS
# ============================================================

struct DiagnosticReport

    sensors_ok::Bool

    actuators_safe::Bool

    environmental_state::EnvironmentState

    alarm_count::Int

    health_score::Float64

    stability_score::Float64

end


function diagnostics(
    controller::WineCellarController
)

    sensors_ok =
        valid_sensor_data(
            controller,
            controller.sensors
        )


    a =
        controller.actuators


    actuators_safe =
        !(
            a.cooling &&
            a.heating
        ) &&
        !(
            a.humidifier &&
            a.dehumidifier
        )


    DiagnosticReport(

        sensors_ok,

        actuators_safe,

        controller.state,

        length(
            controller.alarms
        ),

        health_score(
            controller
        ),

        stability_index(
            controller
        )
    )

end


# ============================================================
# STARTUP
# ============================================================

function startup!(
    controller::WineCellarController
)

    shutdown!(
        controller.actuators
    )


    controller.mode =
        NORMAL


    controller.state =
        STABILISING


    controller.alarms =
        Alarm[]


    controller.telemetry =
        Telemetry[]


    controller.control_cycles =
        UInt64(0)


    controller.cooling_cycles =
        UInt64(0)


    controller.heating_cycles =
        UInt64(0)


    controller.humidity_cycles =
        UInt64(0)


    controller

end


# ============================================================
# SHUTDOWN
# ============================================================

function shutdown_system!(
    controller::WineCellarController
)

    shutdown!(
        controller.actuators
    )

    controller.state =
        STABILISING

    controller.mode =
        MAINTENANCE

end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println()
    println("Starting ", SOFTWARE_NAME)
    println()


    controller =
        WineCellarController()


    startup!(
        controller
    )


    # --------------------------------------------------------
    # Normal cellar
    # --------------------------------------------------------

    tick!(
        controller,

        simulated_sensor(
            12.5,
            65.0
        )
    )


    # --------------------------------------------------------
    # Cellar becomes warm
    # --------------------------------------------------------

    tick!(
        controller,

        simulated_sensor(
            15.0,
            65.0
        )
    )


    # --------------------------------------------------------
    # Cellar becomes humid
    # --------------------------------------------------------

    tick!(
        controller,

        simulated_sensor(
            12.5,
            76.0
        )
    )


    # --------------------------------------------------------
    # Return to normal
    # --------------------------------------------------------

    tick!(
        controller,

        simulated_sensor(
            12.5,
            65.0
        )
    )


    status(
        controller
    )


    println(
        "Diagnostics:"
    )


    println(
        diagnostics(
            controller
        )
    )


    println()


    println(
        "Energy report:"
    )


    println(
        energy_report(
            controller
        )
    )


    println()


    println(
        "Running simulation..."
    )


    simulate!(
        controller,
        steps = 48
    )


    status(
        controller
    )


    return controller

end


end # module


# ============================================================
# EXECUTION
# ============================================================

using .WineCellarOS

WineCellarOS.demo()
