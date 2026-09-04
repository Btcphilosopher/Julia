###############################################################
# RHINOSAW 3-D LOG SAWING OPTIMIZER
# Julia 1.10+
#
# Purpose:
#   Optimize the sawing pattern of an individual log.
#
# Features:
#   - Tapered cylindrical log model
#   - Arbitrary log length
#   - Diameter variation
#   - Saw kerf
#   - Board thickness / width
#   - Multiple product grades
#   - Internal defects
#   - Log rotation search
#   - Board recovery calculation
#   - Revenue optimization
#   - Waste calculation
#   - Production-cost model
#   - Ranked cutting plans
#
# This is an engineering prototype rather than a machine-control
# system. Real sawmills require calibration against their scanners,
# saw geometry, grading rules and PLC interfaces.
###############################################################

using Printf
using Statistics
using LinearAlgebra
using Random

###############################################################
# 1. DATA STRUCTURES
###############################################################

struct Log
    length_mm::Float64
    butt_diameter_mm::Float64
    top_diameter_mm::Float64
end

struct Defect
    x_mm::Float64
    y_mm::Float64
    z_mm::Float64
    radius_mm::Float64
end

struct Product
    name::String
    thickness_mm::Float64
    width_mm::Float64
    price_per_m3::Float64
    grade_factor::Float64
end

struct Board
    product::Product
    x_position::Float64
    y_position::Float64
    rotation_deg::Float64
    volume_m3::Float64
    value::Float64
    defect_penalty::Float64
end

struct SawPattern
    rotation_deg::Float64
    boards::Vector{Board}
    lumber_volume_m3::Float64
    waste_volume_m3::Float64
    revenue::Float64
    processing_cost::Float64
    net_value::Float64
    recovery_percent::Float64
end

###############################################################
# 2. CONFIGURATION
###############################################################

const KERF_MM = 3.5

const TRIM_ALLOWANCE_MM = 5.0

const MIN_EDGE_MARGIN_MM = 8.0

const SAW_COST_PER_M3 = 18.0

const DEFECT_PENALTY = 0.35

###############################################################
# 3. BASIC GEOMETRY
###############################################################

"""
Radius of the log at position z.

z = 0        -> butt
z = length  -> top
"""
function log_radius(log::Log, z::Float64)

    t = clamp(z / log.length_mm, 0.0, 1.0)

    diameter =
        log.butt_diameter_mm * (1.0 - t) +
        log.top_diameter_mm * t

    return diameter / 2.0
end


"""
Approximate volume of a tapered cylindrical log using
the frustum equation.
"""
function log_volume_m3(log::Log)

    r1 = log.butt_diameter_mm / 2000.0
    r2 = log.top_diameter_mm / 2000.0
    h  = log.length_mm / 1000.0

    volume =
        π * h / 3.0 *
        (r1^2 + r1*r2 + r2^2)

    return volume
end


###############################################################
# 4. POINT INSIDE LOG
###############################################################

function point_inside_log(log::Log,
                          x::Float64,
                          y::Float64,
                          z::Float64)

    r = log_radius(log, z)

    return x^2 + y^2 <= r^2
end


###############################################################
# 5. DEFECT MODEL
###############################################################

"""
Check whether a board intersects any defect.

The board is represented by its centre position in the
cross-sectional plane.
"""
function board_hits_defect(board_x,
                           board_y,
                           defects::Vector{Defect})

    penalty = 0.0

    for defect in defects

        distance =
            sqrt(
                (board_x - defect.x_mm)^2 +
                (board_y - defect.y_mm)^2
            )

        if distance < defect.radius_mm

            penetration =
                1.0 -
                distance / defect.radius_mm

            penalty += penetration
        end
    end

    return min(penalty, 1.0)
end


###############################################################
# 6. BOARD VOLUME
###############################################################

function board_volume_m3(product::Product,
                          log::Log)

    thickness_m = product.thickness_mm / 1000.0
    width_m     = product.width_mm / 1000.0
    length_m    = log.length_mm / 1000.0

    return thickness_m * width_m * length_m
end


###############################################################
# 7. BOARD FITTING
###############################################################

"""
Determine whether the centre of a rectangular board fits
inside the log cross-section.

This uses the worst-case section: the smallest diameter,
which is conservative for tapered logs.
"""
function board_fits(log::Log,
                    x::Float64,
                    y::Float64,
                    product::Product)

    r = minimum(
        log.butt_diameter_mm,
        log.top_diameter_mm
    ) / 2.0

    half_w =
        product.width_mm / 2.0

    half_t =
        product.thickness_mm / 2.0

    # Check the four corners.
    corners = [
        (x-half_w, y-half_t),
        (x+half_w, y-half_t),
        (x-half_w, y+half_t),
        (x+half_w, y+half_t)
    ]

    for (cx, cy) in corners

        if cx^2 + cy^2 >
           (r - MIN_EDGE_MARGIN_MM)^2

            return false
        end
    end

    return true
end


###############################################################
# 8. CREATE BOARD
###############################################################

function create_board(log::Log,
                      product::Product,
                      x::Float64,
                      y::Float64,
                      rotation::Float64,
                      defects)

    if !board_fits(log, x, y, product)
        return nothing
    end

    volume =
        board_volume_m3(product, log)

    defect_penalty =
        board_hits_defect(
            x,
            y,
            defects
        )

    effective_grade =
        product.grade_factor *
        (1.0 - DEFECT_PENALTY * defect_penalty)

    value =
        volume *
        product.price_per_m3 *
        effective_grade

    return Board(
        product,
        x,
        y,
        rotation,
        volume,
        value,
        defect_penalty
    )
end


###############################################################
# 9. CROSS-SECTION BOARD GENERATOR
###############################################################

"""
Generate candidate board positions for a particular product.
"""
function generate_board_positions(log::Log,
                                  product::Product,
                                  rotation::Float64,
                                  defects)

    boards = Board[]

    r =
        minimum(
            log.butt_diameter_mm,
            log.top_diameter_mm
        ) / 2.0

    step_x =
        product.width_mm + KERF_MM

    step_y =
        product.thickness_mm + KERF_MM

    max_range = Int(ceil(r / step_x)) + 1

    for ix in -max_range:max_range

        for iy in -max_range:max_range

            x = ix * step_x
            y = iy * step_y

            b =
                create_board(
                    log,
                    product,
                    x,
                    y,
                    rotation,
                    defects
                )

            if b !== nothing
                push!(boards, b)
            end
        end
    end

    return boards
end


###############################################################
# 10. BOARD OVERLAP TEST
###############################################################

function boards_overlap(a::Board,
                        b::Board)

    ax1 =
        a.x_position -
        a.product.width_mm / 2

    ax2 =
        a.x_position +
        a.product.width_mm / 2

    ay1 =
        a.y_position -
        a.product.thickness_mm / 2

    ay2 =
        a.y_position +
        a.product.thickness_mm / 2

    bx1 =
        b.x_position -
        b.product.width_mm / 2

    bx2 =
        b.x_position +
        b.product.width_mm / 2

    by1 =
        b.y_position -
        b.product.thickness_mm / 2

    by2 =
        b.y_position +
        b.product.thickness_mm / 2

    x_overlap =
        !(ax2 + KERF_MM/2 < bx1 ||
          bx2 + KERF_MM/2 < ax1)

    y_overlap =
        !(ay2 + KERF_MM/2 < by1 ||
          by2 + KERF_MM/2 < ay1)

    return x_overlap && y_overlap
end


###############################################################
# 11. BUILD VALID BOARD COMBINATION
###############################################################

function select_boards(candidates::Vector{Board})

    # Highest economic value first
    sorted =
        sort(
            candidates,
            by = b -> b.value,
            rev = true
        )

    selected = Board[]

    for board in sorted

        valid = true

        for existing in selected

            if boards_overlap(
                board,
                existing
            )

                valid = false
                break
            end
        end

        if valid
            push!(selected, board)
        end
    end

    return selected
end


###############################################################
# 12. SAW PATTERN EVALUATION
###############################################################

function evaluate_pattern(log::Log,
                          products::Vector{Product},
                          rotation::Float64,
                          defects)

    candidates = Board[]

    for product in products

        boards =
            generate_board_positions(
                log,
                product,
                rotation,
                defects
            )

        append!(
            candidates,
            boards
        )
    end

    selected =
        select_boards(candidates)

    lumber_volume =
        sum(
            b.volume_m3
            for b in selected
        )

    revenue =
        sum(
            b.value
            for b in selected
        )

    raw_volume =
        log_volume_m3(log)

    waste_volume =
        max(
            raw_volume -
            lumber_volume,
            0.0
        )

    processing_cost =
        lumber_volume *
        SAW_COST_PER_M3

    net_value =
        revenue -
        processing_cost

    recovery =
        raw_volume > 0 ?
        100.0 *
        lumber_volume /
        raw_volume :
        0.0

    return SawPattern(
        rotation,
        selected,
        lumber_volume,
        waste_volume,
        revenue,
        processing_cost,
        net_value,
        recovery
    )
end


###############################################################
# 13. ROTATION SEARCH
###############################################################

function optimize_log(log::Log,
                      products::Vector{Product},
                      defects;
                      rotation_step = 5.0)

    patterns = SawPattern[]

    angle = 0.0

    while angle < 180.0

        pattern =
            evaluate_pattern(
                log,
                products,
                angle,
                defects
            )

        push!(
            patterns,
            pattern
        )

        angle += rotation_step
    end

    sort!(
        patterns,
        by = p -> p.net_value,
        rev = true
    )

    return patterns
end


###############################################################
# 14. REPORTING
###############################################################

function print_pattern(pattern::SawPattern)

    println()
    println("===================================================")
    println("SAWING PATTERN")
    println("===================================================")

    @printf(
        "Rotation:          %.1f degrees\n",
        pattern.rotation_deg
    )

    @printf(
        "Lumber volume:     %.4f m³\n",
        pattern.lumber_volume_m3
    )

    @printf(
        "Waste volume:      %.4f m³\n",
        pattern.waste_volume_m3
    )

    @printf(
        "Recovery:          %.2f %%\n",
        pattern.recovery_percent
    )

    @printf(
        "Revenue:           £%.2f\n",
        pattern.revenue
    )

    @printf(
        "Processing cost:   £%.2f\n",
        pattern.processing_cost
    )

    @printf(
        "NET VALUE:         £%.2f\n",
        pattern.net_value
    )

    println()
    println("Boards:")

    for (i, board) in enumerate(pattern.boards)

        @printf(
            "%3d | %-12s | %6.1f × %6.1f mm | " *
            "x=%7.1f y=%7.1f | £%8.2f\n",

            i,

            board.product.name,

            board.product.thickness_mm,

            board.product.width_mm,

            board.x_position,

            board.y_position,

            board.value
        )
    end

    println("===================================================")
end


###############################################################
# 15. EXAMPLE MILL PRODUCTS
###############################################################

products = [

    Product(
        "2x4 Structural",
        38.0,
        89.0,
        420.0,
        1.00
    ),

    Product(
        "2x6 Structural",
        38.0,
        140.0,
        455.0,
        1.00
    ),

    Product(
        "2x8 Structural",
        38.0,
        184.0,
        475.0,
        0.98
    ),

    Product(
        "2x10 Structural",
        38.0,
        235.0,
        500.0,
        0.96
    ),

    Product(
        "4x4 Timber",
        89.0,
        89.0,
        530.0,
        0.92
    )
]


###############################################################
# 16. EXAMPLE LOG
###############################################################

log = Log(

    # length
    5000.0,

    # butt diameter
    420.0,

    # top diameter
    340.0
)


###############################################################
# 17. EXAMPLE INTERNAL DEFECTS
###############################################################

defects = [

    Defect(
        40.0,
        20.0,
        2500.0,
        30.0
    ),

    Defect(
        -75.0,
        -45.0,
        3200.0,
        25.0
    )
]


###############################################################
# 18. RUN OPTIMIZATION
###############################################################

println()
println("===================================================")
println("RHINOSAW 3-D LOG OPTIMIZER")
println("===================================================")

@printf(
    "Log volume: %.4f m³\n",
    log_volume_m3(log)
)

println()

patterns =
    optimize_log(
        log,
        products,
        defects,
        rotation_step = 5.0
    )


###############################################################
# 19. BEST SOLUTION
###############################################################

best =
    first(patterns)

println()
println("OPTIMAL SOLUTION")
print_pattern(best)


###############################################################
# 20. TOP 10 ALTERNATIVES
###############################################################

println()
println("TOP 10 CUTTING PLANS")
println("---------------------------------------------------")

for (i, pattern) in
    enumerate(first(patterns,
                    min(10, length(patterns))))

    @printf(
        "%2d | Rotation %6.1f° | " *
        "Recovery %6.2f%% | " *
        "Net £%10.2f\n",

        i,

        pattern.rotation_deg,

        pattern.recovery_percent,

        pattern.net_value
    )
end


###############################################################
# 21. PRODUCT MIX SUMMARY
###############################################################

function product_summary(pattern::SawPattern)

    println()
    println("PRODUCT MIX")
    println("---------------------------------------------------")

    counts =
        Dict{String, Int}()

    volumes =
        Dict{String, Float64}()

    values =
        Dict{String, Float64}()

    for board in pattern.boards

        name =
            board.product.name

        counts[name] =
            get(counts, name, 0) + 1

        volumes[name] =
            get(volumes, name, 0.0) +
            board.volume_m3

        values[name] =
            get(values, name, 0.0) +
            board.value
    end

    for name in keys(counts)

        @printf(
            "%-20s | Boards %3d | " *
            "Volume %7.4f m³ | " *
            "Value £%9.2f\n",

            name,

            counts[name],

            volumes[name],

            values[name]
        )
    end
end

product_summary(best)


###############################################################
# END
###############################################################
