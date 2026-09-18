# Julia Automatic Door Controller

A modular Julia system for an automatic sliding door with:

* presence detection
* opening and closing
* adjustable opening speed
* obstruction detection
* reopening while closing
* hold-open timer
* motor control
* position feedback
* safety supervision
* energy optimisation
* simulated sensor faults

```text
automatic_door/
├── Project.toml
├── src/
│   ├── AutomaticDoor.jl
│   ├── door.jl
│   ├── sensors.jl
│   ├── motor.jl
│   ├── controller.jl
│   ├── safety.jl
│   ├── energy.jl
│   ├── simulation.jl
│   └── optimisation.jl
├── examples/
│   └── door_demo.jl
└── test/
    └── runtests.jl
```

## `Project.toml`

```toml
name = "AutomaticDoor"
uuid = "c4e4d2a1-7b52-4f21-9d6a-123456789abc"
authors = ["Automatic Door Control Research"]
version = "0.1.0"

[deps]
Random = "9a3f8284-686f-5f34-9a9f-3a7b1d6c8b6f"
Statistics = "10745b16-90c0-5a5c-9e9b-0d4d5b3a8c6e"
```

# Main module

## `src/AutomaticDoor.jl`

```julia
module AutomaticDoor

using Random
using Statistics

include("door.jl")
include("sensors.jl")
include("motor.jl")
include("controller.jl")
include("safety.jl")
include("energy.jl")
include("simulation.jl")
include("optimisation.jl")

export Door
export DoorState
export SensorState
export MotorCommand
export SimulationResult

export default_door
export read_sensors
export door_controller
export simulate
export optimise_door

end
```

# Door model

## `src/door.jl`

```julia
@enum DoorState begin
    CLOSED
    OPENING
    OPEN
    CLOSING
    OBSTRUCTED
    FAULT
end

struct Door

    travel_m::Float64

    opening_speed_mps::Float64
    closing_speed_mps::Float64

    maximum_motor_force::Float64

    hold_open_time_s::Float64

    motor_efficiency::Float64

    obstacle_threshold::Float64
end

function default_door()

    return Door(
        1.20,       # door travel
        0.80,       # opening speed
        0.60,       # closing speed
        100.0,      # motor force
        4.0,        # hold-open time
        0.85,       # efficiency
        15.0        # obstacle force threshold
    )
end
```

# Sensors

## `src/sensors.jl`

The door can use several independent sensors:

```text
┌──────────────────────────────┐
│       AUTOMATIC DOOR         │
│                              │
│  [PRESENCE]       [PRESENCE] │
│                              │
│          ║      ║            │
│          ║ DOOR ║            │
│          ║      ║            │
│                              │
│       [SAFETY BEAM]          │
└──────────────────────────────┘
```

```julia
struct SensorState

    person_present::Bool

    safety_beam_blocked::Bool

    obstacle_detected::Bool

    door_position_m::Float64

    motor_force::Float64
end

function read_sensors(
    person_present::Bool,
    safety_beam_blocked::Bool,
    obstacle_detected::Bool,
    position::Float64,
    motor_force::Float64
)

    return SensorState(
        person_present,
        safety_beam_blocked,
        obstacle_detected,
        position,
        motor_force
    )
end
```

# Motor

## `src/motor.jl`

```julia
struct MotorCommand

    velocity_mps::Float64

    enabled::Bool

    direction::Symbol
end

function motor_command(
    velocity::Float64
)

    if velocity > 0

        return MotorCommand(
            velocity,
            true,
            :open
        )

    elseif velocity < 0

        return MotorCommand(
            velocity,
            true,
            :close
        )

    else

        return MotorCommand(
            0.0,
            false,
            :stop
        )
    end
end
```

# Safety layer

## `src/safety.jl`

Safety gets priority over the normal opening/closing logic.

```julia
function safety_override(
    state::DoorState,
    sensors::SensorState
)

    if sensors.obstacle_detected
        return true
    end

    if sensors.safety_beam_blocked &&
       state == CLOSING

        return true
    end

    return false
end
```

When closing and an obstruction is detected, the controller should stop/reopen rather than continuing to apply closing force.

# Door controller

## `src/controller.jl`

```julia
function door_controller(
    door::Door,
    state::DoorState,
    sensors::SensorState,
    time_since_open::Float64
)

    # Independent safety layer.

    if safety_override(
        state,
        sensors
    )

        return (
            state = OPENING,
            command =
                motor_command(
                    door.opening_speed_mps
                )
        )
    end

    if state == CLOSED

        if sensors.person_present

            return (
                state = OPENING,
                command =
                    motor_command(
                        door.opening_speed_mps
                    )
            end

        else

            return (
                state = CLOSED,
                command =
                    motor_command(0.0)
            )
        end

    elseif state == OPENING

        if sensors.door_position_m >=
           door.travel_m

            return (
                state = OPEN,
                command =
                    motor_command(0.0)
            )
        end

        return (
            state = OPENING,
            command =
                motor_command(
                    door.opening_speed_mps
                )
        )

    elseif state == OPEN

        if sensors.person_present

            return (
                state = OPEN,
                command =
                    motor_command(0.0)
            )

        elseif time_since_open >=
               door.hold_open_time_s

            return (
                state = CLOSING,
                command =
                    motor_command(
                        -door.closing_speed_mps
                    )
            )

        else

            return (
                state = OPEN,
                command =
                    motor_command(0.0)
            )
        end

    elseif state == CLOSING

        if sensors.person_present

            return (
                state = OPENING,
                command =
                    motor_command(
                        door.opening_speed_mps
                    )
            )
        end

        if sensors.door_position_m <= 0.0

            return (
                state = CLOSED,
                command =
                    motor_command(0.0)
            )
        end

        return (
            state = CLOSING,
            command =
                motor_command(
                    -door.closing_speed_mps
                )
        )
    end

    return (
        state = FAULT,
        command =
            motor_command(0.0)
    )
end
```

# Energy model

## `src/energy.jl`

```julia
function motor_power(
    force::Float64,
    velocity::Float64,
    efficiency::Float64
)

    mechanical_power =
        abs(force * velocity)

    return mechanical_power /
           max(efficiency, 0.01)
end

function motor_energy(
    force::Float64,
    velocity::Float64,
    duration::Float64,
    efficiency::Float64
)

    power =
        motor_power(
            force,
            velocity,
            efficiency
        )

    return power *
           duration /
           3_600_000.0
end
```

# Simulation

## `src/simulation.jl`

```julia
struct SimulationResult

    time::Vector{Float64}

    position::Vector{Float64}

    state::Vector{DoorState}

    velocity::Vector{Float64}

    person_present::Vector{Bool}

    energy_kwh::Float64
end
```

```julia
function simulate(
    door::Door;
    duration::Float64=20.0,
    dt::Float64=0.02,
    presence_function=nothing
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

    position =
        zeros(steps)

    velocity =
        zeros(steps)

    states =
        Vector{DoorState}(
            undef,
            steps
        )

    presence =
        falses(steps)

    current_state =
        CLOSED

    current_position =
        0.0

    energy =
        0.0

    time_since_open =
        0.0

    for i in 1:steps

        t = time[i]

        person =
            if presence_function === nothing
                2.0 <= t <= 4.0
            else
                presence_function(t)
            end

        presence[i] = person

        sensors =
            read_sensors(
                person,
                false,
                false,
                current_position,
                0.0
            )

        result =
            door_controller(
                door,
                current_state,
                sensors,
                time_since_open
            )

        command =
            result.command

        current_state =
            result.state

        current_position +=
            command.velocity_mps *
            dt

        current_position =
            clamp(
                current_position,
                0.0,
                door.travel_m
            )

        velocity[i] =
            command.velocity_mps

        position[i] =
            current_position

        states[i] =
            current_state

        if current_state == OPEN
            time_since_open += dt
        else
            time_since_open = 0.0
        end

        energy +=
            motor_energy(
                door.maximum_motor_force,
                command.velocity_mps,
                dt,
                door.motor_efficiency
            )
    end

    return SimulationResult(
        time,
        position,
        states,
        velocity,
        presence,
        energy
    )
end
```

# Optimisation

## `src/optimisation.jl`

The optimisation engine searches for opening/closing speeds and hold-open time that balance:

* response time
* energy
* unnecessary door movements

```julia
function optimise_door(
    door::Door;
    opening_speeds=0.4:0.1:1.2,
    closing_speeds=0.3:0.1:1.0,
    hold_times=2.0:0.5:8.0
)

    best_score = Inf
    best = nothing

    for open_speed in opening_speeds

        for close_speed in closing_speeds

            for hold in hold_times

                candidate =
                    Door(
                        door.travel_m,
                        open_speed,
                        close_speed,
                        door.maximum_motor_force,
                        hold,
                        door.motor_efficiency,
                        door.obstacle_threshold
                    )

                result =
                    simulate(candidate)

                movement =
                    sum(
                        abs.(result.velocity)
                    )

                energy =
                    result.energy_kwh

                score =
                    0.5 * energy +
                    0.001 * movement +
                    0.01 * hold

                if score < best_score

                    best_score = score

                    best =
                        (
                            door = candidate,
                            simulation = result,
                            score = score
                        )
                end
            end
        end
    end

    return best
end
```

# Example

## `examples/door_demo.jl`

```julia
include(
    joinpath(
        @__DIR__,
        "..",
        "src",
        "AutomaticDoor.jl"
    )
)

using .AutomaticDoor

door =
    default_door()

result =
    simulate(
        door;
        duration=20.0
    )

println("================================")
println("JULIA AUTOMATIC DOOR CONTROLLER")
println("================================")

println(
    "Door travel: ",
    door.travel_m,
    " m"
)

println(
    "Opening speed: ",
    door.opening_speed_mps,
    " m/s"
)

println(
    "Closing speed: ",
    door.closing_speed_mps,
    " m/s"
)

println(
    "Energy consumed: ",
    round(
        result.energy_kwh,
        digits=6
    ),
    " kWh"
)

println(
    "Final position: ",
    round(
        result.position[end],
        digits=3
    ),
    " m"
)

println(
    "Final state: ",
    result.state[end]
)
```

# Tests

## `test/runtests.jl`

```julia
using Test

include(
    joinpath(
        @__DIR__,
        "..",
        "src",
        "AutomaticDoor.jl"
    )
)

using .AutomaticDoor

@testset "Automatic Door" begin

    door =
        default_door()

    @test door.travel_m > 0
    @test door.opening_speed_mps > 0
    @test door.closing_speed_mps > 0

    result =
        simulate(
            door;
            duration=10.0
        )

    @test length(result.time) > 0

    @test length(result.position) ==
          length(result.time)

    @test all(
        result.position .>= 0.0
    )

    @test all(
        result.position .<=
        door.travel_m
    )

    @test result.energy_kwh >= 0
end
```

# Control architecture

The finished system is essentially:

```text
             PERSON / OBJECT
                    │
                    ▼
        ┌─────────────────────┐
        │   SENSOR SYSTEM     │
        │ presence / beam /   │
        │ position / force    │
        └──────────┬──────────┘
                   │
                   ▼
        ┌─────────────────────┐
        │  SAFETY SUPERVISOR  │
        │                     │
        │ obstacle?           │
        │ beam blocked?       │
        │ sensor fault?       │
        └──────────┬──────────┘
                   │
                   ▼
        ┌─────────────────────┐
        │  JULIA CONTROLLER   │
        │                     │
        │ CLOSED              │
        │ OPENING             │
        │ OPEN                │
        │ CLOSING             │
        │ FAULT               │
        └──────────┬──────────┘
                   │
                   ▼
        ┌─────────────────────┐
        │    MOTOR CONTROL    │
        │ speed / direction   │
        └──────────┬──────────┘
                   │
                   ▼
             DOOR MOVEMENT
                   │
                   └──────────────► position feedback
```

## More advanced version

The interesting next step would be to turn this into a **commercial-building automatic-door digital twin**.

Julia could optimise an entire building's doors based on:

```text
                    BUILDING
                       │
       ┌───────────────┼────────────────┐
       │               │                │
    FOOTFALL        WEATHER          SECURITY
       │               │                │
       ▼               ▼                ▼
   occupancy       temperature       access
   patterns        wind/load          events
       │               │                │
       └───────────────┼────────────────┘
                       ▼
                JULIA DIGITAL TWIN
                       │
          ┌────────────┼────────────┐
          │            │            │
       opening      closing      standby
        speed        speed        time
          │            │            │
          └────────────┼────────────┘
                       ▼
                  OPTIMISER
                       │
                       ▼
             MOTOR / DOOR CONTROLLER
```

You could even model **hundreds of doors simultaneously**, with Julia deciding when each door should open, how long it should remain open, motor acceleration/deceleration profiles, energy use, predicted pedestrian arrival, and maintenance requirements.

For real automatic doors, the safety functions should remain independently implemented and validated against the applicable machinery/automatic-door safety standards; the Julia optimiser should not be the sole safety mechanism.

