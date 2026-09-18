# Julia Vending Machine Optimisation System

A modular Julia project for simulating and optimising a modern vending machine.

## Project structure

```text
vending_machine_optimizer/
├── Project.toml
├── README.md
├── src/
│   ├── VendingMachineOptimizer.jl
│   ├── products.jl
│   ├── machine.jl
│   ├── inventory.jl
│   ├── demand.jl
│   ├── pricing.jl
│   ├── energy.jl
│   ├── refrigeration.jl
│   ├── payments.jl
│   ├── replenishment.jl
│   ├── simulation.jl
│   ├── economics.jl
│   └── optimisation.jl
├── examples/
│   └── optimise_machine.jl
└── test/
    └── runtests.jl
```

---

## `Project.toml`

```toml
name = "VendingMachineOptimizer"
uuid = "7e0e9d6e-3f72-4e5d-b6d4-1f6b6c8a1234"
authors = ["Vending Optimisation Research"]
version = "0.1.0"

[deps]
Random = "9a3f8284-686f-5f34-9a9f-3a7b1d6c8b6f"
Statistics = "10745b16-90c0-5a5c-9e9b-0d4d5b3a8c6e"
```

---

# Main module

## `src/VendingMachineOptimizer.jl`

```julia
module VendingMachineOptimizer

using Random
using Statistics

include("products.jl")
include("machine.jl")
include("inventory.jl")
include("demand.jl")
include("pricing.jl")
include("energy.jl")
include("refrigeration.jl")
include("payments.jl")
include("replenishment.jl")
include("economics.jl")
include("simulation.jl")
include("optimisation.jl")

export Product
export MachineConfig
export InventoryState
export DemandModel
export SimulationResult
export OptimisationResult

export default_products
export simulate
export optimise_machine
export machine_profit
export inventory_value

end
```

---

# Products

## `src/products.jl`

```julia
struct Product
    name::String
    category::Symbol
    wholesale_price::Float64
    base_price::Float64
    shelf_life_hours::Float64
    refrigerated::Bool
    demand_rate::Float64
    volume_litres::Float64
    width_mm::Float64
    height_mm::Float64
end

function default_products()

    return Product[
        Product(
            "Water",
            :drink,
            0.35,
            1.50,
            8760.0,
            true,
            0.12,
            0.50,
            70.0,
            210.0
        ),

        Product(
            "Cola",
            :drink,
            0.55,
            1.80,
            8760.0,
            true,
            0.10,
            0.50,
            70.0,
            210.0
        ),

        Product(
            "Energy Drink",
            :drink,
            0.75,
            2.50,
            8760.0,
            true,
            0.07,
            0.50,
            70.0,
            210.0
        ),

        Product(
            "Orange Juice",
            :drink,
            0.65,
            2.20,
            240.0,
            true,
            0.045,
            0.33,
            65.0,
            180.0
        ),

        Product(
            "Crisps",
            :snack,
            0.45,
            1.50,
            2160.0,
            false,
            0.08,
            0.10,
            90.0,
            150.0
        ),

        Product(
            "Chocolate",
            :snack,
            0.50,
            1.60,
            1440.0,
            false,
            0.07,
            0.08,
            90.0,
            120.0
        )
    ]
end
```

---

# Machine configuration

## `src/machine.jl`

```julia
struct MachineConfig
    capacity::Int
    slots::Int

    refrigerated::Bool
    target_temperature::Float64

    base_power_watts::Float64
    refrigeration_power_watts::Float64

    payment_fee_fraction::Float64
    electricity_price_kwh::Float64

    daily_rental_cost::Float64
    replenishment_cost::Float64
end
```

---

# Inventory

## `src/inventory.jl`

```julia
struct InventoryState
    quantities::Vector{Int}
    maximums::Vector{Int}
end

function inventory_value(
    inventory::InventoryState,
    products::Vector{Product}
)

    value = 0.0

    for i in eachindex(products)
        value += inventory.quantities[i] *
                 products[i].wholesale_price
    end

    return value
end

function initialise_inventory(
    products::Vector{Product},
    capacity::Int
)

    n = length(products)

    per_slot = max(1, capacity ÷ n)

    quantities = fill(per_slot, n)
    maximums = fill(per_slot, n)

    return InventoryState(
        quantities,
        maximums
    )
end
```

---

# Demand model

## `src/demand.jl`

```julia
struct DemandModel
    hourly_multiplier::Vector{Float64}
    weekend_multiplier::Float64
    temperature_sensitivity::Float64
end

function default_demand_model()

    multipliers = [
        0.25, # 00
        0.20,
        0.15,
        0.12,
        0.15,
        0.30,
        0.55,
        0.80,
        1.00,
        0.90,
        0.85,
        0.90,
        1.00,
        1.05,
        1.00,
        0.95,
        1.05,
        1.25,
        1.35,
        1.20,
        1.00,
        0.80,
        0.55,
        0.35
    ]

    return DemandModel(
        multipliers,
        0.85,
        0.02
    )
end

function demand_probability(
    product::Product,
    model::DemandModel,
    hour::Int;
    weekend::Bool=false,
    temperature::Float64=18.0
)

    h = clamp(hour + 1, 1, 24)

    multiplier = model.hourly_multiplier[h]

    if weekend
        multiplier *= model.weekend_multiplier
    end

    temperature_effect =
        1.0 + model.temperature_sensitivity *
        max(temperature - 18.0, 0.0)

    return clamp(
        product.demand_rate *
        multiplier *
        temperature_effect,
        0.0,
        0.95
    )
end
```

---

# Pricing

## `src/pricing.jl`

```julia
function effective_price(
    product::Product,
    price_multiplier::Float64
)

    return product.base_price * price_multiplier
end

function price_demand_multiplier(
    multiplier::Float64
)

    # Simple elasticity model.

    elasticity = -1.25

    return multiplier ^ elasticity
end
```

---

# Energy model

## `src/energy.jl`

```julia
function base_energy_kwh(
    machine::MachineConfig,
    hours::Float64
)

    return machine.base_power_watts *
           hours /
           1000.0
end

function refrigeration_energy_kwh(
    machine::MachineConfig,
    hours::Float64,
    ambient_temperature::Float64
)

    if !machine.refrigerated
        return 0.0
    end

    temperature_delta =
        max(
            ambient_temperature -
            machine.target_temperature,
            0.0
        )

    load_factor =
        0.25 +
        0.03 * temperature_delta

    return machine.refrigeration_power_watts *
           load_factor *
           hours /
           1000.0
end
```

---

# Refrigeration

## `src/refrigeration.jl`

```julia
function refrigeration_load(
    target_temperature::Float64,
    ambient_temperature::Float64
)

    delta =
        max(
            ambient_temperature -
            target_temperature,
            0.0
        )

    return 0.25 + 0.03 * delta
end

function refrigeration_cost(
    machine::MachineConfig,
    hours::Float64,
    ambient_temperature::Float64
)

    energy =
        refrigeration_energy_kwh(
            machine,
            hours,
            ambient_temperature
        )

    return energy *
           machine.electricity_price_kwh
end
```

---

# Payments

## `src/payments.jl`

```julia
function payment_fee(
    revenue::Float64,
    fee_fraction::Float64
)

    return revenue * fee_fraction
end
```

---

# Replenishment

## `src/replenishment.jl`

```julia
function replenish!(
    inventory::InventoryState,
    products::Vector{Product}
)

    for i in eachindex(inventory.quantities)

        inventory.quantities[i] =
            inventory.maximums[i]

    end

    return inventory
end

function stockout_rate(
    sold::Vector{Int},
    lost::Vector{Int}
)

    total_demand = sum(sold) + sum(lost)

    if total_demand == 0
        return 0.0
    end

    return sum(lost) / total_demand
end
```

---

# Economics

## `src/economics.jl`

```julia
function machine_profit(
    revenue::Float64,
    product_cost::Float64,
    payment_cost::Float64,
    energy_cost::Float64,
    replenishment_cost::Float64,
    fixed_cost::Float64
)

    return revenue -
           product_cost -
           payment_cost -
           energy_cost -
           replenishment_cost -
           fixed_cost
end
```

---

# Simulation result

## `src/simulation.jl`

```julia
struct SimulationResult

    revenue::Float64
    product_cost::Float64
    payment_cost::Float64
    energy_cost::Float64
    replenishment_cost::Float64
    fixed_cost::Float64

    profit::Float64

    units_sold::Int
    stockouts::Int

    utilisation::Float64

    inventory_remaining::Vector{Int}
end
```

---

# Simulation engine

## `src/simulation.jl`

```julia
function simulate(
    machine::MachineConfig,
    products::Vector{Product};
    days::Int=30,
    price_multipliers=ones(length(products)),
    seed::Int=42,
    ambient_temperature::Float64=18.0
)

    rng = MersenneTwister(seed)

    inventory =
        initialise_inventory(
            products,
            machine.capacity
        )

    demand_model =
        default_demand_model()

    revenue = 0.0
    product_cost = 0.0
    payment_cost = 0.0

    units_sold = 0
    stockouts = 0

    replenishments = 0

    for day in 1:days

        weekend =
            day % 7 == 6 ||
            day % 7 == 0

        for hour in 0:23

            for i in eachindex(products)

                product = products[i]

                probability =
                    demand_probability(
                        product,
                        demand_model,
                        hour;
                        weekend=weekend,
                        temperature=ambient_temperature
                    )

                probability *=
                    price_demand_multiplier(
                        price_multipliers[i]
                    )

                if rand(rng) < probability

                    if inventory.quantities[i] > 0

                        inventory.quantities[i] -= 1

                        price =
                            effective_price(
                                product,
                                price_multipliers[i]
                            )

                        revenue += price

                        product_cost +=
                            product.wholesale_price

                        units_sold += 1

                    else

                        stockouts += 1
                    end
                end
            end
        end

        # Automatic replenishment every 7 days.

        if day % 7 == 0

            replenish!(
                inventory,
                products
            )

            replenishments += 1
        end
    end

    energy =
        base_energy_kwh(
            machine,
            days * 24
        ) +
        refrigeration_energy_kwh(
            machine,
            days * 24,
            ambient_temperature
        )

    energy_cost =
        energy *
        machine.electricity_price_kwh

    payment_cost =
        payment_fee(
            revenue,
            machine.payment_fee_fraction
        )

    replenishment_cost =
        replenishments *
        machine.replenishment_cost

    fixed_cost =
        days *
        machine.daily_rental_cost

    profit =
        machine_profit(
            revenue,
            product_cost,
            payment_cost,
            energy_cost,
            replenishment_cost,
            fixed_cost
        )

    utilisation =
        units_sold /
        max(
            1,
            machine.capacity * days
        )

    return SimulationResult(
        revenue,
        product_cost,
        payment_cost,
        energy_cost,
        replenishment_cost,
        fixed_cost,
        profit,
        units_sold,
        stockouts,
        utilisation,
        inventory.quantities
    )
end
```

---

# Optimisation

## `src/optimisation.jl`

```julia
struct OptimisationResult

    capacity::Int
    price_multipliers::Vector{Float64}

    profit::Float64
    revenue::Float64

    units_sold::Int
    stockouts::Int

    simulation::SimulationResult
end
```

The first optimisation layer can search both **machine capacity and product pricing**.

```julia
function optimise_machine(
    products::Vector{Product};
    capacities=20:10:100,
    price_range=0.85:0.05:1.20,
    days::Int=30
)

    best_result = nothing
    best_profit = -Inf

    n = length(products)

    for capacity in capacities

        machine =
            MachineConfig(
                capacity,
                n,
                true,
                4.0,
                30.0,
                180.0,
                0.018,
                0.30,
                4.0,
                8.0
            )

        for multiplier in price_range

            multipliers =
                fill(
                    multiplier,
                    n
                )

            result =
                simulate(
                    machine,
                    products;
                    days=days,
                    price_multipliers=multipliers
                )

            if result.profit > best_profit

                best_profit =
                    result.profit

                best_result =
                    OptimisationResult(
                        capacity,
                        multipliers,
                        result.profit,
                        result.revenue,
                        result.units_sold,
                        result.stockouts,
                        result
                    )
            end
        end
    end

    return best_result
end
```

---

# Example

## `examples/optimise_machine.jl`

```julia
using Pkg

Pkg.activate(joinpath(@__DIR__, ".."))

include(
    joinpath(
        @__DIR__,
        "..",
        "src",
        "VendingMachineOptimizer.jl"
    )
)

using .VendingMachineOptimizer

products =
    default_products()

result =
    optimise_machine(
        products;
        capacities=20:10:100,
        price_range=0.85:0.05:1.20,
        days=30
    )

println("================================")
println("VENDING MACHINE OPTIMISATION")
println("================================")

println("Optimal capacity: ",
        result.capacity)

println("Price multiplier: ",
        result.price_multipliers)

println("Revenue: £",
        round(result.revenue, digits=2))

println("Profit: £",
        round(result.profit, digits=2))

println("Units sold: ",
        result.units_sold)

println("Stockouts: ",
        result.stockouts)

println("Utilisation: ",
        round(
            result.simulation.utilisation * 100,
            digits=2
        ),
        "%")
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
        "VendingMachineOptimizer.jl"
    )
)

using .VendingMachineOptimizer

@testset "Vending Machine Optimizer" begin

    products =
        default_products()

    @test length(products) > 0

    machine =
        MachineConfig(
            60,
            length(products),
            true,
            4.0,
            30.0,
            180.0,
            0.018,
            0.30,
            4.0,
            8.0
        )

    result =
        simulate(
            machine,
            products;
            days=7
        )

    @test result.revenue >= 0
    @test result.product_cost >= 0
    @test result.energy_cost >= 0
    @test result.units_sold >= 0

    @test length(
        result.inventory_remaining
    ) == length(products)
end
```

---

# Running it

From the project directory:

```bash
julia --project=. examples/optimise_machine.jl
```

Run the tests:

```bash
julia --project=. test/runtests.jl
```

# Next-generation version

The interesting part is to turn this from a simple simulator into a **vending-machine digital twin**.

The production architecture would optimise:

```text
                  VENDING MACHINE
                         │
       ┌─────────────────┼─────────────────┐
       │                 │                 │
   CUSTOMER          HARDWARE          ECONOMICS
       │                 │                 │
   Demand              Motors           Revenue
   Time of day         Compressor       Margin
   Weather             Sensors          Payment fees
   Location             LEDs             Electricity
   Events               Cooling         Replenishment
       │                 │                 │
       └─────────────────┼─────────────────┘
                         │
                  JULIA DIGITAL TWIN
                         │
             ┌───────────┼───────────┐
             │           │           │
          Pricing     Inventory    Energy
             │           │           │
             └───────────┼───────────┘
                         │
                    OPTIMISER
                         │
             ┌───────────┼───────────┐
             │           │           │
         What to sell   How much   When to refill
             │           │           │
             └───────────┼───────────┘
                         │
                  PROFIT / SERVICE
```

A much more advanced implementation could optimise **each individual product slot** rather than treating the machine as a single inventory pool.

For example:

```text
Slot 01   Water
Slot 02   Water
Slot 03   Cola
Slot 04   Cola
Slot 05   Energy Drink
Slot 06   Energy Drink
Slot 07   Orange Juice
Slot 08   Crisps
Slot 09   Chocolate
...
```

The optimiser could then ask:

```text
Which products?
How many slots?
What price?
What inventory level?
When should the machine be refilled?
Should refrigeration run harder?
Should the machine enter low-power mode?
What happens if demand changes?
```

For a real commercial system, I would take the next version further into a **Julia vending-machine digital twin + optimisation engine**, with discrete-event customer arrivals, hourly demand forecasting, product-level slot allocation, dynamic pricing, machine faults, refrigeration thermal modelling, payment-method economics, telemetry ingestion, and a JuMP-based mixed-integer optimisation layer.

