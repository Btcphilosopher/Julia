ForecourtPriceOptimizer





module ForecourtPriceOptimizer

using Statistics
using Printf

# ============================================================
# FORECOURT FUEL PRICE OPTIMISATION ENGINE
# Pure Julia
#
# Designed for:
#   - Petrol stations
#   - Diesel stations
#   - Multi-site forecourt groups
#
# Optimises pump price using:
#   wholesale replacement cost
#   crude/refined-product input
#   FX
#   fuel duty
#   VAT
#   transport costs
#   operating costs
#   inventory
#   demand elasticity
#   traffic
#   historical sales
#   target margin
#   price bounds
#
# IMPORTANT:
# This optimiser uses the station's own costs and demand data.
# It does not coordinate pricing with competitors.
# ============================================================


# ============================================================
# FUEL TYPES
# ============================================================

@enum FuelType begin
    PETROL
    DIESEL
    PREMIUM_PETROL
    PREMIUM_DIESEL
end


# ============================================================
# MARKET INPUT
# ============================================================

mutable struct MarketData

    crude_usd_bbl::Float64

    refined_product_usd_bbl::Float64

    gbp_usd::Float64

    biofuel_cost_ppl::Float64

    transport_cost_ppl::Float64

    wholesale_margin_ppl::Float64

    refinery_margin_ppl::Float64

    market_demand_index::Float64

    volatility_index::Float64
end


# ============================================================
# STATION
# ============================================================

mutable struct Forecourt

    name::Symbol

    fuel_type::FuelType

    wholesale_cost_ppl::Float64

    operating_cost_ppl::Float64

    card_payment_cost_ppl::Float64

    other_cost_ppl::Float64

    fuel_duty_ppl::Float64

    vat_rate::Float64

    target_margin_ppl::Float64

    minimum_margin_ppl::Float64

    maximum_margin_ppl::Float64

    minimum_price_ppl::Float64

    maximum_price_ppl::Float64

    tank_capacity_l::Float64

    inventory_l::Float64

    daily_sales_l::Float64

    traffic_index::Float64

    price::Float64
end


# ============================================================
# DEMAND MODEL
# ============================================================

mutable struct DemandModel

    base_daily_volume_l::Float64

    reference_price_ppl::Float64

    elasticity::Float64

    traffic_elasticity::Float64

    market_elasticity::Float64

    seasonality::Float64

    weather_factor::Float64

    event_factor::Float64
end


# ============================================================
# PRICE RESULT
# ============================================================

struct PriceCandidate

    price_ppl::Float64

    ex_vat_price_ppl::Float64

    expected_volume_l::Float64

    expected_revenue::Float64

    expected_gross_profit::Float64

    expected_margin_ppl::Float64

    margin_percent::Float64

    demand_index::Float64
end


struct OptimisationResult

    recommended_price_ppl::Float64

    expected_volume_l::Float64

    expected_revenue::Float64

    expected_profit::Float64

    expected_margin_ppl::Float64

    margin_percent::Float64

    candidates::Vector{PriceCandidate}

    reason::Symbol
end


# ============================================================
# UK TAX MODEL
# ============================================================

function tax_component(
    price_ppl::Float64,
    duty_ppl::Float64,
    vat_rate::Float64
)

    # VAT applies to the sale price including duty.
    return (
        price_ppl -
        (
            price_ppl -
            duty_ppl
        ) /
        (
            1.0 +
            vat_rate
        )
    )
end


function net_of_vat(
    pump_price_ppl::Float64,
    vat_rate::Float64
)

    return pump_price_ppl /
           (
               1.0 +
               vat_rate
           )
end


# ============================================================
# WHOLESALE COST MODEL
# ============================================================

function estimated_wholesale_cost(
    market::MarketData
)

    # Simplified conversion from $/barrel to pence/litre.
    #
    # 1 barrel ≈ 158.987 litres.
    #
    # In production this should be replaced by actual
    # supplier / CIF / rack-price feeds.

    refined_ppl =
        market.refined_product_usd_bbl /
        158.987 *
        100.0 /
        market.gbp_usd

    return refined_ppl +
           market.biofuel_cost_ppl +
           market.transport_cost_ppl +
           market.wholesale_margin_ppl +
           market.refinery_margin_ppl
end


function update_wholesale_cost!(
    station::Forecourt,
    market::MarketData
)

    station.wholesale_cost_ppl =
        estimated_wholesale_cost(
            market
        )

    return station.wholesale_cost_ppl
end


# ============================================================
# DEMAND FUNCTION
# ============================================================

function expected_demand(
    station::Forecourt,
    model::DemandModel,
    price_ppl::Float64,
    market::MarketData
)

    price_ratio =
        price_ppl /
        model.reference_price_ppl

    # Constant elasticity model.
    price_effect =
        price_ratio ^
        model.elasticity

    traffic_effect =
        station.traffic_index ^
        model.traffic_elasticity

    market_effect =
        market.market_demand_index ^
        model.market_elasticity

    demand =
        model.base_daily_volume_l *
        price_effect *
        traffic_effect *
        market_effect *
        model.seasonality *
        model.weather_factor *
        model.event_factor

    return max(
        demand,
        0.0
    )
end


# ============================================================
# INVENTORY CONSTRAINT
# ============================================================

function inventory_adjusted_demand(
    demand_l::Float64,
    station::Forecourt
)

    # Don't forecast sales beyond available stock.
    return min(
        demand_l,
        station.inventory_l
    )
end


# ============================================================
# PROFIT CALCULATION
# ============================================================

function calculate_candidate(
    station::Forecourt,
    model::DemandModel,
    market::MarketData,
    price_ppl::Float64
)

    net_price =
        net_of_vat(
            price_ppl,
            station.vat_rate
        )

    volume =
        expected_demand(
            station,
            model,
            price_ppl,
            market
        )

    volume =
        inventory_adjusted_demand(
            volume,
            station
        )

    total_cost_ppl =
        station.wholesale_cost_ppl +
        station.operating_cost_ppl +
        station.card_payment_cost_ppl +
        station.other_cost_ppl

    margin_ppl =
        net_price -
        station.fuel_duty_ppl -
        total_cost_ppl

    revenue =
        net_price *
        volume

    profit =
        (
            net_price -
            station.fuel_duty_ppl -
            total_cost_ppl
        ) *
        volume

    margin_percent =
        net_price <= 0.0 ?
        0.0 :
        margin_ppl /
        net_price *
        100.0

    demand_index =
        model.base_daily_volume_l <= 0.0 ?
        0.0 :
        volume /
        model.base_daily_volume_l

    return PriceCandidate(
        price_ppl,
        net_price,
        volume,
        revenue,
        profit,
        margin_ppl,
        margin_percent,
        demand_index
    )
end


# ============================================================
# PRICE GRID
# ============================================================

function generate_prices(
    station::Forecourt;
    step_ppl=0.1
)

    prices =
        Float64[]

    price =
        station.minimum_price_ppl

    while price <=
          station.maximum_price_ppl + 1e-9

        push!(
            prices,
            round(
                price,
                digits=2
            )
        )

        price +=
            step_ppl
    end

    return prices
end


# ============================================================
# OPTIMISATION
# ============================================================

function optimise_price(
    station::Forecourt,
    model::DemandModel,
    market::MarketData;
    step_ppl=0.1
)

    candidates =
        PriceCandidate[]

    prices =
        generate_prices(
            station;
            step_ppl=step_ppl
        )

    for price in prices

        candidate =
            calculate_candidate(
                station,
                model,
                market,
                price
            )

        # Don't recommend a price below the
        # station's minimum viable margin.

        if candidate.expected_margin_ppl >=
           station.minimum_margin_ppl

            push!(
                candidates,
                candidate
            )
        end
    end

    if isempty(candidates)

        return OptimisationResult(

            station.minimum_price_ppl,

            0.0,
            0.0,
            0.0,

            0.0,
            0.0,

            PriceCandidate[],

            :NO_VALID_PRICE
        )
    end

    # Maximise expected daily gross profit.
    best =
        argmax(
            c -> c.expected_gross_profit,
            candidates
        )

    return OptimisationResult(

        best.price_ppl,

        best.expected_volume_l,

        best.expected_revenue,

        best.expected_gross_profit,

        best.expected_margin_ppl,

        best.margin_percent,

        candidates,

        :MAXIMUM_EXPECTED_PROFIT
    )
end


# ============================================================
# MARGIN TARGET OPTIMISATION
# ============================================================

function target_margin_price(
    station::Forecourt
)

    required_net =
        station.wholesale_cost_ppl +
        station.operating_cost_ppl +
        station.card_payment_cost_ppl +
        station.other_cost_ppl +
        station.fuel_duty_ppl +
        station.target_margin_ppl

    # Reverse VAT.
    price =
        required_net *
        (
            1.0 +
            station.vat_rate
        )

    return clamp(
        price,
        station.minimum_price_ppl,
        station.maximum_price_ppl
    )
end


# ============================================================
# INVENTORY PRICING
# ============================================================

function inventory_pressure(
    station::Forecourt
)

    return station.inventory_l /
           max(
               station.tank_capacity_l,
               1.0
           )
end


function inventory_price_adjustment(
    station::Forecourt,
    price_ppl::Float64
)

    inventory_fraction =
        inventory_pressure(
            station
        )

    # High inventory:
    # modestly lower price to stimulate volume.
    #
    # Low inventory:
    # modestly increase price to preserve stock.

    if inventory_fraction > 0.80

        return price_ppl -
               1.5

    elseif inventory_fraction < 0.20

        return price_ppl +
               2.0

    end

    return price_ppl
end


# ============================================================
# VOLATILITY BUFFER
# ============================================================

function volatility_buffer(
    market::MarketData
)

    # Prevent excessive sensitivity to temporary
    # market noise.

    return clamp(
        market.volatility_index *
        1.0,
        0.0,
        3.0
    )
end


# ============================================================
# REPLACEMENT-COST PRICING
# ============================================================

function replacement_cost_price(
    station::Forecourt,
    market::MarketData
)

    replacement_cost =
        estimated_wholesale_cost(
            market
        )

    net_required =
        replacement_cost +
        station.operating_cost_ppl +
        station.card_payment_cost_ppl +
        station.other_cost_ppl +
        station.fuel_duty_ppl +
        station.target_margin_ppl

    pump_price =
        net_required *
        (
            1.0 +
            station.vat_rate
        )

    return clamp(
        pump_price,
        station.minimum_price_ppl,
        station.maximum_price_ppl
    )
end


# ============================================================
# FULL PRICING ENGINE
# ============================================================

function optimise_forecourt(
    station::Forecourt,
    model::DemandModel,
    market::MarketData;
    step_ppl=0.1
)

    # Update current replacement cost.
    update_wholesale_cost!(
        station,
        market
    )

    # Economic optimisation.
    result =
        optimise_price(
            station,
            model,
            market;
            step_ppl=step_ppl
        )

    # Replacement-cost price.
    replacement_price =
        replacement_cost_price(
            station,
            market
        )

    # Inventory adjustment.
    adjusted_price =
        inventory_price_adjustment(
            station,
            result.recommended_price_ppl
        )

    # Volatility protection.
    buffer =
        volatility_buffer(
            market
        )

    # Blend the optimised economic price with
    # replacement-cost pricing.
    blended_price =
        0.70 *
        adjusted_price +

        0.30 *
        replacement_price

    # If market volatility is high, avoid
    # making an unnecessarily large immediate move.
    current =
        station.price

    maximum_move =
        3.0 +
        buffer

    blended_price =
        clamp(
            blended_price,
            current -
            maximum_move,
            current +
            maximum_move
        )

    final_price =
        clamp(
            blended_price,
            station.minimum_price_ppl,
            station.maximum_price_ppl
        )

    # Recalculate economics at final price.
    final =
        calculate_candidate(
            station,
            model,
            market,
            final_price
        )

    return OptimisationResult(

        final_price,

        final.expected_volume_l,

        final.expected_revenue,

        final.expected_gross_profit,

        final.expected_margin_ppl,

        final.margin_percent,

        result.candidates,

        :HYBRID_PROFIT_REPLACEMENT_COST
    )
end


# ============================================================
# UPDATE PRICE
# ============================================================

function apply_price!(
    station::Forecourt,
    result::OptimisationResult
)

    station.price =
        result.recommended_price_ppl

    return station.price
end


# ============================================================
# HISTORICAL DEMAND
# ============================================================

mutable struct SalesObservation

    price_ppl::Float64
    volume_l::Float64
    traffic_index::Float64
end


function estimate_elasticity(
    observations::Vector{SalesObservation}
)

    if length(observations) < 3

        return -0.5
    end

    prices =
        [
            log(
                max(
                    x.price_ppl,
                    0.01
                )
            )
            for x in observations
        ]

    volumes =
        [
            log(
                max(
                    x.volume_l,
                    0.01
                )
            )
            for x in observations
        ]

    xbar =
        mean(prices)

    ybar =
        mean(volumes)

    numerator =
        sum(
            (
                prices[i] -
                xbar
            ) *
            (
                volumes[i] -
                ybar
            )
            for i in eachindex(prices)
        )

    denominator =
        sum(
            (
                prices[i] -
                xbar
            )^2
            for i in eachindex(prices)
        )

    denominator <= 0.0 &&
        return -0.5

    elasticity =
        numerator /
        denominator

    # Keep the model within a reasonable range.
    return clamp(
        elasticity,
        -5.0,
        -0.01
    )
end


# ============================================================
# FORECAST NEXT DAY
# ============================================================

function forecast_volume(
    station::Forecourt,
    model::DemandModel,
    market::MarketData,
    price_ppl::Float64
)

    return expected_demand(
        station,
        model,
        price_ppl,
        market
    )
end


# ============================================================
# SCENARIO ANALYSIS
# ============================================================

function scenario_analysis(
    station::Forecourt,
    model::DemandModel,
    market::MarketData
)

    scenarios =
        Dict{Symbol,Float64}(
            :BASE => 1.0,
            :LOW_DEMAND => 0.85,
            :HIGH_DEMAND => 1.15,
            :SUPPLY_STRESS => 0.70,
            :OVERSUPPLY => 1.25
        )

    results =
        Dict{Symbol,OptimisationResult}()

    original =
        market.market_demand_index

    for (name, multiplier)
        in scenarios

        market.market_demand_index =
            original *
            multiplier

        results[name] =
            optimise_forecourt(
                station,
                model,
                market
            )
    end

    market.market_demand_index =
        original

    return results
end


# ============================================================
# REPORT
# ============================================================

function print_report(
    station::Forecourt,
    result::OptimisationResult,
    market::MarketData
)

    println()
    println(
        "=========================================================="
    )

    println(
        "             FORECOURT PRICE OPTIMISER"
    )

    println(
        "=========================================================="
    )

    println(
        "Site:                   ",
        station.name
    )

    println(
        "Fuel:                   ",
        station.fuel_type
    )

    @printf(
        "Crude benchmark:        $%.2f/bbl\n",
        market.crude_usd_bbl
    )

    @printf(
        "Refined product:        $%.2f/bbl\n",
        market.refined_product_usd_bbl
    )

    @printf(
        "GBP/USD:                %.4f\n",
        market.gbp_usd
    )

    @printf(
        "Wholesale cost:         %.2f ppl\n",
        station.wholesale_cost_ppl
    )

    @printf(
        "Fuel duty:              %.2f ppl\n",
        station.fuel_duty_ppl
    )

    @printf(
        "VAT:                    %.1f %%\n",
        station.vat_rate * 100
    )

    println()
    println(
        "PRICING"
    )

    @printf(
        "Current price:          %.1f ppl\n",
        station.price
    )

    @printf(
        "Recommended price:      %.1f ppl\n",
        result.recommended_price_ppl
    )

    @printf(
        "Price change:           %+.1f ppl\n",
        result.recommended_price_ppl -
        station.price
    )

    @printf(
        "Expected volume:        %.0f L/day\n",
        result.expected_volume_l
    )

    @printf(
        "Expected revenue:       £%.2f/day\n",
        result.expected_revenue / 100.0
    )

    @printf(
        "Expected gross profit:  £%.2f/day\n",
        result.expected_profit / 100.0
    )

    @printf(
        "Expected margin:        %.2f ppl\n",
        result.expected_margin_ppl
    )

    @printf(
        "Margin percentage:      %.2f %%\n",
        result.margin_percent
    )

    println()
    println(
        "INVENTORY"
    )

    @printf(
        "Tank inventory:         %.0f L\n",
        station.inventory_l
    )

    @printf(
        "Tank utilisation:       %.1f %%\n",
        inventory_pressure(
            station
        ) * 100
    )

    println()
    println(
        "OPTIMISATION MODE:      ",
        result.reason
    )

    println(
        "=========================================================="
    )
end


# ============================================================
# EXAMPLE DATA
# ============================================================

function create_demo()

    station =
        Forecourt(

            :YORKSHIRE_FORECOURT,

            PETROL,

            90.0,

            4.0,

            1.2,

            1.0,

            52.95,

            0.20,

            8.0,

            4.0,

            20.0,

            125.0,

            190.0,

            60000.0,

            35000.0,

            12000.0,

            1.0,

            155.0
        )

    market =
        MarketData(

            92.0,

            105.0,

            1.34,

            4.0,

            2.0,

            1.5,

            1.0,

            1.0,

            0.5
        )

    demand =
        DemandModel(

            12000.0,

            155.0,

            -0.8,

            0.4,

            0.3,

            1.0,

            1.0,

            1.0
        )

    return station,
           market,
           demand
end


# ============================================================
# DEMO
# ============================================================

function demo()

    station,
    market,
    demand =
        create_demo()

    result =
        optimise_forecourt(
            station,
            demand,
            market;
            step_ppl=0.1
        )

    print_report(
        station,
        result,
        market
    )

    println()

    println(
        "SCENARIO ANALYSIS"
    )

    scenarios =
        scenario_analysis(
            station,
            demand,
            market
        )

    for (name, result)
        in scenarios

        @printf(
            "%-18s %.1f ppl | %.0f L/day | £%.2f profit/day\n",

            name,

            result.recommended_price_ppl,

            result.expected_volume_l,

            result.expected_profit / 100.0
        )
    end

    apply_price!(
        station,
        result
    )

    return station,
           market,
           demand,
           result
end


end # module


# ============================================================
# RUN
# ============================================================

using .ForecourtPriceOptimizer

ForecourtPriceOptimizer.demo()
