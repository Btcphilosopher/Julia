module JuliaTakeoff

using Printf
using Dates

export Aircraft,
       Runway,
       TakeoffController,
       TakeoffPhase,
       create_aircraft,
       create_runway,
       create_controller,
       run_takeoff

# ============================================================
# TAKEOFF PHASES
# ============================================================

@enum TakeoffPhase begin
    PARKED
    LINEUP
    TAKEOFF_POWER
    TAKEOFF_ROLL
    V1_REACHED
    ROTATION
    LIFTOFF
    INITIAL_CLIMB
    GEAR_UP
    CLIMB_OUT
    ABORT
    COMPLETE
end

# ============================================================
# AIRCRAFT
# ============================================================

mutable struct Aircraft

    # Position
    x::Float64
    altitude::Float64

    # Motion
    groundspeed::Float64
    airspeed::Float64
    vertical_speed::Float64

    # Attitude
    pitch::Float64
    roll::Float64
    yaw::Float64

    # Engines
    throttle::Float64
    engine_count::Int
    engines_running::Int

    # Controls
    elevator::Float64
    rudder::Float64
    aileron::Float64

    # Configuration
    flaps::Float64
    gear_down::Bool

    # State
    phase::TakeoffPhase
    airborne::Bool
end

# ============================================================
# RUNWAY
# ============================================================

struct Runway

    length::Float64
    width::Float64
    elevation::Float64
    heading::Float64

    # Simplified runway condition
    friction::Float64
    wind_speed::Float64
    wind_direction::Float64
end

# ============================================================
# TAKEOFF CONTROLLER
# ============================================================

mutable struct TakeoffController

    enabled::Bool

    # Reference speeds
    v1::Float64
    vr::Float64
    v2::Float64

    # Desired pitch
    rotation_pitch::Float64
    climb_pitch::Float64

    # Control gains
    pitch_gain::Float64
    heading_gain::Float64
    speed_gain::Float64

    # Target heading
    runway_heading::Float64

    # Safety limits
    max_pitch::Float64
    max_roll::Float64

    # Failure state
    engine_failure::Bool
    reject_takeoff::Bool
end

# ============================================================
# AIRCRAFT INITIALIZATION
# ============================================================

function create_aircraft()

    Aircraft(

        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        0.0,
        0.0,
        0.0,

        0.0,
        2,
        2,

        0.0,
        0.0,
        0.0,

        5.0,
        true,

        PARKED,
        false
    )
end

# ============================================================
# RUNWAY
# ============================================================

function create_runway()

    Runway(

        3000.0,
        45.0,
        0.0,
        90.0,

        0.025,

        0.0,
        90.0
    )
end

# ============================================================
# CONTROLLER
# ============================================================

function create_controller(
    runway::Runway
)

    # Example simulator values only.
    #
    # These are NOT aircraft-specific operational
    # performance numbers.

    TakeoffController(

        true,

        130.0,     # V1
        140.0,     # VR
        150.0,     # V2

        12.0,      # rotation pitch
        10.0,      # climb pitch

        1.5,
        0.8,
        0.03,

        runway.heading,

        15.0,
        10.0,

        false,
        false
    )
end

# ============================================================
# ENGINE THRUST MODEL
# ============================================================

function engine_thrust(
    aircraft::Aircraft
)

    if aircraft.engines_running == 0
        return 0.0
    end

    engine_fraction =
        aircraft.engines_running /
        aircraft.engine_count

    # Simplified normalized thrust model.

    180_000.0 *
    aircraft.throttle *
    engine_fraction
end

# ============================================================
# AERODYNAMIC DRAG
# ============================================================

function aerodynamic_drag(
    aircraft::Aircraft
)

    speed =
        aircraft.airspeed

    # Simplified quadratic drag.

    0.5 *
    1.225 *
    350.0 *
    0.035 *
    speed^2
end

# ============================================================
# GROUND FRICTION
# ============================================================

function rolling_resistance(
    aircraft::Aircraft,
    runway::Runway
)

    if aircraft.airborne
        return 0.0
    end

    mass =
        180_000.0

    mass *
    9.81 *
    runway.friction
end

# ============================================================
# SPEED UPDATE
# ============================================================

function update_speed!(
    aircraft::Aircraft,
    runway::Runway,
    dt::Float64
)

    thrust =
        engine_thrust(
            aircraft
        )

    drag =
        aerodynamic_drag(
            aircraft
        )

    resistance =
        rolling_resistance(
            aircraft,
            runway
        )

    mass =
        180_000.0

    acceleration =
        (
            thrust -
            drag -
            resistance
        ) / mass

    aircraft.groundspeed +=
        acceleration * dt

    aircraft.groundspeed =
        max(
            aircraft.groundspeed,
            0.0
        )

    aircraft.airspeed =
        aircraft.groundspeed
end

# ============================================================
# TAKEOFF DISTANCE
# ============================================================

function takeoff_distance(
    aircraft::Aircraft,
    dt::Float64
)

    aircraft.x +=
        aircraft.groundspeed * dt
end

# ============================================================
# ROTATION CONTROLLER
# ============================================================

function rotation_controller!(
    aircraft::Aircraft,
    controller::TakeoffController,
    dt::Float64
)

    if aircraft.airspeed >=
       controller.vr

        aircraft.phase =
            ROTATION

        pitch_error =
            controller.rotation_pitch -
            aircraft.pitch

        aircraft.pitch +=
            pitch_error *
            controller.pitch_gain *
            dt

        aircraft.pitch =
            min(
                aircraft.pitch,
                controller.max_pitch
            )
    end
end

# ============================================================
# LATERAL CONTROL
# ============================================================

function runway_heading_controller!(
    aircraft::Aircraft,
    controller::TakeoffController,
    dt::Float64
)

    heading_error =
        controller.runway_heading -
        aircraft.yaw

    rudder_command =
        heading_error *
        controller.heading_gain

    aircraft.rudder =
        clamp(
            rudder_command,
            -1.0,
            1.0
        )

    aircraft.yaw +=
        aircraft.rudder *
        2.0 *
        dt
end

# ============================================================
# LIFTOFF
# ============================================================

function check_liftoff!(
    aircraft::Aircraft,
    controller::TakeoffController
)

    if aircraft.phase ==
       ROTATION

        if aircraft.pitch >=
           8.0 &&
           aircraft.airspeed >=
           controller.vr

            aircraft.airborne =
                true

            aircraft.phase =
                LIFTOFF

            aircraft.altitude =
                1.0

            aircraft.vertical_speed =
                1.0

            println(
                ">>> LIFTOFF"
            )
        end
    end
end

# ============================================================
# INITIAL CLIMB
# ============================================================

function climb_controller!(
    aircraft::Aircraft,
    controller::TakeoffController,
    dt::Float64
)

    if !aircraft.airborne
        return
    end

    pitch_error =
        controller.climb_pitch -
        aircraft.pitch

    aircraft.pitch +=
        pitch_error *
        0.8 *
        dt

    aircraft.pitch =
        clamp(
            aircraft.pitch,
            0.0,
            controller.max_pitch
        )

    # Simplified climb model.

    aircraft.vertical_speed =
        aircraft.airspeed *
        sin(
            deg2rad(
                aircraft.pitch
            )
        )

    aircraft.altitude +=
        aircraft.vertical_speed *
        dt
end

# ============================================================
# SPEED TARGET
# ============================================================

function climb_speed_controller!(
    aircraft::Aircraft,
    controller::TakeoffController,
    dt::Float64
)

    target =
        controller.v2

    speed_error =
        target -
        aircraft.airspeed

    aircraft.throttle +=
        speed_error *
        controller.speed_gain *
        dt

    aircraft.throttle =
        clamp(
            aircraft.throttle,
            0.0,
            1.0
        )
end

# ============================================================
# GEAR LOGIC
# ============================================================

function gear_controller!(
    aircraft::Aircraft
)

    if aircraft.airborne &&
       aircraft.altitude > 15.0

        if aircraft.gear_down

            aircraft.gear_down =
                false

            aircraft.phase =
                GEAR_UP

            println(
                ">>> LANDING GEAR UP"
            )
        end
    end
end

# ============================================================
# FLAP / CONFIGURATION LOGIC
# ============================================================

function configuration_controller!(
    aircraft::Aircraft
)

    if aircraft.altitude > 100.0

        # Simplified configuration transition.

        aircraft.flaps =
            max(
                aircraft.flaps - 0.02,
                0.0
            )
    end
end

# ============================================================
# ENGINE FAILURE
# ============================================================

function engine_failure!(
    aircraft::Aircraft
)

    if aircraft.engines_running > 1

        aircraft.engines_running -= 1

        println(
            "!!! ENGINE FAILURE !!!"
        )
    end
end

# ============================================================
# TAKEOFF ABORT
# ============================================================

function reject_takeoff!(
    aircraft::Aircraft
)

    aircraft.phase =
        ABORT

    aircraft.throttle =
        0.0

    println(
        "!!! TAKEOFF REJECTED !!!"
    )
end

# ============================================================
# SAFETY MONITOR
# ============================================================

function monitor_takeoff!(
    aircraft::Aircraft,
    runway::Runway,
    controller::TakeoffController
)

    # Runway excursion check.

    if !aircraft.airborne &&
       aircraft.x >
       runway.length

        controller.reject_takeoff =
            true

        reject_takeoff!(
            aircraft
        )

        return
    end

    # Excessive pitch.

    if aircraft.pitch >
       controller.max_pitch

        controller.reject_takeoff =
            true

        println(
            "!!! EXCESSIVE PITCH !!!"
        )
    end

    # Excessive bank.

    if abs(
        aircraft.roll
    ) >
    controller.max_roll

        controller.reject_takeoff =
            true

        println(
            "!!! EXCESSIVE BANK !!!"
        )
    end
end

# ============================================================
# ABORT DYNAMICS
# ============================================================

function update_abort!(
    aircraft::Aircraft,
    dt::Float64
)

    aircraft.throttle =
        0.0

    braking =
        8.0

    aircraft.groundspeed -=
        braking * dt

    aircraft.groundspeed =
        max(
            aircraft.groundspeed,
            0.0
        )

    aircraft.airspeed =
        aircraft.groundspeed

    if aircraft.groundspeed <=
       0.1

        aircraft.phase =
            COMPLETE

        println(
            ">>> AIRCRAFT STOPPED"
        )
    end
end

# ============================================================
# MAIN SIMULATION
# ============================================================

function run_takeoff(
    ;
    duration=120.0,
    dt=0.05
)

    aircraft =
        create_aircraft()

    runway =
        create_runway()

    controller =
        create_controller(
            runway
        )

    println()
    println(
        "=============================================="
    )
    println(
        "       JULIA AUTOMATED TAKEOFF SIMULATOR"
    )
    println(
        "=============================================="
    )

    println(
        "Runway: ",
        runway.length,
        " m"
    )

    println(
        "V1: ",
        controller.v1
    )

    println(
        "VR: ",
        controller.vr
    )

    println(
        "V2: ",
        controller.v2
    )

    println()

    t = 0.0

    # --------------------------------------------------------
    # Line up
    # --------------------------------------------------------

    aircraft.phase =
        LINEUP

    aircraft.throttle =
        0.0

    # --------------------------------------------------------
    # Takeoff power
    # --------------------------------------------------------

    aircraft.phase =
        TAKEOFF_POWER

    aircraft.throttle =
        1.0

    while t < duration

        # ----------------------------------------------------
        # Abort state
        # ----------------------------------------------------

        if aircraft.phase ==
           ABORT

            update_abort!(
                aircraft,
                dt
            )

            t += dt

            continue
        end

        if aircraft.phase ==
           COMPLETE

            break
        end

        # ----------------------------------------------------
        # Speed / thrust
        # ----------------------------------------------------

        update_speed!(
            aircraft,
            runway,
            dt
        )

        # ----------------------------------------------------
        # Ground acceleration
        # ----------------------------------------------------

        if !aircraft.airborne

            takeoff_distance!(
                aircraft,
                dt
            )
        end

        # ----------------------------------------------------
        # V1
        # ----------------------------------------------------

        if aircraft.airspeed >=
           controller.v1 &&
           aircraft.phase ==
           TAKEOFF_ROLL

            aircraft.phase =
                V1_REACHED

            println(
                ">>> V1 REACHED: ",
                round(
                    aircraft.airspeed,
                    digits=1
                )
            )
        end

        # ----------------------------------------------------
        # Enter takeoff roll
        # ----------------------------------------------------

        if aircraft.phase ==
           TAKEOFF_POWER &&
           aircraft.airspeed > 1.0

            aircraft.phase =
                TAKEOFF_ROLL

            println(
                ">>> TAKEOFF ROLL"
            )
        end

        # ----------------------------------------------------
        # Rotation
        # ----------------------------------------------------

        rotation_controller!(
            aircraft,
            controller,
            dt
        )

        # ----------------------------------------------------
        # Lateral control
        # ----------------------------------------------------

        runway_heading_controller!(
            aircraft,
            controller,
            dt
        )

        # ----------------------------------------------------
        # Liftoff
        # ----------------------------------------------------

        check_liftoff!(
            aircraft,
            controller
        )

        # ----------------------------------------------------
        # Airborne guidance
        # ----------------------------------------------------

        if aircraft.airborne

            aircraft.phase =
                INITIAL_CLIMB

            climb_speed_controller!(
                aircraft,
                controller,
                dt
            )

            climb_controller!(
                aircraft,
                controller,
                dt
            )

            gear_controller!(
                aircraft
            )

            configuration_controller!(
                aircraft
            )
        end

        # ----------------------------------------------------
        # Safety
        # ----------------------------------------------------

        monitor_takeoff!(
            aircraft,
            runway,
            controller
        )

        # ----------------------------------------------------
        # Telemetry
        # ----------------------------------------------------

        if mod(
            round(t / dt),
            100
        ) == 0

            @printf(
                "T=%6.1f  DIST=%7.1f  ALT=%7.1f  SPD=%6.1f  PITCH=%5.1f  THR=%4.2f  PHASE=%s\n",
                t,
                aircraft.x,
                aircraft.altitude,
                aircraft.airspeed,
                aircraft.pitch,
                aircraft.throttle,
                string(aircraft.phase)
            )
        end

        # ----------------------------------------------------
        # Complete climb-out
        # ----------------------------------------------------

        if aircraft.altitude >
           1000.0

            aircraft.phase =
                COMPLETE

            println()
            println(
                ">>> TAKEOFF COMPLETE"
            )

            println(
                "Altitude: ",
                round(
                    aircraft.altitude,
                    digits=1
                ),
                " m"
            )

            println(
                "Airspeed: ",
                round(
                    aircraft.airspeed,
                    digits=1
                )
            )

            break
        end

        t += dt
    end

    println()
    println(
        "=============================================="
    )

    return aircraft
end

end # module
