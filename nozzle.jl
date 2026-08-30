module NozzleMeasurement

using LinearAlgebra
using Statistics
using Printf

export NozzleConfig,
       Measurement,
       MeasurementResult,
       Calibration,
       calibrate,
       measure_nozzle,
       batch_measure,
       detect_edge,
       calculate_diameter,
       calculate_concentricity,
       calculate_roundness,
       calculate_taper,
       calculate_flow_area,
       quality_check,
       print_result


# ============================================================
# CONFIGURATION
# ============================================================

struct NozzleConfig
    nominal_diameter_mm::Float64
    diameter_tolerance_mm::Float64

    nominal_length_mm::Float64
    length_tolerance_mm::Float64

    max_roundness_error_mm::Float64
    max_concentricity_error_mm::Float64
    max_taper_mm::Float64

    min_measurements::Int
end


struct Calibration
    scale_x_mm_per_pixel::Float64
    scale_y_mm_per_pixel::Float64
    offset_x_mm::Float64
    offset_y_mm::Float64

    measurement_uncertainty_mm::Float64
end


struct Measurement
    x_mm::Float64
    y_mm::Float64
    z_mm::Float64
end


struct MeasurementResult
    diameter_mm::Float64
    diameter_min_mm::Float64
    diameter_max_mm::Float64

    center_x_mm::Float64
    center_y_mm::Float64

    roundness_mm::Float64
    concentricity_mm::Float64
    taper_mm::Float64

    cross_section_area_mm2::Float64

    point_count::Int

    diameter_pass::Bool
    roundness_pass::Bool
    concentricity_pass::Bool
    taper_pass::Bool

    overall_pass::Bool
end


# ============================================================
# CALIBRATION
# ============================================================

function calibrate(
    reference_pixels::Vector{Tuple{Float64,Float64}},
    reference_mm::Vector{Tuple{Float64,Float64}};
    measurement_uncertainty_mm=0.01
)

    length(reference_pixels) ==
    length(reference_mm) ||
        throw(
            ArgumentError(
                "Reference point counts must match"
            )
        )

    length(reference_pixels) >= 2 ||
        throw(
            ArgumentError(
                "At least two calibration points required"
            )
        )

    px = [p[1] for p in reference_pixels]
    py = [p[2] for p in reference_pixels]

    mx = [p[1] for p in reference_mm]
    my = [p[2] for p in reference_mm]

    dx_pixels =
        maximum(px) - minimum(px)

    dy_pixels =
        maximum(py) - minimum(py)

    dx_mm =
        maximum(mx) - minimum(mx)

    dy_mm =
        maximum(my) - minimum(my)

    dx_pixels > 0 ||
        throw(ArgumentError("Invalid X calibration"))

    dy_pixels > 0 ||
        throw(ArgumentError("Invalid Y calibration"))

    sx =
        dx_mm / dx_pixels

    sy =
        dy_mm / dy_pixels

    ox =
        mean(mx) -
        sx * mean(px)

    oy =
        mean(my) -
        sy * mean(py)

    Calibration(
        sx,
        sy,
        ox,
        oy,
        Float64(measurement_uncertainty_mm)
    )
end


# ============================================================
# PIXEL → MILLIMETRE CONVERSION
# ============================================================

function pixel_to_mm(
    x,
    y,
    calibration::Calibration
)

    return (
        x * calibration.scale_x_mm_per_pixel +
        calibration.offset_x_mm,

        y * calibration.scale_y_mm_per_pixel +
        calibration.offset_y_mm
    )
end


# ============================================================
# BASIC GEOMETRY
# ============================================================

function point_distance(
    a::Measurement,
    b::Measurement
)

    sqrt(
        (a.x_mm - b.x_mm)^2 +
        (a.y_mm - b.y_mm)^2 +
        (a.z_mm - b.z_mm)^2
    )
end


function radial_distance(
    point::Measurement,
    cx::Float64,
    cy::Float64
)

    sqrt(
        (point.x_mm - cx)^2 +
        (point.y_mm - cy)^2
    )
end


# ============================================================
# EDGE DETECTION
# ============================================================

"""
Detect nozzle edges from a 1D intensity profile.

Uses a gradient-based edge detector.

Returns:
    left_edge
    right_edge
"""
function detect_edge(
    intensity::AbstractVector{<:Real};
    threshold=nothing
)

    length(intensity) >= 5 ||
        throw(
            ArgumentError(
                "Intensity profile too short"
            )
        )

    profile =
        Float64.(intensity)

    gradient =
        zeros(Float64, length(profile))

    for i in 2:length(profile)-1

        gradient[i] =
            (
                profile[i+1] -
                profile[i-1]
            ) / 2
    end

    maximum_gradient =
        maximum(gradient)

    minimum_gradient =
        minimum(gradient)

    if threshold === nothing

        threshold =
            0.25 *
            max(
                abs(maximum_gradient),
                abs(minimum_gradient)
            )
    end

    left_edge = nothing
    right_edge = nothing

    # Positive edge
    for i in eachindex(gradient)

        if gradient[i] > threshold

            left_edge = i
            break
        end
    end

    # Negative edge
    for i in reverse(eachindex(gradient))

        if gradient[i] < -threshold

            right_edge = i
            break
        end
    end

    return left_edge, right_edge
end


# ============================================================
# CIRCLE FITTING
# ============================================================

"""
Algebraic least-squares circle fit.

Returns:

    cx
    cy
    radius
"""
function fit_circle(
    points::Vector{Measurement}
)

    n = length(points)

    n >= 3 ||
        throw(
            ArgumentError(
                "At least three points required"
            )
        )

    A =
        zeros(Float64, n, 3)

    b =
        zeros(Float64, n)

    for i in 1:n

        x = points[i].x_mm
        y = points[i].y_mm

        A[i,1] = 2x
        A[i,2] = 2y
        A[i,3] = 1

        b[i] =
            x^2 + y^2
    end

    solution =
        A \ b

    cx = solution[1]
    cy = solution[2]

    c =
        solution[3]

    radius =
        sqrt(
            c +
            cx^2 +
            cy^2
        )

    return cx, cy, radius
end


# ============================================================
# DIAMETER
# ============================================================

function calculate_diameter(
    points::Vector{Measurement}
)

    cx, cy, radius =
        fit_circle(points)

    radii = [
        radial_distance(
            p,
            cx,
            cy
        )
        for p in points
    ]

    diameter =
        2 * mean(radii)

    diameter_min =
        2 * minimum(radii)

    diameter_max =
        2 * maximum(radii)

    return (
        diameter,
        diameter_min,
        diameter_max,
        cx,
        cy,
        radii
    )
end


# ============================================================
# ROUNDNESS
# ============================================================

function calculate_roundness(
    radii::Vector{Float64}
)

    isempty(radii) &&
        throw(
            ArgumentError(
                "No radial measurements"
            )
        )

    maximum(radii) -
    minimum(radii)
end


# ============================================================
# CONCENTRICITY
# ============================================================

function calculate_concentricity(
    inner_points::Vector{Measurement},
    reference_cx::Float64,
    reference_cy::Float64
)

    cx, cy, _ =
        fit_circle(inner_points)

    center_offset =
        sqrt(
            (cx - reference_cx)^2 +
            (cy - reference_cy)^2
        )

    return center_offset
end


# ============================================================
# TAPER
# ============================================================

function calculate_taper(
    sections::Vector{
        Vector{Measurement}
    }
)

    length(sections) >= 2 ||
        throw(
            ArgumentError(
                "At least two sections required"
            )
        )

    diameters = Float64[]

    for section in sections

        d, _, _, _, _, _ =
            calculate_diameter(section)

        push!(
            diameters,
            d
        )
    end

    return maximum(diameters) -
           minimum(diameters)
end


# ============================================================
# FLOW AREA
# ============================================================

function calculate_flow_area(
    diameter_mm::Real
)

    π *
    (Float64(diameter_mm) / 2)^2
end


# ============================================================
# QUALITY CHECK
# ============================================================

function quality_check(
    config::NozzleConfig,
    diameter_mm::Float64,
    roundness_mm::Float64,
    concentricity_mm::Float64,
    taper_mm::Float64
)

    diameter_pass =
        abs(
            diameter_mm -
            config.nominal_diameter_mm
        ) <=
        config.diameter_tolerance_mm

    roundness_pass =
        roundness_mm <=
        config.max_roundness_error_mm

    concentricity_pass =
        concentricity_mm <=
        config.max_concentricity_error_mm

    taper_pass =
        taper_mm <=
        config.max_taper_mm

    overall =
        diameter_pass &&
        roundness_pass &&
        concentricity_pass &&
        taper_pass

    return (
        diameter_pass,
        roundness_pass,
        concentricity_pass,
        taper_pass,
        overall
    )
end


# ============================================================
# COMPLETE NOZZLE MEASUREMENT
# ============================================================

function measure_nozzle(
    points::Vector{Measurement},
    config::NozzleConfig;
    reference_center=nothing,
    sections=nothing
)

    length(points) >=
    config.min_measurements ||
        throw(
            ArgumentError(
                "Insufficient measurement points"
            )
        )

    # Diameter
    diameter,
    diameter_min,
    diameter_max,
    cx,
    cy,
    radii =
        calculate_diameter(points)

    # Roundness
    roundness =
        calculate_roundness(radii)

    # Concentricity
    concentricity = 0.0

    if reference_center !== nothing

        concentricity =
            sqrt(
                (cx - reference_center[1])^2 +
                (cy - reference_center[2])^2
            )
    end

    # Taper
    taper = 0.0

    if sections !== nothing

        taper =
            calculate_taper(
                sections
            )
    end

    # Flow area
    area =
        calculate_flow_area(
            diameter
        )

    # Quality
    diameter_pass,
    roundness_pass,
    concentricity_pass,
    taper_pass,
    overall_pass =
        quality_check(
            config,
            diameter,
            roundness,
            concentricity,
            taper
        )

    MeasurementResult(
        diameter,
        diameter_min,
        diameter_max,

        cx,
        cy,

        roundness,
        concentricity,
        taper,

        area,

        length(points),

        diameter_pass,
        roundness_pass,
        concentricity_pass,
        taper_pass,

        overall_pass
    )
end


# ============================================================
# BATCH MEASUREMENT
# ============================================================

function batch_measure(
    datasets::Vector{
        Vector{Measurement}
    },
    config::NozzleConfig
)

    results =
        MeasurementResult[]

    for points in datasets

        result =
            measure_nozzle(
                points,
                config
            )

        push!(
            results,
            result
        )
    end

    return results
end


# ============================================================
# STATISTICAL PROCESS CAPABILITY
# ============================================================

function process_statistics(
    results::Vector{MeasurementResult}
)

    diameters =
        [r.diameter_mm for r in results]

    roundness =
        [r.roundness_mm for r in results]

    return (
        diameter_mean = mean(diameters),
        diameter_std = std(diameters),

        diameter_min = minimum(diameters),
        diameter_max = maximum(diameters),

        roundness_mean = mean(roundness),
        roundness_std = std(roundness),

        pass_rate =
            mean(
                r.overall_pass
                for r in results
            )
    )
end


# ============================================================
# REPORT
# ============================================================

function print_result(
    result::MeasurementResult,
    config::NozzleConfig
)

    println()
    println(
        "======================================================"
    )

    println(
        "              NOZZLE MEASUREMENT"
    )

    println(
        "======================================================"
    )

    @printf(
        "Diameter:              %.4f mm\n",
        result.diameter_mm
    )

    @printf(
        "Minimum diameter:      %.4f mm\n",
        result.diameter_min_mm
    )

    @printf(
        "Maximum diameter:      %.4f mm\n",
        result.diameter_max_mm
    )

    @printf(
        "Centre X:              %.4f mm\n",
        result.center_x_mm
    )

    @printf(
        "Centre Y:              %.4f mm\n",
        result.center_y_mm
    )

    @printf(
        "Roundness error:       %.4f mm\n",
        result.roundness_mm
    )

    @printf(
        "Concentricity error:   %.4f mm\n",
        result.concentricity_mm
    )

    @printf(
        "Taper:                 %.4f mm\n",
        result.taper_mm
    )

    @printf(
        "Flow area:             %.4f mm²\n",
        result.cross_section_area_mm2
    )

    println()
    println(
        "QUALITY CONTROL"
    )

    println(
        "Diameter:              ",
        result.diameter_pass ?
        "PASS" : "FAIL"
    )

    println(
        "Roundness:             ",
        result.roundness_pass ?
        "PASS" : "FAIL"
    )

    println(
        "Concentricity:         ",
        result.concentricity_pass ?
        "PASS" : "FAIL"
    )

    println(
        "Taper:                 ",
        result.taper_pass ?
        "PASS" : "FAIL"
    )

    println()

    println(
        "OVERALL:               ",
        result.overall_pass ?
        "PASS" : "FAIL"
    )

    println(
        "======================================================"
    )

    return nothing
end


# ============================================================
# SYNTHETIC TEST DATA
# ============================================================

function generate_test_nozzle(
    diameter_mm::Float64;
    center_x=0.0,
    center_y=0.0,
    points=360,
    noise_mm=0.01,
    ovality_mm=0.0
)

    radius =
        diameter_mm / 2

    measurements =
        Measurement[]

    for i in 0:points-1

        θ =
            2π *
            i /
            points

        # Ellipticity / ovality
        r =
            radius +
            (ovality_mm / 2) *
            cos(2θ)

        x =
            center_x +
            r * cos(θ) +
            randn() * noise_mm

        y =
            center_y +
            r * sin(θ) +
            randn() * noise_mm

        push!(
            measurements,
            Measurement(
                x,
                y,
                0.0
            )
        )
    end

    return measurements
end


export generate_test_nozzle,
       process_statistics

end # module


# ============================================================
# EXAMPLE
# ============================================================

using .NozzleMeasurement

config = NozzleConfig(
    10.000,    # nominal diameter
    0.050,     # diameter tolerance

    25.000,    # nominal length
    0.100,     # length tolerance

    0.030,     # max roundness error
    0.040,     # max concentricity
    0.050,     # max taper

    30         # minimum measurements
)

# Generate synthetic measurement data
points =
    generate_test_nozzle(
        10.015;
        center_x=0.012,
        center_y=-0.008,
        points=360,
        noise_mm=0.002,
        ovality_mm=0.012
    )

# Measure
result =
    measure_nozzle(
        points,
        config
    )

# Print inspection report
print_result(
    result,
    config
)
