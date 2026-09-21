#!/usr/bin/env julia

using Printf
using Statistics

# ============================================================
# HomePrint.jl
#
# Lightweight printer optimisation engine
# ============================================================

struct Printer
    name::String
    dpi_x::Int
    dpi_y::Int
    colour::Bool
    duplex::Bool

    # Approximate cartridge capacities
    black_capacity_ml::Float64
    colour_capacity_ml::Float64

    # Approximate printer power consumption
    idle_watts::Float64
    printing_watts::Float64
end


struct PrintJob
    pages::Int
    colour::Bool
    text_density::Float64
    image_density::Float64
    desired_quality::Float64
    deadline_minutes::Float64
end


struct PrintPlan
    dpi::Int
    quality::Float64
    ink_factor::Float64
    estimated_black_ml::Float64
    estimated_colour_ml::Float64
    estimated_energy_wh::Float64
    duplex::Bool
    score::Float64
end


# ------------------------------------------------------------
# Printer definitions
# ------------------------------------------------------------

home_printer = Printer(
    "Home Printer",
    1200,
    1200,
    true,
    true,
    18.0,
    15.0,
    3.0,
    18.0
)


# ------------------------------------------------------------
# Ink consumption model
# ------------------------------------------------------------

function estimate_black_ink(job::PrintJob, plan_quality)

    # Base consumption per page.
    base = 0.018

    text_component =
        job.text_density * 0.018

    image_component =
        job.image_density * 0.035

    quality_component =
        plan_quality^1.35

    return job.pages *
           (base +
            text_component +
            image_component) *
           quality_component
end


function estimate_colour_ink(job::PrintJob, plan_quality)

    if !job.colour
        return 0.0
    end

    base = 0.025

    image_component =
        job.image_density * 0.055

    quality_component =
        plan_quality^1.45

    return job.pages *
           (base + image_component) *
           quality_component
end


# ------------------------------------------------------------
# Energy model
# ------------------------------------------------------------

function estimate_energy(
    printer::Printer,
    job::PrintJob,
    plan_quality
)

    # Approximate pages/minute.
    speed = 12.0

    # Higher quality generally reduces throughput.
    speed /= (0.65 + plan_quality)

    printing_minutes =
        job.pages / speed

    printing_energy =
        printing_minutes *
        printer.printing_watts / 60

    warmup_energy =
        printer.printing_watts * 0.05

    return printing_energy + warmup_energy
end


# ------------------------------------------------------------
# DPI optimisation
# ------------------------------------------------------------

function optimal_dpi(job::PrintJob)

    if job.desired_quality < 0.35
        return 300
    elseif job.desired_quality < 0.65
        return 600
    elseif job.desired_quality < 0.85
        return 900
    else
        return 1200
    end
end


# ------------------------------------------------------------
# Quality / ink tradeoff
# ------------------------------------------------------------

function ink_efficiency(
    black_ml,
    colour_ml
)

    total = black_ml + colour_ml

    return 1.0 / (1.0 + total)
end


function quality_score(
    actual_quality,
    desired_quality
)

    difference =
        abs(actual_quality - desired_quality)

    return exp(-4.0 * difference)
end


# ------------------------------------------------------------
# Optimisation
# ------------------------------------------------------------

function optimise(
    printer::Printer,
    job::PrintJob
)

    candidates = PrintPlan[]

    qualities =
        0.25:0.05:1.0

    dpis = [
        300,
        600,
        900,
        1200
    ]

    for quality in qualities

        for dpi in dpis

            # Don't request colour from monochrome printer.
            if job.colour && !printer.colour
                continue
            end

            black =
                estimate_black_ink(
                    job,
                    quality
                )

            colour =
                estimate_colour_ink(
                    job,
                    quality
                )

            energy =
                estimate_energy(
                    printer,
                    job,
                    quality
                )

            qscore =
                quality_score(
                    quality,
                    job.desired_quality
                )

            efficiency =
                ink_efficiency(
                    black,
                    colour
                )

            energy_score =
                1.0 / (1.0 + energy / 100)

            # Weighted objective.
            score =
                qscore * 0.55 +
                efficiency * 0.30 +
                energy_score * 0.15

            plan =
                PrintPlan(
                    dpi,
                    quality,
                    1.0 - efficiency,
                    black,
                    colour,
                    energy,
                    printer.duplex,
                    score
                )

            push!(
                candidates,
                plan
            )
        end
    end

    return candidates[
        argmax(p.score for p in candidates)
    ]
end


# ------------------------------------------------------------
# Queue optimisation
# ------------------------------------------------------------

function optimise_queue(
    printer,
    jobs
)

    plans = PrintPlan[]

    for job in jobs

        plan =
            optimise(
                printer,
                job
            )

        push!(
            plans,
            plan
        )
    end

    return plans
end


# ------------------------------------------------------------
# Reporting
# ------------------------------------------------------------

function print_plan(
    job,
    plan
)

    println()
    println("========================================")
    println("PRINT OPTIMISATION")
    println("========================================")

    println(
        "Pages:              ",
        job.pages
    )

    println(
        "Colour:             ",
        job.colour
    )

    println(
        "Optimised DPI:      ",
        plan.dpi
    )

    @printf(
        "Quality level:      %.2f\n",
        plan.quality
    )

    @printf(
        "Black ink:          %.3f ml\n",
        plan.estimated_black_ml
    )

    @printf(
        "Colour ink:         %.3f ml\n",
        plan.estimated_colour_ml
    )

    @printf(
        "Energy:             %.2f Wh\n",
        plan.estimated_energy_wh
    )

    println(
        "Duplex:             ",
        plan.duplex
    )

    @printf(
        "Optimisation score: %.3f\n",
        plan.score
    )
end


# ------------------------------------------------------------
# Example workload
# ------------------------------------------------------------

jobs = [

    PrintJob(
        20,
        false,
        0.35,
        0.0,
        0.45,
        10
    ),

    PrintJob(
        8,
        true,
        0.30,
        0.65,
        0.80,
        15
    ),

    PrintJob(
        2,
        true,
        0.10,
        0.95,
        1.0,
        30
    )
]


# ------------------------------------------------------------
# Run optimiser
# ------------------------------------------------------------

plans =
    optimise_queue(
        home_printer,
        jobs
    )


for i in eachindex(jobs)

    print_plan(
        jobs[i],
        plans[i]
    )

end
























#!/usr/bin/env julia

# ============================================================
# InkOpt.jl
#
# Printer Ink Optimisation Engine
#
# Goal:
#   Minimise estimated ink consumption while maintaining
#   acceptable visual quality.
#
# Input:
#   RGB image
#
# Output:
#   Optimised RGB image
#   Estimated ink usage
#   Ink savings
#
# Dependencies:
#   Pkg.add(["Images", "FileIO", "ImageIO", "ColorTypes"])
# ============================================================

using Images
using FileIO
using ImageIO
using ColorTypes
using Statistics
using Printf

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

struct InkConfig

    # Remove very faint colours.
    white_threshold::Float64

    # Reduce excessive saturation.
    saturation_limit::Float64

    # Maximum amount of black generation.
    max_black::Float64

    # Minimum printable density.
    minimum_density::Float64

    # Quality-preservation factor.
    quality_factor::Float64
end


const DEFAULT_CONFIG = InkConfig(
    0.97,      # white threshold
    0.82,      # saturation limit
    0.92,      # black limit
    0.015,     # minimum density
    0.97       # quality factor
)


# ------------------------------------------------------------
# RGB → CMYK
# ------------------------------------------------------------

function rgb_to_cmyk(r, g, b)

    k = 1.0 - max(r, g, b)

    if k >= 0.999999

        return (
            0.0,
            0.0,
            0.0,
            1.0
        )
    end

    c = (1.0 - r - k) / (1.0 - k)
    m = (1.0 - g - k) / (1.0 - k)
    y = (1.0 - b - k) / (1.0 - k)

    return (
        clamp(c, 0.0, 1.0),
        clamp(m, 0.0, 1.0),
        clamp(y, 0.0, 1.0),
        clamp(k, 0.0, 1.0)
    )
end


# ------------------------------------------------------------
# CMYK → RGB
# ------------------------------------------------------------

function cmyk_to_rgb(c, m, y, k)

    r = (1.0 - c) * (1.0 - k)
    g = (1.0 - m) * (1.0 - k)
    b = (1.0 - y) * (1.0 - k)

    return RGB(
        clamp(r, 0.0, 1.0),
        clamp(g, 0.0, 1.0),
        clamp(b, 0.0, 1.0)
    )
end


# ------------------------------------------------------------
# Perceived luminance
# ------------------------------------------------------------

@inline function luminance(r, g, b)

    return (
        0.2126 * r +
        0.7152 * g +
        0.0722 * b
    )
end


# ------------------------------------------------------------
# Saturation
# ------------------------------------------------------------

@inline function saturation(r, g, b)

    mx = max(r, g, b)
    mn = min(r, g, b)

    if mx == 0.0
        return 0.0
    end

    return (mx - mn) / mx
end


# ------------------------------------------------------------
# Ink cost model
# ------------------------------------------------------------

@inline function ink_cost(c, m, y, k)

    # Approximate relative deposition cost.
    #
    # Black is weighted slightly lower because a printer
    # normally gets more useful density from black ink.
    
    return (
        0.95c +
        0.95m +
        0.95y +
        0.72k
    )
end


# ------------------------------------------------------------
# Pixel optimiser
# ------------------------------------------------------------

function optimise_pixel(
    r,
    g,
    b,
    config::InkConfig
)

    # ----------------------------------------
    # Detect near-white pixels.
    # ----------------------------------------

    brightness =
        luminance(r, g, b)

    if brightness >= config.white_threshold

        return RGB(
            1.0,
            1.0,
            1.0
        )
    end


    # ----------------------------------------
    # Convert to CMYK.
    # ----------------------------------------

    c, m, y, k =
        rgb_to_cmyk(r, g, b)


    # ----------------------------------------
    # Suppress extremely light ink.
    # ----------------------------------------

    if c < config.minimum_density
        c = 0.0
    end

    if m < config.minimum_density
        m = 0.0
    end

    if y < config.minimum_density
        y = 0.0
    end

    if k < config.minimum_density
        k = 0.0
    end


    # ----------------------------------------
    # Saturation optimisation.
    # ----------------------------------------

    s = saturation(r, g, b)

    if s > config.saturation_limit

        reduction =
            config.saturation_limit / s

        c *= reduction
        m *= reduction
        y *= reduction
    end


    # ----------------------------------------
    # Black generation optimisation.
    # ----------------------------------------

    k =
        min(k, config.max_black)


    # ----------------------------------------
    # Preserve luminance.
    # ----------------------------------------

    original_luma =
        luminance(r, g, b)

    new_rgb =
        cmyk_to_rgb(
            c,
            m,
            y,
            k
        )

    new_luma =
        luminance(
            Float64(new_rgb.r),
            Float64(new_rgb.g),
            Float64(new_rgb.b)
        )


    # Correct luminance drift.
    if new_luma > 0.0

        correction =
            original_luma / new_luma

        rr =
            clamp(
                Float64(new_rgb.r) * correction,
                0.0,
                1.0
            )

        gg =
            clamp(
                Float64(new_rgb.g) * correction,
                0.0,
                1.0
            )

        bb =
            clamp(
                Float64(new_rgb.b) * correction,
                0.0,
                1.0
            )

        new_rgb =
            RGB(rr, gg, bb)
    end

    return new_rgb
end


# ------------------------------------------------------------
# Image optimisation
# ------------------------------------------------------------

function optimise_image(
    image,
    config::InkConfig = DEFAULT_CONFIG
)

    output =
        similar(image)

    height, width =
        size(image)

    for y in 1:height

        for x in 1:width

            pixel = image[y, x]

            r = Float64(red(pixel))
            g = Float64(green(pixel))
            b = Float64(blue(pixel))

            output[y, x] =
                optimise_pixel(
                    r,
                    g,
                    b,
                    config
                )
        end
    end

    return output
end


# ------------------------------------------------------------
# Estimate original ink usage
# ------------------------------------------------------------

function estimate_ink(image)

    total = 0.0

    height, width =
        size(image)

    for y in 1:height

        for x in 1:width

            p = image[y, x]

            r = Float64(red(p))
            g = Float64(green(p))
            b = Float64(blue(p))

            c, m, yy, k =
                rgb_to_cmyk(r, g, b)

            total +=
                ink_cost(
                    c,
                    m,
                    yy,
                    k
                )
        end
    end

    return total
end


# ------------------------------------------------------------
# Per-channel ink analysis
# ------------------------------------------------------------

function ink_statistics(image)

    c_total = 0.0
    m_total = 0.0
    y_total = 0.0
    k_total = 0.0

    pixels =
        length(image)

    for p in image

        r = Float64(red(p))
        g = Float64(green(p))
        b = Float64(blue(p))

        c, m, y, k =
            rgb_to_cmyk(
                r,
                g,
                b
            )

        c_total += c
        m_total += m
        y_total += y
        k_total += k
    end

    return (
        cyan = c_total / pixels,
        magenta = m_total / pixels,
        yellow = y_total / pixels,
        black = k_total / pixels
    )
end


# ------------------------------------------------------------
# Image quality estimate
# ------------------------------------------------------------

function quality_difference(
    original,
    optimised
)

    total = 0.0

    n =
        length(original)

    for i in eachindex(original)

        a = original[i]
        b = optimised[i]

        dr =
            Float64(red(a)) -
            Float64(red(b))

        dg =
            Float64(green(a)) -
            Float64(green(b))

        db =
            Float64(blue(a)) -
            Float64(blue(b))

        total +=
            sqrt(
                dr^2 +
                dg^2 +
                db^2
            )
    end

    return total / n
end


# ------------------------------------------------------------
# Optimisation report
# ------------------------------------------------------------

function report(
    original,
    optimised
)

    original_ink =
        estimate_ink(original)

    optimised_ink =
        estimate_ink(optimised)

    savings =
        if original_ink > 0

            100.0 *
            (1.0 -
             optimised_ink /
             original_ink)

        else
            0.0
        end

    quality =
        quality_difference(
            original,
            optimised
        )

    before =
        ink_statistics(
            original
        )

    after =
        ink_statistics(
            optimised
        )

    println()
    println("========================================")
    println("       PRINTER INK OPTIMISER")
    println("========================================")

    @printf(
        "Original ink index : %.4f\n",
        original_ink
    )

    @printf(
        "Optimised ink index: %.4f\n",
        optimised_ink
    )

    @printf(
        "Estimated savings  : %.2f %%\n",
        savings
    )

    @printf(
        "Quality difference : %.6f\n",
        quality
    )

    println()
    println("CHANNEL USAGE")
    println("----------------------------------------")

    @printf(
        "Cyan     %.4f → %.4f\n",
        before.cyan,
        after.cyan
    )

    @printf(
        "Magenta  %.4f → %.4f\n",
        before.magenta,
        after.magenta
    )

    @printf(
        "Yellow   %.4f → %.4f\n",
        before.yellow,
        after.yellow
    )

    @printf(
        "Black    %.4f → %.4f\n",
        before.black,
        after.black
    )

    println("========================================")
end


# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

function main()

    if length(ARGS) < 2

        println(
            "Usage:"
        )

        println(
            "  julia InkOpt.jl input.jpg output.png"
        )

        exit(1)
    end

    input =
        ARGS[1]

    output =
        ARGS[2]

    println(
        "Loading: ",
        input
    )

    image =
        load(input)

    println(
        "Pixels: ",
        length(image)
    )

    println(
        "Optimising ink usage..."
    )

    optimised =
        optimise_image(
            image
        )

    save(
        output,
        optimised
    )

    report(
        image,
        optimised
    )

    println()
    println(
        "Saved: ",
        output
    )
end


main()









