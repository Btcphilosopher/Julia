module ScotchDistilleryAutomation

using Statistics
using Printf
using Dates
using Random

# ============================================================
# SCOTCH DISTILLERY AUTOMATION / DIGITAL TWIN
#
# Pure Julia
#
# Process model:
#
#   BARLEY / MALT
#       ↓
#   MILLING
#       ↓
#   MASHING
#       ↓
#   WORT
#       ↓
#   FERMENTATION
#       ↓
#   WASH
#       ↓
#   WASH STILL
#       ↓
#   LOW WINES
#       ↓
#   SPIRIT STILL
#       ↓
#   NEW MAKE SPIRIT
#       ↓
#   CASK FILLING
#       ↓
#   MATURATION
#       ↓
#   BLENDING / VATTING
#       ↓
#   BOTTLING
#
# This is a process simulation / supervisory optimisation
# model. Physical plant safety systems, SIS, PLC logic,
# pressure protection and hazardous-area controls must remain
# independent safety-rated systems.
#
# Scotch Whisky is legally defined and production must comply
# with the Scotch Whisky Regulations and applicable verification
# requirements.
# ============================================================


# ============================================================
# STATES
# ============================================================

@enum ProcessState begin
    IDLE
    PREPARING
    MASHING
    FERMENTING
    DISTILLING
    MATURING
    BLENDING
    BOTTLING
    COMPLETE
    FAULT
end


@enum DistillationStage begin
    NO_STAGE
    WASH_STILL
    LOW_WINES
    SPIRIT_STILL
    COMPLETE_DISTILLATION
end


# ============================================================
# RAW MATERIALS
# ============================================================

mutable struct MaltBatch

    id::Int

    mass_kg::Float64

    moisture_percent::Float64

    extract_percent::Float64

    temperature_c::Float64

    milled::Bool
    mashed::Bool
end


# ============================================================
# MASH
# ============================================================

mutable struct Mash

    id::Int

    malt_mass_kg::Float64
    water_volume_l::Float64

    temperature_c::Float64

    target_temperature_c::Float64

    extraction_percent::Float64

    wort_volume_l::Float64
    wort_sugar_g_l::Float64

    complete::Bool
end


# ============================================================
# FERMENTATION
# ============================================================

mutable struct Fermentation

    id::Int

    wort_volume_l::Float64

    sugar_g_l::Float64

    yeast_activity::Float64

    temperature_c::Float64

    target_temperature_c::Float64

    elapsed_hours::Float64

    alcohol_percent::Float64

    wash_volume_l::Float64

    complete::Bool
end


# ============================================================
# DISTILLATION
# ============================================================

mutable struct Still

    id::Int

    capacity_l::Float64

    charge_volume_l::Float64

    temperature_c::Float64

    target_temperature_c::Float64

    heating_power_percent::Float64

    condenser_efficiency::Float64

    vapour_rate_l_h::Float64

    output_volume_l::Float64

    output_abv::Float64

    active::Bool
end


# ============================================================
# SPIRIT
# ============================================================

mutable struct SpiritBatch

    id::Int

    source_batch::Int

    volume_l::Float64

    abv::Float64

    strength_lal::Float64

    quality_score::Float64

    classification::Symbol

    cask_id::Int
end


# ============================================================
# CASK
# ============================================================

mutable struct Cask

    id::Int

    type::Symbol

    capacity_l::Float64

    fill_volume_l::Float64

    initial_abv::Float64

    current_abv::Float64

    age_years::Float64

    warehouse::Symbol

    evaporation_rate_percent_year::Float64

    quality_score::Float64

    active::Bool
end


# ============================================================
# BLEND
# ============================================================

mutable struct BlendComponent

    cask_id::Int
    volume_l::Float64
    abv::Float64
end


mutable struct Blend

    id::Int

    components::Vector{BlendComponent}

    volume_l::Float64

    abv::Float64

    target_abv::Float64

    water_added_l::Float64

    quality_score::Float64

    complete::Bool
end


# ============================================================
# DISTILLERY
# ============================================================

mutable struct Distillery

    state::ProcessState

    malt_batches::Vector{MaltBatch}
    mashes::Vector{Mash}
    fermentations::Vector{Fermentation}

    wash_still::Still
    spirit_still::Still

    spirits::Vector{SpiritBatch}

    casks::Vector{Cask}

    blends::Vector{Blend}

    elapsed_hours::Float64

    water_used_l::Float64
    energy_used_kwh::Float64

    total_spirit_l::Float64
    total_whisky_l::Float64

    faults::Vector{Symbol}

    next_batch_id::Int
    next_cask_id::Int
    next_blend_id::Int
end


# ============================================================
# DEFAULT STILL
# ============================================================

function create_still(
    id::Int,
    capacity_l::Float64
)

    return Still(

        id,

        capacity_l,

        0.0,

        20.0,

        95.0,

        0.0,

        0.95,

        0.0,

        0.0,

        0.0,

        false
    )
end


# ============================================================
# CREATE DISTILLERY
# ============================================================

function create_distillery()

    return Distillery(

        IDLE,

        MaltBatch[],
        Mash[],
        Fermentation[],

        create_still(
            1,
            5000.0
        ),

        create_still(
            2,
            4000.0
        ),

        SpiritBatch[],

        Cask[],

        Blend[],

        0.0,

        0.0,
        0.0,

        0.0,
        0.0,

        Symbol[],

        1,
        1,
        1
    )
end


# ============================================================
# MALT
# ============================================================

function add_malt!(
    d::Distillery,
    mass_kg::Float64
)

    batch =
        MaltBatch(

            d.next_batch_id,

            mass_kg,

            4.5,

            80.0,

            15.0,

            false,
            false
        )

    push!(
        d.malt_batches,
        batch
    )

    d.next_batch_id +=
        1

    return batch.id
end


# ============================================================
# MILLING
# ============================================================

function mill!(
    d::Distillery,
    batch_id::Int
)

    batch =
        findfirst(
            b -> b.id == batch_id,
            d.malt_batches
        )

    batch === nothing &&
        return false

    malt =
        d.malt_batches[batch]

    malt.milled =
        true

    return true
end


# ============================================================
# MASHING
# ============================================================

function create_mash!(
    d::Distillery,
    malt_id::Int;
    water_ratio=4.0,
    target_temperature=65.0
)

    index =
        findfirst(
            b -> b.id == malt_id,
            d.malt_batches
        )

    index === nothing &&
        return nothing

    malt =
        d.malt_batches[index]

    if !malt.milled

        mill!(
            d,
            malt_id
        )
    end

    water =
        malt.mass_kg *
        water_ratio

    mash =
        Mash(

            malt.id,

            malt.mass_kg,
            water,

            20.0,

            target_temperature,

            0.0,

            0.0,
            0.0,

            false
        )

    push!(
        d.mashes,
        mash
    )

    d.water_used_l +=
        water

    malt.mashed =
        true

    return mash.id
end


# ============================================================
# MASH UPDATE
# ============================================================

function update_mash!(
    mash::Mash,
    dt_hours::Float64
)

    if mash.complete
        return
    end

    temperature_error =
        mash.target_temperature_c -
        mash.temperature_c

    mash.temperature_c +=
        temperature_error *
        min(
            1.0,
            dt_hours * 2.0
        )

    if abs(
        mash.temperature_c -
        mash.target_temperature_c
    ) < 1.0

        mash.extraction_percent =
            min(
                100.0,
                mash.extraction_percent +
                dt_hours *
                15.0
            )
    end

    if mash.extraction_percent >=
       80.0

        mash.wort_volume_l =
            mash.water_volume_l *
            0.90

        mash.wort_sugar_g_l =
            75.0 *
            mash.extraction_percent /
            100.0

        mash.complete =
            true
    end
end


# ============================================================
# CREATE FERMENTATION
# ============================================================

function create_fermentation!(
    d::Distillery,
    mash_id::Int
)

    index =
        findfirst(
            m -> m.id == mash_id,
            d.mashes
        )

    index === nothing &&
        return nothing

    mash =
        d.mashes[index]

    !mash.complete &&
        return nothing

    fermentation =
        Fermentation(

            mash.id,

            mash.wort_volume_l,

            mash.wort_sugar_g_l,

            1.0,

            18.0,

            20.0,

            0.0,

            0.0,

            0.0,

            false
        )

    push!(
        d.fermentations,
        fermentation
    )

    return fermentation.id
end


# ============================================================
# FERMENTATION MODEL
# ============================================================

function update_fermentation!(
    f::Fermentation,
    dt_hours::Float64
)

    if f.complete
        return
    end

    # Temperature moves toward the process target.

    error =
        f.target_temperature_c -
        f.temperature_c

    f.temperature_c +=
        error *
        min(
            1.0,
            dt_hours
        )

    # Yeast activity depends on temperature
    # and gradually declines as fermentation progresses.

    temperature_factor =
        exp(
            -(
                f.temperature_c -
                f.target_temperature_c
            )^2 /
            18.0
        )

    f.yeast_activity =
        clamp(
            f.yeast_activity *
            temperature_factor,
            0.0,
            1.0
        )

    sugar_consumption =
        4.0 *
        f.yeast_activity *
        dt_hours

    f.sugar_g_l =
        max(
            0.0,
            f.sugar_g_l -
            sugar_consumption
        )

    # Simplified alcohol yield model.

    f.alcohol_percent =
        clamp(
            (
                f.wort_volume_l *
                0.00055 *
                (
                    75.0 -
                    f.sugar_g_l
                )
            ),
            0.0,
            12.0
        )

    f.elapsed_hours +=
        dt_hours

    if f.elapsed_hours >=
       48.0 ||
       f.sugar_g_l <= 8.0

        f.wash_volume_l =
            f.wort_volume_l *
            0.94

        f.complete =
            true
    end
end


# ============================================================
# STILL CHARGE
# ============================================================

function charge_still!(
    still::Still,
    volume_l::Float64
)

    if volume_l >
       still.capacity_l

        return false
    end

    if still.active

        return false
    end

    still.charge_volume_l =
        volume_l

    still.output_volume_l =
        0.0

    still.output_abv =
        0.0

    still.active =
        true

    still.heating_power_percent =
        0.0

    return true
end


# ============================================================
# STILL CONTROL
# ============================================================

function update_still!(
    still::Still,
    dt_hours::Float64
)

    if !still.active
        return
    end

    # Supervisory thermal model.
    #
    # Actual plant implementation should use independently
    # validated instrumentation and control hardware.

    heating =
        still.heating_power_percent /
        100.0

    temperature_rate =
        12.0 *
        heating

    cooling =
        1.5

    still.temperature_c +=
        (
            temperature_rate -
            cooling
        ) *
        dt_hours

    still.temperature_c =
        clamp(
            still.temperature_c,
            20.0,
            110.0
        )

    if still.temperature_c >
       78.0

        still.vapour_rate_l_h =
            80.0 *
            heating

        produced =
            still.vapour_rate_l_h *
            dt_hours *
            still.condenser_efficiency

        produced =
            min(
                produced,
                still.charge_volume_l
            )

        still.output_volume_l +=
            produced

        still.charge_volume_l -=
            produced

        still.output_abv =
            clamp(
                65.0 +
                (
                    still.temperature_c -
                    78.0
                ) *
                0.4,
                0.0,
                95.0
            )
    end

    if still.charge_volume_l <=
       50.0

        still.active =
            false

        still.heating_power_percent =
            0.0
    end
end


# ============================================================
# DISTILLATION
# ============================================================

function distil_wash!(
    d::Distillery,
    fermentation_id::Int
)

    index =
        findfirst(
            f -> f.id == fermentation_id,
            d.fermentations
        )

    index === nothing &&
        return nothing

    fermentation =
        d.fermentations[index]

    !fermentation.complete &&
        return nothing

    charge_still!(
        d.wash_still,
        fermentation.wash_volume_l
    )

    d.wash_still.heating_power_percent =
        65.0

    return true
end


# ============================================================
# SPIRIT CREATION
# ============================================================

function create_spirit!(
    d::Distillery,
    source_id::Int,
    volume_l::Float64,
    abv::Float64
)

    spirit =
        SpiritBatch(

            d.next_batch_id,

            source_id,

            volume_l,

            abv,

            volume_l *
            abv /
            100.0,

            90.0,

            :NEW_MAKE,

            0
        )

    push!(
        d.spirits,
        spirit
    )

    d.next_batch_id +=
        1

    d.total_spirit_l +=
        volume_l

    return spirit.id
end


# ============================================================
# CASK CREATION
# ============================================================

function fill_cask!(
    d::Distillery,
    spirit_id::Int,
    cask_type::Symbol;
    capacity_l=250.0
)

    index =
        findfirst(
            s -> s.id == spirit_id,
            d.spirits
        )

    index === nothing &&
        return nothing

    spirit =
        d.spirits[index]

    volume =
        min(
            capacity_l,
            spirit.volume_l
        )

    cask =
        Cask(

            d.next_cask_id,

            cask_type,

            capacity_l,

            volume,

            spirit.abv,

            spirit.abv,

            0.0,

            :WAREHOUSE_A,

            2.0,

            spirit.quality_score,

            true
        )

    push!(
        d.casks,
        cask
    )

    spirit.volume_l -=
        volume

    spirit.cask_id =
        cask.id

    d.next_cask_id +=
        1

    return cask.id
end


# ============================================================
# MATURATION
# ============================================================

function mature_cask!(
    cask::Cask,
    years::Float64
)

    if !cask.active
        return
    end

    cask.age_years +=
        years

    evaporation =
        cask.evaporation_rate_percent_year *
        years /
        100.0

    cask.fill_volume_l *=
        max(
            0.0,
            1.0 -
            evaporation
        )

    # Simplified maturation quality model.

    maturation_gain =
        min(
            10.0,
            years *
            1.2
        )

    cask.quality_score =
        clamp(
            cask.quality_score +
            maturation_gain,
            0.0,
            100.0
        )
end


# ============================================================
# MATURATION VALIDATION
# ============================================================

function is_scotch_mature(
    cask::Cask
)

    return cask.age_years >=
           3.0
end


# ============================================================
# CASK QUALITY
# ============================================================

function cask_quality(
    cask::Cask
)

    age_score =
        min(
            20.0,
            cask.age_years *
            2.0
        )

    return clamp(
        cask.quality_score +
        age_score,
        0.0,
        100.0
    )
end


# ============================================================
# BLEND
# ============================================================

function create_blend!(
    d::Distillery,
    cask_ids::Vector{Int},
    target_abv::Float64
)

    components =
        BlendComponent[]

    total_volume =
        0.0

    total_alcohol =
        0.0

    quality =
        Float64[]

    for id in cask_ids

        index =
            findfirst(
                c -> c.id == id,
                d.casks
            )

        index === nothing &&
            continue

        cask =
            d.casks[index]

        # Do not use immature casks.

        if !is_scotch_mature(cask)

            continue
        end

        volume =
            cask.fill_volume_l

        push!(
            components,
            BlendComponent(
                cask.id,
                volume,
                cask.current_abv
            )
        )

        total_volume +=
            volume

        total_alcohol +=
            volume *
            cask.current_abv /
            100.0

        push!(
            quality,
            cask_quality(cask)
        )
    end

    total_volume <=
        0.0 &&
        return nothing

    blend_abv =
        total_alcohol /
        total_volume *
        100.0

    blend =
        Blend(

            d.next_blend_id,

            components,

            total_volume,

            blend_abv,

            target_abv,

            0.0,

            mean(quality),

            false
        )

    push!(
        d.blends,
        blend
    )

    d.next_blend_id +=
        1

    return blend.id
end


# ============================================================
# DILUTION
# ============================================================

function reduce_to_bottling_strength!(
    blend::Blend,
    target_abv::Float64
)

    if target_abv <=
       0.0

        return false
    end

    if blend.abv <=
       target_abv

        return false
    end

    original_alcohol =
        blend.volume_l *
        blend.abv /
        100.0

    required_volume =
        original_alcohol /
        (
            target_abv /
            100.0
        )

    water =
        max(
            0.0,
            required_volume -
            blend.volume_l
        )

    blend.water_added_l +=
        water

    blend.volume_l =
        required_volume

    blend.abv =
        target_abv

    blend.complete =
        true

    return true
end


# ============================================================
# ENERGY MODEL
# ============================================================

function estimate_energy!(
    d::Distillery,
    dt_hours::Float64
)

    wash_energy =
        d.wash_still.heating_power_percent /
        100.0 *
        1200.0

    spirit_energy =
        d.spirit_still.heating_power_percent /
        100.0 *
        1000.0

    d.energy_used_kwh +=
        (
            wash_energy +
            spirit_energy
        ) *
        dt_hours
end


# ============================================================
# DISTILLERY CONTROL LOOP
# ============================================================

function update!(
    d::Distillery,
    dt_hours::Float64
)

    d.elapsed_hours +=
        dt_hours

    # Mash process.

    for mash in
        d.mashes

        update_mash!(
            mash,
            dt_hours
        )
    end

    # Fermentation.

    for fermentation in
        d.fermentations

        update_fermentation!(
            fermentation,
            dt_hours
        )
    end

    # Still models.

    update_still!(
        d.wash_still,
        dt_hours
    )

    update_still!(
        d.spirit_still,
        dt_hours
    )

    estimate_energy!(
        d,
        dt_hours
    )
end


# ============================================================
# PROCESS BATCH
# ============================================================

function process_batch!(
    d::Distillery,
    malt_mass_kg::Float64
)

    malt_id =
        add_malt!(
            d,
            malt_mass_kg
        )

    mash_id =
        create_mash!(
            d,
            malt_id
        )

    mash_id === nothing &&
        return false

    # Simulate mashing.

    for _ in 1:20

        update!(
            d,
            0.25
        )

        d.mashes[end].complete &&
            break
    end

    fermentation_id =
        create_fermentation!(
            d,
            mash_id
        )

    fermentation_id === nothing &&
        return false

    # Simulate fermentation.

    for _ in 1:240

        update!(
            d,
            0.25
        )

        d.fermentations[end].complete &&
            break
    end

    distil_wash!(
        d,
        fermentation_id
    )

    # Simulate wash still.

    for _ in 1:240

        update!(
            d,
            0.1
        )

        !d.wash_still.active &&
            break
    end

    spirit_volume =
        d.wash_still.output_volume_l

    spirit_abv =
        d.wash_still.output_abv

    if spirit_volume > 0

        spirit_id =
            create_spirit!(
                d,
                fermentation_id,
                spirit_volume,
                spirit_abv
            )

        fill_cask!(
            d,
            spirit_id,
            :BOURBON;
            capacity_l=200.0
        )
    end

    return true
end


# ============================================================
# WAREHOUSE SIMULATION
# ============================================================

function mature_all!(
    d::Distillery,
    years::Float64
)

    for cask in
        d.casks

        mature_cask!(
            cask,
            years
        )
    end
end


# ============================================================
# PRODUCTION REPORT
# ============================================================

function report(
    d::Distillery
)

    println()
    println(
        "=========================================================="
    )

    println(
        "             SCOTCH DISTILLERY AUTOMATION"
    )

    println(
        "=========================================================="

    )

    @printf(
        "Runtime:                 %.1f hours\n",
        d.elapsed_hours
    )

    @printf(
        "Malt batches:            %d\n",
        length(d.malt_batches)
    )

    @printf(
        "Mashes:                  %d\n",
        length(d.mashes)
    )

    @printf(
        "Fermentations:           %d\n",
        length(d.fermentations)
    )

    @printf(
        "Spirit batches:          %d\n",
        length(d.spirits)
    )

    @printf(
        "Casks:                   %d\n",
        length(d.casks)
    )

    @printf(
        "Total new make:          %.1f L\n",
        d.total_spirit_l
    )

    @printf(
        "Water used:              %.1f L\n",
        d.water_used_l
    )

    @printf(
        "Energy estimate:         %.1f kWh\n",
        d.energy_used_kwh
    )

    println()

    println(
        "CASK INVENTORY"
    )

    for cask in
        d.casks

        @printf(
            "Cask %04d | %-10s | %.1f L | %.1f%% ABV | %.1f years | Q %.1f\n",

            cask.id,

            cask.type,

            cask.fill_volume_l,

            cask.current_abv,

            cask.age_years,

            cask.quality_score
        )
    end

    println()

    println(
        "FAULTS"
    )

    if isempty(d.faults)

        println(
            "  NONE"
        )

    else

        for fault in
            unique(d.faults)

            println(
                "  ",
                fault
            )
        end
    end

    println(
        "=========================================================="
    )
end


# ============================================================
# DIGITAL TWIN DEMONSTRATION
# ============================================================

function demo()

    d =
        create_distillery()

    # Create several production batches.

    process_batch!(
        d,
        1000.0
    )

    process_batch!(
        d,
        1000.0
    )

    process_batch!(
        d,
        1200.0
    )

    # Simulate maturation.
    #
    # A real inventory system would advance casks through
    # calendar time rather than instantly aging them.

    mature_all!(
        d,
        3.0
    )

    # Create a mature blend.

    if length(d.casks) >= 2

        ids =
            [
                d.casks[1].id,
                d.casks[2].id
            ]

        blend_id =
            create_blend!(
                d,
                ids,
                40.0
            )

        if blend_id !== nothing

            blend =
                d.blends[
                    findfirst(
                        b -> b.id == blend_id,
                        d.blends
                    )
                ]

            reduce_to_bottling_strength!(
                blend,
                40.0
            )
        end
    end

    report(
        d
    )

    return d
end


end # module


# ============================================================
# RUN
# ============================================================

using .ScotchDistilleryAutomation

ScotchDistilleryAutomation.demo()
