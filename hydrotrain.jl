# 1. Project

## `Project.toml`

```toml
name = "HydrogenHSR"
uuid = "4d9e5a71-3c4b-4d8e-a101-9c27a5001001"
authors = ["Hydrogen HSR Research"]
version = "0.1.0"

[deps]
LinearAlgebra = "37e2e46d-f6a4-5c5d-b7c1-0a9d7f1a7e2d"

[compat]
julia = "1.10"
```

# 2. Main module

## `src/HydrogenHSR.jl`

```julia
module HydrogenHSR

include("train.jl")
include("route.jl")
include("aerodynamics.jl")
include("traction.jl")
include("motor.jl")
include("fuelcell.jl")
include("battery.jl")
include("hydrogen.jl")
include("regenerative_braking.jl")
include("thermal.jl")
include("timetable.jl")
include("simulation.jl")
include("optimisation.jl")

export
    Train,
    RoutePoint,
    Motor,
    FuelCell,
    Battery,
    HSRProfile,
    simulate,
    optimise_hsr,
    hydrogen_consumption

end
```

# 3. Train

## `src/train.jl`

```julia
struct Train

    mass_kg::Float64

    frontal_area_m2::Float64

    drag_coefficient::Float64

    rolling_coefficient::Float64

    wheel_radius_m::Float64

    max_speed_ms::Float64

    max_tractive_force_n::Float64

    max_braking_force_n::Float64

end
```

Example 400 km/h-class train:

```julia
const HSR_TRAIN =
    Train(
        420_000.0,
        12.0,
        0.16,
        0.0012,
        0.46,
        400.0 / 3.6,
        350_000.0,
        400_000.0
    )
```

# 4. Route

## `src/route.jl`

```julia
struct RoutePoint

    distance_m::Float64

    gradient::Float64

    speed_limit_ms::Float64

end


function gradient_force(
    mass,
    gradient
)

    g = 9.81

    return mass * g * gradient

end
```

A route could then be represented as:

```julia
route = [

    RoutePoint(
        0.0,
        0.000,
        300.0 / 3.6
    ),

    RoutePoint(
        20_000.0,
        0.005,
        300.0 / 3.6
    ),

    RoutePoint(
        50_000.0,
        -0.003,
        350.0 / 3.6
    ),

    RoutePoint(
        100_000.0,
        0.000,
        400.0 / 3.6
    )

]
```

# 5. Aerodynamics

## `src/aerodynamics.jl`

```julia
const AIR_DENSITY = 1.225


function aerodynamic_force(
    train::Train,
    speed_ms
)

    return 0.5 *
        AIR_DENSITY *
        train.drag_coefficient *
        train.frontal_area_m2 *
        speed_ms^2

end


function rolling_force(
    train::Train
)

    return (
        train.mass_kg *
        9.81 *
        train.rolling_coefficient
    )

end


function total_resistance(
    train::Train,
    speed_ms,
    gradient
)

    return (
        aerodynamic_force(
            train,
            speed_ms
        )
        +
        rolling_force(train)
        +
        gradient_force(
            train.mass_kg,
            gradient
        )
    )

end
```

# 6. Traction

## `src/traction.jl`

```julia
function traction_power(
    force,
    speed
)

    return force * speed

end


function acceleration_from_force(
    train::Train,
    tractive_force,
    resistance
)

    return (
        tractive_force -
        resistance
    ) / train.mass_kg

end


function required_force(
    train::Train,
    speed,
    acceleration,
    gradient
)

    resistance =
        total_resistance(
            train,
            speed,
            gradient
        )

    return (
        train.mass_kg *
        acceleration +
        resistance
    )

end
```

# 7. Electric motor

## `src/motor.jl`

```julia
struct Motor

    rated_power_kw::Float64

    peak_power_kw::Float64

    efficiency::Float64

    max_rpm::Float64

    torque_limit_nm::Float64

end


const HSR_MOTOR =
    Motor(
        1000.0,
        1400.0,
        0.96,
        6000.0,
        5000.0
    )


function motor_electrical_power(
    mechanical_power_kw,
    motor::Motor
)

    if mechanical_power_kw <= 0
        return 0.0
    end

    return mechanical_power_kw /
        motor.efficiency

end
```

For a multi-motor train:

```julia
function total_motor_power(
    mechanical_power_kw,
    motor::Motor,
    motor_count
)

    per_motor =
        mechanical_power_kw /
        motor_count

    per_motor =
        min(
            per_motor,
            motor.peak_power_kw
        )

    return (
        per_motor *
        motor_count
    )

end
```

# 8. Fuel cell

## `src/fuelcell.jl`

```julia
struct FuelCell

    rated_power_kw::Float64

    peak_power_kw::Float64

    efficiency::Float64

    minimum_load_fraction::Float64

end


const HSR_FUEL_CELL =
    FuelCell(
        5000.0,
        6000.0,
        0.55,
        0.10
    )


function fuel_cell_power(
    requested_kw,
    fc::FuelCell
)

    return clamp(
        requested_kw,
        0.0,
        fc.peak_power_kw
    )

end


function fuel_cell_hydrogen_rate(
    electrical_kw,
    fc::FuelCell
)

    if electrical_kw <= 0
        return 0.0
    end

    hydrogen_energy_kw =
        electrical_kw /
        fc.efficiency

    return hydrogen_energy_kw

end
```

# 9. Hydrogen

## `src/hydrogen.jl`

Use hydrogen's lower heating value as the energy basis.

```julia
const H2_LHV_KWH_KG = 33.33


function hydrogen_consumption(
    electrical_energy_kwh,
    fuel_cell_efficiency
)

    chemical_energy =
        electrical_energy_kwh /
        fuel_cell_efficiency

    return (
        chemical_energy /
        H2_LHV_KWH_KG
    )

end


function hydrogen_flow_rate(
    electrical_kw,
    fuel_cell_efficiency
)

    return hydrogen_consumption(
        electrical_kw,
        fuel_cell_efficiency
    )

end
```

# 10. Battery

The battery acts as the buffer between fuel-cell output and rapid traction-power changes.

## `src/battery.jl`

```julia
struct Battery

    capacity_kwh::Float64

    max_charge_kw::Float64

    max_discharge_kw::Float64

    charge_efficiency::Float64

    discharge_efficiency::Float64

    initial_soc::Float64

end


const HSR_BATTERY =
    Battery(
        1500.0,
        3000.0,
        3000.0,
        0.95,
        0.95,
        0.70
    )


function battery_energy(
    battery::Battery
)

    return (
        battery.capacity_kwh *
        battery.initial_soc
    )

end


function charge_battery(
    energy_kwh,
    battery::Battery
)

    return (
        energy_kwh *
        battery.charge_efficiency
    )

end


function discharge_battery(
    energy_kwh,
    battery::Battery
)

    return (
        energy_kwh /
        battery.discharge_efficiency
    )

end
```

# 11. Regenerative braking

## `src/regenerative_braking.jl`

```julia
function kinetic_energy_kwh(
    mass_kg,
    speed_ms
)

    joules =
        0.5 *
        mass_kg *
        speed_ms^2

    return joules /
        3.6e6

end


function regenerative_energy(
    mass_kg,
    initial_speed,
    final_speed,
    efficiency
)

    initial =
        kinetic_energy_kwh(
            mass_kg,
            initial_speed
        )

    final =
        kinetic_energy_kwh(
            mass_kg,
            final_speed
        )

    available =
        max(
            0.0,
            initial - final
        )

    return available *
        efficiency

end
```

# 12. Thermal model

## `src/thermal.jl`

```julia
function motor_heat(
    electrical_kw,
    mechanical_kw
)

    return max(
        0.0,
        electrical_kw -
        mechanical_kw
    )

end


function fuel_cell_heat(
    electrical_kw,
    efficiency
)

    chemical =
        electrical_kw /
        efficiency

    return max(
        0.0,
        chemical -
        electrical_kw
    )

end


function temperature_rise(
    heat_kw,
    thermal_mass_kj_k,
    dt_seconds
)

    energy_kj =
        heat_kw *
        dt_seconds

    return (
        energy_kj /
        thermal_mass_kj_k
    )

end
```

# 13. Timetable

## `src/timetable.jl`

```julia
function travel_time(
    distance_m,
    average_speed_ms
)

    return (
        distance_m /
        average_speed_ms
    )

end


function timetable_penalty(
    actual_time,
    target_time
)

    delay =
        max(
            0.0,
            actual_time -
            target_time
        )

    return delay^2

end
```

# 14. Complete HSR simulation

## `src/simulation.jl`

```julia
struct HSRProfile

    acceleration_ms2::Float64

    cruise_speed_kmh::Float64

    braking_ms2::Float64

    fuel_cell_fraction::Float64

    battery_buffer_fraction::Float64

    regenerative_efficiency::Float64

end


function simulate(
    train::Train,
    motor::Motor,
    fuelcell::FuelCell,
    battery::Battery,
    route::Vector{RoutePoint},
    profile::HSRProfile
)

    total_hydrogen =
        0.0

    total_energy =
        0.0

    regenerative_energy_total =
        0.0

    total_time =
        0.0

    peak_power =
        0.0

    battery_energy =
        battery_energy(battery)

    for i in 1:length(route)-1

        p1 =
            route[i]

        p2 =
            route[i+1]

        distance =
            p2.distance_m -
            p1.distance_m

        target_speed =
            min(
                profile.cruise_speed_kmh / 3.6,
                p2.speed_limit_ms
            )

        resistance =
            total_resistance(
                train,
                target_speed,
                p2.gradient
            )

        force =
            required_force(
                train,
                target_speed,
                profile.acceleration_ms2,
                p2.gradient
            )

        mechanical_power =
            max(
                0.0,
                force *
                target_speed
            ) / 1000.0

        mechanical_power =
            min(
                mechanical_power,
                motor.peak_power_kw
            )

        electrical_motor_power =
            motor_electrical_power(
                mechanical_power,
                motor
            )

        peak_power =
            max(
                peak_power,
                electrical_motor_power
            )

        fuelcell_power =
            electrical_motor_power *
            profile.fuel_cell_fraction

        battery_power =
            electrical_motor_power -
            fuelcell_power

        if battery_power > 0

            battery_energy -=
                battery_power *
                distance /
                max(
                    target_speed,
                    1.0
                ) /
                3600.0

        end

        hydrogen_energy =
            fuelcell_power *
            distance /
            max(
                target_speed,
                1.0
            ) /
            3600.0

        hydrogen =
            hydrogen_energy /
            fuelcell.efficiency /
            H2_LHV_KWH_KG

        total_hydrogen +=
            hydrogen

        total_energy +=
            electrical_motor_power *
            distance /
            max(
                target_speed,
                1.0
            ) /
            3600.0

        segment_time =
            distance /
            max(
                target_speed,
                1.0
            )

        total_time +=
            segment_time

        regen =
            regenerative_energy(
                train.mass_kg,
                target_speed,
                0.0,
                profile.regenerative_efficiency
            )

        regenerative_energy_total +=
            regen

    end

    return (
        hydrogen_kg=total_hydrogen,
        energy_kwh=total_energy,
        regenerative_kwh=
            regenerative_energy_total,
        travel_time_s=total_time,
        peak_power_kw=peak_power,
        final_battery_kwh=battery_energy
    )

end
```

# 15. Optimisation

The optimiser searches the train's operating strategy.

```julia
function objective(
    result,
    target_time_s,
    target_hydrogen_kg
)

    hydrogen_penalty =
        result.hydrogen_kg /
        target_hydrogen_kg

    time_penalty =
        max(
            0.0,
            result.travel_time_s -
            target_time_s
        ) / target_time_s

    power_penalty =
        result.peak_power_kw /
        10000.0

    battery_penalty =
        max(
            0.0,
            -result.final_battery_kwh
        ) / 1000.0

    return (
        10.0 * hydrogen_penalty +
        5.0 * time_penalty +
        2.0 * power_penalty +
        20.0 * battery_penalty
    )

end
```

Then:

```julia
function optimise_hsr(
    train,
    motor,
    fuelcell,
    battery,
    route;
    target_time_s=3600.0
)

    best_profile =
        nothing

    best_result =
        nothing

    best_score =
        Inf

    for acceleration in
        0.15:0.05:0.80

        for cruise in
            250.0:10.0:400.0

            for braking in
                0.15:0.05:1.00

                for fuel_fraction in
                    0.5:0.05:1.0

                    for battery_fraction in
                        0.0:0.05:0.5

                        profile =
                            HSRProfile(
                                acceleration,
                                cruise,
                                braking,
                                fuel_fraction,
                                battery_fraction,
                                0.80
                            )

                        result =
                            simulate(
                                train,
                                motor,
                                fuelcell,
                                battery,
                                route,
                                profile
                            )

                        score =
                            objective(
                                result,
                                target_time_s,
                                100.0
                            )

                        if score < best_score

                            best_score =
                                score

                            best_profile =
                                profile

                            best_result =
                                result

                        end

                    end
                end
            end
        end
    end

    return (
        profile=best_profile,
        result=best_result,
        score=best_score
    )

end
```

# 16. Example

## `examples/optimise_hsr.jl`

```julia
using Pkg

Pkg.activate(joinpath(@__DIR__, ".."))

using HydrogenHSR

route = [

    RoutePoint(
        0.0,
        0.000,
        300.0 / 3.6
    ),

    RoutePoint(
        25_000.0,
        0.004,
        300.0 / 3.6
    ),

    RoutePoint(
        75_000.0,
        -0.002,
        350.0 / 3.6
    ),

    RoutePoint(
        150_000.0,
        0.000,
        400.0 / 3.6
    )

]

result =
    optimise_hsr(
        HSR_TRAIN,
        HSR_MOTOR,
        HSR_FUEL_CELL,
        HSR_BATTERY,
        route;
        target_time_s=2400.0
    )

println("HYDROGEN HSR OPTIMISATION")
println("==========================")

println()

println(
    "Acceleration: ",
    result.profile.acceleration_ms2,
    " m/s²"
)

println(
    "Cruise speed: ",
    result.profile.cruise_speed_kmh,
    " km/h"
)

println(
    "Hydrogen: ",
    result.result.hydrogen_kg,
    " kg"
)

println(
    "Traction energy: ",
    result.result.energy_kwh,
    " kWh"
)

println(
    "Regenerative energy: ",
    result.result.regenerative_kwh,
    " kWh"
)

println(
    "Peak electrical power: ",
    result.result.peak_power_kw,
    " kW"
)

println(
    "Travel time: ",
    result.result.travel_time_s / 60.0,
    " minutes"
)

println(
    "Final battery energy: ",
    result.result.final_battery_kwh,
    " kWh"
)
```

# 17. Tests

## `test/runtests.jl`

```julia
using Test

include("../src/HydrogenHSR.jl")

using .HydrogenHSR

@testset "Aerodynamics" begin

    force =
        aerodynamic_force(
            HSR_TRAIN,
            100.0
        )

    @test force > 0

end


@testset "Hydrogen" begin

    h2 =
        hydrogen_consumption(
            1000.0,
            0.55
        )

    @test h2 > 0

end


@testset "Regeneration" begin

    energy =
        regenerative_energy(
            400_000.0,
            100.0,
            50.0,
            0.80
        )

    @test energy > 0

end


@testset "Simulation" begin

    route = [

        RoutePoint(
            0.0,
            0.0,
            300.0 / 3.6
        ),

        RoutePoint(
            50_000.0,
            0.0,
            300.0 / 3.6
        )

    ]

    profile =
        HSRProfile(
            0.4,
            300.0,
            0.5,
            0.8,
            0.2,
            0.8
        )

    result =
        simulate(
            HSR_TRAIN,
            HSR_MOTOR,
            HSR_FUEL_CELL,
            HSR_BATTERY,
            route,
            profile
        )

    @test result.hydrogen_kg >= 0
    @test result.energy_kwh >= 0
    @test result.travel_time_s > 0

end
```

# 18. The production-level model

The basic version above can then become a much more sophisticated **HSR digital twin**.

```text
                 HYDROGEN STORAGE
                        │
                        ▼
                ┌───────────────┐
                │   FUEL CELL   │
                └───────┬───────┘
                        │ DC
                        ▼
                ┌───────────────┐
                │    DC BUS     │◄──────────┐
                └───────┬───────┘           │
                        │                   │
             ┌──────────┴──────────┐        │
             ▼                     ▼        │
        ┌──────────┐          ┌─────────┐   │
        │ INVERTER │          │ BATTERY │   │
        └────┬─────┘          └─────────┘   │
             │                              │
             ▼                              │
       ┌────────────┐                       │
       │TRACTION    │                       │
       │MOTORS      │                       │
       └─────┬──────┘                       │
             │                              │
             ▼                              │
           WHEELS                           │
             │                              │
             ▼                              │
           RAIL                             │
                                            │
             REGENERATIVE BRAKING ──────────┘
```

Julia can then optimise **five different levels simultaneously**:

### 1. Motor

```text
motor torque
motor RPM
motor efficiency
inverter efficiency
thermal load
```

### 2. Battery

```text
SOC
charge/discharge rate
temperature
degradation
buffer size
```

### 3. Fuel cell

```text
fuel-cell load
efficiency
hydrogen flow
stack temperature
ramp rate
```

### 4. Train

```text
acceleration
cruising speed
coasting
braking
regeneration
drag
gradient
```

### 5. Railway

```text
station spacing
speed limits
gradients
timetable
headways
energy recovery
```

The optimisation objective could consequently become:

```text
MINIMISE

hydrogen consumption
       +
electricity consumption
       +
battery degradation
       +
fuel-cell degradation
       +
motor thermal stress
       +
travel-time penalty
       +
peak power requirement

SUBJECT TO

speed limits
acceleration limits
braking limits
hydrogen tank capacity
battery SOC limits
fuel-cell limits
motor temperature limits
timetable constraints
gradient
train mass
```

For a serious engineering version, I would move from the simple grid search above to **JuMP + nonlinear optimisation/model-predictive control**, with the route represented as hundreds or thousands of segments. That would allow Julia to optimise an entire **Jeddah–Riyadh-style 300–400 km/h hydrogen HSR journey**, including the speed trajectory, fuel-cell operating point, battery buffering and regenerative braking rather than merely choosing a few fixed parameters.

