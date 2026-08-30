from pathlib import Path

p = Path("/mnt/data/InfusionMixerOS.jl")

code = r'''module InfusionMixerOS

# ============================================================================
# INFUSIONMIXER.OS
# ============================================================================
# Production-style Julia reference implementation for a countertop
# beverage/infusion mixing appliance.
#
# SAFETY MODEL
# -----------
# This software is a supervisory controller. Physical heaters, motors,
# pumps, pressure systems and any hazardous-fluid interfaces must have
# independent hardware interlocks and certified safety controls.
#
# The controller deliberately:
#   * fails actuators OFF on faults
#   * validates lid/vessel/emergency-stop conditions
#   * bounds requested process parameters
#   * separates recipe intent from actuator commands
#   * provides deterministic simulation and test infrastructure
#
# This implementation accepts commercially prepared ingredients. It does
# not implement extraction, concentration, or chemical manufacture of
# controlled substances.
# ============================================================================

using Dates
using UUIDs
using Random
using Serialization
using Printf
using Statistics

# ============================================================================
# 1. ENUMERATIONS
# ============================================================================

@enum SystemState begin
    BOOT
    SELF_TEST
    OFF
    READY
    LOADING
    PRECHECK
    MIXING
    DISPENSING
    COMPLETE
    CLEANING
    CALIBRATION
    PAUSED
    FAULT
    EMERGENCY_STOP
    MAINTENANCE
end

@enum FaultSeverity begin
    INFO
    WARNING
    CRITICAL
    LATCHED
end

@enum AlarmCode begin
    ALARM_NONE
    ALARM_ESTOP
    ALARM_LID_OPEN
    ALARM_VESSEL_MISSING
    ALARM_MOTOR
    ALARM_PUMP
    ALARM_HEATER
    ALARM_OVERTEMP
    ALARM_UNDERTEMP
    ALARM_LOADCELL
    ALARM_FLOW
    ALARM_SENSOR
    ALARM_WATCHDOG
    ALARM_CONFIGURATION
    ALARM_RECIPE
    ALARM_CLEANING
    ALARM_CALIBRATION
    ALARM_SERVICE
end

@enum MotorMode begin
    MOTOR_OFF
    MOTOR_IDLE
    MOTOR_AGITATE
    MOTOR_RAMP
end

@enum PumpMode begin
    PUMP_OFF
    PUMP_PRIME
    PUMP_TRANSFER
    PUMP_DISPENSE
    PUMP_CLEAN
end

@enum HeaterMode begin
    HEATER_OFF
    HEATER_HOLD
    HEATER_COOL
end

@enum MixStage begin
    STAGE_IDLE
    STAGE_PREWET
    STAGE_LOW
    STAGE_MEDIUM
    STAGE_HIGH
    STAGE_PULSE
    STAGE_SETTLE
    STAGE_FINISHED
end

# ============================================================================
# 2. CONSTANTS
# ============================================================================

const SOFTWARE_NAME = "InfusionMixerOS"
const SOFTWARE_VERSION = v"1.0.0"
const CONTROL_PERIOD_S = 0.05
const WATCHDOG_TIMEOUT_S = 0.50

const MIN_TEMP_C = 0.0
const MAX_TEMP_C = 85.0

const MIN_MOTOR_RPM = 0.0
const MAX_MOTOR_RPM = 3000.0

const MIN_FLOW_ML_S = 0.0
const MAX_FLOW_ML_S = 100.0

const MIN_BATCH_ML = 50.0
const MAX_BATCH_ML = 5000.0

const MAX_INGREDIENTS = 32
const MAX_RECIPE_STEPS = 64

const MASS_EPSILON_G = 0.5
const VOLUME_EPSILON_ML = 2.0

# ============================================================================
# 3. LIMITS
# ============================================================================

Base.@kwdef struct SafetyLimits
    minimum_temperature_c::Float64 = MIN_TEMP_C
    maximum_temperature_c::Float64 = MAX_TEMP_C
    maximum_motor_rpm::Float64 = MAX_MOTOR_RPM
    maximum_flow_ml_s::Float64 = MAX_FLOW_ML_S
    maximum_batch_ml::Float64 = MAX_BATCH_ML
    minimum_batch_ml::Float64 = MIN_BATCH_ML
    maximum_continuous_motor_s::Float64 = 600.0
    maximum_process_s::Float64 = 1800.0
end

Base.@kwdef struct CalibrationData
    loadcell_zero_g::Float64 = 0.0
    loadcell_scale::Float64 = 1.0
    temperature_offset_c::Float64 = 0.0
    flow_scale::Float64 = 1.0
    motor_scale::Float64 = 1.0
end

# ============================================================================
# 4. INGREDIENTS
# ============================================================================

struct IngredientSpec
    id::Symbol
    name::String
    category::Symbol
    default_unit::Symbol
    density_g_ml::Float64
    commercially_prepared::Bool
end

struct IngredientLoad
    spec::IngredientSpec
    target_ml::Float64
    target_g::Float64
    actual_ml::Float64
    actual_g::Float64
    loaded::Bool
end

const INGREDIENT_LIBRARY = Dict{Symbol,IngredientSpec}(
    :water => IngredientSpec(:water, "Water", :base, :ml, 1.000, true),
    :sparkling_water => IngredientSpec(:sparkling_water, "Sparkling Water", :base, :ml, 0.998, true),
    :lemon_juice => IngredientSpec(:lemon_juice, "Lemon Juice", :acid, :ml, 1.030, true),
    :lime_juice => IngredientSpec(:lime_juice, "Lime Juice", :acid, :ml, 1.030, true),
    :simple_syrup => IngredientSpec(:simple_syrup, "Simple Syrup", :sweetener, :ml, 1.200, true),
    :cola_syrup => IngredientSpec(:cola_syrup, "Cola Syrup", :flavour, :ml, 1.100, true),
    :ginger_syrup => IngredientSpec(:ginger_syrup, "Ginger Syrup", :flavour, :ml, 1.120, true),
    :tonic_syrup => IngredientSpec(:tonic_syrup, "Tonic Syrup", :flavour, :ml, 1.090, true),
    :prepared_flavour => IngredientSpec(:prepared_flavour, "Prepared Flavour", :flavour, :ml, 1.050, true),
    :ice => IngredientSpec(:ice, "Ice", :solid, :g, 0.920, true)
)

function ingredient(id::Symbol)
    haskey(INGREDIENT_LIBRARY, id) || throw(ArgumentError("Unknown ingredient: $id"))
    return INGREDIENT_LIBRARY[id]
end

# ============================================================================
# 5. RECIPE MODEL
# ============================================================================

struct MixStep
    stage::MixStage
    duration_s::Float64
    target_rpm::Float64
    target_temp_c::Float64
    tolerance_temp_c::Float64
end

struct Recipe
    id::Symbol
    name::String
    version::Int
    target_volume_ml::Float64
    target_temperature_c::Float64
    ingredients::Vector{IngredientLoad}
    steps::Vector{MixStep}
    dispense_flow_ml_s::Float64
    cleaning_required::Bool
end

function validate(recipe::Recipe, limits::SafetyLimits)
    isempty(recipe.ingredients) && return false
    isempty(recipe.steps) && return false
    length(recipe.ingredients) > MAX_INGREDIENTS && return false
    length(recipe.steps) > MAX_RECIPE_STEPS && return false
    recipe.target_volume_ml < limits.minimum_batch_ml && return false
    recipe.target_volume_ml > limits.maximum_batch_ml && return false
    recipe.target_temperature_c < limits.minimum_temperature_c && return false
    recipe.target_temperature_c > limits.maximum_temperature_c && return false
    recipe.dispense_flow_ml_s < MIN_FLOW_ML_S && return false
    recipe.dispense_flow_ml_s > limits.maximum_flow_ml_s && return false
    for s in recipe.steps
        s.duration_s <= 0 && return false
        s.target_rpm < MIN_MOTOR_RPM && return false
        s.target_rpm > limits.maximum_motor_rpm && return false
    end
    return true
end

# ============================================================================
# 6. RECIPE FACTORY
# ============================================================================

function load_ingredients(pairs::Vector{Tuple{Symbol,Float64}})
    loads = IngredientLoad[]
    for (id, ml) in pairs
        spec = ingredient(id)
        g = ml * spec.density_g_ml
        push!(loads, IngredientLoad(spec, ml, g, 0.0, 0.0, false))
    end
    return loads
end

function lemonade_recipe(; volume_ml=750.0)
    water = volume_ml * 0.72
    lemon = volume_ml * 0.18
    syrup = volume_ml * 0.10
    Recipe(
        :lemonade,
        "Lemonade",
        1,
        volume_ml,
        18.0,
        load_ingredients([
            (:water, water),
            (:lemon_juice, lemon),
            (:simple_syrup, syrup)
        ]),
        [
            MixStep(STAGE_PREWET, 5.0, 300.0, 18.0, 4.0),
            MixStep(STAGE_LOW, 20.0, 600.0, 18.0, 4.0),
            MixStep(STAGE_MEDIUM, 15.0, 900.0, 18.0, 4.0),
            MixStep(STAGE_SETTLE, 5.0, 0.0, 18.0, 4.0)
        ],
        25.0,
        true
    )
end

function cola_recipe(; volume_ml=750.0)
    water = volume_ml * 0.82
    syrup = volume_ml * 0.15
    flavour = volume_ml * 0.03
    Recipe(
        :cola,
        "Cola",
        1,
        volume_ml,
        10.0,
        load_ingredients([
            (:water, water),
            (:cola_syrup, syrup),
            (:prepared_flavour, flavour)
        ]),
        [
            MixStep(STAGE_PREWET, 5.0, 250.0, 10.0, 4.0),
            MixStep(STAGE_LOW, 15.0, 500.0, 10.0, 4.0),
            MixStep(STAGE_MEDIUM, 10.0, 700.0, 10.0, 4.0),
            MixStep(STAGE_SETTLE, 5.0, 0.0, 10.0, 4.0)
        ],
        20.0,
        true
    )
end

function lime_soda_recipe(; volume_ml=750.0)
    water = volume_ml * 0.78
    lime = volume_ml * 0.14
    syrup = volume_ml * 0.08
    Recipe(
        :lime_soda,
        "Lime Soda",
        1,
        volume_ml,
        8.0,
        load_ingredients([
            (:sparkling_water, water),
            (:lime_juice, lime),
            (:simple_syrup, syrup)
        ]),
        [
            MixStep(STAGE_LOW, 8.0, 250.0, 8.0, 4.0),
            MixStep(STAGE_PULSE, 8.0, 450.0, 8.0, 4.0),
            MixStep(STAGE_SETTLE, 8.0, 0.0, 8.0, 4.0)
        ],
        20.0,
        true
    )
end

# ============================================================================
# 7. SENSOR MODEL
# ============================================================================

Base.@kwdef mutable struct Sensors
    lid_closed::Bool = false
    vessel_present::Bool = false
    emergency_stop::Bool = false
    motor_ok::Bool = true
    pump_ok::Bool = true
    heater_ok::Bool = true
    temperature_c::Float64 = 20.0
    loadcell_g::Float64 = 0.0
    flow_ml_s::Float64 = 0.0
    liquid_level_ml::Float64 = 0.0
    leak_detected::Bool = false
    drain_ready::Bool = true
    door_closed::Bool = true
    supply_available::Bool = true
end

function calibrated_temperature(s::Sensors, c::CalibrationData)
    return s.temperature_c + c.temperature_offset_c
end

function calibrated_mass(s::Sensors, c::CalibrationData)
    return max(0.0, (s.loadcell_g - c.loadcell_zero_g) * c.loadcell_scale)
end

# ============================================================================
# 8. ACTUATOR MODEL
# ============================================================================

Base.@kwdef mutable struct Actuators
    motor_mode::MotorMode = MOTOR_OFF
    motor_rpm::Float64 = 0.0
    pump_mode::PumpMode = PUMP_OFF
    pump_flow_ml_s::Float64 = 0.0
    heater_mode::HeaterMode = HEATER_OFF
    heater_power_pct::Float64 = 0.0
    valve_open::Bool = false
end

function all_off!(a::Actuators)
    a.motor_mode = MOTOR_OFF
    a.motor_rpm = 0.0
    a.pump_mode = PUMP_OFF
    a.pump_flow_ml_s = 0.0
    a.heater_mode = HEATER_OFF
    a.heater_power_pct = 0.0
    a.valve_open = false
    return a
end

# ============================================================================
# 9. PID CONTROLLER
# ============================================================================

mutable struct PIDController
    kp::Float64
    ki::Float64
    kd::Float64
    integral::Float64
    previous_error::Float64
    minimum::Float64
    maximum::Float64
end

function PIDController(kp, ki, kd, minimum, maximum)
    PIDController(kp, ki, kd, 0.0, 0.0, minimum, maximum)
end

function reset!(pid::PIDController)
    pid.integral = 0.0
    pid.previous_error = 0.0
end

function update!(pid::PIDController, setpoint, measurement, dt)
    error = setpoint - measurement
    pid.integral += error * dt
    derivative = dt > 0 ? (error - pid.previous_error) / dt : 0.0
    output = pid.kp * error + pid.ki * pid.integral + pid.kd * derivative
    output = clamp(output, pid.minimum, pid.maximum)
    pid.previous_error = error
    return output
end

# ============================================================================
# 10. SAFETY CONTROLLER
# ============================================================================

struct SafetyResult
    safe::Bool
    severity::FaultSeverity
    alarm::AlarmCode
    message::String
end

mutable struct SafetyController
    limits::SafetyLimits
    last_result::SafetyResult
end

function SafetyController(limits=SafetyLimits())
    SafetyController(
        limits,
        SafetyResult(true, INFO, ALARM_NONE, "SAFE")
    )
end

function evaluate!(sc::SafetyController, s::Sensors, a::Actuators, state::SystemState)
    if s.emergency_stop
        sc.last_result = SafetyResult(false, LATCHED, ALARM_ESTOP, "Emergency stop active")
        return sc.last_result
    end

    if s.leak_detected
        sc.last_result = SafetyResult(false, LATCHED, ALARM_FLOW, "Leak detected")
        return sc.last_result
    end

    if !s.motor_ok && a.motor_mode != MOTOR_OFF
        sc.last_result = SafetyResult(false, CRITICAL, ALARM_MOTOR, "Motor fault")
        return sc.last_result
    end

    if !s.pump_ok && a.pump_mode != PUMP_OFF
        sc.last_result = SafetyResult(false, CRITICAL, ALARM_PUMP, "Pump fault")
        return sc.last_result
    end

    if !s.heater_ok && a.heater_mode != HEATER_OFF
        sc.last_result = SafetyResult(false, CRITICAL, ALARM_HEATER, "Heater fault")
        return sc.last_result
    end

    if calibrated_temperature(s, CalibrationData()) > sc.limits.maximum_temperature_c
        sc.last_result = SafetyResult(false, CRITICAL, ALARM_OVERTEMP, "Temperature limit exceeded")
        return sc.last_result
    end

    if a.motor_rpm > sc.limits.maximum_motor_rpm
        sc.last_result = SafetyResult(false, CRITICAL, ALARM_MOTOR, "Motor command exceeded limit")
        return sc.last_result
    end

    if a.pump_flow_ml_s > sc.limits.maximum_flow_ml_s
        sc.last_result = SafetyResult(false, CRITICAL, ALARM_FLOW, "Pump command exceeded limit")
        return sc.last_result
    end

    if state in (MIXING, DISPENSING, CLEANING) && !s.lid_closed
        sc.last_result = SafetyResult(false, CRITICAL, ALARM_LID_OPEN, "Lid open during active process")
        return sc.last_result
    end

    if state in (MIXING, DISPENSING) && !s.vessel_present
        sc.last_result = SafetyResult(false, CRITICAL, ALARM_VESSEL_MISSING, "Vessel missing")
        return sc.last_result
    end

    sc.last_result = SafetyResult(true, INFO, ALARM_NONE, "SAFE")
    return sc.last_result
end

# ============================================================================
# 11. ALARM MODEL
# ============================================================================

struct Alarm
    id::UUID
    timestamp::DateTime
    code::AlarmCode
    severity::FaultSeverity
    message::String
    acknowledged::Bool
end

mutable struct AlarmManager
    active::Vector{Alarm}
    history::Vector{Alarm}
    maximum_history::Int
end

AlarmManager() = AlarmManager(Alarm[], Alarm[], 1000)

function raise_alarm!(am::AlarmManager, code, severity, message)
    alarm = Alarm(uuid4(), now(), code, severity, message, false)
    push!(am.active, alarm)
    push!(am.history, alarm)
    while length(am.history) > am.maximum_history
        popfirst!(am.history)
    end
    return alarm
end

function acknowledge_all!(am::AlarmManager)
    for i in eachindex(am.active)
        a = am.active[i]
        am.active[i] = Alarm(a.id, a.timestamp, a.code, a.severity, a.message, true)
    end
end

function clear_acknowledged!(am::AlarmManager)
    filter!(a -> !a.acknowledged, am.active)
end

# ============================================================================
# 12. EVENT LOGGER
# ============================================================================

struct Event
    timestamp::DateTime
    level::Symbol
    subsystem::Symbol
    message::String
end

mutable struct EventLogger
    events::Vector{Event}
    maximum_events::Int
end

EventLogger() = EventLogger(Event[], 5000)

function log!(logger::EventLogger, level, subsystem, message)
    push!(logger.events, Event(now(), level, subsystem, String(message)))
    while length(logger.events) > logger.maximum_events
        popfirst!(logger.events)
    end
end

# ============================================================================
# 13. BATCH RECORD
# ============================================================================

mutable struct BatchRecord
    id::UUID
    recipe_id::Symbol
    started_at::DateTime
    finished_at::Union{Nothing,DateTime}
    target_volume_ml::Float64
    actual_volume_ml::Float64
    status::Symbol
    energy_wh::Float64
    peak_temperature_c::Float64
    peak_rpm::Float64
    fault_count::Int
end

function BatchRecord(recipe::Recipe)
    BatchRecord(
        uuid4(),
        recipe.id,
        now(),
        nothing,
        recipe.target_volume_ml,
        0.0,
        :created,
        0.0,
        -Inf,
        0.0,
        0
    )
end

# ============================================================================
# 14. MAINTENANCE
# ============================================================================

mutable struct MaintenanceCounters
    total_batches::UInt64
    total_motor_seconds::Float64
    total_pump_seconds::Float64
    total_heater_seconds::Float64
    cleaning_cycles::UInt64
    service_due_batches::UInt64
    last_service::Union{Nothing,DateTime}
end

MaintenanceCounters() = MaintenanceCounters(0, 0.0, 0.0, 0.0, 0, 250, nothing)

function service_due(m::MaintenanceCounters)
    return m.total_batches >= m.service_due_batches
end

# ============================================================================
# 15. WATCHDOG
# ============================================================================

mutable struct Watchdog
    timeout_s::Float64
    elapsed_s::Float64
    tripped::Bool
end

Watchdog(timeout_s=WATCHDOG_TIMEOUT_S) = Watchdog(timeout_s, 0.0, false)

function kick!(w::Watchdog)
    w.elapsed_s = 0.0
    w.tripped = false
end

function tick!(w::Watchdog, dt)
    w.elapsed_s += dt
    if w.elapsed_s > w.timeout_s
        w.tripped = true
    end
    return !w.tripped
end

# ============================================================================
# 16. ENERGY MODEL
# ============================================================================

mutable struct EnergyMonitor
    motor_w::Float64
    pump_w::Float64
    heater_w::Float64
    accumulated_wh::Float64
end

EnergyMonitor() = EnergyMonitor(0.0, 0.0, 0.0, 0.0)

function update_energy!(e::EnergyMonitor, a::Actuators, dt_s::Float64)
    e.motor_w = a.motor_rpm > 0 ? 40.0 + 0.02 * a.motor_rpm : 0.0
    e.pump_w = a.pump_flow_ml_s > 0 ? 15.0 + 0.3 * a.pump_flow_ml_s : 0.0
    e.heater_w = a.heater_power_pct > 0 ? 1000.0 * a.heater_power_pct / 100.0 : 0.0
    e.accumulated_wh += (e.motor_w + e.pump_w + e.heater_w) * dt_s / 3600.0
end

# ============================================================================
# 17. HARDWARE ABSTRACTION
# ============================================================================

abstract type AbstractHardware end

mutable struct SimulatedHardware <: AbstractHardware
    sensors::Sensors
    actuators::Actuators
    ambient_temperature_c::Float64
    simulated_mass_g::Float64
    simulated_volume_ml::Float64
end

function SimulatedHardware()
    SimulatedHardware(
        Sensors(),
        Actuators(),
        20.0,
        0.0,
        0.0
    )
end

function read_sensors(h::SimulatedHardware)
    return deepcopy(h.sensors)
end

function write_actuators!(h::SimulatedHardware, a::Actuators)
    h.actuators = deepcopy(a)
end

# ============================================================================
# 18. SIMULATION
# ============================================================================

function simulate_hardware!(h::SimulatedHardware, dt_s::Float64)
    a = h.actuators

    if a.motor_mode != MOTOR_OFF
        h.sensors.motor_ok = true
    end

    if a.pump_mode != PUMP_OFF
        flow = max(0.0, a.pump_flow_ml_s)
        h.simulated_volume_ml += flow * dt_s
        h.simulated_mass_g += flow * dt_s
        h.sensors.flow_ml_s = flow
        h.sensors.liquid_level_ml = h.simulated_volume_ml
    else
        h.sensors.flow_ml_s = 0.0
    end

    target = a.heater_power_pct > 0 ? 50.0 : h.ambient_temperature_c
    thermal_rate = 0.15 * (target - h.sensors.temperature_c)
    h.sensors.temperature_c += thermal_rate * dt_s

    h.sensors.loadcell_g = h.simulated_mass_g
end

# ============================================================================
# 19. LOADING MANAGER
# ============================================================================

mutable struct LoadingManager
    active::Bool
    index::Int
    loads::Vector{IngredientLoad}
    tolerance_pct::Float64
end

LoadingManager() = LoadingManager(false, 1, IngredientLoad[], 5.0)

function begin_loading!(lm::LoadingManager, recipe::Recipe)
    lm.active = true
    lm.index = 1
    lm.loads = deepcopy(recipe.ingredients)
end

function update_loading!(lm::LoadingManager, measured_mass_g::Float64)
    !lm.active && return :idle
    lm.index > length(lm.loads) && return :complete

    load = lm.loads[lm.index]
    tolerance = max(MASS_EPSILON_G, load.target_g * lm.tolerance_pct / 100.0)

    if abs(measured_mass_g - load.target_g) <= tolerance
        lm.loads[lm.index] = IngredientLoad(
            load.spec,
            load.target_ml,
            load.target_g,
            measured_mass_g / load.spec.density_g_ml,
            measured_mass_g,
            true
        )
        lm.index += 1
        if lm.index > length(lm.loads)
            lm.active = false
            return :complete
        end
        return :next
    end

    return :loading
end

# ============================================================================
# 20. MIXING ENGINE
# ============================================================================

mutable struct MixingEngine
    step_index::Int
    elapsed_s::Float64
    stage::MixStage
    active::Bool
end

MixingEngine() = MixingEngine(1, 0.0, STAGE_IDLE, false)

function begin_mix!(me::MixingEngine)
    me.step_index = 1
    me.elapsed_s = 0.0
    me.stage = STAGE_IDLE
    me.active = true
end

function current_step(me::MixingEngine, recipe::Recipe)
    me.step_index > length(recipe.steps) && return nothing
    return recipe.steps[me.step_index]
end

# ============================================================================
# 21. DISPENSE ENGINE
# ============================================================================

mutable struct DispenseEngine
    target_ml::Float64
    delivered_ml::Float64
    active::Bool
end

DispenseEngine() = DispenseEngine(0.0, 0.0, false)

function begin_dispense!(de::DispenseEngine, target_ml)
    de.target_ml = max(0.0, target_ml)
    de.delivered_ml = 0.0
    de.active = true
end

function update_dispense!(de::DispenseEngine, flow_ml_s, dt_s)
    !de.active && return :idle
    de.delivered_ml += max(0.0, flow_ml_s) * dt_s
    if de.delivered_ml >= de.target_ml
        de.active = false
        de.delivered_ml = de.target_ml
        return :complete
    end
    return :dispensing
end

# ============================================================================
# 22. CLEANING ENGINE
# ============================================================================

mutable struct CleaningEngine
    active::Bool
    elapsed_s::Float64
    stage::Int
    total_s::Float64
end

CleaningEngine() = CleaningEngine(false, 0.0, 0, 0.0)

function begin_cleaning!(ce::CleaningEngine)
    ce.active = true
    ce.elapsed_s = 0.0
    ce.stage = 1
    ce.total_s = 120.0
end

function update_cleaning!(ce::CleaningEngine, dt_s)
    !ce.active && return :idle
    ce.elapsed_s += dt_s
    if ce.elapsed_s < 30
        ce.stage = 1
    elseif ce.elapsed_s < 80
        ce.stage = 2
    elseif ce.elapsed_s < ce.total_s
        ce.stage = 3
    else
        ce.stage = 4
        ce.active = false
        return :complete
    end
    return :cleaning
end

# ============================================================================
# 23. CALIBRATION
# ============================================================================

mutable struct CalibrationManager
    active::Bool
    phase::Symbol
    accumulated_mass::Vector{Float64}
    accumulated_temperature::Vector{Float64}
end

CalibrationManager() = CalibrationManager(false, :idle, Float64[], Float64[])

function begin_calibration!(cm::CalibrationManager)
    cm.active = true
    cm.phase = :collecting
    empty!(cm.accumulated_mass)
    empty!(cm.accumulated_temperature)
end

function collect_calibration!(cm::CalibrationManager, s::Sensors, c::CalibrationData)
    !cm.active && return false
    push!(cm.accumulated_mass, s.loadcell_g)
    push!(cm.accumulated_temperature, s.temperature_c)
    return true
end

function finish_calibration!(cm::CalibrationManager, c::CalibrationData)
    !cm.active && return c
    zero = isempty(cm.accumulated_mass) ? c.loadcell_zero_g : mean(cm.accumulated_mass)
    offset = isempty(cm.accumulated_temperature) ? c.temperature_offset_c :
        20.0 - mean(cm.accumulated_temperature)
    cm.active = false
    cm.phase = :complete
    return CalibrationData(
        zero,
        c.loadcell_scale,
        offset,
        c.flow_scale,
        c.motor_scale
    )
end

# ============================================================================
# 24. SYSTEM CONFIGURATION
# ============================================================================

Base.@kwdef mutable struct Configuration
    safety::SafetyLimits = SafetyLimits()
    calibration::CalibrationData = CalibrationData()
    control_period_s::Float64 = CONTROL_PERIOD_S
    language::Symbol = :en_GB
    unit_system::Symbol = :metric
    logging_enabled::Bool = true
    simulation_mode::Bool = true
end

# ============================================================================
# 25. MAIN CONTROLLER
# ============================================================================

mutable struct InfusionMixer

    state::SystemState
    previous_state::SystemState

    configuration::Configuration
    recipe::Union{Nothing,Recipe}

    sensors::Sensors
    actuators::Actuators

    safety::SafetyController
    alarms::AlarmManager
    logger::EventLogger
    watchdog::Watchdog
    energy::EnergyMonitor

    loading::LoadingManager
    mixing::MixingEngine
    dispensing::DispenseEngine
    cleaning::CleaningEngine
    calibration::CalibrationManager

    maintenance::MaintenanceCounters

    current_batch::Union{Nothing,BatchRecord}
    completed_batches::Vector{BatchRecord}

    process_elapsed_s::Float64
    state_elapsed_s::Float64
    total_runtime_s::Float64

    thermal_pid::PIDController

    hardware::AbstractHardware

    powered::Bool
    start_requested::Bool
    stop_requested::Bool
end

function InfusionMixer(;
    configuration=Configuration(),
    hardware=SimulatedHardware()
)
    limits = configuration.safety
    InfusionMixer(
        BOOT,
        BOOT,
        configuration,
        nothing,
        Sensors(),
        Actuators(),
        SafetyController(limits),
        AlarmManager(),
        EventLogger(),
        Watchdog(),
        EnergyMonitor(),
        LoadingManager(),
        MixingEngine(),
        DispenseEngine(),
        CleaningEngine(),
        CalibrationManager(),
        MaintenanceCounters(),
        BatchRecord[],
        0.0,
        0.0,
        0.0,
        PIDController(4.0, 0.1, 0.2, 0.0, 100.0),
        hardware,
        false,
        false,
        false
    )
end

# ============================================================================
# 26. STATE TRANSITIONS
# ============================================================================

function transition!(m::InfusionMixer, new_state::SystemState)
    if m.state != new_state
        m.previous_state = m.state
        m.state = new_state
        m.state_elapsed_s = 0.0
        log!(m.logger, :info, :state,
            "$(m.previous_state) -> $(m.state)")
    end
end

# ============================================================================
# 27. SAFETY SHUTDOWN
# ============================================================================

function safe_shutdown!(m::InfusionMixer)
    all_off!(m.actuators)
    write_actuators!(m.hardware, m.actuators)
end

function enter_fault!(m::InfusionMixer, code::AlarmCode, message::String;
                      severity=CRITICAL)
    safe_shutdown!(m)
    raise_alarm!(m.alarms, code, severity, message)
    log!(m.logger, :error, :safety, message)
    if m.current_batch !== nothing
        m.current_batch.fault_count += 1
    end
    transition!(m, FAULT)
end

# ============================================================================
# 28. SELF TEST
# ============================================================================

function self_test!(m::InfusionMixer)
    transition!(m, SELF_TEST)
    safe_shutdown!(m)

    s = read_sensors(m.hardware)

    if s.emergency_stop
        enter_fault!(m, ALARM_ESTOP, "Emergency stop active at startup";
                     severity=LATCHED)
        return false
    end

    if !s.motor_ok
        enter_fault!(m, ALARM_MOTOR, "Motor self-test failed")
        return false
    end

    if !s.pump_ok
        enter_fault!(m, ALARM_PUMP, "Pump self-test failed")
        return false
    end

    if !s.heater_ok
        enter_fault!(m, ALARM_HEATER, "Heater self-test failed")
        return false
    end

    transition!(m, OFF)
    return true
end

# ============================================================================
# 29. POWER CONTROL
# ============================================================================

function power_on!(m::InfusionMixer)
    m.powered = true
    m.start_requested = false
    m.stop_requested = false
    kick!(m.watchdog)
    return self_test!(m)
end

function power_off!(m::InfusionMixer)
    safe_shutdown!(m)
    m.powered = false
    transition!(m, OFF)
end

# ============================================================================
# 30. RECIPE SELECTION
# ============================================================================

function select_recipe!(m::InfusionMixer, recipe::Recipe)
    validate(recipe, m.configuration.safety) ||
        throw(ArgumentError("Recipe failed safety validation"))

    m.recipe = deepcopy(recipe)
    log!(m.logger, :info, :recipe,
        "Selected recipe $(recipe.id) v$(recipe.version)")
    return true
end

function select_recipe!(m::InfusionMixer, id::Symbol)
    recipe = id == :lemonade ? lemonade_recipe() :
             id == :cola ? cola_recipe() :
             id == :lime_soda ? lime_soda_recipe() :
             throw(ArgumentError("Unknown recipe"))
    return select_recipe!(m, recipe)
end

# ============================================================================
# 31. USER COMMANDS
# ============================================================================

function arm!(m::InfusionMixer)
    m.powered || return false
    m.state == OFF || m.state == READY || return false
    m.recipe === nothing && return false

    s = read_sensors(m.hardware)
    if !s.vessel_present || !s.lid_closed
        raise_alarm!(m.alarms, ALARM_VESSEL_MISSING, WARNING,
                     "Vessel and lid must be ready")
        return false
    end

    transition!(m, READY)
    return true
end

function start_batch!(m::InfusionMixer)
    m.recipe === nothing && return false
    m.state == READY || return false

    recipe = m.recipe
    m.current_batch = BatchRecord(recipe)
    m.current_batch.status = :running

    m.process_elapsed_s = 0.0
    m.maintenance.total_batches += 1

    begin_loading!(m.loading, recipe)
    transition!(m, LOADING)

    return true
end

function request_stop!(m::InfusionMixer)
    m.stop_requested = true
end

function request_start!(m::InfusionMixer)
    m.start_requested = true
end

function emergency_stop!(m::InfusionMixer)
    m.sensors.emergency_stop = true
    safe_shutdown!(m)
    transition!(m, EMERGENCY_STOP)
    raise_alarm!(m.alarms, ALARM_ESTOP, LATCHED, "Emergency stop requested")
end

function reset_emergency!(m::InfusionMixer)
    m.sensors.emergency_stop = false
    if m.state == EMERGENCY_STOP
        safe_shutdown!(m)
        transition!(m, OFF)
    end
end

# ============================================================================
# 32. LOADING
# ============================================================================

function update_loading_state!(m::InfusionMixer, dt_s)
    recipe = m.recipe
    recipe === nothing && return

    result = update_loading!(
        m.loading,
        calibrated_mass(m.sensors, m.configuration.calibration)
    )

    if result == :complete
        transition!(m, PRECHECK)
    end
end

# ============================================================================
# 33. PRECHECK
# ============================================================================

function precheck!(m::InfusionMixer)
    recipe = m.recipe
    recipe === nothing && return false

    if !validate(recipe, m.configuration.safety)
        enter_fault!(m, ALARM_RECIPE, "Recipe validation failed")
        return false
    end

    s = m.sensors

    if !s.vessel_present
        enter_fault!(m, ALARM_VESSEL_MISSING, "Vessel absent")
        return false
    end

    if !s.lid_closed
        enter_fault!(m, ALARM_LID_OPEN, "Lid is open")
        return false
    end

    if s.emergency_stop
        enter_fault!(m, ALARM_ESTOP, "Emergency stop active";
                     severity=LATCHED)
        return false
    end

    begin_mix!(m.mixing)
    transition!(m, MIXING)
    return true
end

# ============================================================================
# 34. MIXING CONTROL
# ============================================================================

function apply_mix_step!(m::InfusionMixer, step::MixStep)
    rpm = clamp(
        step.target_rpm * m.configuration.calibration.motor_scale,
        0.0,
        m.configuration.safety.maximum_motor_rpm
    )

    m.actuators.motor_rpm = rpm
    m.actuators.motor_mode = rpm > 0 ? MOTOR_AGITATE : MOTOR_IDLE

    current_temp = calibrated_temperature(
        m.sensors,
        m.configuration.calibration
    )

    heater_output = update!(
        m.thermal_pid,
        step.target_temp_c,
        current_temp,
        m.configuration.control_period_s
    )

    if current_temp < step.target_temp_c - step.tolerance_temp_c
        m.actuators.heater_mode = HEATER_HOLD
        m.actuators.heater_power_pct = heater_output
    else
        m.actuators.heater_mode = HEATER_OFF
        m.actuators.heater_power_pct = 0.0
    end
end

function update_mixing_state!(m::InfusionMixer, dt_s)
    recipe = m.recipe
    recipe === nothing && return

    step = current_step(m.mixing, recipe)

    if step === nothing
        m.mixing.stage = STAGE_FINISHED
        all_off!(m.actuators)
        begin_dispense!(m.dispensing, recipe.target_volume_ml)
        transition!(m, DISPENSING)
        return
    end

    m.mixing.stage = step.stage
    apply_mix_step!(m, step)
    m.mixing.elapsed_s += dt_s

    if m.mixing.elapsed_s >= step.duration_s
        m.mixing.step_index += 1
        m.mixing.elapsed_s = 0.0
        reset!(m.thermal_pid)
    end
end

# ============================================================================
# 35. DISPENSING CONTROL
# ============================================================================

function update_dispensing_state!(m::InfusionMixer, dt_s)
    recipe = m.recipe
    recipe === nothing && return

    m.actuators.motor_mode = MOTOR_OFF
    m.actuators.motor_rpm = 0.0
    m.actuators.pump_mode = PUMP_DISPENSE
    m.actuators.pump_flow_ml_s =
        clamp(recipe.dispense_flow_ml_s, 0.0,
              m.configuration.safety.maximum_flow_ml_s)
    m.actuators.valve_open = true

    result = update_dispense!(
        m.dispensing,
        m.sensors.flow_ml_s > 0 ?
            m.sensors.flow_ml_s :
            m.actuators.pump_flow_ml_s,
        dt_s
    )

    if result == :complete
        all_off!(m.actuators)
        if m.current_batch !== nothing
            m.current_batch.actual_volume_ml = m.dispensing.delivered_ml
            m.current_batch.finished_at = now()
            m.current_batch.status = :complete
            m.current_batch.energy_wh = m.energy.accumulated_wh
            push!(m.completed_batches, m.current_batch)
        end
        transition!(m, COMPLETE)
    end
end

# ============================================================================
# 36. CLEANING
# ============================================================================

function start_cleaning!(m::InfusionMixer)
    m.state in (READY, COMPLETE, OFF) || return false
    begin_cleaning!(m.cleaning)
    transition!(m, CLEANING)
    return true
end

function update_cleaning_state!(m::InfusionMixer, dt_s)
    result = update_cleaning!(m.cleaning, dt_s)

    m.actuators.motor_mode = MOTOR_AGITATE
    m.actuators.motor_rpm = m.cleaning.stage <= 2 ? 400.0 : 250.0
    m.actuators.pump_mode = PUMP_CLEAN
    m.actuators.pump_flow_ml_s = 15.0

    if result == :complete
        all_off!(m.actuators)
        m.maintenance.cleaning_cycles += 1
        transition!(m, READY)
    end
end

# ============================================================================
# 37. CALIBRATION
# ============================================================================

function start_calibration!(m::InfusionMixer)
    m.state in (OFF, READY) || return false
    begin_calibration!(m.calibration)
    transition!(m, CALIBRATION)
    return true
end

function update_calibration_state!(m::InfusionMixer, dt_s)
    all_off!(m.actuators)
    collect_calibration!(
        m.calibration,
        m.sensors,
        m.configuration.calibration
    )

    if m.state_elapsed_s >= 3.0
        m.configuration.calibration =
            finish_calibration!(
                m.calibration,
                m.configuration.calibration
            )
        transition!(m, READY)
    end
end

# ============================================================================
# 38. GLOBAL SAFETY
# ============================================================================

function enforce_safety!(m::InfusionMixer)
    result = evaluate!(
        m.safety,
        m.sensors,
        m.actuators,
        m.state
    )

    if !result.safe
        if m.state != EMERGENCY_STOP
            enter_fault!(
                m,
                result.alarm,
                result.message;
                severity=result.severity
            )
        end
        return false
    end

    return true
end

# ============================================================================
# 39. MAIN CONTROL TICK
# ============================================================================

function tick!(m::InfusionMixer, dt_s::Float64=m.configuration.control_period_s)

    dt = clamp(dt_s, 0.0, 1.0)

    m.total_runtime_s += dt
    m.state_elapsed_s += dt
    m.process_elapsed_s +=
        m.state in (LOADING, PRECHECK, MIXING, DISPENSING) ? dt : 0.0

    if !tick!(m.watchdog, dt)
        safe_shutdown!(m)
        enter_fault!(m, ALARM_WATCHDOG, "Control watchdog expired";
                     severity=LATCHED)
        return :watchdog_fault
    end

    # Read physical/simulated inputs first.
    m.sensors = read_sensors(m.hardware)

    if m.state in (MIXING, DISPENSING, CLEANING) &&
       m.process_elapsed_s > m.configuration.safety.maximum_process_s
        enter_fault!(m, ALARM_SERVICE, "Maximum process duration exceeded")
        return :process_timeout
    end

    # Safety is evaluated before process commands.
    if !enforce_safety!(m)
        return :fault
    end

    if m.stop_requested &&
       m.state in (LOADING, PRECHECK, MIXING, DISPENSING)
        m.stop_requested = false
        safe_shutdown!(m)
        transition!(m, READY)
        return :stopped
    end

    if m.start_requested
        m.start_requested = false
        if m.state == READY
            start_batch!(m)
        end
    end

    if m.state == LOADING
        update_loading_state!(m, dt)

    elseif m.state == PRECHECK
        precheck!(m)

    elseif m.state == MIXING
        update_mixing_state!(m, dt)

    elseif m.state == DISPENSING
        update_dispensing_state!(m, dt)

    elseif m.state == CLEANING
        update_cleaning_state!(m, dt)

    elseif m.state == CALIBRATION
        update_calibration_state!(m, dt)

    elseif m.state == COMPLETE
        all_off!(m.actuators)

    elseif m.state == FAULT
        safe_shutdown!(m)

    elseif m.state == EMERGENCY_STOP
        safe_shutdown!(m)

    else
        # OFF/READY/BOOT/SELF_TEST remain actuator-safe.
        all_off!(m.actuators)
    end

    # Safety is checked again after process logic.
    if !enforce_safety!(m)
        return :fault
    end

    write_actuators!(m.hardware, m.actuators)

    if m.configuration.simulation_mode
        simulate_hardware!(m.hardware, dt)
    end

    update_energy!(m.energy, m.actuators, dt)

    if m.actuators.motor_rpm > 0
        m.maintenance.total_motor_seconds += dt
    end
    if m.actuators.pump_flow_ml_s > 0
        m.maintenance.total_pump_seconds += dt
    end
    if m.actuators.heater_power_pct > 0
        m.maintenance.total_heater_seconds += dt
    end

    if m.current_batch !== nothing
        m.current_batch.peak_temperature_c =
            max(m.current_batch.peak_temperature_c,
                m.sensors.temperature_c)
        m.current_batch.peak_rpm =
            max(m.current_batch.peak_rpm,
                m.actuators.motor_rpm)
    end

    kick!(m.watchdog)

    return m.state
end

# ============================================================================
# 40. OPERATOR STATUS
# ============================================================================

struct SystemStatus
    software::String
    version::VersionNumber
    state::SystemState
    recipe::Union{Nothing,Symbol}
    temperature_c::Float64
    mass_g::Float64
    flow_ml_s::Float64
    motor_rpm::Float64
    pump_flow_ml_s::Float64
    heater_power_pct::Float64
    active_alarms::Int
    batch_count::UInt64
    cleaning_cycles::UInt64
    service_due::Bool
end

function status(m::InfusionMixer)
    SystemStatus(
        SOFTWARE_NAME,
        SOFTWARE_VERSION,
        m.state,
        m.recipe === nothing ? nothing : m.recipe.id,
        calibrated_temperature(m.sensors, m.configuration.calibration),
        calibrated_mass(m.sensors, m.configuration.calibration),
        m.sensors.flow_ml_s,
        m.actuators.motor_rpm,
        m.actuators.pump_flow_ml_s,
        m.actuators.heater_power_pct,
        length(m.alarms.active),
        m.maintenance.total_batches,
        m.maintenance.cleaning_cycles,
        service_due(m.maintenance)
    )
end

function print_status(m::InfusionMixer)
    s = status(m)
    println("==============================================")
    println("          INFUSIONMIXER.OS")
    println("==============================================")
    println("STATE       : ", s.state)
    println("RECIPE      : ", s.recipe)
    println("TEMPERATURE : ", @sprintf("%.2f °C", s.temperature_c))
    println("MASS        : ", @sprintf("%.1f g", s.mass_g))
    println("FLOW        : ", @sprintf("%.1f ml/s", s.flow_ml_s))
    println("MOTOR       : ", @sprintf("%.0f rpm", s.motor_rpm))
    println("PUMP        : ", @sprintf("%.1f ml/s", s.pump_flow_ml_s))
    println("HEATER      : ", @sprintf("%.1f %%", s.heater_power_pct))
    println("ALARMS      : ", s.active_alarms)
    println("BATCHES     : ", s.batch_count)
    println("CLEANING    : ", s.cleaning_cycles)
    println("SERVICE DUE : ", s.service_due)
end

# ============================================================================
# 41. PERSISTENCE
# ============================================================================

struct PersistentSnapshot
    saved_at::DateTime
    configuration::Configuration
    maintenance::MaintenanceCounters
    completed_batches::Vector{BatchRecord}
end

function snapshot(m::InfusionMixer)
    PersistentSnapshot(
        now(),
        deepcopy(m.configuration),
        deepcopy(m.maintenance),
        deepcopy(m.completed_batches)
    )
end

function save_snapshot(m::InfusionMixer, path::AbstractString)
    open(path, "w") do io
        serialize(io, snapshot(m))
    end
    log!(m.logger, :info, :storage, "Snapshot saved")
end

function load_snapshot!(m::InfusionMixer, path::AbstractString)
    snap = open(path, "r") do io
        deserialize(io)
    end
    snap isa PersistentSnapshot ||
        throw(ArgumentError("Invalid snapshot"))
    m.configuration = snap.configuration
    m.maintenance = snap.maintenance
    m.completed_batches = snap.completed_batches
    m.safety = SafetyController(m.configuration.safety)
    log!(m.logger, :info, :storage, "Snapshot loaded")
    return true
end

# ============================================================================
# 42. DIAGNOSTICS
# ============================================================================

struct DiagnosticReport
    timestamp::DateTime
    sensors_ok::Bool
    actuators_safe::Bool
    recipe_loaded::Bool
    watchdog_ok::Bool
    safety_ok::Bool
    service_due::Bool
    messages::Vector{String}
end

function diagnostics(m::InfusionMixer)
    messages = String[]
    sensors_ok = true
    actuators_safe =
        m.actuators.motor_rpm == 0 &&
        m.actuators.pump_flow_ml_s == 0 &&
        m.actuators.heater_power_pct == 0

    if !m.sensors.motor_ok
        sensors_ok = false
        push!(messages, "Motor sensor reports fault")
    end
    if !m.sensors.pump_ok
        sensors_ok = false
        push!(messages, "Pump sensor reports fault")
    end
    if !m.sensors.heater_ok
        sensors_ok = false
        push!(messages, "Heater sensor reports fault")
    end
    if !m.sensors.door_closed
        push!(messages, "Service door open")
    end
    if !m.sensors.drain_ready
        push!(messages, "Drain not ready")
    end
    if !m.sensors.supply_available
        push!(messages, "Ingredient supply unavailable")
    end

    safety_ok = m.safety.last_result.safe
    if !safety_ok
        push!(messages, m.safety.last_result.message)
    end

    DiagnosticReport(
        now(),
        sensors_ok,
        actuators_safe,
        m.recipe !== nothing,
        !m.watchdog.tripped,
        safety_ok,
        service_due(m.maintenance),
        messages
    )
end

# ============================================================================
# 43. RECIPE SCALING
# ============================================================================

function scale_recipe(recipe::Recipe, new_volume_ml::Float64)
    new_volume_ml >= MIN_BATCH_ML || throw(ArgumentError("Volume too small"))
    new_volume_ml <= MAX_BATCH_ML || throw(ArgumentError("Volume too large"))

    factor = new_volume_ml / recipe.target_volume_ml

    ingredients = IngredientLoad[]
    for i in recipe.ingredients
        target_ml = i.target_ml * factor
        target_g = i.target_g * factor
        push!(
            ingredients,
            IngredientLoad(
                i.spec,
                target_ml,
                target_g,
                0.0,
                0.0,
                false
            )
        )
    end

    Recipe(
        recipe.id,
        recipe.name,
        recipe.version + 1,
        new_volume_ml,
        recipe.target_temperature_c,
        ingredients,
        deepcopy(recipe.steps),
        recipe.dispense_flow_ml_s,
        recipe.cleaning_required
    )
end

# ============================================================================
# 44. RECIPE REGISTRY
# ============================================================================

mutable struct RecipeRegistry
    recipes::Dict{Symbol,Recipe}
end

function RecipeRegistry()
    r = RecipeRegistry(Dict{Symbol,Recipe}())
    register!(r, lemonade_recipe())
    register!(r, cola_recipe())
    register!(r, lime_soda_recipe())
    return r
end

function register!(r::RecipeRegistry, recipe::Recipe)
    validate(recipe, SafetyLimits()) ||
        throw(ArgumentError("Unsafe recipe"))
    r.recipes[recipe.id] = deepcopy(recipe)
    return true
end

function get_recipe(r::RecipeRegistry, id::Symbol)
    haskey(r.recipes, id) ||
        throw(KeyError(id))
    return deepcopy(r.recipes[id])
end

function list_recipes(r::RecipeRegistry)
    sort!(collect(keys(r.recipes)), by=String)
end

# ============================================================================
# 45. QUALITY METRICS
# ============================================================================

struct QualityMetrics
    target_volume_ml::Float64
    actual_volume_ml::Float64
    volume_error_pct::Float64
    target_temperature_c::Float64
    final_temperature_c::Float64
    temperature_error_c::Float64
    peak_rpm::Float64
    energy_wh::Float64
end

function quality_metrics(m::InfusionMixer)
    batch = m.current_batch
    batch === nothing && return nothing
    recipe = m.recipe
    recipe === nothing && return nothing

    volume_error =
        recipe.target_volume_ml > 0 ?
        100.0 * (batch.actual_volume_ml - recipe.target_volume_ml) /
        recipe.target_volume_ml : 0.0

    QualityMetrics(
        recipe.target_volume_ml,
        batch.actual_volume_ml,
        volume_error,
        recipe.target_temperature_c,
        m.sensors.temperature_c,
        m.sensors.temperature_c - recipe.target_temperature_c,
        batch.peak_rpm,
        batch.energy_wh
    )
end

# ============================================================================
# 46. OPERATOR CONSOLE
# ============================================================================

function console_help()
    println("""
Commands:
  power       - power on and self-test
  recipe NAME - select lemonade, cola, or lime_soda
  arm         - arm the appliance
  start       - start a batch
  stop        - stop current process
  clean       - run cleaning cycle
  status      - display status
  diagnostics - display diagnostics
  reset       - reset emergency/fault condition
  quit        - exit
""")
end

# ============================================================================
# 47. HIGH-LEVEL AUTOMATION
# ============================================================================

function run_batch!(
    m::InfusionMixer,
    recipe::Recipe;
    dt_s=m.configuration.control_period_s,
    max_iterations=100000
)
    select_recipe!(m, recipe)
    arm!(m) || return false
    start_batch!(m) || return false

    for _ in 1:max_iterations
        tick!(m, dt_s)

        if m.state == COMPLETE
            return true
        end

        if m.state in (FAULT, EMERGENCY_STOP)
            return false
        end
    end

    enter_fault!(m, ALARM_WATCHDOG, "Batch simulation iteration limit")
    return false
end

# ============================================================================
# 48. DEMONSTRATION
# ============================================================================

function demo(; verbose=true)
    configuration = Configuration(simulation_mode=true)
    hardware = SimulatedHardware()

    # Simulated appliance starts with vessel and lid correctly installed.
    hardware.sensors.vessel_present = true
    hardware.sensors.lid_closed = true
    hardware.sensors.motor_ok = true
    hardware.sensors.pump_ok = true
    hardware.sensors.heater_ok = true

    machine = InfusionMixer(
        configuration=configuration,
        hardware=hardware
    )

    power_on!(machine)
    select_recipe!(machine, lemonade_recipe(volume_ml=750.0))
    arm!(machine)

    # The simulated loader uses the load-cell model. In a physical appliance,
    # each ingredient would be loaded through a separately validated mechanism.
    machine.loading.active = false
    machine.loading.loads = deepcopy(machine.recipe.ingredients)

    start_batch!(machine)

    # In simulation, mark ingredient loading complete.
    machine.loading.active = false
    machine.loading.index = length(machine.loading.loads) + 1

    for _ in 1:2000
        tick!(machine)

        if machine.state == COMPLETE
            break
        end

        if machine.state == PRECHECK
            precheck!(machine)
        end
    end

    verbose && print_status(machine)
    return machine
end

# ============================================================================
# 49. TEST HELPERS
# ============================================================================

function safe_simulator()
    h = SimulatedHardware()
    h.sensors.vessel_present = true
    h.sensors.lid_closed = true
    h.sensors.motor_ok = true
    h.sensors.pump_ok = true
    h.sensors.heater_ok = true
    h
end

# ============================================================================
# 50. BUILT-IN TESTS
# ============================================================================

function test_recipe_validation()
    limits = SafetyLimits()
    @assert validate(lemonade_recipe(), limits)
    @assert validate(cola_recipe(), limits)
    @assert validate(lime_soda_recipe(), limits)
    true
end

function test_safety_lock()
    h = safe_simulator()
    h.sensors.lid_closed = false
    m = InfusionMixer(hardware=h)
    power_on!(m)
    select_recipe!(m, lemonade_recipe())
    @assert !arm!(m)
    true
end

function test_estop()
    h = safe_simulator()
    m = InfusionMixer(hardware=h)
    power_on!(m)
    emergency_stop!(m)
    @assert m.state == EMERGENCY_STOP
    @assert m.actuators.motor_rpm == 0.0
    @assert m.actuators.pump_flow_ml_s == 0.0
    true
end

function test_scaling()
    r = lemonade_recipe(volume_ml=750.0)
    s = scale_recipe(r, 1500.0)
    @assert isapprox(s.target_volume_ml, 1500.0)
    @assert isapprox(
        sum(i.target_ml for i in s.ingredients),
        1500.0
    )
    true
end

function test_pid()
    pid = PIDController(1.0, 0.1, 0.0, 0.0, 100.0)
    out = update!(pid, 50.0, 20.0, 0.1)
    @assert out >= 0.0
    @assert out <= 100.0
    true
end

function test_watchdog()
    w = Watchdog(0.1)
    kick!(w)
    @assert tick!(w, 0.05)
    @assert !tick!(w, 0.10)
    true
end

function test_loading()
    r = lemonade_recipe()
    lm = LoadingManager()
    begin_loading!(lm, r)
    target = r.ingredients[1].target_g
    result = update_loading!(lm, target)
    @assert result in (:next, :complete)
    true
end

function test_dispensing()
    d = DispenseEngine()
    begin_dispense!(d, 100.0)
    @assert update_dispense!(d, 25.0, 2.0) == :dispensing
    @assert update_dispense!(d, 25.0, 2.0) == :complete
    @assert d.delivered_ml == 100.0
    true
end

function test_persistence(path="/tmp/infusionmixer_test.bin")
    h = safe_simulator()
    m = InfusionMixer(hardware=h)
    m.maintenance.total_batches = 12
    save_snapshot!(m, path)
    n = InfusionMixer(hardware=safe_simulator())
    load_snapshot!(n, path)
    @assert n.maintenance.total_batches == 12
    rm(path; force=true)
    true
end

function test_demo()
    m = demo(verbose=false)
    @assert m.state == COMPLETE
    true
end

function run_tests()
    tests = [
        ("recipe validation", test_recipe_validation),
        ("safety lock", test_safety_lock),
        ("emergency stop", test_estop),
        ("recipe scaling", test_scaling),
        ("PID", test_pid),
        ("watchdog", test_watchdog),
        ("loading", test_loading),
        ("dispensing", test_dispensing),
        ("persistence", test_persistence),
        ("demo", test_demo)
    ]

    passed = 0

    println("InfusionMixerOS test suite")
    println("--------------------------------")

    for (name, f) in tests
        try
            f()
            println("PASS  ", name)
            passed += 1
        catch e
            println("FAIL  ", name, ": ", sprint(showerror, e))
        end
    end

    println("--------------------------------")
    println("Passed ", passed, "/", length(tests))

    return passed == length(tests)
end

# ============================================================================
# 51. EXPORTS
# ============================================================================

export
    InfusionMixer,
    Configuration,
    Sensors,
    Actuators,
    Recipe,
    MixStep,
    IngredientSpec,
    IngredientLoad,
    SafetyLimits,
    CalibrationData,
    SystemState,
    FaultSeverity,
    AlarmCode,
    MixStage,
    lemonade_recipe,
    cola_recipe,
    lime_soda_recipe,
    scale_recipe,
    RecipeRegistry,
    register!,
    get_recipe,
    list_recipes,
    power_on!,
    power_off!,
    arm!,
    start_batch!,
    request_start!,
    request_stop!,
    emergency_stop!,
    reset_emergency!,
    start_cleaning!,
    start_calibration!,
    tick!,
    status,
    print_status,
    diagnostics,
    run_batch!,
    save_snapshot!,
    load_snapshot!,
    run_tests,
    demo

end # module
'''

p.write_text(code)
print(f"Created {p} ({len(code.splitlines())} lines).")


