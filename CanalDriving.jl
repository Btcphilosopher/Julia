module CanalDriving

using LinearAlgebra
using Statistics
using Printf

export CanalConfig,
       CanalSection,
       CanalObstacle,
       Lock,
       Mooring,
       BoatState,
       ControlCommand,
       CanalController,
       create_controller,
       permitted_speed,
       detect_obstacles,
       calculate_stopping_distance,
       steering_controller,
       speed_controller,
       update!,
       run_simulation,
       print_report,
       demo


# ============================================================
# CANAL BOAT DRIVING / NAVIGATION SIMULATOR
#
# Pure Julia
#
# Features:
#   • Canal following
#   • Speed control
#   • Heading control
#   • Waypoint navigation
#   • Bend handling
#   • Obstacle detection
#   • Passing / collision avoidance
#   • Mooring detection
#   • Bridge / tunnel approach
#   • Lock approach
#   • Current and wind compensation
#   • Stopping-distance calculation
#   • Route speed restrictions
#   • Simulation telemetry
#
# UK-oriented defaults:
#   Narrow canals commonly have a 4 mph maximum speed,
#   but local waterways can differ and river sections may
#   have different limits.
#
# Real navigation must remain under competent human control
# and comply with local navigation authority instructions.
# ============================================================


# ============================================================
# UNIT CONVERSION
# ============================================================

mph_to_ms(v) = Float64(v) * 0.44704
ms_to_mph(v) = Float64(v) / 0.44704

deg_to_rad(v) = Float64(v) * π / 180
rad_to_deg(v) = Float64(v) * 180 / π


# ============================================================
# CANAL CONFIGURATION
# ============================================================

struct CanalConfig

    boat_length_m::Float64
    boat_beam_m::Float64
    boat_draught_m::Float64

    max_speed_mph::Float64

    max_acceleration_ms2::Float64
    service_deceleration_ms2::Float64
    emergency_deceleration_ms2::Float64

    max_turn_rate_deg_s::Float64

    steering_gain::Float64
    speed_gain::Float64

    stopping_margin_m::Float64

    timestep_s::Float64
end


function CanalConfig(;
    boat_length_m=20.0,
    boat_beam_m=2.1,
    boat_draught_m=0.9,

    max_speed_mph=4.0,

    max_acceleration_ms2=0.15,
    service_deceleration_ms2=0.20,
    emergency_deceleration_ms2=0.40,

    max_turn_rate_deg_s=12.0,

    steering_gain=1.8,
    speed_gain=0.8,

    stopping_margin_m=8.0,

    timestep_s=0.1
)

    CanalConfig(
        Float64(boat_length_m),
        Float64(boat_beam_m),
        Float64(boat_draught_m),
        Float64(max_speed_mph),
        Float64(max_acceleration_ms2),
        Float64(service_deceleration_ms2),
        Float64(emergency_deceleration_ms2),
        Float64(max_turn_rate_deg_s),
        Float64(steering_gain),
        Float64(speed_gain),
        Float64(stopping_margin_m),
        Float64(timestep_s)
    )
end


# ============================================================
# CANAL SECTION
# ============================================================

struct CanalSection

    start_m::Float64
    end_m::Float64

    width_m::Float64
    depth_m::Float64

    speed_limit_mph::Float64

    current_ms::Float64

    bank_left_x::Float64
    bank_left_y::Float64

    bank_right_x::Float64
    bank_right_y::Float64

    tunnel::Bool
    bridge::Bool
    lock_approach::Bool
end


# ============================================================
# OBSTACLE
# ============================================================

struct CanalObstacle

    id::Int

    x_m::Float64
    y_m::Float64

    radius_m::Float64

    velocity_x_ms::Float64
    velocity_y_ms::Float64

    type::Symbol

    active::Bool
end


# ============================================================
# LOCK
# ============================================================

struct Lock

    id::Int

    x_m::Float64
    y_m::Float64

    chamber_length_m::Float64
    chamber_width_m::Float64

    approach_distance_m::Float64

    ready::Bool
end


# ============================================================
# MOORING
# ============================================================

struct Mooring

    id::Int

    x_m::Float64
    y_m::Float64

    length_m::Float64

    available::Bool
end


# ============================================================
# BOAT STATE
# ============================================================

mutable struct BoatState

    time_s::Float64

    x_m::Float64
    y_m::Float64

    speed_ms::Float64

    heading_rad::Float64

    acceleration_ms2::Float64
    yaw_rate_rad_s::Float64

    throttle::Float64
    brake::Float64
    steering::Float64

    target_speed_ms::Float64

    waypoint_index::Int

    mode::Symbol

    collision_warning::Bool
    emergency_stop::Bool

    distance_travelled_m::Float64
end


# ============================================================
# CONTROL COMMAND
# ============================================================

struct ControlCommand

    throttle::Float64
    brake::Float64
    steering::Float64

    target_speed_ms::Float64

    mode::Symbol
end


# ============================================================
# CONTROLLER
# ============================================================

mutable struct CanalController

    config::CanalConfig

    sections::Vector{CanalSection}

    obstacles::Vector{CanalObstacle}

    locks::Vector{Lock}

    moorings::Vector{Mooring}

    waypoints::Vector{Tuple{Float64,Float64}}

    current_speed_limit_mph::Float64

    enabled::Bool

    previous_cross_track_error::Float64
end


function create_controller(
    config::CanalConfig,
    sections::Vector{CanalSection},
    waypoints::Vector{Tuple{Float64,Float64}};
    obstacles=CanalObstacle[],
    locks=Lock[],
    moorings=Mooring[]
)

    CanalController(
        config,
        sections,
        obstacles,
        locks,
        moorings,
        waypoints,
        config.max_speed_mph,
        true,
        0.0
    )
end


# ============================================================
# ANGLE NORMALISATION
# ============================================================

function wrap_angle(
    angle::Float64
)

    return mod(
        angle + π,
        2π
    ) - π
end


# ============================================================
# DISTANCE
# ============================================================

function distance_2d(
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


# ============================================================
# CANAL SECTION LOOKUP
# ============================================================

function current_section(
    controller::CanalController,
    distance_along_route::Float64
)

    for section in controller.sections

        if distance_along_route >= section.start_m &&
           distance_along_route < section.end_m

            return section
        end
    end

    return nothing
end


# ============================================================
# PERMITTED SPEED
# ============================================================

function permitted_speed(
    controller::CanalController,
    distance_along_route::Float64
)

    section =
        current_section(
            controller,
            distance_along_route
        )

    if section === nothing

        return controller.config.max_speed_mph
    end

    return min(
        section.speed_limit_mph,
        controller.config.max_speed_mph
    )
end


# ============================================================
# WAYPOINT
# ============================================================

function current_waypoint(
    controller::CanalController,
    state::BoatState
)

    if state.waypoint_index >
       length(controller.waypoints)

        return nothing
    end

    return controller.waypoints[
        state.waypoint_index
    ]
end


# ============================================================
# WAYPOINT ADVANCEMENT
# ============================================================

function update_waypoint!(
    controller::CanalController,
    state::BoatState
)

    waypoint =
        current_waypoint(
            controller,
            state
        )

    waypoint === nothing &&
        return

    d =
        distance_2d(
            state.x_m,
            state.y_m,
            waypoint[1],
            waypoint[2]
        )

    if d < 5.0

        state.waypoint_index += 1
    end
end


# ============================================================
# PATH HEADING
# ============================================================

function desired_heading(
    controller::CanalController,
    state::BoatState
)

    waypoint =
        current_waypoint(
            controller,
            state
        )

    waypoint === nothing &&
        return state.heading_rad

    return atan(
        waypoint[2] - state.y_m,
        waypoint[1] - state.x_m
    )
end


# ============================================================
# CROSS TRACK ERROR
# ============================================================

function cross_track_error(
    controller::CanalController,
    state::BoatState
)

    waypoint =
        current_waypoint(
            controller,
            state
        )

    waypoint === nothing &&
        return 0.0

    dx =
        waypoint[1] -
        state.x_m

    dy =
        waypoint[2] -
        state.y_m

    # Signed error relative to boat heading.
    lateral =
        -sin(state.heading_rad) * dx +
        cos(state.heading_rad) * dy

    return lateral
end


# ============================================================
# STEERING CONTROLLER
# ============================================================

function steering_controller(
    controller::CanalController,
    state::BoatState
)

    target_heading =
        desired_heading(
            controller,
            state
        )

    heading_error =
        wrap_angle(
            target_heading -
            state.heading_rad
        )

    lateral_error =
        cross_track_error(
            controller,
            state
        )

    controller.previous_cross_track_error =
        lateral_error

    steering =
        controller.config.steering_gain *
        heading_error

    steering +=
        0.05 *
        lateral_error

    return clamp(
        steering,
        -1.0,
        1.0
    )
end


# ============================================================
# STOPPING DISTANCE
# ============================================================

function calculate_stopping_distance(
    speed_ms::Real,
    deceleration_ms2::Real,
    margin_m::Real
)

    v =
        max(
            Float64(speed_ms),
            0.0
        )

    a =
        max(
            Float64(deceleration_ms2),
            1e-6
        )

    return (
        v^2 /
        (2a)
    ) +
    Float64(margin_m)
end


# ============================================================
# OBSTACLE DETECTION
# ============================================================

function detect_obstacles(
    controller::CanalController,
    state::BoatState
)

    detections =
        NamedTuple[]

    heading_x =
        cos(state.heading_rad)

    heading_y =
        sin(state.heading_rad)

    for obstacle in controller.obstacles

        obstacle.active ||
            continue

        dx =
            obstacle.x_m -
            state.x_m

        dy =
            obstacle.y_m -
            state.y_m

        longitudinal =
            dx * heading_x +
            dy * heading_y

        lateral =
            -dx * heading_y +
            dy * heading_x

        distance =
            hypot(
                dx,
                dy
            )

        if longitudinal > 0 &&
           longitudinal < 100.0

            push!(
                detections,
                (
                    id=obstacle.id,
                    type=obstacle.type,
                    distance_m=distance,
                    longitudinal_m=longitudinal,
                    lateral_m=lateral,
                    obstacle=obstacle
                )
            )
        end
    end

    sort!(
        detections,
        by=x -> x.distance_m
    )

    return detections
end


# ============================================================
# COLLISION RISK
# ============================================================

function collision_risk(
    controller::CanalController,
    state::BoatState,
    detections
)

    isempty(detections) &&
        return false

    stopping =
        calculate_stopping_distance(
            state.speed_ms,
            controller.config.service_deceleration_ms2,
            controller.config.stopping_margin_m
        )

    for detection in detections

        lateral_clearance =
            abs(
                detection.lateral_m
            )

        required_clearance =
            (
                controller.config.boat_beam_m / 2
            ) +
            detection.obstacle.radius_m +
            1.0

        if detection.longitudinal_m <=
           stopping &&
           lateral_clearance <=
           required_clearance

            return true
        end
    end

    return false
end


# ============================================================
# OBSTACLE AVOIDANCE
# ============================================================

function obstacle_avoidance(
    controller::CanalController,
    state::BoatState,
    detections
)

    isempty(detections) &&
        return 0.0

    closest =
        first(detections)

    # If obstacle is left of boat,
    # steer right.
    if closest.lateral_m > 0

        return -0.7
    end

    # If obstacle is right,
    # steer left.
    return 0.7
end


# ============================================================
# LOCK APPROACH
# ============================================================

function nearest_lock(
    controller::CanalController,
    state::BoatState
)

    best =
        nothing

    best_distance =
        Inf

    for lock in controller.locks

        d =
            distance_2d(
                state.x_m,
                state.y_m,
                lock.x_m,
                lock.y_m
            )

        if d < best_distance

            best =
                lock

            best_distance =
                d
        end
    end

    return best, best_distance
end


# ============================================================
# MOORING APPROACH
# ============================================================

function nearest_mooring(
    controller::CanalController,
    state::BoatState
)

    best =
        nothing

    best_distance =
        Inf

    for mooring in controller.moorings

        !mooring.available &&
            continue

        d =
            distance_2d(
                state.x_m,
                state.y_m,
                mooring.x_m,
                mooring.y_m
            )

        if d < best_distance

            best =
                mooring

            best_distance =
                d
        end
    end

    return best, best_distance
end


# ============================================================
# SPEED CONTROLLER
# ============================================================

function speed_controller(
    controller::CanalController,
    state::BoatState
)

    permitted =
        permitted_speed(
            controller,
            state.distance_travelled_m
        )

    target =
        mph_to_ms(
            permitted
        )

    # Reduce speed around locks.
    lock,
    lock_distance =
        nearest_lock(
            controller,
            state
        )

    if lock !== nothing &&
       lock_distance < 100.0

        target =
            min(
                target,
                mph_to_ms(1.0)
            )
    end

    # Reduce speed around moorings.
    mooring,
    mooring_distance =
        nearest_mooring(
            controller,
            state
        )

    if mooring !== nothing &&
       mooring_distance < 50.0

        target =
            min(
                target,
                mph_to_ms(1.0)
            )
    end

    return target
end


# ============================================================
# MAIN CONTROL LAW
# ============================================================

function update!(
    controller::CanalController,
    state::BoatState
)

    !controller.enabled &&
        return ControlCommand(
            0.0,
            0.0,
            0.0,
            state.speed_ms,
            :MANUAL
        )

    # Update waypoint.
    update_waypoint!(
        controller,
        state
    )

    # Detect obstacles.
    detections =
        detect_obstacles(
            controller,
            state
        )

    emergency =
        collision_risk(
            controller,
            state,
            detections
        )

    state.collision_warning =
        !isempty(detections)

    # --------------------------------------------------------
    # EMERGENCY STOP
    # --------------------------------------------------------

    if emergency

        state.emergency_stop =
            true

        return ControlCommand(
            0.0,
            1.0,
            obstacle_avoidance(
                controller,
                state,
                detections
            ),
            0.0,
            :EMERGENCY_BRAKE
        )
    end

    state.emergency_stop =
        false

    # --------------------------------------------------------
    # STEERING
    # --------------------------------------------------------

    steering =
        steering_controller(
            controller,
            state
        )

    # Obstacle avoidance takes precedence.
    if !isempty(detections)

        steering =
            obstacle_avoidance(
                controller,
                state,
                detections
            )
    end

    # --------------------------------------------------------
    # SPEED
    # --------------------------------------------------------

    target =
        speed_controller(
            controller,
            state
        )

    speed_error =
        target -
        state.speed_ms

    # --------------------------------------------------------
    # BRAKING
    # --------------------------------------------------------

    if speed_error < -0.05

        brake =
            clamp(
                abs(speed_error) /
                controller.config.service_deceleration_ms2,
                0.0,
                1.0
            )

        return ControlCommand(
            0.0,
            brake,
            steering,
            target,
            :BRAKING
        )
    end

    # --------------------------------------------------------
    # ACCELERATION
    # --------------------------------------------------------

    if speed_error > 0.05

        throttle =
            clamp(
                controller.config.speed_gain *
                speed_error,
                0.0,
                1.0
            )

        return ControlCommand(
            throttle,
            0.0,
            steering,
            target,
            :CRUISING
        )
    end

    # --------------------------------------------------------
    # COAST
    # --------------------------------------------------------

    return ControlCommand(
        0.0,
        0.0,
        steering,
        target,
        :COASTING
    )
end


# ============================================================
# PHYSICS
# ============================================================

function apply_physics!(
    state::BoatState,
    config::CanalConfig,
    command::ControlCommand;
    current_ms=0.0,
    wind_ms=0.0
)

    dt =
        config.timestep_s

    # --------------------------------------------------------
    # Longitudinal acceleration
    # --------------------------------------------------------

    acceleration =
        command.throttle *
        config.max_acceleration_ms2

    acceleration -=
        command.brake *
        config.service_deceleration_ms2

    # Water resistance.
    acceleration -=
        0.015 *
        state.speed_ms

    # Prevent unrealistic negative speed.
    new_speed =
        max(
            0.0,
            state.speed_ms +
            acceleration * dt
        )

    # --------------------------------------------------------
    # Steering
    # --------------------------------------------------------

    max_yaw =
        deg_to_rad(
            config.max_turn_rate_deg_s
        )

    yaw_rate =
        command.steering *
        max_yaw

    new_heading =
        wrap_angle(
            state.heading_rad +
            yaw_rate * dt
        )

    # --------------------------------------------------------
    # Ground speed
    # --------------------------------------------------------

    ground_vx =
        new_speed *
        cos(new_heading) +
        current_ms

    ground_vy =
        new_speed *
        sin(new_heading)

    # Small wind disturbance.
    ground_vx +=
        0.02 *
        wind_ms

    # --------------------------------------------------------
    # Position
    # --------------------------------------------------------

    dx =
        ground_vx * dt

    dy =
        ground_vy * dt

    state.x_m +=
        dx

    state.y_m +=
        dy

    state.distance_travelled_m +=
        hypot(
            dx,
            dy
        )

    state.speed_ms =
        new_speed

    state.heading_rad =
        new_heading

    state.acceleration_ms2 =
        acceleration

    state.yaw_rate_rad_s =
        yaw_rate

    state.throttle =
        command.throttle

    state.brake =
        command.brake

    state.steering =
        command.steering

    state.target_speed_ms =
        command.target_speed_ms

    state.time_s +=
        dt

    return state
end


# ============================================================
# SIMULATION
# ============================================================

function run_simulation(
    controller::CanalController;
    start_x=0.0,
    start_y=0.0,
    start_heading_rad=0.0,
    max_time_s=3600.0,
    current_function=nothing,
    wind_function=nothing
)

    state =
        BoatState(
            0.0,

            Float64(start_x),
            Float64(start_y),

            0.0,

            Float64(start_heading_rad),

            0.0,
            0.0,

            0.0,
            0.0,
            0.0,

            0.0,

            1,

            :STARTING,

            false,
            false,

            0.0
        )

    history =
        NamedTuple[]

    while state.time_s <
          max_time_s

        command =
            update!(
                controller,
                state
            )

        current =
            current_function === nothing ?
            0.0 :
            current_function(
                state.x_m,
                state.y_m
            )

        wind =
            wind_function === nothing ?
            0.0 :
            wind_function(
                state.x_m,
                state.y_m
            )

        section =
            current_section(
                controller,
                state.distance_travelled_m
            )

        if section !== nothing

            current =
                section.current_ms
        end

        apply_physics!(
            state,
            controller.config,
            command;
            current_ms=current,
            wind_ms=wind
        )

        push!(
            history,
            (
                time_s=state.time_s,

                x_m=state.x_m,
                y_m=state.y_m,

                speed_mph=
                    ms_to_mph(
                        state.speed_ms
                    ),

                target_speed_mph=
                    ms_to_mph(
                        state.target_speed_ms
                    ),

                heading_deg=
                    rad_to_deg(
                        state.heading_rad
                    ),

                throttle=
                    state.throttle,

                brake=
                    state.brake,

                steering=
                    state.steering,

                mode=
                    command.mode,

                warning=
                    state.collision_warning,

                emergency=
                    state.emergency_stop,

                distance_m=
                    state.distance_travelled_m
            )
        )

        # Route complete.
        if state.waypoint_index >
           length(controller.waypoints)

            break
        end
    end

    return state, history
end


# ============================================================
# REPORT
# ============================================================

function print_report(
    state::BoatState,
    history
)

    println()
    println(
        "======================================================"
    )

    println(
        "             CANAL DRIVING SIMULATOR"
    )

    println(
        "======================================================"
    )

    @printf(
        "Simulation time:       %.1f s\n",
        state.time_s
    )

    @printf(
        "Distance travelled:    %.2f km\n",
        state.distance_travelled_m / 1000
    )

    @printf(
        "Final speed:           %.2f mph\n",
        ms_to_mph(
            state.speed_ms
        )
    )

    @printf(
        "Final heading:         %.1f degrees\n",
        rad_to_deg(
            state.heading_rad
        )
    )

    if !isempty(history)

        @printf(
            "Maximum speed:         %.2f mph\n",
            maximum(
                h.speed_mph
                for h in history
            )
        )

        @printf(
            "Mean speed:            %.2f mph\n",
            mean(
                h.speed_mph
                for h in history
            )
        )

        warnings =
            count(
                h.warning
                for h in history
            )

        @printf(
            "Warning samples:       %d\n",
            warnings
        )
    end

    println(
        "======================================================"
    )
end


# ============================================================
# EXAMPLE CANAL
# ============================================================

function create_example_canal()

    sections = [

        CanalSection(
            0.0,
            2_000.0,
            3.5,
            1.5,
            4.0,
            0.0,
            0.0, 0.0,
            0.0, 0.0,
            false,
            false,
            false
        ),

        CanalSection(
            2_000.0,
            4_000.0,
            3.2,
            1.4,
            3.0,
            0.0,
            0.0, 0.0,
            0.0, 0.0,
            false,
            true,
            false
        ),

        CanalSection(
            4_000.0,
            6_000.0,
            3.0,
            1.4,
            2.0,
            0.0,
            0.0, 0.0,
            0.0, 0.0,
            true,
            false,
            false
        ),

        CanalSection(
            6_000.0,
            8_000.0,
            3.5,
            1.5,
            4.0,
            0.0,
            0.0, 0.0,
            0.0, 0.0,
            false,
            false,
            true
        )
    ]

    return sections
end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    config =
        CanalConfig(
            boat_length_m=20.0,
            boat_beam_m=2.1,
            boat_draught_m=0.9,
            max_speed_mph=4.0
        )

    sections =
        create_example_canal()

    waypoints = [

        (0.0, 0.0),

        (500.0, 0.0),

        (1_000.0, 100.0),

        (1_500.0, 300.0),

        (2_000.0, 500.0),

        (3_000.0, 700.0),

        (4_000.0, 900.0),

        (5_000.0, 1_100.0),

        (6_000.0, 1_200.0),

        (7_000.0, 1_400.0),

        (8_000.0, 1_600.0)
    ]

    obstacles = [

        CanalObstacle(
            1,
            1_700.0,
            350.0,
            2.0,
            0.0,
            0.0,
            :MOORED_BOAT,
            true
        ),

        CanalObstacle(
            2,
            3_200.0,
            730.0,
            3.0,
            0.0,
            0.0,
            :ONCOMING_BOAT,
            true
        )
    ]

    locks = [

        Lock(
            1,
            6_000.0,
            1_200.0,
            22.0,
            3.2,
            100.0,
            true
        )
    ]

    moorings = [

        Mooring(
            1,
            7_000.0,
            1_400.0,
            30.0,
            true
        )
    ]

    controller =
        create_controller(
            config,
            sections,
            waypoints;
            obstacles=obstacles,
            locks=locks,
            moorings=moorings
        )

    println()
    println(
        "Starting canal navigation..."
    )

    state,
    history =
        run_simulation(
            controller;
            start_x=0.0,
            start_y=0.0,
            start_heading_rad=0.0,
            max_time_s=3_600.0
        )

    print_report(
        state,
        history
    )

    return state, history
end


end # module


# ============================================================
# RUN
# ============================================================

using .CanalDriving

CanalDriving.demo()
