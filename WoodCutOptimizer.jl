WoodCutOptimizer



module WoodCutOptimizer

using Printf

# ============================================================
# WOOD CUTTING OPTIMISATION ENGINE
# Pure Julia
#
# Supports:
#   - Linear timber cutting
#   - Board / beam optimisation
#   - Sheet/panel rectangular parts
#   - Saw kerf
#   - Trim allowance
#   - Grain direction
#   - Stock costs
#   - Offcut tracking
#   - Waste calculation
#   - Cut sequencing
#   - Production reporting
#
# DIGITAL-TWIN / PLANNING SOFTWARE
# Not a machine-control program.
# ============================================================


# ============================================================
# DATA TYPES
# ============================================================

struct Stock

    id::Int

    length_mm::Float64
    width_mm::Float64
    thickness_mm::Float64

    quantity::Int

    cost::Float64

    species::Symbol
    grade::Symbol
end


struct CutPart

    id::Int

    name::String

    length_mm::Float64
    width_mm::Float64
    thickness_mm::Float64

    quantity::Int

    priority::Int

    grain::Symbol

    species::Symbol
end


struct CutPiece

    id::Int

    name::String

    length_mm::Float64
    width_mm::Float64
    thickness_mm::Float64

    priority::Int

    grain::Symbol
end


mutable struct Placement

    piece::CutPiece

    x_mm::Float64
    y_mm::Float64

    rotated::Bool
end


mutable struct BoardPlan

    stock::Stock

    placements::Vector{Placement}

    used_length_mm::Float64
    used_area_mm2::Float64

    waste_area_mm2::Float64

    cuts::Int

    kerf_loss_mm::Float64
end


mutable struct LinearPlan

    stock::Stock

    pieces::Vector{CutPiece}

    remaining_mm::Float64

    kerf_loss_mm::Float64

    offcut_mm::Float64
end


mutable struct OptimizationResult

    plans::Vector{BoardPlan}

    linear_plans::Vector{LinearPlan}

    total_stock_cost::Float64

    total_stock_area_mm2::Float64

    total_part_area_mm2::Float64

    total_waste_area_mm2::Float64

    total_kerf_loss_mm::Float64

    yield_fraction::Float64

    total_parts::Int
end


# ============================================================
# PIECE EXPANSION
# ============================================================

function expand_parts(
    parts::Vector{CutPart}
)

    pieces =
        CutPiece[]

    id = 1

    for part in parts

        for _ in 1:part.quantity

            push!(
                pieces,

                CutPiece(
                    id,
                    part.name,
                    part.length_mm,
                    part.width_mm,
                    part.thickness_mm,
                    part.priority,
                    part.grain
                )
            )

            id += 1
        end
    end

    return pieces
end


# ============================================================
# SORTING
# ============================================================

function sort_pieces(
    pieces
)

    return sort(
        pieces,

        by = x -> (
            -x.priority,
            -(x.length_mm * x.width_mm)
        )
    )
end


# ============================================================
# GRAIN CHECK
# ============================================================

function allowed_orientation(
    piece::CutPiece,
    rotated::Bool
)

    if piece.grain == :ANY

        return true

    elseif piece.grain == :LENGTH

        return !rotated

    elseif piece.grain == :WIDTH

        return rotated

    end

    return true
end


# ============================================================
# LINEAR TIMBER OPTIMISER
# ============================================================

function optimize_linear(
    stock::Stock,
    pieces::Vector{CutPiece};
    kerf_mm=3.0,
    trim_start_mm=0.0,
    trim_end_mm=0.0
)

    linear_plans =
        LinearPlan[]

    sorted =
        sort(
            pieces,
            by = x -> -x.length_mm
        )

    for piece in sorted

        placed = false

        # Try existing boards first.
        for plan in linear_plans

            required =
                piece.length_mm +
                kerf_mm

            if plan.remaining_mm >=
               required

                push!(
                    plan.pieces,
                    piece
                )

                plan.remaining_mm -=
                    required

                plan.kerf_loss_mm +=
                    kerf_mm

                placed = true

                break
            end
        end

        if !placed

            available =
                stock.length_mm -
                trim_start_mm -
                trim_end_mm

            if piece.length_mm >
               available

                error(
                    "Piece $(piece.name) does not fit stock."
                )
            end

            plan =
                LinearPlan(
                    stock,
                    [piece],
                    available -
                    piece.length_mm -
                    kerf_mm,

                    kerf_mm,

                    max(
                        0.0,
                        available -
                        piece.length_mm -
                        kerf_mm
                    )
                )

            push!(
                linear_plans,
                plan
            )
        end
    end

    return linear_plans
end


# ============================================================
# 2D PANEL PLACEMENT
# ============================================================

function can_place(
    placement::Placement,
    placements::Vector{Placement},
    stock::Stock
)

    p =
        placement.piece

    x1 =
        placement.x_mm

    y1 =
        placement.y_mm

    x2 =
        x1 +
        (placement.rotated ?
         p.width_mm :
         p.length_mm)

    y2 =
        y1 +
        (placement.rotated ?
         p.length_mm :
         p.width_mm)

    if x2 >
       stock.length_mm

        return false
    end

    if y2 >
       stock.width_mm

        return false
    end

    for existing in placements

        ep =
            existing.piece

        ex1 =
            existing.x_mm

        ey1 =
            existing.y_mm

        ex2 =
            ex1 +
            (existing.rotated ?
             ep.width_mm :
             ep.length_mm)

        ey2 =
            ey1 +
            (existing.rotated ?
             ep.length_mm :
             ep.width_mm)

        overlap_x =
            x1 < ex2 &&
            x2 > ex1

        overlap_y =
            y1 < ey2 &&
            y2 > ey1

        if overlap_x &&
           overlap_y

            return false
        end
    end

    return true
end


# ============================================================
# PANEL PLACEMENT SEARCH
# ============================================================

function find_position(
    piece::CutPiece,
    placements::Vector{Placement},
    stock::Stock,
    kerf_mm::Float64
)

    orientations =
        Bool[]

    push!(
        orientations,
        false
    )

    if piece.length_mm !=
       piece.width_mm

        push!(
            orientations,
            true
        )
    end

    for rotated in orientations

        allowed_orientation(
            piece,
            rotated
        ) || continue

        width =
            rotated ?
            piece.length_mm :
            piece.width_mm

        length =
            rotated ?
            piece.width_mm :
            piece.length_mm

        # Candidate points.
        candidates =
            Tuple{Float64,Float64}[]

        push!(
            candidates,
            (0.0, 0.0)
        )

        for existing in placements

            ep =
                existing.piece

            ex =
                existing.x_mm

            ey =
                existing.y_mm

            ew =
                existing.rotated ?
                ep.length_mm :
                ep.width_mm

            el =
                existing.rotated ?
                ep.width_mm :
                ep.length_mm

            push!(
                candidates,
                (
                    ex + el + kerf_mm,
                    ey
                )
            )

            push!(
                candidates,
                (
                    ex,
                    ey + ew + kerf_mm
                )
            )
        end

        # Bottom-left heuristic.
        sort!(
            candidates,
            by = x -> (
                x[2],
                x[1]
            )
        )

        for (x, y) in candidates

            placement =
                Placement(
                    piece,
                    x,
                    y,
                    rotated
                )

            if can_place(
                placement,
                placements,
                stock
            )

                return placement
            end
        end
    end

    return nothing
end


# ============================================================
# PANEL OPTIMISER
# ============================================================

function optimize_panel(
    stock::Stock,
    pieces::Vector{CutPiece};
    kerf_mm=3.0
)

    plans =
        BoardPlan[]

    remaining =
        copy(pieces)

    stock_used =
        0

    while !isempty(remaining)

        stock_used += 1

        stock_used >
        stock.quantity &&
            error(
                "Insufficient stock."
            )

        current =
            BoardPlan(
                Stock(
                    stock_used,
                    stock.length_mm,
                    stock.width_mm,
                    stock.thickness_mm,
                    1,
                    stock.cost,
                    stock.species,
                    stock.grade
                ),

                Placement[],

                0.0,
                0.0,

                stock.length_mm *
                stock.width_mm,

                0,

                0.0
            )

        still_unplaced =
            CutPiece[]

        for piece in remaining

            placement =
                find_position(
                    piece,
                    current.placements,
                    current.stock,
                    kerf_mm
                )

            if placement === nothing

                push!(
                    still_unplaced,
                    piece
                )

            else

                push!(
                    current.placements,
                    placement
                )

                current.used_area_mm2 +=
                    piece.length_mm *
                    piece.width_mm

                current.cuts += 1

                current.kerf_loss_mm +=
                    kerf_mm
            end
        end

        current.waste_area_mm2 =
            max(
                0.0,
                stock.length_mm *
                stock.width_mm -
                current.used_area_mm2
            )

        push!(
            plans,
            current
        )

        remaining =
            still_unplaced
    end

    return plans
end


# ============================================================
# WASTE
# ============================================================

function calculate_linear_waste(
    plans::Vector{LinearPlan}
)

    total =
        0.0

    for plan in plans

        total +=
            plan.offcut_mm

    end

    return total
end


function calculate_panel_waste(
    plans::Vector{BoardPlan}
)

    return sum(
        p.waste_area_mm2
        for p in plans
    )
end


# ============================================================
# CUT SEQUENCE
# ============================================================

function cut_sequence(
    plan::LinearPlan
)

    # Longest cuts first.
    return sort(
        plan.pieces,
        by = x -> -x.length_mm
    )
end


function panel_cut_sequence(
    plan::BoardPlan
)

    # Prioritise large pieces.
    return sort(
        plan.placements,

        by = p ->
            -(
                p.piece.length_mm *
                p.piece.width_mm
            )
    )
end


# ============================================================
# TOTAL YIELD
# ============================================================

function calculate_yield(
    total_part_area,
    total_stock_area
)

    total_stock_area <= 0 &&
        return 0.0

    return clamp(
        total_part_area /
        total_stock_area,

        0.0,
        1.0
    )
end


# ============================================================
# PANEL JOB
# ============================================================

function optimize_panel_job(
    stock::Stock,
    parts::Vector{CutPart};
    kerf_mm=3.0
)

    pieces =
        expand_parts(parts)

    pieces =
        sort_pieces(pieces)

    plans =
        optimize_panel(
            stock,
            pieces;
            kerf_mm=kerf_mm
        )

    total_part_area =
        sum(
            p.length_mm *
            p.width_mm
            for p in pieces
        )

    total_stock_area =
        sum(
            p.stock.length_mm *
            p.stock.width_mm
            for p in plans
        )

    total_waste =
        calculate_panel_waste(
            plans
        )

    total_kerf =
        sum(
            p.kerf_loss_mm
            for p in plans
        )

    cost =
        sum(
            p.stock.cost
            for p in plans
        )

    yield =
        calculate_yield(
            total_part_area,
            total_stock_area
        )

    OptimizationResult(

        plans,

        LinearPlan[],

        cost,

        total_stock_area,

        total_part_area,

        total_waste,

        total_kerf,

        yield,

        length(pieces)
    )
end


# ============================================================
# LINEAR JOB
# ============================================================

function optimize_linear_job(
    stock::Stock,
    parts::Vector{CutPart};
    kerf_mm=3.0
)

    pieces =
        expand_parts(parts)

    plans =
        optimize_linear(
            stock,
            pieces;
            kerf_mm=kerf_mm
        )

    total_stock_length =
        sum(
            p.stock.length_mm
            for p in plans
        )

    total_part_length =
        sum(
            p.length_mm
            for p in pieces
        )

    total_kerf =
        sum(
            p.kerf_loss_mm
            for p in plans
        )

    total_waste =
        sum(
            p.offcut_mm
            for p in plans
        )

    yield =
        total_stock_length <= 0 ?
        0.0 :
        total_part_length /
        total_stock_length

    cost =
        sum(
            p.stock.cost
            for p in plans
        )

    OptimizationResult(

        BoardPlan[],

        plans,

        cost,

        total_stock_length,

        total_part_length,

        total_waste,

        total_kerf,

        yield,

        length(pieces)
    )
end


# ============================================================
# REPORT
# ============================================================

function print_linear_report(
    result::OptimizationResult
)

    println()
    println(
        "======================================================"
    )

    println(
        "             WOOD CUTTING PLAN"
    )

    println(
        "======================================================"
    )

    @printf(
        "Parts:              %d\n",
        result.total_parts
    )

    @printf(
        "Stock pieces:       %d\n",
        length(result.linear_plans)
    )

    @printf(
        "Stock cost:         %.2f\n",
        result.total_stock_cost
    )

    @printf(
        "Material used:      %.0f mm\n",
        result.total_part_area_mm2
    )

    @printf(
        "Kerf loss:          %.0f mm\n",
        result.total_kerf_loss_mm
    )

    @printf(
        "Offcut:             %.0f mm\n",
        result.total_waste_area_mm2
    )

    @printf(
        "Yield:              %.2f %%\n",
        result.yield_fraction * 100
    )

    println(
        "------------------------------------------------------"
    )

    for (i, plan) in
        enumerate(result.linear_plans)

        @printf(
            "STOCK %02d | %s\n",
            i,
            plan.stock.species
        )

        position =
            0.0

        for piece in
            cut_sequence(plan)

            @printf(
                "  %.0f mm  %s  @ %.0f mm\n",
                piece.length_mm,
                piece.name,
                position
            )

            position +=
                piece.length_mm

            position +=
                plan.kerf_loss_mm /
                max(
                    length(plan.pieces),
                    1
                )
        end

        @printf(
            "  OFFCUT %.0f mm\n",
            plan.offcut_mm
        )

        println()
    end

    println(
        "======================================================"
    )
end


# ============================================================
# PANEL REPORT
# ============================================================

function print_panel_report(
    result::OptimizationResult
)

    println()
    println(
        "======================================================"
    )

    println(
        "             PANEL CUTTING PLAN"
    )

    println(
        "======================================================"
    )

    @printf(
        "Parts:              %d\n",
        result.total_parts
    )

    @printf(
        "Panels used:        %d\n",
        length(result.plans)
    )

    @printf(
        "Material cost:      %.2f\n",
        result.total_stock_cost
    )

    @printf(
        "Waste area:         %.0f mm²\n",
        result.total_waste_area_mm2
    )

    @printf(
        "Kerf loss:          %.0f mm\n",
        result.total_kerf_loss_mm
    )

    @printf(
        "Yield:              %.2f %%\n",
        result.yield_fraction * 100
    )

    println(
        "------------------------------------------------------"
    )

    for (i, plan) in
        enumerate(result.plans)

        @printf(
            "PANEL %02d\n",
            i
        )

        for placement in
            panel_cut_sequence(plan)

            p =
                placement.piece

            @printf(
                "  %-20s %7.0f × %7.0f mm @ (%7.0f,%7.0f) %s\n",

                p.name,

                p.length_mm,

                p.width_mm,

                placement.x_mm,

                placement.y_mm,

                placement.rotated ?
                "ROTATED" :
                "NORMAL"
            )
        end

        @printf(
            "  Waste: %.0f mm²\n",
            plan.waste_area_mm2
        )

        println()
    end

    println(
        "======================================================"
    )
end


# ============================================================
# EXAMPLE: TIMBER
# ============================================================

function timber_demo()

    stock =
        Stock(
            1,

            4800.0,
            100.0,
            50.0,

            100,

            18.50,

            :OAK,
            :A
        )

    parts =
        CutPart[

            CutPart(
                1,
                "LONG_RAIL",
                1800.0,
                100.0,
                50.0,
                4,
                10,
                :LENGTH,
                :OAK
            ),

            CutPart(
                2,
                "SHORT_RAIL",
                900.0,
                100.0,
                50.0,
                6,
                8,
                :LENGTH,
                :OAK
            ),

            CutPart(
                3,
                "STILE",
                1200.0,
                100.0,
                50.0,
                4,
                7,
                :LENGTH,
                :OAK
            ),

            CutPart(
                4,
                "SMALL_BLOCK",
                450.0,
                100.0,
                50.0,
                6,
                3,
                :LENGTH,
                :OAK
            )
        ]

    result =
        optimize_linear_job(
            stock,
            parts;
            kerf_mm=3.0
        )

    print_linear_report(
        result
    )

    return result
end


# ============================================================
# EXAMPLE: SHEET GOODS
# ============================================================

function panel_demo()

    stock =
        Stock(
            1,

            2440.0,
            1220.0,
            18.0,

            50,

            65.0,

            :PLYWOOD,
            :A
        )

    parts =
        CutPart[

            CutPart(
                1,
                "SIDE_PANEL",
                700.0,
                400.0,
                18.0,
                4,
                10,
                :LENGTH,
                :PLYWOOD
            ),

            CutPart(
                2,
                "SHELF",
                600.0,
                350.0,
                18.0,
                6,
                8,
                :LENGTH,
                :PLYWOOD
            ),

            CutPart(
                3,
                "BACK_PANEL",
                900.0,
                500.0,
                18.0,
                2,
                9,
                :ANY,
                :PLYWOOD
            ),

            CutPart(
                4,
                "DRAWER_BASE",
                500.0,
                300.0,
                18.0,
                4,
                5,
                :ANY,
                :PLYWOOD
            )
        ]

    result =
        optimize_panel_job(
            stock,
            parts;
            kerf_mm=3.2
        )

    print_panel_report(
        result
    )

    return result
end


# ============================================================
# RUN
# ============================================================

function demo()

    println()
    println(
        "WOOD CUTTING OPTIMISATION"
    )

    println(
        "=========================="
    )

    println()
    println(
        "LINEAR TIMBER"
    )

    timber =
        timber_demo()

    println()
    println(
        "PANEL / SHEET GOODS"
    )

    panels =
        panel_demo()

    return timber, panels
end


end # module


# ============================================================
# EXECUTE
# ============================================================

using .WoodCutOptimizer

WoodCutOptimizer.demo()
