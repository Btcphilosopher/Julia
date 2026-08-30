module F1Battery

using Statistics
using LinearAlgebra
using Printf
using Dates

# ============================================================
# F1 BATTERY / ENERGY STORAGE SYSTEM
# Pure Julia — no external packages
#
# Model:
#   Cell → Module → Pack → BMS → MGU-K → Vehicle → Lap
#
# SI units unless otherwise stated:
#   Voltage       V
#   Current       A
#   Power         W
#   Energy        J
#   Temperature   °C
#   Mass          kg
#   Time          s
# ============================================================


# ============================================================
# CONSTANTS
# ============================================================

const R_GAS = 8.31446261815324
const ABS_ZERO = -273.15


# ============================================================
# CELL MODEL
# ============================================================

struct CellParameters
    nominal_voltage::Float64
    max_voltage::Float64
    min_voltage::Float64

    capacity_Ah::Float64

    resistance_ohm::Float64

    mass_kg::Float64

    thermal_capacity_JK::Float64
    thermal_resistance_KW::Float64

    max_charge_current_A::Float64
    max_discharge_current_A::Float64

    max_temperature_C::Float64
    min_temperature_C::Float64
end


mutable struct CellState
    soc::Float64
    temperature_C::Float64
    voltage_V::Float64

    current_A::Float64

    energy_throughput_J::Float64

    cycles::Float64

    resistance_multiplier::Float64

    capacity_multiplier::Float64
end


function CellState(p::CellParameters;
                   soc=0.70,
                   temperature_C=30.0)

    v = p.min_voltage +
        soc * (p.max_voltage - p.min_voltage)

    CellState(
        clamp(soc, 0.0, 1.0),
        temperature_C,
        v,
        0.0,
        0.0,
        0.0,
        1.0,
        1.0
    )
end


# ------------------------------------------------------------
# Open-circuit voltage
# ------------------------------------------------------------

function ocv(p::CellParameters, soc::Float64)

    s = clamp(soc, 0.0, 1.0)

    # Simplified Li-ion style OCV curve.
    return p.min_voltage +
           (p.max_voltage - p.min_voltage) *
           (0.08s +
            0.45s^0.7 +
            0.47s)
end


# ------------------------------------------------------------
# Cell voltage under load
# ------------------------------------------------------------

function terminal_voltage(
    p::CellParameters,
    state::CellState,
    current_A::Float64
)

    R = p.resistance_ohm * state.resistance_multiplier

    return ocv(p, state.soc) - current_A * R
end


# ============================================================
# MODULE MODEL
# ============================================================

struct ModuleParameters
    cells_series::Int
    cells_parallel::Int
end


mutable struct ModuleState
    cells::Vector{CellState}
end


function ModuleState(
    cell_parameters::CellParameters,
    module_parameters::ModuleParameters;
    soc=0.70,
    temperature_C=30.0
)

    n = module_parameters.cells_series *
        module_parameters.cells_parallel

    ModuleState([
        CellState(
            cell_parameters;
            soc=soc,
            temperature_C=temperature_C
        )
        for _ in 1:n
    ])
end


# ============================================================
# BATTERY PACK
# ============================================================

struct PackParameters
    modules_series::Int

    module::ModuleParameters
    cell::CellParameters

    nominal_voltage_V::Float64
    maximum_power_W::Float64
    maximum_regen_power_W::Float64

    coolant_temperature_C::Float64

    pack_mass_kg::Float64
end


mutable struct PackState
    modules::Vector{ModuleState}

    soc::Float64
    voltage_V::Float64
    current_A::Float64
    power_W::Float64

    temperature_C::Float64

    energy_J::Float64
    energy_charged_J::Float64
    energy_discharged_J::Float64

    peak_power_W::Float64
    peak_temperature_C::Float64

    fault::Bool
    fault_message::String
end


function PackState(p::PackParameters;
                   soc=0.70,
                   temperature_C=30.0)

    modules = [
        ModuleState(
            p.cell,
            p.module;
            soc=soc,
            temperature_C=temperature_C
        )
        for _ in 1:p.modules_series
    ]

    voltage =
        p.modules_series *
        p.module.cells_series *
        ocv(p.cell, soc)

    capacity =
        p.cell.capacity_Ah *
        p.module.cells_parallel

    energy =
        voltage * capacity * 3600.0

    PackState(
        modules,
        soc,
        voltage,
        0.0,
        0.0,
        temperature_C,
        energy,
        0.0,
        0.0,
        0.0,
        temperature_C,
        false,
        ""
    )
end


# ============================================================
# PACK CHARACTERISTICS
# ============================================================

function pack_capacity_Ah(p::PackParameters)

    return p.cell.capacity_Ah *
           p.module.cells_parallel
end


function pack_energy_Wh(p::PackParameters)

    return p.nominal_voltage_V *
           pack_capacity_Ah(p)
end


function pack_energy_kWh(p::PackParameters)

    return pack_energy_Wh(p) / 1000.0
end


function pack_cell_count(p::PackParameters)

    return p.modules_series *
           p.module.cells_series *
           p.module.cells_parallel
end


function pack_soc(pack::PackState)

    return pack.soc
end


# ============================================================
# BMS
# ============================================================

struct BMSLimits

    minimum_soc::Float64
    maximum_soc::Float64

    minimum_temperature_C::Float64
    maximum_temperature_C::Float64

    maximum_current_A::Float64
    maximum_charge_current_A::Float64

    maximum_power_W::Float64
    maximum_regen_power_W::Float64
end


mutable struct BMSState

    charge_limit_A::Float64
    discharge_limit_A::Float64

    charge_power_limit_W::Float64
    discharge_power_limit_W::Float64

    balancing_active::Bool

    over_temperature::Bool
    under_temperature::Bool

    over_voltage::Bool
    under_voltage::Bool

    fault::Bool
end


function BMSState()

    BMSState(
        0.0,
        0.0,
        0.0,
        0.0,
        false,
        false,
        false,
        false,
        false,
        false
    )
end


function evaluate_bms!(
    bms::BMSState,
    pack::PackState,
    p::PackParameters,
    limits::BMSLimits
)

    bms.over_temperature =
        pack.temperature_C > limits.maximum_temperature_C

    bms.under_temperature =
        pack.temperature_C < limits.minimum_temperature_C

    bms.over_voltage =
        pack.voltage_V >
        p.modules_series *
        p.module.cells_series *
        p.cell.max_voltage

    bms.under_voltage =
        pack.voltage_V <
        p.modules_series *
        p.module.cells_series *
        p.cell.min_voltage

    bms.fault =
        bms.over_temperature ||
        bms.under_temperature ||
        bms.over_voltage ||
        bms.under_voltage

    if bms.fault

        bms.charge_limit_A = 0.0
        bms.discharge_limit_A = 0.0

        bms.charge_power_limit_W = 0.0
        bms.discharge_power_limit_W = 0.0

        return bms
    end

    # SOC-dependent limits

    charge_factor =
        clamp(
            (limits.maximum_soc - pack.soc) /
            0.10,
            0.0,
            1.0
        )

    discharge_factor =
        clamp(
            (pack.soc - limits.minimum_soc) /
            0.10,
            0.0,
            1.0
        )

    bms.charge_limit_A =
        min(
            limits.maximum_charge_current_A,
            p.cell.max_charge_current_A *
            p.module.cells_parallel
        ) * charge_factor

    bms.discharge_limit_A =
        min(
            limits.maximum_current_A,
            p.cell.max_discharge_current_A *
            p.module.cells_parallel
        ) * discharge_factor

    bms.charge_power_limit_W =
        min(
            limits.maximum_regen_power_W,
            bms.charge_limit_A *
            pack.voltage_V
        )

    bms.discharge_power_limit_W =
        min(
            limits.maximum_power_W,
            bms.discharge_limit_A *
            pack.voltage_V
        )

    # Simple balancing activation

    bms.balancing_active =
        pack.soc > 0.95

    return bms
end


# ============================================================
# THERMAL MODEL
# ============================================================

struct ThermalParameters

    ambient_temperature_C::Float64

    coolant_temperature_C::Float64

    cooling_coefficient_WK::Float64

    thermal_mass_JK::Float64

    maximum_temperature_C::Float64
end


function thermal_step!(
    pack::PackState,
    p::PackParameters,
    thermal::ThermalParameters,
    dt::Float64
)

    current = pack.current_A

    resistance =
        p.cell.resistance_ohm

    # Joule heating

    heat_generation =
        current^2 * resistance

    # Cooling to coolant

    heat_rejection =
        thermal.cooling_coefficient_WK *
        (pack.temperature_C -
         thermal.coolant_temperature_C)

    net_heat =
        heat_generation -
        heat_rejection

    ΔT =
        net_heat * dt /
        thermal.thermal_mass_JK

    pack.temperature_C += ΔT

    pack.peak_temperature_C =
        max(
            pack.peak_temperature_C,
            pack.temperature_C
        )

    return pack.temperature_C
end


# ============================================================
# PACK ELECTRICAL STEP
# ============================================================

function update_pack_state!(
    pack::PackState,
    p::PackParameters,
    requested_power_W::Float64,
    dt::Float64
)

    V = max(pack.voltage_V, 1.0)

    current =
        requested_power_W / V

    # Positive current = discharge
    # Negative current = regenerative charge

    pack.current_A = current

    pack.power_W =
        current * V

    pack.peak_power_W =
        max(
            pack.peak_power_W,
            abs(pack.power_W)
        )

    # Effective capacity

    capacity_Ah =
        pack_capacity_Ah(p)

    capacity_J =
        capacity_Ah *
        3600.0

    # Coulomb counting

    Δsoc =
        -(current * dt) /
        capacity_J

    pack.soc =
        clamp(
            pack.soc + Δsoc,
            0.0,
            1.0
        )

    # Energy accounting

    Δenergy =
        pack.power_W * dt

    pack.energy_J =
        clamp(
            pack.energy_J - Δenergy,
            0.0,
            capacity_J *
            p.nominal_voltage_V
        )

    if Δenergy > 0

        pack.energy_discharged_J +=
            Δenergy

    else

        pack.energy_charged_J +=
            -Δenergy
    end

    # Voltage update

    pack.voltage_V =
        p.modules_series *
        p.module.cells_series *
        ocv(p.cell, pack.soc)

    return pack
end


# ============================================================
# MGU-K
# ============================================================

struct MGUKParameters

    maximum_deployment_power_W::Float64

    maximum_regeneration_power_W::Float64

    efficiency::Float64

    maximum_regeneration_time_s::Float64
end


mutable struct MGUKState

    deployment_power_W::Float64

    regeneration_power_W::Float64

    harvested_energy_J::Float64

    deployed_energy_J::Float64

    deployment_time_s::Float64

    regeneration_time_s::Float64
end


function MGUKState()

    MGUKState(
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0
    )
end


# ============================================================
# VEHICLE INPUT
# ============================================================

struct VehicleInput

    speed_mps::Float64

    acceleration_mps2::Float64

    braking_request::Float64

    traction_request::Float64

    electrical_demand_W::Float64

    aerodynamic_drag_W::Float64
end


# ============================================================
# ENERGY MANAGEMENT
# ============================================================

struct EnergyStrategy

    target_soc::Float64

    minimum_deployment_soc::Float64

    maximum_deployment_soc::Float64

    braking_priority::Float64

    acceleration_priority::Float64

    conserve_energy::Bool
end


mutable struct EnergyManagerState

    requested_deployment_W::Float64

    requested_regeneration_W::Float64

    cumulative_deployment_J::Float64

    cumulative_regeneration_J::Float64

    sector_energy_J::Float64

    strategy_mode::Symbol
end


function EnergyManagerState()

    EnergyManagerState(
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        :BALANCED
    )
end


# ============================================================
# ENERGY MANAGEMENT ALGORITHM
# ============================================================

function calculate_energy_strategy!(
    ems::EnergyManagerState,
    manager::EnergyStrategy,
    pack::PackState,
    bms::BMSState,
    vehicle::VehicleInput,
    dt::Float64
)

    ems.requested_deployment_W = 0.0
    ems.requested_regeneration_W = 0.0

    # ----------------------------------------
    # REGENERATIVE BRAKING
    # ----------------------------------------

    if vehicle.braking_request > 0.0

        braking_factor =
            clamp(
                vehicle.braking_request,
                0.0,
                1.0
            )

        requested_regen =
            manager.braking_priority *
            braking_factor *
            bms.charge_power_limit_W

        requested_regen =
            min(
                requested_regen,
                bms.charge_power_limit_W
            )

        ems.requested_regeneration_W =
            requested_regen

        ems.strategy_mode = :REGENERATION

        return ems
    end

    # ----------------------------------------
    # ELECTRICAL DEPLOYMENT
    # ----------------------------------------

    if vehicle.traction_request > 0.0 &&
       pack.soc >
       manager.minimum_deployment_soc

        traction =
            clamp(
                vehicle.traction_request,
                0.0,
                1.0
            )

        available =
            bms.discharge_power_limit_W

        requested =
            available *
            traction *
            manager.acceleration_priority

        # Conserve energy near minimum SOC

        if pack.soc <
           manager.target_soc

            requested *=
                clamp(
                    (pack.soc -
                     manager.minimum_deployment_soc) /
                    (manager.target_soc -
                     manager.minimum_deployment_soc),
                    0.0,
                    1.0
                )
        end

        ems.requested_deployment_W =
            min(
                requested,
                available
            )

        ems.strategy_mode =
            manager.conserve_energy ?
            :CONSERVE :
            :DEPLOY

        return ems
    end

    ems.strategy_mode = :BALANCED

    return ems
end


# ============================================================
# BATTERY SYSTEM
# ============================================================

mutable struct BatterySystem

    pack_parameters::PackParameters

    pack::PackState

    bms_limits::BMSLimits

    bms::BMSState

    thermal::ThermalParameters

    mgu_parameters::MGUKParameters

    mgu::MGUKState

    energy_strategy::EnergyStrategy

    energy_manager::EnergyManagerState

    simulation_time_s::Float64
end


function BatterySystem(
    pack_parameters::PackParameters;
    initial_soc=0.70,
    initial_temperature_C=30.0
)

    pack =
        PackState(
            pack_parameters;
            soc=initial_soc,
            temperature_C=initial_temperature_C
        )

    limits =
        BMSLimits(
            0.05,
            0.98,
            -10.0,
            60.0,
            600.0,
            400.0,
            pack_parameters.maximum_power_W,
            pack_parameters.maximum_regen_power_W
        )

    bms =
        BMSState()

    thermal =
        ThermalParameters(
            25.0,
            pack_parameters.coolant_temperature_C,
            1200.0,
            25_000.0,
            60.0
        )

    mgu =
        MGUKParameters(
            pack_parameters.maximum_power_W,
            pack_parameters.maximum_regen_power_W,
            0.95,
            10.0
        )

    mgu_state =
        MGUKState()

    strategy =
        EnergyStrategy(
            0.70,
            0.10,
            0.95,
            1.0,
            1.0,
            false
        )

    em =
        EnergyManagerState()

    BatterySystem(
        pack_parameters,
        pack,
        limits,
        bms,
        thermal,
        mgu,
        mgu_state,
        strategy,
        em,
        0.0
    )
end


# ============================================================
# SINGLE SIMULATION STEP
# ============================================================

function step!(
    system::BatterySystem,
    vehicle::VehicleInput,
    dt::Float64
)

    system.simulation_time_s += dt

    # --------------------------------------------------------
    # BMS
    # --------------------------------------------------------

    evaluate_bms!(
        system.bms,
        system.pack,
        system.pack_parameters,
        system.bms_limits
    )

    if system.bms.fault

        system.pack.fault = true

        system.pack.fault_message =
            "BMS protection fault"

        return system
    end

    # --------------------------------------------------------
    # ENERGY MANAGEMENT
    # --------------------------------------------------------

    calculate_energy_strategy!(
        system.energy_manager,
        system.energy_strategy,
        system.pack,
        system.bms,
        vehicle,
        dt
    )

    deployment =
        system.energy_manager.requested_deployment_W

    regeneration =
        system.energy_manager.requested_regeneration_W

    # --------------------------------------------------------
    # MGU-K
    # --------------------------------------------------------

    if regeneration > 0

        # Vehicle → MGU-K → Battery

        battery_charge_power =
            regeneration *
            system.mgu_parameters.efficiency

        system.mgu.regeneration_power_W =
            regeneration

        system.mgu.harvested_energy_J +=
            regeneration * dt

        system.mgu.regeneration_time_s +=
            dt

        update_pack_state!(
            system.pack,
            system.pack_parameters,
            -battery_charge_power,
            dt
        )

        system.energy_manager.cumulative_regeneration_J +=
            battery_charge_power * dt

    elseif deployment > 0

        # Battery → MGU-K → Vehicle

        mechanical_power =
            deployment *
            system.mgu_parameters.efficiency

        system.mgu.deployment_power_W =
            deployment

        system.mgu.deployed_energy_J +=
            deployment * dt

        system.mgu.deployment_time_s +=
            dt

        update_pack_state!(
            system.pack,
            system.pack_parameters,
            deployment,
            dt
        )

        system.energy_manager.cumulative_deployment_J +=
            deployment * dt

    else

        system.mgu.deployment_power_W = 0.0
        system.mgu.regeneration_power_W = 0.0

    end

    # --------------------------------------------------------
    # THERMAL MODEL
    # --------------------------------------------------------

    thermal_step!(
        system.pack,
        system.pack_parameters,
        system.thermal,
        dt
    )

    # --------------------------------------------------------
    # PROTECTION
    # --------------------------------------------------------

    if system.pack.temperature_C >
       system.bms_limits.maximum_temperature_C

        system.pack.fault = true

        system.pack.fault_message =
            "Battery over-temperature"
    end

    if system.pack.soc <=
       system.bms_limits.minimum_soc

        system.pack.soc =
            system.bms_limits.minimum_soc
    end

    if system.pack.soc >=
       system.bms_limits.maximum_soc

        system.pack.soc =
            system.bms_limits.maximum_soc
    end

    return system
end


# ============================================================
# TELEMETRY
# ============================================================

struct TelemetrySample

    time_s::Float64

    soc::Float64

    voltage_V::Float64

    current_A::Float64

    power_W::Float64

    temperature_C::Float64

    deployment_power_W::Float64

    regeneration_power_W::Float64

    speed_mps::Float64

    braking_request::Float64

    traction_request::Float64
end


mutable struct TelemetryLog

    samples::Vector{TelemetrySample}
end


TelemetryLog() =
    TelemetryLog(TelemetrySample[])


function record!(
    log::TelemetryLog,
    system::BatterySystem,
    vehicle::VehicleInput
)

    push!(
        log.samples,
        TelemetrySample(
            system.simulation_time_s,
            system.pack.soc,
            system.pack.voltage_V,
            system.pack.current_A,
            system.pack.power_W,
            system.pack.temperature_C,
            system.mgu.deployment_power_W,
            system.mgu.regeneration_power_W,
            vehicle.speed_mps,
            vehicle.braking_request,
            vehicle.traction_request
        )
    )

    return log
end


# ============================================================
# LAP CIRCUIT
# ============================================================

struct TrackSegment

    name::String

    length_m::Float64

    speed_mps::Float64

    acceleration_mps2::Float64

    braking_request::Float64

    traction_request::Float64

    duration_s::Float64
end


struct Circuit

    name::String

    segments::Vector{TrackSegment}
end


function total_length(circuit::Circuit)

    sum(s.length_m for s in circuit.segments)
end


# ============================================================
# LAP RESULT
# ============================================================

struct LapResult

    lap_time_s::Float64

    distance_m::Float64

    initial_soc::Float64
    final_soc::Float64

    energy_harvested_J::Float64
    energy_deployed_J::Float64

    peak_power_W::Float64

    peak_temperature_C::Float64

    minimum_soc::Float64
    maximum_soc::Float64

    fault::Bool

    telemetry::TelemetryLog
end


# ============================================================
# LAP SIMULATOR
# ============================================================

function simulate_lap!(
    system::BatterySystem,
    circuit::Circuit;
    timestep_s=0.01,
    telemetry=true
)

    initial_soc =
        system.pack.soc

    log =
        TelemetryLog()

    distance = 0.0

    minimum_soc =
        system.pack.soc

    maximum_soc =
        system.pack.soc

    for segment in circuit.segments

        elapsed = 0.0

        while elapsed <
              segment.duration_s

            vehicle =
                VehicleInput(
                    segment.speed_mps,
                    segment.acceleration_mps2,
                    segment.braking_request,
                    segment.traction_request,
                    0.0,
                    0.0
                )

            step!(
                system,
                vehicle,
                timestep_s
            )

            if telemetry
                record!(
                    log,
                    system,
                    vehicle
                )
            end

            elapsed += timestep_s

            distance +=
                segment.speed_mps *
                timestep_s

            minimum_soc =
                min(
                    minimum_soc,
                    system.pack.soc
                )

            maximum_soc =
                max(
                    maximum_soc,
                    system.pack.soc
                )

            if system.pack.fault
                break
            end
        end

        if system.pack.fault
            break
        end
    end

    LapResult(
        system.simulation_time_s,
        distance,
        initial_soc,
        system.pack.soc,
        system.mgu.harvested_energy_J,
        system.mgu.deployed_energy_J,
        system.pack.peak_power_W,
        system.pack.peak_temperature_C,
        minimum_soc,
        maximum_soc,
        system.pack.fault,
        log
    )
end


# ============================================================
# PERFORMANCE ANALYTICS
# ============================================================

function average_power(log::TelemetryLog)

    isempty(log.samples) &&
        return 0.0

    mean(
        abs(s.power_W)
        for s in log.samples
    )
end


function peak_current(log::TelemetryLog)

    isempty(log.samples) &&
        return 0.0

    maximum(
        abs(s.current_A)
        for s in log.samples
    )
end


function energy_efficiency(result::LapResult)

    if result.energy_harvested_J <= 0
        return 0.0
    end

    result.energy_deployed_J /
    result.energy_harvested_J
end


# ============================================================
# CSV EXPORT
# ============================================================

function export_telemetry_csv(
    filename::String,
    log::TelemetryLog
)

    open(filename, "w") do io

        println(
            io,
            "time_s,soc,voltage_V,current_A,power_W," *
            "temperature_C,deployment_power_W," *
            "regeneration_power_W,speed_mps," *
            "braking_request,traction_request"
        )

        for s in log.samples

            println(
                io,
                join(
                    [
                        s.time_s,
                        s.soc,
                        s.voltage_V,
                        s.current_A,
                        s.power_W,
                        s.temperature_C,
                        s.deployment_power_W,
                        s.regeneration_power_W,
                        s.speed_mps,
                        s.braking_request,
                        s.traction_request
                    ],
                    ","
                )
            )
        end
    end

    return filename
end


# ============================================================
# REPORT
# ============================================================

function print_report(
    result::LapResult
)

    println()
    println("="^65)
    println(" F1 ENERGY STORAGE SYSTEM — LAP REPORT")
    println("="^65)

    @printf(
        "Lap time:                 %.3f s\n",
        result.lap_time_s
    )

    @printf(
        "Distance:                 %.1f m\n",
        result.distance_m
    )

    @printf(
        "Initial SOC:              %.2f %%\n",
        result.initial_soc * 100
    )

    @printf(
        "Final SOC:                %.2f %%\n",
        result.final_soc * 100
    )

    @printf(
        "Minimum SOC:              %.2f %%\n",
        result.minimum_soc * 100
    )

    @printf(
        "Maximum SOC:              %.2f %%\n",
        result.maximum_soc * 100
    )

    @printf(
        "Energy harvested:        %.3f MJ\n",
        result.energy_harvested_J / 1e6
    )

    @printf(
        "Energy deployed:         %.3f MJ\n",
        result.energy_deployed_J / 1e6
    )

    @printf(
        "Peak battery power:      %.1f kW\n",
        result.peak_power_W / 1000
    )

    @printf(
        "Peak battery temperature: %.2f °C\n",
        result.peak_temperature_C
    )

    @printf(
        "Energy deployment ratio: %.2f %%\n",
        energy_efficiency(result) * 100
    )

    println(
        "Fault:                   ",
        result.fault
    )

    println("="^65)
    println()
end


# ============================================================
# EXAMPLE F1-STYLE BATTERY
# ============================================================

function create_example_system()

    # Representative engineering values.
    #
    # These are NOT claimed FIA/team specifications.

    cell =
        CellParameters(
            3.7,       # nominal voltage
            4.2,       # maximum voltage
            2.8,       # minimum voltage
            10.0,      # Ah
            0.002,     # resistance
            0.045,     # kg
            950.0,     # J/K
            0.08,      # K/W
            40.0,      # charge A
            120.0,     # discharge A
            60.0,      # max temperature
            -10.0
        )

    module =
        ModuleParameters(
            12,        # series
            4          # parallel
        )

    pack =
        PackParameters(
            20,        # modules series
            module,
            cell,
            888.0,     # nominal voltage
            350_000.0, # max discharge power
            200_000.0, # max regeneration
            30.0,      # coolant temperature
            150.0      # pack mass
        )

    BatterySystem(
        pack;
        initial_soc=0.70,
        initial_temperature_C=30.0
    )
end


# ============================================================
# EXAMPLE CIRCUIT
# ============================================================

function create_example_circuit()

    segments = TrackSegment[

        TrackSegment(
            "Main Straight",
            900.0,
            80.0,
            5.0,
            0.0,
            1.0,
            11.25
        ),

        TrackSegment(
            "Heavy Braking",
            120.0,
            45.0,
            -8.0,
            1.0,
            0.0,
            2.67
        ),

        TrackSegment(
            "Technical Sector",
            1100.0,
            38.0,
            2.0,
            0.0,
            0.8,
            28.95
        ),

        TrackSegment(
            "Hairpin",
            100.0,
            20.0,
            -6.0,
            1.0,
            0.0,
            5.0
        ),

        TrackSegment(
            "Acceleration Zone",
            700.0,
            70.0,
            4.5,
            0.0,
            1.0,
            10.0
        ),

        TrackSegment(
            "Final Braking",
            150.0,
            40.0,
            -7.0,
            1.0,
            0.0,
            3.75
        )
    ]

    Circuit(
        "Example Grand Prix Circuit",
        segments
    )
end


# ============================================================
# MAIN DEMONSTRATION
# ============================================================

function demo()

    println()
    println("F1 BATTERY DIGITAL TWIN")
    println("Pure Julia")
    println()

    system =
        create_example_system()

    circuit =
        create_example_circuit()

    println(
        "Battery capacity: ",
        round(
            pack_energy_kWh(
                system.pack_parameters
            ),
            digits=2
        ),
        " kWh"
    )

    println(
        "Cell count: ",
        pack_cell_count(
            system.pack_parameters
        )
    )

    println(
        "Initial SOC: ",
        round(
            system.pack.soc * 100,
            digits=2
        ),
        "%"
    )

    result =
        simulate_lap!(
            system,
            circuit;
            timestep_s=0.01,
            telemetry=true
        )

    print_report(result)

    export_telemetry_csv(
        "f1_battery_telemetry.csv",
        result.telemetry
    )

    println(
        "Telemetry written to f1_battery_telemetry.csv"
    )

    println(
        "Peak current: ",
        round(
            peak_current(result.telemetry),
            digits=1
        ),
        " A"
    )

    println(
        "Average electrical power: ",
        round(
            average_power(result.telemetry) / 1000,
            digits=2
        ),
        " kW"
    )

    return result
end


# ============================================================
# PUBLIC API
# ============================================================

export CellParameters
export CellState

export ModuleParameters
export ModuleState

export PackParameters
export PackState

export BMSLimits
export BMSState

export ThermalParameters

export MGUKParameters
export MGUKState

export VehicleInput

export EnergyStrategy
export EnergyManagerState

export BatterySystem

export TelemetrySample
export TelemetryLog

export TrackSegment
export Circuit
export LapResult

export create_example_system
export create_example_circuit

export step!
export simulate_lap!
export record!

export evaluate_bms!
export calculate_energy_strategy!
export thermal_step!
export update_pack_state!

export export_telemetry_csv
export print_report

export pack_capacity_Ah
export pack_energy_Wh
export pack_energy_kWh
export pack_cell_count

export average_power
export peak_current
export energy_efficiency

export demo


end # module F1Battery


# ============================================================
# RUN DEMONSTRATION WHEN FILE IS EXECUTED DIRECTLY
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .F1Battery

    F1Battery.demo()

end
