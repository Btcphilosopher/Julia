# Julia Self-Checkout Optimiser

```text
self_checkout_optimizer/
│
├── Project.toml
├── src/
│   ├── SelfCheckoutOptimizer.jl
│   ├── customer.jl
│   ├── checkout.jl
│   ├── queue.jl
│   ├── scanning.jl
│   ├── payment.jl
│   ├── interventions.jl
│   ├── staffing.jl
│   ├── simulation.jl
│   └── optimisation.jl
│
├── data/
│   └── store_profiles.csv
│
├── examples/
│   └── optimise_store.jl
│
└── test/
    └── runtests.jl
```

# 1. Project

## `Project.toml`

```toml
name = "SelfCheckoutOptimizer"
uuid = "7f3b2c81-1d72-4a9e-91a7-6c2d50001001"
authors = ["Retail Systems Research"]
version = "0.1.0"

[compat]
julia = "1.10"
```

# 2. Main module

## `src/SelfCheckoutOptimizer.jl`

```julia
module SelfCheckoutOptimizer

include("customer.jl")
include("checkout.jl")
include("queue.jl")
include("scanning.jl")
include("payment.jl")
include("interventions.jl")
include("staffing.jl")
include("simulation.jl")
include("optimisation.jl")

export
    Customer,
    CheckoutMachine,
    StoreProfile,
    SimulationResult,
    STANDARD_MACHINE,
    simulate_store,
    optimise_store

end
```

# 3. Customer model

## `src/customer.jl`

```julia
struct Customer

    items::Int

    basket_type::Symbol

    scanning_speed::Float64

    payment_time::Float64

    intervention_probability::Float64

end


function customer_service_time(
    customer::Customer
)

    scanning =
        customer.items /
        customer.scanning_speed

    return (
        scanning +
        customer.payment_time
    )

end
```

Different customers can therefore have different behaviour:

```julia
fast_customer =
    Customer(
        8,
        :small,
        0.8,
        20.0,
        0.04
    )

large_shop =
    Customer(
        65,
        :large,
        0.55,
        35.0,
        0.12
    )
```

# 4. Checkout hardware

## `src/checkout.jl`

```julia
struct CheckoutMachine

    scan_time::Float64

    payment_time::Float64

    bagging_time::Float64

    screen_response::Float64

    reliability::Float64

    max_queue::Int

end


const STANDARD_MACHINE =
    CheckoutMachine(
        2.2,
        18.0,
        0.8,
        0.4,
        0.995,
        20
    )
```

# 5. Scanning

## `src/scanning.jl`

```julia
function scan_time(
    items::Int,
    machine::CheckoutMachine
)

    return items *
        (
            machine.scan_time +
            machine.screen_response
        )

end


function scanning_error_probability(
    items,
    base_error
)

    return clamp(
        base_error *
        sqrt(items),
        0.0,
        0.8
    )

end
```

The model can distinguish between:

```text
single item
small basket
medium basket
large basket
```

rather than assuming every transaction behaves identically.

# 6. Payment

## `src/payment.jl`

```julia
function payment_duration(
    payment_type::Symbol
)

    if payment_type == :contactless

        return 8.0

    elseif payment_type == :chip

        return 20.0

    elseif payment_type == :cash

        return 35.0

    elseif payment_type == :mobile

        return 10.0

    else

        return 20.0

    end

end


function payment_failure_probability(
    payment_type::Symbol
)

    if payment_type == :contactless
        return 0.005
    elseif payment_type == :chip
        return 0.008
    elseif payment_type == :cash
        return 0.015
    else
        return 0.006
    end

end
```

# 7. Intervention model

## `src/interventions.jl`

```julia
struct Intervention

    probability::Float64

    resolution_time::Float64

end


function expected_intervention_time(
    intervention::Intervention
)

    return (
        intervention.probability *
        intervention.resolution_time
    )

end


function intervention_cost(
    probability,
    resolution_time
)

    return (
        probability *
        resolution_time
    )

end
```

Examples include:

```text
age verification
unexpected item
barcode failure
payment problem
bagging issue
restricted product
machine fault
customer assistance
```

The model treats these as operational events rather than attempting to identify customers personally.

# 8. Queue model

## `src/queue.jl`

```julia
struct QueueState

    waiting::Int

    active::Int

    completed::Int

    abandoned::Int

end


function queue_wait(
    arrival_time,
    service_start
)

    return max(
        0.0,
        service_start -
        arrival_time
    )

end


function utilisation(
    arrival_rate,
    service_rate,
    machines
)

    return (
        arrival_rate /
        (
            service_rate *
            machines
        )
    )

end
```

# 9. Staffing

## `src/staffing.jl`

```julia
struct StaffingProfile

    staff_count::Int

    intervention_rate::Float64

    response_time::Float64

    staff_cost_per_hour::Float64

end


function staff_capacity(
    staff::StaffingProfile
)

    return (
        staff.staff_count /
        staff.response_time
    )

end


function staffing_cost(
    staff::StaffingProfile,
    hours
)

    return (
        staff.staff_count *
        staff.staff_cost_per_hour *
        hours
    )

end
```

# 10. Store model

```julia
struct StoreProfile

    checkout_count::Int

    customers_per_hour::Float64

    average_items::Float64

    item_variance::Float64

    opening_hours::Float64

    staffing::StaffingProfile

end
```

# 11. Simulation

## `src/simulation.jl`

```julia
struct SimulationResult

    customers_processed::Int

    average_wait_seconds::Float64

    median_wait_seconds::Float64

    p95_wait_seconds::Float64

    average_transaction_seconds::Float64

    intervention_count::Int

    abandoned_customers::Int

    machine_utilisation::Float64

    staff_utilisation::Float64

    total_staff_cost::Float64

    estimated_operating_cost::Float64

end
```

A simple deterministic simulation:

```julia
function simulate_store(
    store::StoreProfile,
    machine::CheckoutMachine;
    simulation_hours=1.0,
    seed=42
)

    Random.seed!(seed)

    customers =
        Int(round(
            store.customers_per_hour *
            simulation_hours
        ))

    service_times =
        Float64[]

    wait_times =
        Float64[]

    interventions =
        0

    current_time =
        zeros(
            store.checkout_count
        )

    for i in 1:customers

        items =
            max(
                1,
                round(
                    Int,
                    randn() *
                    sqrt(
                        store.item_variance
                    ) +
                    store.average_items
                )
            )

        scanning =
            items *
            (
                machine.scan_time +
                machine.screen_response
            )

        payment =
            machine.payment_time

        bagging =
            items *
            machine.bagging_time

        service =
            scanning +
            payment +
            bagging

        customer =
            Customer(
                items,
                :mixed,
                1.0,
                payment,
                0.05
            )

        shortest =
            argmin(current_time)

        arrival =
            (i - 1) /
            store.customers_per_hour *
            3600.0

        start =
            max(
                arrival,
                current_time[shortest]
            )

        wait =
            start - arrival

        finish =
            start + service

        current_time[shortest] =
            finish

        push!(
            service_times,
            service
        )

        push!(
            wait_times,
            wait
        )

        if rand() <
            customer.intervention_probability

            interventions += 1

        end

    end

    sort!(
        wait_times
    )

    average_wait =
        isempty(wait_times) ?
        0.0 :
        sum(wait_times) /
        length(wait_times)

    median_wait =
        isempty(wait_times) ?
        0.0 :
        wait_times[
            cld(length(wait_times), 2)
        ]

    p95_index =
        max(
            1,
            ceil(
                Int,
                0.95 *
                length(wait_times)
            )
        )

    p95_wait =
        isempty(wait_times) ?
        0.0 :
        wait_times[p95_index]

    average_transaction =
        isempty(service_times) ?
        0.0 :
        sum(service_times) /
        length(service_times)

    utilisation =
        sum(current_time) /
        (
            store.checkout_count *
            simulation_hours *
            3600.0
        )

    staff_utilisation =
        min(
            1.0,
            interventions *
            store.staffing.response_time /
            (
                store.staffing.staff_count *
                simulation_hours *
                3600.0
            )
        )

    staff_cost =
        staffing_cost(
            store.staffing,
            simulation_hours
        )

    operating_cost =
        staff_cost +
        interventions * 0.05

    return SimulationResult(
        customers,
        average_wait,
        median_wait,
        p95_wait,
        average_transaction,
        interventions,
        0,
        utilisation,
        staff_utilisation,
        staff_cost,
        operating_cost
    )

end
```

Because this uses `Random`, add:

```julia
using Random
```

at the top of `simulation.jl`.

# 12. Optimisation engine

The optimiser can vary:

```text
number of checkout machines
staffing level
scan speed
payment speed
intervention response time
```

and find configurations that reduce queueing without simply throwing unlimited machines and staff at the problem.

## `src/optimisation.jl`

```julia
function store_objective(
    result::SimulationResult
)

    waiting_cost =
        result.average_wait_seconds *
        0.02

    p95_cost =
        result.p95_wait_seconds *
        0.01

    intervention_cost =
        result.intervention_count *
        0.20

    utilisation_penalty =
        max(
            0.0,
            result.machine_utilisation -
            0.85
        ) *
        100.0

    staff_penalty =
        max(
            0.0,
            result.staff_utilisation -
            0.90
        ) *
        100.0

    return (
        waiting_cost +
        p95_cost +
        intervention_cost +
        result.total_staff_cost +
        utilisation_penalty +
        staff_penalty
    )

end
```

Then search the design space:

```julia
function optimise_store(
    base_store::StoreProfile,
    machine::CheckoutMachine
)

    best_score =
        Inf

    best_store =
        nothing

    best_result =
        nothing

    for machines in
        4:1:30

        for staff_count in
            1:1:8

            store =
                StoreProfile(
                    machines,
                    base_store.customers_per_hour,
                    base_store.average_items,
                    base_store.item_variance,
                    base_store.opening_hours,
                    StaffingProfile(
                        staff_count,
                        base_store.staffing.intervention_rate,
                        base_store.staffing.response_time,
                        base_store.staffing.staff_cost_per_hour
                    )
                )

            result =
                simulate_store(
                    store,
                    machine
                )

            score =
                store_objective(
                    result
                )

            if score < best_score

                best_score =
                    score

                best_store =
                    store

                best_result =
                    result

            end

        end
    end

    return (
        store=best_store,
        result=best_result,
        score=best_score
    )

end
```

# 13. Example store

## `examples/optimise_store.jl`

```julia
using Pkg

Pkg.activate(
    joinpath(
        @__DIR__,
        ".."
    )
)

using .SelfCheckoutOptimizer

staff =
    StaffingProfile(
        3,
        0.05,
        30.0,
        14.0
    )

store =
    StoreProfile(
        10,
        600.0,
        12.0,
        30.0,
        16.0,
        staff
    )

result =
    optimise_store(
        store,
        STANDARD_MACHINE
    )

println()
println(
    "SELF-CHECKOUT OPTIMISATION"
)
println(
    "=========================="
)

println()

println(
    "Optimised checkout count: ",
    result.store.checkout_count
)

println(
    "Optimised staff count: ",
    result.store.staffing.staff_count
)

println()

println(
    "Customers processed: ",
    result.result.customers_processed
)

println(
    "Average wait: ",
    result.result.average_wait_seconds,
    " seconds"
)

println(
    "Median wait: ",
    result.result.median_wait_seconds,
    " seconds"
)

println(
    "95th percentile wait: ",
    result.result.p95_wait_seconds,
    " seconds"
)

println(
    "Average transaction: ",
    result.result.average_transaction_seconds,
    " seconds"
)

println(
    "Interventions: ",
    result.result.intervention_count
)

println(
    "Machine utilisation: ",
    result.result.machine_utilisation
)

println(
    "Staff utilisation: ",
    result.result.staff_utilisation
)

println(
    "Operating cost: £",
    result.result.estimated_operating_cost
)
```

# 14. Tests

## `test/runtests.jl`

```julia
using Test

include("../src/SelfCheckoutOptimizer.jl")

using .SelfCheckoutOptimizer

@testset "Customer" begin

    customer =
        Customer(
            10,
            :small,
            1.0,
            20.0,
            0.05
        )

    @test customer_service_time(
        customer
    ) > 0

end


@testset "Queue" begin

    @test queue_wait(
        10.0,
        25.0
    ) == 15.0

    @test queue_wait(
        30.0,
        25.0
    ) == 0.0

end


@testset "Store simulation" begin

    staff =
        StaffingProfile(
            2,
            0.05,
            30.0,
            14.0
        )

    store =
        StoreProfile(
            8,
            300.0,
            10.0,
            20.0,
            1.0,
            staff
        )

    result =
        simulate_store(
            store,
            STANDARD_MACHINE
        )

    @test result.customers_processed > 0

    @test result.average_wait_seconds >= 0

    @test result.p95_wait_seconds >=
        result.median_wait_seconds

end


@testset "Optimisation" begin

    staff =
        StaffingProfile(
            2,
            0.05,
            30.0,
            14.0
        )

    store =
        StoreProfile(
            8,
            300.0,
            10.0,
            20.0,
            1.0,
            staff
        )

    result =
        optimise_store(
            store,
            STANDARD_MACHINE
        )

    @test result.store !== nothing
    @test result.result !== nothing
end
```

# 15. What I would add for a serious retail optimiser

The simple version above is useful for demonstrating the architecture, but the interesting production model would become a **digital twin of the checkout area**.

```text
                    CUSTOMER ARRIVALS
                           │
                           ▼
                  ┌─────────────────┐
                  │  QUEUE MODEL    │
                  └────────┬────────┘
                           │
             ┌─────────────┼─────────────┐
             ▼             ▼             ▼
          SCO 1          SCO 2         SCO N
             │             │             │
             └─────────────┼─────────────┘
                           ▼
                    PAYMENT SYSTEM
                           │
                           ▼
                    EXIT / COMPLETE
```

Julia could optimise:

### Customer flow

```text
arrival rate
basket size
scanning speed
payment method
service-time distribution
queue abandonment
```

### Machine performance

```text
scanner latency
screen latency
payment latency
barcode failure
printer failure
bagging events
machine downtime
```

### Staff

```text
staff numbers
staff location
intervention response time
simultaneous interventions
peak-period staffing
```

### Store layout

```text
number of machines
machine spacing
entrance position
exit position
queue geometry
staff station location
```

### Economics

```text
labour cost
machine cost
maintenance
electricity
lost sales from queue abandonment
customer waiting cost
```

The optimiser could then run something closer to:

```text
               HISTORICAL STORE DATA
                        │
                        ▼
                Julia Digital Twin
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
       8 tills        10 tills      12 tills
          │             │             │
          ▼             ▼             ▼
       simulate       simulate       simulate
          │             │             │
          └─────────────┼─────────────┘
                        ▼
                  COST FUNCTION
                        │
                        ▼
                OPTIMAL CONFIGURATION
```

And rather than only doing a grid search, I would eventually use **JuMP** for constrained optimisation and a discrete-event simulation layer for realistic queues. The resulting system could optimise an entire supermarket's checkout operation by **time of day**, e.g. different machine/staff configurations for 07:00, lunchtime, 17:00 peak, evening and weekends.

For a real deployment, customer analytics should use aggregate operational statistics rather than unnecessary identification or tracking of individual shoppers.

