IndustrialSlicing



module IndustrialSlicing

using Statistics
using Printf

# ============================================================
# INDUSTRIAL SLICING CONTROL ENGINE
#
# Pure Julia
#
# Designed as a simulation / optimisation layer for:
#
#   - Meat
#   - Cheese
#   - Bread
#   - Fish
#   - Bakery products
#   - Other portionable products
#
# Core objectives:
#
#   1. Maintain slice thickness
#   2. Maintain target portion weight
#   3. Maximise usable yield
#   4. Maintain continuous product flow
#   5. Synchronise conveyor and blade
#   6. Detect abnormal product geometry
#   7. Minimise trim / kerf waste
#   8. Detect machine faults
#
# This is a control/simulation model, NOT a safety-rated
# machine controller.
# ============================================================


# ============================================================
# ENUMS
# ============================================================

@enum MachineState begin
    STOPPED
    STARTING
    RUNNING
    PAUSED
    FAULT
    EMERGENCY_STOP
end


@enum ProductState begin
    WAITING
    SCANNING
    TRACKING
    SLICING
    COMPLETE
    REJECTED
end


@enum ControlMode begin
    FIXED_THICKNESS
    TARGET_WEIGHT
    ADAPTIVE_YIELD
end


# ============================================================
# PRODUCT
# ============================================================

mutable struct Product

    id::Int

    state::ProductState

    length_mm::Float64
    width_mm::Float64
    height_mm::Float64

    density_g_cm3::Float64

    position_mm::Float64
    velocity_mm_s::Float64

    orientation_deg::Float64

    remaining_length_mm::Float64

    target_weight_g::Float64

    slices_produced::Int

    total_weight_produced_g::Float64
    waste_weight_g::Float64

    scan_complete::Bool
    tracking_locked::Bool
end


# ============================================================
# SLICE
# ============================================================

struct Slice

    id::Int
    product_id::Int

    thickness_mm::Float64

    width_mm::Float64
    height_mm::Float64

    estimated_weight_g::Float64

    target_weight_g::Float64

    weight_error_percent::Float64

    position_mm::Float64
end


# ============================================================
# VISION MEASUREMENT
# ============================================================

struct VisionMeasurement

    length_mm::Float64
    width_mm::Float64
    height_mm::Float64

    orientation_deg::Float64

    confidence::Float64

    valid::Bool
end


# ============================================================
# BLADE
# ============================================================

mutable struct Blade

    radius_mm::Float64

    rpm::Float64

    maximum_rpm::Float64

    cutting_angle_deg::Float64

    kerf_mm::Float64

    sharpness::Float64

    cuts_completed::Int

    maintenance_required::Bool
end


# ============================================================
# CONVEYOR
# ============================================================

mutable struct Conveyor

    position_mm::Float64

    velocity_mm_s::Float64

    target_velocity_mm_s::Float64

    maximum_velocity_mm_s::Float64

    acceleration_mm_s2::Float64

    position_error_mm::Float64
end


# ============================================================
# PRODUCT FOLLOWER
# ============================================================

mutable struct ProductFollower

    position_mm::Float64

    target_position_mm::Float64

    velocity_mm_s::Float64

    maximum_velocity_mm_s::Float64

    kp::Float64
    ki::Float64
    kd::Float64

    integral_error::Float64
    previous_error::Float64
end


# ============================================================
# SLICING PROGRAM
# ============================================================

mutable struct SliceProgram

    name::Symbol

    mode::ControlMode

    nominal_thickness_mm::Float64

    minimum_thickness_mm::Float64
    maximum_thickness_mm::Float64

    target_weight_g::Float64

    maximum_weight_error_percent::Float64

    minimum_product_length_mm::Float64

    maximum_product_length_mm::Float64

    production_speed_mm_s::Float64

    maximum_waste_percent::Float64
end


# ============================================================
# MACHINE
# ============================================================

mutable struct SlicingMachine

    state::MachineState

    program::SliceProgram

    conveyor::Conveyor

    follower::ProductFollower

    blade::Blade

    products::Vector{Product}

    slices::Vector{Slice}

    active_product::Union{Nothing,Int}

    next_product_id::Int
    next_slice_id::Int

    elapsed_seconds::Float64

    total_products::Int
    completed_products::Int

    total_input_weight_g::Float64
    total_output_weight_g::Float64
    total_waste_weight_g::Float64

    faults::Vector{Symbol}
end


# ============================================================
# DEFAULT PROGRAM
# ============================================================

function standard_program()

    return SliceProgram(

        :STANDARD_PORTION,

        ADAPTIVE_YIELD,

        2.0,

        1.5,
        2.5,

        20.0,

        3.0,

        100.0,

        1000.0,

        250.0,

        8.0
    )
end


# ============================================================
# MACHINE CREATION
# ============================================================

function create_machine()

    program =
        standard_program()

    conveyor =
        Conveyor(

            0.0,
            0.0,
            0.0,
            500.0,
            500.0,
            0.0
        )

    follower =
        ProductFollower(

            0.0,
            0.0,
            0.0,
            500.0,

            2.0,
            0.05,
            0.2,

            0.0,
            0.0
        )

    blade =
        Blade(

            150.0,
            1200.0,
            3000.0,
            90.0,
            1.0,
            100.0,

            0,
            false
        )

    return SlicingMachine(

        STOPPED,

        program,

        conveyor,

        follower,

        blade,

        Product[],
        Slice[],

        nothing,

        1,
        1,

        0.0,

        0,
        0,

        0.0,
        0.0,
        0.0,

        Symbol[]
    )
end


# ============================================================
# VISION SYSTEM
# ============================================================

function scan_product(
    product::Product
)

    # Simulated machine vision.
    #
    # A real implementation would consume camera /
    # depth-camera measurements.

    confidence =
        0.98

    valid =
        product.length_mm > 0 &&
        product.width_mm > 0 &&
        product.height_mm > 0

    return VisionMeasurement(

        product.length_mm,
        product.width_mm,
        product.height_mm,

        product.orientation_deg,

        confidence,

        valid
    )
end


# ============================================================
# PRODUCT VOLUME
# ============================================================

function product_volume_mm3(
    product::Product
)

    return product.length_mm *
           product.width_mm *
           product.height_mm
end


# ============================================================
# PRODUCT WEIGHT
# ============================================================

function product_weight_g(
    product::Product
)

    volume_cm3 =
        product_volume_mm3(product) /
        1000.0

    return volume_cm3 *
           product.density_g_cm3
end


# ============================================================
# CROSS SECTION
# ============================================================

function cross_section_mm2(
    product::Product
)

    return product.width_mm *
           product.height_mm
end


# ============================================================
# ESTIMATE SLICE WEIGHT
# ============================================================

function estimate_slice_weight(
    product::Product,
    thickness_mm::Float64
)

    volume_mm3 =
        cross_section_mm2(product) *
        thickness_mm

    volume_cm3 =
        volume_mm3 /
        1000.0

    return volume_cm3 *
           product.density_g_cm3
end


# ============================================================
# THICKNESS FROM TARGET WEIGHT
# ============================================================

function thickness_for_weight(
    product::Product,
    target_weight_g::Float64
)

    area =
        cross_section_mm2(product)

    area <= 0 &&
        return 0.0

    volume_cm3 =
        target_weight_g /
        product.density_g_cm3

    volume_mm3 =
        volume_cm3 *
        1000.0

    return volume_mm3 /
           area
end


# ============================================================
# CLAMP THICKNESS
# ============================================================

function safe_thickness(
    machine::SlicingMachine,
    thickness_mm::Float64
)

    program =
        machine.program

    return clamp(

        thickness_mm,

        program.minimum_thickness_mm,

        program.maximum_thickness_mm
    )
end


# ============================================================
# OPTIMAL THICKNESS
# ============================================================

function optimal_thickness(
    machine::SlicingMachine,
    product::Product
)

    program =
        machine.program

    if program.mode ==
       FIXED_THICKNESS

        return safe_thickness(
            machine,
            program.nominal_thickness_mm
        )
    end

    if program.mode ==
       TARGET_WEIGHT

        thickness =
            thickness_for_weight(
                product,
                program.target_weight_g
            )

        return safe_thickness(
            machine,
            thickness
        )
    end

    # Adaptive yield mode.
    #
    # Balance:
    #
    #   target weight
    #   thickness constraints
    #   remaining product
    #   waste

    target =
        thickness_for_weight(
            product,
            program.target_weight_g
        )

    nominal =
        program.nominal_thickness_mm

    weighted_target =
        0.75 * target +
        0.25 * nominal

    return safe_thickness(
        machine,
        weighted_target
    )
end


# ============================================================
# PID FOLLOWER
# ============================================================

function follower_control!(
    follower::ProductFollower,
    dt::Float64
)

    error =
        follower.target_position_mm -
        follower.position_mm

    follower.integral_error +=
        error *
        dt

    derivative =
        (
            error -
            follower.previous_error
        ) /
        max(
            dt,
            0.0001
        )

    output =
        follower.kp * error +
        follower.ki *
        follower.integral_error +
        follower.kd *
        derivative

    follower.velocity_mm_s =
        clamp(

            output,

            -follower.maximum_velocity_mm_s,

            follower.maximum_velocity_mm_s
        )

    follower.previous_error =
        error

    return follower.velocity_mm_s
end


# ============================================================
# CONVEYOR CONTROL
# ============================================================

function update_conveyor!(
    conveyor::Conveyor,
    dt::Float64
)

    error =
        conveyor.target_velocity_mm_s -
        conveyor.velocity_mm_s

    maximum_change =
        conveyor.acceleration_mm_s2 *
        dt

    change =
        clamp(
            error,
            -maximum_change,
            maximum_change
        )

    conveyor.velocity_mm_s +=
        change

    conveyor.velocity_mm_s =
        clamp(

            conveyor.velocity_mm_s,

            0.0,

            conveyor.maximum_velocity_mm_s
        )

    conveyor.position_mm +=
        conveyor.velocity_mm_s *
        dt
end


# ============================================================
# BLADE SYNCHRONISATION
# ============================================================

function blade_surface_speed(
    blade::Blade
)

    circumference =
        2π *
        blade.radius_mm

    return circumference *
           blade.rpm /
           60.0
end


function synchronise_blade!(
    machine::SlicingMachine
)

    conveyor_speed =
        machine.conveyor.velocity_mm_s

    # Simplified synchronisation relationship.
    #
    # Actual machines use electronic gearing/camming
    # and machine-specific kinematics.

    target_rpm =
        (
            conveyor_speed /
            max(
                2π *
                machine.blade.radius_mm,
                1.0
            )
        ) *
        60.0

    target_rpm *=
        4.0

    machine.blade.rpm =
        clamp(

            target_rpm,

            300.0,

            machine.blade.maximum_rpm
        )
end


# ============================================================
# ADD PRODUCT
# ============================================================

function add_product!(
    machine::SlicingMachine;

    length_mm=300.0,
    width_mm=100.0,
    height_mm=60.0,
    density_g_cm3=1.05,
    target_weight_g=20.0,
    orientation_deg=0.0
)

    product =
        Product(

            machine.next_product_id,

            WAITING,

            length_mm,
            width_mm,
            height_mm,

            density_g_cm3,

            0.0,
            0.0,

            orientation_deg,

            length_mm,

            target_weight_g,

            0,

            0.0,
            0.0,

            false,
            false
        )

    push!(
        machine.products,
        product
    )

    machine.next_product_id +=
        1

    machine.total_products +=
        1

    weight =
        product_weight_g(
            product
        )

    machine.total_input_weight_g +=
        weight

    return product.id
end


# ============================================================
# FIND PRODUCT
# ============================================================

function get_product(
    machine::SlicingMachine,
    id::Int
)

    index =
        findfirst(
            p -> p.id == id,
            machine.products
        )

    index === nothing &&
        return nothing

    return machine.products[index]
end


# ============================================================
# START MACHINE
# ============================================================

function start!(
    machine::SlicingMachine
)

    if machine.state ==
       EMERGENCY_STOP

        return false
    end

    machine.state =
        STARTING

    machine.conveyor.target_velocity_mm_s =
        machine.program.production_speed_mm_s

    machine.state =
        RUNNING

    return true
end


# ============================================================
# STOP MACHINE
# ============================================================

function stop!(
    machine::SlicingMachine
)

    machine.conveyor.target_velocity_mm_s =
        0.0

    machine.state =
        STOPPED
end


# ============================================================
# PRODUCT TRACKING
# ============================================================

function track_product!(
    machine::SlicingMachine,
    product::Product
)

    if product.state ==
       WAITING

        product.state =
            SCANNING
    end

    if product.state ==
       SCANNING

        vision =
            scan_product(
                product
            )

        if !vision.valid ||
           vision.confidence < 0.90

            product.state =
                REJECTED

            return false
        end

        product.scan_complete =
            true

        product.state =
            TRACKING
    end

    if product.state ==
       TRACKING

        product.tracking_locked =
            true

        machine.follower.target_position_mm =
            product.position_mm

        return true
    end

    return false
end


# ============================================================
# SLICE DECISION
# ============================================================

function calculate_slice(
    machine::SlicingMachine,
    product::Product
)

    thickness =
        optimal_thickness(
            machine,
            product
        )

    estimated_weight =
        estimate_slice_weight(
            product,
            thickness
        )

    target =
        machine.program.target_weight_g

    error =
        (
            estimated_weight -
            target
        ) /
        max(
            target,
            0.001
        ) *
        100.0

    return thickness,
           estimated_weight,
           error
end


# ============================================================
# PERFORM SLICE
# ============================================================

function perform_slice!(
    machine::SlicingMachine,
    product::Product
)

    if product.remaining_length_mm <=
       machine.program.minimum_thickness_mm

        product.state =
            COMPLETE

        machine.completed_products +=
            1

        return nothing
    end

    thickness,
    weight,
    error =
        calculate_slice(
            machine,
            product
        )

    # --------------------------------------------------------
    # Prevent impossible cut.
    # --------------------------------------------------------

    if thickness >
       product.remaining_length_mm

        product.waste_weight_g +=
            estimate_slice_weight(
                product,
                product.remaining_length_mm
            )

        product.remaining_length_mm =
            0.0

        product.state =
            COMPLETE

        machine.completed_products +=
            1

        return nothing
    end

    slice =
        Slice(

            machine.next_slice_id,

            product.id,

            thickness,

            product.width_mm,

            product.height_mm,

            weight,

            machine.program.target_weight_g,

            error,

            product.position_mm
        )

    push!(
        machine.slices,
        slice
    )

    machine.next_slice_id +=
        1

    product.slices_produced +=
        1

    product.total_weight_produced_g +=
        weight

    product.remaining_length_mm -=
        thickness

    machine.total_output_weight_g +=
        weight

    machine.blade.cuts_completed +=
        1

    # --------------------------------------------------------
    # Kerf loss
    # --------------------------------------------------------

    kerf_loss =
        machine.blade.kerf_mm *
        cross_section_mm2(product) /
        1000.0 *
        product.density_g_cm3

    product.waste_weight_g +=
        kerf_loss

    machine.total_waste_weight_g +=
        kerf_loss

    machine.blade.sharpness -=
        0.002

    if machine.blade.sharpness <
       20.0

        machine.blade.maintenance_required =
            true
    end

    return slice
end


# ============================================================
# YIELD OPTIMISER
# ============================================================

function calculate_yield(
    product::Product
)

    input =
        product_weight_g(
            product
        )

    output =
        product.total_weight_produced_g

    if input <= 0
        return 0.0
    end

    return output /
           input *
           100.0
end


# ============================================================
# WASTE PERCENTAGE
# ============================================================

function calculate_waste(
    product::Product
)

    input =
        product_weight_g(
            product
        )

    input <= 0 &&
        return 0.0

    return product.waste_weight_g /
           input *
           100.0
end


# ============================================================
# CONTROL LOOP
# ============================================================

function update!(
    machine::SlicingMachine,
    dt::Float64
)

    if machine.state !=
       RUNNING

        return
    end

    machine.elapsed_seconds +=
        dt

    # --------------------------------------------------------
    # Conveyor
    # --------------------------------------------------------

    update_conveyor!(
        machine.conveyor,
        dt
    )

    # --------------------------------------------------------
    # Blade
    # --------------------------------------------------------

    synchronise_blade!(
        machine
    )

    # --------------------------------------------------------
    # Find / track products
    # --------------------------------------------------------

    for product in
        machine.products

        if product.state ==
           COMPLETE ||
           product.state ==
           REJECTED

            continue
        end

        product.position_mm +=
            machine.conveyor.velocity_mm_s *
            dt

        track_product!(
            machine,
            product
        )
    end

    # --------------------------------------------------------
    # Select active product
    # --------------------------------------------------------

    active =
        findfirst(
            p ->
                p.state ==
                TRACKING ||
                p.state ==
                SLICING,
            machine.products
        )

    if active !== nothing

        product =
            machine.products[
                active
            ]

        machine.active_product =
            product.id

        product.state =
            SLICING

        # ----------------------------------------------------
        # Determine whether another cut is due.
        # ----------------------------------------------------

        slice_pitch =
            optimal_thickness(
                machine,
                product
            )

        if product.remaining_length_mm >
           slice_pitch

            perform_slice!(
                machine,
                product
            )

        else

            product.state =
                COMPLETE

            machine.completed_products +=
                1
        end
    end

    # --------------------------------------------------------
    # Blade maintenance
    # --------------------------------------------------------

    if machine.blade.maintenance_required

        push!(
            machine.faults,
            :BLADE_MAINTENANCE_REQUIRED
        )
    end
end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(
    machine::SlicingMachine,
    reason::Symbol
)

    machine.state =
        EMERGENCY_STOP

    machine.conveyor.target_velocity_mm_s =
        0.0

    machine.conveyor.velocity_mm_s =
        0.0

    push!(
        machine.faults,
        reason
    )
end


# ============================================================
# MACHINE STATISTICS
# ============================================================

function throughput(
    machine::SlicingMachine
)

    if machine.elapsed_seconds <=
       0.0

        return 0.0
    end

    return length(machine.slices) /
           (
               machine.elapsed_seconds /
               60.0
           )
end


function total_yield(
    machine::SlicingMachine
)

    if machine.total_input_weight_g <=
       0.0

        return 0.0
    end

    return machine.total_output_weight_g /
           machine.total_input_weight_g *
           100.0
end


function total_waste(
    machine::SlicingMachine
)

    if machine.total_input_weight_g <=
       0.0

        return 0.0
    end

    return machine.total_waste_weight_g /
           machine.total_input_weight_g *
           100.0
end


# ============================================================
# REPORT
# ============================================================

function report(
    machine::SlicingMachine
)

    println()
    println(
        "=========================================================="
    )

    println(
        "          INDUSTRIAL SLICING CONTROL ENGINE"
    )

    println(
        "=========================================================="
    )

    @printf(
        "Machine state:          %s\n",
        machine.state
    )

    @printf(
        "Runtime:                %.2f min\n",
        machine.elapsed_seconds / 60
    )

    @printf(
        "Products processed:    %d\n",
        machine.completed_products
    )

    @printf(
        "Slices produced:       %d\n",
        length(machine.slices)
    )

    @printf(
        "Throughput:             %.1f slices/min\n",
        throughput(machine)
    )

    @printf(
        "Input mass:             %.2f kg\n",
        machine.total_input_weight_g / 1000
    )

    @printf(
        "Output mass:            %.2f kg\n",
        machine.total_output_weight_g / 1000
    )

    @printf(
        "Yield:                  %.2f %%\n",
        total_yield(machine)
    )

    @printf(
        "Waste:                  %.2f %%\n",
        total_waste(machine)
    )

    println()

    println(
        "BLADE"
    )

    @printf(
        "RPM:                    %.0f\n",
        machine.blade.rpm
    )

    @printf(
        "Sharpness:              %.1f %%\n",
        machine.blade.sharpness
    )

    @printf(
        "Cuts:                   %d\n",
        machine.blade.cuts_completed
    )

    @printf(
        "Maintenance required:  %s\n",
        machine.blade.maintenance_required
    )

    println()

    println(
        "CONVEYOR"
    )

    @printf(
        "Velocity:               %.1f mm/s\n",
        machine.conveyor.velocity_mm_s
    )

    println()

    println(
        "FAULTS"
    )

    if isempty(machine.faults)

        println(
            "  NONE"
        )

    else

        for fault in
            unique(machine.faults)

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
# DEMONSTRATION
# ============================================================

function demo()

    machine =
        create_machine()

    start!(
        machine
    )

    # Add products with slightly different dimensions.
    for i in 1:10

        add_product!(
            machine;

            length_mm =
                280.0 +
                rand() * 60.0,

            width_mm =
                95.0 +
                rand() * 10.0,

            height_mm =
                55.0 +
                rand() * 10.0,

            density_g_cm3 =
                1.00 +
                rand() * 0.10,

            target_weight_g =
                20.0
        )
    end

    # Simulate production.
    timestep =
        0.1

    runtime =
        120.0

    steps =
        Int(
            runtime /
            timestep
        )

    for _ in 1:steps

        update!(
            machine,
            timestep
        )

        if machine.state ==
           EMERGENCY_STOP

            break
        end
    end

    report(
        machine
    )

    return machine
end


end # module


# ============================================================
# RUN
# ============================================================

using .IndustrialSlicing

IndustrialSlicing.demo()
