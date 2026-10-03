```julia
module TouchscreenLatency

using Statistics
using Dates

# ============================================================
# TOUCHSCREEN LATENCY INTELLIGENCE
#
# Julia numerical layer for analysing:
#
#   touch sensor
#        ↓
#   digitiser timestamp
#        ↓
#   OS event timestamp
#        ↓
#   application receipt
#        ↓
#   rendering
#        ↓
#   display presentation
#
# Julia does not directly drive UIKit/Core Animation.
# Swift should collect timestamps and apply the resulting
# policy.
# ============================================================


# ============================================================
# ENUMERATIONS
# ============================================================

@enum TouchPhase begin
    TOUCH_BEGAN
    TOUCH_MOVED
    TOUCH_ENDED
    TOUCH_CANCELLED
end

@enum LatencyQuality begin
    EXCELLENT
    GOOD
    ACCEPTABLE
    DEGRADED
    POOR
end

@enum LatencySource begin
    SENSOR
    EVENT_PIPELINE
    MAIN_THREAD
    RENDERING
    DISPLAY
    UNKNOWN
end


# ============================================================
# RAW TOUCH SAMPLE
# ============================================================

struct TouchSample
    id::UInt64

    phase::TouchPhase

    sensor_time_ns::Int64
    event_time_ns::Int64
    application_time_ns::Int64
    render_submit_time_ns::Int64
    presentation_time_ns::Int64

    x::Float64
    y::Float64

    pressure::Float64

    predicted::Bool
end


# ============================================================
# LATENCY MEASUREMENT
# ============================================================

struct TouchLatencyMeasurement

    sensor_to_event_ms::Float64
    event_to_app_ms::Float64
    app_to_render_ms::Float64
    render_to_display_ms::Float64

    total_latency_ms::Float64

    jitter_ms::Float64

    source::LatencySource
end


# ============================================================
# DEVICE TOUCH PROFILE
# ============================================================

struct TouchDeviceProfile

    nominal_touch_rate_hz::Float64
    display_refresh_rate_hz::Float64

    target_latency_ms::Float64

    warning_latency_ms::Float64
    critical_latency_ms::Float64
end


const DEFAULT_PROFILE =
    TouchDeviceProfile(
        120.0,
        120.0,
        10.0,
        16.67,
        25.0
    )


# ============================================================
# LATENCY HISTORY
# ============================================================

mutable struct LatencyHistory

    measurements::Vector{TouchLatencyMeasurement}

    function LatencyHistory()

        new(
            TouchLatencyMeasurement[]
        )
    end
end


function add_measurement!(
    history::LatencyHistory,
    measurement::TouchLatencyMeasurement
)

    push!(
        history.measurements,
        measurement
    )

    # Keep bounded rolling history.
    if length(history.measurements) > 100_000

        deleteat!(
            history.measurements,
            1
        )
    end

    return history
end


# ============================================================
# CONVERT RAW TOUCH SAMPLE
# ============================================================

function analyse_sample(
    sample::TouchSample
)

    sensor_event =
        (
            sample.event_time_ns -
            sample.sensor_time_ns
        ) / 1e6

    event_app =
        (
            sample.application_time_ns -
            sample.event_time_ns
        ) / 1e6

    app_render =
        (
            sample.render_submit_time_ns -
            sample.application_time_ns
        ) / 1e6

    render_display =
        (
            sample.presentation_time_ns -
            sample.render_submit_time_ns
        ) / 1e6

    total =
        (
            sample.presentation_time_ns -
            sample.sensor_time_ns
        ) / 1e6

    source =
        if sensor_event > 5.0

            SENSOR

        elseif event_app > 5.0

            EVENT_PIPELINE

        elseif app_render > 8.0

            MAIN_THREAD

        elseif render_display > 12.0

            DISPLAY

        else

            UNKNOWN
        end

    return TouchLatencyMeasurement(
        sensor_event,
        event_app,
        app_render,
        render_display,
        total,
        0.0,
        source
    )
end


# ============================================================
# JITTER
# ============================================================

function calculate_jitter(
    history::LatencyHistory;
    window::Int = 100
)

    measurements =
        history.measurements

    length(measurements) < 3 &&
        return 0.0

    first_index =
        max(
            1,
            length(measurements) - window + 1
        )

    values =
        [
            m.total_latency_ms
            for m in measurements[first_index:end]
        ]

    return std(values)
end


# ============================================================
# MEDIAN LATENCY
# ============================================================

function median_latency(
    history::LatencyHistory;
    window::Int = 100
)

    measurements =
        history.measurements

    isempty(measurements) &&
        return 0.0

    first_index =
        max(
            1,
            length(measurements) - window + 1
        )

    values =
        [
            m.total_latency_ms
            for m in measurements[first_index:end]
        ]

    return median(values)
end


# ============================================================
# PERCENTILES
# ============================================================

function percentile(
    values::Vector{Float64},
    p::Float64
)

    isempty(values) &&
        return 0.0

    sorted =
        sort(values)

    index =
        clamp(
            ceil(Int, p * length(sorted)),
            1,
            length(sorted)
        )

    return sorted[index]
end


function latency_percentiles(
    history::LatencyHistory;
    window::Int = 1000
)

    measurements =
        history.measurements

    isempty(measurements) &&
        return (
            p50 = 0.0,
            p90 = 0.0,
            p95 = 0.0,
            p99 = 0.0
        )

    first_index =
        max(
            1,
            length(measurements) - window + 1
        )

    values =
        [
            m.total_latency_ms
            for m in measurements[first_index:end]
        ]

    return (
        p50 = percentile(values, 0.50),
        p90 = percentile(values, 0.90),
        p95 = percentile(values, 0.95),
        p99 = percentile(values, 0.99)
    )
end


# ============================================================
# LATENCY QUALITY
# ============================================================

function latency_quality(
    latency_ms::Float64,
    profile::TouchDeviceProfile
)

    if latency_ms <= profile.target_latency_ms

        return EXCELLENT

    elseif latency_ms <= profile.warning_latency_ms

        return GOOD

    elseif latency_ms <= 20.0

        return ACCEPTABLE

    elseif latency_ms <= profile.critical_latency_ms

        return DEGRADED

    else

        return POOR
    end
end


# ============================================================
# FRAME BUDGET
# ============================================================

function frame_budget_ms(
    refresh_rate_hz::Float64
)

    refresh_rate_hz <= 0 &&
        return Inf

    return 1000.0 /
        refresh_rate_hz
end


# ============================================================
# DISPLAY QUANTISATION
#
# A touch event may wait for the next frame.
# ============================================================

function estimated_frame_wait_ms(
    refresh_rate_hz::Float64
)

    frame =
        frame_budget_ms(
            refresh_rate_hz
        )

    # Average phase wait ≈ half a frame.
    return frame / 2.0
end


# ============================================================
# END-TO-END ESTIMATE
# ============================================================

function theoretical_touch_latency(
    profile::TouchDeviceProfile
)

    frame_wait =
        estimated_frame_wait_ms(
            profile.display_refresh_rate_hz
        )

    return (
        1000.0 /
        profile.nominal_touch_rate_hz
    ) +
    frame_wait
end


# ============================================================
# LATENCY BREAKDOWN
# ============================================================

struct LatencyBreakdown

    sensor::Float64
    event_pipeline::Float64
    application::Float64
    rendering::Float64
    display::Float64
    total::Float64
end


function breakdown(
    history::LatencyHistory;
    window::Int = 1000
)

    ms =
        history.measurements

    isempty(ms) &&
        return LatencyBreakdown(
            0, 0, 0, 0, 0, 0
        )

    first_index =
        max(
            1,
            length(ms) - window + 1
        )

    values =
        ms[first_index:end]

    return LatencyBreakdown(

        median([
            m.sensor_to_event_ms
            for m in values
        ]),

        median([
            m.event_to_app_ms
            for m in values
        ]),

        median([
            m.app_to_render_ms
            for m in values
        ]),

        median([
            m.render_to_display_ms
            for m in values
        ]),

        median([
            m.total_latency_ms
            for m in values
        ])
    )
end


# ============================================================
# BOTTLENECK DETECTION
# ============================================================

struct LatencyBottleneck

    source::LatencySource

    average_latency_ms::Float64

    percentage_of_total::Float64

    severity::LatencyQuality

    recommendation::String
end


function detect_bottleneck(
    history::LatencyHistory
)

    b =
        breakdown(history)

    components = [
        (SENSOR, b.sensor),
        (EVENT_PIPELINE, b.event_pipeline),
        (MAIN_THREAD, b.application),
        (RENDERING, b.rendering),
        (DISPLAY, b.display)
    ]

    total =
        max(
            b.total,
            0.001
        )

    source, latency =
        findmax(
            x -> x[2],
            components
        )

    percentage =
        latency /
        total *
        100.0

    quality =
        if percentage > 50
            POOR
        elseif percentage > 30
            DEGRADED
        elseif percentage > 20
            ACCEPTABLE
        else
            GOOD
        end

    recommendation =
        if source == SENSOR

            "Investigate touch sampling and digitiser timing."

        elseif source == EVENT_PIPELINE

            "Reduce event dispatch and queue latency."

        elseif source == MAIN_THREAD

            "Reduce main-thread work and UI contention."

        elseif source == RENDERING

            "Reduce rendering workload and frame stalls."

        elseif source == DISPLAY

            "Investigate frame scheduling or display cadence."

        else

            "No dominant bottleneck identified."
        end

    return LatencyBottleneck(
        source,
        latency,
        percentage,
        quality,
        recommendation
    )
end


# ============================================================
# SPIKE DETECTION
# ============================================================

struct LatencySpike

    timestamp_index::Int

    latency_ms::Float64

    deviation_ms::Float64

    severity::LatencyQuality
end


function detect_spikes(
    history::LatencyHistory;
    sigma_threshold::Float64 = 3.0
)

    ms =
        history.measurements

    length(ms) < 10 &&
        return LatencySpike[]

    values =
        [
            m.total_latency_ms
            for m in ms
        ]

    μ =
        median(values)

    σ =
        std(values)

    spikes =
        LatencySpike[]

    for (i, value) in enumerate(values)

        deviation =
            value - μ

        if σ > 0 &&
           deviation > sigma_threshold * σ

            quality =
                if value > 25
                    POOR
                elseif value > 16.67
                    DEGRADED
                else
                    ACCEPTABLE
                end

            push!(
                spikes,
                LatencySpike(
                    i,
                    value,
                    deviation,
                    quality
                )
            )
        end
    end

    return spikes
end


# ============================================================
# MAIN-THREAD LATENCY ANALYSIS
# ============================================================

function main_thread_pressure(
    history::LatencyHistory
)

    isempty(history.measurements) &&
        return 0.0

    app_latency =
        [
            m.event_to_app_ms
            for m in history.measurements
        ]

    return mean(app_latency)
end


# ============================================================
# TOUCH-TO-DISPLAY SCORE
# ============================================================

function responsiveness_score(
    history::LatencyHistory,
    profile::TouchDeviceProfile
)

    isempty(history.measurements) &&
        return 0.0

    latency =
        median_latency(history)

    jitter =
        calculate_jitter(history)

    latency_score =
        clamp(
            100.0 *
            (
                1.0 -
                latency /
                profile.critical_latency_ms
            ),
            0.0,
            100.0
        )

    jitter_score =
        clamp(
            100.0 *
            (
                1.0 -
                jitter /
                10.0
            ),
            0.0,
            100.0
        )

    return (
        0.75 * latency_score +
        0.25 * jitter_score
    )
end


# ============================================================
# ADAPTIVE TOUCH POLICY
# ============================================================

struct TouchPolicy

    touch_priority::Int

    preferred_refresh_rate::Float64

    animation_scale::Float64

    prediction_enabled::Bool

    aggressive_frame_scheduling::Bool

    reduce_background_work::Bool
end


function adaptive_policy(
    history::LatencyHistory,
    profile::TouchDeviceProfile
)

    latency =
        median_latency(history)

    jitter =
        calculate_jitter(history)

    if latency <= 10.0 &&
       jitter <= 2.0

        return TouchPolicy(
            10,
            profile.display_refresh_rate_hz,
            1.0,
            true,
            false,
            false
        )

    elseif latency <= 16.67

        return TouchPolicy(
            10,
            profile.display_refresh_rate_hz,
            1.0,
            true,
            true,
            true
        )

    elseif latency <= 25.0

        return TouchPolicy(
            10,
            profile.display_refresh_rate_hz,
            0.85,
            true,
            true,
            true
        )

    else

        return TouchPolicy(
            10,
            profile.display_refresh_rate_hz,
            0.70,
            true,
            true,
            true
        )
    end
end


# ============================================================
# TOUCH PREDICTION QUALITY
# ============================================================

struct PredictionStatistics

    total_predictions::Int
    predicted_events::Int

    prediction_ratio::Float64

    average_displacement::Float64
end


function prediction_statistics(
    samples::Vector{TouchSample}
)

    isempty(samples) &&
        return PredictionStatistics(
            0,
            0,
            0.0,
            0.0
        )

    predicted =
        count(
            s -> s.predicted,
            samples
        )

    return PredictionStatistics(
        length(samples),
        predicted,
        predicted / length(samples),
        0.0
    )
end


# ============================================================
# LATENCY TREND
# ============================================================

struct LatencyTrend

    slope_ms_per_sample::Float64

    improving::Bool

    degrading::Bool
end


function latency_trend(
    history::LatencyHistory;
    window::Int = 500
)

    ms =
        history.measurements

    length(ms) < 10 &&
        return LatencyTrend(
            0.0,
            false,
            false
        )

    first_index =
        max(
            1,
            length(ms) - window + 1
        )

    values =
        [
            m.total_latency_ms
            for m in ms[first_index:end]
        ]

    x =
        collect(
            1:length(values)
        )

    xmean =
        mean(x)

    ymean =
        mean(values)

    denominator =
        sum(
            (x .- xmean).^2
        )

    denominator == 0 &&
        return LatencyTrend(
            0.0,
            false,
            false
        )

    slope =
        sum(
            (x .- xmean) .*
            (values .- ymean)
        ) / denominator

    return LatencyTrend(
        slope,
        slope < -0.005,
        slope > 0.005
    )
end


# ============================================================
# COMPLETE ANALYSIS
# ============================================================

struct TouchscreenAnalysis

    median_latency_ms::Float64

    jitter_ms::Float64

    percentiles::NamedTuple

    responsiveness_score::Float64

    bottleneck::LatencyBottleneck

    spikes::Vector{LatencySpike}

    trend::LatencyTrend

    policy::TouchPolicy
end


function analyse_touchscreen(
    history::LatencyHistory,
    profile::TouchDeviceProfile =
        DEFAULT_PROFILE
)

    return TouchscreenAnalysis(

        median_latency(history),

        calculate_jitter(history),

        latency_percentiles(history),

        responsiveness_score(
            history,
            profile
        ),

        detect_bottleneck(
            history
        ),

        detect_spikes(
            history
        ),

        latency_trend(
            history
        ),

        adaptive_policy(
            history,
            profile
        )
    )
end


# ============================================================
# REPORT
# ============================================================

function print_report(
    analysis::TouchscreenAnalysis
)

    println()
    println("==============================================")
    println("       TOUCHSCREEN LATENCY INTELLIGENCE")
    println("==============================================")

    println(
        "Median latency: ",
        round(
            analysis.median_latency_ms,
            digits=2
        ),
        " ms"
    )

    println(
        "Jitter: ",
        round(
            analysis.jitter_ms,
            digits=2
        ),
        " ms"
    )

    println(
        "P50: ",
        round(
            analysis.percentiles.p50,
            digits=2
        ),
        " ms"
    )

    println(
        "P90: ",
        round(
            analysis.percentiles.p90,
            digits=2
        ),
        " ms"
    )

    println(
        "P95: ",
        round(
            analysis.percentiles.p95,
            digits=2
        ),
        " ms"
    )

    println(
        "P99: ",
        round(
            analysis.percentiles.p99,
            digits=2
        ),
        " ms"
    )

    println(
        "Responsiveness score: ",
        round(
            analysis.responsiveness_score,
            digits=1
        ),
        "/ 100"
    )

    println()
    println("BOTTLENECK")

    println(
        "Source: ",
        analysis.bottleneck.source
    )

    println(
        "Contribution: ",
        round(
            analysis.bottleneck.percentage_of_total,
            digits=1
        ),
        "%"
    )

    println(
        "Recommendation: ",
        analysis.bottleneck.recommendation
    )

    println()
    println("LATENCY SPIKES: ",
        length(analysis.spikes)
    )

    println(
        "Trend slope: ",
        round(
            analysis.trend.slope_ms_per_sample,
            digits=5
        ),
        " ms/sample"
    )

    println(
        "Improving: ",
        analysis.trend.improving
    )

    println(
        "Degrading: ",
        analysis.trend.degrading
    )

    println()
    println("ADAPTIVE POLICY")

    println(
        "Refresh rate: ",
        analysis.policy.preferred_refresh_rate,
        " Hz"
    )

    println(
        "Animation scale: ",
        analysis.policy.animation_scale
    )

    println(
        "Prediction: ",
        analysis.policy.prediction_enabled
    )

    println(
        "Aggressive scheduling: ",
        analysis.policy.aggressive_frame_scheduling
    )

    println(
        "Reduce background work: ",
        analysis.policy.reduce_background_work
    )

    println()
    println("==============================================")
end


# ============================================================
# SYNTHETIC TEST DATA
# ============================================================

function generate_demo_history(
    n::Int = 1000
)

    history =
        LatencyHistory()

    base =
        DateTime(
            2026,
            10,
            3,
            14,
            0,
            0
        )

    for i in 1:n

        # Simulated latency components.

        sensor =
            1.2 +
            0.2 * randn()

        event =
            1.5 +
            0.4 * randn()

        app =
            2.5 +
            0.8 * randn()

        render =
            2.0 +
            0.7 * randn()

        display =
            3.0 +
            0.8 * randn()

        # Occasional simulated frame stall.
        if i % 173 == 0

            app += 8.0

        end

        sensor =
            max(sensor, 0.1)

        event =
            max(event, 0.1)

        app =
            max(app, 0.1)

        render =
            max(render, 0.1)

        display =
            max(display, 0.1)

        total =
            sensor +
            event +
            app +
            render +
            display

        measurement =
            TouchLatencyMeasurement(
                sensor,
                event,
                app,
                render,
                total,
                0.0,
                UNKNOWN
            )

        add_measurement!(
            history,
            measurement
        )
    end

    return history
end


# ============================================================
# DEMO
# ============================================================

function demo()

    history =
        generate_demo_history()

    analysis =
        analyse_touchscreen(
            history
        )

    print_report(
        analysis
    )

    println()

    println(
        "Theoretical touch latency: ",
        round(
            theoretical_touch_latency(
                DEFAULT_PROFILE
            ),
            digits=2
        ),
        " ms"
    )

    return analysis
end


end # module
```

