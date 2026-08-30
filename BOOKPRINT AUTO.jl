```julia
# ================================================================
# BOOKPRINT AUTO
#
# Fully automated digital book-printing production simulator
#
# Pipeline:
#
#   DIGITAL MANUSCRIPT
#          ↓
#      PREFLIGHT
#          ↓
#      TYPESETTING
#          ↓
#      PAGE IMPOSITION
#          ↓
#      COVER GENERATION
#          ↓
#      PRODUCTION SCHEDULER
#          ↓
#      DIGITAL PRESS
#          ↓
#       BINDING
#          ↓
#       TRIMMING
#          ↓
#        QC
#          ↓
#       PACKING
#          ↓
#      DISPATCH
#
# Julia is used as the orchestration / optimisation engine.
#
# All production values are illustrative.
# ================================================================

using Dates
using UUIDs
using Printf
using Statistics

# ================================================================
# ENUMS
# ================================================================

@enum BookFormat begin
    A5
    A4
    SIX_BY_NINE
    CUSTOM
end

@enum BindingType begin
    PERFECT_BOUND
    SADDLE_STITCH
    CASE_BOUND
end

@enum ProductionStage begin
    PREFLIGHT
    TYPESETTING
    IMPOSITION
    COVER
    PRINTING
    BINDING
    TRIMMING
    QUALITY_CONTROL
    PACKING
    DISPATCHED
    FAILED
end

# ================================================================
# BOOK SPECIFICATION
# ================================================================

struct BookSpec

    title::String

    author::String

    pages::Int

    format::BookFormat

    width_mm::Float64

    height_mm::Float64

    binding::BindingType

    interior_colour::Bool

    cover_colour::Bool

    paper_gsm::Int

    cover_gsm::Int

    quantity::Int
end

# ================================================================
# MANUSCRIPT
# ================================================================

struct Manuscript

    filename::String

    word_count::Int

    chapters::Int

    images::Int

    fonts_embedded::Bool

    missing_references::Int

    corrupted_assets::Int
end

# ================================================================
# PREFLIGHT RESULT
# ================================================================

struct PreflightResult

    passed::Bool

    errors::Vector{String}

    warnings::Vector{String}

    estimated_pages::Int
end

# ================================================================
# PRODUCTION JOB
# ================================================================

mutable struct ProductionJob

    id::UUID

    book::BookSpec

    manuscript::Manuscript

    stage::ProductionStage

    progress::Float64

    created_at::DateTime

    completed_at::Union{Nothing,DateTime}

    estimated_cost::Float64

    actual_cost::Float64

    estimated_minutes::Float64

    actual_minutes::Float64

    qc_score::Float64

    rejected::Int

    packed::Int
end

# ================================================================
# PRESS
# ================================================================

mutable struct DigitalPress

    id::String

    name::String

    pages_per_minute_bw::Float64

    pages_per_minute_colour::Float64

    max_sheet_width_mm::Float64

    max_sheet_height_mm::Float64

    available::Bool

    current_job::Union{Nothing,UUID}

    uptime::Float64
end

# ================================================================
# FINISHING LINE
# ================================================================

mutable struct FinishingLine

    id::String

    binding_type::BindingType

    books_per_hour::Float64

    available::Bool
end

# ================================================================
# FACTORY
# ================================================================

mutable struct PrintFactory

    presses::Vector{DigitalPress}

    finishing_lines::Vector{FinishingLine}

    jobs::Vector{ProductionJob}

    completed_jobs::Int

    total_books_printed::Int

    total_waste::Int
end

# ================================================================
# FORMAT DIMENSIONS
# ================================================================

function format_dimensions(
    format::BookFormat
)

    if format == A5

        return (
            148.0,
            210.0
        )

    elseif format == A4

        return (
            210.0,
            297.0
        )

    elseif format == SIX_BY_NINE

        return (
            152.4,
            228.6
        )

    else

        return (
            150.0,
            230.0
        )
    end
end

# ================================================================
# PREFLIGHT
# ================================================================

function preflight(
    book::BookSpec,
    manuscript::Manuscript
)

    errors =
        String[]

    warnings =
        String[]

    # ------------------------------------------------------------
    # Page count
    # ------------------------------------------------------------

    if book.pages <= 0

        push!(
            errors,
            "Book contains no pages."
        )
    end

    if manuscript.corrupted_assets > 0

        push!(
            errors,
            "Corrupted manuscript assets detected."
        )
    end

    if manuscript.missing_references > 0

        push!(
            warnings,
            "Missing references detected."
        )
    end

    if !manuscript.fonts_embedded

        push!(
            warnings,
            "Fonts are not embedded."
        )
    end

    # ------------------------------------------------------------
    # Binding constraints
    # ------------------------------------------------------------

    if book.binding ==
       SADDLE_STITCH &&
       book.pages > 96

        push!(
            errors,
            "Page count exceeds saddle-stitch limit."
        )
    end

    # ------------------------------------------------------------
    # Image density
    # ------------------------------------------------------------

    if manuscript.images >
       manuscript.word_count ÷ 100

        push!(
            warnings,
            "High image density."
        )
    end

    return PreflightResult(

        isempty(errors),

        errors,

        warnings,

        book.pages
    )
end

# ================================================================
# TYPESETTING
# ================================================================

function typeset_time(
    manuscript::Manuscript
)

    base =
        manuscript.word_count /
        12_000.0

    image_processing =
        manuscript.images *
        0.15

    chapter_processing =
        manuscript.chapters *
        0.05

    return (
        base +
        image_processing +
        chapter_processing
    )
end

# ================================================================
# IMPOSITION
#
# Converts book pages into press sheets.
# ================================================================

function sheets_per_book(
    book::BookSpec
)

    # Demonstration:
    # two book pages per side,
    # two sides per sheet.

    pages_per_sheet =
        4

    if book.binding ==
       SADDLE_STITCH

        pages_per_sheet = 4

    elseif book.binding ==
           PERFECT_BOUND

        pages_per_sheet = 4

    elseif book.binding ==
           CASE_BOUND

        pages_per_sheet = 2
    end

    return ceil(
        book.pages /
        pages_per_sheet
    )
end

# ================================================================
# PRINT TIME
# ================================================================

function print_time(
    book::BookSpec,
    press::DigitalPress
)

    pages =
        book.pages *
        book.quantity

    speed =
        book.interior_colour ?
        press.pages_per_minute_colour :
        press.pages_per_minute_bw

    return pages / speed
end

# ================================================================
# PAPER CONSUMPTION
# ================================================================

function paper_mass_per_book(
    book::BookSpec
)

    area_m2 =
        (
            book.width_mm / 1000.0
        ) *
        (
            book.height_mm / 1000.0
        )

    return (
        area_m2 *
        book.pages *
        book.paper_gsm /
        1000.0
    )
end

# ================================================================
# COVER COST
# ================================================================

function cover_cost(
    book::BookSpec
)

    if book.cover_colour

        return 0.32

    else

        return 0.18
    end
end

# ================================================================
# PRINT COST
# ================================================================

function print_cost(
    book::BookSpec
)

    bw_cost =
        0.012

    colour_cost =
        0.045

    page_cost =
        book.interior_colour ?
        colour_cost :
        bw_cost

    return (
        book.pages *
        book.quantity *
        page_cost
    )
end

# ================================================================
# BINDING COST
# ================================================================

function binding_cost(
    book::BookSpec
)

    if book.binding ==
       PERFECT_BOUND

        return 0.80 *
               book.quantity

    elseif book.binding ==
           SADDLE_STITCH

        return 0.35 *
               book.quantity

    else

        return 4.50 *
               book.quantity
    end
end

# ================================================================
# ESTIMATE COST
# ================================================================

function estimate_cost(
    book::BookSpec
)

    printing =
        print_cost(book)

    covers =
        cover_cost(book) *
        book.quantity

    binding =
        binding_cost(book)

    paper =
        paper_mass_per_book(book) *
        book.quantity *
        0.002

    finishing =
        0.25 *
        book.quantity

    return (
        printing +
        covers +
        binding +
        paper +
        finishing
    )
end

# ================================================================
# CREATE JOB
# ================================================================

function create_job(
    book::BookSpec,
    manuscript::Manuscript
)

    return ProductionJob(

        uuid4(),

        book,

        manuscript,

        PREFLIGHT,

        0.0,

        now(),

        nothing,

        estimate_cost(book),

        0.0,

        0.0,

        0.0,

        0.0,

        0,

        0
    )
end

# ================================================================
# FACTORY INITIALISATION
# ================================================================

function create_factory()

    presses = [

        DigitalPress(
            "PRESS-01",
            "Digital Press Alpha",
            240.0,
            110.0,
            330.0,
            480.0,
            true,
            nothing,
            1.0
        ),

        DigitalPress(
            "PRESS-02",
            "Digital Press Beta",
            300.0,
            140.0,
            330.0,
            480.0,
            true,
            nothing,
            1.0
        )
    ]

    finishing = [

        FinishingLine(
            "FIN-01",
            PERFECT_BOUND,
            600.0,
            true
        ),

        FinishingLine(
            "FIN-02",
            SADDLE_STITCH,
            900.0,
            true
        ),

        FinishingLine(
            "FIN-03",
            CASE_BOUND,
            180.0,
            true
        )
    ]

    return PrintFactory(

        presses,

        finishing,

        ProductionJob[],

        0,

        0,

        0
    )
end

# ================================================================
# PRODUCTION ROUTING
# ================================================================

function select_press(
    factory::PrintFactory,
    book::BookSpec
)

    available =
        filter(
            p ->
                p.available &&
                book.width_mm <=
                    p.max_sheet_width_mm &&
                book.height_mm <=
                    p.max_sheet_height_mm,

            factory.presses
        )

    if isempty(available)

        return nothing
    end

    # Select fastest suitable press

    return argmax(
        p ->
            book.interior_colour ?
            p.pages_per_minute_colour :
            p.pages_per_minute_bw,

        available
    )
end

# ================================================================
# FINISHING ROUTING
# ================================================================

function select_finisher(
    factory::PrintFactory,
    binding::BindingType
)

    available =
        filter(
            f ->
                f.available &&
                f.binding_type == binding,

            factory.finishing_lines
        )

    if isempty(available)

        return nothing
    end

    return argmax(
        f -> f.books_per_hour,
        available
    )
end

# ================================================================
# RUN PREFLIGHT
# ================================================================

function run_preflight!(
    job::ProductionJob
)

    result =
        preflight(
            job.book,
            job.manuscript
        )

    if !result.passed

        job.stage =
            FAILED

        return result
    end

    job.stage =
        TYPESETTING

    return result
end

# ================================================================
# TYPESETTING
# ================================================================

function run_typesetting!(
    job::ProductionJob
)

    job.actual_minutes +=
        typeset_time(
            job.manuscript
        )

    job.progress =
        1.0

    job.stage =
        IMPOSITION

    return true
end

# ================================================================
# IMPOSITION
# ================================================================

function run_imposition!(
    job::ProductionJob
)

    sheets =
        sheets_per_book(
            job.book
        )

    total_sheets =
        sheets *
        job.book.quantity

    # Simulated imposition computation

    job.actual_minutes +=
        total_sheets /
        500.0

    job.progress =
        1.0

    job.stage =
        COVER

    return true
end

# ================================================================
# COVER GENERATION
# ================================================================

function generate_cover!(
    job::ProductionJob
)

    job.actual_minutes +=
        0.2

    job.stage =
        PRINTING

    return true
end

# ================================================================
# PRINTING
# ================================================================

function run_press!(
    factory::PrintFactory,
    job::ProductionJob
)

    press =
        select_press(
            factory,
            job.book
        )

    if press === nothing

        job.stage =
            FAILED

        return false
    end

    press.available =
        false

    press.current_job =
        job.id

    job.estimated_minutes =
        print_time(
            job.book,
            press
        )

    # Production simulation

    job.actual_minutes +=
        job.estimated_minutes

    job.progress =
        1.0

    # Simulated waste

    waste_rate =
        0.008

    waste =
        ceil(
            job.book.quantity *
            waste_rate
        )

    job.rejected +=
        Int(waste)

    factory.total_waste +=
        Int(waste)

    factory.total_books_printed +=
        job.book.quantity -
        Int(waste)

    press.uptime =
        max(
            0.0,
            press.uptime -
            job.estimated_minutes /
            10_000.0
        )

    press.available =
        true

    press.current_job =
        nothing

    job.stage =
        BINDING

    return true
end

# ================================================================
# BINDING
# ================================================================

function run_binding!(
    factory::PrintFactory,
    job::ProductionJob
)

    finisher =
        select_finisher(
            factory,
            job.book.binding
        )

    if finisher === nothing

        job.stage =
            FAILED

        return false
    end

    finisher.available =
        false

    minutes =
        (
            job.book.quantity /
            finisher.books_per_hour
        ) *
        60.0

    job.actual_minutes +=
        minutes

    finisher.available =
        true

    job.stage =
        TRIMMING

    return true
end

# ================================================================
# TRIMMING
# ================================================================

function run_trimming!(
    job::ProductionJob
)

    trim_time =
        job.book.quantity *
        0.015

    job.actual_minutes +=
        trim_time

    job.stage =
        QUALITY_CONTROL

    return true
end

# ================================================================
# QUALITY CONTROL
# ================================================================

function quality_control!(
    factory::PrintFactory,
    job::ProductionJob
)

    # Simulated automated QC

    registration_error =
        rand()

    colour_error =
        rand()

    binding_error =
        rand()

    score =
        100.0

    if registration_error >
       0.97

        score -= 8
    end

    if colour_error >
       0.98

        score -= 5
    end

    if binding_error >
       0.99

        score -= 10
    end

    job.qc_score =
        score

    if score < 90.0

        job.rejected +=
            1

        factory.total_waste +=
            1
    end

    job.stage =
        PACKING

    return true
end

# ================================================================
# PACKING
# ================================================================

function pack!(
    job::ProductionJob
)

    good_books =
        max(
            0,
            job.book.quantity -
            job.rejected
        )

    job.packed =
        good_books

    job.actual_minutes +=
        good_books *
        0.01

    job.stage =
        DISPATCHED

    job.completed_at =
        now()

    return true
end

# ================================================================
# COMPLETE JOB
# ================================================================

function execute_job!(
    factory::PrintFactory,
    job::ProductionJob
)

    result =
        run_preflight!(
            job
        )

    if !result.passed

        return false
    end

    run_typesetting!(
        job
    )

    run_imposition!(
        job
    )

    generate_cover!(
        job
    )

    if !run_press!(
        factory,
        job
    )

        return false
    end

    if !run_binding!(
        factory,
        job
    )

        return false
    end

    run_trimming!(
        job
    )

    quality_control!(
        factory,
        job
    )

    pack!(
        job
    )

    job.actual_cost =
        job.estimated_cost *
        (
            0.96 +
            rand() * 0.08
        )

    factory.completed_jobs +=
        1

    return true
end

# ================================================================
# PRODUCTION DASHBOARD
# ================================================================

function print_dashboard(
    factory::PrintFactory
)

    println()
    println(
        "=============================================================="
    )

    println(
        "                  BOOKPRINT AUTO"
    )

    println(
        "=============================================================="
    )

    println(
        "Jobs completed:     ",
        factory.completed_jobs
    )

    println(
        "Books produced:     ",
        factory.total_books_printed
    )

    println(
        "Production waste:   ",
        factory.total_waste
    )

    println()

    println(
        "PRESS STATUS"
    )

    for press in
        factory.presses

        println(
            "  ",
            press.id,
            " | ",
            press.name,
            " | Available: ",
            press.available,
            " | Uptime: ",
            round(
                press.uptime * 100,
                digits=2
            ),
            "%"
        )
    end

    println(
        "=============================================================="
    )
end

# ================================================================
# JOB REPORT
# ================================================================

function job_report(
    job::ProductionJob
)

    println()
    println(
        "--------------------------------------------------------------"
    )

    println(
        "JOB REPORT"
    )

    println(
        "--------------------------------------------------------------"
    )

    println(
        "Job ID:              ",
        job.id
    )

    println(
        "Title:               ",
        job.book.title
    )

    println(
        "Author:              ",
        job.book.author
    )

    println(
        "Pages:               ",
        job.book.pages
    )

    println(
        "Quantity:            ",
        job.book.quantity
    )

    println(
        "Binding:             ",
        job.book.binding
    )

    println(
        "Final stage:         ",
        job.stage
    )

    @printf(
        "Estimated cost:      £%.2f\n",
        job.estimated_cost
    )

    @printf(
        "Actual cost:         £%.2f\n",
        job.actual_cost
    )

    @printf(
        "QC score:            %.1f / 100\n",
        job.qc_score
    )

    println(
        "Rejected:            ",
        job.rejected
    )

    println(
        "Packed:              ",
        job.packed
    )

    @printf(
        "Production time:     %.2f minutes\n",
        job.actual_minutes
    )

    println(
        "--------------------------------------------------------------"
    )
end

# ================================================================
# DEMONSTRATION
# ================================================================

println()
println(
    "BOOKPRINT AUTO INITIALISING..."
)

factory =
    create_factory()

# ---------------------------------------------------------------
# Digital manuscript
# ---------------------------------------------------------------

manuscript =
    Manuscript(

        "future_book.indd",

        82_000,

        14,

        38,

        true,

        0,

        0
    )

# ---------------------------------------------------------------
# Book order
# ---------------------------------------------------------------

book =
    BookSpec(

        "The Automated Future",

        "A. Example",

        320,

        SIX_BY_NINE,

        152.4,

        228.6,

        PERFECT_BOUND,

        false,

        true,

        90,

        250,

        250
    )

# ---------------------------------------------------------------
# Create job
# ---------------------------------------------------------------

job =
    create_job(
        book,
        manuscript
    )

push!(
    factory.jobs,
    job
)

# ---------------------------------------------------------------
# Show preflight
# ---------------------------------------------------------------

println()
println(
    "Running automated preflight..."
)

preflight_result =
    preflight(
        book,
        manuscript
    )

println(
    "Preflight passed: ",
    preflight_result.passed
)

for warning in
    preflight_result.warnings

    println(
        "WARNING: ",
        warning
    )
end

for error in
    preflight_result.errors

    println(
        "ERROR: ",
        error
    )
end

# ---------------------------------------------------------------
# Cost estimate
# ---------------------------------------------------------------

println()

@printf(
    "Estimated production cost: £%.2f\n",
    job.estimated_cost
)

# ---------------------------------------------------------------
# Execute complete production
# ---------------------------------------------------------------

println()

println(
    "Starting autonomous production..."
)

execute_job!(
    factory,
    job
)

# ---------------------------------------------------------------
# Report
# ---------------------------------------------------------------

job_report(
    job
)

print_dashboard(
    factory
)

# ================================================================
# END
# ================================================================
```

