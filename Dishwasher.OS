# DISHWASHEROS

## Intelligent Home Dishwasher Appliance Control System

### Pure Julia / Standard Library

```julia
module DishwasherOS

using Dates
using Printf
using Statistics


# ============================================================
#
#                     DISHWASHEROS
#
#       INTELLIGENT HOME DISHWASHER CONTROL SYSTEM
#
# ============================================================
#
# Architecture
#
#       USER / LOAD
#           │
#           ▼
#       CYCLE ENGINE
#           │
#     ┌─────┼──────────────────────────┐
#     │     │          │               │
#   WATER  HEAT      PUMP          DOSING
#     │     │          │               │
#     └─────┼──────────┼───────────────┘
#           │
#           ▼
#       WASH PROCESS
#           │
#       ┌───┴────────────┐
#       │                │
#   TURBIDITY         PRESSURE
#    SENSOR            SENSOR
#       │                │
#       └───────┬────────┘
#               │
#               ▼
#        CLEANLINESS ESTIMATOR
#               │
#               ▼
#          RINSE / DRY
#               │
#               ▼
#          QUALITY SCORE
#
# Hardware abstraction:
#
#   - Water inlet valve
#   - Drain pump
#   - Circulation pump
#   - Heater
#   - Temperature sensor
#   - Turbidity sensor
#   - Pressure sensor
#   - Water-level sensor
#   - Leak sensor
#   - Door sensor
#   - Detergent dispenser
#   - Rinse-aid dispenser
#   - Drying fan
#
# This implementation is a control-system simulation.
#
# Real appliances require independently certified electrical,
# thermal, pressure, leak, door-interlock and food-contact/
# detergent-compatible hardware.
#
# ============================================================


# ============================================================
# STATES
# ============================================================

@enum DishwasherState begin

    IDLE

    LOADING

    FILL

    PREWASH

    MAIN_WASH

    HEATING

    INTENSIVE_WASH

    DRAIN

    INTERMEDIATE_RINSE

    FINAL_RINSE

    SANITIZATION

    DRYING

    COOLING

    COMPLETE

    CLEANING

    FAULT

    EMERGENCY_STOP

end


# ============================================================
# WATER SYSTEM
# ============================================================

mutable struct WaterSystem

    volume_l::Float64

    target_volume_l::Float64

    inlet_open::Bool

    inlet_flow_l_min::Float64

    drain_open::Bool

    drain_flow_l_min::Float64

    maximum_volume_l::Float64

end


function WaterSystem(;

    maximum_volume_l=15.0

)

    WaterSystem(

        0.0,

        0.0,

        false,

        0.0,

        false,

        0.0,

        Float64(maximum_volume_l)

    )

end


function open_inlet!(

    water::WaterSystem,

    flow::Real

)

    water.inlet_open =
        true

    water.inlet_flow_l_min =
        max(
            0.0,
            Float64(flow)
        )

end


function close_inlet!(
    water::WaterSystem
)

    water.inlet_open =
        false

    water.inlet_flow_l_min =
        0.0

end


function open_drain!(

    water::WaterSystem,

    flow::Real

)

    water.drain_open =
        true

    water.drain_flow_l_min =
        max(
            0.0,
            Float64(flow)
        )

end


function close_drain!(
    water::WaterSystem
)

    water.drain_open =
        false

    water.drain_flow_l_min =
        0.0

end


function update!(

    water::WaterSystem,

    dt::Float64

)

    if water.inlet_open

        water.volume_l +=

            water.inlet_flow_l_min /
            60.0 *
            dt

    end


    if water.drain_open

        water.volume_l -=

            water.drain_flow_l_min /
            60.0 *
            dt

    end


    water.volume_l =
        clamp(

            water.volume_l,

            0.0,

            water.maximum_volume_l

        )

end


# ============================================================
# TEMPERATURE SYSTEM
# ============================================================

mutable struct ThermalSystem

    temperature_c::Float64

    target_c::Float64

    heater_on::Bool

    heater_power_percent::Float64

    ambient_c::Float64

    maximum_c::Float64

end


function ThermalSystem(;

    ambient_c=20.0,

    maximum_c=90.0

)

    ThermalSystem(

        Float64(ambient_c),

        Float64(ambient_c),

        false,

        0.0,

        Float64(ambient_c),

        Float64(maximum_c)

    )

end


function set_target!(

    thermal::ThermalSystem,

    target::Real

)

    thermal.target_c =
        clamp(

            Float64(target),

            thermal.ambient_c,

            thermal.maximum_c

        )

end


function update!(

    thermal::ThermalSystem,

    dt::Float64,

    water_volume_l::Float64

)

    error =
        thermal.target_c -
        thermal.temperature_c


    if error > 0

        thermal.heater_on =
            true

        thermal.heater_power_percent =
            clamp(

                45.0 +
                error * 8.0,

                0.0,
                100.0

            )

    else

        thermal.heater_on =
            false

        thermal.heater_power_percent =
            0.0

    end


    heat_input =

        thermal.heater_on ?

        thermal.heater_power_percent *
        0.018 /
        max(
            water_volume_l,
            1.0
        ) :

        0.0


    ambient_loss =

        (
            thermal.temperature_c -
            thermal.ambient_c
        ) *
        0.002


    thermal.temperature_c +=

        (
            heat_input -
            ambient_loss
        ) *
        dt


    thermal.temperature_c =
        clamp(

            thermal.temperature_c,

            thermal.ambient_c,

            thermal.maximum_c

        )

end


# ============================================================
# CIRCULATION PUMP
# ============================================================

mutable struct CirculationPump

    enabled::Bool

    speed_percent::Float64

    pressure_bar::Float64

    target_pressure_bar::Float64

    maximum_pressure_bar::Float64

end


function CirculationPump(;

    maximum_pressure_bar=3.0

)

    CirculationPump(

        false,

        0.0,

        0.0,

        0.0,

        Float64(maximum_pressure_bar)

    )

end


function set_speed!(

    pump::CirculationPump,

    speed::Real

)

    pump.speed_percent =
        clamp(

            Float64(speed),

            0.0,
            100.0

        )

    pump.enabled =
        pump.speed_percent > 0

end


function stop!(
    pump::CirculationPump
)

    pump.enabled =
        false

    pump.speed_percent =
        0.0

    pump.pressure_bar =
        0.0

    pump.target_pressure_bar =
        0.0

end


function update!(

    pump::CirculationPump,

    dt::Float64

)

    if !pump.enabled

        pump.pressure_bar *=
            max(
                0.0,
                1.0 - 5.0 * dt
            )

        return

    end


    pump.target_pressure_bar =

        pump.speed_percent /
        100.0 *
        pump.maximum_pressure_bar


    pump.pressure_bar +=

        (
            pump.target_pressure_bar -
            pump.pressure_bar
        ) *
        0.20

end


# ============================================================
# TURBIDITY SENSOR
# ============================================================

mutable struct TurbiditySensor

    ntu::Float64

    baseline_ntu::Float64

    minimum_ntu::Float64

    maximum_ntu::Float64

    healthy::Bool

end


function TurbiditySensor()

    TurbiditySensor(

        120.0,

        1.0,

        0.0,

        1000.0,

        true

    )

end


# ============================================================
# LOAD SENSOR
# ============================================================

mutable struct LoadSensor

    estimated_mass_kg::Float64

    plate_count::Int

    cup_count::Int

    cutlery_count::Int

    soil_level::Float64

end


function LoadSensor()

    LoadSensor(

        5.0,

        8,

        6,

        12,

        0.65

    )

end


function estimate_soil!(
    load::LoadSensor
)

    load.soil_level =

        clamp(

            0.25 +
            0.02 *
            load.plate_count +
            0.015 *
            load.cup_count +
            0.005 *
            load.cutlery_count,

            0.0,
            1.0

        )

end


# ============================================================
# DOSING
# ============================================================

mutable struct DosingSystem

    detergent_available_ml::Float64

    rinse_aid_available_ml::Float64

    detergent_dosed_ml::Float64

    rinse_aid_dosed_ml::Float64

end


function DosingSystem()

    DosingSystem(

        500.0,

        200.0,

        0.0,

        0.0

    )

end


function dose_detergent!(

    dosing::DosingSystem,

    amount_ml::Real

)

    amount =
        min(

            Float64(amount_ml),

            dosing.detergent_available_ml

        )


    dosing.detergent_available_ml -=
        amount


    dosing.detergent_dosed_ml +=
        amount


    return amount

end


function dose_rinse_aid!(

    dosing::DosingSystem,

    amount_ml::Real

)

    amount =
        min(

            Float64(amount_ml),

            dosing.rinse_aid_available_ml

        )


    dosing.rinse_aid_available_ml -=
        amount


    dosing.rinse_aid_dosed_ml +=
        amount


    return amount

end


# ============================================================
# DRYING SYSTEM
# ============================================================

mutable struct DryingSystem

    fan_on::Bool

    fan_speed_percent::Float64

    estimated_surface_moisture::Float64

end


function DryingSystem()

    DryingSystem(

        false,

        0.0,

        1.0

    )

end


function set_speed!(

    dryer::DryingSystem,

    speed::Real

)

    dryer.fan_speed_percent =
        clamp(

            Float64(speed),

            0.0,
            100.0

        )

    dryer.fan_on =
        dryer.fan_speed_percent > 0

end


function stop!(
    dryer::DryingSystem
)

    dryer.fan_on =
        false

    dryer.fan_speed_percent =
        0.0

end


# ============================================================
# SAFETY
# ============================================================

mutable struct SafetySystem

    door_closed::Bool

    leak_detected::Bool

    overtemperature_limit_c::Float64

    overpressure_limit_bar::Float64

    emergency::Bool

end


function SafetySystem()

    SafetySystem(

        true,

        false,

        85.0,

        3.0,

        false

    )

end


# ============================================================
# CYCLE DEFINITION
# ============================================================

struct DishwasherCycle

    name::String

    target_wash_temperature_c::Float64

    target_rinse_temperature_c::Float64

    fill_volume_l::Float64

    prewash_seconds::Float64

    wash_seconds::Float64

    rinse_seconds::Float64

    dry_seconds::Float64

    pump_speed_percent::Float64

end


function DishwasherCycle(;

    name="AUTO",

    target_wash_temperature_c=55.0,

    target_rinse_temperature_c=65.0,

    fill_volume_l=8.0,

    prewash_seconds=300.0,

    wash_seconds=1800.0,

    rinse_seconds=300.0,

    dry_seconds=1800.0,

    pump_speed_percent=80.0

)

    DishwasherCycle(

        name,

        target_wash_temperature_c,

        target_rinse_temperature_c,

        fill_volume_l,

        prewash_seconds,

        wash_seconds,

        rinse_seconds,

        dry_seconds,

        pump_speed_percent

    )

end


# ============================================================
# BATCH RECORD
# ============================================================

mutable struct CycleRecord

    id::String

    start_time::Union{Nothing,DateTime}

    end_time::Union{Nothing,DateTime}

    cycle_name::String

    water_used_l::Float64

    estimated_energy_kwh::Float64

    final_turbidity_ntu::Float64

    cleanliness_score::Float64

    drying_score::Float64

end


# ============================================================
# TELEMETRY
# ============================================================

struct TelemetryPoint

    timestamp::DateTime

    state::DishwasherState

    water_l::Float64

    temperature_c::Float64

    pressure_bar::Float64

    turbidity_ntu::Float64

    pump_speed_percent::Float64

    soil_level::Float64

end


mutable struct Telemetry

    points::Vector{TelemetryPoint}

end


Telemetry() =
    Telemetry(
        TelemetryPoint[]
    )


# ============================================================
# DISHWASHER
# ============================================================

mutable struct Dishwasher

    name::String

    state::DishwasherState

    cycle::DishwasherCycle

    water::WaterSystem

    thermal::ThermalSystem

    pump::CirculationPump

    turbidity::TurbiditySensor

    load::LoadSensor

    dosing::DosingSystem

    dryer::DryingSystem

    safety::SafetySystem

    telemetry::Telemetry

    record::Union{Nothing,CycleRecord}

    elapsed::Float64

    state_elapsed::Float64

    energy_kwh::Float64

    water_used_l::Float64

end


# ============================================================
# CONSTRUCTOR
# ============================================================

function Dishwasher(

    name::String,

    cycle::DishwasherCycle=DishwasherCycle()

)

    Dishwasher(

        name,

        IDLE,

        cycle,

        WaterSystem(),

        ThermalSystem(),

        CirculationPump(),

        TurbiditySensor(),

        LoadSensor(),

        DosingSystem(),

        DryingSystem(),

        SafetySystem(),

        Telemetry(),

        nothing,

        0.0,

        0.0,

        0.0,

        0.0

    )

end


# ============================================================
# LOAD
# ============================================================

function load_machine!(

    machine::Dishwasher,

    cycle::DishwasherCycle,

    batch_id::String

)

    machine.state == IDLE ||
        error(
            "Dishwasher must be idle."
        )


    machine.cycle =
        cycle


    machine.load =
        LoadSensor()


    estimate_soil!(
        machine.load
    )


    machine.record =

        CycleRecord(

            batch_id,

            nothing,

            nothing,

            cycle.name,

            0.0,

            0.0,

            0.0,

            0.0,

            0.0

        )

end


# ============================================================
# START
# ============================================================

function start!(
    machine::Dishwasher
)

    machine.record === nothing &&
        error(
            "No cycle loaded."
        )


    machine.state =
        FILL


    machine.state_elapsed =
        0.0


    machine.elapsed =
        0.0


    machine.energy_kwh =
        0.0


    machine.water_used_l =
        0.0


    machine.safety.emergency =
        false


    machine.turbidity.ntu =
        120.0


    machine.dryer.estimated_surface_moisture =
        1.0


    if machine.record !== nothing

        machine.record.start_time =
            now()

    end

end


# ============================================================
# FILL
# ============================================================

function fill_step!(

    machine::Dishwasher,

    dt::Float64

)

    target =
        machine.cycle.fill_volume_l


    open_inlet!(

        machine.water,

        4.0

    )


    machine.water.target_volume_l =
        target


    if machine.water.volume_l >=
       target

        close_inlet!(
            machine.water
        )


        machine.water_used_l +=
            target


        machine.state =
            PREWASH


        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# PREWASH
# ============================================================

function prewash_step!(

    machine::Dishwasher,

    dt::Float64

)

    set_speed!(

        machine.pump,

        45.0

    )


    machine.turbidity.ntu -=

        0.025 *
        machine.load.soil_level *
        machine.pump.speed_percent *
        dt


    machine.turbidity.ntu =
        max(

            machine.turbidity.baseline_ntu,

            machine.turbidity.ntu

        )


    machine.state_elapsed +=
        dt


    if machine.state_elapsed >=
       machine.cycle.prewash_seconds

        stop!(
            machine.pump
        )


        machine.state =
            DRAIN


        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# DRAIN
# ============================================================

function drain_step!(

    machine::Dishwasher,

    dt::Float64

)

    close_inlet!(
        machine.water
    )


    open_drain!(

        machine.water,

        6.0

    )


    if machine.water.volume_l <=
       0.10

        close_drain!(
            machine.water
        )


        machine.state =
            FILL


        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# MAIN WASH
# ============================================================

function main_wash_step!(

    machine::Dishwasher,

    dt::Float64

)

    # Dose detergent once.

    if machine.state_elapsed < 1.0

        dose_detergent!(

            machine.dosing,

            25.0 +
            25.0 *
            machine.load.soil_level

        )

    end


    set_speed!(

        machine.pump,

        machine.cycle.pump_speed_percent

    )


    set_target!(

        machine.thermal,

        machine.cycle.target_wash_temperature_c

    )


    # Cleaning model.

    cleaning_rate =

        0.000018 *

        machine.pump.speed_percent *

        (
            1.0 +
            machine.thermal.temperature_c /
            100.0
        )


    machine.turbidity.ntu -=

        cleaning_rate *
        machine.load.soil_level *
        dt


    machine.turbidity.ntu =
        max(

            machine.turbidity.baseline_ntu,

            machine.turbidity.ntu

        )


    machine.state_elapsed +=
        dt


    if machine.state_elapsed >=
       machine.cycle.wash_seconds

        stop!(
            machine.pump
        )


        machine.state =
            DRAIN


        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# HEATING / MAIN WASH CONTROLLER
# ============================================================

function heating_step!(

    machine::Dishwasher,

    dt::Float64

)

    set_target!(

        machine.thermal,

        machine.cycle.target_wash_temperature_c

    )


    set_speed!(

        machine.pump,

        machine.cycle.pump_speed_percent

    )


    machine.state_elapsed +=
        dt


    if machine.thermal.temperature_c >=
       machine.cycle.target_wash_temperature_c - 1.0

        machine.state =
            MAIN_WASH

        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# INTERMEDIATE RINSE
# ============================================================

function intermediate_rinse_step!(

    machine::Dishwasher,

    dt::Float64

)

    set_speed!(
        machine.pump,
        65.0
    )


    machine.turbidity.ntu -=

        0.03 *
        machine.pump.speed_percent /
        100.0 *
        dt


    machine.turbidity.ntu =
        max(

            machine.turbidity.baseline_ntu,

            machine.turbidity.ntu

        )


    machine.state_elapsed +=
        dt


    if machine.state_elapsed >=
       240.0

        stop!(
            machine.pump
        )


        machine.state =
            DRAIN


        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# FINAL RINSE
# ============================================================

function final_rinse_step!(

    machine::Dishwasher,

    dt::Float64

)

    set_speed!(
        machine.pump,
        70.0
    )


    set_target!(

        machine.thermal,

        machine.cycle.target_rinse_temperature_c

    )


    # Rinse aid.

    if machine.state_elapsed < 1.0

        dose_rinse_aid!(

            machine.dosing,

            2.0

        )

    end


    machine.turbidity.ntu -=

        0.02 *
        dt


    machine.turbidity.ntu =
        max(

            machine.turbidity.baseline_ntu,

            machine.turbidity.ntu

        )


    machine.state_elapsed +=
        dt


    if machine.state_elapsed >=
       machine.cycle.rinse_seconds

        stop!(
            machine.pump
        )


        machine.state =
            DRYING


        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# DRYING
# ============================================================

function drying_step!(

    machine::Dishwasher,

    dt::Float64

)

    set_speed!(
        machine.dryer,
        75.0
    )


    drying_rate =

        0.00045 *
        machine.dryer.fan_speed_percent


    machine.dryer.estimated_surface_moisture -=

        drying_rate *
        dt


    machine.dryer.estimated_surface_moisture =

        clamp(

            machine.dryer.estimated_surface_moisture,

            0.0,
            1.0

        )


    machine.state_elapsed +=
        dt


    if machine.state_elapsed >=
       machine.cycle.dry_seconds ||
       machine.dryer.estimated_surface_moisture <=
       0.05

        stop!(
            machine.dryer
        )


        machine.state =
            COOLING


        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# COOLING
# ============================================================

function cooling_step!(

    machine::Dishwasher,

    dt::Float64

)

    set_speed!(
        machine.dryer,
        40.0
    )


    machine.state_elapsed +=
        dt


    if machine.temperature.temperature_c <=
       machine.thermal.ambient_c + 10.0

        stop!(
            machine.dryer
        )


        machine.state =
            COMPLETE


        machine.state_elapsed =
            0.0

    end

end


# ============================================================
# QUALITY MODEL
# ============================================================

function cleanliness_score(

    machine::Dishwasher

)

    turbidity_score =

        1.0 -

        clamp(

            (
                machine.turbidity.ntu -
                machine.turbidity.baseline_ntu
            ) /
            100.0,

            0.0,
            1.0

        )


    temperature_score =

        clamp(

            machine.thermal.temperature_c /
            machine.cycle.target_wash_temperature_c,

            0.0,
            1.0

        )


    pump_score =

        machine.pump.pressure_bar /
        max(
            machine.pump.maximum_pressure_bar,
            0.1
        )


    100.0 *

    (

        0.60 * turbidity_score +
        0.25 * temperature_score +
        0.15 * pump_score

    )

end


function drying_score(

    machine::Dishwasher

)

    100.0 *

    (

        1.0 -
        machine.dryer.estimated_surface_moisture

    )

end


# ============================================================
# ENERGY MODEL
# ============================================================

function update_energy!(

    machine::Dishwasher,

    dt::Float64

)

    heater_kw =

        machine.thermal.heater_on ?

        1.8 *
        machine.thermal.heater_power_percent /
        100.0 :

        0.0


    pump_kw =

        machine.pump.enabled ?

        0.08 +
        0.40 *
        machine.pump.speed_percent /
        100.0 :

        0.0


    fan_kw =

        machine.dryer.fan_on ?

        0.06 *
        machine.dryer.fan_speed_percent /
        100.0 :

        0.0


    total_kw =
        heater_kw +
        pump_kw +
        fan_kw


    machine.energy_kwh +=

        total_kw *
        dt /
        3600.0

end


# ============================================================
# SAFETY
# ============================================================

function emergency_stop!(

    machine::Dishwasher

)

    close_inlet!(
        machine.water
    )


    close_drain!(
        machine.water
    )


    stop!(
        machine.pump
    )


    stop!(
        machine.dryer
    )


    machine.thermal.heater_on =
        false


    machine.thermal.heater_power_percent =
        0.0


    machine.safety.emergency =
        true


    machine.state =
        EMERGENCY_STOP

end


function safety_check!(

    machine::Dishwasher

)

    safety =
        machine.safety


    if !safety.door_closed

        emergency_stop!(
            machine
        )

        return false

    end


    if safety.leak_detected

        emergency_stop!(
            machine
        )

        return false

    end


    if machine.thermal.temperature_c >
       safety.overtemperature_limit_c

        emergency_stop!(
            machine
        )

        return false

    end


    if machine.pump.pressure_bar >
       safety.overpressure_limit_bar

        emergency_stop!(
            machine
        )

        return false

    end


    if machine.water.volume_l >
       machine.water.maximum_volume_l

        emergency_stop!(
            machine
        )

        return false

    end


    true

end


# ============================================================
# TELEMETRY
# ============================================================

function record!(

    machine::Dishwasher

)

    push!(

        machine.telemetry.points,

        TelemetryPoint(

            now(),

            machine.state,

            machine.water.volume_l,

            machine.thermal.temperature_c,

            machine.pump.pressure_bar,

            machine.turbidity.ntu,

            machine.pump.speed_percent,

            machine.load.soil_level

        )

    )

end


# ============================================================
# STATE MACHINE
# ============================================================

function process_state!(

    machine::Dishwasher,

    dt::Float64

)

    state =
        machine.state


    if state == FILL

        # First fill becomes PREWASH.
        # Subsequent fill becomes heating.

        if machine.elapsed < 100.0

            fill_step!(
                machine,
                dt
            )

        else

            fill_step!(
                machine,
                dt
            )

            if machine.state == PREWASH

                machine.state =
                    HEATING

                machine.state_elapsed =
                    0.0

            end

        end


    elseif state == PREWASH

        prewash_step!(
            machine,
            dt
        )


    elseif state == MAIN_WASH

        main_wash_step!(
            machine,
            dt
        )


    elseif state == HEATING

        heating_step!(
            machine,
            dt
        )


    elseif state == DRAIN

        drain_step!(
            machine,
            dt
        )


    elseif state == INTERMEDIATE_RINSE

        intermediate_rinse_step!(
            machine,
            dt
        )


    elseif state == FINAL_RINSE

        final_rinse_step!(
            machine,
            dt
        )


    elseif state == DRYING

        drying_step!(
            machine,
            dt
        )


    elseif state == COOLING

        cooling_step!(
            machine,
            dt
        )


    elseif state == COMPLETE

        finalize_record!(
            machine
        )

    end

end


# ============================================================
# STATE TRANSITION OVERRIDE
# ============================================================

function transition_logic!(

    machine::Dishwasher

)

    # This controller interprets the DRAIN state according to
    # the stage immediately preceding it.

    state =
        machine.state


    if state == DRAIN

        if machine.state_elapsed < 0.5

            # Drain step itself controls transition.
            return

        end

    end

end


# ============================================================
# IMPROVED DRAIN ROUTER
# ============================================================

function route_after_drain!(

    machine::Dishwasher

)

    # Determine next stage from the completed process.

    if machine.dosing.detergent_dosed_ml > 0 &&
       machine.state_elapsed == 0.0

        machine.state =
            INTERMEDIATE_RINSE

        machine.state_elapsed =
            0.0

        return

    end

end


# ============================================================
# MASTER PROCESS LOOP
# ============================================================

function control_step!(

    machine::Dishwasher,

    dt::Float64=1.0

)

    machine.state in
        (
            IDLE,
            COMPLETE,
            FAULT,
            EMERGENCY_STOP
        ) &&
        return


    previous_state =
        machine.state


    update!(
        machine.water,
        dt
    )


    update!(
        machine.thermal,
        dt,
        machine.water.volume_l
    )


    update!(
        machine.pump,
        dt
    )


    process_state!(
        machine,
        dt
    )


    # Handle the process sequence.

    if previous_state == DRAIN &&
       machine.state == FILL

        # This is the post-prewash fill.

        machine.state =
            HEATING

        machine.state_elapsed =
            0.0

    end


    if previous_state == DRAIN &&
       machine.state == FILL

        machine.state =
            HEATING

    end


    # When the second fill completes, enter heating.

    if machine.state == PREWASH &&
       machine.dosing.detergent_dosed_ml > 0

        machine.state =
            HEATING

        machine.state_elapsed =
            0.0

    end


    # Main wash completion routes to intermediate rinse.

    if previous_state == MAIN_WASH &&
       machine.state == DRAIN

        # Flag through negative elapsed marker.

        machine.state_elapsed =
            -1.0

    end


    if machine.state == DRAIN &&
       machine.state_elapsed == -1.0

        open_drain!(
            machine.water,
            6.0
        )

        if machine.water.volume_l <= 0.10

            close_drain!(
                machine.water
            )

            machine.state =
                FINAL_RINSE

            machine.state_elapsed =
                0.0

        end

    end


    update_energy!(
        machine,
        dt
    )


    safety_check!(
        machine
    )


    record!(
        machine
    )


    machine.elapsed +=
        dt

end


# ============================================================
# FINAL RECORD
# ============================================================

function finalize_record!(

    machine::Dishwasher

)

    machine.record === nothing &&
        return


    record =
        machine.record


    record.end_time =
        now()


    record.water_used_l =
        machine.water_used_l


    record.estimated_energy_kwh =
        machine.energy_kwh


    record.final_turbidity_ntu =
        machine.turbidity.ntu


    record.cleanliness_score =
        cleanliness_score(
            machine
        )


    record.drying_score =
        drying_score(
            machine
        )

end


# ============================================================
# STATUS
# ============================================================

function status(

    machine::Dishwasher

)

    (

        machine =
            machine.name,

        state =
            machine.state,

        water_l =
            machine.water.volume_l,

        temperature_c =
            machine.thermal.temperature_c,

        pressure_bar =
            machine.pump.pressure_bar,

        turbidity_ntu =
            machine.turbidity.ntu,

        soil_level =
            machine.load.soil_level,

        detergent_used_ml =
            machine.dosing.detergent_dosed_ml,

        rinse_aid_used_ml =
            machine.dosing.rinse_aid_dosed_ml,

        energy_kwh =
            machine.energy_kwh,

        cleanliness =
            cleanliness_score(
                machine
            ),

        drying =
            drying_score(
                machine
            )

    )

end


# ============================================================
# DISPLAY
# ============================================================

function display_status!(

    machine::Dishwasher

)

    s =
        status(machine)


    println(

        @sprintf(

            "%-20s | WATER %5.2f L | TEMP %5.1f°C | PRESS %4.2f bar | TURB %6.1f NTU | CLEAN %5.1f%% | %-18s",

            string(s.state),

            s.water_l,

            s.temperature_c,

            s.pressure_bar,

            s.turbidity_ntu,

            s.cleanliness,

            string(machine.name)

        )

    )

end


# ============================================================
# SELF DIAGNOSTICS
# ============================================================

function diagnostics(

    machine::Dishwasher

)

    checks = Dict{String,Bool}()


    checks["Door sensor"] =
        machine.safety.door_closed


    checks["Temperature sensor"] =
        machine.temperature_sensor_ok


    checks["Turbidity sensor"] =
        machine.turbidity.healthy


    checks["Leak sensor"] =
        !machine.safety.leak_detected


    checks["Pump pressure"] =
        machine.pump.pressure_bar <=
        machine.safety.overpressure_limit_bar


    checks

end


# ============================================================
# CLEANING CYCLE
# ============================================================

function machine_clean!(
    machine::Dishwasher
)

    machine.state in
        (
            IDLE,
            COMPLETE
        ) || error(
            "Machine cleaning unavailable during active cycle."
        )


    machine.state =
        CLEANING


    println()
    println(
        "DISHWASHEROS MACHINE CLEAN"
    )


    println(
        "→ Drain system"
    )


    machine.water.volume_l =
        0.0


    println(
        "→ Circulation system purge"
    )


    stop!(
        machine.pump
    )


    println(
        "→ Heater shutdown"
    )


    machine.thermal.heater_on =
        false


    println(
        "→ Filter inspection required"
    )


    println(
        "→ Cleaning complete"
    )


    machine.state =
        IDLE

end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println()
    println("="^120)

    println(
        "                         DISHWASHEROS"
    )

    println(
        "              INTELLIGENT HOME DISHWASHER"
    )

    println("="^120)


    # --------------------------------------------------------
    # Automatic cycle
    # --------------------------------------------------------

    cycle =

        DishwasherCycle(

            name="AUTO",

            target_wash_temperature_c=55.0,

            target_rinse_temperature_c=65.0,

            fill_volume_l=8.0,

            prewash_seconds=300.0,

            wash_seconds=1200.0,

            rinse_seconds=300.0,

            dry_seconds=900.0,

            pump_speed_percent=80.0

        )


    machine =

        Dishwasher(

            "DISHWASHEROS-001",

            cycle

        )


    load_machine!(

        machine,

        cycle,

        "DW-2026-0001"

    )


    println()
    println(
        "CYCLE: ",
        cycle.name
    )


    println(
        "LOAD MASS: ",
        machine.load.estimated_mass_kg,
        " kg"
    )


    println(
        "ESTIMATED SOIL: ",

        round(

            machine.load.soil_level * 100,

            digits=1

        ),

        "%"
    )


    start!(
        machine
    )


    println()
    println(
        "AUTOMATIC WASH STARTED"
    )


    # --------------------------------------------------------
    # Simulated appliance runtime
    # --------------------------------------------------------

    for second in 1:10000

        control_step!(
            machine,
            1.0
        )


        if second % 120 == 0

            display_status!(
                machine
            )

        end


        if machine.state in
            (
                COMPLETE,
                FAULT,
                EMERGENCY_STOP
            )

            break

        end

    end


    # --------------------------------------------------------
    # Final report
    # --------------------------------------------------------

    s =
        status(machine)


    println()
    println("="^120)

    println(
        "                         CYCLE COMPLETE"
    )

    println("="^120)


    println(
        "State: ",
        s.state
    )


    println(

        @sprintf(

            "Water used: %.2f L",

            machine.water_used_l

        )

    )


    println(

        @sprintf(

            "Energy estimate: %.3f kWh",

            machine.energy_kwh

        )

    )


    println(

        @sprintf(

            "Final turbidity: %.2f NTU",

            machine.turbidity.ntu

        )

    )


    println(

        @sprintf(

            "Cleanliness score: %.1f / 100",

            cleanliness_score(
                machine
            )

        )

    )


    println(

        @sprintf(

            "Drying score: %.1f / 100",

            drying_score(
                machine
            )

        )

    )


    println(
        "Detergent used: ",

        round(

            machine.dosing.detergent_dosed_ml,

            digits=1

        ),

        " ml"
    )


    println(
        "Rinse aid used: ",

        round(

            machine.dosing.rinse_aid_dosed_ml,

            digits=1

        ),

        " ml"
    )


    println(
        "Telemetry samples: ",

        length(
            machine.telemetry.points
        )

    )


    println("="^120)

end


# ============================================================
# EXPORTS
# ============================================================

export DishwasherState

export IDLE
export LOADING
export FILL
export PREWASH
export MAIN_WASH
export HEATING
export INTENSIVE_WASH
export DRAIN
export INTERMEDIATE_RINSE
export FINAL_RINSE
export SANITIZATION
export DRYING
export COOLING
export COMPLETE
export CLEANING
export FAULT
export EMERGENCY_STOP

export WaterSystem
export ThermalSystem
export CirculationPump
export TurbiditySensor
export LoadSensor
export DosingSystem
export DryingSystem
export SafetySystem

export DishwasherCycle
export CycleRecord
export TelemetryPoint
export Telemetry

export Dishwasher

export load_machine!
export start!
export control_step!
export emergency_stop!
export machine_clean!

export cleanliness_score
export drying_score
export status
export display_status!

export demo


end # module


# ============================================================
# APPLICATION ENTRY POINT
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .DishwasherOS

    DishwasherOS.demo()

end
```
 
