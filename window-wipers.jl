###############################################################
# AUREOM VEHICLE AI
# PREDICTIVE WINDSHIELD WIPER + CLEANING SYSTEM
#
# Julia research / simulation implementation
###############################################################

using Dates
using Printf

############################
# ENUMS
############################

@enum WiperMode begin
    OFF
    MANUAL
    AUTO
    LIGHT_RAIN
    MEDIUM_RAIN
    HEAVY_RAIN
    STORM
    SNOW
    ICE
    CLEANING
    DEFROST
    FAULT
end

@enum WiperDirection begin
    FORWARD
    REVERSE
end

############################
# CONFIGURATION
############################

struct WiperConfig

    # Wiper geometry
    max_wipe_angle::Float64
    min_wipe_angle::Float64

    # Speed
    min_cycle_frequency::Float64
    max_cycle_frequency::Float64

    # Motor
    max_motor_speed::Float64
    max_motor_current::Float64
    max_motor_temperature::Float64

    # Rain
    rain_threshold::Float64
    heavy_rain_threshold::Float64
    storm_threshold::Float64

    # Visibility
    visibility_min::Float64
    visibility_target::Float64

    # Vehicle speed
    speed_compensation::Float64

    # Washer system
    washer_flow_rate::Float64
    washer_pressure::Float64
    washer_max_duration::Float64

    # Protection
    snow_load_limit::Float64
    ice_load_limit::Float64

    # Camera
    camera_visibility_threshold::Float64

    # Control
    dt::Float64
end


const DEFAULT_WIPER_CONFIG = WiperConfig(
    82.0,       # max wipe angle
    48.0,       # min wipe angle

    0.15,       # minimum frequency
    3.0,        # maximum cycles/sec

    180.0,      # motor speed
    18.0,       # motor current
    120.0,      # motor temperature

    0.10,       # rain threshold
    0.40,       # heavy rain
    0.75,       # storm

    0.20,       # minimum visibility
    0.95,       # desired visibility

    0.025,      # speed compensation

    0.35,       # washer flow
    3.0,        # washer pressure
    2.5,        # max spray duration

    8.0,        # snow load
    10.0,       # ice load

    0.85,       # camera visibility

    0.02
)

############################
# SENSOR STATE
############################

mutable struct WiperSensors

    timestamp::DateTime

    rain_sensor::Float64
    optical_rain::Float64

    windshield_visibility::Float64

    ambient_temperature::Float64

    humidity::Float64

    road_spray::Float64

    snow_detection::Float64
    ice_detection::Float64

    windshield_contamination::Float64

    camera_visibility::Float64

    vehicle_speed::Float64

    steering_angle::Float64

    yaw_rate::Float64

    motor_current::Float64
    motor_temperature::Float64

    washer_level::Float64
end

############################
# WIPER STATE
############################

mutable struct WiperState

    mode::WiperMode

    frequency::Float64

    wipe_angle::Float64

    motor_speed::Float64

    motor_current::Float64

    motor_temperature::Float64

    blade_load::Float64

    washer_active::Bool

    washer_duration::Float64

    washer_pressure::Float64

    front_left_position::Float64
    front_right_position::Float64

    rear_position::Float64

    direction::WiperDirection

    camera_cleaning::Bool

    defrost_active::Bool

    cleaning_score::Float64

    visibility_score::Float64

    cycle_count::Int

    fault::Bool

    last_update::DateTime
end

############################
# COMMAND
############################

struct WiperCommand

    mode::WiperMode

    frequency::Float64

    wipe_angle::Float64

    motor_speed::Float64

    washer::Bool

    washer_duration::Float64

    washer_pressure::Float64

    rear_wiper::Bool

    camera_clean::Bool

    defrost::Bool
end

############################
# UTILITY
############################

clamp(x, lo, hi) = max(lo, min(hi, x))

function lerp(a, b, t)

    t = clamp(t, 0.0, 1.0)

    return a + (b - a) * t
end

############################
# RAIN SENSOR FUSION
############################

function estimate_rain(sensor::WiperSensors)

    optical = sensor.optical_rain
    physical = sensor.rain_sensor

    # Sensor fusion
    rain = (
        0.55 * optical +
        0.45 * physical
    )

    # Road spray correction
    rain += 0.15 * sensor.road_spray

    return clamp(rain, 0.0, 1.0)
end

############################
# VISIBILITY ESTIMATION
############################

function estimate_visibility(sensor::WiperSensors)

    visibility = sensor.windshield_visibility

    contamination_penalty =
        0.30 * sensor.windshield_contamination

    camera_penalty =
        0.20 * (1.0 - sensor.camera_visibility)

    rain_penalty =
        0.20 * estimate_rain(sensor)

    visibility -=
        contamination_penalty +
        camera_penalty +
        rain_penalty

    return clamp(visibility, 0.0, 1.0)
end

############################
# WIPER MODE
############################

function determine_mode(
    sensor::WiperSensors,
    cfg::WiperConfig
)

    rain = estimate_rain(sensor)

    if sensor.ice_detection > 0.8

        return ICE

    elseif sensor.snow_detection > 0.7

        return SNOW

    elseif rain >= cfg.storm_threshold

        return STORM

    elseif rain >= cfg.heavy_rain_threshold

        return HEAVY_RAIN

    elseif rain >= cfg.rain_threshold

        return MEDIUM_RAIN

    elseif sensor.windshield_contamination > 0.75

        return CLEANING

    elseif sensor.camera_visibility <
           cfg.camera_visibility_threshold

        return CLEANING

    else

        return AUTO
    end
end

############################
# RAIN INTENSITY
############################

function rain_intensity(
    sensor::WiperSensors
)

    rain = estimate_rain(sensor)

    # Non-linear response
    return clamp(
        rain^1.35,
        0.0,
        1.0
    )
end

############################
# WIPE FREQUENCY
############################

function calculate_frequency(
    sensor::WiperSensors,
    cfg::WiperConfig
)

    rain = rain_intensity(sensor)

    speed = sensor.vehicle_speed

    # Base rain response
    frequency = lerp(
        cfg.min_cycle_frequency,
        cfg.max_cycle_frequency,
        rain
    )

    # Increase response at speed because
    # aerodynamic water loading increases.
    speed_factor =
        1.0 +
        cfg.speed_compensation * speed

    frequency *= speed_factor

    # Road spray
    frequency *=
        1.0 +
        0.35 * sensor.road_spray

    return clamp(
        frequency,
        cfg.min_cycle_frequency,
        cfg.max_cycle_frequency
    )
end

############################
# WIPE ANGLE
############################

function calculate_wipe_angle(
    sensor::WiperSensors,
    cfg::WiperConfig
)

    visibility =
        estimate_visibility(sensor)

    contamination =
        sensor.windshield_contamination

    angle_factor =
        0.75 * (1.0 - visibility) +
        0.25 * contamination

    return lerp(
        cfg.min_wipe_angle,
        cfg.max_wipe_angle,
        angle_factor
    )
end

############################
# MOTOR SPEED
############################

function calculate_motor_speed(
    frequency::Float64,
    cfg::WiperConfig
)

    # Two wipes per cycle.
    speed =
        frequency *
        2.0 *
        cfg.max_wipe_angle

    return clamp(
        speed,
        0.0,
        cfg.max_motor_speed
    )
end

############################
# BLADE LOAD
############################

function estimate_blade_load(
    sensor::WiperSensors,
    frequency::Float64
)

    rain_load =
        2.0 *
        estimate_rain(sensor)

    snow_load =
        3.0 *
        sensor.snow_detection

    ice_load =
        5.0 *
        sensor.ice_detection

    speed_load =
        0.015 *
        sensor.vehicle_speed

    frequency_load =
        0.10 *
        frequency

    return (
        rain_load +
        snow_load +
        ice_load +
        speed_load +
        frequency_load
    )
end

############################
# MOTOR PROTECTION
############################

function motor_protection(
    load::Float64,
    sensor::WiperSensors,
    cfg::WiperConfig
)

    if sensor.motor_temperature >
       cfg.max_motor_temperature

        return true

    elseif sensor.motor_current >
           cfg.max_motor_current

        return true

    elseif load >
           cfg.snow_load_limit +
           cfg.ice_load_limit

        return true

    end

    return false
end

############################
# WASHER OPTIMISATION
############################

function washer_required(
    sensor::WiperSensors
)

    contamination =
        sensor.windshield_contamination

    visibility =
        estimate_visibility(sensor)

    camera =
        sensor.camera_visibility

    return (
        contamination > 0.65 ||
        visibility < 0.45 ||
        camera < 0.65
    )
end

############################
# WASHER DURATION
############################

function calculate_washer_duration(
    sensor::WiperSensors,
    cfg::WiperConfig
)

    contamination =
        sensor.windshield_contamination

    duration =
        0.4 +
        1.7 * contamination

    # High speed requires more controlled
    # delivery but not necessarily more fluid.
    if sensor.vehicle_speed > 30.0

        duration *= 0.85

    end

    return clamp(
        duration,
        0.3,
        cfg.washer_max_duration
    )
end

############################
# WASHER PRESSURE
############################

function calculate_washer_pressure(
    sensor::WiperSensors,
    cfg::WiperConfig
)

    contamination =
        sensor.windshield_contamination

    speed =
        sensor.vehicle_speed

    pressure =
        1.5 +
        1.0 * contamination +
        0.01 * speed

    return clamp(
        pressure,
        1.0,
        cfg.washer_pressure
    )
end

############################
# CAMERA CLEANING
############################

function camera_cleaning_required(
    sensor::WiperSensors,
    cfg::WiperConfig
)

    return (
        sensor.camera_visibility <
        cfg.camera_visibility_threshold
    )
end

############################
# PREDICTIVE CLEANING
############################

function predictive_cleaning(
    sensor::WiperSensors
)

    # Predict worsening visibility from
    # rain + contamination + road spray.

    rain =
        estimate_rain(sensor)

    contamination =
        sensor.windshield_contamination

    spray =
        sensor.road_spray

    predicted =
        0.50 * rain +
        0.30 * contamination +
        0.20 * spray

    return clamp(
        predicted,
        0.0,
        1.0
    )
end

############################
# REAR WIPER
############################

function rear_wiper_required(
    sensor::WiperSensors
)

    rear_need =
        0.50 * estimate_rain(sensor) +
        0.30 * sensor.road_spray +
        0.20 * sensor.windshield_contamination

    return rear_need > 0.30
end

############################
# MAIN OPTIMISER
############################

function optimise_wipers(
    sensor::WiperSensors,
    cfg::WiperConfig
)

    mode =
        determine_mode(
            sensor,
            cfg
        )

    ########################
    # ICE / SNOW PROTECTION
    ########################

    if mode == ICE

        return WiperCommand(
            DEFROST,
            0.0,
            0.0,
            0.0,
            false,
            0.0,
            0.0,
            false,
            true,
            true
        )
    end

    if mode == SNOW

        return WiperCommand(
            SNOW,
            0.20,
            60.0,
            40.0,
            false,
            0.0,
            0.0,
            true,
            true,
            true
        )
    end

    ########################
    # NORMAL WIPING
    ########################

    frequency =
        calculate_frequency(
            sensor,
            cfg
        )

    angle =
        calculate_wipe_angle(
            sensor,
            cfg
        )

    motor =
        calculate_motor_speed(
            frequency,
            cfg
        )

    load =
        estimate_blade_load(
            sensor,
            frequency
        )

    ########################
    # SAFETY
    ########################

    if motor_protection(
        load,
        sensor,
        cfg
    )

        return WiperCommand(
            FAULT,
            0.0,
            0.0,
            0.0,
            false,
            0.0,
            0.0,
            false,
            false,
            false
        )
    end

    ########################
    # CLEANING
    ########################

    cleaning =
        washer_required(sensor)

    washer_duration =
        cleaning ?
        calculate_washer_duration(
            sensor,
            cfg
        ) : 0.0

    washer_pressure =
        cleaning ?
        calculate_washer_pressure(
            sensor,
            cfg
        ) : 0.0

    camera_clean =
        camera_cleaning_required(
            sensor,
            cfg
        )

    rear =
        rear_wiper_required(
            sensor
        )

    return WiperCommand(
        mode,
        frequency,
        angle,
        motor,
        cleaning,
        washer_duration,
        washer_pressure,
        rear,
        camera_clean,
        false
    )
end

############################
# WIPER STATE UPDATE
############################

function update_wiper!(
    state::WiperState,
    command::WiperCommand,
    sensor::WiperSensors,
    cfg::WiperConfig
)

    state.mode =
        command.mode

    state.frequency =
        command.frequency

    state.wipe_angle =
        command.wipe_angle

    state.motor_speed =
        command.motor_speed

    state.washer_active =
        command.washer

    state.washer_duration =
        command.washer_duration

    state.washer_pressure =
        command.washer_pressure

    state.camera_cleaning =
        command.camera_clean

    state.defrost_active =
        command.defrost

    state.blade_load =
        estimate_blade_load(
            sensor,
            command.frequency
        )

    state.motor_current =
        2.0 +
        0.8 * state.blade_load

    state.motor_temperature +=
        0.015 *
        state.motor_current

    # Passive cooling
    state.motor_temperature -=
        0.01 *
        (state.motor_temperature - 25.0)

    state.motor_temperature =
        clamp(
            state.motor_temperature,
            20.0,
            140.0
        )

    ########################
    # WIPER POSITION
    ########################

    if command.frequency > 0

        phase =
            sin(
                2π *
                state.cycle_count *
                cfg.dt *
                command.frequency
            )

        state.front_left_position =
            command.wipe_angle * phase

        state.front_right_position =
            -command.wipe_angle * phase

        if command.rear_wiper

            state.rear_position =
                70.0 * phase

        end
    end

    ########################
    # VISIBILITY
    ########################

    cleaning_effect =
        command.frequency *
        0.025

    contamination =
        sensor.windshield_contamination

    state.cleaning_score =
        clamp(
            1.0 -
            contamination +
            cleaning_effect,
            0.0,
            1.0
        )

    state.visibility_score =
        clamp(
            estimate_visibility(sensor) +
            0.20 * cleaning_effect,
            0.0,
            1.0
        )

    ########################
    # COUNTER
    ########################

    if command.frequency > 0

        state.cycle_count += 1

    end

    state.last_update =
        sensor.timestamp

    return state
end

############################
# SIMULATED SENSOR INPUT
############################

function simulated_sensors(t)

    rain =
        clamp(
            0.15 +
            0.45 *
            (sin(t / 8.0) + 1.0) / 2.0,
            0.0,
            1.0
        )

    contamination =
        clamp(
            0.25 +
            0.15 *
            sin(t / 12.0),
            0.0,
            1.0
        )

    visibility =
        clamp(
            1.0 -
            0.65 * rain -
            0.25 * contamination,
            0.0,
            1.0
        )

    speed =
        15.0 +
        12.0 *
        sin(t / 10.0)

    return WiperSensors(

        now(),

        rain,
        rain * 0.95,

        visibility,

        12.0,

        0.85,

        rain * 0.45,

        0.0,
        0.0,

        contamination,

        visibility,

        max(speed, 0.0),

        0.0,

        0.02,

        4.0,

        28.0,

        0.0,

        65.0
    )
end

############################
# CREATE SYSTEM
############################

function create_wiper_system()

    state = WiperState(

        AUTO,

        0.0,
        60.0,

        0.0,
        0.0,
        25.0,

        0.0,

        false,
        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        FORWARD,

        false,
        false,

        0.0,
        1.0,

        0,

        false,

        now()
    )

    return state
end

############################
# LIVE SYSTEM
############################

function run_wiper_system(
    duration_seconds = 30.0
)

    cfg =
        DEFAULT_WIPER_CONFIG

    state =
        create_wiper_system()

    start =
        time()

    t = 0.0

    while time() - start <
          duration_seconds

        sensor =
            simulated_sensors(t)

        command =
            optimise_wipers(
                sensor,
                cfg
            )

        update_wiper!(
            state,
            command,
            sensor,
            cfg
        )

        ####################
        # LIVE TELEMETRY
        ####################

        @printf(
            "\rRAIN %.2f | VIS %.2f | MODE %-12s | WIPER %.2f Hz | ANGLE %.1f° | MOTOR %.1f | LOAD %.2f | WASH %s",
            estimate_rain(sensor),
            state.visibility_score,
            string(state.mode),
            state.frequency,
            state.wipe_angle,
            state.motor_speed,
            state.blade_load,
            state.washer_active ? "ON" : "OFF"
        )

        flush(stdout)

        sleep(cfg.dt)

        t += cfg.dt
    end

    println()

    return state
end

###############################################################
# END
###############################################################
