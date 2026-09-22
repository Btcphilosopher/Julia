module TelescopeAutoFocus

using Statistics
using LinearAlgebra
using Dates

export StarMeasurement,
       FocusSample,
       FocusModel,
       AutofocusConfig,
       AutofocusController,
       add_sample!,
       estimate_focus,
       autofocus_step!,
       temperature_compensation


# ============================================================
# STAR MEASUREMENT
# ============================================================

struct StarMeasurement

    x::Float64
    y::Float64

    flux::Float64

    fwhm_x::Float64
    fwhm_y::Float64

    eccentricity::Float64

    sharpness::Float64

end


# ============================================================
# FOCUS SAMPLE
# ============================================================

struct FocusSample

    focuser_position::Float64

    temperature::Float64

    hfr::Float64
    fwhm::Float64

    star_count::Int

    sharpness::Float64

    timestamp::DateTime

end


# ============================================================
# CONFIGURATION
# ============================================================

struct AutofocusConfig

    coarse_step::Int
    fine_step::Int

    coarse_range::Int
    fine_range::Int

    minimum_stars::Int

    minimum_temperature_change::Float64

    max_focus_move::Int

    smoothing::Float64

end


# ============================================================
# FOCUS MODEL
#
# The model approximates the focus curve:
#
#       quality
#          ^
#          |
#          |       *
#          |     *   *
#          |   *       *
#          | *           *
#          +-----------------> position
#                    ^
#                 optimum
# ============================================================

mutable struct FocusModel

    positions::Vector{Float64}

    qualities::Vector{Float64}

    temperatures::Vector{Float64}

    weights::Vector{Float64}

end


function FocusModel()

    return FocusModel(
        Float64[],
        Float64[],
        Float64[],
        Float64[]
    )

end


# ============================================================
# CONTROLLER
# ============================================================

mutable struct AutofocusController

    position::Float64

    target_position::Float64

    temperature::Float64

    last_temperature::Float64

    model::FocusModel

    samples::Vector{FocusSample}

    focusing::Bool

end


function AutofocusController(
    initial_position::Float64,
    temperature::Float64
)

    return AutofocusController(

        initial_position,
        initial_position,

        temperature,
        temperature,

        FocusModel(),

        FocusSample[],

        false
    )

end


# ============================================================
# STAR QUALITY
# ============================================================

function star_quality(
    star::StarMeasurement
)

    # Smaller FWHM is better.
    #
    # Higher sharpness is better.
    #
    # Lower eccentricity is generally preferable.

    geometric_fwhm =
        sqrt(
            star.fwhm_x *
            star.fwhm_y
        )

    fwhm_score =
        1.0 /
        max(
            geometric_fwhm,
            0.001
        )

    eccentricity_score =
        1.0 -
        clamp(
            star.eccentricity,
            0.0,
            1.0
        )

    return (

        0.55 * fwhm_score +

        0.30 * star.sharpness +

        0.15 * eccentricity_score

    )

end


# ============================================================
# IMAGE QUALITY
# ============================================================

function image_quality(
    stars::Vector{StarMeasurement}
)

    isempty(stars) &&
        return 0.0

    qualities =
        map(
            star_quality,
            stars
        )

    # Median is deliberately used rather than
    # the mean so that a cosmic ray or bad star
    # has less influence.

    return median(qualities)

end


# ============================================================
# HFR
# ============================================================

function calculate_hfr(
    stars::Vector{StarMeasurement}
)

    isempty(stars) &&
        return Inf

    values = Float64[]

    for star in stars

        diameter =
            sqrt(
                star.fwhm_x *
                star.fwhm_y
            )

        push!(
            values,
            diameter
        )

    end

    return median(values)

end


# ============================================================
# FWHM
# ============================================================

function calculate_fwhm(
    stars::Vector{StarMeasurement}
)

    isempty(stars) &&
        return Inf

    values =
        [
            sqrt(
                s.fwhm_x *
                s.fwhm_y
            )
            for s in stars
        ]

    return median(values)

end


# ============================================================
# ADD FOCUS SAMPLE
# ============================================================

function add_sample!(
    controller::AutofocusController,

    stars::Vector{StarMeasurement},

    temperature::Float64
)

    quality =
        image_quality(stars)

    hfr =
        calculate_hfr(stars)

    fwhm =
        calculate_fwhm(stars)

    sample =
        FocusSample(

            controller.position,

            temperature,

            hfr,
            fwhm,

            length(stars),

            quality,

            now()
        )

    push!(
        controller.samples,
        sample
    )

    push!(
        controller.model.positions,
        controller.position
    )

    push!(
        controller.model.qualities,
        quality
    )

    push!(
        controller.model.temperatures,
        temperature
    )

    push!(
        controller.model.weights,
        1.0
    )

    return sample

end


# ============================================================
# PARABOLIC FOCUS MODEL
#
# Real telescope focus curves are often approximately
# V-shaped / parabolic around best focus.
# ============================================================

function fit_focus_curve(
    model::FocusModel
)

    n =
        length(model.positions)

    n < 3 &&
        return nothing

    x =
        model.positions

    y =
        model.qualities

    X =
        hcat(
            ones(n),
            x,
            x .^ 2
        )

    coefficients =
        X \ y

    return coefficients

end


# ============================================================
# PARABOLA OPTIMUM
# ============================================================

function parabola_optimum(
    coefficients
)

    a =
        coefficients[3]

    b =
        coefficients[2]

    abs(a) < 1e-12 &&
        return nothing

    optimum =
        -b / (2a)

    return optimum

end


# ============================================================
# ML-STYLE FOCUS ESTIMATE
#
# Combines:
#
#   1. measured samples
#   2. parabolic fit
#   3. local weighted interpolation
#
# rather than trusting one noisy measurement.
# ============================================================

function estimate_focus(
    controller::AutofocusController
)

    model =
        controller.model

    if length(model.positions) < 3

        return controller.position

    end

    coefficients =
        fit_focus_curve(model)

    coefficients === nothing &&
        return controller.position

    parabola =
        parabola_optimum(coefficients)

    parabola === nothing &&
        return controller.position

    minimum_position =
        minimum(model.positions)

    maximum_position =
        maximum(model.positions)

    return clamp(
        parabola,
        minimum_position,
        maximum_position
    )

end


# ============================================================
# LOCAL WEIGHTED ESTIMATE
# ============================================================

function weighted_focus_estimate(
    controller::AutofocusController
)

    model =
        controller.model

    isempty(model.positions) &&
        return controller.position

    weights =
        model.weights

    # Focus samples with stronger image quality
    # receive more influence.

    effective_weights =
        weights .*
        (
            model.qualities .-
            minimum(model.qualities) .+
            1e-6
        )

    denominator =
        sum(effective_weights)

    denominator <= 0 &&
        return controller.position

    return sum(
        model.positions .*
        effective_weights
    ) / denominator

end


# ============================================================
# ROBUST FOCUS ESTIMATE
# ============================================================

function robust_focus_estimate(
    controller::AutofocusController
)

    parabola =
        estimate_focus(controller)

    weighted =
        weighted_focus_estimate(controller)

    # Give the local model more influence.

    return (
        0.70 * parabola +
        0.30 * weighted
    )

end


# ============================================================
# TEMPERATURE COMPENSATION
# ============================================================

function temperature_compensation(
    controller::AutofocusController
)

    model =
        controller.model

    n =
        length(model.temperatures)

    n < 3 &&
        return 0.0

    positions =
        model.positions

    temperatures =
        model.temperatures

    X =
        hcat(
            ones(n),
            temperatures
        )

    coefficients =
        X \ positions

    slope =
        coefficients[2]

    delta_temperature =
        controller.temperature -
        controller.last_temperature

    return slope *
           delta_temperature

end


# ============================================================
# MOVE CALCULATION
# ============================================================

function calculate_focus_move(
    controller::AutofocusController,
    config::AutofocusConfig
)

    target =
        robust_focus_estimate(
            controller
        )

    temperature_delta =
        temperature_compensation(
            controller
        )

    target +=
        temperature_delta

    movement =
        target -
        controller.position

    movement =
        clamp(
            movement,
            -config.max_focus_move,
            config.max_focus_move
        )

    return movement

end


# ============================================================
# AUTOFOCUS STEP
# ============================================================

function autofocus_step!(
    controller::AutofocusController,

    stars::Vector{StarMeasurement},

    temperature::Float64,

    config::AutofocusConfig
)

    controller.temperature =
        temperature

    # Reject frames with too few stars.

    if length(stars) <
       config.minimum_stars

        return (
            action = :wait,
            movement = 0.0,
            reason = :insufficient_stars
        )

    end


    add_sample!(
        controller,
        stars,
        temperature
    )


    # Need several measurements before
    # fitting a focus curve.

    if length(controller.samples) < 3

        return (
            action = :sample,
            movement = config.coarse_step,
            reason = :building_model
        )

    end


    movement =
        calculate_focus_move(
            controller,
            config
        )


    # Prevent tiny oscillations.

    if abs(movement) < 0.5

        controller.target_position =
            controller.position

        controller.focusing =
            false

        return (
            action = :locked,
            movement = 0.0,
            reason = :optimal_focus
        )

    end


    controller.target_position =
        controller.position +
        movement

    controller.focusing =
        true

    return (
        action = :move,
        movement = movement,
        target = controller.target_position,
        reason = :optimising
    )

end


# ============================================================
# FOCUS CONFIRMATION
# ============================================================

function focus_confirmed!(
    controller::AutofocusController
)

    controller.position =
        controller.target_position

    controller.focusing =
        false

    return controller.position

end


# ============================================================
# FOCUS QUALITY TREND
# ============================================================

function focus_trend(
    controller::AutofocusController
)

    n =
        length(
            controller.samples
        )

    n < 2 &&
        return 0.0

    previous =
        controller.samples[n-1].sharpness

    current =
        controller.samples[n].sharpness

    return current - previous

end


# ============================================================
# AUTOMATIC REFOCUS DECISION
# ============================================================

function should_refocus(
    controller::AutofocusController,
    temperature_change::Float64,
    quality_threshold::Float64
)

    if abs(
        temperature_change
    ) > 0.5

        return true
    end

    if isempty(
        controller.samples
    )

        return true
    end

    quality =
        controller.samples[end].sharpness

    return quality <
           quality_threshold

end


end
