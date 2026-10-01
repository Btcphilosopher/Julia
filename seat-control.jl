Julia: automated seat-recline controller
using LinearAlgebra

# ============================================================
# AUTOMATED VEHICLE SEAT RECLINER
# Research / simulation controller
# ============================================================

struct ReclinerConfig
    min_angle::Float64          # degrees
    max_angle::Float64          # degrees
    max_rate::Float64           # degrees/sec
    comfort_angle::Float64      # preferred driving position
    relaxed_angle::Float64      # long-distance position
    sport_angle::Float64        # more upright position

    comfort_gain::Float64
    speed_gain::Float64
    braking_gain::Float64
    curvature_gain::Float64

    dt::Float64
end


struct SeatState
    recline_angle::Float64
    recline_rate::Float64

    occupant_present::Bool
    occupant_height::Float64
    occupant_weight::Float64

    seat_belt_fastened::Bool

    vehicle_speed::Float64
    longitudinal_accel::Float64
    lateral_accel::Float64
    road_curvature::Float64
end


struct ReclineCommand
    target_angle::Float64
    motor_rate::Float64
    enable::Bool
end


# ------------------------------------------------------------
# Clamp utility
# ------------------------------------------------------------

function clamp_value(x, lo, hi)
    return max(lo, min(hi, x))
end


# ------------------------------------------------------------
# Determine base posture
# ------------------------------------------------------------

function preferred_base_angle(cfg::ReclinerConfig,
                              state::SeatState)

    # Default ergonomic driving position
    angle = cfg.comfort_angle

    # Taller occupants generally benefit from slightly
    # more rearward recline.
    height_offset =
        clamp_value((state.occupant_height - 1.75) * 8.0,
                    -4.0,
                    5.0)

    angle += height_offset

    return angle
end


# ------------------------------------------------------------
# Driving mode adjustment
# ------------------------------------------------------------

function driving_posture(cfg::ReclinerConfig,
                         state::SeatState)

    angle = preferred_base_angle(cfg, state)

    speed = state.vehicle_speed

    # High speed -> slightly more upright
    speed_factor =
        clamp_value((speed - 20.0) / 25.0, 0.0, 1.0)

    angle +=
        speed_factor *
        (cfg.sport_angle - cfg.comfort_angle)

    # Longitudinal acceleration / braking
    braking = max(0.0, -state.longitudinal_accel)

    # During stronger braking move toward safer upright posture
    angle -= min(braking * cfg.braking_gain, 5.0)

    # Cornering -> slightly more upright
    cornering =
        abs(state.lateral_accel) *
        cfg.curvature_gain

    angle -= min(cornering, 4.0)

    return clamp_value(
        angle,
        cfg.min_angle,
        cfg.max_angle
    )
end


# ------------------------------------------------------------
# Long-distance relaxation
# ------------------------------------------------------------

function relaxation_factor(speed, trip_time_minutes)

    # Only relax once the vehicle is cruising.
    cruising =
        clamp_value((speed - 15.0) / 20.0, 0.0, 1.0)

    duration =
        clamp_value(trip_time_minutes / 60.0, 0.0, 1.0)

    return cruising * duration
end


function target_recline(cfg::ReclinerConfig,
                        state::SeatState,
                        trip_time_minutes)

    driving_angle =
        driving_posture(cfg, state)

    relaxation =
        relaxation_factor(
            state.vehicle_speed,
            trip_time_minutes
        )

    target =
        driving_angle +
        relaxation *
        (cfg.relaxed_angle - driving_angle)

    return clamp_value(
        target,
        cfg.min_angle,
        cfg.max_angle
    )
end


# ------------------------------------------------------------
# Safety constraints
# ------------------------------------------------------------

function safety_gate(state::SeatState)

    # No occupant = don't move the seat automatically
    if !state.occupant_present
        return false
    end

    # Seat belt should be established before automatic
    # driving-position movement.
    if !state.seat_belt_fastened
        return false
    end

    return true
end


# ------------------------------------------------------------
# Smooth motor control
# ------------------------------------------------------------

function recliner_controller(cfg::ReclinerConfig,
                              state::SeatState,
                              trip_time_minutes)

    if !safety_gate(state)

        return ReclineCommand(
            state.recline_angle,
            0.0,
            false
        )
    end

    target =
        target_recline(
            cfg,
            state,
            trip_time_minutes
        )

    error =
        target - state.recline_angle

    # Proportional position controller
    desired_rate =
        cfg.comfort_gain * error

    # Rate limit
    desired_rate =
        clamp_value(
            desired_rate,
            -cfg.max_rate,
            cfg.max_rate
        )

    return ReclineCommand(
        target,
        desired_rate,
        true
    )
end


# ------------------------------------------------------------
# Simulated motor update
# ------------------------------------------------------------

function update_seat(cfg::ReclinerConfig,
                     state::SeatState,
                     command::ReclineCommand)

    if !command.enable
        return state
    end

    new_rate =
        command.motor_rate

    new_angle =
        state.recline_angle +
        new_rate * cfg.dt

    new_angle =
        clamp_value(
            new_angle,
            cfg.min_angle,
            cfg.max_angle
        )

    return SeatState(
        new_angle,
        new_rate,
        state.occupant_present,
        state.occupant_height,
        state.occupant_weight,
        state.seat_belt_fastened,
        state.vehicle_speed,
        state.longitudinal_accel,
        state.lateral_accel,
        state.road_curvature
    )
end
Example vehicle configuration
cfg = ReclinerConfig(
    18.0,      # minimum recline
    42.0,      # maximum recline
    3.0,       # maximum movement rate °/s

    25.0,      # normal driving posture
    34.0,      # relaxed motorway posture
    22.0,      # sport / high-speed posture

    0.8,       # comfort gain
    1.0,       # speed influence
    1.2,       # braking influence
    1.0,       # cornering influence

    0.05       # controller timestep
)

And the virtual occupant:

seat = SeatState(
    25.0,      # current recline
    0.0,

    true,      # occupant present
    1.82,      # height
    82.0,      # mass

    true,      # seat belt

    30.0,      # speed m/s
    0.0,       # longitudinal acceleration
    0.0,       # lateral acceleration
    0.001      # road curvature
)

command = recliner_controller(
    cfg,
    seat,
    45.0       # 45 minute trip
)

println(command)






seat_position = [
    slide,
    height,
    front_tilt,
    rear_height,
    recline,
    lumbar,
    cushion_length,
    bolster_left,
    bolster_right,
    headrest_height,
    headrest_angle
]

Then optimise something like:

J =
    100 × posture_error²
  + 80  × visibility_error²
  + 50  × steering_reach_error²
  + 40  × pedal_reach_error²
  + 30  × lumbar_discomfort²
  + 20  × lateral_support_error²
  + 10  × motor_energy
  + 10  × movement_speed²
