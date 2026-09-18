# Julia Rice Cooker Optimisation Engine

```text
rice_cooker_optimizer/
│
├── Project.toml
│
├── src/
│   ├── RiceCookerOptimizer.jl
│   ├── rice.jl
│   ├── water.jl
│   ├── thermodynamics.jl
│   ├── heating.jl
│   ├── evaporation.jl
│   ├── texture.jl
│   ├── cooker.jl
│   ├── simulation.jl
│   ├── optimisation.jl
│   └── profiles.jl
│
├── data/
│   ├── rice_types.csv
│   └── cooker_profiles.csv
│
├── examples/
│   └── optimise_rice.jl
│
└── test/
    └── runtests.jl
```

## `Project.toml`

```toml
name = "RiceCookerOptimizer"
uuid = "5c6d3a41-5c8a-4a77-8f13-7b4a9d201001"
authors = ["Rice Cooker Research"]
version = "0.1.0"

[compat]
julia = "1.10"
```

# `src/RiceCookerOptimizer.jl`

```julia
module RiceCookerOptimizer

include("rice.jl")
include("water.jl")
include("thermodynamics.jl")
include("heating.jl")
include("evaporation.jl")
include("texture.jl")
include("cooker.jl")
include("simulation.jl")
include("optimisation.jl")
include("profiles.jl")

export
    RiceType,
    CookerProfile,
    CookingProfile,
    SimulationResult,
    BASMATI,
    JASMINE,
    SHORT_GRAIN,
    optimise_cooking,
    simulate_cooking,
    default_profile,
    save_profile

end
```

# `src/rice.jl`

```julia
struct RiceType

    name::String

    moisture_target::Float64

    absorption_rate::Float64

    preferred_temperature::Float64

    texture_target::Float64

    sensitivity::Float64

end


const BASMATI =
    RiceType(
        "Basmati",
        0.62,
        0.78,
        96.0,
        0.82,
        0.70
    )


const JASMINE =
    RiceType(
        "Jasmine",
        0.64,
        0.82,
        96.0,
        0.86,
        0.75
    )


const SHORT_GRAIN =
    RiceType(
        "Short Grain",
        0.68,
        0.88,
        97.0,
        0.90,
        0.85
    )
```

The values above are **model parameters**, not universal cooking instructions. They should be calibrated against actual rice varieties and measurements.

# `src/water.jl`

```julia
function initial_water_mass(
    rice_mass::Float64,
    ratio::Float64
)

    return rice_mass * ratio

end


function absorbed_water(
    rice_mass,
    water_mass,
    rice::RiceType,
    temperature
)

    temperature_factor =
        clamp(
            (temperature - 40.0) / 60.0,
            0.0,
            1.2
        )

    potential =
        rice_mass *
        rice.absorption_rate *
        temperature_factor

    return min(
        water_mass,
        potential
    )

end


function remaining_water(
    initial_water,
    absorbed,
    evaporated
)

    return max(
        0.0,
        initial_water -
        absorbed -
        evaporated
    )

end
```

# `src/thermodynamics.jl`

```julia
const WATER_HEAT_CAPACITY = 4.186
const RICE_HEAT_CAPACITY = 1.7


function thermal_mass(
    rice_mass,
    water_mass
)

    return (
        rice_mass *
        RICE_HEAT_CAPACITY
        +
        water_mass *
        WATER_HEAT_CAPACITY
    )

end


function equilibrium_temperature(
    ambient,
    heater_power,
    heat_loss
)

    return ambient +
        heater_power /
        max(heat_loss, 0.001)

end


function temperature_change(
    heater_power,
    heat_loss,
    temperature,
    ambient,
    mass,
    dt
)

    net_power =
        heater_power -
        heat_loss *
        (temperature - ambient)

    energy =
        net_power *
        dt

    return energy /
        max(
            mass *
            WATER_HEAT_CAPACITY,
            0.001
        )

end
```

# `src/heating.jl`

```julia
function heater_power(
    cooker,
    temperature,
    target
)

    if temperature < target - 5

        return cooker.max_power

    elseif temperature < target

        return cooker.max_power * 0.60

    else

        return cooker.max_power * 0.20

    end

end


function controlled_heater_power(
    cooker,
    temperature,
    target,
    proportional_gain
)

    error =
        target - temperature

    power =
        proportional_gain * error

    return clamp(
        power,
        0.0,
        cooker.max_power
    )

end
```

# `src/evaporation.jl`

```julia
function evaporation_rate(
    temperature,
    relative_humidity,
    surface_factor
)

    if temperature < 70.0
        return 0.0
    end

    temperature_factor =
        (temperature - 70.0) / 30.0

    humidity_factor =
        1.0 -
        relative_humidity

    return (
        0.00008 *
        temperature_factor *
        humidity_factor *
        surface_factor
    )

end


function evaporated_water(
    temperature,
    humidity,
    surface,
    dt
)

    return evaporation_rate(
        temperature,
        humidity,
        surface
    ) * dt

end
```

# `src/texture.jl`

```julia
function texture_score(
    rice::RiceType,
    absorbed_fraction,
    peak_temperature,
    cooking_time,
    target_time
)

    absorption_error =
        abs(
            absorbed_fraction -
            rice.moisture_target
        )

    temperature_error =
        abs(
            peak_temperature -
            rice.preferred_temperature
        ) / 10.0

    time_error =
        abs(
            cooking_time -
            target_time
        ) / target_time

    penalty =
        rice.sensitivity *
        (
            absorption_error +
            0.2 * temperature_error +
            0.2 * time_error
        )

    return clamp(
        1.0 - penalty,
        0.0,
        1.0
    )

end
```

# `src/cooker.jl`

```julia
struct CookerProfile

    name::String

    max_power::Float64

    thermal_efficiency::Float64

    heat_loss::Float64

    bowl_mass::Float64

    surface_factor::Float64

end


const STANDARD_COOKER =
    CookerProfile(
        "Standard 700W",
        700.0,
        0.82,
        5.0,
        1.0,
        1.0
    )
```

# `src/simulation.jl`

```julia
struct CookingProfile

    water_ratio::Float64

    soak_minutes::Float64

    target_temperature::Float64

    simmer_minutes::Float64

    rest_minutes::Float64

    proportional_gain::Float64

end


struct SimulationResult

    total_time_minutes::Float64

    energy_wh::Float64

    final_temperature::Float64

    peak_temperature::Float64

    absorbed_fraction::Float64

    evaporated_water::Float64

    texture_score::Float64

    scorching_risk::Float64

end
```

## Main simulation

```julia
function simulate_cooking(
    rice_mass::Float64,
    rice::RiceType,
    cooker::CookerProfile,
    profile::CookingProfile;
    ambient_temperature=22.0,
    humidity=0.50,
    dt_seconds=5.0
)

    water_mass =
        initial_water_mass(
            rice_mass,
            profile.water_ratio
        )

    temperature =
        ambient_temperature

    peak_temperature =
        temperature

    absorbed =
        0.0

    evaporated =
        0.0

    energy =
        0.0

    total_seconds =
        (
            profile.soak_minutes +
            profile.simmer_minutes +
            profile.rest_minutes
        ) * 60.0

    elapsed = 0.0

    while elapsed < total_seconds

        minute =
            elapsed / 60.0

        if minute <
            profile.soak_minutes

            power = 0.0

            target =
                ambient_temperature

        elseif minute <
            profile.soak_minutes +
            profile.simmer_minutes

            target =
                profile.target_temperature

            power =
                controlled_heater_power(
                    cooker,
                    temperature,
                    target,
                    profile.proportional_gain
                )

        else

            power = 0.0

            target =
                ambient_temperature

        end

        mass =
            thermal_mass(
                rice_mass,
                max(
                    water_mass -
                    evaporated,
                    0.01
                )
            )

        delta =
            temperature_change(
                power *
                cooker.thermal_efficiency,
                cooker.heat_loss,
                temperature,
                ambient_temperature,
                mass,
                dt_seconds
            )

        temperature += delta

        peak_temperature =
            max(
                peak_temperature,
                temperature
            )

        absorbed_now =
            absorbed_water(
                rice_mass,
                water_mass,
                rice,
                temperature
            )

        absorbed =
            max(
                absorbed,
                absorbed_now
            )

        evaporation =
            evaporated_water(
                temperature,
                humidity,
                cooker.surface_factor,
                dt_seconds
            )

        evaporated += evaporation

        energy +=
            power *
            dt_seconds /
            3600.0

        elapsed += dt_seconds

    end

    absorbed_fraction =
        clamp(
            absorbed /
            max(
                rice_mass,
                0.001
            ),
            0.0,
            1.0
        )

    score =
        texture_score(
            rice,
            absorbed_fraction,
            peak_temperature,
            total_seconds / 60.0,
            profile.simmer_minutes +
            profile.soak_minutes
        )

    scorching =
        max(
            0.0,
            peak_temperature -
            103.0
        ) / 20.0

    return SimulationResult(
        total_seconds / 60.0,
        energy,
        temperature,
        peak_temperature,
        absorbed_fraction,
        evaporated,
        score,
        clamp(scorching, 0.0, 1.0)
    )

end
```

# `src/optimisation.jl`

The optimiser searches the cooking profile rather than simply maximising temperature.

```julia
function cooking_objective(
    result::SimulationResult
)

    texture =
        result.texture_score

    energy_penalty =
        result.energy_wh / 1000.0

    time_penalty =
        result.total_time_minutes /
        100.0

    scorching_penalty =
        result.scorching_risk * 2.0

    return (
        100.0 * texture -
        energy_penalty -
        time_penalty -
        scorching_penalty
    )

end


function optimise_cooking(
    rice_mass::Float64,
    rice::RiceType,
    cooker::CookerProfile
)

    best_profile =
        nothing

    best_result =
        nothing

    best_score =
        -Inf

    water_ratios =
        1.00:0.02:2.00

    soak_times =
        0.0:5.0:30.0

    temperatures =
        92.0:1.0:100.0

    simmer_times =
        10.0:2.0:40.0

    gains =
        5.0:2.0:20.0

    for ratio in water_ratios

        for soak in soak_times

            for target in temperatures

                for simmer in simmer_times

                    for gain in gains

                        profile =
                            CookingProfile(
                                ratio,
                                soak,
                                target,
                                simmer,
                                10.0,
                                gain
                            )

                        result =
                            simulate_cooking(
                                rice_mass,
                                rice,
                                cooker,
                                profile
                            )

                        score =
                            cooking_objective(
                                result
                            )

                        if score > best_score

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

# `src/profiles.jl`

```julia
function default_profile(
    rice::RiceType
)

    if rice.name == "Basmati"

        return CookingProfile(
            1.55,
            10.0,
            97.0,
            22.0,
            10.0,
            10.0
        )

    elseif rice.name == "Jasmine"

        return CookingProfile(
            1.50,
            10.0,
            97.0,
            22.0,
            10.0,
            10.0
        )

    else

        return CookingProfile(
            1.40,
            15.0,
            98.0,
            25.0,
            10.0,
            10.0
        )

    end

end


function save_profile(
    filename,
    profile::CookingProfile
)

    open(filename, "w") do io

        println(io, "water_ratio = ",
            profile.water_ratio)

        println(io, "soak_minutes = ",
            profile.soak_minutes)

        println(io, "target_temperature = ",
            profile.target_temperature)

        println(io, "simmer_minutes = ",
            profile.simmer_minutes)

        println(io, "rest_minutes = ",
            profile.rest_minutes)

        println(io, "proportional_gain = ",
            profile.proportional_gain)

    end

end
```

# Example

## `examples/optimise_rice.jl`

```julia
using Pkg

Pkg.activate(joinpath(@__DIR__, ".."))

using RiceCookerOptimizer

rice_mass = 300.0

rice =
    BASMATI

cooker =
    STANDARD_COOKER

println("Optimising rice cooker...")
println()

result =
    optimise_cooking(
        rice_mass,
        rice,
        cooker
    )

profile =
    result.profile

simulation =
    result.result

println("Rice: ",
    rice.name)

println("Batch: ",
    rice_mass,
    " g")

println()

println("OPTIMISED PROFILE")
println("------------------")

println(
    "Water ratio: ",
    profile.water_ratio
)

println(
    "Soak: ",
    profile.soak_minutes,
    " min"
)

println(
    "Target temperature: ",
    profile.target_temperature,
    " °C"
)

println(
    "Simmer: ",
    profile.simmer_minutes,
    " min"
)

println(
    "Rest: ",
    profile.rest_minutes,
    " min"
)

println()

println("SIMULATION")
println("------------------")

println(
    "Total time: ",
    simulation.total_time_minutes,
    " min"
)

println(
    "Energy: ",
    simulation.energy_wh,
    " Wh"
)

println(
    "Peak temperature: ",
    simulation.peak_temperature,
    " °C"
)

println(
    "Absorbed fraction: ",
    simulation.absorbed_fraction
)

println(
    "Evaporated water: ",
    simulation.evaporated_water,
    " g"
)

println(
    "Texture score: ",
    simulation.texture_score
)

println(
    "Scorching risk: ",
    simulation.scorching_risk
)

save_profile(
    "optimised_basmati_profile.txt",
    profile
)
```

# Tests

## `test/runtests.jl`

```julia
using Test

include("../src/RiceCookerOptimizer.jl")

using .RiceCookerOptimizer

@testset "Rice cooker model" begin

    @test BASMATI.name == "Basmati"

    @test JASMINE.name == "Jasmine"

    @test SHORT_GRAIN.name == "Short Grain"

end


@testset "Water model" begin

    water =
        initial_water_mass(
            300.0,
            1.5
        )

    @test water == 450.0

end


@testset "Simulation" begin

    profile =
        default_profile(
            BASMATI
        )

    result =
        simulate_cooking(
            300.0,
            BASMATI,
            STANDARD_COOKER,
            profile
        )

    @test result.total_time_minutes > 0

    @test result.energy_wh >= 0

    @test result.texture_score >= 0

    @test result.texture_score <= 1

end


@testset "Optimisation" begin

    result =
        optimise_cooking(
            100.0,
            BASMATI,
            STANDARD_COOKER
        )

    @test result.profile !== nothing

    @test result.result !== nothing

end
```

# What this becomes in a real smart rice cooker

The next version could connect the Julia model to actual sensors:

```text
                    SMART RICE COOKER
                           │
          ┌────────────────┼────────────────┐
          │                │                │
      Temperature       Weight          Humidity
       sensor           sensor           sensor
          │                │                │
          └────────────────┼────────────────┘
                           │
                           ▼
                    Controller
                           │
                           ▼
                     Julia model
                           │
              ┌────────────┼────────────┐
              │            │            │
          Heat power     Water        Timing
              │            │            │
              └────────────┼────────────┘
                           │
                           ▼
                   Optimised profile
```

A more sophisticated optimiser could continuously estimate:

```text
Rice mass
Water mass
Rice moisture
Bowl temperature
Rice temperature
Steam temperature
Evaporation rate
Absorption rate
Thermal efficiency
Ambient temperature
Ambient pressure
Cooking phase
```

and then dynamically adjust the heater.

The cooker could therefore move through something like:

```text
PHASE 1
Loading
│
├── Measure rice mass
├── Measure water mass
└── Establish baseline

        ↓

PHASE 2
Soak
│
├── Low/no heat
├── Monitor absorption
└── Estimate rice hydration

        ↓

PHASE 3
Heat
│
├── High power
├── Temperature tracking
└── Estimate remaining water

        ↓

PHASE 4
Boil / simmer
│
├── Reduce power
├── Prevent excessive evaporation
└── Estimate starch development

        ↓

PHASE 5
Finish
│
├── Detect water depletion
├── Reduce heater
└── Prevent scorching

        ↓

PHASE 6
Rest
│
├── Residual heat
├── Steam redistribution
└── Texture stabilisation
```

## The really powerful version

Instead of having fixed programs such as **WHITE RICE / BROWN RICE / QUICK COOK**, the cooker could have a **model-predictive controller**:

```text
                 CURRENT STATE
                       │
                       ▼
             ┌─────────────────┐
             │ Julia simulator  │
             └────────┬────────┘
                      │
             simulate next 30 min
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
      Heat 1        Heat 2        Heat 3
        │             │             │
        └─────────────┼─────────────┘
                      ▼
                score outcomes
                      │
                      ▼
                choose action
                      │
                      ▼
                 REAL HEATER
                      │
                      ▼
                 new sensors
                      │
                      └──────► repeat
```

That would make Julia particularly useful: **the cooker isn't following a fixed recipe; it is continuously estimating the physical state of the rice and optimising the next heating action.**

For an actual appliance, the final controller should be validated extensively against real thermocouple/weight measurements and implemented with appropriate embedded safety controls; Julia is excellent for the modelling and optimisation layer, but shouldn't be the sole safety-critical control layer of a consumer cooker.

