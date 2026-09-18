# Julia Automotive Cruise Control Optimisation System

A modular Julia implementation for adaptive cruise control, speed optimisation, gradient compensation, traffic response, braking and energy efficiency.

## Architecture

```text
cruise_control/
├── Project.toml
├── src/
│   ├── CruiseControl.jl
│   ├── vehicle.jl
│   ├── road.jl
│   ├── sensors.jl
│   ├── traffic.jl
│   ├── dynamics.jl
│   ├── controller.jl
│   ├── mpc.jl
│   ├── braking.jl
│   ├── energy.jl
│   ├── simulation.jl
│   └── optimisation.jl
├── examples/
│   └── adaptive_cruise.jl
└── test/
    └── runtests.jl
```

---

## `Project.toml`

```toml
name = "CruiseControl"
uuid = "3e7f4d20-4f5a-4d73-8b4c-912c12345678"
authors = ["Automotive Control Research"]
version = "0.1.0"

[deps]
Random = "9a3f8284-686f-5f34-9a9f-3a7b1d6c8b6f"
LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c6e"
Statistics = "10745b16-90c0-5a5c-9e9b-0d4d5b3a8c6e"
```

---

# Main module

## `src/CruiseControl.jl`

```julia
module CruiseControl

using Random
using LinearAlgebra
using Statistics

include("vehicle.jl")
include("road.jl")
include("sensors.jl")
include("traffic.jl")
include("dynamics.jl")
include("controller.jl")
include("mpc.jl")
include("braking.jl")
include("energy.jl")
include("simulation.jl")
include("optimisation.jl")

export Vehicle
export RoadSegment
export LeadVehicle
export SensorState
export CruiseState
export SimulationResult

export vehicle_acceleration
export cruise_controller
export simulate
export optimise_cruise

end
```

---

# Vehicle model

## `src/vehicle.jl`

```julia
struct Vehicle

    mass_kg::Float64
    frontal_area_m2::Float64
    drag_coefficient::Float64
    rolling_resistance::Float64

    max_acceleration::Float64
    max_braking::Float64

    drivetrain_efficiency::Float64
end
```

A representative vehicle:

```julia
function default_vehicle()

    return Vehicle(
        1650.0,   # mass
        2.25,     # frontal area
        0.29,     # Cd
        0.012,    # rolling resistance
        3.0,      # maximum acceleration
        8.0,      # maximum braking
        0.90      # drivetrain efficiency
    )
end
```

---

# Road model

## `src/road.jl`

```julia
struct RoadSegment

    gradient::Float64
    speed_limit::Float64
    curvature::Float64
end

function default_road()

    return RoadSegment[
        RoadSegment(0.00, 31.29, 0.0),
        RoadSegment(0.01, 31.29, 0.0),
        RoadSegment(0.03, 27.78, 0.01),
        RoadSegment(-0.02, 31.29, 0.0),
        RoadSegment(0.00, 33.33, 0.0)
    ]
end
```

Speeds here are in **m/s**, so:

```text
27.78 m/s ≈ 100 km/h
31.29 m/s ≈ 112.6 km/h
33.33 m/s ≈ 120 km/h
```

---

# Traffic

## `src/traffic.jl`

```julia
struct LeadVehicle

    distance_m::Float64
    speed_mps::Float64
    acceleration_mps2::Float64
end

function lead_vehicle()

    return LeadVehicle(
        80.0,
        25.0,
        0.0
    )
end
```

---

# Sensors

## `src/sensors.jl`

```julia
struct SensorState

    vehicle_speed::Float64
    lead_distance::Float64
    lead_speed::Float64

    road_gradient::Float64
    speed_limit::Float64
end

function read_sensors(
    speed,
    lead::LeadVehicle,
    road::RoadSegment
)

    return SensorState(
        speed,
        lead.distance_m,
        lead.speed_mps,
        road.gradient,
        road.speed_limit
    )
end
```

---

# Vehicle dynamics

## `src/dynamics.jl`

The longitudinal model is:

```text
F = ma

Ftractive
    -
Faero
    -
Frolling
    -
Fgrade
=
ma
```

```julia
function aerodynamic_force(
    vehicle::Vehicle,
    speed::Float64
)

    rho = 1.225

    return 0.5 *
           rho *
           vehicle.drag_coefficient *
           vehicle.frontal_area_m2 *
           speed^2
end

function rolling_force(
    vehicle::Vehicle
)

    g = 9.81

    return vehicle.mass_kg *
           g *
           vehicle.rolling_resistance
end

function gradient_force(
    vehicle::Vehicle,
    gradient::Float64
)

    g = 9.81

    return vehicle.mass_kg *
           g *
           gradient
end

function vehicle_acceleration(
    vehicle::Vehicle,
    speed::Float64,
    command_acceleration::Float64,
    gradient::Float64
)

    command =
        clamp(
            command_acceleration,
            -vehicle.max_braking,
            vehicle.max_acceleration
        )

    drag =
        aerodynamic_force(
            vehicle,
            speed
        )

    rolling =
        rolling_force(vehicle)

    grade =
        gradient_force(
            vehicle,
            gradient
        )

    resisting =
        drag +
        rolling +
        grade

    return command -
           resisting /
           vehicle.mass_kg
end
```

---

# Cruise state

## `src/controller.jl`

```julia
struct CruiseState

    target_speed::Float64
    desired_gap::Float64

    acceleration_command::Float64
    braking_command::Float64
end
```

---

# Adaptive cruise controller

A simple controller can combine:

1. speed error
2. distance error
3. relative speed

```julia
function cruise_controller(
    vehicle::Vehicle,
    sensors::SensorState,
    target_speed::Float64
)

    speed_error =
        target_speed -
        sensors.vehicle_speed

    desired_gap =
        2.0 *
        sensors.vehicle_speed +
        8.0

    gap_error =
        sensors.lead_distance -
        desired_gap

    relative_speed =
        sensors.lead_speed -
        sensors.vehicle_speed

    acceleration =
        0.45 * speed_error +
        0.015 * gap_error +
        0.30 * relative_speed

    acceleration =
        clamp(
            acceleration,
            -vehicle.max_braking,
            vehicle.max_acceleration
        )

    if acceleration >= 0

        return CruiseState(
            target_speed,
            desired_gap,
            acceleration,
            0.0
        )

    else

        return CruiseState(
            target_speed,
            desired_gap,
            0.0,
            -acceleration
        )
    end
end
```

---

# Safety braking

## `src/braking.jl`

The controller should have a separate emergency-braking calculation.

```julia
function stopping_distance(
    speed::Float64,
    braking::Float64
)

    if braking <= 0
        return Inf
    end

    return speed^2 /
           (2.0 * braking)
end

function emergency_required(
    speed::Float64,
    distance::Float64,
    max_braking::Float64
)

    required =
        stopping_distance(
            speed,
            max_braking
        )

    return distance <= required
end
```

This provides an independent safety check rather than relying entirely on the optimisation controller.

---

# Energy model

## `src/energy.jl`

```julia
function propulsion_power(
    vehicle::Vehicle,
    speed::Float64,
    acceleration::Float64
)

    force =
        vehicle.mass_kg *
        acceleration

    return max(
        0.0,
        force * speed /
        vehicle.drivetrain_efficiency
    )
end

function energy_for_step(
    vehicle::Vehicle,
    speed::Float64,
    acceleration::Float64,
    dt::Float64
)

    power =
        propulsion_power(
            vehicle,
            speed,
            acceleration
        )

    return power *
           dt /
           3_600_000.0
end
```

The output is kWh.

---

# MPC controller

## `src/mpc.jl`

The model-predictive controller evaluates several possible accelerations over a short horizon.

```julia
function predict_speed(
    speed,
    acceleration,
    dt
)

    return max(
        0.0,
        speed +
        acceleration * dt
    )
end

function mpc_cost(
    vehicle::Vehicle,
    speed::Float64,
    target_speed::Float64,
    acceleration::Float64,
    lead_distance::Float64,
    lead_speed::Float64,
    dt::Float64
)

    predicted =
        predict_speed(
            speed,
            acceleration,
            dt
        )

    speed_error =
        predicted -
        target_speed

    desired_gap =
        2.0 * predicted +
        8.0

    predicted_gap =
        lead_distance +
        (lead_speed - predicted) *
        dt

    gap_error =
        max(
            0.0,
            desired_gap -
            predicted_gap
        )

    energy_penalty =
        acceleration^2

    return (
        2.0 * speed_error^2 +
        10.0 * gap_error^2 +
        0.5 * energy_penalty
    )
end

function mpc_control(
    vehicle::Vehicle,
    sensors::SensorState,
    target_speed::Float64
)

    candidates =
        range(
            -vehicle.max_braking,
            vehicle.max_acceleration;
            length=31
        )

    best_command = 0.0
    best_cost = Inf

    dt = 0.2

    for acceleration in candidates

        cost =
            mpc_cost(
                vehicle,
                sensors.vehicle_speed,
                target_speed,
                acceleration,
                sensors.lead_distance,
                sensors.lead_speed,
                dt
            )

        if cost < best_cost

            best_cost = cost
            best_command = acceleration
        end
    end

    return best_command
end
```

---

# Simulation

## `src/simulation.jl`

```julia
struct SimulationResult

    time::Vector{Float64}
    speed::Vector{Float64}
    distance::Vector{Float64}
    acceleration::Vector{Float64}

    target_speed::Vector{Float64}
    lead_distance::Vector{Float64}

    energy_kwh::Float64
end
```

```julia
function simulate(
    vehicle::Vehicle;
    duration::Float64=120.0,
    dt::Float64=0.1,
    initial_speed::Float64=25.0,
    target_speed::Float64=27.78
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

    speed =
        zeros(steps)

    distance =
        zeros(steps)

    acceleration =
        zeros(steps)

    targets =
        fill(
            target_speed,
            steps
        )

    lead_distances =
        zeros(steps)

    vehicle_state =
        initial_speed

    lead =
        lead_vehicle()

    road =
        default_road()[1]

    total_energy = 0.0

    for i in 1:steps

        sensors =
            read_sensors(
                vehicle_state,
                lead,
                road
            )

        command =
            mpc_control(
                vehicle,
                sensors,
                min(
                    target_speed,
                    road.speed_limit
                )
            )

        if emergency_required(
            vehicle_state,
            lead.distance_m,
            vehicle.max_braking
        )

            command =
                -vehicle.max_braking
        end

        actual_acceleration =
            vehicle_acceleration(
                vehicle,
                vehicle_state,
                command,
                road.gradient
            )

        vehicle_state =
            predict_speed(
                vehicle_state,
                actual_acceleration,
                dt
            )

        lead.distance_m +=
            (
                lead.speed_mps -
                vehicle_state
            ) * dt

        speed[i] =
            vehicle_state

        distance[i] =
            i == 1 ?
            vehicle_state * dt :
            distance[i-1] +
            vehicle_state * dt

        acceleration[i] =
            actual_acceleration

        lead_distances[i] =
            lead.distance_m

        total_energy +=
            energy_for_step(
                vehicle,
                vehicle_state,
                actual_acceleration,
                dt
            )
    end

    return SimulationResult(
        time,
        speed,
        distance,
        acceleration,
        targets,
        lead_distances,
        total_energy
    )
end
```

---

# Cruise optimisation

## `src/optimisation.jl`

This searches for the target cruise speed that balances journey time against energy consumption.

```julia
function optimise_cruise(
    vehicle::Vehicle;
    speeds=20.0:1.0:35.0
)

    best_speed = first(speeds)
    best_score = Inf
    best_result = nothing

    for speed in speeds

        result =
            simulate(
                vehicle;
                target_speed=speed
            )

        travel_time =
            result.time[end]

        energy =
            result.energy_kwh

        score =
            travel_time +
            20.0 * energy

        if score < best_score

            best_score = score
            best_speed = speed
            best_result = result
        end
    end

    return (
        speed = best_speed,
        score = best_score,
        simulation = best_result
    )
end
```

---

# Example application

## `examples/adaptive_cruise.jl`

```julia
include(
    joinpath(
        @__DIR__,
        "..",
        "src",
        "CruiseControl.jl"
    )
)

using .CruiseControl

vehicle =
    default_vehicle()

result =
    simulate(
        vehicle;
        duration=120.0,
        dt=0.1,
        initial_speed=22.0,
        target_speed=27.78
    )

println("================================")
println("JULIA ADAPTIVE CRUISE CONTROL")
println("================================")

println(
    "Final speed: ",
    round(
        result.speed[end] * 3.6,
        digits=2
    ),
    " km/h"
)

println(
    "Distance travelled: ",
    round(
        result.distance[end],
        digits=1
    ),
    " m"
)

println(
    "Energy consumed: ",
    round(
        result.energy_kwh,
        digits=4
    ),
    " kWh"
)

println(
    "Peak acceleration: ",
    round(
        maximum(result.acceleration),
        digits=2
    ),
    " m/s²"
)

println(
    "Peak braking: ",
    round(
        minimum(result.acceleration),
        digits=2
    ),
    " m/s²"
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
        "CruiseControl.jl"
    )
)

using .CruiseControl

@testset "Cruise Control" begin

    vehicle =
        default_vehicle()

    @test vehicle.mass_kg > 0
    @test vehicle.max_acceleration > 0
    @test vehicle.max_braking > 0

    result =
        simulate(
            vehicle;
            duration=10.0
        )

    @test length(result.time) > 0
    @test length(result.speed) ==
          length(result.time)

    @test all(
        result.speed .>= 0
    )

    @test result.energy_kwh >= 0
end
```

---

# Production architecture

For a serious automotive implementation, I'd expand it into five layers:

```text
┌───────────────────────────────────────────┐
│              VEHICLE SENSORS              │
│ radar │ camera │ wheel speed │ IMU │ GPS │
└───────────────────┬───────────────────────┘
                    │
                    ▼
┌───────────────────────────────────────────┐
│             STATE ESTIMATION              │
│ speed │ acceleration │ road │ traffic     │
└───────────────────┬───────────────────────┘
                    │
                    ▼
┌───────────────────────────────────────────┐
│              JULIA MPC ENGINE              │
│                                           │
│ speed trajectory                          │
│ following distance                        │
│ acceleration                              │
│ braking                                   │
│ energy                                    │
│ gradient                                  │
└───────────────────┬───────────────────────┘
                    │
                    ▼
┌───────────────────────────────────────────┐
│              SAFETY SUPERVISOR            │
│ collision envelope │ hard speed limits    │
│ emergency braking  │ actuator limits      │
└───────────────────┬───────────────────────┘
                    │
                    ▼
┌───────────────────────────────────────────┐
│                 VEHICLE                   │
│ throttle │ brake │ transmission │ motor   │
└───────────────────────────────────────────┘
```

The really powerful version would use **JuMP/Ipopt or another validated optimisation stack** for the MPC problem rather than the simple grid search above. It could optimise a complete future trajectory:

```text
time ──────────────────────────────────────►

speed
  │            _________
  │       ____/         \____
  │  ____/                    \____
  │_/                              \___
  └──────────────────────────────────────

       acceleration trajectory

       ┌───────┐
       │       │
───────┘       └───────┐
                       │
                       └───────────────

       braking trajectory

                         ┌──────────┐
─────────────────────────┘          └────

       road gradient

__________/^^^^^^^^^^^^^\______________/^^
```

It could then minimise something like:

```text
J =
    w₁ × speed_error²
  + w₂ × following_distance_error²
  + w₃ × acceleration²
  + w₄ × jerk²
  + w₅ × energy_consumption
  + w₆ × braking_penalty
```

That gives you a **Julia automotive control laboratory** where the same underlying model can be used for conventional petrol/diesel cars, hybrids and EVs, with the optimisation objective changed from fuel consumption to battery energy, regenerative braking, comfort, journey time, or a combination of those objectives.

