```julia
# ================================================================
# ROTOROPT
# Julia Rotor Blade Aerodynamic Optimisation Engine
#
# Simplified Blade Element Momentum / Blade Element model
#
# Designed as a research / conceptual engineering simulator.
#
# Optimises:
#   - chord distribution
#   - twist distribution
#   - rotational speed
#   - thrust
#   - power
#   - torque
#   - blade mass
#   - centrifugal load
#   - bending load
#   - efficiency
#
# No external packages required.
# ================================================================

using Random
using Statistics
using Printf

Random.seed!(42)

# ================================================================
# PHYSICAL CONSTANTS
# ================================================================

const RHO = 1.225       # kg/m³
const MU_AIR = 1.81e-5  # Pa·s
const G = 9.80665

# ================================================================
# ROTOR CONFIGURATION
# ================================================================

struct RotorConfig

    radius_m::Float64

    hub_radius_m::Float64

    blade_count::Int

    rotational_speed_rpm::Float64

    air_density::Float64

    target_thrust_N::Float64

    max_tip_speed_mps::Float64

    max_power_W::Float64

    blade_material_density::Float64

    blade_thickness_ratio::Float64
end


const ROTOR = RotorConfig(

    7.0,       # radius

    0.8,       # hub radius

    4,         # blades

    300.0,     # RPM

    RHO,

    55_000.0,  # target thrust

    240.0,     # tip-speed limit

    900_000.0, # power limit

    1600.0,    # composite-equivalent density

    0.10
)

# ================================================================
# BLADE DESIGN
# ================================================================

struct BladeDesign

    radial_positions::Vector{Float64}

    chord_m::Vector{Float64}

    twist_deg::Vector{Float64}

    thickness::Vector{Float64}
end


function initial_blade(
    config::RotorConfig,
    sections::Int = 20
)

    r =
        collect(
            range(
                config.hub_radius_m,
                config.radius_m,
                length=sections
            )
        )

    chord = Float64[]

    twist = Float64[]

    thickness = Float64[]

    for x in r

        normalized =
            (
                x -
                config.hub_radius_m
            ) /
            (
                config.radius_m -
                config.hub_radius_m
            )

        # Tapered blade

        c =
            0.55 -
            0.25 *
            normalized

        push!(
            chord,
            c
        )

        # Washout

        θ =
            14.0 -
            10.0 *
            normalized

        push!(
            twist,
            θ
        )

        push!(
            thickness,
            config.blade_thickness_ratio
        )
    end

    return BladeDesign(
        r,
        chord,
        twist,
        thickness
    )
end

# ================================================================
# AIRFOIL MODEL
# ================================================================

function airfoil_coefficients(
    α_deg::Float64
)

    α =
        deg2rad(
            α_deg
        )

    # Simplified lift curve

    cl =
        2π * α

    # Stall limiter

    cl =
        clamp(
            cl,
            -1.4,
            1.4
        )

    # Simplified drag polar

    cd0 = 0.012

    induced_drag =
        0.018 *
        cl^2

    cd =
        cd0 +
        induced_drag

    return cl, cd
end

# ================================================================
# ROTATIONAL SPEED
# ================================================================

function angular_velocity(
    config::RotorConfig
)

    return (
        config.rotational_speed_rpm *
        2π /
        60.0
    )
end


function tip_speed(
    config::RotorConfig
)

    return (
        angular_velocity(config) *
        config.radius_m
    )
end

# ================================================================
# SECTION AERODYNAMICS
# ================================================================

struct SectionResult

    radius_m::Float64

    velocity_mps::Float64

    angle_of_attack_deg::Float64

    lift_N::Float64

    drag_N::Float64

    torque_Nm::Float64

    power_W::Float64
end

# ================================================================
# ROTOR PERFORMANCE
# ================================================================

struct RotorPerformance

    thrust_N::Float64

    torque_Nm::Float64

    power_W::Float64

    figure_of_merit::Float64

    efficiency::Float64

    blade_mass_kg::Float64

    centrifugal_force_N::Float64

    bending_moment_Nm::Float64

    tip_speed_mps::Float64

    max_section_AoA_deg::Float64
end

# ================================================================
# SECTION CALCULATION
# ================================================================

function section_performance(

    r::Float64,

    chord::Float64,

    twist_deg::Float64,

    config::RotorConfig

)

    ω =
        angular_velocity(
            config
        )

    tangential_velocity =
        ω * r

    # Simplified induced velocity model

    induced_velocity =
        sqrt(
            config.target_thrust_N /
            (
                2.0 *
                config.air_density *
                π *
                config.radius_m^2
            )
        )

    velocity =
        sqrt(
            tangential_velocity^2 +
            induced_velocity^2
        )

    inflow_angle =
        atan(
            induced_velocity /
            tangential_velocity
        )

    inflow_angle_deg =
        rad2deg(
            inflow_angle
        )

    AoA =
        twist_deg -
        inflow_angle_deg

    cl, cd =
        airfoil_coefficients(
            AoA
        )

    dynamic_pressure =
        0.5 *
        config.air_density *
        velocity^2

    # Small radial element.
    # Actual integration performed by caller.

    return (
        velocity,
        AoA,
        cl,
        cd,
        dynamic_pressure
    )
end

# ================================================================
# BLADE MASS
# ================================================================

function blade_mass(
    blade::BladeDesign,
    config::RotorConfig
)

    mass = 0.0

    for i in 1:length(
        blade.radial_positions
    )-1

        r1 =
            blade.radial_positions[i]

        r2 =
            blade.radial_positions[i+1]

        dr =
            r2 - r1

        c =
            (
                blade.chord_m[i] +
                blade.chord_m[i+1]
            ) / 2.0

        thickness =
            (
                blade.thickness[i] +
                blade.thickness[i+1]
            ) / 2.0

        # Approximate blade cross-section

        area =
            c *
            thickness

        volume =
            area *
            dr

        mass +=
            volume *
            config.blade_material_density
    end

    return mass
end

# ================================================================
# CENTRIFUGAL LOAD
# ================================================================

function centrifugal_force(
    blade::BladeDesign,
    config::RotorConfig
)

    ω =
        angular_velocity(
            config
        )

    total = 0.0

    for i in 1:length(
        blade.radial_positions
    )-1

        r1 =
            blade.radial_positions[i]

        r2 =
            blade.radial_positions[i+1]

        dr =
            r2 - r1

        c =
            (
                blade.chord_m[i] +
                blade.chord_m[i+1]
            ) / 2.0

        t =
            (
                blade.thickness[i] +
                blade.thickness[i+1]
            ) / 2.0

        mass_per_length =
            c *
            t *
            config.blade_material_density

        r =
            (
                r1 + r2
            ) / 2.0

        total +=
            mass_per_length *
            dr *
            ω^2 *
            r
    end

    return total
end

# ================================================================
# ROTOR EVALUATION
# ================================================================

function evaluate_rotor(

    blade::BladeDesign,

    config::RotorConfig

)

    ω =
        angular_velocity(
            config
        )

    thrust = 0.0

    torque = 0.0

    max_AoA = 0.0

    bending = 0.0

    sections =
        length(
            blade.radial_positions
        )

    for i in 1:sections-1

        r1 =
            blade.radial_positions[i]

        r2 =
            blade.radial_positions[i+1]

        dr =
            r2 - r1

        r =
            (
                r1 + r2
            ) / 2.0

        chord =
            (
                blade.chord_m[i] +
                blade.chord_m[i+1]
            ) / 2.0

        twist =
            (
                blade.twist_deg[i] +
                blade.twist_deg[i+1]
            ) / 2.0

        velocity,
        AoA,
        cl,
        cd,
        q =
            section_performance(
                r,
                chord,
                twist,
                config
            )

        dL =
            q *
            chord *
            cl *
            dr

        dD =
            q *
            chord *
            cd *
            dr

        # Convert lift/drag into thrust
        # relative to rotor plane

        inflow =
            atan(
                velocity /
                max(
                    ω*r,
                    1e-6
                )
            )

        dT =
            dL *
            cos(inflow) -
            dD *
            sin(inflow)

        thrust +=
            config.blade_count *
            dT

        dQ =
            (
                dL *
                sin(inflow) +
                dD *
                cos(inflow)
            ) *
            r

        torque +=
            config.blade_count *
            dQ

        bending +=
            config.blade_count *
            dT *
            r

        max_AoA =
            max(
                max_AoA,
                abs(AoA)
            )
    end

    power =
        torque *
        ω

    mass =
        blade_mass(
            blade,
            config
        )

    centrifugal =
        centrifugal_force(
            blade,
            config
        )

    # Ideal induced power

    disk_area =
        π *
        config.radius_m^2

    induced_power =
        config.target_thrust_N *
        sqrt(
            config.target_thrust_N /
            (
                2.0 *
                config.air_density *
                disk_area
            )
        )

    figure_of_merit =
        induced_power /
        max(
            power,
            1.0
        )

    efficiency =
        config.target_thrust_N /
        max(
            power,
            1.0
        )

    return RotorPerformance(

        thrust,

        torque,

        power,

        figure_of_merit,

        efficiency,

        mass,

        centrifugal,

        bending,

        tip_speed(config),

        max_AoA
    )
end

# ================================================================
# OBJECTIVE FUNCTION
# ================================================================

function objective(

    blade::BladeDesign,

    config::RotorConfig

)

    performance =
        evaluate_rotor(
            blade,
            config
        )

    # Target thrust error

    thrust_error =
        abs(
            performance.thrust_N -
            config.target_thrust_N
        ) /
        config.target_thrust_N

    # Penalise excessive power

    power_penalty =
        max(
            0.0,
            performance.power_W /
            config.max_power_W -
            1.0
        )

    # Penalise excessive AoA

    AoA_penalty =
        max(
            0.0,
            performance.max_section_AoA_deg -
            12.0
        ) / 12.0

    # Penalise excessive tip speed

    tip_penalty =
        max(
            0.0,
            performance.tip_speed_mps /
            config.max_tip_speed_mps -
            1.0
        )

    # Penalise excessive blade mass

    mass_penalty =
        performance.blade_mass_kg /
        30.0

    # Lower is better

    score =
        100.0 *
        thrust_error +
        1000.0 *
        power_penalty +
        100.0 *
        AoA_penalty +
        1000.0 *
        tip_penalty +
        0.5 *
        mass_penalty

    return score
end

# ================================================================
# MUTATION
# ================================================================

function mutate_blade(

    blade::BladeDesign,

    strength::Float64 = 0.05

)

    new_chord =
        copy(
            blade.chord_m
        )

    new_twist =
        copy(
            blade.twist_deg
        )

    new_thickness =
        copy(
            blade.thickness
        )

    for i in eachindex(
        new_chord
    )

        new_chord[i] *=
            1.0 +
            randn() *
            strength

        new_twist[i] +=
            randn() *
            strength *
            10.0

        new_thickness[i] *=
            1.0 +
            randn() *
            strength
    end

    # Physical bounds

    new_chord =
        clamp.(
            new_chord,
            0.15,
            0.80
        )

    new_twist =
        clamp.(
            new_twist,
            -5.0,
            25.0
        )

    new_thickness =
        clamp.(
            new_thickness,
            0.06,
            0.18
        )

    return BladeDesign(

        blade.radial_positions,

        new_chord,

        new_twist,

        new_thickness
    )
end

# ================================================================
# EVOLUTIONARY OPTIMISER
# ================================================================

function optimise_rotor(

    config::RotorConfig;

    generations::Int = 150,

    population_size::Int = 40

)

    initial =
        initial_blade(
            config
        )

    population =
        [
            mutate_blade(
                initial,
                0.15
            )
            for _ in 1:population_size
        ]

    best =
        initial

    best_score =
        objective(
            best,
            config
        )

    for generation in
        1:generations

        scores =
            [
                objective(
                    blade,
                    config
                )
                for blade in population
            ]

        order =
            sortperm(
                scores
            )

        population =
            population[
                order
            ]

        scores =
            scores[
                order
            ]

        if scores[1] <
           best_score

            best =
                population[1]

            best_score =
                scores[1]

            performance =
                evaluate_rotor(
                    best,
                    config
                )

            @printf(
                "Generation %3d | Score %9.3f | " *
                "Thrust %9.1f N | Power %9.1f kW | " *
                "Mass %6.2f kg\n",

                generation,

                best_score,

                performance.thrust_N,

                performance.power_W / 1000.0,

                performance.blade_mass_kg
            )
        end

        # Elitism

        elite_count =
            max(
                2,
                population_size ÷ 5
            )

        new_population =
            population[
                1:elite_count
            ]

        while length(
            new_population
        ) < population_size

            parent =
                population[
                    rand(
                        1:elite_count
                    )
                ]

            child =
                mutate_blade(
                    parent,
                    0.04
                )

            push!(
                new_population,
                child
            )
        end

        population =
            new_population
    end

    return best
end

# ================================================================
# BLADE REPORT
# ================================================================

function blade_report(

    blade::BladeDesign,

    config::RotorConfig

)

    performance =
        evaluate_rotor(
            blade,
            config
        )

    println()
    println(
        "================================================"
    )

    println(
        " ROTOROPT FINAL DESIGN"
    )

    println(
        "================================================"
    )

    @printf(
        "Radius:              %.3f m\n",
        config.radius_m
    )

    @printf(
        "Blade count:         %d\n",
        config.blade_count
    )

    @printf(
        "RPM:                 %.1f\n",
        config.rotational_speed_rpm
    )

    @printf(
        "Tip speed:           %.2f m/s\n",
        performance.tip_speed_mps
    )

    @printf(
        "Thrust:              %.2f N\n",
        performance.thrust_N
    )

    @printf(
        "Torque:              %.2f Nm\n",
        performance.torque_Nm
    )

    @printf(
        "Power:               %.2f kW\n",
        performance.power_W / 1000.0
    )

    @printf(
        "Blade mass:          %.2f kg\n",
        performance.blade_mass_kg
    )

    @printf(
        "Centrifugal load:    %.2f kN\n",
        performance.centrifugal_force_N /
        1000.0
    )

    @printf(
        "Root bending proxy:  %.2f kNm\n",
        performance.bending_moment_Nm /
        1000.0
    )

    @printf(
        "Max section AoA:     %.2f°\n",
        performance.max_section_AoA_deg
    )

    @printf(
        "Figure of merit:     %.4f\n",
        performance.figure_of_merit
    )

    println()
    println(
        "RADIAL BLADE GEOMETRY"
    )

    println(
        "r [m]       chord [m]       twist [deg]"
    )

    for i in eachindex(
        blade.radial_positions
    )

        @printf(
            "%6.2f       %8.4f       %8.3f\n",

            blade.radial_positions[i],

            blade.chord_m[i],

            blade.twist_deg[i]
        )
    end

    println(
        "================================================"
    )
end

# ================================================================
# RUN
# ================================================================

println(
    "Starting ROTOROPT..."
)

println()

println(
    "Natural design optimisation beginning..."
)

best_blade =
    optimise_rotor(

        ROTOR;

        generations = 150,

        population_size = 40
    )

blade_report(
    best_blade,
    ROTOR
)
```

