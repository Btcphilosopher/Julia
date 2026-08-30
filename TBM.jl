module TBMOptimiser

using Printf
using Statistics

# ============================================================
# TUNNEL BORING MACHINE
# CUT-SPEED / PENETRATION OPTIMISER
#
# Pure Julia
#
# Optimises:
#   - Cutterhead RPM
#   - Thrust
#   - Penetration per revolution
#   - Advance rate
#   - Cutterhead power
#
# Subject to:
#   - Maximum thrust
#   - Maximum torque
#   - Maximum motor power
#   - Maximum cutter load
#   - Maximum cutterhead RPM
#   - Thermal limits
#   - Geological conditions
#
# This is intended as a simulation / decision-support layer.
# Real TBM actuation requires validated machine-specific PLC,
# safety systems, interlocks and operator/geotechnical approval.
# ============================================================


# ============================================================
# GEOLOGY
# ============================================================

struct RockCondition

    ucs_mpa::Float64
    rqd_percent::Float64
    abrasivity::Float64

    fracture_factor::Float64
    water_factor::Float64

    mixed_face_factor::Float64
end


# ============================================================
# TBM LIMITS
# ============================================================

struct TBMLimits

    diameter_m::Float64

    max_thrust_kn::Float64
    max_torque_knm::Float64

    max_power_kw::Float64

    max_rpm::Float64
    min_rpm::Float64

    max_penetration_mm_rev::Float64

    max_cutter_load_kn::Float64

    max_temperature_c::Float64

    cutter_count::Int
    cutter_diameter_mm::Float64
end


# ============================================================
# TBM STATE
# ============================================================

mutable struct TBMState

    rpm::Float64

    thrust_kn::Float64
    torque_knm::Float64

    penetration_mm_rev::Float64
    advance_m_h::Float64

    power_kw::Float64

    cutter_load_kn::Float64

    motor_temperature_c::Float64

    specific_energy_kwh_m3::Float64

    cutter_wear_index::Float64

    utilisation::Float64
end


# ============================================================
# OPTIMISATION RESULT
# ============================================================

struct OptimisationResult

    rpm::Float64
    thrust_kn::Float64

    penetration_mm_rev::Float64
    advance_m_h::Float64

    torque_knm::Float64
    power_kw::Float64

    cutter_load_kn::Float64

    specific_energy_kwh_m3::Float64

    cutter_wear_index::Float64

    objective_score::Float64

    feasible::Bool
end


# ============================================================
# ROCK MODEL
# ============================================================

function rock_resistance(
    rock::RockCondition
)

    strength =
        clamp(
            rock.ucs_mpa /
            200.0,
            0.1,
            2.0
        )

    quality =
        clamp(
            rock.rqd_percent /
            100.0,
            0.1,
            1.0
        )

    fracture_relief =
        clamp(
            1.0 -
            rock.fracture_factor,
            0.1,
            1.0
        )

    mixed_penalty =
        1.0 +
        rock.mixed_face_factor

    return strength *
           quality *
           fracture_relief *
           mixed_penalty
end


# ============================================================
# CUTTER LOAD MODEL
# ============================================================

function cutter_load(
    thrust_kn::Float64,
    penetration_mm_rev::Float64,
    limits::TBMLimits,
    rock::RockCondition
)

    resistance =
        rock_resistance(
            rock
        )

    average_load =
        thrust_kn /
        limits.cutter_count

    penetration_factor =
        1.0 +
        penetration_mm_rev /
        10.0

    return average_load *
           penetration_factor *
           resistance
end


# ============================================================
# TORQUE MODEL
# ============================================================

function estimate_torque(
    thrust_kn::Float64,
    penetration_mm_rev::Float64,
    limits::TBMLimits,
    rock::RockCondition
)

    resistance =
        rock_resistance(
            rock
        )

    radius =
        limits.diameter_m /
        2.0

    penetration_factor =
        1.0 +
        penetration_mm_rev /
        20.0

    # Simplified supervisory torque model.

    torque =
        thrust_kn *
        radius *
        0.08 *
        resistance *
        penetration_factor

    return max(
        torque,
        0.0
    )
end


# ============================================================
# PENETRATION MODEL
# ============================================================

function estimate_penetration(
    thrust_kn::Float64,
    rpm::Float64,
    rock::RockCondition,
    limits::TBMLimits
)

    resistance =
        rock_resistance(
            rock
        )

    cutter_load =
        thrust_kn /
        limits.cutter_count

    # Simplified empirical response:
    #
    # More cutter load increases penetration,
    # but increasing rock resistance reduces it.

    base =
        0.045 *
        cutter_load

    penetration =
        base /
        max(
            resistance,
            0.1
        )

    # Extremely high RPM can reduce effective penetration
    # because cutter linear velocity becomes limiting.

    rpm_factor =
        clamp(
            1.0 -
            max(
                rpm -
                limits.max_rpm *
                0.70,
                0.0
            ) /
            (
                limits.max_rpm *
                0.40
            ),
            0.5,
            1.0
        )

    penetration *=
        rpm_factor

    return clamp(
        penetration,
        0.1,
        limits.max_penetration_mm_rev
    )
end


# ============================================================
# ADVANCE RATE
# ============================================================

function advance_rate(
    rpm::Float64,
    penetration_mm_rev::Float64
)

    # mm/rev × rev/min → m/h

    return (
        rpm *
        penetration_mm_rev *
        60.0
    ) /
    1000.0
end


# ============================================================
# POWER
# ============================================================

function estimate_power(
    torque_knm::Float64,
    rpm::Float64
)

    # P(kW) = 2πTN / 60
    # T in kNm.

    return (
        2.0 *
        π *
        torque_knm *
        rpm
    ) /
    60.0
end


# ============================================================
# SPECIFIC ENERGY
# ============================================================

function specific_energy(
    power_kw::Float64,
    advance_m_h::Float64,
    diameter_m::Float64
)

    area =
        π *
        diameter_m^2 /
        4.0

    excavation_rate =
        area *
        advance_m_h

    if excavation_rate <= 0

        return Inf
    end

    return power_kw /
           excavation_rate
end


# ============================================================
# CUTTER WEAR
# ============================================================

function cutter_wear(
    thrust_kn::Float64,
    penetration_mm_rev::Float64,
    rpm::Float64,
    rock::RockCondition,
    limits::TBMLimits
)

    load_factor =
        thrust_kn /
        limits.max_thrust_kn

    penetration_factor =
        penetration_mm_rev /
        limits.max_penetration_mm_rev

    speed_factor =
        rpm /
        limits.max_rpm

    return clamp(
        (
            0.45 *
            load_factor +
            0.30 *
            penetration_factor +
            0.25 *
            speed_factor
        ) *
        (
            0.5 +
            rock.abrasivity
        ),
        0.0,
        2.0
    )
end


# ============================================================
# MOTOR TEMPERATURE
# ============================================================

function motor_temperature(
    power_kw::Float64,
    rpm::Float64,
    limits::TBMLimits
)

    load =
        power_kw /
        limits.max_power_kw

    speed =
        rpm /
        limits.max_rpm

    return 40.0 +
           45.0 *
           load^1.5 +
           10.0 *
           speed
end


# ============================================================
# FEASIBILITY
# ============================================================

function feasible(
    result::OptimisationResult,
    limits::TBMLimits
)

    return (

        result.thrust_kn <=
        limits.max_thrust_kn

        &&

        result.torque_knm <=
        limits.max_torque_knm

        &&

        result.power_kw <=
        limits.max_power_kw

        &&

        result.rpm <=
        limits.max_rpm

        &&

        result.rpm >=
        limits.min_rpm

        &&

        result.cutter_load_kn <=
        limits.max_cutter_load_kn

        &&

        result.penetration_mm_rev <=
        limits.max_penetration_mm_rev

    )
end


# ============================================================
# OBJECTIVE FUNCTION
# ============================================================

function objective(
    advance::Float64,
    specific_energy_value::Float64,
    wear::Float64,
    power::Float64,
    limits::TBMLimits
)

    if !isfinite(
        specific_energy_value
    )

        return -Inf
    end

    # Maximise advance while penalising:
    #
    #   - energy
    #   - cutter wear
    #   - excessive power
    #
    # This avoids simply commanding maximum thrust/RPM.

    speed_score =
        advance

    energy_penalty =
        0.25 *
        specific_energy_value

    wear_penalty =
        5.0 *
        wear

    power_penalty =
        0.10 *
        (
            power /
            limits.max_power_kw
        )

    return speed_score -
           energy_penalty -
           wear_penalty -
           power_penalty
end


# ============================================================
# CANDIDATE EVALUATION
# ============================================================

function evaluate_candidate(
    thrust::Float64,
    rpm::Float64,
    rock::RockCondition,
    limits::TBMLimits
)

    penetration =
        estimate_penetration(
            thrust,
            rpm,
            rock,
            limits
        )

    advance =
        advance_rate(
            rpm,
            penetration
        )

    torque =
        estimate_torque(
            thrust,
            penetration,
            limits,
            rock
        )

    power =
        estimate_power(
            torque,
            rpm
        )

    cutter =
        cutter_load(
            thrust,
            penetration,
            limits,
            rock
        )

    energy =
        specific_energy(
            power,
            advance,
            limits.diameter_m
        )

    wear =
        cutter_wear(
            thrust,
            penetration,
            rpm,
            rock,
            limits
        )

    temperature =
        motor_temperature(
            power,
            rpm,
            limits
        )

    # Reject excessive motor temperature.

    if temperature >
       limits.max_temperature_c

        return nothing
    end

    score =
        objective(
            advance,
            energy,
            wear,
            power,
            limits
        )

    result =
        OptimisationResult(

            rpm,
            thrust,

            penetration,
            advance,

            torque,
            power,

            cutter,

            energy,

            wear,

            score,

            false
        )

    result =
        OptimisationResult(

            result.rpm,
            result.thrust_kn,

            result.penetration_mm_rev,
            result.advance_m_h,

            result.torque_knm,
            result.power_kw,

            result.cutter_load_kn,

            result.specific_energy_kwh_m3,
            result.cutter_wear_index,

            result.objective_score,

            feasible(
                result,
                limits
            )
        )

    return result
end


# ============================================================
# GRID SEARCH OPTIMISER
# ============================================================

function optimise(
    rock::RockCondition,
    limits::TBMLimits;

    thrust_steps=30,
    rpm_steps=25
)

    best =
        nothing

    thrust_range =
        range(
            limits.max_thrust_kn *
            0.20,

            limits.max_thrust_kn,

            length=thrust_steps
        )

    rpm_range =
        range(
            limits.min_rpm,

            limits.max_rpm,

            length=rpm_steps
        )

    for thrust in
        thrust_range

        for rpm in
            rpm_range

            candidate =
                evaluate_candidate(
                    thrust,
                    rpm,
                    rock,
                    limits
                )

            candidate === nothing &&
                continue

            !candidate.feasible &&
                continue

            if best === nothing ||
               candidate.objective_score >
               best.objective_score

                best =
                    candidate
            end
        end
    end

    return best
end


# ============================================================
# ADAPTIVE OPTIMISER
# ============================================================

function optimise_realtime(
    state::TBMState,
    rock::RockCondition,
    limits::TBMLimits
)

    result =
        optimise(
            rock,
            limits
        )

    result === nothing &&
        return nothing

    # Smooth changes instead of instantaneous jumps.

    smoothing =
        0.20

    new_rpm =
        state.rpm +
        smoothing *
        (
            result.rpm -
            state.rpm
        )

    new_thrust =
        state.thrust_kn +
        smoothing *
        (
            result.thrust_kn -
            state.thrust_kn
        )

    return evaluate_candidate(
        new_thrust,
        new_rpm,
        rock,
        limits
    )
end


# ============================================================
# GEOLOGY CHANGE DETECTION
# ============================================================

function geology_change(
    old::RockCondition,
    new::RockCondition
)

    ucs_change =
        abs(
            new.ucs_mpa -
            old.ucs_mpa
        ) /
        max(
            old.ucs_mpa,
            1.0
        )

    rqd_change =
        abs(
            new.rqd_percent -
            old.rqd_percent
        ) /
        100.0

    mixed_change =
        abs(
            new.mixed_face_factor -
            old.mixed_face_factor
        )

    return max(
        ucs_change,
        rqd_change,
        mixed_change
    )
end


# ============================================================
# STATE UPDATE
# ============================================================

function apply_result!(
    state::TBMState,
    result::OptimisationResult
)

    state.rpm =
        result.rpm

    state.thrust_kn =
        result.thrust_kn

    state.penetration_mm_rev =
        result.penetration_mm_rev

    state.advance_m_h =
        result.advance_m_h

    state.torque_knm =
        result.torque_knm

    state.power_kw =
        result.power_kw

    state.cutter_load_kn =
        result.cutter_load_kn

    state.specific_energy_kwh_m3 =
        result.specific_energy_kwh_m3

    state.cutter_wear_index =
        result.cutter_wear_index

    state.utilisation =
        result.power_kw /
        1.0
end


# ============================================================
# REPORT
# ============================================================

function report(
    result::OptimisationResult
)

    println()
    println(
        "=========================================================="
    )

    println(
        "             TBM CUT-SPEED OPTIMISER"
    )

    println(
        "=========================================================="
    )

    @printf(
        "Cutterhead RPM:          %.2f rev/min\n",
        result.rpm
    )

    @printf(
        "Thrust:                  %.1f kN\n",
        result.thrust_kn
    )

    @printf(
        "Penetration:             %.2f mm/rev\n",
        result.penetration_mm_rev
    )

    @printf(
        "Advance rate:            %.2f m/h\n",
        result.advance_m_h
    )

    println()

    @printf(
        "Torque:                  %.1f kNm\n",
        result.torque_knm
    )

    @printf(
        "Power:                   %.1f kW\n",
        result.power_kw
    )

    @printf(
        "Cutter load:             %.1f kN\n",
        result.cutter_load_kn
    )

    @printf(
        "Specific energy:         %.2f kWh/m³\n",
        result.specific_energy_kwh_m3
    )

    @printf(
        "Cutter wear index:       %.3f\n",
        result.cutter_wear_index
    )

    @printf(
        "Objective score:         %.3f\n",
        result.objective_score
    )

    @printf(
        "Feasible:                %s\n",
        result.feasible
    )

    println(
        "=========================================================="
    )
end


# ============================================================
# EXAMPLE
# ============================================================

function demo()

    # Example hard-rock TBM.

    limits =
        TBMLimits(

            10.0,

            50000.0,

            8000.0,

            5000.0,

            8.0,
            1.0,

            20.0,

            300.0,

            100.0,

            60,

            483.0
        )

    # Example geological state.

    rock =
        RockCondition(

            120.0,     # UCS MPa

            75.0,      # RQD

            0.70,      # abrasivity

            0.20,      # fracture factor

            0.10,      # water factor

            0.05       # mixed face
        )

    result =
        optimise(
            rock,
            limits;
            thrust_steps=40,
            rpm_steps=30
        )

    if result === nothing

        println(
            "No feasible operating point found."
        )

        return nothing
    end

    report(
        result
    )

    return result
end


end # module


# ============================================================
# RUN
# ============================================================

using .TBMOptimiser

TBMOptimiser.demo()
