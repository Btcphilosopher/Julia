# SOAP.OS

## Intelligent Soap-Making Appliance

### Pure Julia — Recipe, Thermal, Mixing & Process-Control Engine

```julia
module SoapOS

using Dates
using Printf
using Statistics


# ============================================================
# SOAP.OS
# ============================================================
#
# Intelligent automated soap-making appliance
#
# SYSTEMS
#
#   Recipe/formulation engine
#   Oil inventory
#   Temperature controller
#   Mixing controller
#   Saponification estimator
#   Trace detection
#   Additive dosing
#   Batch state machine
#   Thermal safety
#   Motor protection
#   Recipe validation
#   Batch telemetry
#   Cure management
#   Fault handling
#
# Designed as a digital-twin/control architecture.
#
# IMPORTANT:
# A real appliance handling NaOH/KOH requires independently
# validated hardware safety systems, chemical compatibility,
# containment, emergency shutoff and certified controls.
#
# ============================================================


# ============================================================
# ENUMERATIONS
# ============================================================

@enum SoapState begin

    IDLE
    RECIPE_CHECK
    PREHEAT
    OIL_MELT
    TEMPERATURE_BALANCE
    READY_TO_MIX
    MIXING
    TRACE_DETECTION
    ADDITIVES
    MOLD_FILL
    COOLING
    CURE
    COMPLETE
    PAUSED
    FAULT
    EMERGENCY_STOP

end


@enum OilType begin

    OLIVE
    COCONUT
    PALM
    SHEA_BUTTER
    COCOA_BUTTER
    CASTOR
    SUNFLOWER
    CANOLA
    AVOCADO
    RICE_BRAN
end


@enum MotorMode begin

    MOTOR_OFF
    SLOW_MIX
    NORMAL_MIX
    HIGH_MIX
end


# ============================================================
# OIL DATA
# ============================================================

struct OilSpecification

    oil_type::OilType

    name::String

    density_g_ml::Float64

    melting_point_c::Float64

    default_sap_naoh::Float64

    hardness_index::Float64

    cleansing_index::Float64

    conditioning_index::Float64

end


const OIL_DATABASE = Dict(

    OLIVE => OilSpecification(

        OLIVE,
        "Olive Oil",
        0.91,
        5.0,
        0.134,
        0.17,
        0.10,
        0.90

    ),

    COCONUT => OilSpecification(

        COCONUT,
        "Coconut Oil",
        0.92,
        24.0,
        0.183,
        0.79,
        0.95,
        0.20

    ),

    PALM => OilSpecification(

        PALM,
        "Palm Oil",
        0.89,
        35.0,
        0.142,
        0.65,
        0.65,
        0.35

    ),

    SHEA_BUTTER => OilSpecification(

        SHEA_BUTTER,
        "Shea Butter",
        0.91,
        32.0,
        0.128,
        0.55,
        0.30,
        0.65

    ),

    COCOA_BUTTER => OilSpecification(

        COCOA_BUTTER,
        "Cocoa Butter",
        0.90,
        34.0,
        0.137,
        0.70,
        0.30,
        0.55

    ),

    CASTOR => OilSpecification(

        CASTOR,
        "Castor Oil",
        0.96,
        -10.0,
        0.128,
        0.20,
        0.10,
        0.95

    ),

    SUNFLOWER => OilSpecification(

        SUNFLOWER,
        "Sunflower Oil",
        0.92,
        -18.0,
        0.135,
        0.15,
        0.10,
        0.90

    ),

    CANOLA => OilSpecification(

        CANOLA,
        "Canola Oil",
        0.92,
        -10.0,
        0.124,
        0.15,
        0.10,
        0.85

    ),

    AVOCADO => OilSpecification(

        AVOCADO,
        "Avocado Oil",
        0.91,
        -10.0,
        0.133,
        0.20,
        0.10,
        0.90

    ),

    RICE_BRAN => OilSpecification(

        RICE_BRAN,
        "Rice Bran Oil",
        0.92,
        -5.0,
        0.128,
        0.25,
        0.15,
        0.80

    )

)


# ============================================================
# RECIPE COMPONENT
# ============================================================

struct OilComponent

    oil_type::OilType

    mass_g::Float64

end


# ============================================================
# RECIPE
# ============================================================

mutable struct SoapRecipe

    name::String

    batch_mass_g::Float64

    oils::Vector{OilComponent}

    superfat_percent::Float64

    water_ratio::Float64

    target_temperature_c::Float64

    target_mix_rpm::Float64

    fragrance_percent::Float64

    colour_percent::Float64

end


function SoapRecipe(

    name::String;

    batch_mass_g=1000.0,

    oils=OilComponent[],

    superfat_percent=5.0,

    water_ratio=2.0,

    target_temperature_c=40.0,

    target_mix_rpm=120.0,

    fragrance_percent=0.0,

    colour_percent=0.0

)

    SoapRecipe(

        name,

        batch_mass_g,

        oils,

        superfat_percent,

        water_ratio,

        target_temperature_c,

        target_mix_rpm,

        fragrance_percent,

        colour_percent

    )

end


# ============================================================
# FORMULATION ENGINE
# ============================================================

struct Formulation

    total_oil_mass_g::Float64

    calculated_naoh_g::Float64

    recommended_naoh_g::Float64

    water_g::Float64

    superfat_percent::Float64

end


function calculate_formulation(

    recipe::SoapRecipe

)

    total_oil =

        sum(

            oil.mass_g

            for oil in recipe.oils

        )


    calculated_lye = 0.0


    for oil in recipe.oils

        spec =

            OIL_DATABASE[oil.oil_type]


        calculated_lye +=

            oil.mass_g *

            spec.default_sap_naoh

    end


    recommended_lye =

        calculated_lye *

        (

            1.0 -

            recipe.superfat_percent / 100.0

        )


    water =

        recommended_lye *

        recipe.water_ratio


    Formulation(

        total_oil,

        calculated_lye,

        recommended_lye,

        water,

        recipe.superfat_percent

    )

end


# ============================================================
# RECIPE VALIDATION
# ============================================================

struct ValidationResult

    valid::Bool

    warnings::Vector{String}

    errors::Vector{String}

end


function validate_recipe(

    recipe::SoapRecipe

)

    warnings = String[]
    errors = String[]


    if isempty(recipe.oils)

        push!(

            errors,

            "Recipe contains no oils."

        )

    end


    if recipe.batch_mass_g <= 0

        push!(

            errors,

            "Batch mass must be positive."

        )

    end


    if recipe.superfat_percent < 0 ||

       recipe.superfat_percent > 20

        push!(

            errors,

            "Superfat percentage outside configured range."

        )

    end


    if recipe.target_temperature_c < 25 ||

       recipe.target_temperature_c > 70

        push!(

            warnings,

            "Target temperature requires recipe verification."

        )

    end


    for component in recipe.oils

        if component.mass_g <= 0

            push!(

                errors,

                "Oil mass must be positive."

            )

        end

    end


    formulation =

        calculate_formulation(

            recipe

        )


    if formulation.recommended_naoh_g <= 0

        push!(

            errors,

            "Calculated caustic requirement invalid."

        )

    end


    ValidationResult(

        isempty(errors),

        warnings,

        errors

    )

end


# ============================================================
# THERMAL SYSTEM
# ============================================================

mutable struct ThermalSystem

    temperature_c::Float64

    target_temperature_c::Float64

    ambient_temperature_c::Float64

    heater_power_percent::Float64

    maximum_temperature_c::Float64

    heating_rate_c_s::Float64

    cooling_rate_c_s::Float64

end


function ThermalSystem()

    ThermalSystem(

        22.0,
        40.0,
        22.0,
        0.0,
        80.0,
        0.25,
        0.05

    )

end


function thermal_control!(

    thermal::ThermalSystem,

    dt::Float64

)

    error =

        thermal.target_temperature_c -

        thermal.temperature_c


    thermal.heater_power_percent =

        clamp(

            error * 8.0,

            0.0,
            100.0

        )


    heating =

        thermal.heater_power_percent /
        100.0 *

        thermal.heating_rate_c_s


    cooling =

        max(

            thermal.temperature_c -
            thermal.ambient_temperature_c,

            0.0

        ) *

        thermal.cooling_rate_c_s


    thermal.temperature_c +=

        (

            heating -
            cooling

        ) * dt


    thermal.temperature_c =

        max(

            thermal.temperature_c,

            thermal.ambient_temperature_c

        )

end


# ============================================================
# MIXER
# ============================================================

mutable struct Mixer

    mode::MotorMode

    target_rpm::Float64

    actual_rpm::Float64

    current_a::Float64

    load::Float64

    torque_nm::Float64

    total_runtime_s::Float64

end


function Mixer()

    Mixer(

        MOTOR_OFF,

        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0

    )

end


function set_mixer_mode!(

    mixer::Mixer,

    mode::MotorMode

)

    mixer.mode = mode


    mixer.target_rpm =

        if mode == MOTOR_OFF
            0.0
        elseif mode == SLOW_MIX
            60.0
        elseif mode == NORMAL_MIX
            120.0
        else
            220.0
        end

end


function update_mixer!(

    mixer::Mixer,

    dt::Float64,

    viscosity::Float64

)

    mixer.actual_rpm +=

        (

            mixer.target_rpm -
            mixer.actual_rpm

        ) *

        min(

            dt * 4.0,

            1.0

        )


    mixer.load =

        clamp(

            viscosity *
            0.75,

            0.0,
            1.0

        )


    mixer.torque_nm =

        0.05 *

        mixer.actual_rpm *

        mixer.load


    mixer.current_a =

        0.4 +

        mixer.load * 6.0


    if mixer.actual_rpm > 1

        mixer.total_runtime_s += dt

    end

end


# ============================================================
# SAPONIFICATION ESTIMATOR
# ============================================================

mutable struct SaponificationModel

    reaction_progress::Float64

    reaction_rate::Float64

    estimated_conversion_percent::Float64

    estimated_viscosity::Float64

end


function SaponificationModel()

    SaponificationModel(

        0.0,
        0.0,
        0.0,
        0.15

    )

end


function update_saponification!(

    model::SaponificationModel,

    thermal::ThermalSystem,

    mixer::Mixer,

    dt::Float64

)

    temperature_factor =

        clamp(

            (

                thermal.temperature_c -
                20.0

            ) / 50.0,

            0.0,
            1.0

        )


    mixing_factor =

        clamp(

            mixer.actual_rpm / 150.0,

            0.0,
            1.0

        )


    model.reaction_rate =

        0.00035 *

        temperature_factor *

        (

            0.3 +
            0.7 * mixing_factor

        )


    model.reaction_progress +=

        model.reaction_rate *

        dt


    model.reaction_progress =

        clamp(

            model.reaction_progress,

            0.0,
            1.0

        )


    model.estimated_conversion_percent =

        model.reaction_progress * 100.0


    # Simplified process-state viscosity model.

    model.estimated_viscosity =

        0.15 +

        model.reaction_progress^2 *

        0.85

end


# ============================================================
# TRACE DETECTOR
# ============================================================

mutable struct TraceDetector

    trace_score::Float64

    trace_detected::Bool

    previous_viscosity::Float64

    viscosity_rate::Float64

end


TraceDetector() =

    TraceDetector(

        0.0,
        false,
        0.15,
        0.0

    )


function update_trace!(

    detector::TraceDetector,

    viscosity::Float64,

    dt::Float64

)

    detector.viscosity_rate =

        (

            viscosity -
            detector.previous_viscosity

        ) /

        max(

            dt,

            0.001

        )


    detector.trace_score =

        clamp(

            (

                viscosity - 0.45

            ) / 0.45,

            0.0,
            1.0

        )


    detector.trace_detected =

        detector.trace_score >= 0.85


    detector.previous_viscosity =

        viscosity

end


# ============================================================
# ADDITIVE SYSTEM
# ============================================================

mutable struct AdditiveSystem

    fragrance_percent::Float64

    colour_percent::Float64

    fragrance_mass_g::Float64

    colour_mass_g::Float64

    dispensed::Bool

end


AdditiveSystem() =

    AdditiveSystem(

        0.0,
        0.0,
        0.0,
        0.0,
        false

    )


function calculate_additives!(

    additives::AdditiveSystem,

    recipe::SoapRecipe

)

    additives.fragrance_percent =

        recipe.fragrance_percent


    additives.colour_percent =

        recipe.colour_percent


    additives.fragrance_mass_g =

        recipe.batch_mass_g *

        recipe.fragrance_percent /
        100.0


    additives.colour_mass_g =

        recipe.batch_mass_g *

        recipe.colour_percent /
        100.0

end


# ============================================================
# SAFETY SYSTEM
# ============================================================

mutable struct SafetySystem

    emergency_stop::Bool

    lid_closed::Bool

    vessel_present::Bool

    temperature_safe::Bool

    motor_safe::Bool

    caustic_system_locked::Bool

    fault_message::String

end


function SafetySystem()

    SafetySystem(

        false,

        true,

        true,

        true,

        true,

        true,

        ""

    )

end


function safety_check!(

    safety::SafetySystem,

    thermal::ThermalSystem,

    mixer::Mixer

)

    safety.temperature_safe =

        thermal.temperature_c <=

        thermal.maximum_temperature_c


    safety.motor_safe =

        mixer.current_a < 12.0


    if !safety.lid_closed

        safety.fault_message =

            "LID OPEN"

        return false

    end


    if !safety.vessel_present

        safety.fault_message =

            "VESSEL NOT PRESENT"

        return false

    end


    if !safety.temperature_safe

        safety.fault_message =

            "OVER-TEMPERATURE"

        return false

    end


    if !safety.motor_safe

        safety.fault_message =

            "MOTOR OVERCURRENT"

        return false

    end


    if safety.emergency_stop

        safety.fault_message =

            "EMERGENCY STOP"

        return false

    end


    safety.fault_message = ""


    return true

end


# ============================================================
# BATCH TELEMETRY
# ============================================================

struct TelemetryPoint

    timestamp::DateTime

    state::SoapState

    temperature_c::Float64

    heater_power::Float64

    mixer_rpm::Float64

    mixer_load::Float64

    viscosity::Float64

    conversion_percent::Float64

    trace_score::Float64

end


mutable struct Telemetry

    points::Vector{TelemetryPoint}

end


Telemetry() =

    Telemetry(

        TelemetryPoint[]

    )


# ============================================================
# SOAP MACHINE
# ============================================================

mutable struct SoapMaker

    name::String

    state::SoapState

    recipe::SoapRecipe

    formulation::Formulation

    thermal::ThermalSystem

    mixer::Mixer

    saponification::SaponificationModel

    trace::TraceDetector

    additives::AdditiveSystem

    safety::SafetySystem

    telemetry::Telemetry

    elapsed_s::Float64

end


function SoapMaker(

    recipe::SoapRecipe;

    name="SOAPOS-001"

)

    formulation =

        calculate_formulation(

            recipe

        )


    machine = SoapMaker(

        name,

        IDLE,

        recipe,

        formulation,

        ThermalSystem(),

        Mixer(),

        SaponificationModel(),

        TraceDetector(),

        AdditiveSystem(),

        SafetySystem(),

        Telemetry(),

        0.0

    )


    calculate_additives!(

        machine.additives,

        recipe

    )


    return machine

end


# ============================================================
# START BATCH
# ============================================================

function start_batch!(

    machine::SoapMaker

)

    validation =

        validate_recipe(

            machine.recipe

        )


    if !validation.valid

        machine.state = FAULT

        return validation

    end


    machine.state =

        RECIPE_CHECK


    return validation

end


# ============================================================
# PROCESS STATE MACHINE
# ============================================================

function advance_state!(

    machine::SoapMaker

)

    if machine.state == RECIPE_CHECK

        machine.state =

            PREHEAT


    elseif machine.state == PREHEAT

        if machine.thermal.temperature_c >=

           machine.recipe.target_temperature_c

            machine.state =

                OIL_MELT

        end


    elseif machine.state == OIL_MELT

        if machine.thermal.temperature_c >=

           machine.recipe.target_temperature_c

            machine.state =

                TEMPERATURE_BALANCE

        end


    elseif machine.state == TEMPERATURE_BALANCE

        machine.state =

            READY_TO_MIX


    elseif machine.state == READY_TO_MIX

        machine.state =

            MIXING


        set_mixer_mode!(

            machine.mixer,

            NORMAL_MIX

        )


    elseif machine.state == MIXING

        if machine.trace.trace_detected

            machine.state =

                TRACE_DETECTION

        end


    elseif machine.state == TRACE_DETECTION

        machine.state =

            ADDITIVES


    elseif machine.state == ADDITIVES

        machine.additives.dispensed = true

        machine.state =

            MOLD_FILL


    elseif machine.state == MOLD_FILL

        set_mixer_mode!(

            machine.mixer,

            MOTOR_OFF

        )


        machine.state =

            COOLING


    elseif machine.state == COOLING

        if machine.thermal.temperature_c <= 30.0

            machine.state =

                CURE

        end


    elseif machine.state == CURE

        machine.state =

            COMPLETE

    end

end


# ============================================================
# PROCESS STEP
# ============================================================

function process_step!(

    machine::SoapMaker,

    dt::Float64=0.1

)

    machine.elapsed_s += dt


    # --------------------------------------------------------
    # SAFETY
    # --------------------------------------------------------

    if !safety_check!(

        machine.safety,

        machine.thermal,

        machine.mixer

    )

        machine.state =

            FAULT

        set_mixer_mode!(

            machine.mixer,

            MOTOR_OFF

        )

        machine.thermal.heater_power_percent = 0.0

        return

    end


    # --------------------------------------------------------
    # TEMPERATURE TARGET
    # --------------------------------------------------------

    if machine.state in

       (

           PREHEAT,
           OIL_MELT,
           TEMPERATURE_BALANCE,
           MIXING

       )

        machine.thermal.target_temperature_c =

            machine.recipe.target_temperature_c

    else

        machine.thermal.target_temperature_c =

            machine.thermal.ambient_temperature_c

    end


    # --------------------------------------------------------
    # THERMAL CONTROL
    # --------------------------------------------------------

    thermal_control!(

        machine.thermal,

        dt

    )


    # --------------------------------------------------------
    # MIXING
    # --------------------------------------------------------

    update_mixer!(

        machine.mixer,

        dt,

        machine.saponification.
        estimated_viscosity

    )


    # --------------------------------------------------------
    # SAPONIFICATION
    # --------------------------------------------------------

    if machine.state in

       (

           MIXING,
           TRACE_DETECTION

       )

        update_saponification!(

            machine.saponification,

            machine.thermal,

            machine.mixer,

            dt

        )

    end


    # --------------------------------------------------------
    # TRACE
    # --------------------------------------------------------

    update_trace!(

        machine.trace,

        machine.saponification.
        estimated_viscosity,

        dt

    )


    # --------------------------------------------------------
    # STATE TRANSITION
    # --------------------------------------------------------

    if machine.state != IDLE &&

       machine.state != COMPLETE &&

       machine.state != FAULT

        advance_state!(

            machine

        )

    end


    # --------------------------------------------------------
    # TELEMETRY
    # --------------------------------------------------------

    push!(

        machine.telemetry.points,

        TelemetryPoint(

            now(),

            machine.state,

            machine.thermal.temperature_c,

            machine.thermal.heater_power_percent,

            machine.mixer.actual_rpm,

            machine.mixer.load,

            machine.saponification.
            estimated_viscosity,

            machine.saponification.
            estimated_conversion_percent,

            machine.trace.trace_score

        )

    )

end


# ============================================================
# DASHBOARD
# ============================================================

function dashboard(

    machine::SoapMaker

)

    println()

    println("="^88)

    println(

        "                         SOAP.OS"

    )

    println(

        "              INTELLIGENT SOAP APPLIANCE"

    )

    println("="^88)

    println()


    println(

        "MACHINE       : ",

        machine.name

    )


    println(

        "RECIPE        : ",

        machine.recipe.name

    )


    println(

        "STATE         : ",

        machine.state

    )


    println()


    println(

        @sprintf(

            "TEMPERATURE   : %8.2f °C",

            machine.thermal.temperature_c

        )

    )


    println(

        @sprintf(

            "TARGET        : %8.2f °C",

            machine.thermal.target_temperature_c

        )

    )


    println(

        @sprintf(

            "HEATER        : %8.1f %%",

            machine.thermal.heater_power_percent

        )

    )


    println()


    println(

        @sprintf(

            "MIXER         : %8.1f RPM",

            machine.mixer.actual_rpm

        )

    )


    println(

        @sprintf(

            "MOTOR LOAD    : %8.1f %%",

            machine.mixer.load * 100.0

        )

    )


    println(

        @sprintf(

            "VISCOSITY     : %8.3f",

            machine.saponification.
            estimated_viscosity

        )

    )


    println(

        @sprintf(

            "SAP. PROGRESS : %8.1f %%",

            machine.saponification.
            estimated_conversion_percent

        )

    )


    println(

        @sprintf(

            "TRACE SCORE   : %8.1f %%",

            machine.trace.trace_score * 100.0

        )

    )


    println()


    println(

        "SAFETY        : ",

        machine.safety.fault_message == "" ?

        "OK" :

        machine.safety.fault_message

    )


    println()


    println("="^88)

end


# ============================================================
# FORMULATION REPORT
# ============================================================

function formulation_report(

    machine::SoapMaker

)

    f = machine.formulation


    println()

    println("="^88)

    println(

        "                     FORMULATION"

    )

    println("="^88)

    println()


    println(

        @sprintf(

            "TOTAL OILS        : %.2f g",

            f.total_oil_mass_g

        )

    )


    println(

        @sprintf(

            "CALCULATED NaOH   : %.2f g",

            f.calculated_naoh_g

        )

    )


    println(

        @sprintf(

            "DISCOUNTED NaOH   : %.2f g",

            f.recommended_naoh_g

        )

    )


    println(

        @sprintf(

            "WATER             : %.2f g",

            f.water_g

        )

    )


    println(

        @sprintf(

            "SUPERFAT          : %.2f %%",

            f.superfat_percent

        )

    )


    println()


    println(

        "OIL COMPOSITION"

    )


    println("-"^88)


    for oil in machine.recipe.oils

        spec =

            OIL_DATABASE[oil.oil_type]


        percentage =

            100.0 *

            oil.mass_g /
            f.total_oil_mass_g


        println(

            @sprintf(

                "%-18s %8.2f g   %6.2f %%",

                spec.name,

                oil.mass_g,

                percentage

            )

        )

    end


    println()

    println("="^88)

end


# ============================================================
# BATCH REPORT
# ============================================================

function batch_report(

    machine::SoapMaker

)

    points =

        machine.telemetry.points


    if isempty(points)

        return nothing

    end


    temperatures =

        [

            p.temperature_c

            for p in points

        ]


    mixer_loads =

        [

            p.mixer_load

            for p in points

        ]


    return (

        runtime_minutes =

            machine.elapsed_s / 60.0,

        mean_temperature =

            mean(temperatures),

        maximum_temperature =

            maximum(temperatures),

        maximum_motor_load =

            maximum(mixer_loads),

        final_conversion =

            machine.saponification.
            estimated_conversion_percent,

        trace_detected =

            machine.trace.trace_detected,

        final_state =

            machine.state

    )

end


# ============================================================
# DEMONSTRATION RECIPE
# ============================================================

function demonstration_recipe()

    SoapRecipe(

        "CLASSIC CONDITIONING BAR",

        batch_mass_g=1000.0,

        oils=[

            OilComponent(

                OLIVE,

                600.0

            ),

            OilComponent(

                COCONUT,

                250.0

            ),

            CASTOR,

            150.0

        ],

        superfat_percent=5.0,

        water_ratio=2.0,

        target_temperature_c=40.0,

        target_mix_rpm=120.0,

        fragrance_percent=1.0,

        colour_percent=0.1

    )

end


# ============================================================
# DIGITAL-TWIN DEMONSTRATION
# ============================================================

function simulate()

    recipe =

        demonstration_recipe()


    machine =

        SoapMaker(

            recipe,

            name="SOAPOS-LAB-001"

        )


    println()

    println(

        "BOOTING SOAP.OS..."

    )


    validation =

        start_batch!(

            machine

        )


    if !validation.valid

        println(

            "RECIPE INVALID"

        )

        for error in validation.errors

            println(

                "ERROR: ",

                error

            )

        end

        return

    end


    formulation_report(

        machine

    )


    # Simulate approximately 30 minutes.

    for tick in 1:18000

        process_step!(

            machine,

            0.1

        )


        if tick % 3000 == 0

            dashboard(

                machine

            )

        end


        if machine.state == COMPLETE ||

           machine.state == FAULT

            break

        end

    end


    dashboard(

        machine

    )


    result =

        batch_report(

            machine

        )


    println()

    println("="^88)

    println(

        "                       BATCH REPORT"

    )

    println("="^88)

    println()


    println(

        @sprintf(

            "Runtime             : %.2f min",

            result.runtime_minutes

        )

    )


    println(

        @sprintf(

            "Mean temperature    : %.2f °C",

            result.mean_temperature

        )

    )


    println(

        @sprintf(

            "Maximum temperature : %.2f °C",

            result.maximum_temperature

        )

    )


    println(

        @sprintf(

            "Maximum motor load  : %.2f %%",

            result.maximum_motor_load * 100

        )

    )


    println(

        @sprintf(

            "Conversion estimate : %.2f %%",

            result.final_conversion

        )

    )


    println(

        "Trace detected       : ",

        result.trace_detected

    )


    println(

        "Final state          : ",

        result.final_state

    )


    println()

    println("="^88)

end


# ============================================================
# EXPORTS
# ============================================================

export SoapMaker
export SoapRecipe
export OilComponent
export OilType

export start_batch!
export process_step!
export dashboard
export formulation_report
export batch_report
export demonstration_recipe
export simulate

end


# ============================================================
# APPLICATION ENTRY POINT
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .SoapOS

    SoapOS.simulate()

end
```


