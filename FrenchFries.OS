# FRIESOS

## Intelligent Home French-Fry Appliance Controller

### Pure Julia — Standard Library Only

```julia
module FriesOS

using Dates
using Printf
using Statistics


# ============================================================
# FRIESOS
#
# Intelligent French-Fry Home Appliance
#
# Control philosophy:
#
#   INPUT
#     │
#     ├── potato/load estimate
#     ├── temperature
#     ├── cooking medium temperature
#     ├── basket position
#     └── appliance safety sensors
#     │
#     ▼
#   COOKING MODEL
#     │
#     ├── heat control
#     ├── moisture removal
#     ├── browning model
#     ├── crispness model
#     └── adaptive timing
#     │
#     ▼
#   FINISHED FRIES
#
# This is a simulation/control architecture.
#
# For a real appliance, certified hardware safety systems must
# independently handle thermal runaway, electrical isolation,
# over-temperature protection, lid/basket interlocks and fire
# protection.
# ============================================================


# ============================================================
# STATES
# ============================================================

@enum FriesState begin

    IDLE
    PREHEAT
    LOAD
    FIRST_COOK
    REST
    SECOND_COOK
    CRISPING
    DRAIN
    COMPLETE
    COOLING
    CLEANING
    FAULT
    EMERGENCY_STOP

end


# ============================================================
# COOKING PROFILE
# ============================================================

struct FriesProfile

    name::String

    first_temperature_c::Float64

    first_time_s::Float64

    second_temperature_c::Float64

    second_time_s::Float64

    target_browning::Float64

    target_crispness::Float64

end


function FriesProfile(;

    name="DOUBLE COOK",

    first_temperature_c=150.0,

    first_time_s=420.0,

    second_temperature_c=185.0,

    second_time_s=180.0,

    target_browning=0.72,

    target_crispness=0.90

)

    FriesProfile(

        name,

        first_temperature_c,

        first_time_s,

        second_temperature_c,

        second_time_s,

        target_browning,

        target_crispness

    )

end


# ============================================================
# THERMAL SYSTEM
# ============================================================

mutable struct ThermalSystem

    medium_temperature_c::Float64

    chamber_temperature_c::Float64

    target_temperature_c::Float64

    heater_power_percent::Float64

    heater_on::Bool

    ambient_temperature_c::Float64

    maximum_temperature_c::Float64

end


function ThermalSystem(;

    ambient_temperature_c=20.0,

    maximum_temperature_c=210.0

)

    ThermalSystem(

        ambient_temperature_c,

        ambient_temperature_c,

        ambient_temperature_c,

        0.0,

        false,

        ambient_temperature_c,

        maximum_temperature_c

    )

end


function set_target!(

    thermal::ThermalSystem,

    target::Real

)

    thermal.target_temperature_c =

        clamp(

            Float64(target),

            thermal.ambient_temperature_c,

            thermal.maximum_temperature_c

        )

end


function update!(

    thermal::ThermalSystem,

    dt::Float64,

    load_kg::Float64

)

    error =

        thermal.target_temperature_c -
        thermal.medium_temperature_c


    # PID-like proportional control.

    thermal.heater_power_percent =

        clamp(

            55.0 +
            error * 7.0,

            0.0,
            100.0

        )


    thermal.heater_on =

        thermal.heater_power_percent > 0.0


    # Heating model.

    heat_gain =

        thermal.heater_power_percent *
        0.010


    # Food load absorbs energy.

    load_absorption =

        load_kg *
        max(

            thermal.medium_temperature_c -
            20.0,

            0.0

        ) *
        0.00008


    # Ambient losses.

    environmental_loss =

        max(

            thermal.medium_temperature_c -
            thermal.ambient_temperature_c,

            0.0

        ) *
        0.0008


    thermal.medium_temperature_c +=

        (

            heat_gain -
            load_absorption -
            environmental_loss

        ) * dt


    thermal.chamber_temperature_c +=

        (

            thermal.medium_temperature_c -
            thermal.chamber_temperature_c

        ) *

        0.03 *
        dt


    thermal.medium_temperature_c =

        clamp(

            thermal.medium_temperature_c,

            thermal.ambient_temperature_c,

            thermal.maximum_temperature_c

        )

end


# ============================================================
# LOAD MODEL
# ============================================================

mutable struct FryLoad

    mass_kg::Float64

    thickness_mm::Float64

    moisture_fraction::Float64

    surface_area_cm2::Float64

    starch_level::Float64

    surface_moisture::Float64

end


function FryLoad(;

    mass_kg=0.50,

    thickness_mm=10.0

)

    FryLoad(

        mass_kg,

        thickness_mm,

        0.78,

        2500.0,

        0.65,

        1.0

    )

end


function estimate_load!(

    load::FryLoad

)

    load.surface_area_cm2 =

        4200.0 *
        load.mass_kg /
        max(
            load.thickness_mm / 10.0,
            0.5
        )


    load.starch_level =

        clamp(

            0.55 +
            0.02 *
            load.thickness_mm,

            0.0,
            1.0

        )

end


# ============================================================
# FRY QUALITY MODEL
# ============================================================

mutable struct QualityModel

    browning::Float64

    crispness::Float64

    internal_cook::Float64

    moisture_remaining::Float64

    quality_score::Float64

end


function QualityModel()

    QualityModel(

        0.0,

        0.0,

        0.0,

        1.0,

        0.0

    )

end


function update_quality!(

    quality::QualityModel,

    load::FryLoad,

    thermal::ThermalSystem,

    dt::Float64

)

    temperature =

        thermal.medium_temperature_c


    # --------------------------------------------------------
    # Moisture removal
    # --------------------------------------------------------

    moisture_rate =

        if temperature < 130.0

            0.00001

        elseif temperature < 160.0

            0.000025

        else

            0.000045

        end


    quality.moisture_remaining -=

        moisture_rate *
        dt *
        (temperature / 150.0)


    quality.moisture_remaining =

        clamp(

            quality.moisture_remaining,

            0.05,
            1.0

        )


    # --------------------------------------------------------
    # Internal cooking
    # --------------------------------------------------------

    internal_rate =

        max(

            temperature - 95.0,

            0.0

        ) *

        0.000004


    quality.internal_cook +=

        internal_rate *
        dt


    quality.internal_cook =

        clamp(

            quality.internal_cook,

            0.0,
            1.0

        )


    # --------------------------------------------------------
    # Browning / Maillard approximation
    # --------------------------------------------------------

    browning_rate =

        if temperature < 140.0

            0.000005

        elseif temperature < 170.0

            0.000025

        else

            0.000055

        end


    quality.browning +=

        browning_rate *
        dt *
        (
            0.5 +
            load.starch_level
        )


    quality.browning =

        clamp(

            quality.browning,

            0.0,
            1.0

        )


    # --------------------------------------------------------
    # Crispness
    # --------------------------------------------------------

    quality.crispness =

        clamp(

            (
                1.0 -
                quality.moisture_remaining
            ) *

            0.65 +

            quality.browning *
            0.35,

            0.0,
            1.0

        )


    # --------------------------------------------------------
    # Composite quality
    # --------------------------------------------------------

    quality.quality_score =

        100.0 *

        (

            0.25 *
            quality.internal_cook +

            0.35 *
            quality.crispness +

            0.40 *
            quality.browning

        )

end


# ============================================================
# AIRFLOW
# ============================================================

mutable struct AirflowSystem

    fan_on::Bool

    fan_speed_percent::Float64

    airflow_index::Float64

end


function AirflowSystem()

    AirflowSystem(

        false,

        0.0,

        0.0

    )

end


function set_speed!(

    airflow::AirflowSystem,

    speed::Real

)

    airflow.fan_speed_percent =

        clamp(

            Float64(speed),

            0.0,
            100.0

        )


    airflow.fan_on =

        airflow.fan_speed_percent > 0

end


function update!(

    airflow::AirflowSystem

)

    airflow.airflow_index =

        airflow.fan_speed_percent /
        100.0

end


# ============================================================
# BASKET
# ============================================================

mutable struct BasketSystem

    inserted::Bool

    locked::Bool

    shake_required::Bool

    shake_count::Int

end


function BasketSystem()

    BasketSystem(

        true,

        true,

        false,

        0

    )

end


function shake!(

    basket::BasketSystem

)

    basket.shake_count += 1

    basket.shake_required = false

end


# ============================================================
# SAFETY
# ============================================================

mutable struct SafetySystem

    door_closed::Bool

    basket_locked::Bool

    overtemperature::Bool

    emergency_stop::Bool

    thermal_limit_c::Float64

end


function SafetySystem()

    SafetySystem(

        true,

        true,

        false,

        false,

        205.0

    )

end


function safety_check!(

    safety::SafetySystem,

    thermal::ThermalSystem

)

    safety.overtemperature =

        thermal.medium_temperature_c >=
        safety.thermal_limit_c


    if !safety.door_closed ||
       !safety.basket_locked ||
       safety.overtemperature ||
       safety.emergency_stop

        return false

    end


    true

end


# ============================================================
# ENERGY
# ============================================================

mutable struct EnergySystem

    energy_kwh::Float64

end


EnergySystem() =
    EnergySystem(0.0)


function update_energy!(

    energy::EnergySystem,

    thermal::ThermalSystem,

    airflow::AirflowSystem,

    dt::Float64

)

    heater_kw =

        thermal.heater_on ?

        2.0 *
        thermal.heater_power_percent /
        100.0 :

        0.0


    fan_kw =

        airflow.fan_on ?

        0.08 *
        airflow.fan_speed_percent /
        100.0 :

        0.0


    energy.energy_kwh +=

        (

            heater_kw +
            fan_kw

        ) *

        dt /
        3600.0

end


# ============================================================
# TELEMETRY
# ============================================================

struct TelemetryPoint

    timestamp::DateTime

    state::FriesState

    medium_temperature_c::Float64

    chamber_temperature_c::Float64

    heater_power_percent::Float64

    fan_speed_percent::Float64

    load_kg::Float64

    moisture_remaining::Float64

    browning::Float64

    crispness::Float64

    quality_score::Float64

end


mutable struct Telemetry

    points::Vector{TelemetryPoint}

end


Telemetry() =
    Telemetry(
        TelemetryPoint[]
    )


# ============================================================
# FRIES MACHINE
# ============================================================

mutable struct FriesMachine

    name::String

    state::FriesState

    profile::FriesProfile

    thermal::ThermalSystem

    load::FryLoad

    quality::QualityModel

    airflow::AirflowSystem

    basket::BasketSystem

    safety::SafetySystem

    energy::EnergySystem

    telemetry::Telemetry

    elapsed::Float64

    state_elapsed::Float64

    cycle_id::String

end


# ============================================================
# CONSTRUCTOR
# ============================================================

function FriesMachine(

    name::String="FRIESOS-001",

    profile::FriesProfile=FriesProfile()

)

    FriesMachine(

        name,

        IDLE,

        profile,

        ThermalSystem(),

        FryLoad(),

        QualityModel(),

        AirflowSystem(),

        BasketSystem(),

        SafetySystem(),

        EnergySystem(),

        Telemetry(),

        0.0,

        0.0,

        ""

    )

end


# ============================================================
# LOAD
# ============================================================

function load_fries!(

    machine::FriesMachine,

    mass_kg::Real

)

    machine.state == IDLE ||
        error(
            "Machine must be idle."
        )


    machine.load.mass_kg =

        clamp(

            Float64(mass_kg),

            0.05,
            1.50

        )


    estimate_load!(
        machine.load
    )


    machine.cycle_id =

        "FRIES-" *
        Dates.format(
            now(),
            "yyyymmdd-HHMMSS"
        )


    machine.state =
        PREHEAT


    machine.elapsed =
        0.0


    machine.state_elapsed =
        0.0


    machine.quality =
        QualityModel()


    machine.energy =
        EnergySystem()


    machine.basket.inserted =
        true


    machine.basket.locked =
        true

end


# ============================================================
# PREHEAT
# ============================================================

function preheat_step!(

    machine::FriesMachine,

    dt::Float64

)

    set_target!(

        machine.thermal,

        machine.profile.first_temperature_c

    )


    set_speed!(
        machine.airflow,
        55.0
    )


    update!(
        machine.thermal,
        dt,
        0.0
    )


    if machine.thermal.medium_temperature_c >=

       machine.profile.first_temperature_c - 1.0

        machine.state =
            FIRST_COOK

        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# FIRST COOK
# ============================================================

function first_cook_step!(

    machine::FriesMachine,

    dt::Float64

)

    set_target!(

        machine.thermal,

        machine.profile.first_temperature_c

    )


    set_speed!(
        machine.airflow,
        70.0
    )


    update!(
        machine.thermal,
        dt,
        machine.load.mass_kg
    )


    update!(
        machine.airflow
    )


    update_quality!(

        machine.quality,

        machine.load,

        machine.thermal,

        dt

    )


    # Adaptive shake point.

    if machine.state_elapsed > 150.0 &&
       machine.basket.shake_count == 0

        machine.basket.shake_required =
            true

    end


    machine.state_elapsed +=
        dt


    if machine.state_elapsed >=
       machine.profile.first_time_s

        machine.state =
            REST

        machine.state_elapsed =
            0.0

        machine.basket.shake_required =
            true

    end

end


# ============================================================
# REST
# ============================================================

function rest_step!(

    machine::FriesMachine,

    dt::Float64

)

    # Rest allows internal moisture redistribution.

    machine.quality.moisture_remaining +=

        0.000015 *
        dt


    machine.quality.moisture_remaining =

        clamp(

            machine.quality.moisture_remaining,

            0.05,
            1.0

        )


    machine.state_elapsed +=
        dt


    if machine.state_elapsed >= 90.0

        machine.state =
            SECOND_COOK

        machine.state_elapsed =
            0.0

        machine.basket.shake_required =
            false

    end

end


# ============================================================
# SECOND COOK
# ============================================================

function second_cook_step!(

    machine::FriesMachine,

    dt::Float64

)

    set_target!(

        machine.thermal,

        machine.profile.second_temperature_c

    )


    set_speed!(
        machine.airflow,
        85.0
    )


    update!(
        machine.thermal,
        dt,
        machine.load.mass_kg
    )


    update!(
        machine.airflow
    )


    update_quality!(

        machine.quality,

        machine.load,

        machine.thermal,

        dt

    )


    machine.state_elapsed +=
        dt


    # Intelligent early termination.

    quality_target_reached =

        machine.quality.browning >=
        machine.profile.target_browning &&

        machine.quality.crispness >=
        machine.profile.target_crispness


    maximum_time_reached =

        machine.state_elapsed >=
        machine.profile.second_time_s


    if quality_target_reached ||
       maximum_time_reached

        machine.state =
            CRISPING

        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# CRISPING
# ============================================================

function crisping_step!(

    machine::FriesMachine,

    dt::Float64

)

    # Short high-airflow finishing stage.

    set_target!(

        machine.thermal,

        machine.profile.second_temperature_c

    )


    set_speed!(
        machine.airflow,
        100.0
    )


    update!(
        machine.thermal,
        dt,
        machine.load.mass_kg
    )


    update!(
        machine.airflow
    )


    update_quality!(

        machine.quality,

        machine.load,

        machine.thermal,

        dt

    )


    machine.state_elapsed +=
        dt


    if machine.quality.crispness >=
       machine.profile.target_crispness ||

       machine.state_elapsed >= 45.0

        machine.state =
            DRAIN

        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# DRAIN / FINISH
# ============================================================

function drain_step!(

    machine::FriesMachine,

    dt::Float64

)

    set_speed!(
        machine.airflow,
        30.0
    )


    machine.state_elapsed +=
        dt


    if machine.state_elapsed >= 15.0

        machine.state =
            COMPLETE

        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# COOLING
# ============================================================

function cooling_step!(

    machine::FriesMachine,

    dt::Float64

)

    set_speed!(
        machine.airflow,
        50.0
    )


    machine.thermal.target_temperature_c =
        machine.thermal.ambient_temperature_c


    update!(
        machine.thermal,
        dt,
        0.0
    )


    if machine.thermal.chamber_temperature_c <=
       machine.thermal.ambient_temperature_c + 10.0

        set_speed!(
            machine.airflow,
            0.0
        )


        machine.state =
            IDLE

    end

end


# ============================================================
# ENERGY
# ============================================================

function update_energy!(

    machine::FriesMachine,

    dt::Float64

)

    update_energy!(

        machine.energy,

        machine.thermal,

        machine.airflow,

        dt

    )

end


# ============================================================
# TELEMETRY
# ============================================================

function record_telemetry!(

    machine::FriesMachine

)

    push!(

        machine.telemetry.points,

        TelemetryPoint(

            now(),

            machine.state,

            machine.thermal.medium_temperature_c,

            machine.thermal.chamber_temperature_c,

            machine.thermal.heater_power_percent,

            machine.airflow.fan_speed_percent,

            machine.load.mass_kg,

            machine.quality.moisture_remaining,

            machine.quality.browning,

            machine.quality.crispness,

            machine.quality.quality_score

        )

    )

end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(

    machine::FriesMachine

)

    machine.thermal.heater_on =
        false

    machine.thermal.heater_power_percent =
        0.0


    set_speed!(
        machine.airflow,
        0.0
    )


    machine.safety.emergency_stop =
        true


    machine.state =
        EMERGENCY_STOP

end


# ============================================================
# MASTER CONTROL LOOP
# ============================================================

function control_step!(

    machine::FriesMachine,

    dt::Float64=1.0

)

    if machine.state in
        (
            IDLE,
            COMPLETE,
            FAULT,
            EMERGENCY_STOP
        )

        return

    end


    # Safety is evaluated before process control.

    if !safety_check!(

        machine.safety,

        machine.thermal

    )

        emergency_stop!(
            machine
        )

        return

    end


    if machine.state == PREHEAT

        preheat_step!(
            machine,
            dt
        )


    elseif machine.state == FIRST_COOK

        first_cook_step!(
            machine,
            dt
        )


    elseif machine.state == REST

        rest_step!(
            machine,
            dt
        )


    elseif machine.state == SECOND_COOK

        second_cook_step!(
            machine,
            dt
        )


    elseif machine.state == CRISPING

        crisping_step!(
            machine,
            dt
        )


    elseif machine.state == DRAIN

        drain_step!(
            machine,
            dt
        )


    elseif machine.state == COOLING

        cooling_step!(
            machine,
            dt
        )

    end


    update_energy!(
        machine,
        dt
    )


    record_telemetry!(
        machine
    )


    machine.elapsed +=
        dt

end


# ============================================================
# QUALITY REPORT
# ============================================================

function quality_report(

    machine::FriesMachine

)

    return (

        quality_score =
            machine.quality.quality_score,

        browning =
            machine.quality.browning,

        crispness =
            machine.quality.crispness,

        internal_cook =
            machine.quality.internal_cook,

        moisture_remaining =
            machine.quality.moisture_remaining,

        energy_kwh =
            machine.energy.energy_kwh,

        load_kg =
            machine.load.mass_kg,

        total_time_s =
            machine.elapsed,

        shake_count =
            machine.basket.shake_count

    )

end


# ============================================================
# DISPLAY
# ============================================================

function display_status!(

    machine::FriesMachine

)

    println(

        @sprintf(

            "%-14s | TEMP %6.1f°C | LOAD %.2f kg | BROWN %5.1f%% | CRISP %5.1f%% | QUALITY %5.1f",

            string(machine.state),

            machine.thermal.medium_temperature_c,

            machine.load.mass_kg,

            machine.quality.browning * 100,

            machine.quality.crispness * 100,

            machine.quality.quality_score

        )

    )

end


# ============================================================
# USER PRESETS
# ============================================================

const PRESETS = Dict(

    "THIN" => FriesProfile(

        name="THIN FRIES",

        first_temperature_c=145.0,

        first_time_s=330.0,

        second_temperature_c=180.0,

        second_time_s=150.0,

        target_browning=0.68,

        target_crispness=0.90

    ),

    "STANDARD" => FriesProfile(

        name="STANDARD FRIES",

        first_temperature_c=150.0,

        first_time_s=420.0,

        second_temperature_c=185.0,

        second_time_s=180.0,

        target_browning=0.72,

        target_crispness=0.90

    ),

    "THICK" => FriesProfile(

        name="THICK CUT",

        first_temperature_c=155.0,

        first_time_s=540.0,

        second_temperature_c=185.0,

        second_time_s=240.0,

        target_browning=0.70,

        target_crispness=0.88

    )

)


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println()
    println("="^110)
    println(
        "                         FRIESOS"
    )
    println(
        "             INTELLIGENT FRENCH-FRY APPLIANCE"
    )
    println("="^110)


    machine =

        FriesMachine(

            "FRIESOS-HOME-001",

            PRESETS["STANDARD"]

        )


    # 500 g batch.

    load_fries!(
        machine,
        0.50
    )


    println()
    println(
        "Cycle: ",
        machine.profile.name
    )


    println(
        "Load: ",
        machine.load.mass_kg,
        " kg"
    )


    println(
        "Cycle ID: ",
        machine.cycle_id
    )


    println()
    println(
        "STARTING COOKING PROCESS..."
    )


    # Simulated real-time appliance.

    for second in 1:10000

        control_step!(
            machine,
            1.0
        )


        if second % 60 == 0

            display_status!(
                machine
            )

        end


        if machine.state ==
           COMPLETE

            break

        end


        if machine.state ==
           EMERGENCY_STOP

            println(
                "EMERGENCY STOP"
            )

            break

        end

    end


    report =
        quality_report(
            machine
        )


    println()
    println("="^110)
    println(
        "                         FRIES COMPLETE"
    )
    println("="^110)


    println(

        @sprintf(

            "Final quality score: %.1f / 100",

            report.quality_score

        )

    )


    println(

        @sprintf(

            "Browning: %.1f%%",

            report.browning * 100

        )

    )


    println(

        @sprintf(

            "Crispness: %.1f%%",

            report.crispness * 100

        )

    )


    println(

        @sprintf(

            "Internal cook: %.1f%%",

            report.internal_cook * 100

        )

    )


    println(

        @sprintf(

            "Remaining moisture: %.1f%%",

            report.moisture_remaining * 100

        )

    )


    println(

        @sprintf(

            "Energy consumption: %.3f kWh",

            report.energy_kwh

        )

    )


    println(

        @sprintf(

            "Cooking time: %.1f minutes",

            report.total_time_s / 60.0

        )

    )


    println(
        "Basket shakes: ",
        report.shake_count
    )


    println(
        "Telemetry samples: ",
        length(
            machine.telemetry.points
        )
    )


    println("="^110)

end


# ============================================================
# EXPORTS
# ============================================================

export FriesState

export IDLE
export PREHEAT
export LOAD
export FIRST_COOK
export REST
export SECOND_COOK
export CRISPING
export DRAIN
export COMPLETE
export COOLING
export CLEANING
export FAULT
export EMERGENCY_STOP

export FriesProfile
export FriesLoad
export QualityModel
export ThermalSystem
export AirflowSystem
export BasketSystem
export SafetySystem
export EnergySystem

export FriesMachine

export PRESETS

export load_fries!
export control_step!
export emergency_stop!
export quality_report
export display_status!
export demo


end # module


# ============================================================
# APPLICATION ENTRY POINT
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .FriesOS

    FriesOS.demo()

end
```


