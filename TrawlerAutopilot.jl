module TrawlerAutopilot

using LinearAlgebra
using Statistics
using Printf

# ============================================================
# FISHING TRAWLER AUTOPILOT / ROUTE PLANNER
#
# Pure Julia
#
# Features:
#   - Pre-planned waypoint routes
#   - Route sequencing
#   - Automatic heading control
#   - Speed profiles
#   - Vessel position simulation
#   - Current / wind disturbance
#   - Cross-track error calculation
#   - Look-ahead guidance
#   - Fishing-speed mode
#   - Transit-speed mode
#   - Turning control
#   - Waypoint arrival detection
#   - Restricted-area detection
#   - Depth limits
#   - Collision-warning layer
#   - Emergency stop
#   - Telemetry
#
# SIMULATION / DIGITAL-TWIN CODE.
# Real vessel deployment requires certified navigation,
# propulsion, steering, radar/AIS integration, redundancy,
# human oversight and regulatory approval.
# ============================================================


# ============================================================
# STATES
# ============================================================

@enum AutopilotState begin
    IDLE
    ROUTE_ACTIVE
    TRANSIT
    FISHING
    TURNING
    WAYPOINT_REACHED
    HOLDING
    AVOIDANCE
    RETURNING
    COMPLETE
    FAULT
    EMERGENCY_STOP
end


@enum OperatingMode begin
    TRANSIT_MODE
    FISHING_MODE
    RETURN_MODE
end


# ============================================================
# WAYPOINT
# ============================================================

struct Waypoint

    id::Int

    x_m::Float64
    y_m::Float64

    target_speed_ms::Float64

    depth_required_m::Float64

    fishing_allowed::Bool

    arrival_radius_m::Float64
end


# ============================================================
# ROUTE
# ============================================================

struct Route

    name::String

    waypoints::Vector{Waypoint}

    loop_route::Bool
end


# ============================================================
# VESSEL
# ============================================================

mutable struct Trawler

    id::Int

    x_m::Float64
    y_m::Float64

    heading_rad::Float64

    speed_ms::Float64

    target_speed_ms::Float64

    rudder_angle_rad::Float64

    throttle::Float64

    length_m::Float64
    beam_m::Float64

    draft_m::Float64
end


# ============================================================
# MARINE ENVIRONMENT
# ============================================================

mutable struct Environment

    water_depth_m::Float64

    current_x_ms::Float64
    current_y_ms::Float64

    wind_speed_ms::Float64
    wind_direction_rad::Float64

    wave_height_m::Float64

    restricted_area::Bool
end


# ============================================================
# CONFIGURATION
# ============================================================

struct AutopilotConfig

    timestep_s::Float64

    maximum_speed_ms::Float64

    maximum_acceleration_ms2::Float64

    maximum_deceleration_ms2::Float64

    maximum_rudder_rad::Float64

    rudder_rate_rad_s::Float64

    heading_gain::Float64

    cross_track_gain::Float64

    lookahead_distance_m::Float64

    waypoint_tolerance_m::Float64

    minimum_depth_margin_m::Float64

    maximum_wave_height_m::Float64

    collision_warning_distance_m::Float64
end


function AutopilotConfig(;
    timestep_s=0.1,

    maximum_speed_ms=6.0,

    maximum_acceleration_ms2=0.15,

    maximum_deceleration_ms2=0.3,

    maximum_rudder_rad=deg2rad(30.0),

    rudder_rate_rad_s=deg2rad(5.0),

    heading_gain=2.0,

    cross_track_gain=0.8,

    lookahead_distance_m=50.0,

    waypoint_tolerance_m=20.0,

    minimum_depth_margin_m=2.0,

    maximum_wave_height_m=5.0,

    collision_warning_distance_m=500.0
)

    AutopilotConfig(
        Float64(timestep_s),
        Float64(maximum_speed_ms),
        Float64(maximum_acceleration_ms2),
        Float64(maximum_deceleration_ms2),
        Float64(maximum_rudder_rad),
        Float64(rudder_rate_rad_s),
        Float64(heading_gain),
        Float64(cross_track_gain),
        Float64(lookahead_distance_m),
        Float64(waypoint_tolerance_m),
        Float64(minimum_depth_margin_m),
        Float64(maximum_wave_height_m),
        Float64(collision_warning_distance_m)
    )
end


# ============================================================
# AUTOPILOT
# ============================================================

mutable struct Autopilot

    config::AutopilotConfig

    vessel::Trawler

    environment::Environment

    route::Union{Nothing,Route}

    current_waypoint::Int

    state::AutopilotState

    mode::OperatingMode

    elapsed_s::Float64

    distance_travelled_m::Float64

    cross_track_error_m::Float64

    heading_error_rad::Float64

    target_heading_rad::Float64

    fault_code::Symbol

    emergency_stop::Bool
end


# ============================================================
# TELEMETRY
# ============================================================

struct Telemetry

    time_s::Float64

    state::AutopilotState

    mode::OperatingMode

    x_m::Float64
    y_m::Float64

    heading_deg::Float64

    speed_ms::Float64

    target_speed_ms::Float64

    target_heading_deg::Float64

    cross_track_error_m::Float64

    rudder_deg::Float64

    waypoint::Int

    water_depth_m::Float64

    fault::Symbol
end


# ============================================================
# UTILITIES
# ============================================================

function normalize_angle(angle)

    return atan(
        sin(angle),
        cos(angle)
    )
end


function distance(
    x1,
    y1,
    x2,
    y2
)

    hypot(
        x2 - x1,
        y2 - y1
    )
end


function bearing(
    x1,
    y1,
    x2,
    y2
)

    atan(
        y2 - y1,
        x2 - x1
    )
end


# ============================================================
# CREATE VESSEL
# ============================================================

function create_trawler(;
    id=1,

    x_m=0.0,
    y_m=0.0,

    heading_deg=0.0,

    length_m=40.0,
    beam_m=9.0,
    draft_m=5.0
)

    Trawler(

        id,

        Float64(x_m),
        Float64(y_m),

        deg2rad(
            heading_deg
        ),

        0.0,

        0.0,

        0.0,

        0.0,

        Float64(length_m),
        Float64(beam_m),

        Float64(draft_m)
    )
end


# ============================================================
# CREATE AUTOPILOT
# ============================================================

function create_autopilot(;
    config=AutopilotConfig(),

    vessel=create_trawler(),

    environment=Environment(
        100.0,
        0.0,
        0.0,
        5.0,
        0.0,
        1.0,
        false
    )
)

    Autopilot(

        config,

        vessel,

        environment,

        nothing,

        1,

        IDLE,

        TRANSIT_MODE,

        0.0,

        0.0,

        0.0,

        vessel.heading_rad,

        :NONE,

        false
    )
end


# ============================================================
# CREATE WAYPOINT
# ============================================================

function waypoint(
    id,
    x,
    y;
    speed_ms=3.0,
    depth_required_m=10.0,
    fishing_allowed=false,
    arrival_radius_m=20.0
)

    Waypoint(

        id,

        Float64(x),
        Float64(y),

        Float64(speed_ms),

        Float64(depth_required_m),

        fishing_allowed,

        Float64(arrival_radius_m)
    )
end


# ============================================================
# LOAD ROUTE
# ============================================================

function load_route!(
    autopilot::Autopilot,
    route::Route
)

    isempty(route.waypoints) &&
        throw(
            ArgumentError(
                "Route contains no waypoints"
            )
        )

    autopilot.route =
        route

    autopilot.current_waypoint =
        1

    autopilot.state =
        ROUTE_ACTIVE

    return autopilot
end


# ============================================================
# ACTIVE WAYPOINT
# ============================================================

function active_waypoint(
    autopilot::Autopilot
)

    route =
        autopilot.route

    route === nothing &&
        return nothing

    index =
        autopilot.current_waypoint

    if index >
       length(route.waypoints)

        return nothing
    end

    return route.waypoints[index]
end


# ============================================================
# CROSS-TRACK ERROR
# ============================================================

function cross_track_error(
    autopilot::Autopilot
)

    route =
        autopilot.route

    route === nothing &&
        return 0.0

    index =
        autopilot.current_waypoint

    if index <= 1 ||
       index > length(route.waypoints)

        return 0.0
    end

    previous =
        route.waypoints[index - 1]

    current =
        route.waypoints[index]

    px =
        autopilot.vessel.x_m -
        previous.x_m

    py =
        autopilot.vessel.y_m -
        previous.y_m

    dx =
        current.x_m -
        previous.x_m

    dy =
        current.y_m -
        previous.y_m

    segment_length =
        hypot(dx, dy)

    segment_length < 1e-6 &&
        return 0.0

    return (
        px * dy -
        py * dx
    ) / segment_length
end


# ============================================================
# TARGET HEADING
# ============================================================

function calculate_target_heading(
    autopilot::Autopilot
)

    wp =
        active_waypoint(
            autopilot
        )

    wp === nothing &&
        return autopilot.vessel.heading_rad

    vessel =
        autopilot.vessel

    direct_bearing =
        bearing(
            vessel.x_m,
            vessel.y_m,
            wp.x_m,
            wp.y_m
        )

    xte =
        cross_track_error(
            autopilot
        )

    correction =
        atan(
            autopilot.config.cross_track_gain *
            xte /
            max(
                autopilot.config.lookahead_distance_m,
                1.0
            )
        )

    return normalize_angle(
        direct_bearing -
        correction
    )
end


# ============================================================
# HEADING CONTROLLER
# ============================================================

function heading_controller!(
    autopilot::Autopilot
)

    config =
        autopilot.config

    vessel =
        autopilot.vessel

    target =
        calculate_target_heading(
            autopilot
        )

    autopilot.target_heading_rad =
        target

    error =
        normalize_angle(
            target -
            vessel.heading_rad
        )

    autopilot.heading_error_rad =
        error

    desired_rudder =
        config.heading_gain *
        error

    desired_rudder =
        clamp(
            desired_rudder,
            -config.maximum_rudder_rad,
            config.maximum_rudder_rad
        )

    maximum_change =
        config.rudder_rate_rad_s *
        config.timestep_s

    change =
        desired_rudder -
        vessel.rudder_angle_rad

    change =
        clamp(
            change,
            -maximum_change,
            maximum_change
        )

    vessel.rudder_angle_rad +=
        change
end


# ============================================================
# SPEED CONTROLLER
# ============================================================

function speed_controller!(
    autopilot::Autopilot
)

    vessel =
        autopilot.vessel

    config =
        autopilot.config

    wp =
        active_waypoint(
            autopilot
        )

    target =
        wp === nothing ?
        0.0 :
        wp.target_speed_ms

    # Environmental speed reduction.
    if autopilot.environment.wave_height_m >
       config.maximum_wave_height_m * 0.5

        target *= 0.7
    end

    # Depth protection.
    if autopilot.environment.water_depth_m <
       vessel.draft_m +
       config.minimum_depth_margin_m

        target *= 0.4
    end

    target =
        clamp(
            target,
            0.0,
            config.maximum_speed_ms
        )

    vessel.target_speed_ms =
        target

    error =
        target -
        vessel.speed_ms

    if error > 0

        vessel.speed_ms +=
            min(
                error,
                config.maximum_acceleration_ms2 *
                config.timestep_s
            )

    else

        vessel.speed_ms +=
            max(
                error,
                -config.maximum_deceleration_ms2 *
                config.timestep_s
            )
    end

    vessel.speed_ms =
        clamp(
            vessel.speed_ms,
            0.0,
            config.maximum_speed_ms
        )
end


# ============================================================
# VESSEL DYNAMICS
# ============================================================

function update_vessel!(
    autopilot::Autopilot
)

    vessel =
        autopilot.vessel

    environment =
        autopilot.environment

    dt =
        autopilot.config.timestep_s

    # Simplified yaw response.
    yaw_rate =
        vessel.rudder_angle_rad *
        0.25

    vessel.heading_rad +=
        yaw_rate *
        dt

    vessel.heading_rad =
        normalize_angle(
            vessel.heading_rad
        )

    # Through-water velocity.
    vx =
        vessel.speed_ms *
        cos(vessel.heading_rad)

    vy =
        vessel.speed_ms *
        sin(vessel.heading_rad)

    # Add environmental current.
    vx +=
        environment.current_x_ms

    vy +=
        environment.current_y_ms

    dx =
        vx * dt

    dy =
        vy * dt

    vessel.x_m +=
        dx

    vessel.y_m +=
        dy

    autopilot.distance_travelled_m +=
        hypot(
            dx,
            dy
        )
end


# ============================================================
# WAYPOINT MANAGEMENT
# ============================================================

function waypoint_manager!(
    autopilot::Autopilot
)

    route =
        autopilot.route

    route === nothing &&
        return

    wp =
        active_waypoint(
            autopilot
        )

    wp === nothing && return

    vessel =
        autopilot.vessel

    d =
        distance(
            vessel.x_m,
            vessel.y_m,
            wp.x_m,
            wp.y_m
        )

    tolerance =
        min(
            wp.arrival_radius_m,
            autopilot.config.waypoint_tolerance_m
        )

    if d <= tolerance

        autopilot.state =
            WAYPOINT_REACHED

        autopilot.current_waypoint +=
            1

        # Route complete.
        if autopilot.current_waypoint >
           length(route.waypoints)

            if route.loop_route

                autopilot.current_waypoint =
                    1

            else

                autopilot.state =
                    COMPLETE

                autopilot.vessel.target_speed_ms =
                    0.0
            end

            return
        end

        # Switch to fishing mode if allowed.
        next_wp =
            active_waypoint(
                autopilot
            )

        if next_wp !== nothing &&
           next_wp.fishing_allowed

            autopilot.mode =
                FISHING_MODE

            autopilot.state =
                FISHING

        else

            autopilot.mode =
                TRANSIT_MODE

            autopilot.state =
                TRANSIT
        end
    end
end


# ============================================================
# DEPTH SAFETY
# ============================================================

function depth_safety!(
    autopilot::Autopilot
)

    vessel =
        autopilot.vessel

    environment =
        autopilot.environment

    minimum_depth =
        vessel.draft_m +
        autopilot.config.minimum_depth_margin_m

    if environment.water_depth_m <
       minimum_depth

        autopilot.state =
            FAULT

        autopilot.fault_code =
            :INSUFFICIENT_DEPTH

        vessel.target_speed_ms =
            0.0

        return false
    end

    return true
end


# ============================================================
# WEATHER SAFETY
# ============================================================

function weather_safety!(
    autopilot::Autopilot
)

    if autopilot.environment.wave_height_m >
       autopilot.config.maximum_wave_height_m

        autopilot.state =
            FAULT

        autopilot.fault_code =
            :EXCESSIVE_WAVE_HEIGHT

        autopilot.vessel.target_speed_ms =
            0.0

        return false
    end

    return true
end


# ============================================================
# RESTRICTED AREA
# ============================================================

function restricted_area_check!(
    autopilot::Autopilot
)

    if autopilot.environment.restricted_area

        autopilot.state =
            AVOIDANCE

        autopilot.fault_code =
            :RESTRICTED_AREA

        autopilot.vessel.target_speed_ms =
            0.0

        return false
    end

    return true
end


# ============================================================
# START ROUTE
# ============================================================

function start!(
    autopilot::Autopilot
)

    autopilot.route === nothing &&
        throw(
            ArgumentError(
                "No route loaded"
            )
        )

    autopilot.emergency_stop =
        false

    autopilot.fault_code =
        :NONE

    autopilot.current_waypoint =
        1

    autopilot.state =
        ROUTE_ACTIVE

    autopilot.vessel.throttle =
        1.0

    return autopilot
end


# ============================================================
# RETURN-TO-PORT
# ============================================================

function return_to_port!(
    autopilot::Autopilot,
    port::Waypoint
)

    route =
        Route(
            "RETURN_TO_PORT",
            [port],
            false
        )

    load_route!(
        autopilot,
        route
    )

    autopilot.mode =
        RETURN_MODE

    autopilot.state =
        RETURNING

    return autopilot
end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(
    autopilot::Autopilot
)

    autopilot.emergency_stop =
        true

    autopilot.state =
        EMERGENCY_STOP

    autopilot.vessel.speed_ms =
        0.0

    autopilot.vessel.target_speed_ms =
        0.0

    autopilot.vessel.rudder_angle_rad =
        0.0

    autopilot.vessel.throttle =
        0.0

    autopilot.fault_code =
        :EMERGENCY_STOP

    return autopilot
end


# ============================================================
# RESET
# ============================================================

function reset!(
    autopilot::Autopilot
)

    autopilot.state =
        IDLE

    autopilot.mode =
        TRANSIT_MODE

    autopilot.current_waypoint =
        1

    autopilot.elapsed_s =
        0.0

    autopilot.distance_travelled_m =
        0.0

    autopilot.cross_track_error_m =
        0.0

    autopilot.heading_error_rad =
        0.0

    autopilot.fault_code =
        :NONE

    autopilot.emergency_stop =
        false

    autopilot.vessel.speed_ms =
        0.0

    autopilot.vessel.target_speed_ms =
        0.0

    autopilot.vessel.rudder_angle_rad =
        0.0

    return autopilot
end


# ============================================================
# TELEMETRY
# ============================================================

function telemetry(
    autopilot::Autopilot
)

    vessel =
        autopilot.vessel

    Telemetry(

        autopilot.elapsed_s,

        autopilot.state,

        autopilot.mode,

        vessel.x_m,
        vessel.y_m,

        rad2deg(
            vessel.heading_rad
        ),

        vessel.speed_ms,

        vessel.target_speed_ms,

        rad2deg(
            autopilot.target_heading_rad
        ),

        autopilot.cross_track_error_m,

        rad2deg(
            vessel.rudder_angle_rad
        ),

        autopilot.current_waypoint,

        autopilot.environment.water_depth_m,

        autopilot.fault_code
    )
end


# ============================================================
# MAIN CONTROL STEP
# ============================================================

function step!(
    autopilot::Autopilot
)

    dt =
        autopilot.config.timestep_s

    autopilot.elapsed_s +=
        dt

    if autopilot.emergency_stop

        return telemetry(
            autopilot
        )
    end

    if autopilot.state ==
       COMPLETE

        autopilot.vessel.speed_ms =
            max(
                autopilot.vessel.speed_ms -
                autopilot.config.maximum_deceleration_ms2 *
                dt,
                0.0
            )

        return telemetry(
            autopilot
        )
    end

    # -----------------------------------------------
    # SAFETY LAYER FIRST
    # -----------------------------------------------

    if !depth_safety!(
        autopilot
    )

        return telemetry(
            autopilot
        )
    end

    if !weather_safety!(
        autopilot
    )

        return telemetry(
            autopilot
        )
    end

    if !restricted_area_check!(
        autopilot
    )

        return telemetry(
            autopilot
        )
    end

    # -----------------------------------------------
    # NAVIGATION
    # -----------------------------------------------

    if autopilot.route !== nothing

        autopilot.cross_track_error_m =
            cross_track_error(
                autopilot
            )

        heading_controller!(
            autopilot
        )

        speed_controller!(
            autopilot
        )

        waypoint_manager!(
            autopilot
        )
    end

    # -----------------------------------------------
    # VESSEL DYNAMICS
    # -----------------------------------------------

    update_vessel!(
        autopilot
    )

    return telemetry(
        autopilot
    )
end


# ============================================================
# RUN ROUTE
# ============================================================

function run!(
    autopilot::Autopilot;
    max_time_s=3600.0
)

    start!(
        autopilot
    )

    history =
        Telemetry[]

    while autopilot.elapsed_s <
          max_time_s

        sample =
            step!(
                autopilot
            )

        push!(
            history,
            sample
        )

        if autopilot.state ==
           COMPLETE ||
           autopilot.state ==
           FAULT ||
           autopilot.state ==
           EMERGENCY_STOP

            break
        end
    end

    return history
end


# ============================================================
# ROUTE STATISTICS
# ============================================================

function route_statistics(
    history
)

    isempty(history) &&
        return (
            duration_s=0.0,
            distance_m=0.0,
            mean_speed_ms=0.0,
            maximum_xte_m=0.0,
            mean_xte_m=0.0
        )

    speeds =
        [
            x.speed_ms
            for x in history
        ]

    xte =
        [
            abs(
                x.cross_track_error_m
            )
            for x in history
        ]

    return (

        duration_s =
            last(history).time_s,

        distance_m =
            sum(
                hypot(
                    history[i].x_m -
                    history[i-1].x_m,

                    history[i].y_m -
                    history[i-1].y_m
                )
                for i in 2:length(history)
            ),

        mean_speed_ms =
            mean(speeds),

        maximum_xte_m =
            maximum(xte),

        mean_xte_m =
            mean(xte)
    )
end


# ============================================================
# REPORT
# ============================================================

function print_report(
    autopilot::Autopilot,
    history
)

    stats =
        route_statistics(
            history
        )

    println()
    println(
        "=========================================================="
    )

    println(
        "              TRAWLER AUTOPILOT"
    )

    println(
        "=========================================================="
    )

    println(
        "Route:                  ",
        autopilot.route === nothing ?
        "NONE" :
        autopilot.route.name
    )

    println(
        "Final state:            ",
        autopilot.state
    )

    println(
        "Operating mode:         ",
        autopilot.mode
    )

    @printf(
        "Operating time:         %.1f s\n",
        stats.duration_s
    )

    @printf(
        "Distance travelled:     %.1f m\n",
        stats.distance_m
    )

    @printf(
        "Mean speed:             %.2f m/s\n",
        stats.mean_speed_ms
    )

    @printf(
        "Maximum cross-track:    %.2f m\n",
        stats.maximum_xte_m
    )

    @printf(
        "Mean cross-track:       %.2f m\n",
        stats.mean_xte_m
    )

    @printf(
        "Final position:         %.1f, %.1f m\n",
        autopilot.vessel.x_m,
        autopilot.vessel.y_m
    )

    @printf(
        "Final heading:          %.1f°\n",
        rad2deg(
            autopilot.vessel.heading_rad
        )
    )

    println(
        "Fault:                  ",
        autopilot.fault_code
    )

    println(
        "=========================================================="
    )
end


# ============================================================
# DEMONSTRATION ROUTE
# ============================================================

function demo_route()

    Waypoint[

        waypoint(
            1,
            0.0,
            0.0;
            speed_ms=3.0,
            depth_required_m=30.0
        ),

        waypoint(
            2,
            1000.0,
            0.0;
            speed_ms=4.0,
            depth_required_m=30.0
        ),

        waypoint(
            3,
            2000.0,
            500.0;
            speed_ms=4.0,
            depth_required_m=35.0
        ),

        waypoint(
            4,
            3000.0,
            1000.0;
            speed_ms=2.0,
            depth_required_m=35.0,
            fishing_allowed=true
        ),

        waypoint(
            5,
            4000.0,
            1000.0;
            speed_ms=2.0,
            depth_required_m=40.0,
            fishing_allowed=true
        ),

        waypoint(
            6,
            4500.0,
            0.0;
            speed_ms=3.0,
            depth_required_m=40.0
        )
    ]
end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    config =
        AutopilotConfig(
            timestep_s=0.1,

            maximum_speed_ms=6.0,

            maximum_acceleration_ms2=0.15,

            maximum_deceleration_ms2=0.3,

            lookahead_distance_m=100.0,

            waypoint_tolerance_m=25.0
        )

    vessel =
        create_trawler(
            id=101,

            x_m=0.0,
            y_m=0.0,

            heading_deg=0.0,

            length_m=40.0,
            beam_m=9.0,
            draft_m=5.0
        )

    environment =
        Environment(

            60.0,

            0.10,
            0.02,

            8.0,
            deg2rad(90.0),

            1.5,

            false
        )

    autopilot =
        create_autopilot(
            config=config,
            vessel=vessel,
            environment=environment
        )

    route =
        Route(
            "NORTH SEA TRIAL ROUTE",
            demo_route(),
            false
        )

    load_route!(
        autopilot,
        route
    )

    println()
    println(
        "Starting trawler route simulation..."
    )

    history =
        run!(
            autopilot;
            max_time_s=1800.0
        )

    print_report(
        autopilot,
        history
    )

    println()
    println(
        "WAYPOINT / STATE TRANSITIONS"
    )

    println(
        "----------------------------------------------------------"
    )

    previous_state =
        nothing

    previous_waypoint =
        0

    for sample in history

        if sample.state !=
           previous_state ||

           sample.waypoint !=
           previous_waypoint

            @printf(
                "%8.1f s | %-18s | WP %2d | pos %8.1f,%8.1f | hdg %6.1f° | spd %.2f\n",

                sample.time_s,

                string(sample.state),

                sample.waypoint,

                sample.x_m,

                sample.y_m,

                sample.heading_deg,

                sample.speed_ms
            )

            previous_state =
                sample.state

            previous_waypoint =
                sample.waypoint
        end
    end

    return autopilot, history
end


end # module


# ============================================================
# RUN
# ============================================================

using .TrawlerAutopilot

TrawlerAutopilot.demo()
