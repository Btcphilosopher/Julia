using Printf

# ============================================================
# ROTOR PERFORMANCE OPTIMISATION ENGINE
# Language: Julia
#
# Intended for:
#   - Preliminary helicopter rotor studies
#   - Aircraft propeller performance studies
#   - eVTOL rotor simulation
#
# WARNING:
# This is an illustrative, simplified model.
# It is NOT validated for flight or flight-control use.
# ============================================================

# ------------------------------------------------------------
# 1. Rotor configuration
# ------------------------------------------------------------

Base.@kwdef struct RotorConfig
    radius::Float64 = 1.5          # Rotor radius (m)
    blade_count::Int = 4
    air_density::Float64 = 1.225    # kg/m^3
    target_thrust::Float64 = 3000.0 # N

    min_rpm::Float64 = 200.0
    max_rpm::Float64 = 900.0

    min_pitch_deg::Float64 = 2.0
    max_pitch_deg::Float64 = 14.0

    max_tip_mach::Float64 = 0.65
    speed_of_sound::Float64 = 340.0 # m/s

    max_power_kw::Float64 = 100.0
end

# ------------------------------------------------------------
# 2. Simplified aerodynamic model
# ------------------------------------------------------------

function rotor_performance(
    cfg::RotorConfig,
    rpm::Float64,
    pitch_deg::Float64
)
    # Angular velocity (rad/s)
    omega = rpm * 2π / 60.0

    # Rotor disc area
    area = π * cfg.radius^2

    # Blade-tip speed
    tip_speed = omega * cfg.radius

    # Tip Mach number
    tip_mach = tip_speed / cfg.speed_of_sound

    # Reject operating conditions outside model constraints
    if rpm < cfg.min_rpm || rpm > cfg.max_rpm
        return nothing
    end

    if pitch_deg < cfg.min_pitch_deg ||
       pitch_deg > cfg.max_pitch_deg
        return nothing
    end

    if tip_mach > cfg.max_tip_mach
        return nothing
    end

    # Simplified thrust model.
    # The coefficient is illustrative and requires calibration
    # against validated aerodynamic data for a real rotor.

    pitch = deg2rad(pitch_deg)

    thrust_coefficient = 0.006 * pitch

    thrust = thrust_coefficient *
             cfg.air_density *
             area *
             tip_speed^2

    # Do not divide by zero or use nonphysical thrust values.
    if thrust <= 0.0
        return nothing
    end

    # Ideal induced power for a hovering actuator disc.
    # This is a lower-bound approximation, not a complete
    # helicopter or propeller power model.

    induced_power = thrust^(3 / 2) /
                    sqrt(2.0 * cfg.air_density * area)

    # Illustrative profile-power model.
    # The coefficient must be identified experimentally or
    # derived from an appropriate blade-element model.

    profile_coefficient = 0.012

    profile_power = profile_coefficient *
                    cfg.air_density *
                    area *
                    tip_speed^3

    total_power = induced_power + profile_power

    # Power limit
    if total_power > cfg.max_power_kw * 1000.0
        return nothing
    end

    # Thrust-to-power ratio (N/W)
    efficiency_metric = thrust / total_power

    return (
        rpm = rpm,
        pitch_deg = pitch_deg,
        omega = omega,
        tip_speed = tip_speed,
        tip_mach = tip_mach,
        thrust = thrust,
        induced_power = induced_power,
        profile_power = profile_power,
        total_power = total_power,
        efficiency_metric = efficiency_metric
    )
end

# ------------------------------------------------------------
# 3. Operating-point optimisation
# ------------------------------------------------------------

function optimise_rotor(cfg::RotorConfig)

    best_result = nothing
    best_score = -Inf

    # Search candidate operating points.
    # The grid can later be replaced with a continuous optimiser.

    for rpm in range(
        cfg.min_rpm,
        cfg.max_rpm,
        length = 300
    )

        for pitch in range(
            cfg.min_pitch_deg,
            cfg.max_pitch_deg,
            length = 150
        )

            result = rotor_performance(
                cfg,
                rpm,
                pitch
            )

            isnothing(result) && continue

            # Penalise failure to reach target thrust.
            thrust_error = abs(
                result.thrust - cfg.target_thrust
            ) / cfg.target_thrust

            # Reject points that do not reach the required thrust.
            if result.thrust < cfg.target_thrust
                continue
            end

            # Prefer higher thrust per watt, subject to
            # the specified thrust and power constraints.

            score = result.efficiency_metric

            if score > best_score
                best_score = score
                best_result = result
            end
        end
    end

    return best_result
end

# ------------------------------------------------------------
# 4. Run the optimisation
# ------------------------------------------------------------

function main()

    config = RotorConfig(
        radius = 1.5,
        blade_count = 4,
        target_thrust = 3000.0,
        max_power_kw = 100.0
    )

    println("========================================")
    println(" ROTOR PERFORMANCE OPTIMISATION ENGINE")
    println("========================================")

    result = optimise_rotor(config)

    if isnothing(result)
        println("No feasible operating point found.")
        println("Review the model assumptions and constraints.")
        return
    end

    println("\nOPTIMISED OPERATING POINT")
    println("----------------------------------------")

    @printf("Rotational speed: %.1f RPM\n", result.rpm)
    @printf("Blade pitch:      %.2f degrees\n",
            result.pitch_deg)

    @printf("Tip speed:        %.2f m/s\n",
            result.tip_speed)

    @printf("Tip Mach number:  %.3f\n",
            result.tip_mach)

    @printf("Modelled thrust:  %.1f N\n",
            result.thrust)

    @printf("Induced power:    %.2f kW\n",
            result.induced_power / 1000.0)

    @printf("Profile power:    %.2f kW\n",
            result.profile_power / 1000.0)

    @printf("Total power:      %.2f kW\n",
            result.total_power / 1000.0)

    @printf("Thrust per watt:  %.5f N/W\n",
            result.efficiency_metric)

    println("\nNote: Results depend on the illustrative")
    println("model coefficients and are not flight-valid.")
end

main()




# BAE Propulsion Optimiser — integrated Julia research prototype
#
# Modules:
#   A. Blade-element / momentum-inspired propeller model
#   B. Engine–gearbox–propeller matching
#   C. Whole-aircraft drag, level-flight, and climb estimates
#   D. RPM / pitch operating-point search and CSV reporting
#
# SAFETY / VALIDATION:
# This is an educational preliminary-design prototype, not certified
# engineering software. Its airfoil model is generic, and its sample blade,
# engine curve, and aircraft drag data are illustrative. Do not use results
# to manufacture, modify, certify, or operate an aircraft. Replace all
# example inputs with validated manufacturer/test data and have the model
# independently reviewed by qualified aerospace engineers.
#
# Run:
#   julia bae_propulsion_system.jl
#
# No external packages are required.

using Printf
using Statistics
using DelimitedFiles

# ============================================================
# 1. Basic data structures and atmosphere
# ============================================================

Base.@kwdef struct Atmosphere
    density_kgm3::Float64 = 1.225
    speed_of_sound_mps::Float64 = 340.3
    temperature_K::Float64 = 288.15
end

Base.@kwdef struct EngineConfig
    name::String = "Illustrative 100 hp-class piston engine"
    max_takeoff_power_W::Float64 = 73_500.0
    max_continuous_power_W::Float64 = 72_000.0
    max_engine_rpm::Float64 = 5_800.0
    min_engine_rpm::Float64 = 1_500.0
    reduction_ratio::Float64 = 2.43
    gearbox_efficiency::Float64 = 0.97
    # The curve below is an illustrative fraction of rated power.
    # Replace it with validated engine manufacturer data.
    rpm_fraction::Vector{Float64} = [0.30, 0.40, 0.50, 0.60, 0.70,
                                    0.80, 0.90, 1.00]
    power_fraction::Vector{Float64} = [0.35, 0.49, 0.63, 0.75, 0.85,
                                      0.93, 0.98, 1.00]
end

Base.@kwdef struct AircraftConfig
    name::String = "Concept two-seat light aircraft"
    mass_kg::Float64 = 650.0
    wing_area_m2::Float64 = 10.5
    aspect_ratio::Float64 = 7.5
    oswald_efficiency::Float64 = 0.80
    zero_lift_drag_coefficient::Float64 = 0.032
    propulsive_installation_factor::Float64 = 0.96
    max_lift_coefficient::Float64 = 1.5
end

Base.@kwdef struct PropellerConfig
    name::String = "Illustrative two-blade propeller"
    diameter_m::Float64 = 1.80
    blade_count::Int = 2
    hub_radius_ratio::Float64 = 0.18
    min_prop_rpm::Float64 = 900.0
    max_prop_rpm::Float64 = 2_350.0
    max_tip_mach::Float64 = 0.75
    # Simple radial blade geometry. Replace with actual measured geometry.
    radial_fraction::Vector{Float64} = collect(0.20:0.05:0.95)
    chord_m::Vector{Float64} = [0.145, 0.150, 0.155, 0.158, 0.160,
                                0.160, 0.157, 0.152, 0.146, 0.138,
                                0.128, 0.116, 0.103, 0.088, 0.070,
                                0.050]
    twist_deg::Vector{Float64} = [34.0, 31.5, 29.0, 26.8, 24.8,
                                  22.8, 20.9, 19.1, 17.3, 15.7,
                                  14.2, 12.8, 11.5, 10.3, 9.2,
                                  8.2]
    collective_min_deg::Float64 = -5.0
    collective_max_deg::Float64 = 15.0
end

# Check geometry lengths when configurations are created.
function validate_config(engine::EngineConfig, aircraft::AircraftConfig,
                         prop::PropellerConfig)
    length(prop.radial_fraction) == length(prop.chord_m) ||
        error("radial_fraction and chord_m must have equal lengths")
    length(prop.radial_fraction) == length(prop.twist_deg) ||
        error("radial_fraction and twist_deg must have equal lengths")
    length(prop.radial_fraction) >= 4 ||
        error("At least four radial stations are required")
    issorted(prop.radial_fraction) ||
        error("radial_fraction must be sorted")
    all((0 .< prop.radial_fraction) .& (prop.radial_fraction .< 1)) ||
        error("Radial stations must lie between 0 and 1")
    all(prop.chord_m .> 0) || error("All chord values must be positive")
    prop.blade_count >= 2 || error("blade_count must be at least 2")
    prop.diameter_m > 0 || error("Propeller diameter must be positive")
    engine.reduction_ratio > 0 || error("Gearbox ratio must be positive")
    aircraft.mass_kg > 0 || error("Aircraft mass must be positive")
    return true
end

# ============================================================
# 2. Generic airfoil polar (illustrative only)
# ============================================================

"""
    airfoil_coefficients(alpha_rad)

Return generic lift and drag coefficients for a conceptual airfoil.
This is a deliberately simple analytic approximation; it is not an
airfoil database and does not predict real stall or compressibility well.
Use measured or validated XFOIL / wind-tunnel polars for real work.
"""
function airfoil_coefficients(alpha_rad::Float64)
    alpha_deg = rad2deg(alpha_rad)

    # Linear lift region with a soft stall cap.
    cl_linear = 2π * alpha_rad
    cl_limit = 1.15
    cl = cl_limit * tanh(cl_linear / cl_limit)

    # Symmetric generic drag polar.
    cd = 0.010 + 0.018 * cl^2

    # Beyond the nominal linear region, apply a crude drag rise.
    if abs(alpha_deg) > 12.0
        cd += 0.0015 * (abs(alpha_deg) - 12.0)^2
    end

    return cl, cd
end

# ============================================================
# 3. Engine power curve and gearbox matching
# ============================================================

function interpolate_curve(x::Vector{Float64}, y::Vector{Float64}, value::Float64)
    length(x) == length(y) || error("Curve x/y lengths differ")
    value < first(x) && return first(y)
    value > last(x) && return last(y)
    i = clamp(searchsortedlast(x, value), 1, length(x)-1)
    t = (value - x[i]) / (x[i+1] - x[i])
    return (1-t) * y[i] + t * y[i+1]
end

function available_engine_power(engine::EngineConfig, engine_rpm::Float64;
                                continuous::Bool=true)
    rated = continuous ? engine.max_continuous_power_W :
                         engine.max_takeoff_power_W
    rpm_fraction = engine_rpm / engine.max_engine_rpm
    fraction = interpolate_curve(engine.rpm_fraction,
                                 engine.power_fraction, rpm_fraction)
    if engine_rpm < engine.min_engine_rpm ||
       engine_rpm > engine.max_engine_rpm
        return 0.0
    end
    return rated * fraction
end

function engine_torque_Nm(power_W::Float64, rpm::Float64)
    rpm <= 0 && return 0.0
    return power_W / (rpm * 2π / 60.0)
end

# ============================================================
# 4. Blade-element / momentum-inspired propeller model
# ============================================================

"""
    blade_element_propeller(...)

Integrates blade-element forces over radial blade stations.

The induced axial velocity is iterated using an annular momentum relation.
This is a simplified BEM-style model; it omits several effects needed for
reliable design (swirl coupling, detailed hub/tip losses, Reynolds-dependent
polars, robust high-Mach corrections, and validated stall behaviour).
"""
function blade_element_propeller(
    engine::EngineConfig,
    prop::PropellerConfig,
    atm::Atmosphere,
    airspeed_mps::Float64,
    prop_rpm::Float64,
    collective_deg::Float64;
    continuous::Bool=true,
    induced_iterations::Int=80
)
    D = prop.diameter_m
    R = D / 2
    omega = prop_rpm * 2π / 60
    n = prop_rpm / 60
    rho = atm.density_kgm3

    prop.min_prop_rpm <= prop_rpm <= prop.max_prop_rpm || return nothing
    engine_rpm = prop_rpm * engine.reduction_ratio
    engine.min_engine_rpm <= engine_rpm <= engine.max_engine_rpm || return nothing

    # Helical tip speed estimate.
    tip_speed = hypot(airspeed_mps, omega * R)
    tip_mach = tip_speed / atm.speed_of_sound_mps
    tip_mach <= prop.max_tip_mach || return nothing

    rfrac = prop.radial_fraction
    r = rfrac .* R
    chords = prop.chord_m
    twists = prop.twist_deg
    length(r) == length(chords) == length(twists) || error("Geometry mismatch")

    thrust_total = 0.0
    torque_total = 0.0
    stalled_fraction = 0
    station_count = length(r)

    for i in 1:(station_count-1)
        ri = 0.5 * (r[i] + r[i+1])
        dr = r[i+1] - r[i]
        chord = 0.5 * (chords[i] + chords[i+1])
        twist = 0.5 * (twists[i] + twists[i+1]) + collective_deg
        vi = max(0.1, 0.05 * max(airspeed_mps, 1.0))

        dT = 0.0
        dQ = 0.0

        for _ in 1:induced_iterations
            axial_velocity = max(0.1, airspeed_mps + vi)
            tangential_velocity = omega * ri
            W = hypot(axial_velocity, tangential_velocity)
            phi = atan(axial_velocity, tangential_velocity)
            alpha = deg2rad(twist) - phi
            cl, cd = airfoil_coefficients(alpha)

            abs(rad2deg(alpha)) > 12 && (stalled_fraction += 1)

            q = 0.5 * rho * W^2
            lift_per_span = q * chord * cl
            drag_per_span = q * chord * cd

            # Resolve sectional lift/drag into axial thrust and torque.
            dT_blade = prop.blade_count *
                       (lift_per_span * cos(phi) - drag_per_span * sin(phi)) * dr
            dQ_blade = prop.blade_count *
                       (lift_per_span * sin(phi) + drag_per_span * cos(phi)) *
                       ri * dr

            # Annular momentum estimate for axial induced velocity.
            # Use only positive-thrust annuli for this simple relation.
            dT_momentum = 4π * rho * ri * max(vi, 0.0) *
                          max(airspeed_mps + vi, 0.1) * dr

            if dT_blade <= 0
                vi_new = max(0.0, vi * 0.75)
            else
                # Relaxation damps oscillation in this simplified solver.
                ratio = dT_blade / max(dT_momentum, 1e-6)
                vi_new = max(0.0, vi * (0.65 + 0.35 * clamp(ratio, 0.2, 2.0)))
            end

            dT = dT_blade
            dQ = dQ_blade

            if abs(vi_new - vi) < 1e-4
                vi = vi_new
                break
            end
            vi = 0.55 * vi + 0.45 * vi_new
        end

        thrust_total += dT
        torque_total += dQ
    end

    power_W = torque_total * omega
    power_W > 0 || return nothing
    thrust_total > 0 || return nothing

    engine_power_available = available_engine_power(engine, engine_rpm;
                                                    continuous=continuous)
    shaft_power_at_prop = engine_power_available * engine.gearbox_efficiency
    power_W <= shaft_power_at_prop || return nothing

    eta = airspeed_mps > 0 ? thrust_total * airspeed_mps / power_W : 0.0
    ct = thrust_total / (rho * n^2 * D^4)
    cp = power_W / (rho * n^3 * D^5)

    return (
        prop_rpm=prop_rpm,
        engine_rpm=engine_rpm,
        collective_deg=collective_deg,
        thrust_N=thrust_total,
        torque_Nm=torque_total,
        power_W=power_W,
        engine_power_available_W=engine_power_available,
        power_margin_W=shaft_power_at_prop-power_W,
        efficiency=eta,
        tip_speed_mps=tip_speed,
        tip_mach=tip_mach,
        Ct=ct,
        Cp=cp,
        stalled_station_fraction=stalled_fraction / max(station_count-1, 1)
    )
end

# ============================================================
# 5. Aircraft drag and flight performance
# ============================================================

function aircraft_drag(aircraft::AircraftConfig, atm::Atmosphere,
                       airspeed_mps::Float64)
    V = max(airspeed_mps, 0.0)
    q = 0.5 * atm.density_kgm3 * V^2
    e = max(aircraft.oswald_efficiency, 0.1)
    induced_factor = 1 / (π * aircraft.aspect_ratio * e)
    # Simplified drag polar: CD = CD0 + k CL^2.
    weight_N = aircraft.mass_kg * 9.80665
    CL = V > 0 ? weight_N / max(q * aircraft.wing_area_m2, 1e-6) : Inf
    if !isfinite(CL) || CL > aircraft.max_lift_coefficient
        return (drag_N=Inf, CL=CL, CD=Inf, lift_feasible=false)
    end
    CD = aircraft.zero_lift_drag_coefficient + induced_factor * CL^2
    drag = q * aircraft.wing_area_m2 * CD
    return (drag_N=drag, CL=CL, CD=CD, lift_feasible=true)
end

function aircraft_flight_point(
    engine::EngineConfig,
    aircraft::AircraftConfig,
    prop::PropellerConfig,
    atm::Atmosphere,
    airspeed_mps::Float64,
    prop_rpm::Float64,
    collective_deg::Float64;
    continuous::Bool=true
)
    p = blade_element_propeller(engine, prop, atm, airspeed_mps,
                                prop_rpm, collective_deg;
                                continuous=continuous)
    isnothing(p) && return nothing

    drag = aircraft_drag(aircraft, atm, airspeed_mps)
    drag.lift_feasible || return nothing

    available_thrust = p.thrust_N * aircraft.propulsive_installation_factor
    excess_thrust = available_thrust - drag.drag_N
    climb_rate = excess_thrust * airspeed_mps /
                 (aircraft.mass_kg * 9.80665)

    return merge(p, (
        drag_N=drag.drag_N,
        lift_coefficient=drag.CL,
        drag_coefficient=drag.CD,
        available_thrust_N=available_thrust,
        excess_thrust_N=excess_thrust,
        estimated_climb_rate_mps=climb_rate,
        level_flight_feasible=(excess_thrust >= 0)
    ))
end

# ============================================================
# 6. Constrained grid optimiser
# ============================================================

function optimise_operating_point(
    engine::EngineConfig,
    aircraft::AircraftConfig,
    prop::PropellerConfig,
    atm::Atmosphere,
    airspeed_mps::Float64;
    min_thrust_N::Float64=0.0,
    objective::Symbol=:efficiency,
    continuous::Bool=true,
    rpm_steps::Int=90,
    pitch_steps::Int=70
)
    objective in (:efficiency, :thrust, :climb) ||
        error("objective must be :efficiency, :thrust, or :climb")

    best = nothing
    best_score = -Inf
    feasible = 0

    rpms = range(prop.min_prop_rpm, prop.max_prop_rpm, length=rpm_steps)
    pitches = range(prop.collective_min_deg, prop.collective_max_deg,
                    length=pitch_steps)

    for rpm in rpms, pitch in pitches
        r = aircraft_flight_point(engine, aircraft, prop, atm,
                                  airspeed_mps, rpm, pitch;
                                  continuous=continuous)
        isnothing(r) && continue
        r.thrust_N >= min_thrust_N || continue
        feasible += 1

        score = if objective == :efficiency
            r.efficiency
        elseif objective == :thrust
            r.thrust_N
        else
            r.estimated_climb_rate_mps
        end

        if isfinite(score) && score > best_score
            best_score = score
            best = r
        end
    end

    return (best=best, feasible_count=feasible, objective=objective,
            airspeed_mps=airspeed_mps)
end

# ============================================================
# 7. Sweep airspeed for a conceptual performance table
# ============================================================

function sweep_airspeeds(
    engine::EngineConfig,
    aircraft::AircraftConfig,
    prop::PropellerConfig,
    atm::Atmosphere;
    speeds_mps=collect(25.0:5.0:80.0),
    objective::Symbol=:efficiency,
    continuous::Bool=true
)
    rows = Vector{Vector{Float64}}()
    for V in speeds_mps
        result = optimise_operating_point(engine, aircraft, prop, atm, V;
                                          objective=objective,
                                          continuous=continuous)
        if isnothing(result.best)
            push!(rows, [V, NaN, NaN, NaN, NaN, NaN, NaN])
        else
            r = result.best
            push!(rows, [
                V,
                r.prop_rpm,
                r.collective_deg,
                r.thrust_N,
                r.power_W,
                r.efficiency,
                r.estimated_climb_rate_mps
            ])
        end
    end
    return rows
end

function write_csv(path::String, rows::Vector{Vector{Float64}})
    open(path, "w") do io
        println(io, "airspeed_mps,prop_rpm,collective_deg,thrust_N,prop_power_W,efficiency,estimated_climb_rate_mps")
        for row in rows
            println(io, join((isfinite(x) ? string(x) : "" for x in row), ","))
        end
    end
    println("Wrote CSV: ", path)
end

# ============================================================
# 8. Report
# ============================================================

function print_report(engine, aircraft, prop, atm, result)
    println("\nBAE PROPULSION OPTIMISER — PRELIMINARY MODEL")
    println("="^55)
    println("Aircraft:  ", aircraft.name)
    println("Engine:    ", engine.name)
    println("Propeller: ", prop.name)
    @printf("Mass: %.1f kg | Prop diameter: %.2f m | Blades: %d\n",
            aircraft.mass_kg, prop.diameter_m, prop.blade_count)
    @printf("Density: %.3f kg/m³ | Airspeed: %.1f m/s (%.1f km/h)\n",
            atm.density_kgm3, result.airspeed_mps, result.airspeed_mps*3.6)
    println("Objective: ", result.objective)
    println("Feasible grid points: ", result.feasible_count)

    if isnothing(result.best)
        println("\nNo feasible point found.")
        println("Check model inputs and constraints; do not treat this as proof")
        println("that a real aircraft configuration is infeasible.")
        return
    end

    r = result.best
    println("\nBEST CANDIDATE IN THE MODEL")
    println("-"^55)
    @printf("Propeller RPM:             %.0f rpm\n", r.prop_rpm)
    @printf("Engine RPM:                %.0f rpm\n", r.engine_rpm)
    @printf("Collective setting:        %.2f deg (generic model parameter)\n",
            r.collective_deg)
    @printf("Modelled thrust:           %.1f N\n", r.thrust_N)
    @printf("Modelled propeller power:  %.2f kW\n", r.power_W/1000)
    @printf("Available prop shaft power:%.2f kW\n",
            r.engine_power_available_W * engine.gearbox_efficiency/1000)
    @printf("Power margin:              %.2f kW\n", r.power_margin_W/1000)
    @printf("Propulsive efficiency:     %.1f %%\n", 100*r.efficiency)
    @printf("Tip Mach estimate:         %.3f\n", r.tip_mach)
    @printf("Aircraft drag estimate:    %.1f N\n", r.drag_N)
    @printf("Lift coefficient estimate: %.3f\n", r.lift_coefficient)
    @printf("Excess thrust estimate:    %.1f N\n", r.excess_thrust_N)
    @printf("Climb-rate estimate:       %.2f m/s\n",
            r.estimated_climb_rate_mps)
    println("\nAll outputs depend on unvalidated illustrative inputs.")
end

# ============================================================
# 9. Main program
# ============================================================

function main()
    engine = EngineConfig()
    aircraft = AircraftConfig()
    prop = PropellerConfig()
    atm = Atmosphere()

    validate_config(engine, aircraft, prop)

    # Illustrative cruise condition only; not a claim about the brochure's
    # advertised speed or the real aircraft's certified flight envelope.
    cruise_speed_mps = 55.0

    result = optimise_operating_point(
        engine, aircraft, prop, atm, cruise_speed_mps;
        objective=:efficiency,
        continuous=true,
        rpm_steps=90,
        pitch_steps=70
    )

    print_report(engine, aircraft, prop, atm, result)

    # Sweep a range of airspeeds and save candidate results.
    rows = sweep_airspeeds(
        engine, aircraft, prop, atm;
        speeds_mps=collect(25.0:5.0:80.0),
        objective=:efficiency,
        continuous=true
    )
    write_csv("bae_propeller_sweep.csv", rows)

    println("\nValidation checklist before any real engineering use:")
    println("  1. Replace the engine curve with the exact engine/gearbox data.")
    println("  2. Replace sample blade geometry and generic airfoil model.")
    println("  3. Validate against propeller test data over the full operating range.")
    println("  4. Add Reynolds/Mach corrections, swirl, hub/tip losses, and uncertainty.")
    println("  5. Validate aircraft drag and lift model against flight-test data.")
    println("  6. Obtain independent aerospace engineering review.")
    println("\nThis program is not for flight control, certification, or flight decisions.")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end






