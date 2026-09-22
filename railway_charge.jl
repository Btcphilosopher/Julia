module RailwayPowerOptimizer

using LinearAlgebra
using Statistics
using Random

# ============================================================
# 1. TRAIN STATE
# ============================================================

struct TrainState
    speed::Float64              # m/s
    acceleration::Float64       # m/s²
    gradient::Float64           # %
    mass::Float64               # kg
    passengers::Float64
    line_voltage::Float64       # V
    previous_power::Float64     # W
    previous_current::Float64   # A
end


# ============================================================
# 2. POWER SYSTEM PARAMETERS
# ============================================================

struct PowerSystem
    nominal_voltage::Float64
    minimum_voltage::Float64
    maximum_voltage::Float64

    maximum_current::Float64
    maximum_power::Float64

    transformer_resistance::Float64
    line_resistance::Float64

    efficiency::Float64
end


# ============================================================
# 3. OPTIMISER PARAMETERS
# ============================================================

struct OptimizerConfig
    horizon::Int

    timestep::Float64

    # Objective weights
    current_weight::Float64
    ramp_weight::Float64
    peak_weight::Float64
    prediction_weight::Float64
    voltage_weight::Float64

    # Regularisation
    l1_regularisation::Float64
    l2_regularisation::Float64

    # Search resolution
    current_step::Float64

    # Minimum traction requirement
    minimum_traction_power::Float64
end


# ============================================================
# 4. FEATURE ENGINEERING
# ============================================================

function state_features(
    state::TrainState
)

    return [
        state.speed,
        state.acceleration,
        state.gradient,
        state.mass / 100000.0,
        state.passengers / 1000.0,
        state.line_voltage / 10000.0,
        state.previous_power / 1e6,
        state.previous_current / 1000.0
    ]

end


# ============================================================
# 5. LIGHTWEIGHT ML POWER PREDICTOR
#
# A small feed-forward neural network.
# In production this could be replaced with Flux.jl,
# MLJ.jl, or a recurrent/transformer model.
# ============================================================

mutable struct PowerPredictor

    W1::Matrix{Float64}
    b1::Vector{Float64}

    W2::Matrix{Float64}
    b2::Vector{Float64}

    W3::Matrix{Float64}
    b3::Vector{Float64}

end


function create_predictor(
    input_size::Int,
    hidden1::Int = 32,
    hidden2::Int = 16
)

    return PowerPredictor(

        randn(hidden1, input_size) .* 0.05,
        zeros(hidden1),

        randn(hidden2, hidden1) .* 0.05,
        zeros(hidden2),

        randn(1, hidden2) .* 0.05,
        zeros(1)

    )

end


function relu(x)

    return max.(x, 0.0)

end


function predict(
    model::PowerPredictor,
    x::Vector{Float64}
)

    h1 = relu.(model.W1 * x .+ model.b1)

    h2 = relu.(model.W2 * h1 .+ model.b2)

    output = model.W3 * h2 .+ model.b3

    return max(output[1], 0.0)

end


# ============================================================
# 6. TRACTION PHYSICS
# ============================================================

function required_traction_power(
    state::TrainState
)

    g = 9.81

    # Approximate gravitational component
    grade_force =
        state.mass *
        g *
        (state.gradient / 100.0)

    # Approximate acceleration force
    acceleration_force =
        state.mass *
        state.acceleration

    # Simplified rolling resistance
    rolling_force =
        0.0015 *
        state.mass *
        g

    # Simplified aerodynamic resistance
    aero_force =
        0.0006 *
        state.speed^2

    total_force =
        grade_force +
        acceleration_force +
        rolling_force +
        aero_force

    power =
        max(total_force * state.speed, 0.0)

    return power

end


# ============================================================
# 7. ELECTRICAL MODEL
# ============================================================

function current_from_power(
    power::Float64,
    voltage::Float64,
    efficiency::Float64
)

    if voltage <= 0
        return Inf
    end

    return power / (voltage * efficiency)

end


function cable_voltage(
    current::Float64,
    system::PowerSystem
)

    resistance =
        system.transformer_resistance +
        system.line_resistance

    voltage_drop =
        current * resistance

    return system.nominal_voltage - voltage_drop

end


# ============================================================
# 8. POWER LOSS
# ============================================================

function electrical_loss(
    current::Float64,
    system::PowerSystem
)

    resistance =
        system.transformer_resistance +
        system.line_resistance

    return current^2 * resistance

end


# ============================================================
# 9. OBJECTIVE FUNCTION
# ============================================================

function objective(
    current::Float64,
    previous_current::Float64,
    predicted_power::Float64,
    actual_required_power::Float64,
    system::PowerSystem,
    config::OptimizerConfig
)

    voltage =
        cable_voltage(current, system)

    power =
        current *
        voltage *
        system.efficiency

    # --------------------------------------------------------
    # Current minimisation
    # --------------------------------------------------------

    current_cost =
        config.current_weight *
        current^2

    # --------------------------------------------------------
    # Current smoothness
    # --------------------------------------------------------

    ramp_cost =
        config.ramp_weight *
        (current - previous_current)^2

    # --------------------------------------------------------
    # ML prediction tracking
    # --------------------------------------------------------

    prediction_cost =
        config.prediction_weight *
        (
            (power - predicted_power)^2
            / 1e12
        )

    # --------------------------------------------------------
    # Voltage regulation
    # --------------------------------------------------------

    voltage_error =
        voltage - system.nominal_voltage

    voltage_cost =
        config.voltage_weight *
        voltage_error^2

    # --------------------------------------------------------
    # L1 regularisation
    #
    # Encourages unnecessary current to collapse toward zero.
    # --------------------------------------------------------

    l1 =
        config.l1_regularisation *
        abs(current)

    # --------------------------------------------------------
    # L2 regularisation
    #
    # Prevents extreme solutions.
    # --------------------------------------------------------

    l2 =
        config.l2_regularisation *
        current^2

    # --------------------------------------------------------
    # Peak/current penalty
    # --------------------------------------------------------

    peak_cost =
        config.peak_weight *
        (current / system.maximum_current)^4

    # --------------------------------------------------------
    # Total
    # --------------------------------------------------------

    return (
        current_cost +
        ramp_cost +
        prediction_cost +
        voltage_cost +
        l1 +
        l2 +
        peak_cost
    )

end


# ============================================================
# 10. CONSTRAINT CHECKING
# ============================================================

function feasible_current(
    current::Float64,
    state::TrainState,
    required_power::Float64,
    system::PowerSystem,
    config::OptimizerConfig
)

    # Current constraint
    if current < 0
        return false
    end

    if current > system.maximum_current
        return false
    end

    # Cable voltage
    voltage =
        cable_voltage(current, system)

    if voltage < system.minimum_voltage
        return false
    end

    if voltage > system.maximum_voltage
        return false
    end

    # Electrical power actually delivered
    power =
        current *
        voltage *
        system.efficiency

    # Must provide required traction power
    if power < required_power
        return false
    end

    # Maximum infrastructure power
    if power > system.maximum_power
        return false
    end

    return true

end


# ============================================================
# 11. ONE-STEP OPTIMISATION
# ============================================================

function optimise_current(
    state::TrainState,
    predicted_power::Float64,
    system::PowerSystem,
    config::OptimizerConfig
)

    required_power =
        max(
            required_traction_power(state),
            config.minimum_traction_power
        )

    best_current =
        state.previous_current

    best_cost =
        Inf

    current =
        0.0

    while current <= system.maximum_current

        if feasible_current(
            current,
            state,
            required_power,
            system,
            config
        )

            cost =
                objective(
                    current,
                    state.previous_current,
                    predicted_power,
                    required_power,
                    system,
                    config
                )

            if cost < best_cost

                best_cost = cost
                best_current = current

            end

        end

        current += config.current_step

    end

    return best_current

end


# ============================================================
# 12. CONVERT OPTIMAL CURRENT TO POWER
# ============================================================

function optimal_power(
    current::Float64,
    system::PowerSystem
)

    voltage =
        cable_voltage(current, system)

    return (
        current *
        voltage *
        system.efficiency
    )

end


# ============================================================
# 13. MAIN OPTIMISATION STEP
# ============================================================

function optimise_train_power(
    state::TrainState,
    predictor::PowerPredictor,
    system::PowerSystem,
    config::OptimizerConfig
)

    features =
        state_features(state)

    predicted_power =
        predict(
            predictor,
            features
        )

    required_power =
        required_traction_power(state)

    optimal_current =
        optimise_current(
            state,
            predicted_power,
            system,
            config
        )

    delivered_power =
        optimal_power(
            optimal_current,
            system
        )

    voltage =
        cable_voltage(
            optimal_current,
            system
        )

    return (
        predicted_power = predicted_power,
        required_power = required_power,
        optimal_current = optimal_current,
        delivered_power = delivered_power,
        line_voltage = voltage,
        electrical_loss =
            electrical_loss(
                optimal_current,
                system
            )
    )

end


end # module







using .RailwayPowerOptimizer

state = TrainState(

    25.0,       # speed: 25 m/s
    0.35,       # acceleration
    1.2,        # 1.2% gradient

    280_000.0,  # train mass

    650.0,      # passengers

    25_000.0,   # line voltage

    2.1e6,      # previous power
    100.0       # previous current
)


system = PowerSystem(

    25_000.0,   # nominal voltage
    20_000.0,   # minimum
    27_500.0,   # maximum

    1_500.0,    # maximum current
    30e6,       # maximum power

    0.015,      # transformer resistance
    0.025,      # overhead/line resistance

    0.94        # traction efficiency
)


config = OptimizerConfig(

    20,         # prediction horizon

    0.1,        # 100 ms timestep

    1.0,        # current minimisation
    4.0,        # current ramp penalty
    8.0,        # peak penalty
    2.0,        # ML prediction penalty
    0.2,        # voltage penalty

    0.01,       # L1 regularisation
    0.001,      # L2 regularisation

    5.0,        # current search step

    100_000.0   # minimum traction power
)


predictor =
    create_predictor(8)


result =
    optimise_train_power(
        state,
        predictor,
        system,
        config
    )

println("Predicted power: ",
        result.predicted_power / 1e6,
        " MW")

println("Required power: ",
        result.required_power / 1e6,
        " MW")

println("Optimal current: ",
        result.optimal_current,
        " A")

println("Delivered power: ",
        result.delivered_power / 1e6,
        " MW")

println("Line voltage: ",
        result.line_voltage,
        " V")

println("Electrical loss: ",
        result.electrical_loss / 1000,
        " kW")
        
        
        
        
        function adaptive_regularisation(
    speed,
    acceleration,
    gradient,
    voltage,
    nominal_voltage
)

    voltage_stress =
        abs(voltage - nominal_voltage) /
        nominal_voltage

    traction_stress =
        abs(acceleration)

    # Increase smoothing when the electrical system
    # is becoming stressed.
    λ_ramp =
        2.0 +
        20.0 * voltage_stress +
        5.0 * traction_stress

    # Increase current penalty during low-demand operation.
    λ_current =
        if abs(acceleration) < 0.05
            4.0
        else
            1.0
        end

    return λ_current, λ_ramp

end



module MultiTrainRailPower

using LinearAlgebra
using Statistics

# ============================================================
# TRAIN
# ============================================================

struct Train
    id::Int

    position::Float64          # m
    speed::Float64             # m/s
    acceleration::Float64      # m/s²

    mass::Float64               # kg
    gradient::Float64           # %

    max_traction_power::Float64
    max_regen_power::Float64

    traction_efficiency::Float64
    regen_efficiency::Float64
end


# ============================================================
# ELECTRICAL SECTION
# ============================================================

struct ElectricalSection

    nominal_voltage::Float64
    minimum_voltage::Float64

    substation_voltage::Float64

    maximum_substation_current::Float64

    line_resistance_per_km::Float64

    transformer_resistance::Float64

    maximum_regenerative_power::Float64
end


# ============================================================
# OPTIMISER
# ============================================================

struct NetworkOptimizer

    timestep::Float64

    horizon::Int

    current_step::Float64

    # Objective weights
    traction_weight::Float64
    current_weight::Float64
    peak_weight::Float64
    voltage_weight::Float64
    ramp_weight::Float64
    regeneration_weight::Float64

    # Safety margins
    voltage_margin::Float64
    current_margin::Float64
end


# ============================================================
# TRAIN PHYSICS
# ============================================================

function mechanical_power(train::Train)

    g = 9.81

    gravity =
        train.mass *
        g *
        train.gradient / 100.0

    acceleration =
        train.mass *
        train.acceleration

    rolling =
        train.mass *
        g *
        0.0015

    aerodynamic =
        0.0006 *
        train.speed^2

    force =
        gravity +
        acceleration +
        rolling +
        aerodynamic

    return force * train.speed

end


# ============================================================
# TRAIN ELECTRICAL DEMAND
# ============================================================

function traction_power(train::Train)

    mechanical =
        mechanical_power(train)

    if mechanical <= 0

        return 0.0

    end

    return min(
        mechanical /
        train.traction_efficiency,

        train.max_traction_power
    )

end


# ============================================================
# REGENERATIVE BRAKING
# ============================================================

function regenerative_power(train::Train)

    mechanical =
        mechanical_power(train)

    # Negative mechanical demand means
    # braking opportunity.
    if mechanical >= 0

        return 0.0

    end

    braking_power =
        abs(mechanical) *
        train.regen_efficiency

    return min(
        braking_power,
        train.max_regen_power
    )

end


# ============================================================
# ELECTRICAL DISTANCE
# ============================================================

function electrical_resistance(
    train::Train,
    section::ElectricalSection
)

    return (
        train.position / 1000.0
    ) *
    section.line_resistance_per_km +
    section.transformer_resistance

end


# ============================================================
# INITIAL POWER STATE
# ============================================================

function train_power_state(train::Train)

    traction =
        traction_power(train)

    regen =
        regenerative_power(train)

    # Positive = consuming power
    # Negative = returning power

    return traction - regen

end


# ============================================================
# NETWORK POWER BALANCE
# ============================================================

function network_power(
    trains::Vector{Train}
)

    total = 0.0

    for train in trains

        total +=
            train_power_state(train)

    end

    return total

end


# ============================================================
# REGENERATIVE ENERGY AVAILABILITY
# ============================================================

function available_regeneration(
    trains::Vector{Train}
)

    total = 0.0

    for train in trains

        total +=
            regenerative_power(train)

    end

    return total

end


# ============================================================
# NETWORK VOLTAGE
# ============================================================

function estimate_section_voltage(
    trains::Vector{Train},
    section::ElectricalSection
)

    power =
        network_power(trains)

    if power <= 0

        return section.nominal_voltage

    end

    current =
        power /
        section.nominal_voltage

    resistance =
        section.transformer_resistance

    for train in trains

        resistance +=
            electrical_resistance(
                train,
                section
            )

    end

    voltage_drop =
        current * resistance

    return (
        section.substation_voltage -
        voltage_drop
    )

end


# ============================================================
# SUBSTATION CURRENT
# ============================================================

function substation_current(
    trains::Vector{Train},
    section::ElectricalSection
)

    power =
        network_power(trains)

    voltage =
        max(
            estimate_section_voltage(
                trains,
                section
            ),
            1.0
        )

    return power / voltage

end


# ============================================================
# REGENERATION COORDINATION
# ============================================================

function distribute_regenerative_energy(
    trains::Vector{Train},
    section::ElectricalSection
)

    consumers = Train[]

    braking = Train[]

    for train in trains

        if traction_power(train) > 0

            push!(
                consumers,
                train
            )

        elseif regenerative_power(train) > 0

            push!(
                braking,
                train
            )

        end

    end

    total_demand = 0.0

    for train in consumers

        total_demand +=
            traction_power(train)

    end

    total_regen = 0.0

    for train in braking

        total_regen +=
            regenerative_power(train)

    end

    usable_regen =
        min(
            total_regen,
            total_demand,
            section.maximum_regenerative_power
        )

    if total_regen <= 0

        return 0.0, 0.0

    end

    wasted_regen =
        total_regen -
        usable_regen

    return usable_regen, wasted_regen

end


# ============================================================
# ENERGY OBJECTIVE
# ============================================================

function network_objective(
    trains::Vector{Train},
    section::ElectricalSection,
    optimiser::NetworkOptimizer,
    previous_current::Float64
)

    voltage =
        estimate_section_voltage(
            trains,
            section
        )

    current =
        substation_current(
            trains,
            section
        )

    usable_regen,
    wasted_regen =
        distribute_regenerative_energy(
            trains,
            section
        )

    # --------------------------------------------------------
    # Current penalty
    # --------------------------------------------------------

    current_cost =
        optimiser.current_weight *
        current^2

    # --------------------------------------------------------
    # Peak demand penalty
    # --------------------------------------------------------

    peak_ratio =
        current /
        section.maximum_substation_current

    peak_cost =
        optimiser.peak_weight *
        peak_ratio^4

    # --------------------------------------------------------
    # Voltage penalty
    # --------------------------------------------------------

    voltage_error =
        section.nominal_voltage -
        voltage

    voltage_cost =
        optimiser.voltage_weight *
        voltage_error^2

    # --------------------------------------------------------
    # Current ramp penalty
    # --------------------------------------------------------

    ramp_cost =
        optimiser.ramp_weight *
        (current - previous_current)^2

    # --------------------------------------------------------
    # Reward useful regeneration
    # --------------------------------------------------------

    regeneration_reward =
        optimiser.regeneration_weight *
        usable_regen

    # --------------------------------------------------------
    # Penalise wasted regeneration
    # --------------------------------------------------------

    regeneration_waste =
        optimiser.regeneration_weight *
        2.0 *
        wasted_regen

    return (
        current_cost +
        peak_cost +
        voltage_cost +
        ramp_cost +
        regeneration_waste -
        regeneration_reward
    )

end


# ============================================================
# NETWORK CONSTRAINT CHECK
# ============================================================

function network_feasible(
    trains::Vector{Train},
    section::ElectricalSection
)

    voltage =
        estimate_section_voltage(
            trains,
            section
        )

    current =
        substation_current(
            trains,
            section
        )

    if voltage <
       section.minimum_voltage

        return false

    end

    if current >
       section.maximum_substation_current

        return false

    end

    return true

end


# ============================================================
# TRAIN ACCELERATION CONTROL
# ============================================================

function modify_acceleration(
    train::Train,
    multiplier::Float64
)

    return Train(

        train.id,

        train.position,
        train.speed,

        train.acceleration *
        multiplier,

        train.mass,
        train.gradient,

        train.max_traction_power,
        train.max_regen_power,

        train.traction_efficiency,
        train.regen_efficiency
    )

end


# ============================================================
# NETWORK SEARCH
#
# Searches combinations of train power-control factors.
#
# 1.0 = requested acceleration
# <1 = softer acceleration
# >1 = stronger acceleration
# ============================================================

function optimise_network(
    trains::Vector{Train},
    section::ElectricalSection,
    optimiser::NetworkOptimizer,
    previous_current::Float64
)

    best_trains =
        copy(trains)

    best_cost =
        Inf

    multipliers = [
        0.50,
        0.60,
        0.70,
        0.80,
        0.90,
        1.00
    ]

    n =
        length(trains)

    # --------------------------------------------------------
    # Recursive search over train acceleration combinations.
    # --------------------------------------------------------

    candidate =
        copy(trains)

    function search!(
        index::Int
    )

        if index > n

            if network_feasible(
                candidate,
                section
            )

                cost =
                    network_objective(
                        candidate,
                        section,
                        optimiser,
                        previous_current
                    )

                if cost < best_cost

                    best_cost = cost

                    best_trains =
                        copy(candidate)

                end

            end

            return

        end

        original =
            trains[index]

        for multiplier in multipliers

            candidate[index] =
                modify_acceleration(
                    original,
                    multiplier
                )

            search!(
                index + 1
            )

        end

        candidate[index] =
            original

    end

    search!(1)

    return best_trains, best_cost

end


# ============================================================
# NETWORK REPORT
# ============================================================

function network_report(
    trains::Vector{Train},
    section::ElectricalSection
)

    total_consumption = 0.0
    total_regeneration = 0.0

    println()
    println("==============================================")
    println(" RAILWAY ELECTRICAL NETWORK OPTIMISER")
    println("==============================================")

    for train in trains

        traction =
            traction_power(train)

        regen =
            regenerative_power(train)

        net =
            traction - regen

        total_consumption +=
            traction

        total_regeneration +=
            regen

        println()
        println(
            "Train ",
            train.id
        )

        println(
            "  Position: ",
            round(train.position, digits=1),
            " m"
        )

        println(
            "  Speed: ",
            round(train.speed, digits=2),
            " m/s"
        )

        println(
            "  Acceleration: ",
            round(train.acceleration, digits=3),
            " m/s²"
        )

        println(
            "  Traction: ",
            round(traction / 1e6, digits=3),
            " MW"
        )

        println(
            "  Regeneration: ",
            round(regen / 1e6, digits=3),
            " MW"
        )

        println(
            "  Net: ",
            round(net / 1e6, digits=3),
            " MW"
        )

    end

    usable_regen,
    wasted_regen =
        distribute_regenerative_energy(
            trains,
            section
        )

    net_power =
        total_consumption -
        usable_regen

    voltage =
        estimate_section_voltage(
            trains,
            section
        )

    current =
        substation_current(
            trains,
            section
        )

    println()
    println("----------------------------------------------")

    println(
        "Gross traction: ",
        round(
            total_consumption / 1e6,
            digits=3
        ),
        " MW"
    )

    println(
        "Available regeneration: ",
        round(
            total_regeneration / 1e6,
            digits=3
        ),
        " MW"
    )

    println(
        "Useful regeneration: ",
        round(
            usable_regen / 1e6,
            digits=3
        ),
        " MW"
    )

    println(
        "Wasted regeneration: ",
        round(
            wasted_regen / 1e6,
            digits=3
        ),
        " MW"
    )

    println(
        "Net substation demand: ",
        round(
            net_power / 1e6,
            digits=3
        ),
        " MW"
    )

    println(
        "Estimated line voltage: ",
        round(
            voltage,
            digits=1
        ),
        " V"
    )

    println(
        "Substation current: ",
        round(
            current,
            digits=1
        ),
        " A"
    )

    println("==============================================")

end

end





using .MultiTrainRailPower

trains = [

    Train(
        1,
        1_000.0,
        22.0,
        0.70,
        300_000.0,
        0.8,
        5e6,
        4e6,
        0.94,
        0.88
    ),

    Train(
        2,
        4_000.0,
        18.0,
        0.45,
        280_000.0,
        0.5,
        5e6,
        4e6,
        0.94,
        0.88
    ),

    Train(
        3,
        7_500.0,
        27.0,
        -0.35,
        300_000.0,
        -0.2,
        5e6,
        4e6,
        0.94,
        0.88
    ),

    Train(
        4,
        11_000.0,
        20.0,
        0.20,
        250_000.0,
        0.4,
        5e6,
        4e6,
        0.94,
        0.88
    )
]


section = ElectricalSection(

    25_000.0,       # nominal voltage
    20_000.0,       # minimum voltage

    25_000.0,       # substation voltage

    1_800.0,        # max substation current

    0.012,          # Ω/km

    0.015,          # transformer resistance

    5e6             # maximum accepted regeneration
)


optimizer = NetworkOptimizer(

    0.1,            # timestep
    20,             # horizon

    25.0,           # current resolution

    1.0,             # traction
    1.0,             # current
    8.0,             # peak
    0.5,             # voltage
    3.0,             # ramp
    2.0,             # regeneration

    0.05,
    0.05
)


println("BEFORE OPTIMISATION")

network_report(
    trains,
    section
)


previous_current = 600.0

optimised_trains,
cost =
    optimise_network(
        trains,
        section,
        optimizer,
        previous_current
    )


println()
println("AFTER OPTIMISATION")

network_report(
    optimised_trains,
    section
)




struct TrainPrediction

    acceleration::Vector{Float64}
    speed::Vector{Float64}
    position::Vector{Float64}

    traction_power::Vector{Float64}
    regenerative_power::Vector{Float64}

end


function predict_train_motion(
    train::Train,
    horizon::Int,
    dt::Float64
)

    acceleration =
        zeros(horizon)

    speed =
        zeros(horizon)

    position =
        zeros(horizon)

    traction =
        zeros(horizon)

    regen =
        zeros(horizon)

    speed[1] =
        train.speed

    position[1] =
        train.position

    acceleration[1] =
        train.acceleration

    for t in 2:horizon

        speed[t] =
            max(
                speed[t-1] +
                acceleration[t-1] * dt,
                0.0
            )

        position[t] =
            position[t-1] +
            speed[t] * dt

        acceleration[t] =
            train.acceleration

        predicted_train =
            Train(
                train.id,
                position[t],
                speed[t],
                acceleration[t],
                train.mass,
                train.gradient,
                train.max_traction_power,
                train.max_regen_power,
                train.traction_efficiency,
                train.regen_efficiency
            )

        traction[t] =
            traction_power(
                predicted_train
            )

        regen[t] =
            regenerative_power(
                predicted_train
            )

    end

    return TrainPrediction(
        acceleration,
        speed,
        position,
        traction,
        regen
    )

end





RailMPC.jl
module RailMPC

using LinearAlgebra
using Statistics
using JuMP
using HiGHS

# ============================================================
# BASIC TYPES
# ============================================================

struct TrainState
    id::Int

    position::Float64       # m
    speed::Float64          # m/s
    acceleration::Float64   # m/s²

    mass::Float64            # kg
    gradient::Float64        # %

    max_traction_power::Float64
    max_regen_power::Float64

    traction_efficiency::Float64
    regen_efficiency::Float64
end


struct ElectricalNetwork

    nominal_voltage::Float64
    minimum_voltage::Float64
    maximum_voltage::Float64

    substation_voltage::Float64

    maximum_substation_current::Float64

    line_resistance_per_km::Float64
    transformer_resistance::Float64

    maximum_regeneration::Float64
end


struct MPCConfig

    dt::Float64

    horizon::Int

    # Optimisation weights
    current_weight::Float64
    peak_weight::Float64
    voltage_weight::Float64
    ramp_weight::Float64
    regen_weight::Float64
    energy_weight::Float64

    # Train-control weights
    acceleration_tracking_weight::Float64
    jerk_weight::Float64

    # Control limits
    maximum_acceleration::Float64
    minimum_acceleration::Float64

    # Current smoothing
    current_slew_limit::Float64

    # Voltage safety margin
    voltage_margin::Float64

end


# ============================================================
# ML PREDICTION DATA
# ============================================================

struct TrainPrediction

    position::Vector{Float64}
    speed::Vector{Float64}
    acceleration::Vector{Float64}

    traction_power::Vector{Float64}
    regen_power::Vector{Float64}

end


# ============================================================
# NETWORK PREDICTION
# ============================================================

struct NetworkPrediction

    trains::Vector{TrainPrediction}

end


# ============================================================
# PHYSICS
# ============================================================

function resistance_force(
    train::TrainState,
    speed::Float64
)

    g = 9.81

    rolling =
        train.mass * g * 0.0015

    aerodynamic =
        0.0006 * speed^2

    gradient =
        train.mass *
        g *
        train.gradient / 100.0

    return rolling +
           aerodynamic +
           gradient

end


# ============================================================
# MECHANICAL POWER
# ============================================================

function mechanical_power(
    train::TrainState,
    speed::Float64,
    acceleration::Float64
)

    force =
        train.mass * acceleration +
        resistance_force(
            train,
            speed
        )

    return force * speed

end


# ============================================================
# ELECTRICAL TRACTION POWER
# ============================================================

function traction_power(
    train::TrainState,
    speed::Float64,
    acceleration::Float64
)

    mechanical =
        mechanical_power(
            train,
            speed,
            acceleration
        )

    if mechanical >= 0

        return min(
            mechanical /
            train.traction_efficiency,

            train.max_traction_power
        )

    end

    return 0.0

end


# ============================================================
# REGENERATIVE POWER
# ============================================================

function regeneration_power(
    train::TrainState,
    speed::Float64,
    acceleration::Float64
)

    mechanical =
        mechanical_power(
            train,
            speed,
            acceleration
        )

    if mechanical >= 0

        return 0.0

    end

    return min(
        abs(mechanical) *
        train.regen_efficiency,

        train.max_regen_power
    )

end


# ============================================================
# SIMPLE ML PREDICTOR
#
# Research placeholder.
#
# Replace with a trained Flux/MLJ model later.
# ============================================================

mutable struct RailPredictor

    W1::Matrix{Float64}
    b1::Vector{Float64}

    W2::Matrix{Float64}
    b2::Vector{Float64}

    W3::Matrix{Float64}
    b3::Vector{Float64}

end


function create_predictor(
    input_size::Int = 7,
    hidden1::Int = 32,
    hidden2::Int = 16
)

    return RailPredictor(

        randn(hidden1, input_size) .* 0.03,
        zeros(hidden1),

        randn(hidden2, hidden1) .* 0.03,
        zeros(hidden2),

        randn(1, hidden2) .* 0.03,
        zeros(1)
    )

end


function relu(x)

    return max.(x, 0.0)

end


function predict_acceleration(
    model::RailPredictor,
    train::TrainState
)

    x = [

        train.speed / 40.0,

        train.acceleration / 2.0,

        train.position / 50_000.0,

        train.gradient / 5.0,

        train.mass / 500_000.0,

        train.max_traction_power / 10e6,

        train.max_regen_power / 10e6
    ]

    h1 =
        relu.(
            model.W1 * x +
            model.b1
        )

    h2 =
        relu.(
            model.W2 * h1 +
            model.b2
        )

    y =
        model.W3 * h2 +
        model.b3

    return clamp(
        y[1],
        -2.0,
        2.0
    )

end


# ============================================================
# ML FUTURE TRAJECTORY
# ============================================================

function predict_train(
    model::RailPredictor,
    train::TrainState,
    config::MPCConfig
)

    N =
        config.horizon

    dt =
        config.dt

    position =
        zeros(N + 1)

    speed =
        zeros(N + 1)

    acceleration =
        zeros(N + 1)

    traction =
        zeros(N + 1)

    regen =
        zeros(N + 1)

    position[1] =
        train.position

    speed[1] =
        train.speed

    acceleration[1] =
        train.acceleration

    for k in 2:N+1

        predicted_a =
            predict_acceleration(
                model,
                train
            )

        acceleration[k] =
            predicted_a

        speed[k] =
            max(
                speed[k-1] +
                acceleration[k] * dt,
                0.0
            )

        position[k] =
            position[k-1] +
            speed[k] * dt

        traction[k] =
            traction_power(
                train,
                speed[k],
                acceleration[k]
            )

        regen[k] =
            regeneration_power(
                train,
                speed[k],
                acceleration[k]
            )

    end

    return TrainPrediction(
        position,
        speed,
        acceleration,
        traction,
        regen
    )

end


# ============================================================
# PREDICT WHOLE NETWORK
# ============================================================

function predict_network(
    model::RailPredictor,
    trains::Vector{TrainState},
    config::MPCConfig
)

    predictions = TrainPrediction[]

    for train in trains

        push!(
            predictions,
            predict_train(
                model,
                train,
                config
            )
        )

    end

    return NetworkPrediction(
        predictions
    )

end


# ============================================================
# LINE RESISTANCE
# ============================================================

function train_line_resistance(
    train::TrainState,
    network::ElectricalNetwork
)

    return (
        train.position / 1000.0
    ) *
    network.line_resistance_per_km +
    network.transformer_resistance

end


# ============================================================
# MPC MODEL
# ============================================================

function build_mpc(
    trains::Vector{TrainState},
    predictions::NetworkPrediction,
    network::ElectricalNetwork,
    config::MPCConfig,
    previous_current::Float64
)

    N =
        config.horizon

    M =
        length(trains)

    dt =
        config.dt

    # --------------------------------------------------------
    # JuMP model
    # --------------------------------------------------------

    model =
        Model(
            HiGHS.Optimizer
        )

    set_silent(model)

    # --------------------------------------------------------
    # Acceleration controls
    # --------------------------------------------------------

    @variable(
        model,
        config.minimum_acceleration
        <= a[i=1:M, k=1:N]
        <= config.maximum_acceleration
    )

    # --------------------------------------------------------
    # Speed state
    # --------------------------------------------------------

    @variable(
        model,
        v[i=1:M, k=1:N+1]
        >= 0
    )

    # --------------------------------------------------------
    # Position
    # --------------------------------------------------------

    @variable(
        model,
        x[i=1:M, k=1:N+1]
    )

    # --------------------------------------------------------
    # Traction power
    # --------------------------------------------------------

    @variable(
        model,
        traction[i=1:M, k=1:N]
        >= 0
    )

    # --------------------------------------------------------
    # Regeneration
    # --------------------------------------------------------

    @variable(
        model,
        regen[i=1:M, k=1:N]
        >= 0
    )

    # --------------------------------------------------------
    # Net train power
    # --------------------------------------------------------

    @variable(
        model,
        net_power[i=1:M, k=1:N]
    )

    # --------------------------------------------------------
    # Network current
    # --------------------------------------------------------

    @variable(
        model,
        0 <= current[k=1:N]
        <= network.maximum_substation_current
    )

    # --------------------------------------------------------
    # Voltage
    # --------------------------------------------------------

    @variable(
        model,
        voltage[k=1:N]
    )

    # --------------------------------------------------------
    # Current ramp
    # --------------------------------------------------------

    @variable(
        model,
        current_ramp[k=1:N]
        >= 0
    )

    # --------------------------------------------------------
    # Regeneration absorbed by other trains
    # --------------------------------------------------------

    @variable(
        model,
        absorbed_regen[k=1:N]
        >= 0
    )

    # --------------------------------------------------------
    # Initial conditions
    # --------------------------------------------------------

    for i in 1:M

        @constraint(
            model,
            v[i,1] ==
            trains[i].speed
        )

        @constraint(
            model,
            x[i,1] ==
            trains[i].position
        )

    end


    # ========================================================
    # TRAIN DYNAMICS
    # ========================================================

    for i in 1:M

        train =
            trains[i]

        for k in 1:N

            # -----------------------------------------------
            # Discrete speed equation
            # -----------------------------------------------

            @constraint(
                model,

                v[i,k+1] ==
                v[i,k] +
                dt * a[i,k]
            )

            # -----------------------------------------------
            # Discrete position equation
            # -----------------------------------------------

            @constraint(
                model,

                x[i,k+1] ==
                x[i,k] +
                dt * v[i,k]
            )

            # -----------------------------------------------
            # Linearised traction-power model
            #
            # P ≈ m*v*a + resistance*v
            # -----------------------------------------------

            predicted_speed =
                predictions.trains[i].speed[k+1]

            resistance =
                resistance_force(
                    train,
                    predicted_speed
                )

            @constraint(
                model,

                traction[i,k]
                >=
                (
                    train.mass *
                    predicted_speed *
                    a[i,k]
                    +
                    resistance *
                    predicted_speed
                ) /
                train.traction_efficiency
            )

            @constraint(
                model,

                traction[i,k]
                <=
                train.max_traction_power
            )

            # -----------------------------------------------
            # Regeneration
            # -----------------------------------------------

            @constraint(
                model,

                regen[i,k]
                >=
                -(
                    train.mass *
                    predicted_speed *
                    a[i,k]
                    +
                    resistance *
                    predicted_speed
                ) *
                train.regen_efficiency
            )

            @constraint(
                model,

                regen[i,k]
                <=
                train.max_regen_power
            )

            # -----------------------------------------------
            # Net power
            # -----------------------------------------------

            @constraint(
                model,

                net_power[i,k]
                ==
                traction[i,k] -
                regen[i,k]
            )

        end

    end


    # ========================================================
    # NETWORK ELECTRICAL MODEL
    # ========================================================

    for k in 1:N

        # ----------------------------------------------------
        # Total electrical power
        # ----------------------------------------------------

        @constraint(
            model,

            network.maximum_substation_current
            *
            voltage[k]
            >=
            sum(
                net_power[i,k]
                for i in 1:M
            )
        )

        # ----------------------------------------------------
        # Simplified voltage-current relation
        # ----------------------------------------------------

        total_resistance =
            network.transformer_resistance +
            sum(
                train_line_resistance(
                    trains[i],
                    network
                )
                for i in 1:M
            ) / max(M, 1)

        @constraint(
            model,

            voltage[k]
            ==
            network.substation_voltage -
            total_resistance *
            current[k]
        )

        # ----------------------------------------------------
        # Voltage limits
        # ----------------------------------------------------

        @constraint(
            model,

            voltage[k]
            >=
            network.minimum_voltage +
            config.voltage_margin
        )

        @constraint(
            model,

            voltage[k]
            <=
            network.maximum_voltage
        )

        # ----------------------------------------------------
        # Current slew
        # ----------------------------------------------------

        if k == 1

            @constraint(
                model,

                current_ramp[k]
                >=
                current[k] -
                previous_current
            )

            @constraint(
                model,

                current_ramp[k]
                >=
                previous_current -
                current[k]
            )

        else

            @constraint(
                model,

                current_ramp[k]
                >=
                current[k] -
                current[k-1]
            )

            @constraint(
                model,

                current_ramp[k]
                >=
                current[k-1] -
                current[k]
            )

        end

        @constraint(
            model,

            current_ramp[k]
            <=
            config.current_slew_limit
        )

        # ----------------------------------------------------
        # Regeneration absorption
        # ----------------------------------------------------

        @constraint(
            model,

            absorbed_regen[k]
            <=
            sum(
                regen[i,k]
                for i in 1:M
            )
        )

        @constraint(
            model,

            absorbed_regen[k]
            <=
            sum(
                traction[i,k]
                for i in 1:M
            )
        )

        @constraint(
            model,

            absorbed_regen[k]
            <=
            network.maximum_regeneration
        )

    end


    # ========================================================
    # OBJECTIVE
    # ========================================================

    objective =

        # ----------------------------------------------------
        # Minimise substation current
        # ----------------------------------------------------

        config.current_weight *
        sum(
            current[k]^2
            for k in 1:N
        )

        +

        # ----------------------------------------------------
        # Minimise peaks
        # ----------------------------------------------------

        config.peak_weight *
        sum(
            (
                current[k] /
                network.maximum_substation_current
            )^2
            for k in 1:N
        )

        +

        # ----------------------------------------------------
        # Voltage stability
        # ----------------------------------------------------

        config.voltage_weight *
        sum(
            (
                voltage[k] -
                network.nominal_voltage
            )^2
            for k in 1:N
        ) / 1e6

        +

        # ----------------------------------------------------
        # Current smoothness
        # ----------------------------------------------------

        config.ramp_weight *
        sum(
            current_ramp[k]^2
            for k in 1:N
        )

        -

        # ----------------------------------------------------
        # Reward regeneration absorption
        # ----------------------------------------------------

        config.regen_weight *
        sum(
            absorbed_regen[k]
            for k in 1:N
        ) / 1e6

        +

        # ----------------------------------------------------
        # Track ML acceleration prediction
        # ----------------------------------------------------

        config.acceleration_tracking_weight *
        sum(
            (
                a[i,k] -
                predictions.trains[i]
                    .acceleration[k+1]
            )^2

            for i in 1:M,
            k in 1:N
        )

        +

        # ----------------------------------------------------
        # Jerk penalty
        # ----------------------------------------------------

        config.jerk_weight *
        sum(
            (
                a[i,k] -
                (
                    k == 1 ?
                    trains[i].acceleration :
                    a[i,k-1]
                )
            )^2

            for i in 1:M,
            k in 1:N
        )

    @objective(
        model,
        Min,
        objective
    )

    return model

end


# ============================================================
# SOLVE MPC
# ============================================================

function solve_mpc!(
    model
)

    optimize!(model)

    status =
        termination_status(model)

    return status

end


# ============================================================
# EXTRACT FIRST CONTROL ACTION
# ============================================================

function first_control_action(
    model,
    trains::Vector{TrainState}
)

    M =
        length(trains)

    acceleration =
        zeros(M)

    for i in 1:M

        acceleration[i] =
            value(
                model[:a][i,1]
            )

    end

    first_current =
        value(
            model[:current][1]
        )

    first_voltage =
        value(
            model[:voltage][1]
        )

    return (
        acceleration = acceleration,
        current = first_current,
        voltage = first_voltage
    )

end


# ============================================================
# COMPLETE MPC CYCLE
# ============================================================

function mpc_step!(
    predictor::RailPredictor,

    trains::Vector{TrainState},

    network::ElectricalNetwork,

    config::MPCConfig,

    previous_current::Float64
)

    # --------------------------------------------------------
    # 1. ML prediction
    # --------------------------------------------------------

    predictions =
        predict_network(
            predictor,
            trains,
            config
        )

    # --------------------------------------------------------
    # 2. Construct optimisation problem
    # --------------------------------------------------------

    model =
        build_mpc(
            trains,
            predictions,
            network,
            config,
            previous_current
        )

    # --------------------------------------------------------
    # 3. Solve
    # --------------------------------------------------------

    status =
        solve_mpc!(
            model
        )

    # --------------------------------------------------------
    # 4. Extract only FIRST action
    # --------------------------------------------------------

    action =
        first_control_action(
            model,
            trains
        )

    return (
        status = status,
        predictions = predictions,
        action = action,
        model = model
    )

end


# ============================================================
# APPLY FIRST ACTION
#
# In true MPC we throw away the remainder of the solution
# and move the simulation/controller forward by one timestep.
# ============================================================

function apply_action(
    trains::Vector{TrainState},
    action,
    config::MPCConfig
)

    dt =
        config.dt

    new_trains =
        TrainState[]

    for i in eachindex(trains)

        train =
            trains[i]

        a =
            action.acceleration[i]

        new_speed =
            max(
                train.speed +
                a * dt,
                0.0
            )

        new_position =
            train.position +
            train.speed * dt

        push!(
            new_trains,

            TrainState(

                train.id,

                new_position,

                new_speed,

                a,

                train.mass,

                train.gradient,

                train.max_traction_power,

                train.max_regen_power,

                train.traction_efficiency,

                train.regen_efficiency
            )
        )

    end

    return new_trains

end


# ============================================================
# ROLLING-HORIZON SIMULATION
# ============================================================

function run_mpc!(
    predictor,
    trains,
    network,
    config,
    simulation_steps
)

    current =
        0.0

    history =
        NamedTuple[]

    states =
        copy(trains)

    for step in 1:simulation_steps

        result =
            mpc_step!(
                predictor,
                states,
                network,
                config,
                current
            )

        action =
            result.action

        push!(
            history,

            (
                time =
                    (step - 1) *
                    config.dt,

                current =
                    action.current,

                voltage =
                    action.voltage,

                acceleration =
                    copy(
                        action.acceleration
                    ),

                status =
                    result.status
            )
        )

        # -----------------------------------------------
        # Apply ONLY first control action
        # -----------------------------------------------

        states =
            apply_action(
                states,
                action,
                config
            )

        current =
            action.current

    end

    return history, states

end


end # module




network = ElectricalNetwork(

    25_000.0,       # nominal voltage
    20_000.0,       # minimum voltage
    27_500.0,       # maximum voltage

    25_000.0,       # substation voltage

    2_000.0,        # maximum substation current

    0.012,          # Ω/km overhead system
    0.015,          # transformer resistance

    8e6             # max useful regenerative power
)


config = MPCConfig(

    0.10,       # MPC timestep = 100 ms

    100,        # 10 second horizon

    1.0,        # current penalty
    8.0,        # peak penalty
    0.20,       # voltage penalty
    5.0,        # current ramp penalty
    3.0,        # regeneration reward
    0.5,        # energy penalty

    5.0,        # acceleration tracking
    2.0,        # jerk penalty

    1.2,        # max acceleration
    -1.2,       # max braking

    150.0,      # maximum current change / step

    250.0       # voltage safety margin
)








trains = [

    TrainState(
        1,
        1_000.0,
        20.0,
        0.6,
        320_000.0,
        0.8,
        6e6,
        4e6,
        0.94,
        0.88
    ),

    TrainState(
        2,
        4_000.0,
        18.0,
        0.5,
        300_000.0,
        0.4,
        6e6,
        4e6,
        0.94,
        0.88
    ),

    TrainState(
        3,
        7_500.0,
        28.0,
        -0.8,
        300_000.0,
        -0.3,
        6e6,
        4e6,
        0.94,
        0.88
    ),

    TrainState(
        4,
        11_000.0,
        16.0,
        0.3,
        280_000.0,
        0.5,
        6e6,
        4e6,
        0.94,
        0.88
    )
]




predictor =
    create_predictor()


history, final_state =
    run_mpc!(
        predictor,
        trains,
        network,
        config,
        300
    )

That's a 30-second simulation at 100 ms resolution.

The resulting history contains:

history[1]

something conceptually like:

(
    time = 0.0,
    current = ...,
    voltage = ...,
    acceleration = [...],
    status = ...
)
5. Extract the electrical profile
currents =
    [h.current for h in history]

voltages =
    [h.voltage for h in history]

times =
    [h.time for h in history]

Then:

println(
    "Maximum current = ",
    maximum(currents),
    " A"
)

println(
    "Average current = ",
    mean(currents),
    " A"
)

println(
    "Minimum voltage = ",
    minimum(voltages),
    " V"
)

The really interesting metric is:

peak_current =
    maximum(currents)

rms_current =
    sqrt(
        mean(currents .^ 2)
    )
    
    
    
    struct TrainFeatures

    speed::Float64
    acceleration::Float64
    position::Float64

    gradient::Float64

    passenger_load::Float64

    timetable_deviation::Float64

    distance_to_station::Float64

    distance_to_next_signal::Float64

    preceding_train_distance::Float64

    preceding_train_speed::Float64

    line_voltage::Float64

    substation_current::Float64

    temperature::Float64

end






@variable(
    model,
    arrival_error[i=1:M]
)

and impose a timetable constraint:

@constraint(
    model,

    arrival_error[i]
    >=
    predicted_arrival_time[i]
    -
    scheduled_arrival_time[i]
)

Then penalise lateness:

@objective(
    model,
    Min,

    electrical_cost
    +

    timetable_penalty *
    sum(
        arrival_error[i]^2
        for i in 1:M
    )
)


For every pair of trains:

@variable(
    model,
    transfer[i=1:M, j=1:M, k=1:N]
    >= 0
)

Then constrain:

@constraint(
    model,

    transfer[i,j,k]
    <=
    regen[i,k]
)

and:

@constraint(
    model,

    sum(
        transfer[i,j,k]
        for i in 1:M
    )
    <=
    traction[j,k]
)

This allows the optimiser to explicitly determine:

Train 3
regenerates
1.7 MW
   │
   ├──── 0.9 MW → Train 1
   │
   ├──── 0.5 MW → Train 2
   │
   └──── 0.3 MW → Train 4

rather than treating regeneration merely as a negative number in the network power balance.

9. The resulting control philosophy

The final controller is essentially trying to operate the railway according to:

When demand is high
          HIGH DEMAND
               │
               ▼
      Is acceleration necessary?
          /             \
        YES              NO
         │                │
         ▼                ▼
   permit required     reduce current
      traction
         │
         ▼
   check voltage
         │
         ▼
   check substation
         │
         ▼
    smooth current
When another train is braking
            REGENERATING TRAIN
                    │
                    ▼
             available energy
                    │
          ┌─────────┴─────────┐
          ▼                   ▼
    trains accelerating    no demand
          │                   │
          ▼                   ▼
     absorb energy       export/store/
          │              brake resistor
          ▼
    reduce substation
       demand
When the line is heavily loaded
              HIGH CURRENT
                   │
                   ▼
          ┌────────────────┐
          │ MPC looks ahead│
          └───────┬────────┘
                  │
       ┌──────────┼───────────┐
       ▼          ▼           ▼
    Train 1    Train 2      Train 3
    soften     maintain     braking
    accel.     accel.       regen
       │          │           │
       └──────────┴─────┬─────┘
                        ▼
                  lower peak
                   current

This gives you a much more sophisticated objective:

$$ \boxed{ \min \left[ \underbrace{I^2R}_{\text{network losses}} + \underbrace{I_{peak}}_{\text{substation loading}} + \underbrace{\Delta I^2}_{\text{smoothness}} + \underbrace{(V-V_{ref})^2}_{\text{voltage quality}} - \underbrace{E_{regen}}_{\text{energy recovery}} + \underbrace{E_{timetable}}_{\text{service performance}} \right] } $$

while maintaining the hard constraints for train acceleration, speed, voltage, current, traction power and infrastructure limits.

One important engineering caveat: the code above is a research/simulation controller, not something to connect directly to railway traction equipment. A deployed railway controller would need a validated electrical-network model, independent protection layers, fail-safe limits, deterministic real-time implementation, hardware-in-the-loop testing and the applicable railway safety/certification process.







