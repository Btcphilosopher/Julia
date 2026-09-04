module FreightDieselOptimizer

using Printf

# ============================================================
# DIESEL-ELECTRIC FREIGHT LOCOMOTIVE
# COMBUSTION + TRACTION OPTIMIZER
#
# Simulation / modelling software.
# NOT an engine ECU or safety-critical locomotive controller.
# ============================================================


# ------------------------------------------------------------
# ENGINE STATE
# ------------------------------------------------------------

mutable struct DieselEngine

    rpm::Float64
    displacement_l::Float64
    cylinders::Int

    fuel_flow_kg_s::Float64
    air_flow_kg_s::Float64

    boost_bar::Float64
    intake_temp_K::Float64
    exhaust_temp_K::Float64

    injection_timing_deg::Float64
    injection_quantity_mg::Float64

    torque_Nm::Float64
    power_W::Float64

    coolant_temp_K::Float64
    oil_temp_K::Float64

    efficiency::Float64

    max_rpm::Float64
    max_exhaust_temp_K::Float64
    max_coolant_temp_K::Float64
end


# ------------------------------------------------------------
# TURBOCHARGER
# ------------------------------------------------------------

mutable struct Turbocharger

    shaft_rpm::Float64
    boost_bar::Float64

    compressor_efficiency::Float64
    turbine_efficiency::Float64

    spool_rate::Float64

    max_boost_bar::Float64
end


# ------------------------------------------------------------
# GENERATOR
# ------------------------------------------------------------

mutable struct Generator

    electrical_power_W::Float64
    efficiency::Float64

    max_power_W::Float64
end


# ------------------------------------------------------------
# TRACTION SYSTEM
# ------------------------------------------------------------

mutable struct TractionSystem

    locomotive_speed_m_s::Float64

    requested_tractive_force_N::Float64
    actual_tractive_force_N::Float64

    adhesion_coefficient::Float64

    wheel_radius_m::Float64

    electrical_efficiency::Float64

    motor_count::Int
end


# ------------------------------------------------------------
# FREIGHT TRAIN
# ------------------------------------------------------------

mutable struct FreightTrain

    locomotive_mass_kg::Float64
    freight_mass_kg::Float64

    gradient::Float64
    rolling_resistance::Float64

    train_speed_m_s::Float64

    distance_m::Float64
end


# ------------------------------------------------------------
# OPTIMIZER
# ------------------------------------------------------------

mutable struct CombustionOptimizer

    target_rpm::Float64

    target_air_fuel_ratio::Float64

    target_efficiency::Float64

    rpm_gain::Float64
    fuel_gain::Float64
    timing_gain::Float64

    thermal_margin_K::Float64

    fuel_price_per_kg::Float64
end


# ============================================================
# CONSTANTS
# ============================================================

const DIESEL_LHV = 42.5e6       # J/kg
const G = 9.80665


# ============================================================
# ENGINE MASS
# ============================================================

function total_train_mass(train)

    return train.locomotive_mass_kg +
           train.freight_mass_kg

end


# ============================================================
# TRAIN RESISTANCE
# ============================================================

function train_resistance(train)

    mass = total_train_mass(train)

    rolling =
        mass * G *
        train.rolling_resistance

    grade =
        mass * G *
        train.gradient

    return rolling + grade

end


# ============================================================
# REQUIRED TRACTIVE EFFORT
# ============================================================

function required_tractive_force(train,
                                 desired_acceleration)

    mass = total_train_mass(train)

    resistance = train_resistance(train)

    return mass *
           desired_acceleration +
           resistance

end


# ============================================================
# TURBO MODEL
# ============================================================

function update_turbo!(turbo,
                       engine,
                       dt)

    target_boost =
        0.25 +
        0.000008 *
        engine.rpm^1.15

    target_boost =
        min(target_boost,
            turbo.max_boost_bar)

    error =
        target_boost -
        turbo.boost_bar

    turbo.boost_bar +=
        error *
        turbo.spool_rate *
        dt

    turbo.boost_bar =
        max(0.1,
            turbo.boost_bar)

    turbo.shaft_rpm =
        turbo.boost_bar *
        30_000.0

end


# ============================================================
# AIRFLOW
# ============================================================

function calculate_airflow(engine,
                           turbo)

    # Simplified compressor model.

    volumetric_efficiency = 0.88

    displacement =
        engine.displacement_l / 1000

    intake_density =
        1.225 *
        (1.0 + turbo.boost_bar)

    volume_rate =
        displacement *
        engine.rpm /
        120.0

    return volume_rate *
           intake_density *
           volumetric_efficiency

end


# ============================================================
# FUEL/AIR RATIO
# ============================================================

function calculate_afr(engine)

    if engine.fuel_flow_kg_s <= 1e-9

        return Inf

    end

    return engine.air_flow_kg_s /
           engine.fuel_flow_kg_s

end


# ============================================================
# COMBUSTION EFFICIENCY
# ============================================================

function combustion_efficiency(engine)

    afr =
        calculate_afr(engine)

    ideal_afr = 30.0

    afr_error =
        abs(afr - ideal_afr) /
        ideal_afr

    timing_error =
        abs(engine.injection_timing_deg - 12.0) /
        12.0

    efficiency =
        0.46 -
        0.12 * afr_error -
        0.04 * timing_error

    return clamp(efficiency,
                 0.20,
                 0.48)

end


# ============================================================
# FUEL INJECTION
# ============================================================

function calculate_fuel_flow(engine,
                             requested_power)

    η =
        engine.efficiency

    η =
        clamp(η, 0.20, 0.48)

    required_energy =
        requested_power / η

    return required_energy /
           DIESEL_LHV

end


# ============================================================
# ENGINE TORQUE
# ============================================================

function calculate_engine_torque(engine)

    if engine.rpm <= 0

        return 0.0

    end

    return engine.power_W /
           (2π * engine.rpm / 60.0)

end


# ============================================================
# ENGINE POWER
# ============================================================

function calculate_engine_power!(engine)

    engine.efficiency =
        combustion_efficiency(engine)

    chemical_power =
        engine.fuel_flow_kg_s *
        DIESEL_LHV

    engine.power_W =
        chemical_power *
        engine.efficiency

    engine.torque_Nm =
        calculate_engine_torque(engine)

end


# ============================================================
# THERMAL MODEL
# ============================================================

function update_temperature!(engine,
                             dt)

    load_factor =
        engine.power_W /
        (1.0e7)

    target_exhaust =
        650.0 +
        700.0 *
        load_factor

    target_exhaust =
        clamp(target_exhaust,
              450.0,
              1100.0)

    engine.exhaust_temp_K +=
        (target_exhaust -
         engine.exhaust_temp_K) *
        0.08 *
        dt

    target_coolant =
        350.0 +
        80.0 *
        load_factor

    engine.coolant_temp_K +=
        (target_coolant -
         engine.coolant_temp_K) *
        0.03 *
        dt

end


# ============================================================
# GENERATOR
# ============================================================

function update_generator!(generator,
                           engine)

    generator.electrical_power_W =
        min(
            engine.power_W *
            generator.efficiency,
            generator.max_power_W
        )

end


# ============================================================
# TRACTION POWER
# ============================================================

function available_tractive_force(traction,
                                  generator)

    speed =
        max(traction.locomotive_speed_m_s,
            1.0)

    power_force =
        generator.electrical_power_W *
        traction.electrical_efficiency /
        speed

    adhesion_force =
        traction.adhesion_coefficient *
        1_000_000.0

    return min(power_force,
               adhesion_force)

end


# ============================================================
# TRACTION UPDATE
# ============================================================

function update_traction!(traction,
                          generator,
                          train,
                          dt)

    traction.actual_tractive_force_N =
        available_tractive_force(
            traction,
            generator
        )

    resistance =
        train_resistance(train)

    net_force =
        traction.actual_tractive_force_N -
        resistance

    acceleration =
        net_force /
        total_train_mass(train)

    train.train_speed_m_s +=
        acceleration * dt

    train.train_speed_m_s =
        max(train.train_speed_m_s,
            0.0)

    traction.locomotive_speed_m_s =
        train.train_speed_m_s

    train.distance_m +=
        train.train_speed_m_s * dt

end


# ============================================================
# COMBUSTION OPTIMIZER
# ============================================================

function optimize_combustion!(optimizer,
                              engine,
                              turbo,
                              required_power)

    # --------------------------------------------------------
    # RPM OPTIMIZATION
    # --------------------------------------------------------

    power_fraction =
        required_power /
        1.0e7

    target =
        1000.0 +
        600.0 *
        clamp(power_fraction,
              0.0,
              1.0)

    target =
        clamp(target,
              800.0,
              engine.max_rpm)

    engine.rpm +=
        (target - engine.rpm) *
        optimizer.rpm_gain


    # --------------------------------------------------------
    # FUEL REQUEST
    # --------------------------------------------------------

    engine.fuel_flow_kg_s =
        calculate_fuel_flow(
            engine,
            required_power
        )


    # --------------------------------------------------------
    # INJECTION TIMING
    # --------------------------------------------------------

    # Simplified optimum-timing model.

    timing_target =
        10.0 +
        3.0 *
        clamp(
            required_power / 1.0e7,
            0.0,
            1.0
        )

    engine.injection_timing_deg +=
        (timing_target -
         engine.injection_timing_deg) *
        optimizer.timing_gain


    # --------------------------------------------------------
    # INJECTION QUANTITY
    # --------------------------------------------------------

    engine.injection_quantity_mg =
        engine.fuel_flow_kg_s *
        1e9 /
        (engine.rpm / 60.0) /
        engine.cylinders


    return nothing

end


# ============================================================
# ENGINE SAFETY / LIMITING
# ============================================================

function thermal_protection!(engine,
                             optimizer)

    margin =
        engine.max_exhaust_temp_K -
        engine.exhaust_temp_K

    if margin <
       optimizer.thermal_margin_K

        reduction =
            0.85

        engine.fuel_flow_kg_s *=
            reduction

        return :THERMAL_LIMIT

    end

    if engine.coolant_temp_K >
       engine.max_coolant_temp_K

        engine.fuel_flow_kg_s *=
            0.80

        return :COOLING_LIMIT

    end

    return :NORMAL

end


# ============================================================
# COMPLETE POWERTRAIN STEP
# ============================================================

function powertrain_step!(
    engine,
    turbo,
    generator,
    traction,
    train,
    optimizer,
    dt
)

    required_force =
        required_tractive_force(
            train,
            0.02
        )

    speed =
        max(train.train_speed_m_s,
            1.0)

    required_power =
        required_force *
        speed /
        max(
            traction.electrical_efficiency,
            0.01
        )

    required_power =
        clamp(
            required_power,
            0.0,
            generator.max_power_W
        )


    # Optimize combustion.

    optimize_combustion!(
        optimizer,
        engine,
        turbo,
        required_power
    )


    # Turbo response.

    update_turbo!(
        turbo,
        engine,
        dt
    )


    # Airflow.

    engine.air_flow_kg_s =
        calculate_airflow(
            engine,
            turbo
        )


    # Combustion.

    calculate_engine_power!(
        engine
    )


    # Thermal response.

    update_temperature!(
        engine,
        dt
    )


    # Thermal protection.

    status =
        thermal_protection!(
            engine,
            optimizer
        )


    # Generator.

    update_generator!(
        generator,
        engine
    )


    # Train traction.

    update_traction!(
        traction,
        generator,
        train,
        dt
    )


    return status

end


# ============================================================
# TELEMETRY
# ============================================================

function telemetry(engine,
                   turbo,
                   generator,
                   traction,
                   train,
                   status)

    @printf(
        "SPD %6.1f km/h | RPM %5.0f | " *
        "BOOST %4.2f bar | POWER %6.2f MW | " *
        "FORCE %7.0f kN | EGT %4.0f K | " *
        "FUEL %6.3f kg/s | STATUS %s\n",

        train.train_speed_m_s * 3.6,

        engine.rpm,

        turbo.boost_bar,

        generator.electrical_power_W / 1e6,

        traction.actual_tractive_force_N / 1000,

        engine.exhaust_temp_K,

        engine.fuel_flow_kg_s,

        string(status)
    )

end


# ============================================================
# FACTORY
# ============================================================

function create_system()

    engine = DieselEngine(

        900.0,          # RPM
        180.0,          # displacement L
        16,             # cylinders

        0.0,
        0.0,

        1.0,
        300.0,
        650.0,

        10.0,
        0.0,

        0.0,
        0.0,

        0.0,
        1800.0,
        1100.0,
        390.0,

        2200.0,
        390.0
    )


    turbo = Turbocharger(

        30_000.0,
        1.0,

        0.72,
        0.70,

        0.8,

        3.5
    )


    generator = Generator(

        0.0,
        0.95,

        5.0e6
    )


    traction = TractionSystem(

        0.0,
        0.0,
        0.0,

        0.30,

        0.55,

        0.94,

        6
    )


    train = FreightTrain(

        130_000.0,      # locomotive
        8_000_000.0,    # freight

        0.005,          # 0.5% gradient

        0.0015,

        0.0,
        0.0
    )


    optimizer = CombustionOptimizer(

        1400.0,
        30.0,
        0.42,

        0.10,
        0.10,
        0.10,

        50.0,

        0.0
    )


    return engine,
           turbo,
           generator,
           traction,
           train,
           optimizer

end


# ============================================================
# SIMULATOR
# ============================================================

function simulate!(duration)

    engine,
    turbo,
    generator,
    traction,
    train,
    optimizer =
        create_system()

    dt = 0.5

    t = 0.0

    println()
    println("================================================")
    println(" RHINO FREIGHT DIESEL COMBUSTION OPTIMIZER")
    println("================================================")
    println()

    while t < duration

        status =
            powertrain_step!(
                engine,
                turbo,
                generator,
                traction,
                train,
                optimizer,
                dt
            )

        if mod(round(Int, t), 5) == 0

            telemetry(
                engine,
                turbo,
                generator,
                traction,
                train,
                status
            )

        end

        t += dt

    end


    println()
    println("SIMULATION COMPLETE")
    println("--------------------------------")
    println("Distance: ",
            round(train.distance_m / 1000, digits=2),
            " km")

    println("Final speed: ",
            round(train.train_speed_m_s * 3.6, digits=1),
            " km/h")

    println("Final engine RPM: ",
            round(engine.rpm))

    println("Fuel flow: ",
            round(engine.fuel_flow_kg_s, digits=3),
            " kg/s")

    println("Engine power: ",
            round(engine.power_W / 1e6, digits=2),
            " MW")

end


end # module


using .FreightDieselOptimizer

FreightDieselOptimizer.simulate!(120.0)
