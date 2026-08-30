module BreadSlicing

using LinearAlgebra
using Statistics
using Printf

# ============================================================
# AUTOMATED BREAD SLICING / MACHINE-VISION SIMULATOR
#
# Pure Julia
#
# Models:
#   - Loaf geometry
#   - Conveyor position
#   - Slice thickness control
#   - Blade position
#   - Cutting sequence
#   - Crust detection
#   - End-of-loaf detection
#   - Conveyor speed control
#   - Jam / fault detection
#   - Production telemetry
# ============================================================

export BreadConfig,
       Loaf,
       Slice,
       SlicingMachine,
       create_machine,
       add_loaf!,
       calculate_slice_positions,
       start!,
       stop!,
       emergency_stop!,
       step!,
       run!,
       print_report


# ============================================================
# CONFIGURATION
# ============================================================

struct BreadConfig
    loaf_length_mm::Float64
    loaf_width_mm::Float64
    loaf_height_mm::Float64

    slice_thickness_mm::Float64
    minimum_slice_mm::Float64
    maximum_slice_mm::Float64

    conveyor_speed_mm_s::Float64
    blade_speed_mm_s::Float64

    blade_width_mm::Float64

    cutting_clearance_mm::Float64
    end_clearance_mm::Float64

    max_cutting_force_n::Float64

    timestep_s::Float64
end


function BreadConfig(;
    loaf_length_mm=300.0,
    loaf_width_mm=110.0,
    loaf_height_mm=120.0,

    slice_thickness_mm=12.0,
    minimum_slice_mm=8.0,
    maximum_slice_mm=25.0,

    conveyor_speed_mm_s=80.0,
    blade_speed_mm_s=500.0,

    blade_width_mm=1.0,

    cutting_clearance_mm=2.0,
    end_clearance_mm=10.0,

    max_cutting_force_n=150.0,

    timestep_s=0.01
)

    @assert slice_thickness_mm >= minimum_slice_mm
    @assert slice_thickness_mm <= maximum_slice_mm

    BreadConfig(
        Float64(loaf_length_mm),
        Float64(loaf_width_mm),
        Float64(loaf_height_mm),

        Float64(slice_thickness_mm),
        Float64(minimum_slice_mm),
        Float64(maximum_slice_mm),

        Float64(conveyor_speed_mm_s),
        Float64(blade_speed_mm_s),

        Float64(blade_width_mm),

        Float64(cutting_clearance_mm),
        Float64(end_clearance_mm),

        Float64(max_cutting_force_n),

        Float64(timestep_s)
    )
end


# ============================================================
# LOAF
# ============================================================

mutable struct Loaf
    id::Int

    length_mm::Float64
    width_mm::Float64
    height_mm::Float64

    position_mm::Float64

    crust_front_mm::Float64
    crust_back_mm::Float64

    moisture::Float64

    density_kg_m3::Float64

    active::Bool
end


# ============================================================
# SLICE
# ============================================================

struct Slice
    loaf_id::Int

    index::Int

    start_mm::Float64
    end_mm::Float64

    thickness_mm::Float64

    mass_g::Float64

    is_crust::Bool
end


# ============================================================
# MACHINE STATE
# ============================================================

@enum MachineState begin
    IDLE
    LOADING
    POSITIONING
    CUTTING
    INDEXING
    COMPLETE
    FAULT
    EMERGENCY_STOP
end


# ============================================================
# MACHINE
# ============================================================

mutable struct SlicingMachine
    config::BreadConfig

    state::MachineState

    loaf::Union{Nothing,Loaf}

    slices::Vector{Slice}

    slice_positions::Vector{Float64}

    current_slice::Int

    blade_position_mm::Float64

    conveyor_position_mm::Float64

    conveyor_speed_mm_s::Float64

    cutting_force_n::Float64

    elapsed_s::Float64

    total_loaves::Int
    total_slices::Int

    fault_code::Symbol

    running::Bool
    emergency::Bool
end


# ============================================================
# CREATE MACHINE
# ============================================================

function create_machine(
    config::BreadConfig=BreadConfig()
)

    SlicingMachine(
        config,

        IDLE,

        nothing,

        Slice[],

        Float64[],

        0,

        0.0,

        0.0,

        config.conveyor_speed_mm_s,

        0.0,

        0.0,

        0,

        0,

        :NONE,

        false,

        false
    )
end


# ============================================================
# ADD LOAF
# ============================================================

function add_loaf!(
    machine::SlicingMachine;
    id::Int,
    length_mm=machine.config.loaf_length_mm,
    width_mm=machine.config.loaf_width_mm,
    height_mm=machine.config.loaf_height_mm,
    moisture=0.40,
    density_kg_m3=250.0
)

    if machine.loaf !== nothing
        throw(
            ArgumentError(
                "Machine already contains a loaf"
            )
        )
    end

    machine.loaf =
        Loaf(
            id,

            Float64(length_mm),
            Float64(width_mm),
            Float64(height_mm),

            0.0,

            0.0,
            Float64(length_mm),

            Float64(moisture),

            Float64(density_kg_m3),

            true
        )

    machine.state =
        LOADING

    return machine.loaf
end


# ============================================================
# SLICE POSITION GENERATOR
# ============================================================

function calculate_slice_positions(
    machine::SlicingMachine
)

    loaf =
        machine.loaf

    loaf === nothing &&
        throw(
            ArgumentError(
                "No loaf loaded"
            )
        )

    config =
        machine.config

    positions =
        Float64[]

    x =
        config.end_clearance_mm

    while x <
          loaf.length_mm -
          config.end_clearance_mm

        push!(
            positions,
            x
        )

        x +=
            config.slice_thickness_mm
    end

    machine.slice_positions =
        positions

    return positions
end


# ============================================================
# ESTIMATE SLICE MASS
# ============================================================

function estimate_slice_mass(
    loaf::Loaf,
    thickness_mm::Float64
)

    volume_mm3 =
        thickness_mm *
        loaf.width_mm *
        loaf.height_mm

    volume_m3 =
        volume_mm3 /
        1e9

    mass_kg =
        volume_m3 *
        loaf.density_kg_m3

    return mass_kg * 1000
end


# ============================================================
# CRUST DETECTION
# ============================================================

function is_crust_slice(
    loaf::Loaf,
    start_mm::Float64,
    end_mm::Float64
)

    return start_mm <=
           loaf.crust_front_mm + 5.0 ||

           end_mm >=
           loaf.crust_back_mm - 5.0
end


# ============================================================
# START
# ============================================================

function start!(
    machine::SlicingMachine
)

    machine.loaf === nothing &&
        throw(
            ArgumentError(
                "No loaf loaded"
            )
        )

    machine.emergency = false
    machine.running = true
    machine.state = POSITIONING

    calculate_slice_positions(
        machine
    )

    machine.current_slice = 1

    return machine
end


# ============================================================
# STOP
# ============================================================

function stop!(
    machine::SlicingMachine
)

    machine.running =
        false

    machine.state =
        IDLE

    machine.conveyor_speed_mm_s =
        0.0

    return machine
end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(
    machine::SlicingMachine
)

    machine.emergency =
        true

    machine.running =
        false

    machine.state =
        EMERGENCY_STOP

    machine.conveyor_speed_mm_s =
        0.0

    machine.cutting_force_n =
        0.0

    machine.fault_code =
        :EMERGENCY_STOP

    return machine
end


# ============================================================
# CUTTING FORCE MODEL
# ============================================================

function calculate_cutting_force(
    loaf::Loaf,
    blade_speed_mm_s::Float64
)

    base_force =
        loaf.width_mm *
        loaf.height_mm *
        0.003

    speed_factor =
        1.0 +
        100.0 /
        max(blade_speed_mm_s, 1.0)

    moisture_factor =
        1.0 +
        0.5 *
        (1.0 - loaf.moisture)

    return (
        base_force *
        speed_factor *
        moisture_factor
    )
end


# ============================================================
# PERFORM CUT
# ============================================================

function perform_cut!(
    machine::SlicingMachine
)

    loaf =
        machine.loaf

    loaf === nothing &&
        return false

    index =
        machine.current_slice

    if index >
       length(machine.slice_positions)

        machine.state =
            COMPLETE

        return false
    end

    config =
        machine.config

    position =
        machine.slice_positions[index]

    previous =
        index == 1 ?
        config.end_clearance_mm :
        machine.slice_positions[index - 1]

    thickness =
        position -
        previous

    if thickness <
       config.minimum_slice_mm

        machine.state =
            FAULT

        machine.fault_code =
            :SLICE_TOO_THIN

        return false
    end

    if thickness >
       config.maximum_slice_mm

        machine.state =
            FAULT

        machine.fault_code =
            :SLICE_TOO_THICK

        return false
    end

    force =
        calculate_cutting_force(
            loaf,
            config.blade_speed_mm_s
        )

    machine.cutting_force_n =
        force

    if force >
       config.max_cutting_force_n

        machine.state =
            FAULT

        machine.fault_code =
            :EXCESSIVE_CUTTING_FORCE

        return false
    end

    mass =
        estimate_slice_mass(
            loaf,
            thickness
        )

    crust =
        is_crust_slice(
            loaf,
            previous,
            position
        )

    push!(
        machine.slices,

        Slice(
            loaf.id,

            index,

            previous,
            position,

            thickness,

            mass,

            crust
        )
    )

    machine.total_slices +=
        1

    machine.current_slice +=
        1

    return true
end


# ============================================================
# MACHINE STATE UPDATE
# ============================================================

function step!(
    machine::SlicingMachine
)

    config =
        machine.config

    dt =
        config.timestep_s

    machine.elapsed_s +=
        dt

    if machine.emergency

        machine.state =
            EMERGENCY_STOP

        return
    end

    # --------------------------------------------------------
    # LOADING
    # --------------------------------------------------------

    if machine.state ==
       LOADING

        machine.state =
            POSITIONING

        return
    end

    # --------------------------------------------------------
    # POSITIONING
    # --------------------------------------------------------

    if machine.state ==
       POSITIONING

        machine.conveyor_speed_mm_s =
            config.conveyor_speed_mm_s

        machine.conveyor_position_mm +=
            machine.conveyor_speed_mm_s *
            dt

        if machine.conveyor_position_mm >=
           config.end_clearance_mm

            machine.state =
                CUTTING
        end

        return
    end

    # --------------------------------------------------------
    # CUTTING
    # --------------------------------------------------------

    if machine.state ==
       CUTTING

        success =
            perform_cut!(
                machine
            )

        if !success

            if machine.state ==
               COMPLETE

                return
            end

            return
        end

        machine.state =
            INDEXING

        return
    end

    # --------------------------------------------------------
    # INDEXING
    # --------------------------------------------------------

    if machine.state ==
       INDEXING

        machine.conveyor_position_mm +=
            config.slice_thickness_mm

        if machine.current_slice >
           length(
               machine.slice_positions
           )

            machine.state =
                COMPLETE
        else

            machine.state =
                CUTTING
        end

        return
    end

    # --------------------------------------------------------
    # COMPLETE
    # --------------------------------------------------------

    if machine.state ==
       COMPLETE

        machine.conveyor_speed_mm_s =
            0.0

        if machine.loaf !== nothing

            machine.loaf.active =
                false
        end

        machine.total_loaves +=
            1

        machine.running =
            false

        return
    end
end


# ============================================================
# RUN MACHINE
# ============================================================

function run!(
    machine::SlicingMachine;
    max_time_s=60.0
)

    start!(
        machine
    )

    while machine.elapsed_s <
          max_time_s

        step!(
            machine
        )

        if machine.state ==
           COMPLETE ||
           machine.state ==
           FAULT ||
           machine.state ==
           EMERGENCY_STOP

            break
        end
    end

    return machine
end


# ============================================================
# QUALITY STATISTICS
# ============================================================

function slice_statistics(
    machine::SlicingMachine
)

    isempty(machine.slices) &&
        return (
            count=0,
            mean_mm=0.0,
            std_mm=0.0,
            minimum_mm=0.0,
            maximum_mm=0.0,
            crust_count=0
        )

    thicknesses =
        [
            s.thickness_mm
            for s in machine.slices
        ]

    return (
        count=length(thicknesses),

        mean_mm=mean(
            thicknesses
        ),

        std_mm=std(
            thicknesses
        ),

        minimum_mm=minimum(
            thicknesses
        ),

        maximum_mm=maximum(
            thicknesses
        ),

        crust_count=count(
            s.is_crust
            for s in machine.slices
        )
    )
end


# ============================================================
# REPORT
# ============================================================

function print_report(
    machine::SlicingMachine
)

    stats =
        slice_statistics(
            machine
        )

    println()
    println(
        "======================================================"
    )

    println(
        "             AUTOMATED BREAD SLICER"
    )

    println(
        "======================================================"
    )

    @printf(
        "Machine state:          %s\n",
        machine.state
    )

    @printf(
        "Processing time:        %.2f s\n",
        machine.elapsed_s
    )

    @printf(
        "Slices produced:       %d\n",
        stats.count
    )

    @printf(
        "Mean slice thickness:   %.2f mm\n",
        stats.mean_mm
    )

    @printf(
        "Thickness deviation:    %.3f mm\n",
        stats.std_mm
    )

    @printf(
        "Minimum thickness:      %.2f mm\n",
        stats.minimum_mm
    )

    @printf(
        "Maximum thickness:      %.2f mm\n",
        stats.maximum_mm
    )

    @printf(
        "Crust slices:            %d\n",
        stats.crust_count
    )

    @printf(
        "Maximum cutting force:   %.2f N\n",
        machine.cutting_force_n
    )

    println(
        "Fault:                  ",
        machine.fault_code
    )

    println(
        "======================================================"
    )
end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    config =
        BreadConfig(
            loaf_length_mm=300.0,
            loaf_width_mm=110.0,
            loaf_height_mm=120.0,

            slice_thickness_mm=12.0,

            conveyor_speed_mm_s=80.0,
            blade_speed_mm_s=500.0
        )

    machine =
        create_machine(
            config
        )

    add_loaf!(
        machine;
        id=1001,
        length_mm=300.0,
        width_mm=110.0,
        height_mm=120.0,
        moisture=0.40,
        density_kg_m3=250.0
    )

    run!(
        machine
    )

    print_report(
        machine
    )

    println()
    println(
        "Slice data:"
    )

    for slice in machine.slices

        @printf(
            "Slice %3d | %.2f mm | %.2f g | %s\n",
            slice.index,
            slice.thickness_mm,
            slice.mass_g,
            slice.is_crust ? "CRUST" : "BREAD"
        )
    end

    return machine
end


end # module


# ============================================================
# RUN
# ============================================================

using .BreadSlicing

BreadSlicing.demo()
