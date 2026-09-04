module JuliaAutoland

using LinearAlgebra
using Printf

# ============================================================
# AIRCRAFT LANDING SIMULATOR
# ============================================================

@enum FlightPhase begin
    APPROACH
    FLARE
    TOUCHDOWN
    ROLLOUT
    GO_AROUND
    STOPPED
end

# ------------------------------------------------------------
# Aircraft state
# ------------------------------------------------------------

mutable struct Aircraft

    # Position
    x::Float64
    y::Float64
    altitude::Float64

    # Velocity
    airspeed::Float64
    groundspeed::Float64
    vertical_speed::Float64

    # Attitude
    pitch::Float64
    roll::Float64
    yaw::Float64

    # Angular rates
    pitch_rate::Float64
    roll_rate::Float64

    # Control surfaces
    elevator::Float64
    aileron::Float64
    rudder::Float64

    # Engine/throttle
    throttle::Float64

    phase::FlightPhase

    on_ground::Bool
end

# ------------------------------------------------------------
# ILS sensor model
# ------------------------------------------------------------

mutable struct ILSSensor

    localizer_error::Float64
    glideslope_error::Float64

    signal_quality::Float64

    localizer_valid::Bool
    glideslope_valid::Bool
end

# ------------------------------------------------------------
# Radio altimeter
# ------------------------------------------------------------

struct RadioAltimeter

    altitude::Float64
    valid::Bool
end

# ------------------------------------------------------------
# Landing runway
# ------------------------------------------------------------

struct Runway

    heading::Float64

    elevation::Float64

    length::Float64

    touchdown_zone::Float64

    glideslope_deg::Float64
end

# ------------------------------------------------------------
# Autoland controller
# ------------------------------------------------------------

mutable struct AutolandController

    enabled::Bool

    flare_altitude::Float64

    touchdown_speed::Float64

    target_glideslope::Float64

    max_roll_command::Float64
    max_pitch_command::Float64

    lateral_gain::Float64
    vertical_gain::Float64

    pitch_integral::Float64
    roll_integral::Float64

    previous_localizer::Float64
    previous_glideslope::Float64

    failure_detected::Bool

    go_around::Bool
end

# ============================================================
# INITIALIZATION
# ============================================================

function create_aircraft()

    Aircraft(

        0.0,
        0.0,
        900.0,

        72.0,
        72.0,
        -3.0,

        3.0,
        0.0,
        0.0,

        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        0.65,

        APPROACH,

        false
    )
end

function create_controller()

    AutolandController(

        true,

        15.0,

        65.0,

        3.0,

        5.0,
        8.0,

        0.8,
        0.9,

        0.0,
        0.0,

        0.0,
        0.0,

        false,

        false
    )
end

function create_runway()

    Runway(

        0.0,       # heading

        0.0,       # elevation

        3000.0,    # runway length

        300.0,     # touchdown zone

        3.0        # glide slope
    )
end

# ============================================================
# ILS GEOMETRY
# ============================================================

function calculate_localizer_error(
    aircraft::Aircraft,
    runway::Runway
)

    # Simplified lateral displacement from
    # runway centerline.

    aircraft.x
end

function calculate_glideslope_error(
    aircraft::Aircraft,
    runway::Runway
)

    # Simplified ideal glide path.

    distance =
        max(
            aircraft.y,
            1.0
        )

    target_altitude =
        tan(
            deg2rad(
                runway.glideslope_deg
            )
        ) *
        distance

    aircraft.altitude -
    target_altitude
end

# ============================================================
# SENSOR UPDATE
# ============================================================

function update_ils!(
    sensor::ILSSensor,
    aircraft::Aircraft,
    runway::Runway
)

    sensor.localizer_error =
        calculate_localizer_error(
            aircraft,
            runway
        )

    sensor.glideslope_error =
        calculate_glideslope_error(
            aircraft,
            runway
        )

    sensor.signal_quality = 1.0

    sensor.localizer_valid =
        true

    sensor.glideslope_valid =
        true

    sensor
end

# ============================================================
# LATERAL CONTROL
# ============================================================

function lateral_controller(
    controller::AutolandController,
    sensor::ILSSensor,
    dt::Float64
)

    error =
        sensor.localizer_error

    controller.roll_integral +=
        error * dt

    derivative =
        (
            error -
            controller.previous_localizer
        ) / dt

    controller.previous_localizer =
        error

    command =
        -controller.lateral_gain * error -
        0.05 * controller.roll_integral -
        0.2 * derivative

    clamp(
        command,
        -controller.max_roll_command,
        controller.max_roll_command
    )
end

# ============================================================
# VERTICAL CONTROL
# ============================================================

function vertical_controller(
    controller::AutolandController,
    sensor::ILSSensor,
    aircraft::Aircraft,
    dt::Float64
)

    error =
        sensor.glideslope_error

    controller.pitch_integral +=
        error * dt

    derivative =
        (
            error -
            controller.previous_glideslope
        ) / dt

    controller.previous_glideslope =
        error

    command =
        -controller.vertical_gain * error -
        0.03 * controller.pitch_integral -
        0.1 * derivative

    clamp(
        command,
        -controller.max_pitch_command,
        controller.max_pitch_command
    )
end

# ============================================================
# FLARE
# ============================================================

function flare_controller!(
    controller::AutolandController,
    aircraft::Aircraft
)

    if aircraft.altitude <=
       controller.flare_altitude

        aircraft.phase =
            FLARE

        # Gradually reduce descent rate.
        aircraft.vertical_speed =
            max(
                aircraft.vertical_speed,
                -0.5
            )
    end
end

# ============================================================
# AIRCRAFT DYNAMICS
# ============================================================

function update_aircraft!(
    aircraft::Aircraft,
    roll_command::Float64,
    pitch_command::Float64,
    dt::Float64
)

    # --------------------------------------------------------
    # Simplified attitude response
    # --------------------------------------------------------

    roll_target =
        roll_command

    pitch_target =
        pitch_command

    aircraft.roll_rate +=
        (
            roll_target -
            aircraft.roll
        ) *
        2.0 *
        dt

    aircraft.pitch_rate +=
        (
            pitch_target -
            aircraft.pitch
        ) *
        1.5 *
        dt

    aircraft.roll +=
        aircraft.roll_rate * dt

    aircraft.pitch +=
        aircraft.pitch_rate * dt

    # --------------------------------------------------------
    # Clamp aircraft attitude
    # --------------------------------------------------------

    aircraft.roll =
        clamp(
            aircraft.roll,
            -10.0,
            10.0
        )

    aircraft.pitch =
        clamp(
            aircraft.pitch,
            -10.0,
            10.0
        )

    # --------------------------------------------------------
    # Vertical dynamics
    # --------------------------------------------------------

    target_vs =
        -aircraft.airspeed *
        sin(
            deg2rad(
                3.0
            )
        )

    aircraft.vertical_speed +=
        (
            target_vs -
            aircraft.vertical_speed
        ) *
        0.1 *
        dt

    aircraft.altitude +=
        aircraft.vertical_speed *
        dt

    # --------------------------------------------------------
    # Lateral dynamics
    # --------------------------------------------------------

    lateral_velocity =
        aircraft.groundspeed *
        sin(
            deg2rad(
                aircraft.roll
            )
        )

    aircraft.x +=
        lateral_velocity *
        dt

    # --------------------------------------------------------
    # Forward motion
    # --------------------------------------------------------

    aircraft.y +=
        aircraft.groundspeed *
        dt

    # --------------------------------------------------------
    # Ground contact
    # --------------------------------------------------------

    if aircraft.altitude <= 0

        aircraft.altitude =
            0.0

        aircraft.vertical_speed =
            0.0

        aircraft.on_ground =
            true

        aircraft.phase =
            TOUCHDOWN
    end
end

# ============================================================
# SPEED CONTROL
# ============================================================

function speed_controller!(
    aircraft::Aircraft,
    target_speed::Float64,
    dt::Float64
)

    speed_error =
        target_speed -
        aircraft.airspeed

    aircraft.throttle +=
        speed_error *
        0.01 *
        dt

    aircraft.throttle =
        clamp(
            aircraft.throttle,
            0.0,
            1.0
        )

    aircraft.airspeed +=
        (
            aircraft.throttle *
            10.0 -
            aircraft.airspeed *
            0.02
        ) *
        dt

    aircraft.airspeed =
        clamp(
            aircraft.airspeed,
            40.0,
            100.0
        )

    aircraft.groundspeed =
        aircraft.airspeed
end

# ============================================================
# SAFETY MONITOR
# ============================================================

function monitor_system!(
    controller::AutolandController,
    sensor::ILSSensor,
    aircraft::Aircraft
)

    # Invalid ILS
    if !sensor.localizer_valid ||
       !sensor.glideslope_valid

        controller.failure_detected =
            true

        controller.go_around =
            true

        return
    end

    # Excessive deviation
    if abs(
        sensor.localizer_error
    ) > 100.0

        controller.failure_detected =
            true

        controller.go_around =
            true

        return
    end

    # Excessive vertical deviation
    if abs(
        sensor.glideslope_error
    ) > 100.0

        controller.failure_detected =
            true

        controller.go_around =
            true
    end
end

# ============================================================
# GO-AROUND
# ============================================================

function execute_go_around!(
    aircraft::Aircraft
)

    aircraft.phase =
        GO_AROUND

    aircraft.throttle =
        1.0

    aircraft.vertical_speed =
        5.0

    println(
        "!!! GO-AROUND !!!"
    )
end

# ============================================================
# TOUCHDOWN
# ============================================================

function touchdown_logic!(
    aircraft::Aircraft
)

    if aircraft.phase ==
       TOUCHDOWN

        println(
            "TOUCHDOWN"
        )

        println(
            "Airspeed: ",
            round(
                aircraft.airspeed,
                digits=1
            )
        )

        aircraft.throttle =
            0.05

        aircraft.phase =
            ROLLOUT
    end
end

# ============================================================
# ROLLOUT
# ============================================================

function rollout!(
    aircraft::Aircraft,
    dt::Float64
)

    if aircraft.phase !=
       ROLLOUT

        return
    end

    aircraft.groundspeed -=
        5.0 * dt

    aircraft.groundspeed =
        max(
            aircraft.groundspeed,
            0.0
        )

    aircraft.airspeed =
        aircraft.groundspeed

    if aircraft.groundspeed <= 0.5

        aircraft.phase =
            STOPPED

        println(
            "AIRCRAFT STOPPED"
        )
    end
end

# ============================================================
# COMPLETE SIMULATION
# ============================================================

function run_autoland(
    ;
    duration=300.0,
    dt=0.05
)

    aircraft =
        create_aircraft()

    controller =
        create_controller()

    runway =
        create_runway()

    sensor =
        ILSSensor(
            0.0,
            0.0,
            1.0,
            true,
            true
        )

    t = 0.0

    println()
    println(
        "=========================================="
    )
    println(
        " JULIA AUTOLAND SIMULATOR"
    )
    println(
        "=========================================="
    )

    while t < duration

        if aircraft.phase ==
           STOPPED

            break
        end

        # ----------------------------------------------------
        # Sensor update
        # ----------------------------------------------------

        update_ils!(
            sensor,
            aircraft,
            runway
        )

        # ----------------------------------------------------
        # Safety monitoring
        # ----------------------------------------------------

        monitor_system!(
            controller,
            sensor,
            aircraft
        )

        if controller.go_around

            execute_go_around!(
                aircraft
            )

            break
        end

        # ----------------------------------------------------
        # Controllers
        # ----------------------------------------------------

        roll_command =
            lateral_controller(
                controller,
                sensor,
                dt
            )

        pitch_command =
            vertical_controller(
                controller,
                sensor,
                aircraft,
                dt
            )

        # ----------------------------------------------------
        # Flare
        # ----------------------------------------------------

        flare_controller!(
            controller,
            aircraft
        )

        # ----------------------------------------------------
        # Speed
        # ----------------------------------------------------

        speed_controller!(
            aircraft,
            controller.touchdown_speed,
            dt
        )

        # ----------------------------------------------------
        # Aircraft dynamics
        # ----------------------------------------------------

        update_aircraft!(
            aircraft,
            roll_command,
            pitch_command,
            dt
        )

        touchdown_logic!(
            aircraft
        )

        rollout!(
            aircraft,
            dt
        )

        # ----------------------------------------------------
        # Telemetry
        # ----------------------------------------------------

        if mod(
            round(
                t / dt
            ),
            100
        ) == 0

            @printf(
                "t=%6.1f  ALT=%7.1f  SPD=%5.1f  LOC=%7.2f  GS=%7.2f  ROLL=%5.2f\n",
                t,
                aircraft.altitude,
                aircraft.airspeed,
                sensor.localizer_error,
                sensor.glideslope_error,
                aircraft.roll
            )
        end

        t += dt
    end

    println(
        "=========================================="
    )

    aircraft
end

end # module
