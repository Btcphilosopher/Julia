Lane-Centred Adaptive Cruise Control
using LinearAlgebra
using Printf

# ============================================================
# LANE-CENTRED ADAPTIVE CRUISE CONTROL
#
# Julia research / simulation prototype
#
# Controls:
#   1. Longitudinal speed
#   2. Following distance
#   3. Lateral lane position
#   4. Vehicle heading
#   5. Steering angle
#
# The controller is intended for simulation/development,
# not direct deployment to a road vehicle.
# ============================================================


struct ACCConfig

    # Vehicle
    wheelbase::Float64

    # Speed
    target_speed::Float64
    max_speed::Float64

    # Following distance
    desired_time_gap::Float64
    minimum_distance::Float64

    # Lateral control
    lane_width::Float64

    # Limits
    max_acceleration::Float64
    max_deceleration::Float64

    max_steering_angle::Float64
    max_steering_rate::Float64

    # Controller gains
    lateral_gain::Float64
    heading_gain::Float64

    speed_gain::Float64
    distance_gain::Float64

    dt::Float64
end


struct VehicleState

    x::Float64
    y::Float64

    speed::Float64

    heading::Float64

    steering_angle::Float64

    acceleration::Float64
end


struct LeadVehicle

    distance::Float64
    speed::Float64
end


struct LaneModel

    centre_offset::Float64
    heading_error::Float64
    curvature::Float64
end


struct ControlCommand

    acceleration::Float64
    steering_angle::Float64
end
Lane-centre controller

The first task is determining how far the car is from the lane centre.

function lane_error(
    state::VehicleState,
    lane::LaneModel
)

    lateral_error =
        state.y -
        lane.centre_offset

    return lateral_error
end

Then calculate the steering required to bring the vehicle back towards the centre.

function lane_steering(
    state::VehicleState,
    lane::LaneModel,
    cfg::ACCConfig
)

    e_y =
        lane_error(
            state,
            lane
        )

    e_heading =
        lane.heading_error -
        state.heading

    steering =
        -cfg.lateral_gain * e_y -
        cfg.heading_gain * e_heading

    return clamp(
        steering,
        -cfg.max_steering_angle,
         cfg.max_steering_angle
    )
end
Adaptive cruise logic

The car shouldn't blindly maintain 70 mph if another vehicle is doing 55 mph ahead.

function desired_following_distance(
    state::VehicleState,
    cfg::ACCConfig
)

    return max(
        cfg.minimum_distance,
        state.speed *
        cfg.desired_time_gap
    )
end

Then calculate the required acceleration:

function longitudinal_control(
    state::VehicleState,
    lead::LeadVehicle,
    cfg::ACCConfig
)

    desired_distance =
        desired_following_distance(
            state,
            cfg
        )

    distance_error =
        lead.distance -
        desired_distance

    speed_error =
        lead.speed -
        state.speed

    # If no lead vehicle is close enough,
    # target the driver's selected cruising speed.

    if lead.distance > 150.0

        acceleration =
            cfg.speed_gain *
            (cfg.target_speed -
             state.speed)

    else

        acceleration =
            cfg.distance_gain *
            distance_error +
            cfg.speed_gain *
            speed_error

    end

    return clamp(
        acceleration,
        -cfg.max_deceleration,
         cfg.max_acceleration
    )
end
Combine steering + ACC

Now we have a single controller.

function cruise_controller(
    state::VehicleState,
    lead::LeadVehicle,
    lane::LaneModel,
    cfg::ACCConfig
)

    acceleration =
        longitudinal_control(
            state,
            lead,
            cfg
        )

    steering =
        lane_steering(
            state,
            lane,
            cfg
        )

    return ControlCommand(
        acceleration,
        steering
    )
end
Vehicle model

For simulation, use a simple bicycle model.

function vehicle_dynamics(
    state::VehicleState,
    command::ControlCommand,
    cfg::ACCConfig
)

    dt = cfg.dt

    speed =
        max(state.speed, 0.0)

    β =
        atan(
            0.5 *
            tan(command.steering_angle)
        )

    x_dot =
        speed *
        cos(state.heading + β)

    y_dot =
        speed *
        sin(state.heading + β)

    heading_dot =
        speed /
        cfg.wheelbase *
        tan(command.steering_angle)

    new_x =
        state.x +
        x_dot * dt

    new_y =
        state.y +
        y_dot * dt

    new_heading =
        state.heading +
        heading_dot * dt

    new_speed =
        max(
            0.0,
            speed +
            command.acceleration * dt
        )

    return VehicleState(
        new_x,
        new_y,
        new_speed,
        new_heading,
        command.steering_angle,
        command.acceleration
    )
end
Create the virtual car
cfg = ACCConfig(

    2.85,       # wheelbase

    31.3,       # target speed = 70 mph
    40.0,       # max speed

    2.0,        # 2 second time gap
    8.0,        # minimum following distance

    3.7,        # lane width

    2.0,        # acceleration
    5.0,        # deceleration

    deg2rad(30),
    deg2rad(120),

    0.20,       # lateral gain
    1.20,       # heading gain

    0.50,       # speed gain
    0.15,       # distance gain

    0.02
)


state = VehicleState(

    0.0,
    0.0,

    31.3,

    0.0,

    0.0,

    0.0
)


lead = LeadVehicle(

    80.0,       # 80 metres ahead
    27.0        # ~60 mph
)


lane = LaneModel(

    0.0,        # lane centre
    0.0,        # heading error
    0.0         # straight road
)

Run the controller:

command =
    cruise_controller(
        state,
        lead,
        lane,
        cfg
)


@printf(
    "Acceleration: %.2f m/s²\n",
    command.acceleration
)

@printf(
    "Steering: %.2f degrees\n",
    rad2deg(
        command.steering_angle
    )
)
But I'd make your version considerably more advanced

The really interesting Aureom-style system is one predictive controller controlling both axes:

                 CAMERAS
                    │
          ┌─────────┴─────────┐
          ▼                   ▼
      LANE MODEL          LEAD VEHICLE
          │                   │
          └─────────┬─────────┘
                    ▼
              WORLD MODEL
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
   LATERAL STATE          LONGITUDINAL STATE
        │                       │
        └───────────┬───────────┘
                    ▼
              JULIA MPC
                    │
           ┌────────┴────────┐
           ▼                 ▼
       STEERING           ACCELERATION
           │                 │
           ▼                 ▼
          EPS          MOTOR / ENGINE / BRAKES

Instead of making a steering decision based only on the current lane error, MPC predicts the next several seconds.

For example:

t+0.0     current vehicle
t+0.2     predicted vehicle
t+0.4     predicted vehicle
t+0.6     predicted vehicle
t+0.8     predicted vehicle
t+1.0     predicted vehicle
t+1.5     predicted vehicle
t+2.0     predicted vehicle

It can therefore see that the road is curving and begin steering before the vehicle has reached the centre of the curve.

The optimisation function

I'd use something like:

function cruise_cost(
    lateral_error,
    heading_error,
    speed_error,
    distance_error,
    steering,
    steering_rate,
    acceleration,
    jerk
)

    return (

        100.0 * lateral_error^2 +

         60.0 * heading_error^2 +

         40.0 * speed_error^2 +

         80.0 * distance_error^2 +

         10.0 * steering^2 +

         20.0 * steering_rate^2 +

          5.0 * acceleration^2 +

         15.0 * jerk^2
    )
end

This gives you a very different philosophy from conventional cruise control:

Don't just maintain speed.

Optimise:

lane position
road curvature
heading
speed
following distance
steering smoothness
acceleration smoothness
passenger comfort

all simultaneously.

Add road curvature
struct RoadPreview

    distances::Vector{Float64}
    curvature::Vector{Float64}
    speed_limit::Vector{Float64}
end

For example:

road = RoadPreview(

    [0, 20, 40, 60, 80, 100],

    [0.000, 0.002, 0.006,
     0.012, 0.010, 0.004],

    [31.3, 31.3, 31.3,
     27.0, 27.0, 31.3]
)

The controller can then recognise:

              ROAD PREVIEW

              curve begins
                   ↓
───────────────╮
               │
               │
               ╰──────────

vehicle ───────►

     ↓

begin steering
before reaching
the curve
