# Julia Straight-Line Autonomous Driving Controller

A modular Julia controller for keeping a car precisely centred and aligned on a straight road.

```text
straight_line_autonomy/
├── Project.toml
├── src/
│   ├── StraightLineDrive.jl
│   ├── vehicle.jl
│   ├── road.jl
│   ├── sensors.jl
│   ├── state_estimation.jl
│   ├── lateral_dynamics.jl
│   ├── controller.jl
│   ├── steering.jl
│   ├── safety.jl
│   ├── simulation.jl
│   └── optimisation.jl
├── examples/
│   └── straight_line.jl
└── test/
    └── runtests.jl
```

## `Project.toml`

```toml
name = "StraightLineDrive"
uuid = "b8a8a1a0-7a20-4e19-9f41-123456789abc"
authors = ["Autonomous Driving Research"]
version = "0.1.0"

[deps]
LinearAlgebra = "37e2e46d-f89d-539b-b4ee-838fcccc9c6e"
Statistics = "10745b16-90c0-5a5c-9e9b-0d4d5b3a8c6e"
Random = "9a3f8284-686f-5f34-9a9f-3a7b1d6c8b6f"
```

---

# Main module

## `src/StraightLineDrive.jl`

```julia
module StraightLineDrive

using LinearAlgebra
using Statistics
using Random

include("vehicle.jl")
include("road.jl")
include("sensors.jl")
include("state_estimation.jl")
include("lateral_dynamics.jl")
include("controller.jl")
include("steering.jl")
include("safety.jl")
include("simulation.jl")
include("optimisation.jl")

export Vehicle
export StraightRoad
export VehicleState
export SensorState
export ControlCommand
export SimulationResult

export default_vehicle
export straight_road
export estimate_state
export control
export simulate
export optimise_controller

end
```

---

# Vehicle

## `src/vehicle.jl`

```julia
struct Vehicle

    mass_kg::Float64

    wheelbase_m::Float64

    front_track_m::Float64
    rear_track_m::Float64

    maximum_steering_rad::Float64

    steering_rate_rad_s::Float64
end

function default_vehicle()

    return Vehicle(
        1650.0,
        2.85,
        1.60,
        1.58,
        deg2rad(35.0),
        deg2rad(120.0)
    )
end
```

---

# Straight road

## `src/road.jl`

The ideal road centreline is:

```text
                    road direction
                         ↑
                         │
                         │
                         │
             ────────────┼────────────
             lane        │
                         │
                         │
                         │
```

```julia
struct StraightRoad

    lane_width_m::Float64

    centre_x_m::Float64

    heading_rad::Float64

    speed_limit_mps::Float64
end

function straight_road()

    return StraightRoad(
        3.6,
        0.0,
        0.0,
        27.78
    )
end
```

---

# Vehicle state

## `src/state_estimation.jl`

```julia
struct VehicleState

    x_m::Float64
    y_m::Float64

    heading_rad::Float64

    speed_mps::Float64

    yaw_rate_rad_s::Float64
end
```

For a perfectly straight road:

```text
y = 0

heading = 0
```

are the ideal values.

---

# Sensors

## `src/sensors.jl`

A real autonomous system could obtain this information from camera/lane detection, inertial sensors, wheel-speed sensors and other validated vehicle-state sources.

```julia
struct SensorState

    lateral_error_m::Float64
    heading_error_rad::Float64

    speed_mps::Float64

    yaw_rate_rad_s::Float64

    lane_confidence::Float64
end

function read_sensors(
    state::VehicleState,
    road::StraightRoad
)

    lateral_error =
        state.y_m -
        road.centre_x_m

    heading_error =
        state.heading_rad -
        road.heading_rad

    return SensorState(
        lateral_error,
        heading_error,
        state.speed_mps,
        state.yaw_rate_rad_s,
        1.0
    )
end
```

---

# Lateral vehicle dynamics

## `src/lateral_dynamics.jl`

A simple bicycle model is sufficient for the initial simulation.

```julia
function yaw_rate(
    speed::Float64,
    steering::Float64,
    wheelbase::Float64
)

    if abs(speed) < 0.01
        return 0.0
    end

    return speed /
           wheelbase *
           tan(steering)
end

function update_lateral_state(
    state::VehicleState,
    steering::Float64,
    vehicle::Vehicle,
    dt::Float64
)

    β = 0.0

    new_yaw_rate =
        yaw_rate(
            state.speed_mps,
            steering,
            vehicle.wheelbase_m
        )

    new_heading =
        state.heading_rad +
        new_yaw_rate * dt

    new_x =
        state.x_m +
        state.speed_mps *
        cos(new_heading) *
        dt

    new_y =
        state.y_m +
        state.speed_mps *
        sin(new_heading) *
        dt

    return VehicleState(
        new_x,
        new_y,
        new_heading,
        state.speed_mps,
        new_yaw_rate
    )
end
```

---

# Control command

## `src/controller.jl`

```julia
struct ControlCommand

    steering_rad::Float64

    throttle::Float64

    brake::Float64
end
```

---

# Straight-line controller

The basic controller combines:

```text
lateral error
      +
heading error
      +
yaw rate
      ↓
steering command
```

```julia
function control(
    vehicle::Vehicle,
    sensors::SensorState
)

    lateral_gain = 0.80
    heading_gain = 2.40
    yaw_gain = 0.25

    steering =
        -lateral_gain *
        sensors.lateral_error_m

    steering +=
        -heading_gain *
        sensors.heading_error_rad

    steering +=
        -yaw_gain *
        sensors.yaw_rate_rad_s

    steering =
        clamp(
            steering,
            -vehicle.maximum_steering_rad,
            vehicle.maximum_steering_rad
        )

    return ControlCommand(
        steering,
        0.0,
        0.0
    )
end
```

---

# Steering-rate limiter

## `src/steering.jl`

A production controller should not instantly command arbitrary steering changes.

```julia
function limit_steering_rate(
    requested::Float64,
    previous::Float64,
    maximum_rate::Float64,
    dt::Float64
)

    maximum_change =
        maximum_rate * dt

    difference =
        requested -
        previous

    difference =
        clamp(
            difference,
            -maximum_change,
            maximum_change
        )

    return previous +
           difference
end
```

---

# Safety supervisor

## `src/safety.jl`

The safety layer overrides the normal controller when confidence in the lane estimate becomes inadequate.

```julia
function safety_check(
    sensors::SensorState,
    vehicle::Vehicle
)

    if sensors.lane_confidence < 0.50

        return false
    end

    if abs(
        sensors.lateral_error_m
    ) > 1.5

        return false
    end

    if abs(
        sensors.heading_error_rad
    ) > deg2rad(15.0)

        return false
    end

    return true
end
```

A safer implementation would have the supervisor transition to a separately validated fallback behaviour rather than simply continuing to steer.

---

# Simulation

## `src/simulation.jl`

```julia
struct SimulationResult

    time::Vector{Float64}

    x::Vector{Float64}

    y::Vector{Float64}

    heading::Vector{Float64}

    steering::Vector{Float64}

    lateral_error::Vector{Float64}

    yaw_rate::Vector{Float64}
end
```

```julia
function simulate(
    vehicle::Vehicle,
    road::StraightRoad;
    duration::Float64=30.0,
    dt::Float64=0.02,
    initial_y::Float64=0.25,
    initial_heading::Float64=deg2rad(2.0),
    speed_mps::Float64=27.78
)

    steps =
        Int(
            round(
                duration / dt
            )
        )

    time =
        collect(
            0.0:dt:
            duration - dt
        )

    x =
        zeros(steps)

    y =
        zeros(steps)

    heading =
        zeros(steps)

    steering =
        zeros(steps)

    lateral_error =
        zeros(steps)

    yaw_rate =
        zeros(steps)

    state =
        VehicleState(
            0.0,
            initial_y,
            initial_heading,
            speed_mps,
            0.0
        )

    previous_steering = 0.0

    for i in 1:steps

        sensors =
            read_sensors(
                state,
                road
            )

        safe =
            safety_check(
                sensors,
                vehicle
            )

        if safe

            command =
                control(
                    vehicle,
                    sensors
                )

            requested =
                command.steering_rad

            applied =
                limit_steering_rate(
                    requested,
                    previous_steering,
                    vehicle.steering_rate_rad_s,
                    dt
                )

        else

            applied = 0.0
        end

        state =
            update_lateral_state(
                state,
                applied,
                vehicle,
                dt
            )

        x[i] =
            state.x_m

        y[i] =
            state.y_m

        heading[i] =
            state.heading_rad

        steering[i] =
            applied

        lateral_error[i] =
            sensors.lateral_error_m

        yaw_rate[i] =
            state.yaw_rate_rad_s

        previous_steering =
            applied
    end

    return SimulationResult(
        time,
        x,
        y,
        heading,
        steering,
        lateral_error,
        yaw_rate
    )
end
```

---

# Controller optimisation

## `src/optimisation.jl`

The controller gains can be optimised rather than manually selected.

```julia
function optimise_controller(
    vehicle::Vehicle,
    road::StraightRoad;
    lateral_gains=0.4:0.2:1.6,
    heading_gains=1.0:0.2:4.0,
    yaw_gains=0.05:0.05:0.5
)

    best_score = Inf
    best_parameters = nothing

    for kg in lateral_gains

        for kh in heading_gains

            for ky in yaw_gains

                score = 0.0

                y = 0.25
                heading =
                    deg2rad(2.0)

                yaw_rate = 0.0

                speed = 27.78

                for _ in 1:1000

                    steering =
                        -kg * y -
                        kh * heading -
                        ky * yaw_rate

                    steering =
                        clamp(
                            steering,
                            -vehicle.maximum_steering_rad,
                            vehicle.maximum_steering_rad
                        )

                    yaw_rate =
                        yaw_rate(
                            speed,
                            steering,
                            vehicle.wheelbase_m
                        )

                    heading +=
                        yaw_rate * 0.02

                    y +=
                        speed *
                        sin(heading) *
                        0.02

                    score +=
                        y^2 +
                        0.25 *
                        heading^2 +
                        0.05 *
                        steering^2
                end

                if score < best_score

                    best_score = score

                    best_parameters =
                        (
                            lateral_gain = kg,
                            heading_gain = kh,
                            yaw_gain = ky
                        )
                end
            end
        end
    end

    return (
        score = best_score,
        parameters = best_parameters
    )
end
```

---

# Example

## `examples/straight_line.jl`

```julia
include(
    joinpath(
        @__DIR__,
        "..",
        "src",
        "StraightLineDrive.jl"
    )
)

using .StraightLineDrive

vehicle =
    default_vehicle()

road =
    straight_road()

result =
    simulate(
        vehicle,
        road;
        duration=30.0,
        dt=0.02,
        initial_y=0.25,
        initial_heading=deg2rad(2.0),
        speed_mps=27.78
    )

println("======================================")
println("JULIA STRAIGHT-LINE AUTONOMOUS DRIVE")
println("======================================")

println(
    "Initial lateral error: 0.25 m"
)

println(
    "Final lateral error: ",
    round(
        result.lateral_error[end],
        digits=5
    ),
    " m"
)

println(
    "Maximum lateral error: ",
    round(
        maximum(
            abs.(result.lateral_error)
        ),
        digits=5
    ),
    " m"
)

println(
    "Final heading: ",
    round(
        rad2deg(
            result.heading[end]
        ),
        digits=5
    ),
    " degrees"
)

println(
    "Maximum steering: ",
    round(
        rad2deg(
            maximum(
                abs.(result.steering)
            )
        ),
        digits=3
    ),
    " degrees"
)
```

---

# Tests

## `test/runtests.jl`

```julia
using Test

include(
    joinpath(
        @__DIR__,
        "..",
        "src",
        "StraightLineDrive.jl"
    )
)

using .StraightLineDrive

@testset "Straight Line Controller" begin

    vehicle =
        default_vehicle()

    road =
        straight_road()

    result =
        simulate(
            vehicle,
            road;
            duration=10.0
        )

    @test length(result.time) > 0

    @test length(result.y) ==
          length(result.time)

    @test all(
        isfinite,
        result.y
    )

    @test all(
        isfinite,
        result.steering
    )

    @test maximum(
        abs.(result.steering)
    ) <=
        vehicle.maximum_steering_rad +
        1e-6
end
```

---

# What this is actually controlling

The central objective is:

```text
                 STRAIGHT ROAD
─────────────────────────────────────────────
                      │
                      │ centreline
                      │
                      │
             ┌────────┴────────┐
             │       CAR       │
             └─────────────────┘
                      ↑
                 lateral error
```

The controller continuously tries to drive:

```text
lateral error → 0
heading error → 0
yaw rate      → 0
```

while respecting:

```text
maximum steering angle
maximum steering rate
lane confidence
vehicle dynamics
```

The next engineering step would be replacing the simple proportional controller with a **full lateral MPC**. That would allow Julia to predict, for example, the next 2–5 seconds of vehicle position and select a steering trajectory that minimises:

```text
J =
    lateral_position_error²
  + heading_error²
  + steering_angle²
  + steering_rate²
  + yaw_rate²
  + predicted_lane_departure_penalty
```

That is the more realistic architecture for a straight motorway autonomous-driving research system: **perception → state estimation → predictive lateral controller → safety supervisor → steering actuator**, with the controller continuously re-solving the trajectory as new sensor measurements arrive.

