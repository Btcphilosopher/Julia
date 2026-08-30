module BurgerChainAutomation

using Statistics
using Printf
using Dates

# ============================================================
# BURGER CHAIN COOKING / KITCHEN AUTOMATION ENGINE
# Pure Julia
#
# Models:
#   - Grill temperature
#   - Patty specifications
#   - Cooking profiles
#   - Individual burger state
#   - Core temperature
#   - Time/temperature exposure
#   - Batch cooking
#   - Order queue
#   - Grill capacity
#   - Cook-time optimisation
#   - Holding time
#   - Waste
#   - Throughput
#   - HACCP-style critical control monitoring
#
# Safety principle:
#   Safety limits are HARD CONSTRAINTS.
#   The throughput optimiser cannot override them.
#
# Commercial deployment requires validated cooking processes,
# HACCP procedures, calibrated probes and site-specific testing.
# ============================================================


# ============================================================
# ENUMS
# ============================================================

@enum BurgerState begin
    RAW
    COOKING
    RESTING
    READY
    HELD
    SERVED
    DISCARDED
    FAULT
end

@enum GrillMode begin
    OFF
    PREHEATING
    READY_GRILL
    COOKING_GRILL
    FAULT_GRILL
end


# ============================================================
# BURGER SPECIFICATION
# ============================================================

mutable struct BurgerSpec

    name::Symbol

    patty_mass_g::Float64
    patty_thickness_mm::Float64

    target_core_temperature_c::Float64
    target_hold_seconds::Float64

    grill_temperature_c::Float64

    nominal_cook_seconds::Float64

    maximum_cook_seconds::Float64

    rest_seconds::Float64

    maximum_hold_seconds::Float64
end


# ============================================================
# BURGER
# ============================================================

mutable struct Burger

    id::Int

    specification::Symbol

    state::BurgerState

    mass_g::Float64
    thickness_mm::Float64

    surface_temperature_c::Float64
    core_temperature_c::Float64

    cook_seconds::Float64

    validated_hold_seconds::Float64

    total_time_seconds::Float64

    order_id::Int

    grill_id::Int

    quality_score::Float64

    safety_verified::Bool

    discard_reason::Symbol
end


# ============================================================
# GRILL
# ============================================================

mutable struct Grill

    id::Int

    mode::GrillMode

    target_temperature_c::Float64
    surface_temperature_c::Float64

    heating_rate_c_s::Float64
    cooling_rate_c_s::Float64

    positions::Int

    occupied_positions::Int

    total_cooking_seconds::Float64

    burgers_cooked::Int

    faults::Vector{Symbol}
end


# ============================================================
# ORDER
# ============================================================

mutable struct Order

    id::Int

    quantity::Int

    specification::Symbol

    created_at::DateTime

    promised_seconds::Float64

    completed::Bool

    burgers::Vector{Int}
end


# ============================================================
# KITCHEN
# ============================================================

mutable struct Kitchen

    specifications::Dict{Symbol,BurgerSpec}

    burgers::Dict{Int,Burger}

    grills::Vector{Grill}

    orders::Dict{Int,Order}

    queue::Vector{Int}

    next_burger_id::Int
    next_order_id::Int

    elapsed_seconds::Float64

    burgers_served::Int
    burgers_discarded::Int

    total_cooking_seconds::Float64
    total_energy_estimate_kwh::Float64

    safety_events::Vector{Symbol}

    emergency_stop::Bool
end


# ============================================================
# BURGER SPECIFICATION
# ============================================================

function create_standard_burger()

    return BurgerSpec(

        :STANDARD_BEEF,

        120.0,

        15.0,

        70.0,

        120.0,

        210.0,

        300.0,

        480.0,

        30.0,

        600.0
    )
end


function create_thick_burger()

    return BurgerSpec(

        :THICK_BEEF,

        180.0,

        22.0,

        70.0,

        120.0,

        215.0,

        420.0,

        600.0,

        45.0,

        600.0
    )
end


# ============================================================
# GRILL
# ============================================================

function create_grill(
    id;
    positions=8,
    target_temperature_c=210.0
)

    return Grill(

        id,

        OFF,

        target_temperature_c,

        20.0,

        0.8,
        0.12,

        positions,

        0,

        0.0,

        0,

        Symbol[]
    )
end


# ============================================================
# KITCHEN
# ============================================================

function create_kitchen()

    specifications =
        Dict{Symbol,BurgerSpec}()

    standard =
        create_standard_burger()

    thick =
        create_thick_burger()

    specifications[
        standard.name
    ] = standard

    specifications[
        thick.name
    ] = thick

    grills =
        Grill[
            create_grill(
                1;
                positions=8
            ),

            create_grill(
                2;
                positions=8
            )
        ]

    return Kitchen(

        specifications,

        Dict{Int,Burger}(),

        grills,

        Dict{Int,Order}(),

        Int[],

        1,
        1,

        0.0,

        0,
        0,

        0.0,
        0.0,

        Symbol[],

        false
    )
end


# ============================================================
# GRILL PREHEATING
# ============================================================

function start_grill!(
    grill::Grill
)

    if grill.mode ==
       FAULT_GRILL

        return false
    end

    grill.mode =
        PREHEATING

    return true
end


function update_grill!(
    grill::Grill,
    dt::Float64
)

    if grill.mode ==
       OFF

        return
    end

    if grill.mode ==
       PREHEATING ||
       grill.mode ==
       READY_GRILL ||
       grill.mode ==
       COOKING_GRILL

        if grill.surface_temperature_c <
           grill.target_temperature_c

            grill.surface_temperature_c +=
                grill.heating_rate_c_s *
                dt

        else

            grill.surface_temperature_c -=
                grill.cooling_rate_c_s *
                dt
        end
    end

    grill.surface_temperature_c =
        clamp(
            grill.surface_temperature_c,
            0.0,
            400.0
        )

    if abs(
        grill.surface_temperature_c -
        grill.target_temperature_c
    ) < 5.0

        grill.mode =
            READY_GRILL
    end
end


# ============================================================
# ORDER CREATION
# ============================================================

function create_order!(
    kitchen::Kitchen,
    specification::Symbol,
    quantity::Int;
    promised_seconds=900.0
)

    haskey(
        kitchen.specifications,
        specification
    ) ||
        error(
            "Unknown burger specification"
        )

    order =
        Order(

            kitchen.next_order_id,

            quantity,

            specification,

            now(),

            promised_seconds,

            false,

            Int[]
        )

    kitchen.orders[
        order.id
    ] = order

    kitchen.next_order_id += 1

    push!(
        kitchen.queue,
        order.id
    )

    return order.id
end


# ============================================================
# BURGER CREATION
# ============================================================

function create_burger!(
    kitchen::Kitchen,
    order::Order
)

    spec =
        kitchen.specifications[
            order.specification
        ]

    burger =
        Burger(

            kitchen.next_burger_id,

            spec.name,

            RAW,

            spec.patty_mass_g,

            spec.patty_thickness_mm,

            5.0,

            5.0,

            0.0,

            0.0,

            0.0,

            order.id,

            0,

            100.0,

            false,

            :NONE
        )

    kitchen.burgers[
        burger.id
    ] = burger

    kitchen.next_burger_id += 1

    push!(
        order.burgers,
        burger.id
    )

    return burger.id
end


# ============================================================
# FILL ORDER
# ============================================================

function prepare_order_burgers!(
    kitchen::Kitchen,
    order::Order
)

    while length(order.burgers) <
          order.quantity

        create_burger!(
            kitchen,
            order
        )
    end
end


# ============================================================
# THERMAL MODEL
# ============================================================

function heat_transfer_rate(
    burger::Burger,
    grill_temperature_c::Float64
)

    # Simplified lumped thermal model.
    #
    # Production systems should use experimentally
    # validated cooking curves for the exact patty,
    # grill, loading pattern and equipment.

    surface =
        grill_temperature_c

    core =
        burger.core_temperature_c

    delta =
        max(
            surface -
            core,
            0.0
        )

    thickness_factor =
        15.0 /
        max(
            burger.thickness_mm,
            1.0
        )

    mass_factor =
        120.0 /
        max(
            burger.mass_g,
            1.0
        )

    rate =
        0.035 *
        delta *
        thickness_factor *
        mass_factor

    return rate
end


# ============================================================
# PLACE BURGER ON GRILL
# ============================================================

function place_on_grill!(
    kitchen::Kitchen,
    burger_id::Int,
    grill::Grill
)

    burger =
        kitchen.burgers[
            burger_id
        ]

    if burger.state !=
       RAW

        return false
    end

    if grill.mode !=
       READY_GRILL &&
       grill.mode !=
       COOKING_GRILL

        return false
    end

    if grill.occupied_positions >=
       grill.positions

        return false
    end

    burger.state =
        COOKING

    burger.grill_id =
        grill.id

    burger.surface_temperature_c =
        grill.surface_temperature_c

    grill.occupied_positions +=
        1

    grill.mode =
        COOKING_GRILL

    return true
end


# ============================================================
# COOK BURGER
# ============================================================

function update_burger!(
    kitchen::Kitchen,
    burger::Burger,
    grill::Grill,
    dt::Float64
)

    if burger.state !=
       COOKING

        return
    end

    spec =
        kitchen.specifications[
            burger.specification
        ]

    burger.surface_temperature_c =
        grill.surface_temperature_c

    rate =
        heat_transfer_rate(
            burger,
            grill.surface_temperature_c
        )

    burger.core_temperature_c +=
        rate *
        dt

    burger.core_temperature_c =
        min(
            burger.core_temperature_c,
            grill.surface_temperature_c
        )

    burger.cook_seconds +=
        dt

    burger.total_time_seconds +=
        dt

    grill.total_cooking_seconds +=
        dt

    kitchen.total_cooking_seconds +=
        dt

    # --------------------------------------------------------
    # Critical safety condition
    # --------------------------------------------------------

    if burger.core_temperature_c >=
       spec.target_core_temperature_c

        burger.validated_hold_seconds +=
            dt

    else

        burger.validated_hold_seconds =
            0.0
    end

    # --------------------------------------------------------
    # Safety completion
    # --------------------------------------------------------

    if burger.validated_hold_seconds >=
       spec.target_hold_seconds

        burger.safety_verified =
            true

        burger.state =
            RESTING

        grill.occupied_positions =
            max(
                0,
                grill.occupied_positions - 1
            )

    elseif burger.cook_seconds >
           spec.maximum_cook_seconds

        burger.state =
            FAULT

        burger.discard_reason =
            :COOKING_TIMEOUT

        kitchen.burgers_discarded +=
            1

        grill.occupied_positions =
            max(
                0,
                grill.occupied_positions - 1
            )
    end
end


# ============================================================
# RESTING
# ============================================================

function update_resting!(
    kitchen::Kitchen,
    burger::Burger,
    dt::Float64
)

    if burger.state !=
       RESTING

        return
    end

    spec =
        kitchen.specifications[
            burger.specification
        ]

    burger.total_time_seconds +=
        dt

    if burger.total_time_seconds >=
       (
           burger.cook_seconds +
           spec.rest_seconds
       )

        burger.state =
            READY

        burger.quality_score =
            calculate_quality(
                kitchen,
                burger
            )
    end
end


# ============================================================
# QUALITY MODEL
# ============================================================

function calculate_quality(
    kitchen::Kitchen,
    burger::Burger
)

    spec =
        kitchen.specifications[
            burger.specification
        ]

    score =
        100.0

    # Overcooking penalty.
    if burger.cook_seconds >
       spec.nominal_cook_seconds

        excess =
            burger.cook_seconds -
            spec.nominal_cook_seconds

        score -=
            excess *
            0.05
    end

    # Very high temperature penalty.
    if burger.core_temperature_c > 80.0

        score -=
            (
                burger.core_temperature_c -
                80.0
            ) *
            1.0
    end

    return clamp(
        score,
        0.0,
        100.0
    )
end


# ============================================================
# HOLDING
# ============================================================

function place_in_hold!(
    kitchen::Kitchen,
    burger::Burger
)

    if burger.state !=
       READY

        return false
    end

    burger.state =
        HELD

    return true
end


# ============================================================
# SERVE
# ============================================================

function serve_burger!(
    kitchen::Kitchen,
    burger::Burger
)

    if burger.state !=
       READY &&
       burger.state !=
       HELD

        return false
    end

    if !burger.safety_verified

        push!(
            kitchen.safety_events,
            :UNVERIFIED_BURGER_BLOCKED
        )

        return false
    end

    burger.state =
        SERVED

    kitchen.burgers_served +=
        1

    return true
end


# ============================================================
# HOLD TIME
# ============================================================

function check_hold_time!(
    kitchen::Kitchen,
    burger::Burger
)

    if burger.state !=
       HELD

        return
    end

    spec =
        kitchen.specifications[
            burger.specification
        ]

    hold_time =
        burger.total_time_seconds -
        burger.cook_seconds

    if hold_time >
       spec.maximum_hold_seconds

        burger.state =
            DISCARDED

        burger.discard_reason =
            :HOLD_TIME_EXCEEDED

        kitchen.burgers_discarded +=
            1
    end
end


# ============================================================
# GRILL SAFETY
# ============================================================

function grill_safety_check!(
    kitchen::Kitchen,
    grill::Grill
)

    if grill.surface_temperature_c >
       grill.target_temperature_c +
       50.0

        grill.mode =
            FAULT_GRILL

        push!(
            grill.faults,
            :OVER_TEMPERATURE
        )

        push!(
            kitchen.safety_events,
            :GRILL_OVER_TEMPERATURE
        )

        return false
    end

    return true
end


# ============================================================
# QUEUE DISPATCH
# ============================================================

function dispatch_queue!(
    kitchen::Kitchen
)

    for grill in kitchen.grills

        if grill.mode ==
           OFF

            continue
        end

        if grill.mode ==
           PREHEATING

            continue
        end

        available =
            grill.positions -
            grill.occupied_positions

        available <=
            0 &&
            continue

        for order_id in
            kitchen.queue

            order =
                kitchen.orders[
                    order_id
                ]

            prepare_order_burgers!(
                kitchen,
                order
            )

            for burger_id in
                order.burgers

                burger =
                    kitchen.burgers[
                        burger_id
                    ]

                if burger.state ==
                   RAW

                    if place_on_grill!(
                        kitchen,
                        burger_id,
                        grill
                    )

                        available -=
                            1

                        available <=
                            0 &&
                            break
                    end
                end
            end

            available <=
                0 &&
                break
        end
    end
end


# ============================================================
# AUTOMATIC SERVING
# ============================================================

function fulfil_orders!(
    kitchen::Kitchen
)

    for order in
        values(kitchen.orders)

        all_ready =
            true

        for burger_id in
            order.burgers

            burger =
                kitchen.burgers[
                    burger_id
                ]

            if burger.state ==
               READY ||
               burger.state ==
               HELD

                continue
            end

            all_ready =
                false

            break
        end

        if all_ready &&
           !order.completed

            for burger_id in
                order.burgers

                serve_burger!(
                    kitchen,
                    kitchen.burgers[
                        burger_id
                    ]
                )
            end

            order.completed =
                true
        end
    end
end


# ============================================================
# MAIN SIMULATION STEP
# ============================================================

function update!(
    kitchen::Kitchen,
    dt::Float64
)

    if kitchen.emergency_stop

        return
    end

    kitchen.elapsed_seconds +=
        dt

    # --------------------------------------------------------
    # Grills
    # --------------------------------------------------------

    for grill in
        kitchen.grills

        update_grill!(
            grill,
            dt
        )

        grill_safety_check!(
            kitchen,
            grill
        )
    end

    # --------------------------------------------------------
    # Queue
    # --------------------------------------------------------

    dispatch_queue!(
        kitchen
    )

    # --------------------------------------------------------
    # Burgers
    # --------------------------------------------------------

    for burger in
        values(kitchen.burgers)

        if burger.state ==
           COOKING

            grill =
                findfirst(
                    g ->
                        g.id ==
                        burger.grill_id,
                    kitchen.grills
                )

            grill === nothing &&
                continue

            update_burger!(
                kitchen,
                burger,
                kitchen.grills[
                    grill
                ],
                dt
            )

        elseif burger.state ==
               RESTING

            update_resting!(
                kitchen,
                burger,
                dt
            )

        elseif burger.state ==
               HELD

            burger.total_time_seconds +=
                dt

            check_hold_time!(
                kitchen,
                burger
            )
        end
    end

    fulfil_orders!(
        kitchen
    )

    # --------------------------------------------------------
    # Energy estimate
    # --------------------------------------------------------

    for grill in
        kitchen.grills

        if grill.mode ==
           COOKING_GRILL ||
           grill.mode ==
           READY_GRILL

            estimated_kw =
                8.0 *
                (
                    grill.surface_temperature_c /
                    max(
                        grill.target_temperature_c,
                        1.0
                    )
                )

            kitchen.total_energy_estimate_kwh +=
                estimated_kw *
                dt /
                3600.0
        end
    end
end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(
    kitchen::Kitchen,
    reason::Symbol
)

    kitchen.emergency_stop =
        true

    push!(
        kitchen.safety_events,
        reason
    )

    for grill in
        kitchen.grills

        grill.mode =
            OFF

        grill.occupied_positions =
            0
    end

    for burger in
        values(kitchen.burgers)

        if burger.state ==
           COOKING

            burger.state =
                FAULT

            burger.discard_reason =
                :EMERGENCY_STOP
        end
    end
end


# ============================================================
# PERFORMANCE METRICS
# ============================================================

function throughput(
    kitchen::Kitchen
)

    if kitchen.elapsed_seconds <=
       0.0

        return 0.0
    end

    return kitchen.burgers_served /
           (
               kitchen.elapsed_seconds /
               3600.0
           )
end


function waste_rate(
    kitchen::Kitchen
)

    total =
        kitchen.burgers_served +
        kitchen.burgers_discarded

    total == 0 &&
        return 0.0

    return kitchen.burgers_discarded /
           total *
           100.0
end


# ============================================================
# KITCHEN REPORT
# ============================================================

function print_report(
    kitchen::Kitchen
)

    println()
    println(
        "=========================================================="
    )

    println(
        "             BURGER CHAIN COOKING ENGINE"
    )

    println(
        "=========================================================="
    )

    @printf(
        "Runtime:                 %.1f min\n",
        kitchen.elapsed_seconds / 60
    )

    @printf(
        "Burgers served:          %d\n",
        kitchen.burgers_served
    )

    @printf(
        "Burgers discarded:       %d\n",
        kitchen.burgers_discarded
    )

    @printf(
        "Throughput:              %.1f burgers/hour\n",
        throughput(kitchen)
    )

    @printf(
        "Waste rate:              %.2f %%\n",
        waste_rate(kitchen)
    )

    @printf(
        "Energy estimate:         %.2f kWh\n",
        kitchen.total_energy_estimate_kwh
    )

    println()

    println(
        "GRILLS"
    )

    for grill in
        kitchen.grills

        @printf(
            "Grill %d: %-15s %.1f°C | %d/%d positions\n",

            grill.id,

            grill.mode,

            grill.surface_temperature_c,

            grill.occupied_positions,

            grill.positions
        )
    end

    println()

    println(
        "SAFETY EVENTS"
    )

    if isempty(
        kitchen.safety_events
    )

        println(
            "  NONE"
        )

    else

        for event in
            unique(
                kitchen.safety_events
            )

            println(
                "  ⚠ ",
                event
            )
        end
    end

    println(
        "=========================================================="
    )
end


# ============================================================
# DEMO
# ============================================================

function demo()

    kitchen =
        create_kitchen()

    # Start both grills.
    for grill in
        kitchen.grills

        start_grill!(
            grill
        )
    end

    # Create a realistic order burst.
    create_order!(
        kitchen,
        :STANDARD_BEEF,
        10;
        promised_seconds=600.0
    )

    create_order!(
        kitchen,
        :STANDARD_BEEF,
        8;
        promised_seconds=600.0
    )

    create_order!(
        kitchen,
        :THICK_BEEF,
        4;
        promised_seconds=900.0
    )

    # Simulate 20 minutes.
    timestep =
        1.0

    steps =
        Int(
            20 * 60 /
            timestep
        )

    for _ in 1:steps

        update!(
            kitchen,
            timestep
        )

        kitchen.emergency_stop &&
            break
    end

    print_report(
        kitchen
    )

    return kitchen
end


end # module


# ============================================================
# RUN
# ============================================================

using .BurgerChainAutomation

BurgerChainAutomation.demo()
