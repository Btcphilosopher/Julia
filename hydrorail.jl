Yes. For hydrogen rail, Julia is particularly useful because the optimisation problem is much broader than simply calculating train fuel consumption: you can optimise train schedules, hydrogen production, storage, refuelling, gradients, speeds, consists and electricity prices simultaneously.

I’d structure it as a separate project:

hydrogen_rail_optimization/
├── Project.toml
├── src/
│   ├── HydrogenRail.jl
│   ├── trains.jl
│   ├── route.jl
│   ├── physics.jl
│   ├── hydrogen.jl
│   ├── electrolyser.jl
│   ├── storage.jl
│   ├── refuelling.jl
│   ├── timetable.jl
│   ├── energy_market.jl
│   ├── economics.jl
│   ├── optimisation.jl
│   ├── forecasting.jl
│   └── simulation.jl
│
├── data/
│   ├── trains.csv
│   ├── route.csv
│   ├── stations.csv
│   ├── electricity_prices.csv
│   └── hydrogen_prices.csv
│
├── test/
│   └── runtests.jl
│
└── examples/
    └── hydrogen_rail_simulation.jl

And here is the actual Julia architecture I would use.

Project.toml
name = "HydrogenRail"
uuid = "5f6d3e12-3b52-4b67-9c1d-7e8a4d921001"
authors = ["Hydrogen Rail Research"]
version = "0.1.0"

[deps]
CSV = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3a2e7e"
Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
JuMP = "4076af6c-e467-56ae-b986-b466b2749572"
HiGHS = "87dc4568-4c63-4a98-9c4c-9f4f1a4a9f0c"
Statistics = "10745b16-90b1-5c2f-98f3-4d4d9c1a9b2a"
Random = "9a3f8284-686f-5f34-9a0f-0c1b9a8d7c5e"

[compat]
julia = "1.10"
src/HydrogenRail.jl
module HydrogenRail

using CSV
using DataFrames
using Dates
using Statistics
using Random
using JuMP
using HiGHS

include("trains.jl")
include("route.jl")
include("physics.jl")
include("hydrogen.jl")
include("electrolyser.jl")
include("storage.jl")
include("refuelling.jl")
include("timetable.jl")
include("energy_market.jl")
include("economics.jl")
include("optimisation.jl")
include("forecasting.jl")
include("simulation.jl")

export Train,
       RoutePoint,
       HydrogenSystem,
       Electrolyser,
       HydrogenStorage,
       train_energy,
       hydrogen_consumption,
       journey_simulation,
       hydrogen_production,
       optimise_hydrogen_rail,
       simulate_network

end
src/trains.jl
struct Train

    name::String

    mass_tonnes::Float64
    passengers::Int

    traction_power_kw::Float64
    auxiliary_power_kw::Float64

    hydrogen_capacity_kg::Float64
    fuel_cell_efficiency::Float64

    max_speed_kmh::Float64

end


function train_mass_kg(train::Train)

    return train.mass_tonnes * 1000.0

end


function hydrogen_energy_kwh(
    train::Train
)

    # Approximate lower heating value.
    return train.hydrogen_capacity_kg * 33.33

end
src/route.jl
struct RoutePoint

    distance_km::Float64
    elevation_m::Float64
    speed_limit_kmh::Float64

end


function route_gradient(
    a::RoutePoint,
    b::RoutePoint
)

    distance_m =
        (b.distance_km -
         a.distance_km) * 1000.0

    if distance_m == 0
        return 0.0
    end

    return (
        b.elevation_m -
        a.elevation_m
    ) / distance_m

end


function route_distance(
    route::Vector{RoutePoint}
)

    return route[end].distance_km -
           route[1].distance_km

end
src/physics.jl

This is where the train becomes a physical model.

const G = 9.80665

"""
Calculate rolling resistance.

Returns force in Newtons.
"""
function rolling_resistance(
    mass_kg::Float64,
    velocity_ms::Float64
)

    # Simplified Davis-style approximation.

    A = 1.5
    B = 0.03
    C = 0.0008

    return (
        A +
        B * velocity_ms +
        C * velocity_ms^2
    ) * mass_kg

end


"""
Calculate gravitational resistance.
"""
function gradient_force(
    mass_kg::Float64,
    gradient::Float64
)

    return (
        mass_kg *
        G *
        gradient
    )

end


"""
Calculate aerodynamic drag.
"""
function aerodynamic_drag(
    velocity_ms::Float64
)

    rho = 1.225
    Cd = 0.8
    area = 10.0

    return 0.5 *
           rho *
           Cd *
           area *
           velocity_ms^2

end


"""
Total traction force.
"""
function traction_force(
    train::Train,
    velocity_ms::Float64,
    gradient::Float64
)

    mass =
        train_mass_kg(train)

    return (
        rolling_resistance(
            mass,
            velocity_ms
        ) +
        gradient_force(
            mass,
            gradient
        ) +
        aerodynamic_drag(
            velocity_ms
        )
    )

end
src/hydrogen.jl
const H2_LHV_KWH_KG = 33.33


"""
Hydrogen required for a given electrical
energy requirement.
"""
function hydrogen_consumption(
    electrical_energy_kwh::Float64,
    fuel_cell_efficiency::Float64
)

    chemical_energy =
        electrical_energy_kwh /
        fuel_cell_efficiency

    return chemical_energy /
           H2_LHV_KWH_KG

end


function hydrogen_energy(
    hydrogen_kg::Float64
)

    return hydrogen_kg *
           H2_LHV_KWH_KG

end


"""
Hydrogen consumption per passenger-km.
"""
function passenger_km_efficiency(
    hydrogen_kg::Float64,
    passengers::Int,
    distance_km::Float64
)

    return hydrogen_kg /
           (
               passengers *
               distance_km
           )

end
src/electrolyser.jl
struct Electrolyser

    name::String

    capacity_mw::Float64

    efficiency_kwh_per_kg::Float64

    minimum_load_fraction::Float64

end


"""
Hydrogen production from electricity.
"""
function hydrogen_production(
    electrolyser::Electrolyser,
    electricity_mwh::Float64
)

    electricity_kwh =
        electricity_mwh * 1000.0

    return electricity_kwh /
           electrolyser.efficiency_kwh_per_kg

end


function maximum_hydrogen_per_hour(
    electrolyser::Electrolyser
)

    return (
        electrolyser.capacity_mw *
        1000.0 /
        electrolyser.efficiency_kwh_per_kg
    )

end
src/storage.jl
struct HydrogenStorage

    capacity_kg::Float64
    initial_kg::Float64
    minimum_kg::Float64

end


function storage_step(
    storage::HydrogenStorage,
    current_kg::Float64,
    production_kg::Float64,
    refuelling_kg::Float64
)

    new_storage =
        current_kg +
        production_kg -
        refuelling_kg

    return clamp(
        new_storage,
        storage.minimum_kg,
        storage.capacity_kg
    )

end
src/refuelling.jl
struct RefuellingStation

    name::String

    capacity_kg::Float64

    maximum_hourly_delivery_kg::Float64

    operating_cost_per_kg::Float64

end


function can_refuel(
    station::RefuellingStation,
    quantity_kg::Float64
)

    return quantity_kg <=
           station.maximum_hourly_delivery_kg

end


function refuelling_cost(
    station::RefuellingStation,
    quantity_kg::Float64
)

    return quantity_kg *
           station.operating_cost_per_kg

end
src/timetable.jl
struct TrainService

    id::String
    train_id::String

    origin::String
    destination::String

    departure::DateTime
    arrival::DateTime

    distance_km::Float64

end


function journey_duration_minutes(
    service::TrainService
)

    return Dates.value(
        service.arrival -
        service.departure
    ) / 60000.0

end
src/energy_market.jl
function hydrogen_cost(
    hydrogen_kg::Float64,
    price_per_kg::Float64
)

    return hydrogen_kg *
           price_per_kg

end


function electrolyser_electricity_cost(
    electricity_mwh::Float64,
    price_per_mwh::Float64
)

    return electricity_mwh *
           price_per_mwh

end
src/economics.jl
function annual_hydrogen_cost(
    hydrogen_kg::Float64,
    price_per_kg::Float64
)

    return hydrogen_kg *
           price_per_kg

end


function annual_electricity_cost(
    electricity_mwh::Float64,
    price_per_mwh::Float64
)

    return electricity_mwh *
           price_per_mwh

end


function levelised_hydrogen_cost(
    electricity_price_mwh::Float64,
    electrolyser_efficiency_kwh_per_kg::Float64
)

    electricity_cost_per_kg =
        (
            electrolyser_efficiency_kwh_per_kg /
            1000.0
        ) *
        electricity_price_mwh

    return electricity_cost_per_kg

end
src/forecasting.jl
function forecast_electricity_prices(
    prices::Vector{Float64};
    window::Int = 24
)

    n = length(prices)

    start =
        max(
            1,
            n - window + 1
        )

    return mean(
        prices[start:n]
    )

end


function forecast_hydrogen_demand(
    historical_kg::Vector{Float64}
)

    return mean(
        historical_kg
    )

end
src/simulation.jl

The train journey model:

function journey_simulation(
    train::Train,
    route::Vector{RoutePoint};
    timestep_seconds::Float64 = 10.0
)

    total_energy_kwh = 0.0
    total_distance_km = 0.0

    velocity_ms = 0.0

    for i in 1:(length(route)-1)

        a = route[i]
        b = route[i+1]

        distance_km =
            b.distance_km -
            a.distance_km

        gradient =
            route_gradient(a, b)

        velocity_kmh =
            min(
                b.speed_limit_kmh,
                train.max_speed_kmh
            )

        velocity_ms =
            velocity_kmh / 3.6

        force =
            traction_force(
                train,
                velocity_ms,
                gradient
            )

        mechanical_power_kw =
            force *
            velocity_ms /
            1000.0

        electrical_power_kw =
            mechanical_power_kw /
            0.90 +
            train.auxiliary_power_kw

        time_hours =
            distance_km /
            velocity_kmh

        energy_kwh =
            electrical_power_kw *
            time_hours

        total_energy_kwh +=
            energy_kwh

        total_distance_km +=
            distance_km

    end

    hydrogen =
        hydrogen_consumption(
            total_energy_kwh,
            train.fuel_cell_efficiency
        )

    return (
        distance_km = total_distance_km,
        energy_kwh = total_energy_kwh,
        hydrogen_kg = hydrogen
    )

end
src/optimisation.jl

This is where Julia becomes particularly valuable.

The optimiser should decide how much hydrogen to produce and when.

function optimise_hydrogen_rail(
    demand_kg::Vector{Float64},
    electricity_price::Vector{Float64},
    electrolyser::Electrolyser,
    storage::HydrogenStorage
)

    n =
        length(demand_kg)

    model =
        Model(
            HiGHS.Optimizer
        )

    set_silent(model)

    max_production =
        maximum_hydrogen_per_hour(
            electrolyser
        )

    @variable(
        model,
        0 <= production[1:n] <=
        max_production
    )

    @variable(
        model,
        0 <= supplied[1:n]
    )

    @variable(
        model,
        storage_level[1:n]
        >= storage.minimum_kg
    )

    # Storage balance

    @constraint(
        model,
        storage_level[1] ==
        storage.initial_kg +
        production[1] -
        supplied[1]
    )

    for t in 2:n

        @constraint(
            model,
            storage_level[t] ==
            storage_level[t-1] +
            production[t] -
            supplied[t]
        )

    end

    # Rail demand must be satisfied.

    for t in 1:n

        @constraint(
            model,
            supplied[t] >=
            demand_kg[t]
        )

    end

    # Storage capacity.

    for t in 1:n

        @constraint(
            model,
            storage_level[t] <=
            storage.capacity_kg
        )

    end

    # Electrolyser electricity consumption.

    @expression(
        model,
        electricity_mwh[t=1:n],
        production[t] *
        electrolyser.efficiency_kwh_per_kg /
        1000.0
    )

    # Minimise electricity cost.

    @objective(
        model,
        Min,
        sum(
            electricity_mwh[t] *
            electricity_price[t]
            for t in 1:n
        )
    )

    optimize!(model)

    if !is_solved_and_feasible(model)

        error(
            "Hydrogen rail optimisation failed."
        )

    end

    return DataFrame(
        hour = 1:n,

        demand_kg =
            demand_kg,

        production_kg =
            value.(production),

        supplied_kg =
            value.(supplied),

        storage_kg =
            value.(storage_level),

        electricity_mwh =
            value.(electricity_mwh),

        electricity_price =
            electricity_price
    )

end
Example network

examples/hydrogen_rail_simulation.jl

using Pkg

Pkg.activate(
    joinpath(
        @__DIR__,
        ".."
    )
)

using HydrogenRail
using Dates

println()
println("==========================================")
println(" HYDROGEN RAIL OPTIMISATION")
println("==========================================")

train =
    Train(
        "H2 Intercity Unit",
        450.0,
        400,
        3000.0,
        150.0,
        500.0,
        0.55,
        200.0
    )

route = RoutePoint[
    RoutePoint(0.0,   10.0, 160.0),
    RoutePoint(10.0,  20.0, 160.0),
    RoutePoint(20.0,  80.0, 140.0),
    RoutePoint(30.0,  120.0, 140.0),
    RoutePoint(40.0,  100.0, 160.0),
    RoutePoint(50.0,  60.0, 200.0),
    RoutePoint(60.0,  40.0, 200.0)
]

journey =
    journey_simulation(
        train,
        route
    )

println()
println("TRAIN JOURNEY")
println("------------------------------------------")

println(
    "Distance: ",
    round(
        journey.distance_km,
        digits=1
    ),
    " km"
)

println(
    "Electricity: ",
    round(
        journey.energy_kwh,
        digits=1
    ),
    " kWh"
)

println(
    "Hydrogen: ",
    round(
        journey.hydrogen_kg,
        digits=2
    ),
    " kg"
)

println()

# ------------------------------------------------
# Hydrogen infrastructure
# ------------------------------------------------

electrolyser =
    Electrolyser(
        "Rail Hydrogen Plant",
        20.0,
        52.0,
        0.20
    )

storage =
    HydrogenStorage(
        10000.0,
        5000.0,
        500.0
    )

# Example 24-hour rail demand.

demand =
    fill(
        journey.hydrogen_kg * 5.0,
        24
    )

electricity_price =
    [
        55, 52, 50, 48,
        50, 60, 75, 90,
        95, 80, 70, 65,
        60, 58, 62, 75,
        90, 110, 120, 100,
        85, 75, 65, 60
    ]

result =
    optimise_hydrogen_rail(
        demand,
        electricity_price,
        electrolyser,
        storage
    )

println(
    "HYDROGEN OPTIMISATION"
)

println("------------------------------------------")

println(
    "Total hydrogen demand: ",
    round(
        sum(result.demand_kg),
        digits=2
    ),
    " kg"
)

println(
    "Hydrogen produced: ",
    round(
        sum(result.production_kg),
        digits=2
    ),
    " kg"
)

println(
    "Electricity consumed: ",
    round(
        sum(result.electricity_mwh),
        digits=2
    ),
    " MWh"
)

println(
    "Electricity cost: £",
    round(
        sum(
            result.electricity_mwh .*
            result.electricity_price
        ),
        digits=2
    )
)

println()
println("Optimisation complete.")
test/runtests.jl
using Test

using Pkg

Pkg.activate(
    joinpath(
        @__DIR__,
        ".."
    )
)

using HydrogenRail

@testset "Hydrogen Rail" begin

    train =
        Train(
            "Test Train",
            400.0,
            300,
            3000.0,
            100.0,
            500.0,
            0.55,
            200.0
        )

    @test train_mass_kg(train) ==
          400000.0

    h2 =
        hydrogen_consumption(
            1000.0,
            0.55
        )

    @test h2 > 0

    electrolyser =
        Electrolyser(
            "Test Electrolyser",
            10.0,
            52.0,
            0.2
        )

    production =
        hydrogen_production(
            electrolyser,
            10.0
        )

    @test production > 0

    storage =
        HydrogenStorage(
            10000.0,
            5000.0,
            500.0
        )

    new_storage =
        storage_step(
            storage,
            5000.0,
            1000.0,
            500.0
        )

    @test new_storage == 5500.0

end

println("All Hydrogen Rail tests passed.")
What this architecture lets you build

The really powerful version would connect the components like this:

                    ┌──────────────────────┐
                    │   RAIL NETWORK       │
                    │ routes / gradients   │
                    │ stations / speeds    │
                    └──────────┬───────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │ TRAIN PHYSICS        │
                    │ mass / drag / grade  │
                    │ acceleration         │
                    └──────────┬───────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │ ENERGY MODEL         │
                    │ kWh / journey        │
                    └──────────┬───────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │ H₂ DEMAND            │
                    │ kg / train / hour    │
                    └──────────┬───────────┘
                               │
                 ┌─────────────┼─────────────┐
                 ▼             ▼             ▼
          ELECTROLYSER      STORAGE       REFUELLING
                 │             │             │
                 └─────────────┼─────────────┘
                               ▼
                    ┌──────────────────────┐
                    │ ELECTRICITY MARKET   │
                    │ £/MWh by hour        │
                    └──────────┬───────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │ JuMP OPTIMISATION    │
                    │                      │
                    │ when to make H₂      │
                    │ when to store H₂      │
                    │ when to refuel       │
                    │ train deployment     │
                    │ electricity purchase │
                    └──────────┬───────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │ ECONOMIC OUTPUT      │
                    │ £/journey            │
                    │ £/train-km           │
                    │ £/passenger-km       │
                    │ £/kg H₂              │
                    │ utilisation           │
                    │ CO₂ comparison       │
                    └──────────────────────┘

The next level would be to add a network-level mixed-integer optimiser that simultaneously decides which hydrogen trains run, their timetable, speeds, refuelling quantities, electrolyser output, storage inventory and electricity purchases, allowing you to compare an entire hydrogen railway against diesel and electrified alternatives on routes such as Jeddah–Riyadh, regional UK routes, or a hypothetical 400 km/h Saudi hydrogen railway.

