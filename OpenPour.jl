OpenPour




module OpenPour

using Dates
using Printf

# ============================================================
# OPENPOUR
#
# INDUSTRY 4.0 AUTOMATED PINT DISPENSING SYSTEM
# Pure Julia
#
# Digital twin / simulation controller for automated
# draught-beer dispensing.
#
# Pipeline:
#
# ORDER
#   ↓
# BEER SELECTION
#   ↓
# GLASS DETECTION
#   ↓
# LINE / KEG SELECTION
#   ↓
# PRE-DISPENSE CHECK
#   ↓
# LIQUID PHASE
#   ↓
# FOAM MANAGEMENT
#   ↓
# TOP-UP
#   ↓
# QUALITY CONTROL
#   ↓
# SERVE
#   ↓
# INVENTORY / TELEMETRY
#
# NOTE:
# This is a software simulation/reference implementation.
# A real food/beverage machine requires appropriate
# mechanical, electrical, sanitation and safety engineering.
# ============================================================


# ============================================================
# CONSTANTS
# ============================================================

const ML_PER_UK_PINT = 568.26125


# ============================================================
# ENUMERATIONS
# ============================================================

@enum MachineState begin
    OFF
    IDLE
    READY
    GLASS_DETECTED
    PREPARING
    POURING
    FOAM_CONTROL
    TOPPING
    QUALITY_CHECK
    SERVING
    CLEANING
    COMPLETE
    FAULT
    EMERGENCY_STOP
end


@enum BeerStyle begin
    LAGER
    ALE
    STOUT
    IPA
    CIDER
    OTHER
end


@enum KegState begin
    CONNECTED
    LOW
    EMPTY
    DISCONNECTED
end


# ============================================================
# BEER / KEG
# ============================================================

mutable struct Keg

    id::Int

    brand::String

    style::BeerStyle

    volume_ml::Float64

    original_volume_ml::Float64

    temperature_C::Float64

    pressure_bar::Float64

    state::KegState

    batch_lot::String

    best_before::Date

    enabled::Bool
end


function Keg(
    id::Int,
    brand::String,
    style::BeerStyle,
    volume_ml::Float64;
    temperature_C=4.0,
    pressure_bar=1.0,
    batch_lot="UNKNOWN",
    best_before=today() + Day(30)
)

    Keg(
        id,
        brand,
        style,
        volume_ml,
        volume_ml,
        temperature_C,
        pressure_bar,
        CONNECTED,
        batch_lot,
        best_before,
        true
    )
end


# ============================================================
# DISPENSE CONFIGURATION
# ============================================================

struct PourProfile

    target_volume_ml::Float64

    tolerance_ml::Float64

    target_temperature_C::Float64

    max_temperature_C::Float64

    target_foam_ml::Float64

    maximum_pour_time_s::Float64

    fast_flow_ml_s::Float64

    slow_flow_ml_s::Float64

    topping_flow_ml_s::Float64

    quality_threshold::Float64
end


function UKPintProfile(;
    target_volume_ml=ML_PER_UK_PINT,
    tolerance_ml=8.0,
    target_temperature_C=4.0,
    max_temperature_C=7.0,
    target_foam_ml=45.0,
    maximum_pour_time_s=30.0,
    fast_flow_ml_s=180.0,
    slow_flow_ml_s=75.0,
    topping_flow_ml_s=35.0,
    quality_threshold=90.0
)

    PourProfile(
        target_volume_ml,
        tolerance_ml,
        target_temperature_C,
        max_temperature_C,
        target_foam_ml,
        maximum_pour_time_s,
        fast_flow_ml_s,
        slow_flow_ml_s,
        topping_flow_ml_s,
        quality_threshold
    )
end


# ============================================================
# GLASS
# ============================================================

mutable struct Glass

    detected::Bool

    capacity_ml::Float64

    current_volume_ml::Float64

    foam_volume_ml::Float64

    temperature_C::Float64

    position_x_mm::Float64

    position_y_mm::Float64

    position_z_mm::Float64

    clean::Bool
end


function Glass(;
    capacity_ml=600.0,
    temperature_C=20.0
)

    Glass(
        false,
        capacity_ml,
        0.0,
        0.0,
        temperature_C,
        0.0,
        0.0,
        0.0,
        true
    )
end


# ============================================================
# FLOW SENSOR
# ============================================================

mutable struct FlowSensor

    instantaneous_flow_ml_s::Float64

    total_volume_ml::Float64

    pulse_count::Int

    calibration_factor::Float64
end


FlowSensor() =
    FlowSensor(
        0.0,
        0.0,
        0,
        1.0
    )


# ============================================================
# TEMPERATURE SENSOR
# ============================================================

mutable struct TemperatureSensor

    temperature_C::Float64

    valid::Bool
end


TemperatureSensor() =
    TemperatureSensor(
        4.0,
        true
    )


# ============================================================
# PRESSURE SENSOR
# ============================================================

mutable struct PressureSensor

    pressure_bar::Float64

    valid::Bool
end


PressureSensor() =
    PressureSensor(
        1.0,
        true
    )


# ============================================================
# FOAM SENSOR
# ============================================================

mutable struct FoamSensor

    foam_height_mm::Float64

    foam_volume_ml::Float64

    valid::Bool
end


FoamSensor() =
    FoamSensor(
        0.0,
        0.0,
        true
    )


# ============================================================
# VALVE
# ============================================================

mutable struct DispenseValve

    open::Bool

    opening_percent::Float64

    cycle_count::Int
end


DispenseValve() =
    DispenseValve(
        false,
        0.0,
        0
    )


function open!(
    valve::DispenseValve,
    percentage::Float64
)

    valve.open =
        percentage > 0

    valve.opening_percent =
        clamp(
            percentage,
            0.0,
            100.0
        )

    valve.cycle_count += 1
end


function close!(
    valve::DispenseValve
)

    valve.open =
        false

    valve.opening_percent =
        0.0
end


# ============================================================
# GLASS DETECTOR
# ============================================================

mutable struct GlassDetector

    detected::Bool

    confidence::Float64
end


GlassDetector() =
    GlassDetector(
        false,
        0.0
    )


# ============================================================
# POUR RECORD
# ============================================================

mutable struct PourRecord

    id::Int

    timestamp::DateTime

    keg_id::Int

    beer::String

    target_volume_ml::Float64

    actual_volume_ml::Float64

    foam_volume_ml::Float64

    temperature_C::Float64

    pour_time_s::Float64

    quality_score::Float64

    passed::Bool

    status::Symbol
end


# ============================================================
# EVENT LOG
# ============================================================

struct Event

    timestamp::DateTime

    event::Symbol

    message::String
end


mutable struct EventLog

    events::Vector{Event}
end


EventLog() =
    EventLog(
        Event[]
    )


function log!(
    log::EventLog,
    event::Symbol,
    message::String
)

    push!(
        log.events,
        Event(
            now(),
            event,
            message
        )
    )
end


# ============================================================
# MAIN MACHINE
# ============================================================

mutable struct OpenPourMachine

    state::MachineState

    profile::PourProfile

    kegs::Dict{Int,Keg}

    selected_keg_id::Union{Int,Nothing}

    glass::Glass

    glass_detector::GlassDetector

    flow_sensor::FlowSensor

    temperature_sensor::TemperatureSensor

    pressure_sensor::PressureSensor

    foam_sensor::FoamSensor

    valve::DispenseValve

    active_pour::Union{PourRecord,Nothing}

    completed_pours::Vector{PourRecord}

    next_pour_id::Int

    eventlog::EventLog

    emergency_stop::Bool
end


function OpenPourMachine(
    profile::PourProfile=UKPintProfile()
)

    OpenPourMachine(
        OFF,
        profile,
        Dict{Int,Keg}(),
        nothing,
        Glass(),
        GlassDetector(),
        FlowSensor(),
        TemperatureSensor(),
        PressureSensor(),
        FoamSensor(),
        DispenseValve(),
        nothing,
        PourRecord[],
        1,
        EventLog(),
        false
    )
end


# ============================================================
# POWER
# ============================================================

function power_on!(
    machine::OpenPourMachine
)

    machine.emergency_stop &&
        return false

    machine.state =
        READY

    log!(
        machine.eventlog,
        :POWER_ON,
        "OpenPour system ready"
    )

    true
end


function power_off!(
    machine::OpenPourMachine
)

    close!(
        machine.valve
    )

    machine.state =
        OFF

    log!(
        machine.eventlog,
        :POWER_OFF,
        "Machine powered down"
    )
end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(
    machine::OpenPourMachine
)

    machine.emergency_stop =
        true

    close!(
        machine.valve
    )

    machine.state =
        EMERGENCY_STOP

    log!(
        machine.eventlog,
        :EMERGENCY_STOP,
        "Dispense immediately stopped"
    )
end


function reset_emergency!(
    machine::OpenPourMachine
)

    machine.emergency_stop =
        false

    machine.state =
        READY

    log!(
        machine.eventlog,
        :ESTOP_RESET,
        "Emergency stop reset"
    )
end


# ============================================================
# KEG MANAGEMENT
# ============================================================

function add_keg!(
    machine::OpenPourMachine,
    keg::Keg
)

    machine.kegs[
        keg.id
    ] = keg

    log!(
        machine.eventlog,
        :KEG_CONNECTED,
        "$(keg.brand) connected"
    )

    keg.id
end


function keg_remaining_percent(
    keg::Keg
)

    100.0 *
    keg.volume_ml /
    keg.original_volume_ml
end


function update_keg_state!(
    keg::Keg
)

    if keg.volume_ml <= 0

        keg.state =
            EMPTY

    elseif keg.volume_ml <
           0.10 *
           keg.original_volume_ml

        keg.state =
            LOW

    else

        keg.state =
            CONNECTED
    end
end


# ============================================================
# BEER SELECTION
# ============================================================

function select_keg!(
    machine::OpenPourMachine,
    keg_id::Int
)

    haskey(
        machine.kegs,
        keg_id
    ) ||
        error(
            "Keg not found."
        )

    keg =
        machine.kegs[
            keg_id
        ]

    keg.enabled ||
        return false

    keg.state in
        (EMPTY, DISCONNECTED) &&
        return false

    machine.selected_keg_id =
        keg_id

    machine.pressure_sensor.pressure_bar =
        keg.pressure_bar

    machine.temperature_sensor.temperature_C =
        keg.temperature_C

    log!(
        machine.eventlog,
        :KEG_SELECTED,
        "$(keg.brand) selected"
    )

    true
end


# ============================================================
# GLASS DETECTION
# ============================================================

function detect_glass!(
    machine::OpenPourMachine,
    detected::Bool;
    confidence=1.0
)

    machine.glass_detector.detected =
        detected

    machine.glass_detector.confidence =
        confidence

    machine.glass.detected =
        detected

    if detected

        machine.state =
            GLASS_DETECTED

        log!(
            machine.eventlog,
            :GLASS_DETECTED,
            "Glass detected"
        )

    else

        machine.state =
            READY

        log!(
            machine.eventlog,
            :GLASS_REMOVED,
            "Glass removed"
        )
    end

    detected
end


# ============================================================
# GLASS VALIDATION
# ============================================================

function validate_glass(
    machine::OpenPourMachine
)

    machine.glass.detected &&
    machine.glass.clean &&
    machine.glass.capacity_ml >=
        machine.profile.target_volume_ml
end


# ============================================================
# PRE-POUR CHECK
# ============================================================

function pre_pour_check(
    machine::OpenPourMachine
)

    machine.emergency_stop &&
        return false

    machine.selected_keg_id === nothing &&
        return false

    validate_glass(machine) ||
        return false

    keg =
        machine.kegs[
            machine.selected_keg_id
        ]

    keg.volume_ml >=
        machine.profile.target_volume_ml ||
        return false

    keg.temperature_C <=
        machine.profile.max_temperature_C ||
        return false

    keg.pressure_bar > 0 ||
        return false

    true
end


# ============================================================
# CREATE POUR
# ============================================================

function create_pour!(
    machine::OpenPourMachine
)

    keg =
        machine.kegs[
            machine.selected_keg_id
        ]

    pour =
        PourRecord(
            machine.next_pour_id,
            now(),
            keg.id,
            keg.brand,
            machine.profile.target_volume_ml,
            0.0,
            0.0,
            keg.temperature_C,
            0.0,
            0.0,
            false,
            :STARTED
        )

    machine.next_pour_id += 1

    machine.active_pour =
        pour

    pour
end


# ============================================================
# FLOW MODEL
# ============================================================

function flow_rate(
    machine::OpenPourMachine
)

    keg =
        machine.kegs[
            machine.selected_keg_id
        ]

    pressure_factor =
        clamp(
            keg.pressure_bar,
            0.2,
            2.0
        )

    base =
        machine.profile.fast_flow_ml_s

    base *
    pressure_factor
end


# ============================================================
# FOAM MODEL
# ============================================================

function estimated_foam_generation(
    machine::OpenPourMachine,
    flow_ml_s::Float64
)

    keg =
        machine.kegs[
            machine.selected_keg_id
        ]

    # Simplified digital-twin model.
    #
    # Higher flow and higher temperature increase
    # estimated foam generation.

    temperature_factor =
        max(
            0.0,
            keg.temperature_C -
            machine.profile.target_temperature_C
        )

    flow_factor =
        flow_ml_s /
        machine.profile.fast_flow_ml_s

    base_foam =
        0.05 *
        flow_ml_s

    foam =
        base_foam *
        (
            1.0 +
            0.20 *
            temperature_factor +
            0.20 *
            flow_factor
        )

    foam
end


# ============================================================
# SENSOR UPDATE
# ============================================================

function update_sensors!(
    machine::OpenPourMachine
)

    machine.selected_keg_id === nothing &&
        return

    keg =
        machine.kegs[
            machine.selected_keg_id
        ]

    machine.temperature_sensor.temperature_C =
        keg.temperature_C

    machine.pressure_sensor.pressure_bar =
        keg.pressure_bar

    machine.foam_sensor.foam_volume_ml =
        machine.glass.foam_volume_ml

    machine.flow_sensor.total_volume_ml =
        machine.glass.current_volume_ml
end


# ============================================================
# DISPENSE LIQUID
# ============================================================

function dispense_step!(
    machine::OpenPourMachine,
    dt::Float64,
    flow_ml_s::Float64
)

    machine.emergency_stop &&
        return false

    machine.valve.open ||
        return false

    keg =
        machine.kegs[
            machine.selected_keg_id
        ]

    requested =
        flow_ml_s *
        dt

    remaining =
        keg.volume_ml

    delivered =
        min(
            requested,
            remaining
        )

    # ----------------------------------------
    # Beer entering glass
    # ----------------------------------------

    machine.glass.current_volume_ml +=
        delivered

    # ----------------------------------------
    # Foam generation
    # ----------------------------------------

    foam =
        estimated_foam_generation(
            machine,
            flow_ml_s
        ) *
        dt

    machine.glass.foam_volume_ml +=
        foam

    # ----------------------------------------
    # Keg inventory
    # ----------------------------------------

    keg.volume_ml -=
        delivered

    keg.volume_ml =
        max(
            keg.volume_ml,
            0.0
        )

    # ----------------------------------------
    # Sensor simulation
    # ----------------------------------------

    machine.flow_sensor.instantaneous_flow_ml_s =
        delivered / dt

    machine.flow_sensor.total_volume_ml +=
        delivered

    machine.flow_sensor.pulse_count +=
        round(
            delivered / 1.0
        )

    update_keg_state!(
        keg
    )

    update_sensors!(
        machine
    )

    true
end


# ============================================================
# LIQUID PHASE
# ============================================================

function pour_fast_phase!(
    machine::OpenPourMachine
)

    machine.state =
        POURING

    open!(
        machine.valve,
        100.0
    )

    target =
        machine.profile.target_volume_ml

    # Stop before the nominal target to leave room
    # for foam/top-up control.

    fast_target =
        max(
            0.0,
            target -
            machine.profile.target_foam_ml
        )

    current =
        machine.glass.current_volume_ml

    if current < fast_target

        required =
            fast_target -
            current

        duration =
            required /
            machine.profile.fast_flow_ml_s

        duration =
            min(
                duration,
                machine.profile.maximum_pour_time_s
            )

        dispense_step!(
            machine,
            duration,
            machine.profile.fast_flow_ml_s
        )
    end

    close!(
        machine.valve
    )

    true
end


# ============================================================
# FOAM SETTLE
# ============================================================

function settle_foam!(
    machine::OpenPourMachine;
    duration_s=1.5
)

    machine.state =
        FOAM_CONTROL

    close!(
        machine.valve
    )

    # Simulated foam collapse.

    collapse_rate =
        0.20

    machine.glass.foam_volume_ml *=
        exp(
            -collapse_rate *
            duration_s
        )

    update_sensors!(
        machine
    )

    true
end


# ============================================================
# TOP-UP
# ============================================================

function top_up!(
    machine::OpenPourMachine
)

    machine.state =
        TOPPING

    target =
        machine.profile.target_volume_ml

    current =
        machine.glass.current_volume_ml

    if current >= target

        return true
    end

    required =
        target -
        current

    flow =
        machine.profile.topping_flow_ml_s

    duration =
        required /
        flow

    open!(
        machine.valve,
        35.0
    )

    dispense_step!(
        machine,
        duration,
        flow
    )

    close!(
        machine.valve
    )

    true
end


# ============================================================
# FOAM / HEAD MANAGEMENT
# ============================================================

function manage_foam!(
    machine::OpenPourMachine
)

    target =
        machine.profile.target_foam_ml

    current =
        machine.glass.foam_volume_ml

    if current > target

        excess =
            current -
            target

        # Digital model of controlled settling.

        machine.glass.foam_volume_ml =
            max(
                target,
                current -
                excess * 0.50
            )
    end

    update_sensors!(
        machine
    )

    true
end


# ============================================================
# QUALITY CONTROL
# ============================================================

function calculate_quality(
    machine::OpenPourMachine
)

    target_volume =
        machine.profile.target_volume_ml

    actual_volume =
        machine.glass.current_volume_ml

    target_temp =
        machine.profile.target_temperature_C

    actual_temp =
        machine.temperature_sensor.temperature_C

    target_foam =
        machine.profile.target_foam_ml

    actual_foam =
        machine.glass.foam_volume_ml

    volume_error =
        abs(
            actual_volume -
            target_volume
        )

    temperature_error =
        abs(
            actual_temp -
            target_temp
        )

    foam_error =
        abs(
            actual_foam -
            target_foam
        )

    volume_score =
        max(
            0.0,
            100.0 -
            volume_error * 4.0
        )

    temperature_score =
        max(
            0.0,
            100.0 -
            temperature_error * 10.0
        )

    foam_score =
        max(
            0.0,
            100.0 -
            foam_error * 2.0
        )

    quality =
        0.50 *
        volume_score +

        0.25 *
        temperature_score +

        0.25 *
        foam_score

    clamp(
        quality,
        0.0,
        100.0
    )
end


function quality_check!(
    machine::OpenPourMachine
)

    machine.state =
        QUALITY_CHECK

    quality =
        calculate_quality(
            machine
        )

    pour =
        machine.active_pour

    pour === nothing &&
        return false

    pour.actual_volume_ml =
        machine.glass.current_volume_ml

    pour.foam_volume_ml =
        machine.glass.foam_volume_ml

    pour.temperature_C =
        machine.temperature_sensor.temperature_C

    pour.quality_score =
        quality

    pour.passed =
        quality >=
        machine.profile.quality_threshold

    pour.status =
        pour.passed ?
        :PASSED :
        :FAILED

    if pour.passed

        log!(
            machine.eventlog,
            :QUALITY_PASS,
            @sprintf(
                "Pour %d passed: %.1f/100",
                pour.id,
                quality
            )
        )

    else

        log!(
            machine.eventlog,
            :QUALITY_FAIL,
            @sprintf(
                "Pour %d failed: %.1f/100",
                pour.id,
                quality
            )
        )
    end

    pour.passed
end


# ============================================================
# SERVE
# ============================================================

function serve!(
    machine::OpenPourMachine
)

    pour =
        machine.active_pour

    pour === nothing &&
        return false

    machine.state =
        SERVING

    log!(
        machine.eventlog,
        :SERVED,
        "Pour $(pour.id) served"
    )

    push!(
        machine.completed_pours,
        pour
    )

    machine.active_pour =
        nothing

    machine.state =
        COMPLETE

    true
end


# ============================================================
# COMPLETE AUTOMATIC POUR
# ============================================================

function automatic_pour!(
    machine::OpenPourMachine,
    keg_id::Int
)

    machine.state ==
        READY ||
        machine.state ==
        GLASS_DETECTED ||
        return false

    select_keg!(
        machine,
        keg_id
    ) ||
        return false

    machine.glass.detected ||
        return false

    pre_pour_check(
        machine
    ) ||
        return false

    create_pour!(
        machine
    )

    # ----------------------------------------
    # Phase 1 — fast fill
    # ----------------------------------------

    pour_fast_phase!(
        machine
    )

    # ----------------------------------------
    # Phase 2 — foam settling
    # ----------------------------------------

    settle_foam!(
        machine
    )

    # ----------------------------------------
    # Phase 3 — foam management
    # ----------------------------------------

    manage_foam!(
        machine
    )

    # ----------------------------------------
    # Phase 4 — precision top-up
    # ----------------------------------------

    top_up!(
        machine
    )

    # ----------------------------------------
    # Final foam correction
    # ----------------------------------------

    manage_foam!(
        machine
    )

    # ----------------------------------------
    # Quality
    # ----------------------------------------

    passed =
        quality_check!(
            machine
        )

    if !passed

        log!(
            machine.eventlog,
            :POUR_REJECTED,
            "Pour failed quality control"
        )

        return false
    end

    # ----------------------------------------
    # Serve
    # ----------------------------------------

    serve!(
        machine
    )
end


# ============================================================
# CLEANING
# ============================================================

function cleaning_cycle!(
    machine::OpenPourMachine
)

    machine.state =
        CLEANING

    close!(
        machine.valve
    )

    log!(
        machine.eventlog,
        :CLEANING_START,
        "Beer line cleaning cycle started"
    )

    # Simulation only.
    #
    # Real CIP would have separately engineered
    # cleaning chemistry, temperature, contact time,
    # flushing and verification.

    log!(
        machine.eventlog,
        :CLEANING_COMPLETE,
        "Beer line cleaning completed"
    )

    machine.state =
        READY
end


# ============================================================
# RESET GLASS
# ============================================================

function replace_glass!(
    machine::OpenPourMachine;
    capacity_ml=600.0,
    temperature_C=20.0
)

    machine.glass =
        Glass(
            capacity_ml=capacity_ml,
            temperature_C=temperature_C
        )

    machine.glass_detector.detected =
        false

    machine.glass_detector.confidence =
        0.0

    machine.state =
        READY
end


# ============================================================
# INVENTORY REPORT
# ============================================================

function inventory_report(
    machine::OpenPourMachine
)

    rows =
        NamedTuple[]

    for keg in
        values(machine.kegs)

        push!(
            rows,
            (
                id = keg.id,
                beer = keg.brand,
                style = keg.style,
                remaining_ml =
                    keg.volume_ml,
                remaining_percent =
                    keg_remaining_percent(keg),
                temperature_C =
                    keg.temperature_C,
                pressure_bar =
                    keg.pressure_bar,
                state =
                    keg.state,
                lot =
                    keg.batch_lot
            )
        )
    end

    rows
end


# ============================================================
# MACHINE TELEMETRY
# ============================================================

function telemetry(
    machine::OpenPourMachine
)

    (
        timestamp = now(),

        state =
            machine.state,

        selected_keg =
            machine.selected_keg_id,

        glass_detected =
            machine.glass.detected,

        volume_ml =
            machine.glass.current_volume_ml,

        foam_ml =
            machine.glass.foam_volume_ml,

        temperature_C =
            machine.temperature_sensor.temperature_C,

        pressure_bar =
            machine.pressure_sensor.pressure_bar,

        flow_ml_s =
            machine.flow_sensor.instantaneous_flow_ml_s,

        quality =
            machine.active_pour === nothing ?
            nothing :
            machine.active_pour.quality_score
    )
end


# ============================================================
# STATUS
# ============================================================

function print_status(
    machine::OpenPourMachine
)

    t =
        telemetry(machine)

    println()
    println(
        "="^65
    )

    println(
        "             OPENPOUR"
    )

    println(
        "      INDUSTRY 4.0 PUB DISPENSER"
    )

    println(
        "="^65
    )

    println(
        "Machine state:     ",
        t.state
    )

    println(
        "Selected keg:      ",
        t.selected_keg
    )

    println(
        "Glass detected:    ",
        t.glass_detected
    )

    @printf(
        "Beer volume:       %.2f ml\n",
        t.volume_ml
    )

    @printf(
        "Foam/head:         %.2f ml\n",
        t.foam_ml
    )

    @printf(
        "Temperature:       %.2f °C\n",
        t.temperature_C
    )

    @printf(
        "Pressure:          %.2f bar\n",
        t.pressure_bar
    )

    @printf(
        "Flow:              %.2f ml/s\n",
        t.flow_ml_s
    )

    if t.quality !== nothing

        @printf(
            "Quality:           %.1f / 100\n",
            t.quality
        )
    end

    println(
        "="^65
    )
end


# ============================================================
# POUR REPORT
# ============================================================

function print_pour_history(
    machine::OpenPourMachine
)

    println()
    println(
        "POUR HISTORY"
    )

    println(
        "-"^80
    )

    for pour in
        machine.completed_pours

        println(
            "ID=",
            pour.id,
            " | ",
            pour.beer,
            " | ",
            @sprintf(
                "%.1f ml",
                pour.actual_volume_ml
            ),
            " | foam=",
            @sprintf(
                "%.1f ml",
                pour.foam_volume_ml
            ),
            " | temp=",
            @sprintf(
                "%.1f°C",
                pour.temperature_C
            ),
            " | quality=",
            @sprintf(
                "%.1f",
                pour.quality_score
            ),
            " | ",
            pour.status
        )
    end
end


# ============================================================
# EVENT REPORT
# ============================================================

function print_events(
    machine::OpenPourMachine
)

    println()
    println(
        "EVENT LOG"
    )

    println(
        "-"^80
    )

    for event in
        machine.eventlog.events

        println(
            event.timestamp,
            " | ",
            event.event,
            " | ",
            event.message
        )
    end
end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println()
    println(
        "OPENPOUR — AUTOMATED PINT DISPENSER"
    )

    machine =
        OpenPourMachine()

    # --------------------------------------------------------
    # Beer lines / kegs
    # --------------------------------------------------------

    lager =
        Keg(
            1,
            "House Lager",
            LAGER,
            50000.0;
            temperature_C=4.0,
            pressure_bar=1.0,
            batch_lot="LAG-260830"
        )

    stout =
        Keg(
            2,
            "House Stout",
            STOUT,
            50000.0;
            temperature_C=5.0,
            pressure_bar=0.9,
            batch_lot="STO-260830"
        )

    cider =
        Keg(
            3,
            "House Cider",
            CIDER,
            30000.0;
            temperature_C=5.0,
            pressure_bar=1.0,
            batch_lot="CID-260830"
        )

    add_keg!(
        machine,
        lager
    )

    add_keg!(
        machine,
        stout
    )

    add_keg!(
        machine,
        cider
    )

    # --------------------------------------------------------
    # Start
    # --------------------------------------------------------

    power_on!(
        machine
    )

    # --------------------------------------------------------
    # Place glass
    # --------------------------------------------------------

    detect_glass!(
        machine,
        true;
        confidence=0.99
    )

    # --------------------------------------------------------
    # Pour
    # --------------------------------------------------------

    automatic_pour!(
        machine,
        1
    )

    # --------------------------------------------------------
    # Report
    # --------------------------------------------------------

    print_status(
        machine
    )

    print_pour_history(
        machine
    )

    print_events(
        machine
    )

    return machine
end


# ============================================================
# EXPORTS
# ============================================================

export OpenPourMachine
export Keg
export Glass
export PourProfile
export PourRecord

export power_on!
export power_off!

export emergency_stop!
export reset_emergency!

export add_keg!
export select_keg!

export detect_glass!
export replace_glass!

export automatic_pour!

export pour_fast_phase!
export settle_foam!
export manage_foam!
export top_up!

export quality_check!

export cleaning_cycle!

export inventory_report
export telemetry
export print_status
export print_pour_history
export print_events

export demo

end # module


# ============================================================
# RUN DEMO
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .OpenPour

    OpenPour.demo()

end
