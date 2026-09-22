using .PubDynamicPricing

lager = Beer(
    "Premium Lager",
    6.20,       # base price
    1.80,       # cost

    110.0,      # litres currently available
    250.0,      # keg capacity

    180.0,      # historical litres/day
    9.0,        # current litres/hour

    60.0,       # reorder level
    12.0,       # delivery time

    5.00,       # minimum
    7.50        # maximum
)

config = PricingConfig(
    0.40,       # target stock ratio
    0.80,       # inventory sensitivity
    0.40,       # demand sensitivity
    0.10,       # time sensitivity
    0.20,       # maximum movement
    0.35        # smoothing
)

price = price_beer(
    lager,
    config;
    hour=20,
    day_of_week=6
)

println("Recommended price: £", price)








using .PubLivePricing

model = DemandModel(9)

lager = Beer(
    "lager",
    "Premium Lager",

    6.20,       # base price
    1.80,       # cost

    118.0,      # current stock
    250.0,      # keg capacity

    5.50,       # minimum price
    7.50,       # maximum price

    0.20,       # sales/min
    3.5,        # sales/15 min
    14.0,       # sales/hour

    6.20
)


state = PubState(
    now(),
    20,
    15,
    6,
    0.82,       # occupancy
    0.55,       # transaction rate
    1.15        # event multiplier
)


result =
    process_beer!(
        model,
        lager,
        state,
        12.0
    )


println(result.payload)




