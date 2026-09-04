module AfterburnerEnergyManager

using Printf

# ============================================================
# AFTERBURNER ENERGY MANAGEMENT SIMULATOR
# Simulation / game / engineering-model use only
# ============================================================

@enum FlightPhase begin
    CRUISE
    ENERGY_DUMP
    MAX_AFTERBURNER
    ACCELERATION
    DECELERATION
    AB_OFF
    EMERGENCY
end

@enum EngineMode begin
    IDLE
    MILITARY
    AFTERBURNER
end


# ============================================================
# AIRCRAFT
# ============================================================

mutable struct Aircraft

    # Mass / fuel
    dry_mass::Float64
    fuel_mass::Float64

    # Flight condition
    altitude::Float64
    velocity::Float64
    mach::Float64

    # Energy state
    kinetic_energy::Float64
    potential_energy::Float64

    # Propulsion
    engine_count::Int
    military_thrust_per_engine::Float64
    afterburner_thrust_per_engine::Float64

    # Fuel consumption
    military_tsfc::Float64
    afterburner_tsfc::Float64

    # Engine
    engine_mode::EngineMode

    # Aerodynamics
    drag_coefficient::Float64
    reference_area::Float64
    lift_to_drag::Float64

    # Limits
    max_mach::Float64
    max_altitude::Float64
    min_fuel_reserve::Float64

    # State
    phase::FlightPhase
    elapsed_time::Float64
end


# ============================================================
# ATMOSPHERE
# ============================================================

function air_density(altitude)

    # Simplified exponential atmosphere.
    # Not a certification/performance atmosphere model.

    rho0 = 1.225
    scale_height = 8500.0

    return rho0 * exp(-altitude / scale_height)
end


function speed_of_sound(altitude)

    # Simplified ISA-like approximation.

    T0 = 288.15
    lapse = 0.0065

    T = max(216.65, T0 - lapse * altitude)

    γ = 1.4
    R = 287.05

    return sqrt(γ * R * T)
end


function update_mach!(aircraft)

    a = speed_of_sound(aircraft.altitude)

    aircraft.mach = aircraft.velocity / a

end


# ============================================================
# MASS
# ============================================================

function aircraft_mass(a)

    return a.dry_mass + a.fuel_mass

end


# ============================================================
# THRUST
# ============================================================

function engine_thrust(a)

    if a.engine_mode == IDLE

        return 0.05 *
               a.engine_count *
               a.military_thrust_per_engine

    elseif a.engine_mode == MILITARY

        return a.engine_count *
               a.military_thrust_per_engine

    elseif a.engine_mode == AFTERBURNER

        return a.engine_count *
               a.afterburner_thrust_per_engine

    end

end


# ============================================================
# FUEL FLOW
# ============================================================

function fuel_flow(a)

    thrust = engine_thrust(a)

    if a.engine_mode == AFTERBURNER

        return thrust * a.afterburner_tsfc

    elseif a.engine_mode == MILITARY

        return thrust * a.military_tsfc

    else

        return thrust * a.military_tsfc * 0.25

    end

end


# ============================================================
# AERODYNAMIC DRAG
# ============================================================

function aerodynamic_drag(a)

    ρ = air_density(a.altitude)

    q = 0.5 * ρ * a.velocity^2

    return q *
           a.drag_coefficient *
           a.reference_area

end


# ============================================================
# NET FORCE
# ============================================================

function net_force(a)

    thrust = engine_thrust(a)
    drag = aerodynamic_drag(a)

    return thrust - drag

end


# ============================================================
# ENERGY CALCULATION
# ============================================================

function calculate_energy!(a)

    mass = aircraft_mass(a)

    a.kinetic_energy =
        0.5 * mass * a.velocity^2

    a.potential_energy =
        mass * 9.80665 * a.altitude

end


function total_energy(a)

    return a.kinetic_energy +
           a.potential_energy

end


# ============================================================
# AFTERBURNER CONTROL
# ============================================================

function enable_afterburner!(a)

    if a.fuel_mass <= a.min_fuel_reserve

        println("AB LOCKOUT: fuel reserve reached")

        a.engine_mode = MILITARY
        return false

    end

    a.engine_mode = AFTERBURNER

    return true

end


function disable_afterburner!(a)

    a.engine_mode = MILITARY

end


# ============================================================
# ENERGY-DUMP REQUEST
# ============================================================

function request_energy_dump!(a)

    if a.fuel_mass <= a.min_fuel_reserve

        println("Energy dump rejected: reserve fuel")

        a.phase = CRUISE

        return false
    end

    a.phase = ENERGY_DUMP

    enable_afterburner!(a)

    return true

end


# ============================================================
# SPEED CONTROL
# ============================================================

function accelerate!(a, dt)

    force = net_force(a)
    mass = aircraft_mass(a)

    acceleration = force / mass

    a.velocity += acceleration * dt

    a.velocity = max(a.velocity, 0.0)

end


# ============================================================
# FUEL CONSUMPTION
# ============================================================

function consume_fuel!(a, dt)

    flow = fuel_flow(a)

    burned = flow * dt

    if burned >= a.fuel_mass

        a.fuel_mass = 0.0

        a.engine_mode = IDLE

    else

        a.fuel_mass -= burned

    end

end


# ============================================================
# LIMIT MONITOR
# ============================================================

function check_limits!(a)

    # Fuel reserve

    if a.fuel_mass <= a.min_fuel_reserve

        println("FUEL RESERVE REACHED")

        disable_afterburner!(a)

        a.phase = CRUISE

        return
    end


    # Maximum Mach

    if a.mach >= a.max_mach

        println("MAX MACH REACHED")

        disable_afterburner!(a)

        a.phase = DECELERATION

        return
    end


    # Altitude ceiling

    if a.altitude >= a.max_altitude

        println("ALTITUDE LIMIT REACHED")

        disable_afterburner!(a)

        a.phase = DECELERATION

        return
    end

end


# ============================================================
# SIMULATION STEP
# ============================================================

function simulation_step!(a, dt)

    # 1. Calculate propulsion effects
    accelerate!(a, dt)

    # 2. Consume fuel
    consume_fuel!(a, dt)

    # 3. Update Mach
    update_mach!(a)

    # 4. Update energies
    calculate_energy!(a)

    # 5. Check constraints
    check_limits!(a)

    # 6. Clock
    a.elapsed_time += dt

end


# ============================================================
# ENERGY DUMP CONTROLLER
# ============================================================

function energy_dump_controller!(a;
                                  target_mach=1.6,
                                  target_fuel=0.0)

    println()
    println("==========================================")
    println(" AFTERBURNER ENERGY MANAGEMENT")
    println("==========================================")

    println("Initial fuel: ",
            round(a.fuel_mass / 1000, digits=1),
            " tonnes")

    println("Target Mach: ", target_mach)

    a.phase = ENERGY_DUMP

    enable_afterburner!(a)


    dt = 0.5

    while true

        simulation_step!(a, dt)

        # Stop conditions

        if a.fuel_mass <=
           max(target_fuel, a.min_fuel_reserve)

            break
        end

        if a.mach >= target_mach

            println("Target Mach reached.")

            break
        end

        if a.phase != ENERGY_DUMP

            break
        end

    end


    disable_afterburner!(a)

    a.phase = CRUISE

    println()
    println("ENERGY DUMP COMPLETE")
    println("Time: ",
            round(a.elapsed_time, digits=1),
            " s")

    println("Remaining fuel: ",
            round(a.fuel_mass / 1000, digits=2),
            " tonnes")

    println("Mach: ",
            round(a.mach, digits=3))

    println()

end


# ============================================================
# CONTINUOUS MAX-POWER MODE
# ============================================================

function maximum_power_run!(a, duration)

    println()
    println("MAXIMUM AFTERBURNER RUN")
    println("------------------------")

    enable_afterburner!(a)

    a.phase = MAX_AFTERBURNER

    dt = 0.25

    elapsed = 0.0

    while elapsed < duration

        if a.fuel_mass <= a.min_fuel_reserve
            break
        end

        simulation_step!(a, dt)

        elapsed += dt

    end

    disable_afterburner!(a)

    a.phase = CRUISE

end


# ============================================================
# TELEMETRY
# ============================================================

function telemetry(a)

    @printf(
        "TIME %7.1f s | MACH %5.2f | SPEED %7.1f m/s | " *
        "ALT %7.0f m | FUEL %7.2f t | THRUST %8.0f N | MODE %s\n",
        a.elapsed_time,
        a.mach,
        a.velocity,
        a.altitude,
        a.fuel_mass / 1000,
        engine_thrust(a),
        string(a.engine_mode)
    )

end


# ============================================================
# LIVE SIMULATION
# ============================================================

function run_live!(a, duration)

    dt = 1.0

    elapsed = 0.0

    while elapsed < duration

        simulation_step!(a, dt)

        telemetry(a)

        elapsed += dt

        if a.engine_mode == IDLE
            break
        end

    end

end


# ============================================================
# AIRCRAFT FACTORY
# ============================================================

function create_demo_aircraft()

    return Aircraft(

        # Mass
        120_000.0,       # dry mass
        35_000.0,        # fuel

        # Flight
        12_000.0,        # altitude
        260.0,           # velocity
        0.0,             # Mach

        # Energy
        0.0,
        0.0,

        # Engines
        2,
        90_000.0,        # military thrust / engine
        145_000.0,       # AB thrust / engine

        # TSFC
        1.0 / 3600.0,
        2.0 / 3600.0,

        # Engine
        MILITARY,

        # Aerodynamics
        0.025,
        70.0,
        7.0,

        # Limits
        2.2,
        18_000.0,
        5_000.0,

        # State
        CRUISE,
        0.0
    )

end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    aircraft = create_demo_aircraft()

    update_mach!(aircraft)
    calculate_energy!(aircraft)

    println()
    println("==========================================")
    println(" JULIA AFTERBURNER SIMULATOR")
    println("==========================================")

    telemetry(aircraft)

    println()
    println("Requesting high-energy fuel burn...")

    request_energy_dump!(aircraft)

    run_live!(aircraft, 60.0)

    println()
    println("Final state:")

    telemetry(aircraft)

end


end # module


# ============================================================
# RUN
# ============================================================

using .AfterburnerEnergyManager

AfterburnerEnergyManager.demo()
