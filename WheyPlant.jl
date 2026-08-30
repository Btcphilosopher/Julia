module WheyPlant

using Statistics
using Printf

# ============================================================
# WHEY PROCESSING DIGITAL TWIN / AUTOMATION ENGINE
#
# Pure Julia
#
# PROCESS:
#
# Cheese production
#       ↓
# Raw whey
#       ↓
# Clarification / separation
#       ↓
# Fat reduction
#       ↓
# Ultrafiltration
#       ↓
# Whey-protein retentate
#       ↓
# Diafiltration
#       ↓
# Concentration
#       ↓
# Evaporation
#       ↓
# Spray drying
#       ↓
# WPC / WPI powder
#
# Parallel streams:
#
# UF permeate → lactose / mineral recovery
# DF water    → water recovery
#
# This is a process simulator / supervisory-control model.
# Real dairy plants require validated HACCP systems,
# sanitary design, PLC/SCADA systems, instrumentation,
# CIP validation and food-safety controls.
# ============================================================


# ============================================================
# ENUMERATIONS
# ============================================================

@enum PlantState begin
    IDLE
    RECEIVING_WHEY
    CLARIFICATION
    SEPARATION
    ULTRAFILTRATION
    DIAFILTRATION
    CONCENTRATION
    EVAPORATION
    DRYING
    PACKAGING
    COMPLETE
    CIP
    FAULT
    EMERGENCY_STOP
end


@enum PumpState begin
    PUMP_OFF
    PUMP_RUNNING
    PUMP_FAULT
end


@enum MembraneState begin
    MEMBRANE_IDLE
    MEMBRANE_RUNNING
    MEMBRANE_FOULING
    MEMBRANE_CLEANING
end


# ============================================================
# WHEY STREAM
# ============================================================

mutable struct WheyStream

    volume_l::Float64

    protein_kg::Float64
    lactose_kg::Float64
    fat_kg::Float64
    minerals_kg::Float64

    water_kg::Float64

    temperature_c::Float64
    ph::Float64

    flow_l_min::Float64
end


# ============================================================
# PROCESS CONFIGURATION
# ============================================================

struct PlantConfig

    batch_volume_l::Float64

    target_temperature_c::Float64

    target_ph::Float64

    clarification_efficiency::Float64
    fat_removal_efficiency::Float64

    uf_protein_rejection::Float64
    uf_lactose_rejection::Float64
    uf_mineral_rejection::Float64

    membrane_area_m2::Float64

    base_flux_l_m2_h::Float64

    maximum_transmembrane_pressure_kpa::Float64

    target_protein_fraction::Float64

    diafiltration_water_l::Float64

    evaporation_target_solids_fraction::Float64

    drying_target_moisture_fraction::Float64

    pump_capacity_l_min::Float64

    timestep_s::Float64
end


function PlantConfig(;
    batch_volume_l=10000.0,

    target_temperature_c=10.0,
    target_ph=6.5,

    clarification_efficiency=0.98,
    fat_removal_efficiency=0.95,

    uf_protein_rejection=0.95,
    uf_lactose_rejection=0.05,
    uf_mineral_rejection=0.10,

    membrane_area_m2=100.0,

    base_flux_l_m2_h=50.0,

    maximum_transmembrane_pressure_kpa=300.0,

    target_protein_fraction=0.80,

    diafiltration_water_l=5000.0,

    evaporation_target_solids_fraction=0.45,

    drying_target_moisture_fraction=0.04,

    pump_capacity_l_min=500.0,

    timestep_s=1.0
)

    PlantConfig(

        Float64(batch_volume_l),

        Float64(target_temperature_c),
        Float64(target_ph),

        Float64(clarification_efficiency),
        Float64(fat_removal_efficiency),

        Float64(uf_protein_rejection),
        Float64(uf_lactose_rejection),
        Float64(uf_mineral_rejection),

        Float64(membrane_area_m2),

        Float64(base_flux_l_m2_h),

        Float64(maximum_transmembrane_pressure_kpa),

        Float64(target_protein_fraction),

        Float64(diafiltration_water_l),

        Float64(evaporation_target_solids_fraction),

        Float64(drying_target_moisture_fraction),

        Float64(pump_capacity_l_min),

        Float64(timestep_s)
    )
end


# ============================================================
# PUMP
# ============================================================

mutable struct Pump

    name::Symbol

    state::PumpState

    flow_l_min::Float64

    target_flow_l_min::Float64

    efficiency::Float64

    running_hours::Float64
end


# ============================================================
# MEMBRANE SYSTEM
# ============================================================

mutable struct MembraneSystem

    state::MembraneState

    pressure_kpa::Float64

    flux_l_m2_h::Float64

    fouling_index::Float64

    permeability::Float64

    processed_volume_l::Float64

    cleaning_required::Bool
end


# ============================================================
# EVAPORATOR
# ============================================================

mutable struct Evaporator

    inlet_volume_l::Float64

    outlet_volume_l::Float64

    solids_fraction_in::Float64

    solids_fraction_out::Float64

    evaporation_rate_l_h::Float64
end


# ============================================================
# DRYER
# ============================================================

mutable struct Dryer

    inlet_solids_kg::Float64

    outlet_powder_kg::Float64

    moisture_in::Float64

    moisture_out::Float64

    dryer_efficiency::Float64
end


# ============================================================
# PLANT
# ============================================================

mutable struct WheyPlantController

    config::PlantConfig

    state::PlantState

    feed::Union{Nothing,WheyStream}

    retentate::Union{Nothing,WheyStream}

    permeate::Union{Nothing,WheyStream}

    diafiltration_stream::Union{Nothing,WheyStream}

    final_product::Union{Nothing,WheyStream}

    pump_feed::Pump

    pump_uf::Pump

    membrane::MembraneSystem

    evaporator::Evaporator

    dryer::Dryer

    elapsed_s::Float64

    processed_batches::Int

    powder_produced_kg::Float64

    protein_recovered_kg::Float64

    lactose_recovered_kg::Float64

    water_recovered_l::Float64

    fault_code::Symbol

    emergency_stop::Bool
end


# ============================================================
# STREAM HELPERS
# ============================================================

function total_solids(
    stream::WheyStream
)

    return (
        stream.protein_kg +
        stream.lactose_kg +
        stream.fat_kg +
        stream.minerals_kg
    )
end


function protein_fraction(
    stream::WheyStream
)

    solids =
        total_solids(stream)

    solids <= 0 &&
        return 0.0

    return stream.protein_kg /
           solids
end


function clone_stream(
    stream::WheyStream
)

    WheyStream(

        stream.volume_l,

        stream.protein_kg,
        stream.lactose_kg,
        stream.fat_kg,
        stream.minerals_kg,

        stream.water_kg,

        stream.temperature_c,
        stream.ph,

        stream.flow_l_min
    )
end


# ============================================================
# CREATE WHEY
# ============================================================

function create_whey(
    volume_l::Float64
)

    # Representative simulation feed.
    # Actual composition must come from plant analysis.

    protein =
        0.006 * volume_l

    lactose =
        0.045 * volume_l

    fat =
        0.003 * volume_l

    minerals =
        0.006 * volume_l

    water =
        volume_l -
        protein -
        lactose -
        fat -
        minerals

    WheyStream(

        volume_l,

        protein,
        lactose,
        fat,
        minerals,

        water,

        8.0,
        6.4,

        0.0
    )
end


# ============================================================
# CREATE PLANT
# ============================================================

function create_plant(
    config::PlantConfig=PlantConfig()
)

    WheyPlantController(

        config,

        IDLE,

        nothing,
        nothing,
        nothing,
        nothing,
        nothing,

        Pump(
            :FEED,
            PUMP_OFF,
            0.0,
            0.0,
            0.80,
            0.0
        ),

        Pump(
            :UF,
            PUMP_OFF,
            0.0,
            0.0,
            0.75,
            0.0
        ),

        MembraneSystem(
            MEMBRANE_IDLE,

            0.0,

            config.base_flux_l_m2_h,

            0.0,

            1.0,

            0.0,

            false
        ),

        Evaporator(
            0.0,
            0.0,
            0.0,
            config.evaporation_target_solids_fraction,
            0.0
        ),

        Dryer(
            0.0,
            0.0,
            0.0,
            config.drying_target_moisture_fraction,
            0.85
        ),

        0.0,

        0,

        0.0,
        0.0,
        0.0,

        :NONE,

        false
    )
end


# ============================================================
# LOAD BATCH
# ============================================================

function receive_whey!(
    plant::WheyPlantController,
    whey::WheyStream
)

    plant.feed =
        clone_stream(whey)

    plant.state =
        RECEIVING_WHEY

    plant.feed.flow_l_min =
        plant.config.pump_capacity_l_min

    return plant
end


# ============================================================
# CLARIFICATION
# ============================================================

function clarify!(
    plant::WheyPlantController
)

    feed =
        plant.feed

    feed === nothing &&
        return

    efficiency =
        plant.config.clarification_efficiency

    # Remove a small suspended-solids fraction
    # represented here by an adjustment to the fat/solid stream.

    feed.fat_kg *=
        1.0 -
        0.05 * efficiency

    plant.state =
        SEPARATION
end


# ============================================================
# FAT SEPARATION
# ============================================================

function separate_fat!(
    plant::WheyPlantController
)

    feed =
        plant.feed

    feed === nothing &&
        return

    efficiency =
        plant.config.fat_removal_efficiency

    removed =
        feed.fat_kg *
        efficiency

    feed.fat_kg -=
        removed

    plant.state =
        ULTRAFILTRATION
end


# ============================================================
# MEMBRANE FLUX MODEL
# ============================================================

function calculate_flux!(
    plant::WheyPlantController
)

    membrane =
        plant.membrane

    config =
        plant.config

    # Simplified fouling model.
    membrane.permeability =
        max(
            0.30,
            1.0 -
            membrane.fouling_index
        )

    pressure_factor =
        clamp(
            membrane.pressure_kpa /
            config.maximum_transmembrane_pressure_kpa,
            0.2,
            1.0
        )

    membrane.flux_l_m2_h =
        config.base_flux_l_m2_h *
        membrane.permeability *
        pressure_factor

    return membrane.flux_l_m2_h
end


# ============================================================
# ULTRAFILTRATION
# ============================================================

function ultrafiltration!(
    plant::WheyPlantController
)

    feed =
        plant.feed

    feed === nothing &&
        return

    config =
        plant.config

    membrane =
        plant.membrane

    membrane.state =
        MEMBRANE_RUNNING

    membrane.pressure_kpa =
        200.0

    calculate_flux!(
        plant
    )

    # Determine approximate retained protein.
    protein_retained =
        feed.protein_kg *
        config.uf_protein_rejection

    protein_permeate =
        feed.protein_kg -
        protein_retained

    lactose_permeate =
        feed.lactose_kg *
        (1.0 -
         config.uf_lactose_rejection)

    mineral_permeate =
        feed.minerals_kg *
        (1.0 -
         config.uf_mineral_rejection)

    lactose_retained =
        feed.lactose_kg -
        lactose_permeate

    mineral_retained =
        feed.minerals_kg -
        mineral_permeate

    # Fat is assumed largely retained after separation.
    fat_retained =
        feed.fat_kg

    # Approximate water split.
    retentate_water =
        feed.water_kg *
        0.40

    permeate_water =
        feed.water_kg -
        retentate_water

    retentate_volume =
        retentate_water +
        protein_retained +
        lactose_retained +
        mineral_retained +
        fat_retained

    permeate_volume =
        permeate_water +
        protein_permeate +
        lactose_permeate +
        mineral_permeate

    plant.retentate =
        WheyStream(

            retentate_volume,

            protein_retained,
            lactose_retained,
            fat_retained,
            mineral_retained,

            retentate_water,

            feed.temperature_c,
            feed.ph,

            0.0
        )

    plant.permeate =
        WheyStream(

            permeate_volume,

            protein_permeate,
            lactose_permeate,
            0.0,
            mineral_permeate,

            permeate_water,

            feed.temperature_c,
            feed.ph,

            0.0
        )

    membrane.processed_volume_l +=
        feed.volume_l

    # Concentration polarization / fouling.
    membrane.fouling_index +=
        0.02

    membrane.fouling_index =
        min(
            membrane.fouling_index,
            0.70
        )

    plant.state =
        DIAFILTRATION
end


# ============================================================
# DIAFILTRATION
# ============================================================

function diafiltration!(
    plant::WheyPlantController
)

    retentate =
        plant.retentate

    retentate === nothing &&
        return

    water_added =
        plant.config.diafiltration_water_l

    # Diafiltration preferentially removes
    # lactose/mineral species while retaining protein.

    lactose_removed =
        retentate.lactose_kg *
        0.70

    minerals_removed =
        retentate.minerals_kg *
        0.50

    retentate.lactose_kg -=
        lactose_removed

    retentate.minerals_kg -=
        minerals_removed

    retentate.water_kg +=
        water_added

    retentate.volume_l +=
        water_added

    plant.diafiltration_stream =
        clone_stream(
            retentate
        )

    plant.water_recovered_l +=
        water_added * 0.10

    plant.state =
        CONCENTRATION
end


# ============================================================
# CONCENTRATION
# ============================================================

function concentrate!(
    plant::WheyPlantController
)

    retentate =
        plant.retentate

    retentate === nothing &&
        return

    target_fraction =
        plant.config.target_protein_fraction

    solids =
        total_solids(
            retentate
        )

    target_volume =
        retentate.protein_kg /
        max(
            target_fraction,
            0.01
        )

    # Concentrate water removal.
    desired_water =
        max(
            0.0,
            target_volume -
            solids
        )

    retentate.water_kg =
        desired_water

    retentate.volume_l =
        solids +
        desired_water

    plant.state =
        EVAPORATION
end


# ============================================================
# EVAPORATION
# ============================================================

function evaporate!(
    plant::WheyPlantController
)

    retentate =
        plant.retentate

    retentate === nothing &&
        return

    solids =
        total_solids(
            retentate
        )

    target =
        plant.config.evaporation_target_solids_fraction

    target_total_mass =
        solids /
        target

    target_water =
        max(
            0.0,
            target_total_mass -
            solids
        )

    evaporated =
        max(
            0.0,
            retentate.water_kg -
            target_water
        )

    retentate.water_kg =
        target_water

    retentate.volume_l =
        solids +
        target_water

    plant.evaporator =
        Evaporator(

            plant.evaporator.inlet_volume_l,

            retentate.volume_l,

            solids /
            max(
                solids +
                evaporated +
                retentate.water_kg,
                1e-9
            ),

            target,

            evaporated
        )

    plant.state =
        DRYING
end


# ============================================================
# SPRAY DRYING
# ============================================================

function dry!(
    plant::WheyPlantController
)

    retentate =
        plant.retentate

    retentate === nothing &&
        return

    solids =
        total_solids(
            retentate
        )

    moisture =
        plant.config.drying_target_moisture_fraction

    powder_mass =
        solids /
        (1.0 - moisture)

    plant.dryer =
        Dryer(

            solids,

            powder_mass,

            retentate.water_kg /
            max(
                solids +
                retentate.water_kg,
                1e-9
            ),

            moisture,

            0.85
        )

    plant.final_product =
        clone_stream(
            retentate
        )

    plant.powder_produced_kg +=
        powder_mass

    plant.protein_recovered_kg +=
        retentate.protein_kg

    plant.lactose_recovered_kg +=
        retentate.lactose_kg

    plant.state =
        PACKAGING
end


# ============================================================
# PACKAGING
# ============================================================

function package_product!(
    plant::WheyPlantController
)

    plant.state =
        COMPLETE

    plant.processed_batches +=
        1
end


# ============================================================
# MEMBRANE CLEANING
# ============================================================

function clean_membrane!(
    plant::WheyPlantController
)

    plant.membrane.state =
        MEMBRANE_CLEANING

    # Simulated restoration.
    plant.membrane.fouling_index =
        0.0

    plant.membrane.permeability =
        1.0

    plant.membrane.cleaning_required =
        false

    plant.membrane.state =
        MEMBRANE_IDLE
end


# ============================================================
# FAULT MONITOR
# ============================================================

function safety_check!(
    plant::WheyPlantController
)

    config =
        plant.config

    membrane =
        plant.membrane

    if membrane.pressure_kpa >
       config.maximum_transmembrane_pressure_kpa

        plant.state =
            FAULT

        plant.fault_code =
            :UF_PRESSURE_HIGH

        return false
    end

    if membrane.fouling_index >
       0.65

        membrane.cleaning_required =
            true

        plant.state =
            CIP

        plant.fault_code =
            :MEMBRANE_CLEANING_REQUIRED

        return false
    end

    return true
end


# ============================================================
# PROCESS STATE MACHINE
# ============================================================

function process_step!(
    plant::WheyPlantController
)

    if plant.emergency_stop

        plant.state =
            EMERGENCY_STOP

        return
    end

    if plant.state ==
       RECEIVING_WHEY

        clarify!(
            plant

        )

    elseif plant.state ==
           SEPARATION

        separate_fat!(
            plant
        )

    elseif plant.state ==
           ULTRAFILTRATION

        ultrafiltration!(
            plant
        )

    elseif plant.state ==
           DIAFILTRATION

        diafiltration!(
            plant
        )

    elseif plant.state ==
           CONCENTRATION

        concentrate!(
            plant
        )

    elseif plant.state ==
           EVAPORATION

        evaporate!(
            plant
        )

    elseif plant.state ==
           DRYING

        dry!(
            plant
        )

    elseif plant.state ==
           PACKAGING

        package_product!(
            plant
        )

    elseif plant.state ==
           CIP

        clean_membrane!(
            plant

        )

        plant.state =
            ULTRAFILTRATION

    end

    safety_check!(
        plant
    )
end


# ============================================================
# AUTOMATED BATCH
# ============================================================

function run_batch!(
    plant::WheyPlantController
)

    whey =
        create_whey(
            plant.config.batch_volume_l
        )

    receive_whey!(
        plant,
        whey
    )

    while plant.state !=
          COMPLETE &&

          plant.state !=
          FAULT &&

          plant.state !=
          EMERGENCY_STOP

        plant.elapsed_s +=
            plant.config.timestep_s

        process_step!(
            plant
        )
    end

    return plant
end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(
    plant::WheyPlantController
)

    plant.emergency_stop =
        true

    plant.state =
        EMERGENCY_STOP

    plant.fault_code =
        :EMERGENCY_STOP

    plant.pump_feed.state =
        PUMP_OFF

    plant.pump_uf.state =
        PUMP_OFF

    plant.membrane.state =
        MEMBRANE_IDLE

    return plant
end


# ============================================================
# RESET
# ============================================================

function reset!(
    plant::WheyPlantController
)

    plant.state =
        IDLE

    plant.feed =
        nothing

    plant.retentate =
        nothing

    plant.permeate =
        nothing

    plant.diafiltration_stream =
        nothing

    plant.final_product =
        nothing

    plant.elapsed_s =
        0.0

    plant.fault_code =
        :NONE

    plant.emergency_stop =
        false

    return plant
end


# ============================================================
# MASS BALANCE
# ============================================================

function mass_balance(
    plant::WheyPlantController
)

    feed =
        plant.feed

    retentate =
        plant.retentate

    permeate =
        plant.permeate

    feed === nothing &&
        return nothing

    input_protein =
        feed.protein_kg

    output_protein =
        (
            retentate === nothing ?
            0.0 :
            retentate.protein_kg
        ) +

        (
            permeate === nothing ?
            0.0 :
            permeate.protein_kg
        )

    input_lactose =
        feed.lactose_kg

    output_lactose =
        (
            retentate === nothing ?
            0.0 :
            retentate.lactose_kg
        ) +

        (
            permeate === nothing ?
            0.0 :
            permeate.lactose_kg
        )

    return (

        protein_balance_kg =
            input_protein -
            output_protein,

        lactose_balance_kg =
            input_lactose -
            output_lactose,

        protein_recovery =
            input_protein <= 0 ?
            0.0 :
            output_protein /
            input_protein
    )
end


# ============================================================
# REPORT
# ============================================================

function print_report(
    plant::WheyPlantController
)

    println()
    println(
        "=========================================================="
    )

    println(
        "             WHEY PROCESSING PLANT"
    )

    println(
        "=========================================================="
    )

    println(
        "Final state:             ",
        plant.state
    )

    @printf(
        "Processing time:         %.2f min\n",
        plant.elapsed_s / 60
    )

    @printf(
        "Batches processed:       %d\n",
        plant.processed_batches
    )

    @printf(
        "Powder produced:         %.2f kg\n",
        plant.powder_produced_kg
    )

    @printf(
        "Protein recovered:       %.2f kg\n",
        plant.protein_recovered_kg
    )

    @printf(
        "Lactose recovered:       %.2f kg\n",
        plant.lactose_recovered_kg
    )

    @printf(
        "Water recovered:         %.2f L\n",
        plant.water_recovered_l
    )

    @printf(
        "UF membrane flux:        %.2f L/m²/h\n",
        plant.membrane.flux_l_m2_h
    )

    @printf(
        "Membrane fouling:        %.3f\n",
        plant.membrane.fouling_index
    )

    if plant.retentate !== nothing

        @printf(
            "Retentate protein:       %.2f %% solids\n",
            protein_fraction(
                plant.retentate
            ) * 100
        )

        @printf(
            "Retentate volume:        %.2f L\n",
            plant.retentate.volume_l
        )
    end

    println(
        "Fault:                   ",
        plant.fault_code
    )

    println(
        "=========================================================="
    )
end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    config =
        PlantConfig(

            batch_volume_l=10_000.0,

            target_temperature_c=10.0,

            uf_protein_rejection=0.95,

            uf_lactose_rejection=0.05,

            uf_mineral_rejection=0.10,

            membrane_area_m2=100.0,

            base_flux_l_m2_h=50.0,

            target_protein_fraction=0.80,

            diafiltration_water_l=5_000.0,

            evaporation_target_solids_fraction=0.45,

            drying_target_moisture_fraction=0.04
        )

    plant =
        create_plant(
            config
        )

    println()
    println(
        "Starting whey processing batch..."
    )

    run_batch!(
        plant
    )

    print_report(
        plant
    )

    balance =
        mass_balance(
            plant
        )

    if balance !== nothing

        println()
        println(
            "MASS BALANCE"
        )

        @printf(
            "Protein balance error:  %.4f kg\n",
            balance.protein_balance_kg
        )

        @printf(
            "Lactose balance error:  %.4f kg\n",
            balance.lactose_balance_kg
        )

        @printf(
            "Protein recovery:       %.2f %%\n",
            balance.protein_recovery * 100
        )
    end

    return plant
end


end # module


# ============================================================
# RUN
# ============================================================

using .WheyPlant

WheyPlant.demo()
