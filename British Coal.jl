module RhinoBankCoalProcurement

using Statistics
using Printf

# ============================================================
# RHINOBANK
# BRITISH COAL PROCUREMENT ENGINE
#
# Pure Julia
#
# Purpose:
#   Industrial coal purchasing / procurement optimisation.
#
# Core workflow:
#
#   Demand
#      ↓
#   Specification
#      ↓
#   Supplier offers
#      ↓
#   Quality normalisation
#      ↓
#   Delivered-cost calculation
#      ↓
#   Compliance filtering
#      ↓
#   Supplier scoring
#      ↓
#   Procurement optimisation
#      ↓
#   Purchase recommendation
#
# Designed for:
#   - Industrial buyers
#   - Steel / metals
#   - Cement
#   - Industrial boilers
#   - CHP
#   - Historical / simulation markets
#   - Commodity procurement platforms
#
# NOTE:
# This is procurement and optimisation software.
# It does not perform mining operations.
# ============================================================


# ============================================================
# ENUMS
# ============================================================

@enum CoalType begin
    STEAM_COAL
    COKING_COAL
    PCI_COAL
    ANTHRACITE
    INDUSTRIAL_COAL
end

@enum DeliveryMode begin
    ROAD
    RAIL
    PORT
    BELT
end

@enum ContractType begin
    SPOT
    MONTHLY
    QUARTERLY
    ANNUAL
end


# ============================================================
# BUYER SPECIFICATION
# ============================================================

mutable struct CoalSpecification

    coal_type::CoalType

    required_tonnage_t::Float64

    minimum_gcv_mj_kg::Float64
    maximum_gcv_mj_kg::Float64

    maximum_ash_percent::Float64
    maximum_sulphur_percent::Float64

    maximum_moisture_percent::Float64

    delivery_start::Int
    delivery_end::Int

    destination::Symbol

    maximum_delivered_price_t::Float64

    minimum_supplier_score::Float64
end


# ============================================================
# SUPPLIER
# ============================================================

mutable struct Supplier

    name::Symbol

    country::Symbol

    coal_type::CoalType

    available_tonnage_t::Float64

    gcv_mj_kg::Float64

    ash_percent::Float64

    sulphur_percent::Float64

    moisture_percent::Float64

    base_price_t::Float64

    freight_price_t::Float64

    handling_price_t::Float64

    insurance_price_t::Float64

    carbon_cost_t::Float64

    delivery_days::Int

    reliability::Float64

    quality_score::Float64

    sustainability_score::Float64

    contract_type::ContractType

    delivery_mode::DeliveryMode

    active::Bool
end


# ============================================================
# SUPPLIER OFFER
# ============================================================

struct SupplierOffer

    supplier::Symbol

    offered_tonnage_t::Float64

    commodity_price_t::Float64
    freight_price_t::Float64
    handling_price_t::Float64
    insurance_price_t::Float64
    carbon_cost_t::Float64

    delivered_price_t::Float64

    energy_mwh_t::Float64
    delivered_price_mwh::Float64

    quality_score::Float64
    reliability_score::Float64
    sustainability_score::Float64

    compliant::Bool

    compliance_issues::Vector{Symbol}

    total_score::Float64
end


# ============================================================
# PROCUREMENT RESULT
# ============================================================

struct ProcurementAllocation

    supplier::Symbol
    tonnage_t::Float64
    delivered_price_t::Float64
    energy_mwh_t::Float64
    total_cost::Float64
end


struct ProcurementResult

    required_tonnage_t::Float64
    purchased_tonnage_t::Float64

    total_cost::Float64

    average_price_t::Float64

    total_energy_mwh::Float64

    average_cost_mwh::Float64

    allocations::Vector{ProcurementAllocation}

    rejected_suppliers::Vector{Symbol}

    reason::Symbol
end


# ============================================================
# QUALITY / ENERGY CALCULATION
# ============================================================

function energy_content_mwh_t(
    gcv_mj_kg::Float64
)

    # 1 tonne × GCV MJ/kg
    # = GCV × 1000 MJ
    # = GCV / 3.6 MWh

    return gcv_mj_kg /
           3.6
end


# ============================================================
# QUALITY PENALTIES
# ============================================================

function quality_score(
    supplier::Supplier
)

    score = 100.0

    # Ash
    score -=
        supplier.ash_percent *
        1.5

    # Sulphur
    score -=
        supplier.sulphur_percent *
        5.0

    # Moisture
    score -=
        supplier.moisture_percent *
        0.5

    # Energy bonus
    score +=
        max(
            supplier.gcv_mj_kg -
            20.0,
            0.0
        ) *
        0.8

    return clamp(
        score,
        0.0,
        100.0
    )
end


# ============================================================
# DELIVERED COST
# ============================================================

function delivered_price(
    supplier::Supplier
)

    return supplier.base_price_t +
           supplier.freight_price_t +
           supplier.handling_price_t +
           supplier.insurance_price_t +
           supplier.carbon_cost_t
end


# ============================================================
# PRICE PER UNIT OF ENERGY
# ============================================================

function price_per_mwh(
    supplier::Supplier
)

    energy =
        energy_content_mwh_t(
            supplier.gcv_mj_kg
        )

    return delivered_price(
        supplier
    ) /
    max(
        energy,
        0.001
    )
end


# ============================================================
# COMPLIANCE
# ============================================================

function check_compliance(
    supplier::Supplier,
    spec::CoalSpecification
)

    issues =
        Symbol[]

    if supplier.coal_type !=
       spec.coal_type

        push!(
            issues,
            :WRONG_COAL_TYPE
        )
    end

    if supplier.available_tonnage_t <=
       0.0

        push!(
            issues,
            :NO_AVAILABLE_TONNAGE
        )
    end

    if supplier.gcv_mj_kg <
       spec.minimum_gcv_mj_kg

        push!(
            issues,
            :GCV_TOO_LOW
        )
    end

    if supplier.gcv_mj_kg >
       spec.maximum_gcv_mj_kg

        push!(
            issues,
            :GCV_TOO_HIGH
        )
    end

    if supplier.ash_percent >
       spec.maximum_ash_percent

        push!(
            issues,
            :ASH_TOO_HIGH
        )
    end

    if supplier.sulphur_percent >
       spec.maximum_sulphur_percent

        push!(
            issues,
            :SULPHUR_TOO_HIGH
        )
    end

    if supplier.moisture_percent >
       spec.maximum_moisture_percent

        push!(
            issues,
            :MOISTURE_TOO_HIGH
        )
    end

    if supplier.delivery_days >
       spec.delivery_end

        push!(
            issues,
            :DELIVERY_TOO_LATE
        )
    end

    price =
        delivered_price(
            supplier
        )

    if price >
       spec.maximum_delivered_price_t

        push!(
            issues,
            :PRICE_TOO_HIGH
        )
    end

    return issues
end


# ============================================================
# SUPPLIER OFFER
# ============================================================

function create_offer(
    supplier::Supplier,
    spec::CoalSpecification
)

    issues =
        check_compliance(
            supplier,
            spec
        )

    compliant =
        isempty(issues)

    delivered =
        delivered_price(
            supplier
        )

    energy =
        energy_content_mwh_t(
            supplier.gcv_mj_kg
        )

    price_mwh =
        delivered /
        max(
            energy,
            0.001
        )

    qscore =
        quality_score(
            supplier
        )

    reliability =
        supplier.reliability *
        100.0

    sustainability =
        supplier.sustainability_score

    total =
        supplier_score(
            delivered,
            qscore,
            reliability,
            sustainability,
            spec
        )

    return SupplierOffer(

        supplier.name,

        supplier.available_tonnage_t,

        supplier.base_price_t,

        supplier.freight_price_t,

        supplier.handling_price_t,

        supplier.insurance_price_t,

        supplier.carbon_cost_t,

        delivered,

        energy,

        price_mwh,

        qscore,

        reliability,

        sustainability,

        compliant,

        issues,

        total
    )
end


# ============================================================
# SUPPLIER SCORE
# ============================================================

function supplier_score(
    delivered_price_t,
    quality,
    reliability,
    sustainability,
    spec
)

    price_score =
        max(
            0.0,
            100.0 -
            (
                delivered_price_t /
                max(
                    spec.maximum_delivered_price_t,
                    1.0
                )
            ) *
            100.0
        )

    return (

        0.55 *
        price_score +

        0.20 *
        quality +

        0.15 *
        reliability +

        0.10 *
        sustainability
    )
end


# ============================================================
# OFFER BOOK
# ============================================================

function build_offer_book(
    suppliers::Vector{Supplier},
    spec::CoalSpecification
)

    offers =
        SupplierOffer[]

    for supplier in suppliers

        if !supplier.active
            continue
        end

        offer =
            create_offer(
                supplier,
                spec
            )

        push!(
            offers,
            offer
        )
    end

    return offers
end


# ============================================================
# SORT OFFERS
# ============================================================

function rank_offers(
    offers::Vector{SupplierOffer}
)

    return sort(
        offers;
        by = x -> (
            !x.compliant,
            -x.total_score,
            x.delivered_price_mwh
        )
    )
end


# ============================================================
# SINGLE SUPPLIER PROCUREMENT
# ============================================================

function procure_single_source(
    offers,
    spec
)

    valid =
        [
            o for o in offers
            if o.compliant &&
               o.total_score >=
               spec.minimum_supplier_score
        ]

    isempty(valid) &&
        return nothing

    ranked =
        sort(
            valid;
            by = x ->
                x.delivered_price_mwh
        )

    offer =
        first(ranked)

    quantity =
        min(
            offer.offered_tonnage_t,
            spec.required_tonnage_t
        )

    allocation =
        ProcurementAllocation(

            offer.supplier,

            quantity,

            offer.delivered_price_t,

            quantity *
            offer.energy_mwh_t,

            quantity *
            offer.delivered_price_t
        )

    return ProcurementResult(

        spec.required_tonnage_t,

        quantity,

        allocation.total_cost,

        allocation.delivered_price_t,

        allocation.energy_mwh_t,

        allocation.total_cost /
        max(
            allocation.energy_mwh_t,
            0.001
        ),

        [allocation],

        Symbol[],

        :SINGLE_SOURCE
    )
end


# ============================================================
# MULTI-SOURCE PROCUREMENT
# ============================================================

function procure_multi_source(
    offers,
    spec
)

    valid =
        [
            o for o in offers
            if o.compliant &&
               o.total_score >=
               spec.minimum_supplier_score
        ]

    ranked =
        sort(
            valid;
            by = x ->
                x.delivered_price_mwh
        )

    allocations =
        ProcurementAllocation[]

    remaining =
        spec.required_tonnage_t

    for offer in ranked

        remaining <=
            0.0 &&
            break

        quantity =
            min(
                offer.offered_tonnage_t,
                remaining
            )

        push!(
            allocations,

            ProcurementAllocation(

                offer.supplier,

                quantity,

                offer.delivered_price_t,

                quantity *
                offer.energy_mwh_t,

                quantity *
                offer.delivered_price_t
            )
        )

        remaining -=
            quantity
    end

    purchased =
        sum(
            x.tonnage_t
            for x in allocations
        )

    total_cost =
        sum(
            x.total_cost
            for x in allocations
        )

    total_energy =
        sum(
            x.energy_mwh_t
            for x in allocations
        )

    rejected =
        [
            o.supplier
            for o in offers
            if !o.compliant
        ]

    if purchased <
       spec.required_tonnage_t

        reason =
            :INSUFFICIENT_COMPLIANT_SUPPLY

    else

        reason =
            :MULTI_SOURCE_OPTIMISED
    end

    return ProcurementResult(

        spec.required_tonnage_t,

        purchased,

        total_cost,

        total_cost /
        max(
            purchased,
            0.001
        ),

        total_energy,

        total_cost /
        max(
            total_energy,
            0.001
        ),

        allocations,

        rejected,

        reason
    )
end


# ============================================================
# CONTRACT OPTIMISATION
# ============================================================

function contract_score(
    contract::ContractType
)

    if contract ==
       ANNUAL

        return 1.0

    elseif contract ==
           QUARTERLY

        return 0.90

    elseif contract ==
           MONTHLY

        return 0.75

    else

        return 0.60
    end
end


# ============================================================
# PROCUREMENT WITH CONTRACT PREFERENCE
# ============================================================

function contract_adjusted_price(
    supplier::Supplier
)

    stability_bonus =
        contract_score(
            supplier.contract_type
        )

    return delivered_price(
        supplier
    ) -
    (
        stability_bonus *
        0.5
    )
end


# ============================================================
# PORT / RAIL / ROAD LOGISTICS
# ============================================================

function logistics_cost(
    mode::DeliveryMode,
    distance_km::Float64
)

    if mode ==
       ROAD

        return 0.08 *
               distance_km

    elseif mode ==
           RAIL

        return 0.045 *
               distance_km

    elseif mode ==
           PORT

        return 0.030 *
               distance_km

    elseif mode ==
           BELT

        return 0.010 *
               distance_km
    end

    return 0.0
end


# ============================================================
# INVENTORY MODEL
# ============================================================

mutable struct CoalInventory

    capacity_t::Float64

    current_t::Float64

    safety_stock_t::Float64

    daily_consumption_t::Float64
end


function inventory_days(
    inventory::CoalInventory
)

    return inventory.current_t /
           max(
               inventory.daily_consumption_t,
               0.001
           )
end


function reorder_quantity(
    inventory::CoalInventory,
    target_days::Float64
)

    target =
        target_days *
        inventory.daily_consumption_t

    return max(
        0.0,
        target -
        inventory.current_t
    )
end


# ============================================================
# PROCUREMENT TRIGGER
# ============================================================

function should_procure(
    inventory::CoalInventory
)

    return inventory.current_t <=
           inventory.safety_stock_t
end


# ============================================================
# PURCHASE ORDER
# ============================================================

mutable struct PurchaseOrder

    id::Int

    supplier::Symbol

    coal_type::CoalType

    tonnage_t::Float64

    price_t::Float64

    total_value::Float64

    delivery_mode::DeliveryMode

    contract_type::ContractType

    status::Symbol
end


# ============================================================
# CREATE PURCHASE ORDERS
# ============================================================

function create_purchase_orders(
    result::ProcurementResult,
    suppliers::Vector{Supplier}
)

    orders =
        PurchaseOrder[]

    id =
        1

    for allocation in
        result.allocations

        supplier =
            findfirst(
                x ->
                    x.name ==
                    allocation.supplier,
                suppliers
            )

        supplier === nothing &&
            continue

        s =
            suppliers[supplier]

        push!(
            orders,

            PurchaseOrder(

                id,

                s.name,

                s.coal_type,

                allocation.tonnage_t,

                allocation.delivered_price_t,

                allocation.total_cost,

                s.delivery_mode,

                s.contract_type,

                :PENDING_APPROVAL
            )
        )

        id +=
            1
    end

    return orders
end


# ============================================================
# PROCUREMENT REPORT
# ============================================================

function print_offer(
    offer::SupplierOffer
)

    @printf(
        "%-18s %8.1f t | £%7.2f/t | £%7.2f/MWh | score=%6.1f | %s\n",

        offer.supplier,

        offer.offered_tonnage_t,

        offer.delivered_price_t,

        offer.delivered_price_mwh,

        offer.total_score,

        offer.compliant ?
        "COMPLIANT" :
        "REJECTED"
    )
end


function print_result(
    result::ProcurementResult
)

    println()
    println(
        "=========================================================="
    )

    println(
        "              RHINOBANK COAL PROCUREMENT"
    )

    println(
        "=========================================================="
    )

    @printf(
        "Required tonnage:       %.0f t\n",
        result.required_tonnage_t
    )

    @printf(
        "Purchased tonnage:      %.0f t\n",
        result.purchased_tonnage_t
    )

    @printf(
        "Total procurement:      £%.2f\n",
        result.total_cost
    )

    @printf(
        "Average price:          £%.2f/t\n",
        result.average_price_t
    )

    @printf(
        "Total energy:           %.0f MWh\n",
        result.total_energy_mwh
    )

    @printf(
        "Energy-adjusted cost:   £%.2f/MWh\n",
        result.average_cost_mwh
    )

    println()

    println(
        "ALLOCATIONS"
    )

    for allocation in
        result.allocations

        @printf(
            "  %-18s %8.0f t @ £%.2f/t = £%.2f\n",

            allocation.supplier,

            allocation.tonnage_t,

            allocation.delivered_price_t,

            allocation.total_cost
        )
    end

    println()

    println(
        "Rejected suppliers:"
    )

    if isempty(
        result.rejected_suppliers
    )

        println(
            "  None"
        )

    else

        for supplier in
            result.rejected_suppliers

            println(
                "  ",
                supplier
            )
        end
    end

    println()

    println(
        "Decision:               ",
        result.reason
    )

    println(
        "=========================================================="
    )
end


# ============================================================
# DEMO SUPPLIERS
# ============================================================

function demo_suppliers()

    return Supplier[

        Supplier(

            :YORKSHIRE_COAL,

            :UK,

            STEAM_COAL,

            50000.0,

            24.0,

            8.0,

            0.8,

            8.0,

            82.0,

            18.0,

            3.0,

            1.0,

            2.0,

            3,

            0.94,

            0.90,

            75.0,

            QUARTERLY,

            RAIL,

            true
        ),

        Supplier(

            :NORTH_ENGLAND_FUEL,

            :UK,

            STEAM_COAL,

            30000.0,

            25.0,

            6.0,

            0.6,

            7.0,

            84.0,

            15.0,

            3.0,

            1.0,

            2.0,

            4,

            0.97,

            0.94,

            80.0,

            ANNUAL,

            RAIL,

            true
        ),

        Supplier(

            :MIDLANDS_ENERGY,

            :UK,

            STEAM_COAL,

            40000.0,

            22.0,

            11.0,

            1.1,

            10.0,

            78.0,

            16.0,

            3.0,

            1.0,

            2.0,

            5,

            0.90,

            0.80,

            65.0,

            MONTHLY,

            ROAD,

            true
        ),

        Supplier(

            :IMPORT_TERMINAL,

            :EUROPE,

            STEAM_COAL,

            100000.0,

            26.0,

            5.0,

            0.5,

            6.0,

            75.0,

            12.0,

            4.0,

            1.5,

            2.0,

            7,

            0.96,

            0.95,

            90.0,

            SPOT,

            PORT,

            true
        )
    ]
end


# ============================================================
# DEMO
# ============================================================

function demo()

    specification =
        CoalSpecification(

            STEAM_COAL,

            75000.0,

            23.0,

            27.0,

            9.0,

            1.0,

            9.0,

            1,

            30,

            :YORKSHIRE_PLANT,

            115.0,

            65.0
        )

    suppliers =
        demo_suppliers()

    println()
    println(
        "RHINOBANK PROCUREMENT REQUEST"
    )

    println(
        "=============================================="
    )

    @printf(
        "Coal requirement: %.0f tonnes\n",
        specification.required_tonnage_t
    )

    @printf(
        "GCV: %.1f - %.1f MJ/kg\n",
        specification.minimum_gcv_mj_kg,
        specification.maximum_gcv_mj_kg
    )

    @printf(
        "Maximum ash: %.1f %%\n",
        specification.maximum_ash_percent
    )

    @printf(
        "Maximum sulphur: %.1f %%\n",
        specification.maximum_sulphur_percent
    )

    println()

    offers =
        build_offer_book(
            suppliers,
            specification
        )

    ranked =
        rank_offers(
            offers
        )

    println(
        "SUPPLIER OFFER BOOK"
    )

    println(
        "----------------------------------------------"
    )

    for offer in ranked

        print_offer(
            offer
        )
    end

    println()

    result =
        procure_multi_source(
            offers,
            specification
        )

    print_result(
        result
    )

    orders =
        create_purchase_orders(
            result,
            suppliers
        )

    println()
    println(
        "PURCHASE ORDERS"
    )

    println(
        "----------------------------------------------"
    )

    for order in orders

        @printf(
            "PO-%04d | %-18s | %8.0f t | £%.2f/t | £%.2f | %s\n",

            order.id,

            order.supplier,

            order.tonnage_t,

            order.price_t,

            order.total_value,

            order.status
        )
    end

    return specification,
           suppliers,
           offers,
           result,
           orders
end


end # module


# ============================================================
# RUN
# ============================================================

using .RhinoBankCoalProcurement

RhinoBankCoalProcurement.demo()
