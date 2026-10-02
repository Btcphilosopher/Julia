###############################################################################
# AIRPOD ANC — Adaptive Active Noise Cancellation
#
# Julia implementation of a real-time style FxLMS ANC controller.
#
# Model:
#
#   External Noise
#        │
#        ▼
#   [Reference Mic] ───────────────┐
#                                   │
#                                   ▼
#                            [Adaptive Filter]
#                                   │
#                                   ▼
#                            [ANC Speaker]
#                                   │
#                                   ▼
#                         [Secondary Acoustic Path]
#                                   │
#                                   ▼
#                          Cancellation Signal
#                                   │
#                                   ▼
#   [Error Mic] <──────────── Ear / Acoustic Environment
#
###############################################################################

using Random
using Statistics
using LinearAlgebra
using DSP
using Plots

###############################################################################
# CONFIGURATION
###############################################################################

const SAMPLE_RATE = 48_000.0       # AirPod-class audio sampling rate
const DURATION = 10.0              # simulation duration in seconds

const N = Int(round(SAMPLE_RATE * DURATION))

# Adaptive filter length
const FILTER_LENGTH = 256

# Secondary-path model length
const SECONDARY_LENGTH = 128

# LMS learning rate
const MU = 0.00005

# Small leakage factor improves numerical stability
const LEAKAGE = 0.000001

# Random seed for reproducibility
Random.seed!(42)

###############################################################################
# UTILITY FUNCTIONS
###############################################################################

"""
Generate white Gaussian noise.
"""
function white_noise(n)
    return randn(n)
end


"""
Generate a low-frequency coloured noise process.

The AirPod ANC problem is particularly interesting because real-world
environmental noise is usually not white noise.
"""
function coloured_noise(n; α=0.98)

    x = zeros(Float64, n)

    for i in 2:n
        x[i] = α * x[i-1] + randn()
    end

    x ./= maximum(abs.(x))

    return x
end


"""
Generate a synthetic aircraft/train/road-like noise signal.

This combines low-frequency stochastic noise with several tonal components.
"""
function generate_environmental_noise(n, fs)

    t = collect(0:n-1) ./ fs

    # Low frequency stochastic component
    low_noise = coloured_noise(n; α=0.995)

    # Tonal components
    tone1 = 0.30 .* sin.(2π .* 80.0 .* t)
    tone2 = 0.20 .* sin.(2π .* 120.0 .* t)
    tone3 = 0.12 .* sin.(2π .* 240.0 .* t)

    # Higher-frequency broadband component
    broadband = 0.10 .* randn(n)

    noise =
        0.65 .* low_noise .+
        tone1 .+
        tone2 .+
        tone3 .+
        broadband

    noise ./= maximum(abs.(noise))

    return noise
end


###############################################################################
# ACOUSTIC PATH MODELS
###############################################################################

"""
Create a simple model of the acoustic path between the ANC speaker and
the error microphone.

In a real AirPod this would represent:

    DAC → speaker → ear canal → microphone

The real system would identify this path experimentally.
"""
function create_secondary_path(length)

    s = zeros(Float64, length)

    # Approximate propagation delay
    s[8] = 0.85
    s[12] = -0.25
    s[18] = 0.12
    s[25] = 0.06
    s[32] = -0.04

    # Small resonances
    s[45] = 0.025
    s[60] = -0.015
    s[80] = 0.010

    return s
end


"""
Convolution without relying on external convolution routines.

Useful for understanding exactly what the ANC controller is doing.
"""
function apply_fir(x, h)

    n = length(x)
    m = length(h)

    y = zeros(Float64, n)

    for i in 1:n

        accumulator = 0.0

        max_k = min(i, m)

        for k in 1:max_k
            accumulator += h[k] * x[i-k+1]
        end

        y[i] = accumulator
    end

    return y
end


###############################################################################
# ADAPTIVE ANC CONTROLLER
###############################################################################

mutable struct FxLMSController

    # Adaptive ANC filter
    w::Vector{Float64}

    # Estimate of secondary acoustic path
    secondary_path::Vector{Float64}

    # Filtered reference signal
    x_filtered::Vector{Float64}

    # Reference signal history
    x_history::Vector{Float64}

    # Controller output history
    y_history::Vector{Float64}

    # Learning rate
    μ::Float64

    # Leakage
    leakage::Float64
end


"""
Create an FxLMS controller.
"""
function create_controller(filter_length,
                           secondary_path;
                           μ=MU,
                           leakage=LEAKAGE)

    return FxLMSController(

        zeros(filter_length),

        secondary_path,

        zeros(length(secondary_path)),

        zeros(filter_length),

        zeros(filter_length),

        μ,

        leakage
    )
end


###############################################################################
# SINGLE SAMPLE UPDATE
###############################################################################

"""
Process one sample through the adaptive ANC controller.

FxLMS:

1. Receive reference microphone signal x[n].
2. Generate anti-noise y[n].
3. Pass x[n] through estimated secondary path.
4. Measure residual error e[n].
5. Update adaptive coefficients.

Returns:

    y = ANC output
"""
function process_sample!(controller::FxLMSController,
                         x::Float64,
                         e::Float64)

    L = length(controller.w)

    # Shift reference history
    for i in L:-1:2
        controller.x_history[i] =
            controller.x_history[i-1]
    end

    controller.x_history[1] = x


    ###########################################################################
    # GENERATE CONTROL SIGNAL
    ###########################################################################

    y = 0.0

    for i in 1:L
        y += controller.w[i] *
             controller.x_history[i]
    end


    ###########################################################################
    # FILTERED-X
    #
    # The reference signal is passed through an estimate of the secondary
    # acoustic path before being used for the LMS update.
    ###########################################################################

    secondary_length =
        length(controller.secondary_path)

    filtered_x = 0.0

    for k in 1:secondary_length

        if k <= length(controller.x_history)

            filtered_x +=
                controller.secondary_path[k] *
                controller.x_history[k]

        end
    end


    ###########################################################################
    # UPDATE FILTER
    ###########################################################################

    for i in 1:L

        gradient =
            controller.μ *
            e *
            filtered_x *
            controller.x_history[i]

        controller.w[i] =
            (1.0 - controller.leakage) *
            controller.w[i] +
            gradient
    end


    return y
end


###############################################################################
# MORE ACCURATE FX-LMS IMPLEMENTATION
###############################################################################

"""
Full vector-based FxLMS controller.

This version explicitly maintains the filtered reference history.
"""
mutable struct AdvancedFxLMS

    w::Vector{Float64}

    secondary_path::Vector{Float64}

    x_history::Vector{Float64}

    filtered_history::Vector{Float64}

    μ::Float64

    leakage::Float64
end


function create_advanced_controller(filter_length,
                                     secondary_path;
                                     μ=MU,
                                     leakage=LEAKAGE)

    return AdvancedFxLMS(

        zeros(filter_length),

        secondary_path,

        zeros(filter_length),

        zeros(filter_length),

        μ,

        leakage
    )
end


"""
Generate anti-noise using current adaptive coefficients.
"""
function generate_antinoise!(controller::AdvancedFxLMS,
                             x::Float64)

    L = length(controller.w)

    # Shift reference history
    controller.x_history[2:end] =
        controller.x_history[1:end-1]

    controller.x_history[1] = x

    # Calculate adaptive filter output
    y = dot(
        controller.w,
        controller.x_history
    )

    return y
end


"""
Update the adaptive filter using the error microphone measurement.
"""
function update_controller!(controller::AdvancedFxLMS,
                            e::Float64)

    L = length(controller.w)
    M = length(controller.secondary_path)

    ###########################################################################
    # FILTER THE REFERENCE THROUGH SECONDARY PATH
    ###########################################################################

    filtered_x = 0.0

    max_k = min(M, L)

    for k in 1:max_k

        filtered_x +=
            controller.secondary_path[k] *
            controller.x_history[k]
    end


    ###########################################################################
    # SHIFT FILTERED-X HISTORY
    ###########################################################################

    controller.filtered_history[2:end] =
        controller.filtered_history[1:end-1]

    controller.filtered_history[1] =
        filtered_x


    ###########################################################################
    # FX-LMS COEFFICIENT UPDATE
    ###########################################################################

    for i in 1:L

        controller.w[i] *=
            (1.0 - controller.leakage)

        controller.w[i] +=
            controller.μ *
            e *
            controller.filtered_history[i]
    end

    return nothing
end


###############################################################################
# SIMULATE ANC SYSTEM
###############################################################################

"""
Run the complete ANC simulation.

Returns:

    reference       microphone/reference signal
    primary         acoustic noise at the ear
    antinoise       speaker-generated cancellation signal
    residual        remaining error signal
    controller      final adaptive controller
"""
function run_anc_simulation()

    println()
    println("==============================================================")
    println(" AIRPOD ADAPTIVE ANC SIMULATION")
    println("==============================================================")
    println()
    println("Sample rate:       $(SAMPLE_RATE) Hz")
    println("Duration:          $(DURATION) seconds")
    println("Samples:           $(N)")
    println("Adaptive taps:     $(FILTER_LENGTH)")
    println("Secondary taps:    $(SECONDARY_LENGTH)")
    println("Learning rate:     $(MU)")
    println()


    ###########################################################################
    # ENVIRONMENT
    ###########################################################################

    println("Generating environmental noise...")

    reference =
        generate_environmental_noise(
            N,
            SAMPLE_RATE
        )


    ###########################################################################
    # PRIMARY ACOUSTIC PATH
    #
    # This represents the path from the external world to the ear/error mic.
    ###########################################################################

    primary_path = zeros(64)

    primary_path[1] = 1.0
    primary_path[4] = 0.30
    primary_path[8] = -0.12
    primary_path[15] = 0.06


    primary_noise =
        apply_fir(
            reference,
            primary_path
        )


    ###########################################################################
    # SECONDARY PATH
    ###########################################################################

    println("Creating acoustic secondary-path model...")

    secondary_path =
        create_secondary_path(
            SECONDARY_LENGTH
        )


    ###########################################################################
    # CONTROLLER
    ###########################################################################

    controller =
        create_advanced_controller(
            FILTER_LENGTH,
            secondary_path
        )


    ###########################################################################
    # OUTPUT ARRAYS
    ###########################################################################

    antinoise = zeros(Float64, N)
    residual = zeros(Float64, N)

    ###########################################################################
    # SIMULATION
    ###########################################################################

    println("Running adaptive controller...")
    println()

    for n in 1:N

        #######################################################################
        # REFERENCE MICROPHONE
        #######################################################################

        x = reference[n]


        #######################################################################
        # ANC SPEAKER OUTPUT
        #######################################################################

        y =
            generate_antinoise!(
                controller,
                x
            )

        antinoise[n] = y


        #######################################################################
        # SIMULATE SECONDARY ACOUSTIC PATH
        #######################################################################

        secondary_output = 0.0

        for k in 1:length(secondary_path)

            idx = n - k + 1

            if idx >= 1

                secondary_output +=
                    secondary_path[k] *
                    antinoise[idx]
            end
        end


        #######################################################################
        # ERROR MICROPHONE
        #
        # Primary noise + anti-noise.
        #######################################################################

        residual[n] =
            primary_noise[n] +
            secondary_output


        #######################################################################
        # UPDATE ADAPTIVE FILTER
        #######################################################################

        update_controller!(
            controller,
            residual[n]
        )


        #######################################################################
        # PROGRESS
        #######################################################################

        if n % 48000 == 0

            seconds =
                n / SAMPLE_RATE

            current_rms =
                sqrt(
                    mean(
                        residual[max(1,n-47999):n].^2
                    )
                )

            println(
                "Time: $(round(seconds, digits=1)) s   " *
                "Residual RMS: $(round(current_rms, digits=5))"
            )
        end
    end


    println()
    println("ANC simulation complete.")
    println()

    return (
        reference=reference,
        primary=primary_noise,
        antinoise=antinoise,
        residual=residual,
        controller=controller
    )
end


###############################################################################
# PERFORMANCE ANALYSIS
###############################################################################

"""
Calculate RMS level.
"""
function rms(x)

    return sqrt(
        mean(x .^ 2)
    )
end


"""
Calculate approximate dB level.
"""
function db(x)

    value = rms(x)

    return 20.0 * log10(
        max(value, 1e-12)
    )
end


"""
Calculate noise reduction.
"""
function calculate_noise_reduction(primary,
                                   residual)

    before =
        rms(primary)

    after =
        rms(residual)

    reduction_db =
        20.0 *
        log10(
            before /
            max(after, 1e-12)
        )

    return reduction_db
end


###############################################################################
# FREQUENCY ANALYSIS
###############################################################################

"""
Calculate a simple FFT spectrum.
"""
function calculate_spectrum(signal,
                            fs)

    n = length(signal)

    # Use a manageable FFT segment
    segment_length =
        min(n, 65536)

    segment =
        signal[end-segment_length+1:end]

    # Hann window
    window =
        DSP.Windows.hann(segment_length)

    windowed =
        segment .* window

    spectrum =
        abs.(
            rfft(windowed)
        )

    frequencies =
        (0:length(spectrum)-1) .*
        fs /
        segment_length

    spectrum ./=
        maximum(spectrum)

    return frequencies, spectrum
end


###############################################################################
# VISUALISATION
###############################################################################

"""
Plot time-domain comparison.
"""
function plot_time_domain(results)

    seconds_to_plot = 0.10

    samples =
        Int(
            round(
                seconds_to_plot *
                SAMPLE_RATE
            )
        )

    t =
        (0:samples-1) ./ SAMPLE_RATE

    plot(
        t,
        results.primary[1:samples],
        label="Noise before ANC",
        xlabel="Time (s)",
        ylabel="Amplitude",
        title="AirPod ANC — Primary Noise"
    )

    plot!(
        t,
        results.residual[1:samples],
        label="Residual after ANC"
    )

    display(current())
end


"""
Plot frequency spectrum before/after ANC.
"""
function plot_frequency_domain(results)

    f1, s1 =
        calculate_spectrum(
            results.primary,
            SAMPLE_RATE
        )

    f2, s2 =
        calculate_spectrum(
            results.residual,
            SAMPLE_RATE
        )


    max_frequency = 2000.0

    idx1 =
        findall(
            f1 .<= max_frequency
        )

    idx2 =
        findall(
            f2 .<= max_frequency
        )


    plot(
        f1[idx1],
        20 .* log10.(s1[idx1] .+ 1e-12),
        label="Before ANC",
        xlabel="Frequency (Hz)",
        ylabel="Relative magnitude (dB)",
        title="AirPod ANC — Frequency Spectrum"
    )

    plot!(
        f2[idx2],
        20 .* log10.(s2[idx2] .+ 1e-12),
        label="After ANC"
    )

    display(current())
end


###############################################################################
# MAIN
###############################################################################

function main()

    println()
    println("AIRPOD JULIA COMPUTATIONAL AUDIO ENGINE")
    println("---------------------------------------")

    results =
        run_anc_simulation()


    ###########################################################################
    # PERFORMANCE
    ###########################################################################

    before_db =
        db(results.primary)

    after_db =
        db(results.residual)

    reduction =
        calculate_noise_reduction(
            results.primary,
            results.residual
        )


    println("==============================================================")
    println(" RESULTS")
    println("==============================================================")
    println()
    println(
        "Noise before ANC:  ",
        round(before_db, digits=2),
        " dB"
    )

    println(
        "Residual noise:     ",
        round(after_db, digits=2),
        " dB"
    )

    println(
        "Noise reduction:    ",
        round(reduction, digits=2),
        " dB"
    )

    println()
    println(
        "Adaptive coefficients learned: ",
        length(results.controller.w)
    )

    println()


    ###########################################################################
    # PLOTS
    ###########################################################################

    plot_time_domain(results)

    plot_frequency_domain(results)


    return results
end


###############################################################################
# RUN
###############################################################################

results = main()











###############################################################################
# PERSONAL AIRPOD HEARING / EAR-CANAL MODEL
#
# Julia computational-audio system for:
#
#   1. Simulating individual ear-canal acoustics
#   2. Measuring the acoustic transfer function
#   3. Estimating the user's personalised response
#   4. Computing a regularised inverse filter
#   5. Generating a personalised EQ
#   6. Validating the correction
#
# Conceptual signal path:
#
#     AirPod DAC
#         │
#         ▼
#     AirPod Speaker
#         │
#         ▼
#     Earbud / Ear Canal
#         │
#         ▼
#     Eardrum
#         │
#         ▼
#     Measurement Microphone
#         │
#         ▼
#     Julia Acoustic Model
#         │
#         ├── Transfer Function
#         ├── Personal EQ
#         └── Corrected Response
#
###############################################################################

using LinearAlgebra
using Statistics
using Random
using DSP
using FFTW
using Plots

Random.seed!(1234)

###############################################################################
# GLOBAL CONFIGURATION
###############################################################################

const FS = 48_000.0

const TEST_DURATION = 2.0

const N =
    Int(round(TEST_DURATION * FS))

# FFT size
const FFT_SIZE = 65_536

# Frequency limits for safe personalisation
const MIN_FREQ = 20.0
const MAX_FREQ = 20_000.0

# EQ smoothing
const SMOOTHING_BINS = 15

# Maximum correction allowed
const MAX_BOOST_DB = 6.0
const MAX_CUT_DB = -12.0

###############################################################################
# BASIC UTILITIES
###############################################################################

function db_to_linear(db)

    return 10.0^(db / 20.0)

end


function linear_to_db(x)

    return 20.0 *
           log10(
               max(abs(x), 1e-12)
           )

end


function frequency_axis(n, fs)

    return collect(0:n-1) .* fs ./ n

end


###############################################################################
# SYNTHETIC EAR-CANAL MODEL
###############################################################################

"""
Generate a synthetic ear-canal impulse response.

The model approximates:

    earbud speaker
        ↓
    canal reflections
        ↓
    resonances
        ↓
    eardrum

Different users receive different resonance frequencies and amplitudes.
"""

struct EarModel

    canal_length_mm::Float64

    resonance_frequency_1::Float64
    resonance_frequency_2::Float64
    resonance_frequency_3::Float64

    resonance_gain_1::Float64
    resonance_gain_2::Float64
    resonance_gain_3::Float64

    attenuation_db::Float64

    reflection_strength::Float64
end


"""
Create an individual synthetic ear.

The parameters deliberately vary from person to person.
"""

function random_ear_model()

    canal_length =
        rand(
            22.0:0.1:32.0
        )

    # Approximate first resonance around 2–4 kHz
    f1 =
        343_000.0 /
        (4.0 * canal_length)

    f1 *=
        rand(0.90:0.01:1.10)

    f2 =
        f1 * rand(1.7:0.01:2.3)

    f3 =
        f2 * rand(1.5:0.01:2.0)

    return EarModel(

        canal_length,

        f1,
        f2,
        f3,

        rand(1.5:0.1:5.0),
        rand(0.5:0.1:3.0),
        rand(0.2:0.1:2.0),

        rand(-4.0:0.1:0.0),

        rand(0.05:0.01:0.25)
    )
end


###############################################################################
# EAR IMPULSE RESPONSE
###############################################################################

function create_ear_impulse_response(
    ear::EarModel;
    length=4096
)

    h =
        zeros(Float64, length)

    ###########################################################################
    # DIRECT PATH
    ###########################################################################

    h[1] =
        db_to_linear(
            ear.attenuation_db
        )


    ###########################################################################
    # REFLECTIONS
    ###########################################################################

    delay_samples =
        Int(
            round(
                2.0 *
                ear.canal_length_mm /
                1000.0 /
                343.0 *
                FS
            )
        )

    delay_samples =
        max(
            delay_samples,
            1
        )

    if delay_samples < length

        h[delay_samples] +=
            ear.reflection_strength
    end


    ###########################################################################
    # RESONANT IMPULSE RESPONSES
    ###########################################################################

    function add_resonance!(
        h,
        frequency,
        gain,
        damping,
        fs
    )

        decay =
            exp(
                -damping /
                fs
            )

        amplitude =
            db_to_linear(gain)

        max_samples =
            min(
                length(h),
                Int(
                    round(
                        fs * 0.08
                    )
                )
            )

        for n in 1:max_samples

            t =
                (n - 1) /
                fs

            h[n] +=
                amplitude *
                exp(
                    -damping * t
                ) *
                sin(
                    2π *
                    frequency *
                    t
                ) *
                0.005
        end
    end


    add_resonance!(
        h,
        ear.resonance_frequency_1,
        ear.resonance_gain_1,
        40.0,
        FS
    )

    add_resonance!(
        h,
        ear.resonance_frequency_2,
        ear.resonance_gain_2,
        70.0,
        FS
    )

    add_resonance!(
        h,
        ear.resonance_frequency_3,
        ear.resonance_gain_3,
        100.0,
        FS
    )


    ###########################################################################
    # NORMALISE
    ###########################################################################

    maximum_value =
        maximum(
            abs.(h)
        )

    if maximum_value > 0

        h ./=
            maximum_value
    end

    return h
end


###############################################################################
# AIRPOD SPEAKER MODEL
###############################################################################

"""
Approximate AirPod speaker frequency response.

This is NOT an Apple hardware specification.

It is simply a computational model of a small earbud transducer.
"""

function create_speaker_response(
    frequencies
)

    response =
        ones(
            ComplexF64,
            length(frequencies)
        )

    for i in eachindex(frequencies)

        f =
            frequencies[i]

        if f < 100.0

            response[i] *=
                db_to_linear(
                    -8.0
                )

        elseif f < 500.0

            response[i] *=
                db_to_linear(
                    -3.0
                )

        elseif f < 2_000.0

            response[i] *=
                db_to_linear(
                    0.0
                )

        elseif f < 8_000.0

            response[i] *=
                db_to_linear(
                    2.0
                )

        else

            response[i] *=
                db_to_linear(
                    -4.0
                )
        end
    end

    return response
end


###############################################################################
# MEASUREMENT SIGNAL
###############################################################################

"""
Create a logarithmic sine sweep.

This is commonly useful for acoustic system identification.
"""

function logarithmic_sweep(
    duration,
    fs,
    f_start,
    f_end
)

    n =
        Int(
            round(
                duration * fs
            )
        )

    t =
        collect(0:n-1) ./ fs

    K =
        duration /
        log(
            f_end /
            f_start
        )

    L =
        log(
            f_end /
            f_start
        )

    phase =
        2π *
        f_start *
        K *
        (
            exp.(t .* L ./ duration)
            .- 1.0
        )

    sweep =
        sin.(phase)

    # Fade in/out
    fade =
        min(
            Int(
                round(
                    0.01 * fs
                )
            ),
            div(n, 2)
        )

    for i in 1:fade

        multiplier =
            i / fade

        sweep[i] *=
            multiplier

        sweep[end-i+1] *=
            multiplier
    end

    return sweep
end


###############################################################################
# ACOUSTIC MEASUREMENT
###############################################################################

"""
Convolve signal with acoustic impulse response.
"""

function acoustic_convolve(
    signal,
    impulse_response
)

    return DSP.conv(
        signal,
        impulse_response
    )
end


"""
Simulate a microphone measurement.
"""

function simulate_measurement(
    excitation,
    ear_response;
    noise_level=0.001
)

    measured =
        acoustic_convolve(
            excitation,
            ear_response
        )

    # Add microphone noise
    measured .+=
        noise_level .*
        randn(
            length(measured)
        )

    return measured
end


###############################################################################
# FREQUENCY RESPONSE ESTIMATION
###############################################################################

"""
Estimate transfer function using FFT.

H(f) = Y(f) / X(f)
"""

function estimate_transfer_function(
    input_signal,
    output_signal,
    fft_size
)

    x =
        zeros(
            Float64,
            fft_size
        )

    y =
        zeros(
            Float64,
            fft_size
        )

    nx =
        min(
            length(input_signal),
            fft_size
        )

    ny =
        min(
            length(output_signal),
            fft_size
        )

    x[1:nx] =
        input_signal[1:nx]

    y[1:ny] =
        output_signal[1:ny]

    X =
        rfft(x)

    Y =
        rfft(y)

    regularisation =
        1e-8

    H =
        Y .*
        conj.(X) ./
        (
            abs2.(X) .+
            regularisation
        )

    return H
end


###############################################################################
# MAGNITUDE RESPONSE
###############################################################################

function magnitude_response(
    H
)

    return abs.(H)

end


function phase_response(
    H
)

    return angle.(H)

end


###############################################################################
# FREQUENCY RESPONSE SMOOTHING
###############################################################################

"""
Smooth a frequency response.

Acoustic measurements can contain narrow resonances that should not
necessarily become huge EQ corrections.
"""

function smooth_response(
    response,
    window_size
)

    n =
        length(response)

    result =
        similar(response)

    half =
        div(
            window_size,
            2
        )

    for i in 1:n

        lower =
            max(
                1,
                i - half
            )

        upper =
            min(
                n,
                i + half
            )

        result[i] =
            mean(
                response[
                    lower:upper
                ]
            )
    end

    return result
end


###############################################################################
# TARGET RESPONSE
###############################################################################

"""
Create a neutral target response.

A real product could use a user-selectable target:
    - flat
    - diffuse-field
    - free-field
    - personal preference
    - hearing-assistance target
"""

function target_response(
    frequencies
)

    target =
        ones(
            Float64,
            length(frequencies)
        )

    for i in eachindex(frequencies)

        f =
            frequencies[i]

        # Gentle low-frequency shaping
        if f < 100.0

            target[i] =
                db_to_linear(
                    -2.0
                )

        elseif f > 12_000.0

            target[i] =
                db_to_linear(
                    -2.0
                )
        end
    end

    return target
end


###############################################################################
# PERSONALISED EQ CALCULATION
###############################################################################

"""
Calculate inverse EQ.

Desired:

    H_ear(f) × EQ(f) ≈ Target(f)

Therefore:

    EQ(f) ≈ Target(f) / H_ear(f)

Regularisation prevents huge boosts where the acoustic system has
very little energy.
"""

function calculate_inverse_eq(
    H,
    target;
    regularisation=0.03
)

    magnitude =
        abs.(H)

    safe_magnitude =
        magnitude .+
        regularisation

    eq =
        target ./
        safe_magnitude

    return eq
end


###############################################################################
# LIMIT EQ
###############################################################################

"""
Limit EQ correction to sensible bounds.

Large boosts are generally undesirable because they increase:
    - power consumption
    - distortion
    - speaker excursion
    - clipping risk
"""

function limit_eq!(
    eq;
    max_boost_db=MAX_BOOST_DB,
    max_cut_db=MAX_CUT_DB
)

    maximum_gain =
        db_to_linear(
            max_boost_db
        )

    minimum_gain =
        db_to_linear(
            max_cut_db
        )

    for i in eachindex(eq)

        eq[i] =
            clamp(
                eq[i],
                minimum_gain,
                maximum_gain
            )
    end

    return eq
end


###############################################################################
# EQ SMOOTHING
###############################################################################

function smooth_eq!(
    eq;
    window_size=SMOOTHING_BINS
)

    log_eq =
        log.(
            max.(eq, 1e-12)
        )

    smoothed =
        smooth_response(
            log_eq,
            window_size
        )

    eq .=
        exp.(smoothed)

    return eq
end


###############################################################################
# FIR EQ DESIGN
###############################################################################

"""
Convert frequency-domain EQ into a real FIR filter.

The resulting FIR can be used by a real-time audio engine.
"""

function frequency_response_to_fir(
    eq_response,
    fft_size;
    taps=1024
)

    ###########################################################################
    # Construct conjugate-symmetric spectrum
    ###########################################################################

    positive =
        eq_response

    negative =
        conj.(
            positive[
                end-1:-1:2
            ]
        )

    full_spectrum =
        vcat(
            positive,
            negative
        )


    ###########################################################################
    # IFFT
    ###########################################################################

    impulse =
        real.(
            ifft(
                full_spectrum
            )
        )


    ###########################################################################
    # Centre / truncate
    ###########################################################################

    taps =
        min(
            taps,
            length(impulse)
        )

    fir =
        zeros(
            Float64,
            taps
        )

    fir .=
        impulse[
            1:taps
        ]


    ###########################################################################
    # Window
    ###########################################################################

    window =
        DSP.Windows.hann(
            taps
        )

    fir .*= window


    ###########################################################################
    # Normalise
    ###########################################################################

    maximum_gain =
        maximum(
            abs.(fir)
        )

    if maximum_gain > 0

        fir ./=
            maximum_gain
    end

    return fir
end


###############################################################################
# APPLY EQ
###############################################################################

function apply_fir(
    signal,
    fir
)

    return DSP.conv(
        signal,
        fir
    )
end


###############################################################################
# COMPLETE PERSONALISATION PIPELINE
###############################################################################

function personalise_ear(
    ear::EarModel
)

    println()
    println(
        "============================================================"
    )

    println(
        " PERSONAL AIRPOD ACOUSTIC PROFILING"
    )

    println(
        "============================================================"
    )

    println()


    ###########################################################################
    # GENERATE EAR MODEL
    ###########################################################################

    ear_ir =
        create_ear_impulse_response(
            ear
        )


    ###########################################################################
    # MEASUREMENT SWEEP
    ###########################################################################

    println(
        "Generating acoustic measurement sweep..."
    )

    sweep =
        logarithmic_sweep(
            1.0,
            FS,
            20.0,
            20_000.0
        )


    ###########################################################################
    # SIMULATE MEASUREMENT
    ###########################################################################

    println(
        "Simulating ear-canal measurement..."
    )

    measurement =
        simulate_measurement(
            sweep,
            ear_ir
        )


    ###########################################################################
    # FFT
    ###########################################################################

    println(
        "Estimating acoustic transfer function..."
    )

    H =
        estimate_transfer_function(
            sweep,
            measurement,
            FFT_SIZE
        )


    ###########################################################################
    # FREQUENCY AXIS
    ###########################################################################

    frequencies =
        collect(
            0:length(H)-1
        ) .*
        FS /
        FFT_SIZE


    ###########################################################################
    # MAGNITUDE
    ###########################################################################

    magnitude =
        magnitude_response(
            H
        )


    magnitude_db =
        linear_to_db.(
            magnitude
        )


    ###########################################################################
    # SMOOTH RESPONSE
    ###########################################################################

    smoothed_db =
        smooth_response(
            magnitude_db,
            SMOOTHING_BINS
        )


    ###########################################################################
    # CONVERT BACK TO LINEAR
    ###########################################################################

    smoothed_magnitude =
        db_to_linear.(
            smoothed_db
        )


    ###########################################################################
    # TARGET
    ###########################################################################

    target =
        target_response(
            frequencies
        )


    ###########################################################################
    # PERSONAL EQ
    ###########################################################################

    println(
        "Calculating personalised EQ..."
    )

    eq =
        calculate_inverse_eq(
            smoothed_magnitude,
            target
        )


    ###########################################################################
    # LIMIT
    ###########################################################################

    limit_eq!(
        eq
    )


    ###########################################################################
    # SMOOTH EQ
    ###########################################################################

    smooth_eq!(
        eq
    )


    ###########################################################################
    # CREATE FIR
    ###########################################################################

    println(
        "Generating personalised FIR filter..."
    )

    fir =
        frequency_response_to_fir(
            eq,
            FFT_SIZE;
            taps=1024
        )


    ###########################################################################
    # VALIDATION
    ###########################################################################

    println(
        "Validating correction..."
    )

    corrected_measurement =
        apply_fir(
            measurement,
            fir
        )


    H_corrected =
        estimate_transfer_function(
            sweep,
            corrected_measurement,
            FFT_SIZE
        )


    corrected_magnitude =
        abs.(
            H_corrected
        )


    corrected_db =
        linear_to_db.(
            corrected_magnitude
        )


    ###########################################################################
    # RESULTS
    ###########################################################################

    return (

        ear=ear,

        ear_impulse_response=ear_ir,

        sweep=sweep,

        measurement=measurement,

        frequencies=frequencies,

        transfer_function=H,

        magnitude_db=magnitude_db,

        smoothed_db=smoothed_db,

        target=target,

        eq=eq,

        fir=fir,

        corrected_measurement=
            corrected_measurement,

        corrected_transfer_function=
            H_corrected,

        corrected_db=
            corrected_db
    )
end


###############################################################################
# QUALITY METRICS
###############################################################################

"""
Calculate RMS deviation from target in a frequency range.
"""

function response_error(
    response_db,
    target_db,
    frequencies;
    min_freq=100.0,
    max_freq=10_000.0
)

    indices =
        findall(
            (frequencies .>= min_freq) .&
            (frequencies .<= max_freq)
        )

    difference =
        response_db[indices] .-
        target_db[indices]

    return sqrt(
        mean(
            difference .^ 2
        )
    )
end


###############################################################################
# PLOTTING
###############################################################################

function plot_personal_response(
    results
)

    f =
        results.frequencies

    indices =
        findall(
            (f .>= MIN_FREQ) .&
            (f .<= MAX_FREQ)
        )


    target_db =
        linear_to_db.(
            results.target
        )


    plot(
        f[indices],
        results.magnitude_db[indices],
        xscale=:log10,
        label="Measured ear",
        xlabel="Frequency (Hz)",
        ylabel="Magnitude (dB)",
        title="Personal Ear-CanaI Response"
    )

    plot!(
        f[indices],
        target_db[indices],
        label="Target"
    )

    plot!(
        f[indices],
        results.corrected_db[indices],
        label="After personalisation"
    )

    display(current())
end


function plot_personal_eq(
    results
)

    f =
        results.frequencies

    eq_db =
        linear_to_db.(
            results.eq
        )

    indices =
        findall(
            (f .>= MIN_FREQ) .&
            (f .<= MAX_FREQ)
        )


    plot(
        f[indices],
        eq_db[indices],
        xscale=:log10,
        xlabel="Frequency (Hz)",
        ylabel="EQ correction (dB)",
        title="Personalised AirPod EQ",
        label="Personal EQ"
    )

    hline!(
        [0.0],
        label="0 dB"
    )

    display(current())
end


function plot_ear_impulse(
    results
)

    h =
        results.ear_impulse_response

    samples =
        min(
            length(h),
            Int(
                round(
                    0.05 * FS
                )
            )
        )

    t =
        (0:samples-1) ./ FS .* 1000.0


    plot(
        t,
        h[1:samples],
        xlabel="Time (ms)",
        ylabel="Amplitude",
        title="Estimated Ear-CanaI Impulse Response",
        label="Ear response"
    )

    display(current())
end


###############################################################################
# USER PROFILE
###############################################################################

struct PersonalAudioProfile

    ear_model::EarModel

    eq_filter::Vector{Float64}

    sample_rate::Float64

    generated_at::DateTime
end


###############################################################################
# BUILD USER PROFILE
###############################################################################

function create_audio_profile(
    results
)

    return PersonalAudioProfile(

        results.ear,

        results.fir,

        FS,

        Dates.now()
    )
end


###############################################################################
# APPLY PERSONAL PROFILE TO AUDIO
###############################################################################

function process_audio(
    audio,
    profile::PersonalAudioProfile
)

    return DSP.conv(
        audio,
        profile.eq_filter
    )
end


###############################################################################
# MULTI-EAR COMPARISON
###############################################################################

"""
Demonstrate how different ear geometries can produce different responses.
"""

function compare_ears(
    number_of_ears=5
)

    profiles =
        []

    for i in 1:number_of_ears

        println(
            "Generating ear ",
            i
        )

        ear =
            random_ear_model()

        results =
            personalise_ear(
                ear
            )

        push!(
            profiles,
            results
        )
    end

    return profiles
end


###############################################################################
# MAIN
###############################################################################

function main()

    println()
    println(
        "=============================================================="
    )

    println(
        " JULIA PERSONAL AIRPOD HEARING ENGINE"
    )

    println(
        "=============================================================="
    )

    println()


    ###########################################################################
    # CREATE USER EAR
    ###########################################################################

    ear =
        random_ear_model()


    println(
        "Estimated ear-canal length: ",
        round(
            ear.canal_length_mm,
            digits=2
        ),
        " mm"
    )

    println(
        "Estimated resonance #1: ",
        round(
            ear.resonance_frequency_1,
            digits=1
        ),
        " Hz"
    )

    println(
        "Estimated resonance #2: ",
        round(
            ear.resonance_frequency_2,
            digits=1
        ),
        " Hz"
    )

    println(
        "Estimated resonance #3: ",
        round(
            ear.resonance_frequency_3,
            digits=1
        ),
        " Hz"
    )

    println()


    ###########################################################################
    # PERSONALISE
    ###########################################################################

    results =
        personalise_ear(
            ear
        )


    ###########################################################################
    # METRICS
    ###########################################################################

    target_db =
        linear_to_db.(
            results.target
        )


    measured_error =
        response_error(
            results.magnitude_db,
            target_db,
            results.frequencies
        )


    corrected_error =
        response_error(
            results.corrected_db,
            target_db,
            results.frequencies
        )


    println()
    println(
        "=============================================================="
    )

    println(
        " PERSONALISATION RESULTS"
    )

    println(
        "=============================================================="
    )

    println()

    println(
        "Before correction RMS error: ",
        round(
            measured_error,
            digits=3
        ),
        " dB"
    )

    println(
        "After correction RMS error:  ",
        round(
            corrected_error,
            digits=3
        ),
        " dB"
    )

    println()

    println(
        "FIR filter taps: ",
        length(results.fir)
    )

    println(
        "Sample rate: ",
        FS,
        " Hz"
    )

    println()


    ###########################################################################
    # VISUALISATIONS
    ###########################################################################

    plot_ear_impulse(
        results
    )

    plot_personal_response(
        results
    )

    plot_personal_eq(
        results
    )


    return results
end


###############################################################################
# EXECUTE
###############################################################################

results =
    main()
    
    
    
    
    
    ###############################################################################
# AIRPOD POWER OPTIMISATION ENGINE
#
# Julia model for optimising:
#
#   ANC intensity
#   Bluetooth / wireless power
#   DSP workload
#   microphone sampling
#   transparency processing
#   spatial audio
#   EQ complexity
#   CPU frequency
#   speaker output
#
# Objective:
#
#   MINIMISE ENERGY CONSUMPTION
#
# subject to:
#
#   Audio quality >= required quality
#   ANC performance >= required ANC
#   Voice quality >= required voice quality
#   Latency <= maximum latency
#   Battery reserve >= safety reserve
#
###############################################################################

using LinearAlgebra
using Statistics
using Random
using Plots

Random.seed!(42)

###############################################################################
# SYSTEM CONSTANTS
###############################################################################

const BATTERY_CAPACITY_WH = 0.18

# Approximate nominal voltage
const BATTERY_VOLTAGE = 3.8

# Simulation timestep
const DT = 1.0

# Default simulation period
const SIMULATION_HOURS = 8.0

# Minimum reserve
const MINIMUM_RESERVE = 0.05

###############################################################################
# POWER COMPONENT MODEL
###############################################################################

struct PowerModel

    base_power_mw::Float64

    bluetooth_power_mw::Float64

    microphone_power_mw::Float64

    dsp_power_mw::Float64

    anc_power_mw::Float64

    transparency_power_mw::Float64

    spatial_audio_power_mw::Float64

    speaker_power_mw::Float64

    sensor_power_mw::Float64
end


###############################################################################
# DEFAULT HARDWARE POWER MODEL
###############################################################################

function default_power_model()

    return PowerModel(

        8.0,       # base electronics
        12.0,      # Bluetooth
        4.0,       # microphones
        10.0,      # DSP
        20.0,      # ANC
        12.0,      # transparency
        15.0,      # spatial audio
        25.0,      # speaker
        2.0        # sensors
    )

end


###############################################################################
# OPERATING STATE
###############################################################################

mutable struct AirPodState

    anc_level::Float64

    transparency_level::Float64

    spatial_audio::Float64

    microphone_rate::Float64

    dsp_frequency::Float64

    bluetooth_rate::Float64

    volume::Float64

    eq_complexity::Float64

    battery_wh::Float64

    temperature_c::Float64
end


###############################################################################
# DEFAULT STATE
###############################################################################

function default_state()

    return AirPodState(

        0.80,      # ANC

        0.00,      # transparency

        0.00,      # spatial

        48_000.0,  # microphone rate

        1.00,      # DSP clock normalised

        1.00,      # Bluetooth activity

        0.50,      # volume

        0.50,      # EQ complexity

        BATTERY_CAPACITY_WH,

        25.0
    )

end


###############################################################################
# ENVIRONMENT MODEL
###############################################################################

struct Environment

    noise_level::Float64

    noise_frequency::Float64

    speech_activity::Float64

    wind_level::Float64

    movement_level::Float64

    bluetooth_quality::Float64
end


###############################################################################
# ENVIRONMENT GENERATORS
###############################################################################

function aircraft_environment()

    return Environment(

        0.90,
        120.0,
        0.05,
        0.05,
        0.10,
        0.95
    )

end


function train_environment()

    return Environment(

        0.75,
        100.0,
        0.20,
        0.10,
        0.35,
        0.95
    )

end


function office_environment()

    return Environment(

        0.25,
        600.0,
        0.70,
        0.00,
        0.05,
        0.98
    )

end


function street_environment()

    return Environment(

        0.65,
        300.0,
        0.40,
        0.60,
        0.75,
        0.90
    )

end


function quiet_home_environment()

    return Environment(

        0.08,
        1000.0,
        0.15,
        0.00,
        0.02,
        0.99
    )

end


###############################################################################
# POWER CONSUMPTION MODEL
###############################################################################

"""
Calculate power consumption for a given AirPod state.
"""

function calculate_power(
    state::AirPodState,
    model::PowerModel,
    environment::Environment
)

    ###########################################################################
    # BASE POWER
    ###########################################################################

    power =
        model.base_power_mw


    ###########################################################################
    # BLUETOOTH
    ###########################################################################

    bluetooth =
        model.bluetooth_power_mw *
        state.bluetooth_rate

    power +=
        bluetooth


    ###########################################################################
    # MICROPHONE
    ###########################################################################

    microphone_factor =
        state.microphone_rate /
        48_000.0

    microphone =
        model.microphone_power_mw *
        microphone_factor

    power +=
        microphone


    ###########################################################################
    # DSP
    ###########################################################################

    dsp =
        model.dsp_power_mw *
        state.dsp_frequency^1.35

    power +=
        dsp


    ###########################################################################
    # ANC
    ###########################################################################

    anc =
        model.anc_power_mw *
        state.anc_level^1.5

    power +=
        anc


    ###########################################################################
    # TRANSPARENCY
    ###########################################################################

    transparency =
        model.transparency_power_mw *
        state.transparency_level^1.4

    power +=
        transparency


    ###########################################################################
    # SPATIAL AUDIO
    ###########################################################################

    spatial =
        model.spatial_audio_power_mw *
        state.spatial_audio

    power +=
        spatial


    ###########################################################################
    # SPEAKER
    ###########################################################################

    speaker =
        model.speaker_power_mw *
        state.volume^1.7

    power +=
        speaker


    ###########################################################################
    # SENSORS
    ###########################################################################

    sensor =
        model.sensor_power_mw *
        (
            0.5 +
            state.spatial_audio
        )

    power +=
        sensor


    ###########################################################################
    # WIND / MOVEMENT PROCESSING
    ###########################################################################

    environmental_processing =
        3.0 *
        environment.wind_level

    power +=
        environmental_processing


    ###########################################################################
    # RETURN WATTS
    ###########################################################################

    return power / 1000.0
end


###############################################################################
# AUDIO QUALITY MODEL
###############################################################################

"""
Estimate subjective audio quality from the current operating state.
"""

function calculate_audio_quality(
    state,
    environment
)

    quality = 1.0


    # Excessively low DSP frequency can reduce quality
    quality *=
        0.75 +
        0.25 *
        min(
            state.dsp_frequency,
            1.0
        )


    # Excessive compression / low wireless quality
    quality *=
        0.90 +
        0.10 *
        environment.bluetooth_quality


    # Volume does not directly determine fidelity,
    # but extremely low volume can reduce perceived quality.
    quality *=
        0.90 +
        0.10 *
        state.volume


    return clamp(
        quality,
        0.0,
        1.0
    )
end


###############################################################################
# ANC PERFORMANCE MODEL
###############################################################################

"""
Estimate ANC effectiveness.

ANC effectiveness depends on:
    - ANC level
    - DSP resources
    - microphone rate
    - environmental noise
"""

function calculate_anc_performance(
    state,
    environment
)

    base =
        state.anc_level *
        (
            0.70 +
            0.30 *
            state.dsp_frequency
        )

    microphone_factor =
        clamp(
            state.microphone_rate /
            48_000.0,
            0.5,
            1.0
        )

    noise_factor =
        0.90 +
        0.10 *
        environment.noise_level

    performance =
        base *
        microphone_factor *
        noise_factor

    return clamp(
        performance,
        0.0,
        1.0
    )
end


###############################################################################
# VOICE QUALITY
###############################################################################

function calculate_voice_quality(
    state,
    environment
)

    microphone_factor =
        clamp(
            state.microphone_rate /
            48_000.0,
            0.4,
            1.0
        )

    wind_penalty =
        1.0 -
        0.35 *
        environment.wind_level

    voice =
        microphone_factor *
        wind_penalty *
        (
            0.8 +
            0.2 *
            state.dsp_frequency
        )

    return clamp(
        voice,
        0.0,
        1.0
    )
end


###############################################################################
# LATENCY MODEL
###############################################################################

function calculate_latency(
    state
)

    base_latency =
        4.0

    dsp_latency =
        5.0 *
        (
            1.0 /
            max(
                state.dsp_frequency,
                0.1
            )
        )

    microphone_latency =
        1000.0 /
        state.microphone_rate

    return (
        base_latency +
        dsp_latency +
        microphone_latency
    )
end


###############################################################################
# ENERGY EFFICIENCY
###############################################################################

function calculate_efficiency(
    state,
    model,
    environment
)

    power =
        calculate_power(
            state,
            model,
            environment
        )

    quality =
        calculate_audio_quality(
            state,
            environment
        )

    if power <= 0

        return 0.0

    end

    return quality / power
end


###############################################################################
# BATTERY MODEL
###############################################################################

function battery_after(
    battery_wh,
    power_w,
    dt_seconds
)

    energy_used =
        power_w *
        dt_seconds /
        3600.0

    return max(
        0.0,
        battery_wh -
        energy_used
    )
end


function battery_percentage(
    battery_wh
)

    return 100.0 *
           battery_wh /
           BATTERY_CAPACITY_WH

end


###############################################################################
# TEMPERATURE MODEL
###############################################################################

function update_temperature(
    temperature,
    power_w,
    dt
)

    ###########################################################################
    # Simple thermal model:
    #
    # Heat generated proportional to power.
    # Heat dissipates toward ambient.
    ###########################################################################

    ambient = 23.0

    heating =
        0.04 *
        power_w

    cooling =
        0.005 *
        (
            temperature -
            ambient
        )

    return temperature +
           (
               heating -
               cooling
           ) *
           dt

end


###############################################################################
# CONSTRAINTS
###############################################################################

struct OptimisationConstraints

    minimum_audio_quality::Float64

    minimum_anc_performance::Float64

    minimum_voice_quality::Float64

    maximum_latency_ms::Float64

    minimum_battery_percentage::Float64

end


function default_constraints()

    return OptimisationConstraints(

        0.90,
        0.65,
        0.70,
        20.0,
        5.0
    )

end


###############################################################################
# CHECK FEASIBILITY
###############################################################################

function is_feasible(
    state,
    environment,
    model,
    constraints
)

    audio_quality =
        calculate_audio_quality(
            state,
            environment
        )

    anc =
        calculate_anc_performance(
            state,
            environment
        )

    voice =
        calculate_voice_quality(
            state,
            environment
        )

    latency =
        calculate_latency(
            state
        )

    battery =
        battery_percentage(
            state.battery_wh
        )


    return (

        audio_quality >=
        constraints.minimum_audio_quality

        &&

        anc >=
        constraints.minimum_anc_performance

        &&

        voice >=
        constraints.minimum_voice_quality

        &&

        latency <=
        constraints.maximum_latency_ms

        &&

        battery >=
        constraints.minimum_battery_percentage
    )
end


###############################################################################
# COST FUNCTION
###############################################################################

"""
Objective function.

Lower is better.

Energy consumption receives the largest weight, but the optimiser receives
large penalties for violating quality constraints.
"""

function optimisation_cost(
    state,
    environment,
    model,
    constraints
)

    power =
        calculate_power(
            state,
            model,
            environment
        )


    audio =
        calculate_audio_quality(
            state,
            environment
        )


    anc =
        calculate_anc_performance(
            state,
            environment
        )


    voice =
        calculate_voice_quality(
            state,
            environment
        )


    latency =
        calculate_latency(
            state
        )


    ###########################################################################
    # BASE ENERGY COST
    ###########################################################################

    cost =
        power


    ###########################################################################
    # QUALITY PENALTIES
    ###########################################################################

    if audio <
       constraints.minimum_audio_quality

        cost +=
            1000.0 *
            (
                constraints.minimum_audio_quality -
                audio
            )^2

    end


    if anc <
       constraints.minimum_anc_performance

        cost +=
            1000.0 *
            (
                constraints.minimum_anc_performance -
                anc
            )^2

    end


    if voice <
       constraints.minimum_voice_quality

        cost +=
            500.0 *
            (
                constraints.minimum_voice_quality -
                voice
            )^2

    end


    ###########################################################################
    # LATENCY PENALTY
    ###########################################################################

    if latency >
       constraints.maximum_latency_ms

        cost +=
            100.0 *
            (
                latency -
                constraints.maximum_latency_ms
            )^2

    end


    return cost
end


###############################################################################
# STATE COPY
###############################################################################

function copy_state(
    state::AirPodState
)

    return AirPodState(

        state.anc_level,

        state.transparency_level,

        state.spatial_audio,

        state.microphone_rate,

        state.dsp_frequency,

        state.bluetooth_rate,

        state.volume,

        state.eq_complexity,

        state.battery_wh,

        state.temperature_c
    )

end


###############################################################################
# RANDOM STATE GENERATOR
###############################################################################

function random_state(
    battery_wh
)

    return AirPodState(

        rand(),
        rand(),
        rand(),

        rand(
            16_000.0:8_000.0:48_000.0
        ),

        rand(
            0.50:0.05:1.20
        ),

        rand(
            0.50:0.05:1.20
        ),

        rand(
            0.20:0.05:0.90
        ),

        rand(),

        battery_wh,

        25.0
    )
end


###############################################################################
# GRID / RANDOM SEARCH OPTIMISER
###############################################################################

"""
Search thousands of candidate operating states.

For embedded hardware, this could eventually be replaced by a much faster
precomputed policy or gradient-based optimiser.
"""

function optimise_state(
    environment,
    model,
    constraints;
    iterations=20_000,
    battery_wh=BATTERY_CAPACITY_WH
)

    best_state = nothing

    best_cost =
        Inf


    ###########################################################################
    # Candidate search
    ###########################################################################

    for iteration in 1:iterations

        candidate =
            random_state(
                battery_wh
            )


        cost =
            optimisation_cost(
                candidate,
                environment,
                model,
                constraints
            )


        if cost <
           best_cost

            best_cost =
                cost

            best_state =
                candidate
        end
    end


    return (
        state=best_state,
        cost=best_cost
    )
end


###############################################################################
# DETERMINISTIC LOCAL OPTIMISER
###############################################################################

"""
Refine an existing solution by perturbing each parameter.

This gives the random search a local optimisation stage.
"""

function refine_state(
    initial_state,
    environment,
    model,
    constraints;
    iterations=5000
)

    current =
        copy_state(
            initial_state
        )

    current_cost =
        optimisation_cost(
            current,
            environment,
            model,
            constraints
        )


    for iteration in 1:iterations

        candidate =
            copy_state(
                current
            )


        #######################################################################
        # Perturb parameters
        #######################################################################

        candidate.anc_level =
            clamp(
                current.anc_level +
                randn() * 0.04,
                0.0,
                1.0
            )


        candidate.transparency_level =
            clamp(
                current.transparency_level +
                randn() * 0.04,
                0.0,
                1.0
            )


        candidate.spatial_audio =
            clamp(
                current.spatial_audio +
                randn() * 0.04,
                0.0,
                1.0
            )


        candidate.dsp_frequency =
            clamp(
                current.dsp_frequency +
                randn() * 0.04,
                0.5,
                1.2
            )


        candidate.bluetooth_rate =
            clamp(
                current.bluetooth_rate +
                randn() * 0.04,
                0.5,
                1.2
            )


        candidate.microphone_rate =
            clamp(
                current.microphone_rate +
                randn() * 2000.0,
                16_000.0,
                48_000.0
            )


        candidate.volume =
            clamp(
                current.volume +
                randn() * 0.03,
                0.0,
                1.0
            )


        candidate.eq_complexity =
            clamp(
                current.eq_complexity +
                randn() * 0.03,
                0.0,
                1.0
            )


        #######################################################################
        # Evaluate
        #######################################################################

        candidate_cost =
            optimisation_cost(
                candidate,
                environment,
                model,
                constraints
            )


        #######################################################################
        # Accept improvement
        #######################################################################

        if candidate_cost <
           current_cost

            current =
                candidate

            current_cost =
                candidate_cost
        end
    end


    return (
        state=current,
        cost=current_cost
    )
end


###############################################################################
# ADAPTIVE ENVIRONMENT CONTROLLER
###############################################################################

"""
Continuously select operating parameters based on environment.

This represents the higher-level intelligence above the low-level DSP.
"""

mutable struct PowerController

    state::AirPodState

    model::PowerModel

    constraints::OptimisationConstraints
end


function create_power_controller()

    return PowerController(

        default_state(),

        default_power_model(),

        default_constraints()
    )

end


###############################################################################
# ENVIRONMENT CLASSIFICATION
###############################################################################

function classify_environment(
    noise_level,
    speech_activity,
    movement,
    wind
)

    if noise_level > 0.80

        return :HIGH_NOISE

    elseif wind > 0.50

        return :WINDY_OUTDOOR

    elseif speech_activity > 0.60

        return :SPEECH

    elseif movement > 0.50

        return :MOVING_OUTDOOR

    elseif noise_level < 0.15

        return :QUIET

    else

        return :NORMAL

    end
end


###############################################################################
# ENVIRONMENT-SPECIFIC CONSTRAINTS
###############################################################################

function constraints_for_environment(
    environment
)

    category =
        classify_environment(
            environment.noise_level,
            environment.speech_activity,
            environment.movement_level,
            environment.wind_level
        )


    if category == :HIGH_NOISE

        return OptimisationConstraints(

            0.90,
            0.85,
            0.60,
            20.0,
            5.0
        )


    elseif category == :WINDY_OUTDOOR

        return OptimisationConstraints(

            0.88,
            0.70,
            0.85,
            20.0,
            5.0
        )


    elseif category == :SPEECH

        return OptimisationConstraints(

            0.90,
            0.30,
            0.95,
            20.0,
            5.0
        )


    elseif category == :QUIET

        return OptimisationConstraints(

            0.88,
            0.20,
            0.70,
            20.0,
            5.0
        )


    else

        return OptimisationConstraints(

            0.90,
            0.65,
            0.75,
            20.0,
            5.0
        )

    end
end


###############################################################################
# REAL-TIME OPTIMISATION
###############################################################################

function optimise_for_environment!(
    controller,
    environment
)

    controller.constraints =
        constraints_for_environment(
            environment
        )


    result =
        optimise_state(
            environment,
            controller.model,
            controller.constraints;
            iterations=5000,
            battery_wh=
                controller.state.battery_wh
        )


    refined =
        refine_state(
            result.state,
            environment,
            controller.model,
            controller.constraints;
            iterations=1000
        )


    controller.state =
        refined.state


    return controller.state
end


###############################################################################
# BATTERY SIMULATION
###############################################################################

struct SimulationResult

    time_hours::Vector{Float64}

    battery_percentage::Vector{Float64}

    power_watts::Vector{Float64}

    anc_level::Vector{Float64}

    audio_quality::Vector{Float64}

    anc_performance::Vector{Float64}

    temperature::Vector{Float64}
end


###############################################################################
# RUN SIMULATION
###############################################################################

function simulate_battery(
    environments;
    hours=SIMULATION_HOURS
)

    controller =
        create_power_controller()


    total_seconds =
        Int(
            round(
                hours * 3600.0
            )
        )


    ###########################################################################
    # Logging
    ###########################################################################

    time_log =
        Float64[]

    battery_log =
        Float64[]

    power_log =
        Float64[]

    anc_log =
        Float64[]

    quality_log =
        Float64[]

    anc_performance_log =
        Float64[]

    temperature_log =
        Float64[]


    ###########################################################################
    # Optimise every minute
    ###########################################################################

    optimisation_interval =
        60


    current_environment_index =
        1


    for second in 0:total_seconds

        #######################################################################
        # Change environment periodically
        #######################################################################

        if second > 0 &&
           second % 1800 == 0

            current_environment_index += 1

            if current_environment_index >
               length(environments)

                current_environment_index = 1
            end
        end


        environment =
            environments[
                current_environment_index
            ]


        #######################################################################
        # Re-optimise
        #######################################################################

        if second % optimisation_interval == 0

            optimise_for_environment!(
                controller,
                environment
            )
        end


        #######################################################################
        # Calculate power
        #######################################################################

        power =
            calculate_power(
                controller.state,
                controller.model,
                environment
            )


        #######################################################################
        # Battery
        #######################################################################

        controller.state.battery_wh =
            battery_after(
                controller.state.battery_wh,
                power,
                DT
            )


        #######################################################################
        # Temperature
        #######################################################################

        controller.state.temperature_c =
            update_temperature(
                controller.state.temperature_c,
                power,
                DT
            )


        #######################################################################
        # Metrics
        #######################################################################

        quality =
            calculate_audio_quality(
                controller.state,
                environment
            )


        anc =
            calculate_anc_performance(
                controller.state,
                environment
            )


        #######################################################################
        # Log
        #######################################################################

        if second % 10 == 0

            push!(
                time_log,
                second / 3600.0
            )

            push!(
                battery_log,
                battery_percentage(
                    controller.state.battery_wh
                )
            )

            push!(
                power_log,
                power
            )

            push!(
                anc_log,
                controller.state.anc_level
            )

            push!(
                quality_log,
                quality
            )

            push!(
                anc_performance_log,
                anc
            )

            push!(
                temperature_log,
                controller.state.temperature_c
            )
        end


        #######################################################################
        # Battery exhausted
        #######################################################################

        if controller.state.battery_wh <= 0

            println(
                "Battery exhausted at ",
                round(
                    second / 3600.0,
                    digits=2
                ),
                " hours."
            )

            break
        end
    end


    return SimulationResult(

        time_log,

        battery_log,

        power_log,

        anc_log,

        quality_log,

        anc_performance_log,

        temperature_log
    )
end


###############################################################################
# BASELINE SIMULATION
###############################################################################

function simulate_baseline(
    environments;
    hours=SIMULATION_HOURS
)

    state =
        default_state()

    model =
        default_power_model()


    total_seconds =
        Int(
            round(
                hours * 3600
            )
        )


    battery =
        BATTERY_CAPACITY_WH


    time_log =
        Float64[]

    battery_log =
        Float64[]

    power_log =
        Float64[]


    for second in 0:total_seconds

        environment =
            environments[
                1 +
                mod(
                    div(
                        second,
                        1800
                    ),
                    length(environments)
                )
            ]


        power =
            calculate_power(
                state,
                model,
                environment
            )


        battery =
            battery_after(
                battery,
                power,
                1.0
            )


        if second % 10 == 0

            push!(
                time_log,
                second / 3600
            )

            push!(
                battery_log,
                battery_percentage(
                    battery
                )
            )

            push!(
                power_log,
                power
            )
        end


        if battery <= 0

            break
        end
    end


    return (
        time=time_log,
        battery=battery_log,
        power=power_log
    )
end


###############################################################################
# ENERGY REPORT
###############################################################################

function energy_report(
    result
)

    initial =
        first(
            result.battery_percentage
        )

    final =
        last(
            result.battery_percentage
        )

    elapsed =
        last(
            result.time_hours
        )


    average_power =
        mean(
            result.power_watts
        )


    println()
    println(
        "=============================================================="
    )
    println(
        " BATTERY / ENERGY REPORT"
    )
    println(
        "=============================================================="
    )
    println()

    println(
        "Simulation time:       ",
        round(elapsed, digits=2),
        " hours"
    )

    println(
        "Initial battery:       ",
        round(initial, digits=2),
        " %"
    )

    println(
        "Final battery:         ",
        round(final, digits=2),
        " %"
    )

    println(
        "Average power:         ",
        round(average_power, digits=3),
        " W"
    )

    println(
        "Average ANC level:     ",
        round(
            mean(result.anc_level),
            digits=3
        )
    )

    println(
        "Average audio quality: ",
        round(
            mean(result.audio_quality),
            digits=3
        )
    )

    println(
        "Average ANC performance: ",
        round(
            mean(result.anc_performance),
            digits=3
        )
    )

    println(
        "Maximum temperature:   ",
        round(
            maximum(result.temperature),
            digits=2
        ),
        " °C"
    )

    println()
end


###############################################################################
# VISUALISATION
###############################################################################

function plot_battery(
    result
)

    plot(
        result.time_hours,
        result.battery_percentage,
        xlabel="Time (hours)",
        ylabel="Battery (%)",
        title="Adaptive AirPod Battery Optimisation",
        label="Optimised controller"
    )

    display(current())
end


function plot_power(
    result
)

    plot(
        result.time_hours,
        result.power_watts,
        xlabel="Time (hours)",
        ylabel="Power (W)",
        title="AirPod Power Consumption",
        label="Power"
    )

    display(current())
end


function plot_anc(
    result
)

    plot(
        result.time_hours,
        result.anc_level,
        xlabel="Time (hours)",
        ylabel="ANC level",
        title="Adaptive ANC Level",
        label="ANC"
    )

    plot!(
        result.time_hours,
        result.anc_performance,
        label="ANC performance"
    )

    display(current())
end


function plot_quality(
    result
)

    plot(
        result.time_hours,
        result.audio_quality,
        xlabel="Time (hours)",
        ylabel="Quality",
        title="Audio Quality During Optimisation",
        label="Audio quality"
    )

    display(current())
end


function plot_temperature(
    result
)

    plot(
        result.time_hours,
        result.temperature,
        xlabel="Time (hours)",
        ylabel="Temperature (°C)",
        title="AirPod Thermal Model",
        label="Temperature"
    )

    display(current())
end


###############################################################################
# OPTIMISATION DEMONSTRATION
###############################################################################

function demonstrate_environment_optimisation()

    model =
        default_power_model()

    constraints =
        default_constraints()


    environments = [

        (
            name="Aircraft",
            environment=
                aircraft_environment()
        ),

        (
            name="Train",
            environment=
                train_environment()
        ),

        (
            name="Office",
            environment=
                office_environment()
        ),

        (
            name="Street",
            environment=
                street_environment()
        ),

        (
            name="Home",
            environment=
                quiet_home_environment()
        )
    ]


    println()
    println(
        "=============================================================="
    )

    println(
        " ENVIRONMENT-SPECIFIC POWER OPTIMISATION"
    )

    println(
        "=============================================================="
    )

    println()


    for item in environments

        environment =
            item.environment


        constraints =
            constraints_for_environment(
                environment
            )


        result =
            optimise_state(
                environment,
                model,
                constraints;
                iterations=10_000
            )


        refined =
            refine_state(
                result.state,
                environment,
                model,
                constraints;
                iterations=2000
            )


        state =
            refined.state


        power =
            calculate_power(
                state,
                model,
                environment
            )


        quality =
            calculate_audio_quality(
                state,
                environment
            )


        anc =
            calculate_anc_performance(
                state,
                environment
            )


        voice =
            calculate_voice_quality(
                state,
                environment
            )


        println(
            "Environment: ",
            item.name
        )

        println(
            "  ANC:              ",
            round(state.anc_level, digits=3)
        )

        println(
            "  Transparency:     ",
            round(
                state.transparency_level,
                digits=3
            )
        )

        println(
            "  Spatial audio:    ",
            round(
                state.spatial_audio,
                digits=3
            )
        )

        println(
            "  DSP frequency:    ",
            round(
                state.dsp_frequency,
                digits=3
            )
        )

        println(
            "  Microphone rate:  ",
            round(
                state.microphone_rate
            ),
            " Hz"
        )

        println(
            "  Power:            ",
            round(power, digits=4),
            " W"
        )

        println(
            "  Audio quality:    ",
            round(
                quality,
                digits=3
            )
        )

        println(
            "  ANC performance:  ",
            round(
                anc,
                digits=3
            )
        )

        println(
            "  Voice quality:    ",
            round(
                voice,
                digits=3
            )
        )

        println()
    end
end


###############################################################################
# MAIN
###############################################################################

function main()

    println()
    println(
        "=============================================================="
    )

    println(
        " JULIA AIRPOD INTELLIGENT POWER ENGINE"
    )

    println(
        "=============================================================="
    )

    println()


    ###########################################################################
    # ENVIRONMENTS
    ###########################################################################

    environments = [

        aircraft_environment(),

        train_environment(),

        office_environment(),

        street_environment(),

        quiet_home_environment()
    ]


    ###########################################################################
    # SHOW INDIVIDUAL OPTIMISATIONS
    ###########################################################################

    demonstrate_environment_optimisation()


    ###########################################################################
    # LONG BATTERY SIMULATION
    ###########################################################################

    println(
        "Running long-term battery simulation..."
    )

    result =
        simulate_battery(
            environments;
            hours=8.0
        )


    ###########################################################################
    # REPORT
    ###########################################################################

    energy_report(
        result
    )


    ###########################################################################
    # PLOTS
    ###########################################################################

    plot_battery(
        result
    )

    plot_power(
        result
    )

    plot_anc(
        result
    )

    plot_quality(
        result
    )

    plot_temperature(
        result
    )


    return result
end


###############################################################################
# RUN
###############################################################################

result =
    main()
    
    
    
    
    
    ###############################################################################
# AIRPOD SPATIAL AUDIO + HEAD TRACKING ENGINE
#
# Julia implementation of a computational binaural/spatial-audio system.
#
# Pipeline:
#
#       3D SOUND SOURCE
#              │
#              ▼
#       WORLD COORDINATES
#              │
#              ▼
#       HEAD POSITION / ORIENTATION
#              │
#              ▼
#       RELATIVE SOURCE POSITION
#              │
#              ▼
#       AZIMUTH / ELEVATION / DISTANCE
#              │
#              ▼
#       HRTF MODEL
#              │
#        ┌─────┴─────┐
#        ▼           ▼
#      LEFT         RIGHT
#       EAR          EAR
#        │           │
#        └─────┬─────┘
#              ▼
#       BINAURAL AUDIO
#
###############################################################################

using LinearAlgebra
using Statistics
using Random
using DSP
using FFTW
using Plots

Random.seed!(1234)

###############################################################################
# CONSTANTS
###############################################################################

const FS = 48_000.0

const SPEED_OF_SOUND = 343.0

const HEAD_RADIUS = 0.087

const EAR_DISTANCE =
    HEAD_RADIUS * 2.0

const MAX_DISTANCE = 50.0

const MAX_ITD_SECONDS = 0.00065

###############################################################################
# VECTOR TYPES
###############################################################################

struct Vec3

    x::Float64
    y::Float64
    z::Float64

end


Base.:+(a::Vec3, b::Vec3) =
    Vec3(
        a.x + b.x,
        a.y + b.y,
        a.z + b.z
    )


Base.:-(a::Vec3, b::Vec3) =
    Vec3(
        a.x - b.x,
        a.y - b.y,
        a.z - b.z
    )


Base.:*(a::Vec3, s::Float64) =
    Vec3(
        a.x * s,
        a.y * s,
        a.z * s
    )


Base.:*(s::Float64, a::Vec3) =
    a * s


function dot3(a::Vec3, b::Vec3)

    return (
        a.x * b.x +
        a.y * b.y +
        a.z * b.z
    )

end


function cross3(a::Vec3, b::Vec3)

    return Vec3(

        a.y * b.z -
        a.z * b.y,

        a.z * b.x -
        a.x * b.z,

        a.x * b.y -
        a.y * b.x
    )

end


function magnitude(a::Vec3)

    return sqrt(
        dot3(a, a)
    )

end


function normalise(a::Vec3)

    m =
        magnitude(a)

    if m < 1e-12

        return Vec3(
            0.0,
            0.0,
            0.0
        )

    end

    return a / m

end


###############################################################################
# QUATERNION
###############################################################################

struct Quaternion

    w::Float64
    x::Float64
    y::Float64
    z::Float64

end


function quaternion(
    w,
    x,
    y,
    z
)

    q =
        Quaternion(
            w,
            x,
            y,
            z
        )

    n =
        sqrt(
            q.w^2 +
            q.x^2 +
            q.y^2 +
            q.z^2
        )

    return Quaternion(

        q.w / n,
        q.x / n,
        q.y / n,
        q.z / n
    )
end


function quaternion_multiply(
    a::Quaternion,
    b::Quaternion
)

    return Quaternion(

        a.w*b.w -
        a.x*b.x -
        a.y*b.y -
        a.z*b.z,

        a.w*b.x +
        a.x*b.w +
        a.y*b.z -
        a.z*b.y,

        a.w*b.y -
        a.x*b.z +
        a.y*b.w +
        a.z*b.x,

        a.w*b.z +
        a.x*b.y -
        a.y*b.x +
        a.z*b.w
    )

end


function quaternion_conjugate(
    q::Quaternion
)

    return Quaternion(
        q.w,
        -q.x,
        -q.y,
        -q.z
    )

end


###############################################################################
# ROTATE VECTOR
###############################################################################

function rotate_vector(
    q::Quaternion,
    v::Vec3
)

    qv =
        Quaternion(
            0.0,
            v.x,
            v.y,
            v.z
        )

    result =
        quaternion_multiply(
            quaternion_multiply(
                q,
                qv
            ),
            quaternion_conjugate(q)
        )

    return Vec3(
        result.x,
        result.y,
        result.z
    )
end


###############################################################################
# EULER → QUATERNION
###############################################################################

function euler_to_quaternion(
    yaw,
    pitch,
    roll
)

    cy =
        cos(yaw / 2)

    sy =
        sin(yaw / 2)

    cp =
        cos(pitch / 2)

    sp =
        sin(pitch / 2)

    cr =
        cos(roll / 2)

    sr =
        sin(roll / 2)


    return quaternion(

        cr*cp*cy +
        sr*sp*sy,

        sr*cp*cy -
        cr*sp*sy,

        cr*sp*cy +
        sr*cp*sy,

        cr*cp*sy -
        sr*sp*cy
    )

end


###############################################################################
# AUDIO SOURCE
###############################################################################

struct AudioSource

    position::Vec3

    velocity::Vec3

    frequency::Float64

    amplitude::Float64

end


###############################################################################
# LISTENER
###############################################################################

mutable struct Listener

    position::Vec3

    orientation::Quaternion

    velocity::Vec3

end


###############################################################################
# ROOM
###############################################################################

struct Room

    width::Float64

    depth::Float64

    height::Float64

    reflection_gain::Float64

    absorption::Float64

end


###############################################################################
# RELATIVE SOURCE POSITION
###############################################################################

function relative_position(
    listener::Listener,
    source::AudioSource
)

    difference =
        source.position -
        listener.position


    inverse_orientation =
        quaternion_conjugate(
            listener.orientation
        )


    return rotate_vector(
        inverse_orientation,
        difference
    )

end


###############################################################################
# AZIMUTH
###############################################################################

function calculate_azimuth(
    position::Vec3
)

    return atan(
        position.x,
        position.z
    )

end


###############################################################################
# ELEVATION
###############################################################################

function calculate_elevation(
    position::Vec3
)

    horizontal =
        sqrt(
            position.x^2 +
            position.z^2
        )

    return atan(
        position.y,
        horizontal
    )

end


###############################################################################
# DISTANCE
###############################################################################

function calculate_distance(
    position::Vec3
)

    return magnitude(
        position
    )

end


###############################################################################
# INTERAURAL TIME DIFFERENCE
###############################################################################

"""
Woodworth-like spherical-head approximation.
"""

function calculate_itd(
    azimuth
)

    return (
        HEAD_RADIUS /
        SPEED_OF_SOUND
    ) *
    (
        sin(azimuth) +
        azimuth
    )

end


###############################################################################
# INTERAURAL LEVEL DIFFERENCE
###############################################################################

function calculate_ild(
    azimuth,
    frequency
)

    # Maximum effect increases with frequency.

    base =
        sin(
            abs(azimuth)
        )


    frequency_factor =
        clamp(
            frequency /
            5000.0,
            0.0,
            1.0
        )


    return (
        12.0 *
        base *
        frequency_factor
    )

end


###############################################################################
# DISTANCE ATTENUATION
###############################################################################

function distance_gain(
    distance
)

    d =
        max(
            distance,
            0.5
        )


    return 1.0 / d

end


###############################################################################
# HRTF MODEL
###############################################################################

struct HRTFResponse

    left::Vector{ComplexF64}

    right::Vector{ComplexF64}

    frequencies::Vector{Float64}

end


###############################################################################
# SYNTHETIC HRTF
###############################################################################

"""
Generate an approximate HRTF from:

    azimuth
    elevation
    frequency

A production implementation would replace this with measured HRTF datasets.
"""

function generate_hrtf(
    azimuth,
    elevation,
    fft_size
)

    n =
        div(
            fft_size,
            2
        ) + 1


    frequencies =
        collect(
            0:n-1
        ) .* FS ./ fft_size


    left =
        ones(
            ComplexF64,
            n
        )


    right =
        ones(
            ComplexF64,
            n
        )


    ###########################################################################
    # ILD
    ###########################################################################

    for i in eachindex(frequencies)

        f =
            frequencies[i]

        ild =
            calculate_ild(
                azimuth,
                f
            )


        if azimuth > 0

            # Source to right

            left[i] *=
                10.0^(
                    -ild / 20.0
                )

            right[i] *=
                10.0^(
                    0.0
                )

        else

            # Source to left

            right[i] *=
                10.0^(
                    -ild / 20.0
                )

            left[i] *=
                10.0^(
                    0.0
                )
        end


        #######################################################################
        # Elevation shaping
        #######################################################################

        elevation_factor =
            sin(
                elevation
            )


        if f > 6000.0

            high_frequency_gain =
                1.0 +
                0.20 *
                elevation_factor

            left[i] *=
                high_frequency_gain

            right[i] *=
                high_frequency_gain
        end


        #######################################################################
        # Pinna-like resonance
        #######################################################################

        resonance =
            exp(
                -(
                    (
                        f -
                        (
                            7000.0 +
                            1000.0 *
                            elevation_factor
                        )
                    ) /
                    1800.0
                )^2
            )


        resonance_gain =
            1.0 +
            0.12 *
            resonance


        left[i] *=
            resonance_gain

        right[i] *=
            resonance_gain

    end


    ###########################################################################
    # RETURN
    ###########################################################################

    return HRTFResponse(

        left,
        right,
        frequencies
    )

end


###############################################################################
# ITD → SAMPLE DELAY
###############################################################################

function itd_to_samples(
    itd
)

    return Int(
        round(
            abs(itd) *
            FS
        )
    )

end


###############################################################################
# FRACTIONAL DELAY
###############################################################################

"""
Linear interpolation fractional delay.

A production implementation could use a higher-order fractional-delay filter.
"""

function fractional_delay(
    signal,
    delay
)

    n =
        length(signal)

    output =
        zeros(
            Float64,
            n
        )


    for i in 1:n

        source =
            i -
            delay


        if source >= 1 &&
           source <= n

            lower =
                floor(Int, source)

            upper =
                ceil(Int, source)


            if lower == upper

                output[i] =
                    signal[lower]

            else

                fraction =
                    source -
                    lower

                output[i] =
                    (
                        1.0 -
                        fraction
                    ) *
                    signal[lower] +
                    fraction *
                    signal[upper]
            end
        end
    end


    return output
end


###############################################################################
# FREQUENCY RESPONSE → FIR
###############################################################################

function response_to_fir(
    response;
    taps=512
)

    positive =
        response

    negative =
        conj.(
            positive[
                end-1:-1:2
            ]
        )


    full =
        vcat(
            positive,
            negative
        )


    impulse =
        real.(
            ifft(
                full
            )
        )


    taps =
        min(
            taps,
            length(impulse)
        )


    fir =
        impulse[
            1:taps
        ]


    fir .*=
        DSP.Windows.hann(
            taps
        )


    return fir

end


###############################################################################
# HRTF → FIR
###############################################################################

function hrtf_to_fir(
    hrtf::HRTFResponse;
    taps=512
)

    left =
        response_to_fir(
            hrtf.left;
            taps=taps
        )


    right =
        response_to_fir(
            hrtf.right;
            taps=taps
        )


    return left, right

end


###############################################################################
# SIGNAL GENERATOR
###############################################################################

function sine_signal(
    frequency,
    duration;
    amplitude=0.5
)

    n =
        Int(
            round(
                duration * FS
            )
        )


    t =
        collect(
            0:n-1
        ) ./ FS


    return amplitude .*
           sin.(
               2π *
               frequency *
               t
           )

end


###############################################################################
# MULTI-TONE TEST SIGNAL
###############################################################################

function music_test_signal(
    duration
)

    n =
        Int(
            round(
                duration *
                FS
            )
        )


    t =
        collect(
            0:n-1
        ) ./ FS


    signal =
        0.30 .* sin.(2π .* 220.0 .* t) .+
        0.20 .* sin.(2π .* 440.0 .* t) .+
        0.15 .* sin.(2π .* 880.0 .* t) .+
        0.10 .* sin.(2π .* 1760.0 .* t) .+
        0.08 .* sin.(2π .* 3520.0 .* t)


    return signal

end


###############################################################################
# BINAURAL RENDERER
###############################################################################

function spatialise(
    signal,
    listener::Listener,
    source::AudioSource;
    fft_size=4096,
    fir_taps=512
)

    ###########################################################################
    # RELATIVE POSITION
    ###########################################################################

    relative =
        relative_position(
            listener,
            source
        )


    ###########################################################################
    # GEOMETRY
    ###########################################################################

    azimuth =
        calculate_azimuth(
            relative
        )


    elevation =
        calculate_elevation(
            relative
        )


    distance =
        calculate_distance(
            relative
        )


    ###########################################################################
    # HRTF
    ###########################################################################

    hrtf =
        generate_hrtf(
            azimuth,
            elevation,
            fft_size
        )


    left_fir,
    right_fir =
        hrtf_to_fir(
            hrtf;
            taps=fir_taps
        )


    ###########################################################################
    # FILTER
    ###########################################################################

    left =
        DSP.conv(
            signal,
            left_fir
        )


    right =
        DSP.conv(
            signal,
            right_fir
        )


    ###########################################################################
    # ITD
    ###########################################################################

    itd =
        calculate_itd(
            azimuth
        )


    delay =
        itd_to_samples(
            itd
        )


    if azimuth > 0

        left =
            fractional_delay(
                left,
                delay
            )

    else

        right =
            fractional_delay(
                right,
                delay
            )

    end


    ###########################################################################
    # DISTANCE
    ###########################################################################

    gain =
        distance_gain(
            distance
        )


    left .*= gain

    right .*= gain


    ###########################################################################
    # OUTPUT
    ###########################################################################

    return (

        left=left,

        right=right,

        azimuth=azimuth,

        elevation=elevation,

        distance=distance,

        itd=itd
    )

end


###############################################################################
# HEAD TRACKING
###############################################################################

struct HeadPose

    yaw::Float64

    pitch::Float64

    roll::Float64

end


###############################################################################
# TRACKING FILTER
###############################################################################

mutable struct HeadTracker

    pose::HeadPose

    smoothing::Float64

end


function HeadTracker(
    ;
    smoothing=0.85
)

    return HeadTracker(

        HeadPose(
            0.0,
            0.0,
            0.0
        ),

        smoothing
    )

end


###############################################################################
# UPDATE TRACKER
###############################################################################

function update_tracker!(
    tracker::HeadTracker,
    measured_pose::HeadPose
)

    α =
        tracker.smoothing


    yaw =
        α *
        tracker.pose.yaw +
        (
            1.0 -
            α
        ) *
        measured_pose.yaw


    pitch =
        α *
        tracker.pose.pitch +
        (
            1.0 -
            α
        ) *
        measured_pose.pitch


    roll =
        α *
        tracker.pose.roll +
        (
            1.0 -
            α
        ) *
        measured_pose.roll


    tracker.pose =
        HeadPose(
            yaw,
            pitch,
            roll
        )


    return tracker.pose

end


###############################################################################
# APPLY HEAD TRACKING
###############################################################################

function listener_from_tracker(
    tracker::HeadTracker
)

    orientation =
        euler_to_quaternion(

            tracker.pose.yaw,

            tracker.pose.pitch,

            tracker.pose.roll
        )


    return Listener(

        Vec3(
            0.0,
            0.0,
            0.0
        ),

        orientation,

        Vec3(
            0.0,
            0.0,
            0.0
        )
    )

end


###############################################################################
# MOVING SOURCE
###############################################################################

function update_source(
    source::AudioSource,
    dt
)

    return AudioSource(

        source.position +
        source.velocity * dt,

        source.velocity,

        source.frequency,

        source.amplitude
    )

end


###############################################################################
# ROOM REFLECTION
###############################################################################

function generate_room_reflections(
    signal,
    room::Room
)

    ###########################################################################
    # Simplified early-reflection model
    ###########################################################################

    delays_ms = [

        7.0,
        13.0,
        21.0,
        31.0
    ]


    gains = [

        0.20,
        0.12,
        0.08,
        0.04
    ]


    output =
        copy(signal)


    for i in eachindex(delays_ms)

        delay =
            Int(
                round(
                    delays_ms[i] /
                    1000.0 *
                    FS
                )
            )


        delayed =
            zeros(
                length(signal)
            )


        if delay <
           length(signal)

            delayed[
                delay+1:end
            ] =
                signal[
                    1:end-delay
                ]
        end


        output .+=
            room.reflection_gain *
            gains[i] *
            delayed
    end


    return output

end


###############################################################################
# FULL SPATIAL ENGINE
###############################################################################

mutable struct SpatialAudioEngine

    tracker::HeadTracker

    fft_size::Int

    fir_taps::Int

    room::Room
end


function create_spatial_engine()

    room =
        Room(

            10.0,
            15.0,
            3.0,

            0.50,

            0.40
        )


    return SpatialAudioEngine(

        HeadTracker(
            smoothing=0.80
        ),

        4096,

        512,

        room
    )

end


###############################################################################
# PROCESS AUDIO
###############################################################################

function process_spatial_audio!(
    engine::SpatialAudioEngine,
    signal,
    source::AudioSource,
    measured_pose::HeadPose
)

    ###########################################################################
    # HEAD TRACKING
    ###########################################################################

    update_tracker!(
        engine.tracker,
        measured_pose
    )


    ###########################################################################
    # LISTENER
    ###########################################################################

    listener =
        listener_from_tracker(
            engine.tracker
        )


    ###########################################################################
    # ROOM
    ###########################################################################

    room_signal =
        generate_room_reflections(
            signal,
            engine.room
        )


    ###########################################################################
    # SPATIALISE
    ###########################################################################

    result =
        spatialise(
            room_signal,
            listener,
            source;
            fft_size=engine.fft_size,
            fir_taps=engine.fir_taps
        )


    return result

end


###############################################################################
# HEAD-MOVEMENT SIMULATION
###############################################################################

function simulate_head_motion(
    duration
)

    n =
        Int(
            round(
                duration *
                60.0
            )
        )


    poses =
        HeadPose[]


    for i in 1:n

        t =
            i /
            60.0


        yaw =
            0.35 *
            sin(
                2π *
                0.25 *
                t
            )


        pitch =
            0.10 *
            sin(
                2π *
                0.17 *
                t
            )


        roll =
            0.05 *
            sin(
                2π *
                0.12 *
                t
            )


        push!(
            poses,
            HeadPose(
                yaw,
                pitch,
                roll
            )
        )
    end


    return poses

end


###############################################################################
# HEAD-LOCKED SOURCE TEST
###############################################################################

function head_locked_demo()

    engine =
        create_spatial_engine()


    signal =
        music_test_signal(
            2.0
        )


    source =
        AudioSource(

            Vec3(
                0.0,
                0.0,
                5.0
            ),

            Vec3(
                0.0,
                0.0,
                0.0
            ),

            440.0,

            1.0
        )


    poses =
        simulate_head_motion(
            2.0
        )


    println()
    println(
        "=============================================================="
    )
    println(
        " HEAD-TRACKED SPATIAL AUDIO"
    )
    println(
        "=============================================================="
    )
    println()


    azimuths =
        Float64[]


    elevations =
        Float64[]


    for pose in poses

        result =
            process_spatial_audio!(
                engine,
                signal,
                source,
                pose
            )


        push!(
            azimuths,
            result.azimuth
        )


        push!(
            elevations,
            result.elevation
        )

    end


    t =
        collect(
            1:length(azimuths)
        ) ./ 60.0


    plot(
        t,
        azimuths .* 180.0 ./ π,
        xlabel="Time (s)",
        ylabel="Relative azimuth (degrees)",
        title="Head Tracking — Virtual Sound Source",
        label="Azimuth"
    )


    display(current())


    return (

        azimuths=azimuths,

        elevations=elevations
    )

end


###############################################################################
# SOURCE MOVEMENT DEMO
###############################################################################

function moving_source_demo()

    engine =
        create_spatial_engine()


    signal =
        sine_signal(
            440.0,
            0.10
        )


    source =
        AudioSource(

            Vec3(
                -5.0,
                0.0,
                5.0
            ),

            Vec3(
                2.0,
                0.0,
                0.0
            ),

            440.0,

            1.0
        )


    listener =
        listener_from_tracker(
            engine.tracker
        )


    azimuths =
        Float64[]


    distances =
        Float64[]


    current_source =
        source


    for i in 1:200

        result =
            spatialise(
                signal,
                listener,
                current_source;
                fft_size=4096,
                fir_taps=256
            )


        push!(
            azimuths,
            result.azimuth
        )


        push!(
            distances,
            result.distance
        )


        current_source =
            update_source(
                current_source,
                0.02
            )
    end


    t =
        collect(
            1:length(azimuths)
        ) .* 0.02


    plot(
        t,
        azimuths .* 180.0 ./ π,
        xlabel="Time (s)",
        ylabel="Azimuth (degrees)",
        title="Moving Spatial Audio Source",
        label="Source azimuth"
    )


    display(current())


    return (

        azimuths=azimuths,

        distances=distances
    )

end


###############################################################################
# SPATIAL LOCALISATION METRIC
###############################################################################

function localisation_accuracy(
    expected_azimuth,
    measured_azimuth
)

    error =
        abs(
            expected_azimuth -
            measured_azimuth
        )


    # Wrap angle

    error =
        min(
            error,
            2π - error
        )


    return max(
        0.0,
        1.0 -
        error / π
    )

end


###############################################################################
# HRTF VISUALISATION
###############################################################################

function plot_hrtf(
    azimuth
)

    hrtf =
        generate_hrtf(
            azimuth,
            0.0,
            4096
        )


    frequencies =
        hrtf.frequencies


    left_db =
        20.0 .* log10.(
            abs.(hrtf.left) .+
            1e-12
        )


    right_db =
        20.0 .* log10.(
            abs.(hrtf.right) .+
            1e-12
        )


    indices =
        findall(
            (frequencies .>= 20.0) .&
            (frequencies .<= 20_000.0)
        )


    plot(
        frequencies[indices],
        left_db[indices],
        xscale=:log10,
        xlabel="Frequency (Hz)",
        ylabel="Magnitude (dB)",
        title="Synthetic HRTF — $(round(azimuth*180/π))°",
        label="Left ear"
    )


    plot!(
        frequencies[indices],
        right_db[indices],
        label="Right ear"
    )


    display(current())

end


###############################################################################
# BINAURAL ENERGY
###############################################################################

function binaural_energy(
    left,
    right
)

    left_energy =
        sum(
            left .^ 2
        )


    right_energy =
        sum(
            right .^ 2
        )


    total =
        left_energy +
        right_energy


    return (

        left=left_energy,

        right=right_energy,

        total=total
    )

end


###############################################################################
# MAIN
###############################################################################

function main()

    println()
    println(
        "=============================================================="
    )

    println(
        " JULIA AIRPOD SPATIAL AUDIO ENGINE"
    )

    println(
        "=============================================================="
    )

    println()


    ###########################################################################
    # ENGINE
    ###########################################################################

    engine =
        create_spatial_engine()


    ###########################################################################
    # TEST SOURCE
    ###########################################################################

    source =
        AudioSource(

            Vec3(
                3.0,
                1.0,
                5.0
            ),

            Vec3(
                0.0,
                0.0,
                0.0
            ),

            440.0,

            1.0
        )


    ###########################################################################
    # TEST AUDIO
    ###########################################################################

    signal =
        music_test_signal(
            2.0
        )


    ###########################################################################
    # INITIAL HEAD POSE
    ###########################################################################

    pose =
        HeadPose(

            0.0,

            0.0,

            0.0
        )


    ###########################################################################
    # RENDER
    ###########################################################################

    result =
        process_spatial_audio!(
            engine,
            signal,
            source,
            pose
        )


    ###########################################################################
    # REPORT
    ###########################################################################

    println(
        "Source azimuth:   ",
        round(
            result.azimuth *
            180.0 / π,
            digits=2
        ),
        "°"
    )


    println(
        "Source elevation: ",
        round(
            result.elevation *
            180.0 / π,
            digits=2
        ),
        "°"
    )


    println(
        "Source distance:  ",
        round(
            result.distance,
            digits=2
        ),
        " m"
    )


    println(
        "ITD:              ",
        round(
            result.itd * 1e6,
            digits=2
        ),
        " μs"
    )


    println()


    ###########################################################################
    # ENERGY
    ###########################################################################

    energy =
        binaural_energy(
            result.left,
            result.right
        )


    println(
        "Left energy:      ",
        round(
            energy.left,
            digits=4
        )
    )


    println(
        "Right energy:     ",
        round(
            energy.right,
            digits=4
        )
    )


    ###########################################################################
    # HRTF
    ###########################################################################

    plot_hrtf(
        result.azimuth
    )


    ###########################################################################
    # HEAD TRACKING
    ###########################################################################

    head_locked_demo()


    ###########################################################################
    # MOVING SOURCE
    ###########################################################################

    moving_source_demo()


    return result

end


###############################################################################
# RUN
###############################################################################

result =
    main()
    
    
    
    
    ###############################################################################
# AIRPOD ADAPTIVE ANC ENGINE
#
# Real-time-style adaptive active noise cancellation simulation.
#
# Main components:
#
#   1. Reference microphone
#   2. Error microphone
#   3. Acoustic path model
#   4. Adaptive FIR filter
#   5. LMS / NLMS adaptation
#   6. Noise estimation
#   7. Frequency analysis
#   8. Automatic ANC strength control
#   9. Stability protection
#  10. Performance measurement
#
###############################################################################

using LinearAlgebra
using Statistics
using Random
using DSP
using FFTW
using Plots

Random.seed!(1234)

###############################################################################
# CONSTANTS
###############################################################################

const FS = 48_000

const MAX_FILTER_LENGTH = 256

const DEFAULT_FILTER_LENGTH = 128

const SPEED_OF_SOUND = 343.0

const EPSILON = 1e-9

###############################################################################
# ANC CONFIGURATION
###############################################################################

struct ANCConfig

    filter_length::Int

    learning_rate::Float64

    regularisation::Float64

    max_output::Float64

    adaptation_enabled::Bool

    target_attenuation_db::Float64

end


function default_anc_config()

    return ANCConfig(

        DEFAULT_FILTER_LENGTH,

        0.0025,

        1e-8,

        0.95,

        true,

        25.0
    )

end


###############################################################################
# MICROPHONE SIGNAL
###############################################################################

struct MicrophoneSignal

    samples::Vector{Float64}

    sample_rate::Int

end


###############################################################################
# ACOUSTIC PATH
###############################################################################

"""
Represents the acoustic transfer function from speaker to ear.

In a real AirPod this would be measured/calibrated from the physical system.
"""

struct AcousticPath

    impulse_response::Vector{Float64}

end


function default_acoustic_path()

    impulse = zeros(
        Float64,
        64
    )


    # Direct path

    impulse[1] = 0.70


    # Early reflections

    impulse[5] = 0.18

    impulse[11] = 0.08

    impulse[19] = 0.04


    return AcousticPath(
        impulse
    )

end


###############################################################################
# CONVOLVE SIGNAL WITH ACOUSTIC PATH
###############################################################################

function apply_acoustic_path(
    signal,
    path::AcousticPath
)

    return DSP.conv(
        signal,
        path.impulse_response
    )

end


###############################################################################
# NOISE GENERATORS
###############################################################################

function white_noise(
    n;
    amplitude=1.0
)

    return amplitude .* randn(n)

end


###############################################################################
# LOW FREQUENCY ENGINE NOISE
###############################################################################

function low_frequency_noise(
    duration;
    amplitude=1.0
)

    n =
        Int(
            round(
                duration * FS
            )
        )


    t =
        collect(
            0:n-1
        ) ./ FS


    signal =
        0.60 .* sin.(
            2π *
            90.0 *
            t
        )


    signal .+=
        0.35 .* sin.(
            2π *
            130.0 *
            t
        )


    signal .+=
        0.20 .* sin.(
            2π *
            210.0 *
            t
        )


    return amplitude .* signal

end


###############################################################################
# AIRCRAFT NOISE
###############################################################################

function aircraft_noise(
    duration;
    amplitude=1.0
)

    n =
        Int(
            round(
                duration * FS
            )
        )


    t =
        collect(
            0:n-1
        ) ./ FS


    signal =
        0.75 .* sin.(
            2π *
            110.0 *
            t
        )


    signal .+=
        0.35 .* sin.(
            2π *
            220.0 *
            t
        )


    signal .+=
        0.20 .* sin.(
            2π *
            330.0 *
            t
        )


    signal .+=
        0.12 .* randn(n)


    return amplitude .* signal

end


###############################################################################
# TRAIN NOISE
###############################################################################

function train_noise(
    duration;
    amplitude=1.0
)

    n =
        Int(
            round(
                duration * FS
            )
        )


    t =
        collect(
            0:n-1
        ) ./ FS


    signal =
        0.50 .* sin.(
            2π *
            65.0 *
            t
        )


    signal .+=
        0.40 .* sin.(
            2π *
            125.0 *
            t
        )


    signal .+=
        0.25 .* sin.(
            2π *
            250.0 *
            t
        )


    signal .+=
        0.15 .* randn(n)


    return amplitude .* signal

end


###############################################################################
# STREET NOISE
###############################################################################

function street_noise(
    duration;
    amplitude=1.0
)

    n =
        Int(
            round(
                duration * FS
            )
        )


    signal =
        amplitude .* randn(n)


    # Smooth the spectrum slightly

    kernel =
        ones(64) ./ 64


    signal =
        DSP.conv(
            signal,
            kernel
        )


    return signal[
        1:n
    ]

end


###############################################################################
# MULTI-ENVIRONMENT NOISE
###############################################################################

function changing_environment(
    duration
)

    n =
        Int(
            round(
                duration * FS
            )
        )


    segment =
        div(
            n,
            4
        )


    output =
        zeros(n)


    ###########################################################################
    # Aircraft
    ###########################################################################

    a =
        aircraft_noise(
            segment / FS;
            amplitude=1.0
        )


    output[
        1:segment
    ] .=
        a[
            1:segment
        ]


    ###########################################################################
    # Train
    ###########################################################################

    b =
        train_noise(
            segment / FS;
            amplitude=1.0
        )


    output[
        segment+1:2*segment
    ] .=
        b[
            1:segment
        ]


    ###########################################################################
    # Street
    ###########################################################################

    c =
        street_noise(
            segment / FS;
            amplitude=1.0
        )


    output[
        2*segment+1:3*segment
    ] .=
        c[
            1:segment
        ]


    ###########################################################################
    # Aircraft again
    ###########################################################################

    d =
        aircraft_noise(
            segment / FS;
            amplitude=0.7
        )


    output[
        3*segment+1:4*segment
    ] .=
        d[
            1:segment
        ]


    return output

end


###############################################################################
# DELAY LINE
###############################################################################

mutable struct DelayLine

    buffer::Vector{Float64}

    position::Int

end


function DelayLine(
    length::Int
)

    return DelayLine(

        zeros(length),

        1
    )

end


function push_delay!(
    delay_line::DelayLine,
    value
)

    output =
        delay_line.buffer[
            delay_line.position
        ]


    delay_line.buffer[
        delay_line.position
    ] =
        value


    delay_line.position += 1


    if delay_line.position >
       length(
           delay_line.buffer
       )

        delay_line.position = 1

    end


    return output

end


###############################################################################
# ADAPTIVE FIR FILTER
###############################################################################

mutable struct AdaptiveFIR

    weights::Vector{Float64}

    buffer::Vector{Float64}

    learning_rate::Float64

    regularisation::Float64

end


function AdaptiveFIR(
    config::ANCConfig
)

    return AdaptiveFIR(

        zeros(
            config.filter_length
        ),

        zeros(
            config.filter_length
        ),

        config.learning_rate,

        config.regularisation
    )

end


###############################################################################
# FILTER INPUT
###############################################################################

function filter_sample!(
    filter::AdaptiveFIR,
    input::Float64
)

    ###########################################################################
    # Shift input history
    ###########################################################################

    filter.buffer[2:end] .=
        filter.buffer[1:end-1]


    filter.buffer[1] =
        input


    ###########################################################################
    # FIR output
    ###########################################################################

    return dot(
        filter.weights,
        filter.buffer
    )

end


###############################################################################
# LMS UPDATE
###############################################################################

function lms_update!(
    filter::AdaptiveFIR,
    error::Float64
)

    ###########################################################################
    # LMS:
    #
    # w(n+1) = w(n) + μ e(n) x(n)
    #
    ###########################################################################

    filter.weights .+=
        filter.learning_rate *
        error *
        filter.buffer


end


###############################################################################
# NORMALISED LMS UPDATE
###############################################################################

function nlms_update!(
    filter::AdaptiveFIR,
    error::Float64
)

    ###########################################################################
    # NLMS:
    #
    # w(n+1) =
    #   w(n) +
    #   μ e(n)x(n)
    #   ----------------
    #     ||x(n)||² + ε
    #
    ###########################################################################

    energy =
        dot(
            filter.buffer,
            filter.buffer
        )


    step =
        filter.learning_rate *
        error /
        (
            energy +
            filter.regularisation
        )


    filter.weights .+=
        step *
        filter.buffer

end


###############################################################################
# FILTER STABILITY
###############################################################################

function constrain_filter!(
    filter::AdaptiveFIR
)

    ###########################################################################
    # Prevent runaway coefficients.
    ###########################################################################

    maximum_weight =
        maximum(
            abs,
            filter.weights
        )


    if maximum_weight >
       2.0

        filter.weights .*=
            2.0 /
            maximum_weight

    end

end


###############################################################################
# RMS
###############################################################################

function rms(
    signal
)

    return sqrt(
        mean(
            signal .^ 2
        ) +
        EPSILON
    )

end


###############################################################################
# DECIBEL CONVERSION
###############################################################################

function amplitude_to_db(
    x
)

    return 20.0 *
           log10(
               abs(x) +
               EPSILON
           )

end


###############################################################################
# ATTENUATION
###############################################################################

function attenuation_db(
    original,
    residual
)

    return amplitude_to_db(
        rms(original) /
        rms(residual)
    )

end


###############################################################################
# FREQUENCY SPECTRUM
###############################################################################

function spectrum(
    signal
)

    n =
        length(signal)


    fft_result =
        fft(
            signal
        )


    half =
        div(
            n,
            2
        )


    magnitude =
        abs.(
            fft_result[
                1:half
            ]
        )


    frequencies =
        collect(
            0:half-1
        ) .* FS ./ n


    return frequencies,
           magnitude

end


###############################################################################
# NOISE BAND ENERGY
###############################################################################

function band_energy(
    signal,
    low_frequency,
    high_frequency
)

    frequencies,
    magnitude =
        spectrum(
            signal
        )


    indices =
        findall(
            (frequencies .>= low_frequency) .&
            (frequencies .<= high_frequency)
        )


    if isempty(indices)

        return 0.0

    end


    return sum(
        magnitude[
            indices
        ] .^ 2
    )

end


###############################################################################
# ANC PROCESSOR
###############################################################################

mutable struct ANCProcessor

    config::ANCConfig

    adaptive_filter::AdaptiveFIR

    acoustic_path::AcousticPath

    output_gain::Float64

    enabled::Bool

end


function ANCProcessor(
    ;
    config=default_anc_config(),
    acoustic_path=default_acoustic_path()
)

    return ANCProcessor(

        config,

        AdaptiveFIR(
            config
        ),

        acoustic_path,

        1.0,

        true
    )

end


###############################################################################
# SINGLE-SAMPLE ANC
###############################################################################

function process_sample!(
    anc::ANCProcessor,
    reference_sample::Float64,
    error_sample::Float64
)

    ###########################################################################
    # ANC DISABLED
    ###########################################################################

    if !anc.enabled

        return 0.0

    end


    ###########################################################################
    # Generate anti-noise
    ###########################################################################

    anti_noise =
        filter_sample!(
            anc.adaptive_filter,
            reference_sample
        )


    ###########################################################################
    # Output limiter
    ###########################################################################

    anti_noise =
        clamp(
            anti_noise *
            anc.output_gain,

            -anc.config.max_output,

            anc.config.max_output
        )


    ###########################################################################
    # Adapt filter
    ###########################################################################

    if anc.config.adaptation_enabled

        nlms_update!(
            anc.adaptive_filter,
            error_sample
        )

        constrain_filter!(
            anc.adaptive_filter
        )

    end


    return anti_noise

end


###############################################################################
# ANC BLOCK PROCESSOR
###############################################################################

function process_block!(
    anc::ANCProcessor,
    reference,
    error_microphone
)

    n =
        min(
            length(reference),
            length(error_microphone)
        )


    anti_noise =
        zeros(n)


    residual =
        zeros(n)


    for i in 1:n

        #######################################################################
        # Estimate anti-noise
        #######################################################################

        anti_noise[i] =
            filter_sample!(
                anc.adaptive_filter,
                reference[i]
            )


        #######################################################################
        # Limit
        #######################################################################

        anti_noise[i] =
            clamp(
                anti_noise[i] *
                anc.output_gain,

                -anc.config.max_output,

                anc.config.max_output
            )


        #######################################################################
        # Error microphone
        #######################################################################

        residual[i] =
            error_microphone[i] -
            anti_noise[i]


        #######################################################################
        # Adapt
        #######################################################################

        if anc.config.adaptation_enabled

            nlms_update!(
                anc.adaptive_filter,
                residual[i]
            )

            constrain_filter!(
                anc.adaptive_filter
            )

        end

    end


    return anti_noise,
           residual

end


###############################################################################
# SECONDARY PATH MODEL
###############################################################################

function simulate_secondary_path(
    anti_noise,
    path::AcousticPath
)

    return apply_acoustic_path(
        anti_noise,
        path
    )

end


###############################################################################
# PHYSICAL ANC SIMULATION
###############################################################################

function simulate_anc(
    noise,
    anc::ANCProcessor
)

    n =
        length(noise)


    ###########################################################################
    # Reference microphone
    ###########################################################################

    reference =
        noise +
        0.01 .* randn(n)


    ###########################################################################
    # Initial error microphone
    #
    # Before cancellation:
    #
    #     error = noise
    #
    ###########################################################################

    error_microphone =
        copy(noise)


    ###########################################################################
    # Output buffers
    ###########################################################################

    anti_noise =
        zeros(n)


    residual =
        zeros(n)


    ###########################################################################
    # Block size
    ###########################################################################

    block_size =
        256


    ###########################################################################
    # Processing
    ###########################################################################

    for start in 1:block_size:n

        stop =
            min(
                start +
                block_size -
                1,

                n
            )


        ref_block =
            reference[
                start:stop
            ]


        error_block =
            error_microphone[
                start:stop
            ]


        anti_block,
        _ =
            process_block!(
                anc,
                ref_block,
                error_block
            )


        #######################################################################
        # Acoustic path
        #######################################################################

        generated =
            simulate_secondary_path(
                anti_block,
                anc.acoustic_path
            )


        valid_length =
            length(
                anti_block
            )


        #######################################################################
        # Apply cancellation
        #######################################################################

        for j in 1:valid_length

            if j <=
               length(generated)

                residual[
                    start+j-1
                ] =
                    noise[
                        start+j-1
                    ] -
                    generated[j]

            else

                residual[
                    start+j-1
                ] =
                    noise[
                        start+j-1
                    ]

            end


            anti_noise[
                start+j-1
            ] =
                anti_block[j]

        end

    end


    return (

        reference=reference,

        anti_noise=anti_noise,

        residual=residual
    )

end


###############################################################################
# ADAPTIVE ANC CONTROLLER
###############################################################################

mutable struct ANCController

    processor::ANCProcessor

    target_db::Float64

    minimum_gain::Float64

    maximum_gain::Float64

end


function ANCController()

    config =
        default_anc_config()


    return ANCController(

        ANCProcessor(
            config=config
        ),

        20.0,

        0.1,

        1.5
    )

end


###############################################################################
# ADAPT ANC OUTPUT
###############################################################################

function update_anc_gain!(
    controller::ANCController,
    original,
    residual
)

    achieved =
        attenuation_db(
            original,
            residual
        )


    ###########################################################################
    # If insufficient cancellation, increase output.
    ###########################################################################

    if achieved <
       controller.target_db

        controller.processor.output_gain =
            min(
                controller.processor.output_gain *
                1.03,

                controller.maximum_gain
            )

    else

        #######################################################################
        # If excessive cancellation is already achieved, reduce power.
        #######################################################################

        controller.processor.output_gain =
            max(
                controller.processor.output_gain *
                0.995,

                controller.minimum_gain
            )
    end


    return achieved

end


###############################################################################
# ANC PERFORMANCE BY FREQUENCY
###############################################################################

function frequency_attenuation(
    original,
    residual
)

    f1,
    m1 =
        spectrum(
            original
        )


    f2,
    m2 =
        spectrum(
            residual
        )


    n =
        min(
            length(m1),
            length(m2)
        )


    attenuation =
        zeros(n)


    for i in 1:n

        attenuation[i] =
            20.0 *
            log10(
                (
                    m1[i] +
                    EPSILON
                ) /
                (
                    m2[i] +
                    EPSILON
                )
            )
    end


    return (
        frequencies=f1[1:n],
        attenuation=attenuation
    )

end


###############################################################################
# MULTI-BAND ANC ANALYSIS
###############################################################################

function analyse_anc_bands(
    original,
    residual
)

    bands = [

        ("20-80 Hz", 20.0, 80.0),

        ("80-150 Hz", 80.0, 150.0),

        ("150-300 Hz", 150.0, 300.0),

        ("300-1000 Hz", 300.0, 1000.0),

        ("1-3 kHz", 1000.0, 3000.0),

        ("3-8 kHz", 3000.0, 8000.0),

        ("8-20 kHz", 8000.0, 20000.0)
    ]


    results = []


    for (
        name,
        low,
        high
    ) in bands

        original_energy =
            band_energy(
                original,
                low,
                high
            )


        residual_energy =
            band_energy(
                residual,
                low,
                high
            )


        attenuation =
            10.0 *
            log10(
                (
                    original_energy +
                    EPSILON
                ) /
                (
                    residual_energy +
                    EPSILON
                )
            )


        push!(
            results,
            (
                name=name,
                attenuation_db=attenuation
            )
        )

    end


    return results

end


###############################################################################
# ANC ENVIRONMENT CLASSIFICATION
###############################################################################

function classify_noise(
    signal
)

    low =
        band_energy(
            signal,
            20.0,
            300.0
        )


    mid =
        band_energy(
            signal,
            300.0,
            3000.0
        )


    high =
        band_energy(
            signal,
            3000.0,
            10000.0
        )


    total =
        low +
        mid +
        high +
        EPSILON


    low_ratio =
        low /
        total


    if low_ratio > 0.70

        return :LOW_FREQUENCY_DOMINANT

    elseif high > low

        return :HIGH_FREQUENCY_DOMINANT

    else

        return :BROADBAND

    end

end


###############################################################################
# AUTOMATIC ANC MODE
###############################################################################

function choose_anc_mode(
    noise
)

    category =
        classify_noise(
            noise
        )


    if category ==
       :LOW_FREQUENCY_DOMINANT

        return (
            learning_rate=0.0035,
            target_db=25.0
        )


    elseif category ==
           :HIGH_FREQUENCY_DOMINANT

        return (
            learning_rate=0.0015,
            target_db=12.0
        )


    else

        return (
            learning_rate=0.0025,
            target_db=20.0
        )

    end

end


###############################################################################
# ADAPT CONTROLLER TO ENVIRONMENT
###############################################################################

function adapt_to_environment!(
    controller::ANCController,
    noise
)

    mode =
        choose_anc_mode(
            noise
        )


    controller.processor.adaptive_filter.learning_rate =
        mode.learning_rate


    controller.target_db =
        mode.target_db


    return mode

end


###############################################################################
# ANC REPORT
###############################################################################

function anc_report(
    original,
    residual
)

    original_rms =
        rms(
            original
        )


    residual_rms =
        rms(
            residual
        )


    attenuation =
        attenuation_db(
            original,
            residual
        )


    println()
    println(
        "=============================================================="
    )
    println(
        " ANC PERFORMANCE REPORT"
    )
    println(
        "=============================================================="
    )
    println()


    println(
        "Original RMS:   ",
        round(
            original_rms,
            digits=5
        )
    )


    println(
        "Residual RMS:   ",
        round(
            residual_rms,
            digits=5
        )
    )


    println(
        "Total reduction:",
        round(
            attenuation,
            digits=2
        ),
        " dB"
    )


    println()


    println(
        "Frequency-band attenuation:"
    )


    bands =
        analyse_anc_bands(
            original,
            residual
        )


    for band in bands

        println(
            "  ",
            rpad(
                band.name,
                15
            ),
            " ",
            round(
                band.attenuation_db,
                digits=2
            ),
            " dB"
        )

    end


    println()

end


###############################################################################
# PLOT SIGNAL COMPARISON
###############################################################################

function plot_time_domain(
    original,
    residual;
    seconds=0.05
)

    n =
        min(
            length(original),
            Int(
                round(
                    seconds *
                    FS
                )
            )
        )


    t =
        collect(
            0:n-1
        ) ./ FS


    plot(
        t,
        original[
            1:n
        ],
        xlabel="Time (s)",
        ylabel="Amplitude",
        title="ANC — Original Noise",
        label="Original"
    )


    display(current())


    plot(
        t,
        residual[
            1:n
        ],
        xlabel="Time (s)",
        ylabel="Amplitude",
        title="ANC — Residual Noise",
        label="Residual"
    )


    display(current())

end


###############################################################################
# PLOT SPECTRUM
###############################################################################

function plot_spectrum_comparison(
    original,
    residual
)

    f1,
    m1 =
        spectrum(
            original
        )


    f2,
    m2 =
        spectrum(
            residual
        )


    indices1 =
        findall(
            (f1 .>= 20.0) .&
            (f1 .<= 10_000.0)
        )


    indices2 =
        findall(
            (f2 .>= 20.0) .&
            (f2 .<= 10_000.0)
        )


    db_original =
        20.0 .* log10.(
            m1[indices1] .+
            EPSILON
        )


    db_residual =
        20.0 .* log10.(
            m2[indices2] .+
            EPSILON
        )


    plot(
        f1[indices1],
        db_original,
        xscale=:log10,
        xlabel="Frequency (Hz)",
        ylabel="Magnitude (dB)",
        title="ANC Frequency Response",
        label="Original"
    )


    plot!(
        f2[indices2],
        db_residual,
        label="Residual"
    )


    display(current())

end


###############################################################################
# PLOT ATTENUATION
###############################################################################

function plot_attenuation(
    original,
    residual
)

    result =
        frequency_attenuation(
            original,
            residual
        )


    indices =
        findall(
            (result.frequencies .>= 20.0) .&
            (result.frequencies .<= 10_000.0)
        )


    plot(
        result.frequencies[indices],
        result.attenuation[indices],
        xscale=:log10,
        xlabel="Frequency (Hz)",
        ylabel="Attenuation (dB)",
        title="Adaptive ANC Attenuation",
        label="Attenuation"
    )


    hline!(
        [0.0],
        label="0 dB"
    )


    display(current())

end


###############################################################################
# CONVERGENCE ANALYSIS
###############################################################################

function convergence_analysis(
    noise,
    ;
    segment_seconds=0.10
)

    config =
        default_anc_config()


    anc =
        ANCProcessor(
            config=config
        )


    segment =
        Int(
            round(
                segment_seconds *
                FS
            )
        )


    number_segments =
        div(
            length(noise),
            segment
        )


    attenuation_history =
        Float64[]


    residual_history =
        Float64[]


    for i in 1:number_segments

        start =
            (i-1) *
            segment +
            1


        stop =
            i *
            segment


        block =
            noise[
                start:stop
            ]


        result =
            simulate_anc(
                block,
                anc
            )


        attenuation =
            attenuation_db(
                block,
                result.residual
            )


        push!(
            attenuation_history,
            attenuation
        )


        push!(
            residual_history,
            rms(
                result.residual
            )
        )

    end


    t =
        collect(
            1:length(
                attenuation_history
            )
        ) .* segment_seconds


    plot(
        t,
        attenuation_history,
        xlabel="Time (s)",
        ylabel="Attenuation (dB)",
        title="ANC Convergence",
        label="Cancellation"
    )


    display(current())


    return (

        time=t,

        attenuation=attenuation_history,

        residual=residual_history
    )

end


###############################################################################
# POWER ESTIMATION
###############################################################################

function estimate_anc_power(
    filter_length,
    sample_rate,
    adaptation_enabled
)

    ###########################################################################
    # Simplified computational cost model.
    ###########################################################################

    filtering_operations =
        filter_length *
        sample_rate


    adaptation_operations =
        if adaptation_enabled

            filter_length *
            sample_rate

        else

            0.0

        end


    total_operations =
        filtering_operations +
        adaptation_operations


    ###########################################################################
    # Approximate DSP power.
    ###########################################################################

    power_mw =
        4.0 +
        total_operations /
        1e6 *
        0.10


    return power_mw

end


###############################################################################
# POWER-AWARE ANC
###############################################################################

function optimise_anc_power(
    noise;
    target_attenuation=20.0
)

    candidates = [

        32,

        64,

        96,

        128,

        192,

        256
    ]


    best =
        nothing


    best_power =
        Inf


    for length in candidates

        config =
            ANCConfig(

                length,

                0.0025,

                1e-8,

                0.95,

                true,

                target_attenuation
            )


        anc =
            ANCProcessor(
                config=config
            )


        result =
            simulate_anc(
                noise,
                anc
            )


        achieved =
            attenuation_db(
                noise,
                result.residual
            )


        power =
            estimate_anc_power(
                length,
                FS,
                true
            )


        if achieved >=
           target_attenuation &&
           power < best_power

            best =
                (
                    filter_length=length,

                    attenuation=achieved,

                    power_mw=power
                )

            best_power =
                power
        end
    end


    return best

end


###############################################################################
# REAL-TIME BLOCK SIMULATOR
###############################################################################

mutable struct RealTimeANC

    anc::ANCProcessor

    block_size::Int

    latency_samples::Int

end


function RealTimeANC()

    return RealTimeANC(

        ANCProcessor(),

        128,

        0
    )

end


###############################################################################
# PROCESS REAL-TIME BLOCK
###############################################################################

function process_realtime_block!(
    realtime::RealTimeANC,
    reference,
    error
)

    start =
        1


    output =
        Float64[]


    while start <=
          length(reference)

        stop =
            min(
                start +
                realtime.block_size -
                1,

                length(reference)
            )


        reference_block =
            reference[
                start:stop
            ]


        error_block =
            error[
                start:stop
            ]


        anti_noise,
        residual =
            process_block!(
                realtime.anc,
                reference_block,
                error_block
            )


        append!(
            output,
            anti_noise
        )


        start =
            stop +
            1

    end


    return output

end


###############################################################################
# MAIN DEMONSTRATION
###############################################################################

function main()

    println()
    println(
        "=============================================================="
    )

    println(
        " JULIA AIRPOD ADAPTIVE ANC ENGINE"
    )

    println(
        "=============================================================="
    )

    println()


    ###########################################################################
    # CREATE NOISE
    ###########################################################################

    duration =
        4.0


    noise =
        changing_environment(
            duration
        )


    println(
        "Generated ",
        duration,
        " seconds of changing environmental noise."
    )


    ###########################################################################
    # CLASSIFY
    ###########################################################################

    classification =
        classify_noise(
            noise
        )


    println(
        "Noise classification: ",
        classification
    )


    ###########################################################################
    # CONTROLLER
    ###########################################################################

    controller =
        ANCController()


    ###########################################################################
    # ENVIRONMENT ADAPTATION
    ###########################################################################

    mode =
        adapt_to_environment!(
            controller,
            noise
        )


    println(
        "Learning rate: ",
        mode.learning_rate
    )


    println(
        "Target attenuation: ",
        mode.target_db,
        " dB"
    )


    ###########################################################################
    # ANC
    ###########################################################################

    result =
        simulate_anc(
            noise,
            controller.processor
        )


    ###########################################################################
    # REPORT
    ###########################################################################

    anc_report(
        noise,
        result.residual
    )


    ###########################################################################
    # POWER OPTIMISATION
    ###########################################################################

    optimal =
        optimise_anc_power(
            noise;
            target_attenuation=15.0
        )


    println()
    println(
        "=============================================================="
    )
    println(
        " POWER-AWARE ANC"
    )
    println(
        "=============================================================="
    )


    if optimal !== nothing

        println(
            "Selected filter length: ",
            optimal.filter_length
        )


        println(
            "Expected attenuation:   ",
            round(
                optimal.attenuation,
                digits=2
            ),
            " dB"
        )


        println(
            "Estimated DSP power:     ",
            round(
                optimal.power_mw,
                digits=2
            ),
            " mW"
        )

    else

        println(
            "No candidate satisfied the attenuation target."
        )

    end


    ###########################################################################
    # PLOTS
    ###########################################################################

    plot_time_domain(
        noise,
        result.residual
    )


    plot_spectrum_comparison(
        noise,
        result.residual
    )


    plot_attenuation(
        noise,
        result.residual
    )


    ###########################################################################
    # CONVERGENCE
    ###########################################################################

    convergence =
        convergence_analysis(
            noise
        )


    return (

        noise=noise,

        result=result,

        convergence=convergence,

        optimal=optimal
    )

end


###############################################################################
# RUN
###############################################################################

result =
    main()
    
    
    
    
    ###############################################################################
# AIRPOD WIND-NOISE CANCELLATION ENGINE
#
# Julia prototype for modelling and suppressing wind noise around
# miniature earbud microphones.
#
# Designed for:
#
#   - walking
#   - running
#   - cycling
#   - train / vehicle airflow
#   - outdoor environments
#
# Core concepts:
#
#   1. Wind-noise generation
#   2. Microphone turbulence model
#   3. Wind-speed estimation
#   4. Spectral analysis
#   5. Wind-state classification
#   6. Adaptive high-pass filtering
#   7. Multi-microphone correlation
#   8. Speech preservation
#   9. Real-time block processing
#  10. Performance measurement
#
###############################################################################

using DSP
using FFTW
using Statistics
using LinearAlgebra
using Random
using Plots

Random.seed!(1234)

###############################################################################
# GLOBAL PARAMETERS
###############################################################################

const FS = 48_000

const EPSILON = 1e-10

const SPEED_OF_SOUND = 343.0

###############################################################################
# WIND STATES
###############################################################################

@enum WindState begin

    NO_WIND

    LIGHT_WIND

    MODERATE_WIND

    STRONG_WIND

    EXTREME_WIND

end


###############################################################################
# WIND CONFIGURATION
###############################################################################

struct WindConfig

    speed_ms::Float64

    turbulence::Float64

    microphone_area::Float64

    microphone_distance::Float64

end


function WindConfig(
    speed_ms::Float64
)

    return WindConfig(

        speed_ms,

        min(
            1.0,
            speed_ms / 20.0
        ),

        1e-5,

        0.01
    )

end


###############################################################################
# WIND STATE CLASSIFICATION
###############################################################################

function classify_wind_speed(
    speed::Float64
)

    if speed < 1.5

        return NO_WIND

    elseif speed < 4.0

        return LIGHT_WIND

    elseif speed < 8.0

        return MODERATE_WIND

    elseif speed < 15.0

        return STRONG_WIND

    else

        return EXTREME_WIND

    end

end


###############################################################################
# WIND TURBULENCE GENERATOR
###############################################################################

function generate_wind_noise(
    duration::Float64,
    config::WindConfig
)

    n =
        Int(
            round(
                duration *
                FS
            )
        )


    ###########################################################################
    # White turbulence source
    ###########################################################################

    raw =
        randn(n)


    ###########################################################################
    # Wind is dominated by low-frequency turbulence.
    ###########################################################################

    lowpass =
        digitalfilter(
            Lowpass(
                1800.0;
                fs=FS
            ),
            Butterworth(4)
        )


    filtered =
        filt(
            lowpass,
            raw
        )


    ###########################################################################
    # Scale turbulence according to wind speed.
    #
    # Simplified aerodynamic relationship:
    #
    #       noise ∝ v^1.5
    #
    ###########################################################################

    amplitude =
        0.02 *
        (
            config.speed_ms + 0.1
        )^1.5


    ###########################################################################
    # Add very-low-frequency pressure fluctuations.
    ###########################################################################

    t =
        collect(
            0:n-1
        ) ./ FS


    pressure =
        0.4 .* sin.(
            2π *
            25.0 *
            t
        )


    pressure .+=
        0.25 .* sin.(
            2π *
            55.0 *
            t
        )


    ###########################################################################
    # Combine.
    ###########################################################################

    wind =
        amplitude .* filtered .+
        amplitude .* 0.25 .* pressure


    return wind

end


###############################################################################
# SPEECH-LIKE SIGNAL
###############################################################################

function generate_speech_like_signal(
    duration::Float64
)

    n =
        Int(
            round(
                duration *
                FS
            )
        )


    t =
        collect(
            0:n-1
        ) ./ FS


    ###########################################################################
    # Fundamental.
    ###########################################################################

    speech =
        0.5 .* sin.(
            2π *
            130.0 *
            t
        )


    ###########################################################################
    # Harmonics.
    ###########################################################################

    speech .+=
        0.20 .* sin.(
            2π *
            260.0 *
            t
        )


    speech .+=
        0.12 .* sin.(
            2π *
            390.0 *
            t
        )


    speech .+=
        0.08 .* sin.(
            2π *
            520.0 *
            t
        )


    ###########################################################################
    # Speech envelope.
    ###########################################################################

    envelope =
        0.65 .+
        0.35 .* sin.(
            2π *
            2.2 *
            t
        )


    return speech .* envelope

end


###############################################################################
# BREATHING / WIND BURSTS
###############################################################################

function generate_wind_gusts(
    duration::Float64,
    speed::Float64
)

    n =
        Int(
            round(
                duration *
                FS
            )
        )


    signal =
        zeros(n)


    number_gusts =
        max(
            1,
            Int(
                round(
                    duration *
                    speed /
                    4
                )
            )
        )


    for i in 1:number_gusts

        centre =
            rand(
                1:n
            )


        width =
            Int(
                round(
                    FS *
                    (
                        0.1 +
                        rand() *
                        0.8
                    )
                )
            )


        amplitude =
            0.1 +
            rand() *
            0.5


        first =
            max(
                1,
                centre -
                width
            )


        last =
            min(
                n,
                centre +
                width
            )


        for j in first:last

            distance =
                abs(
                    j -
                    centre
                )


            envelope =
                exp(
                    -(
                        distance /
                        max(
                            1,
                            width
                        )
                    )^2
                )


            signal[j] +=
                amplitude *
                envelope

        end

    end


    return signal

end


###############################################################################
# MICROPHONE WIND MODEL
###############################################################################

struct Microphone

    orientation::Vector{Float64}

    sensitivity::Float64

    wind_exposure::Float64

end


function default_microphone()

    return Microphone(

        [1.0, 0.0, 0.0],

        1.0,

        1.0

    )

end


###############################################################################
# MICROPHONE WIND RESPONSE
###############################################################################

function microphone_wind_response(
    wind,
    microphone::Microphone
)

    return (
        wind .*
        microphone.wind_exposure
        .*
        microphone.sensitivity
    )

end


###############################################################################
# TWO-MICROPHONE ARRAY
###############################################################################

struct MicrophoneArray

    outside::Microphone

    inside::Microphone

end


function default_microphone_array()

    return MicrophoneArray(

        Microphone(
            [1.0, 0.0, 0.0],
            1.0,
            1.0
        ),

        Microphone(
            [-1.0, 0.0, 0.0],
            0.8,
            0.35
        )

    )

end


###############################################################################
# CORRELATION
###############################################################################

function normalized_correlation(
    x,
    y
)

    n =
        min(
            length(x),
            length(y)
        )


    x =
        x[
            1:n
        ]


    y =
        y[
            1:n
        ]


    x_centered =
        x .-
        mean(x)


    y_centered =
        y .-
        mean(y)


    numerator =
        dot(
            x_centered,
            y_centered
        )


    denominator =
        sqrt(
            dot(
                x_centered,
                x_centered
            ) *
            dot(
                y_centered,
                y_centered
            )
        ) +
        EPSILON


    return numerator /
           denominator

end


###############################################################################
# RMS
###############################################################################

function rms(
    signal
)

    return sqrt(
        mean(
            signal .^ 2
        ) +
        EPSILON
    )

end


###############################################################################
# DECIBEL
###############################################################################

function db(
    value
)

    return 20.0 *
           log10(
               abs(value) +
               EPSILON
           )

end


###############################################################################
# FFT SPECTRUM
###############################################################################

function spectrum(
    signal
)

    n =
        length(signal)


    transformed =
        fft(
            signal
        )


    half =
        div(
            n,
            2
        )


    magnitude =
        abs.(
            transformed[
                1:half
            ]
        )


    frequency =
        collect(
            0:half-1
        ) .* FS ./ n


    return frequency,
           magnitude

end


###############################################################################
# BAND ENERGY
###############################################################################

function band_energy(
    signal,
    low_frequency,
    high_frequency
)

    frequency,
    magnitude =
        spectrum(
            signal
        )


    indices =
        findall(
            (frequency .>= low_frequency) .&
            (frequency .<= high_frequency)
        )


    if isempty(indices)

        return 0.0

    end


    return sum(
        magnitude[
            indices
        ] .^ 2
    )

end


###############################################################################
# WIND SPECTRAL INDEX
###############################################################################

function wind_spectral_index(
    signal
)

    ###########################################################################
    # Wind tends to create strong low-frequency energy.
    ###########################################################################

    low =
        band_energy(
            signal,
            20.0,
            250.0
        )


    mid =
        band_energy(
            signal,
            250.0,
            2000.0
        )


    high =
        band_energy(
            signal,
            2000.0,
            8000.0
        )


    return low /
           (
               low +
               mid +
               high +
               EPSILON
           )

end


###############################################################################
# WIND ESTIMATOR
###############################################################################

mutable struct WindEstimator

    estimated_speed::Float64

    spectral_index::Float64

    confidence::Float64

    state::WindState

end


function WindEstimator()

    return WindEstimator(

        0.0,

        0.0,

        0.0,

        NO_WIND

    )

end


###############################################################################
# ESTIMATE WIND
###############################################################################

function estimate_wind!(
    estimator::WindEstimator,
    signal
)

    ###########################################################################
    # Calculate low-frequency wind signature.
    ###########################################################################

    index =
        wind_spectral_index(
            signal
        )


    estimator.spectral_index =
        index


    ###########################################################################
    # Convert spectral index to approximate wind speed.
    #
    # This is a calibration model, not an aerodynamic measurement.
    ###########################################################################

    estimated_speed =
        20.0 *
        clamp(
            index,
            0.0,
            1.0
        )


    ###########################################################################
    # Temporal smoothing.
    ###########################################################################

    estimator.estimated_speed =
        0.85 *
        estimator.estimated_speed +
        0.15 *
        estimated_speed


    ###########################################################################
    # Confidence.
    ###########################################################################

    estimator.confidence =
        clamp(
            abs(
                index -
                0.5
            ) *
            2.0,

            0.0,

            1.0
        )


    estimator.state =
        classify_wind_speed(
            estimator.estimated_speed
        )


    return estimator

end


###############################################################################
# ADAPTIVE FILTER CONFIGURATION
###############################################################################

struct WindFilterConfig

    cutoff_hz::Float64

    transition_hz::Float64

    order::Int

end


###############################################################################
# WIND FILTER
###############################################################################

function make_wind_filter(
    config::WindFilterConfig
)

    return digitalfilter(

        Highpass(
            config.cutoff_hz;
            fs=FS
        ),

        Butterworth(
            config.order
        )

    )

end


###############################################################################
# SELECT FILTER BASED ON WIND
###############################################################################

function select_wind_filter(
    state::WindState
)

    if state == NO_WIND

        return WindFilterConfig(
            20.0,
            20.0,
            2
        )


    elseif state == LIGHT_WIND

        return WindFilterConfig(
            50.0,
            50.0,
            2
        )


    elseif state == MODERATE_WIND

        return WindFilterConfig(
            100.0,
            100.0,
            3
        )


    elseif state == STRONG_WIND

        return WindFilterConfig(
            180.0,
            180.0,
            4
        )


    else

        return WindFilterConfig(
            300.0,
            300.0,
            5
        )

    end

end


###############################################################################
# SPEECH PRESERVATION
###############################################################################

function speech_energy(
    signal
)

    return band_energy(
        signal,
        300.0,
        5000.0
    )

end


###############################################################################
# SPEECH PRESERVATION SCORE
###############################################################################

function speech_preservation_score(
    original,
    filtered
)

    original_energy =
        speech_energy(
            original
        )


    filtered_energy =
        speech_energy(
            filtered
        )


    return filtered_energy /
           (
               original_energy +
               EPSILON
           )

end


###############################################################################
# ADAPTIVE WIND PROCESSOR
###############################################################################

mutable struct WindProcessor

    estimator::WindEstimator

    microphone_array::MicrophoneArray

    current_state::WindState

    filter_config::WindFilterConfig

end


function WindProcessor()

    initial_config =
        select_wind_filter(
            NO_WIND
        )


    return WindProcessor(

        WindEstimator(),

        default_microphone_array(),

        NO_WIND,

        initial_config

    )

end


###############################################################################
# UPDATE FILTER
###############################################################################

function update_filter!(
    processor::WindProcessor
)

    processor.filter_config =
        select_wind_filter(
            processor.current_state
        )

end


###############################################################################
# PROCESS WIND
###############################################################################

function process_wind!(
    processor::WindProcessor,
    microphone_signal
)

    ###########################################################################
    # Estimate wind.
    ###########################################################################

    estimate_wind!(
        processor.estimator,
        microphone_signal
    )


    ###########################################################################
    # Update state.
    ###########################################################################

    processor.current_state =
        processor.estimator.state


    ###########################################################################
    # Update filter.
    ###########################################################################

    update_filter!(
        processor
    )


    ###########################################################################
    # Build filter.
    ###########################################################################

    filter =
        make_wind_filter(
            processor.filter_config
        )


    ###########################################################################
    # Apply filtering.
    ###########################################################################

    filtered =
        filt(
            filter,
            microphone_signal
        )


    return filtered

end


###############################################################################
# MULTI-MIC WIND SEPARATION
###############################################################################

function separate_wind_from_speech(
    outside_microphone,
    inside_microphone
)

    ###########################################################################
    # Wind is strongly correlated at exposed microphones.
    #
    # Speech is comparatively less correlated between differently positioned
    # microphones.
    ###########################################################################

    correlation =
        normalized_correlation(
            outside_microphone,
            inside_microphone
        )


    outside_rms =
        rms(
            outside_microphone
        )


    inside_rms =
        rms(
            inside_microphone
        )


    wind_ratio =
        correlation *
        outside_rms /
        (
            inside_rms +
            EPSILON
        )


    wind_ratio =
        clamp(
            wind_ratio,
            0.0,
            1.0
        )


    estimated_wind =
        wind_ratio .*
        outside_microphone


    estimated_speech =
        outside_microphone .-
        estimated_wind


    return (

        wind=estimated_wind,

        speech=estimated_speech,

        correlation=correlation

    )

end


###############################################################################
# ADAPTIVE MICROPHONE MIX
###############################################################################

function adaptive_microphone_mix(
    outside,
    inside,
    wind_state::WindState
)

    ###########################################################################
    # Under low wind, retain outside microphone information.
    ###########################################################################

    if wind_state == NO_WIND

        outside_weight = 0.65

        inside_weight = 0.35


    elseif wind_state == LIGHT_WIND

        outside_weight = 0.55

        inside_weight = 0.45


    elseif wind_state == MODERATE_WIND

        outside_weight = 0.35

        inside_weight = 0.65


    elseif wind_state == STRONG_WIND

        outside_weight = 0.20

        inside_weight = 0.80


    else

        outside_weight = 0.10

        inside_weight = 0.90

    end


    return (
        outside_weight .* outside +
        inside_weight .* inside
    )

end


###############################################################################
# REAL-TIME WIND PROCESSOR
###############################################################################

mutable struct RealTimeWindProcessor

    processor::WindProcessor

    block_size::Int

    history::Vector{Float64}

end


function RealTimeWindProcessor(
    ;
    block_size=256
)

    return RealTimeWindProcessor(

        WindProcessor(),

        block_size,

        Float64[]

    )

end


###############################################################################
# PROCESS REAL-TIME BLOCK
###############################################################################

function process_realtime!(
    realtime::RealTimeWindProcessor,
    microphone_signal
)

    output =
        zeros(
            length(
                microphone_signal
            )
        )


    start =
        1


    while start <=
          length(
              microphone_signal
          )

        stop =
            min(
                start +
                realtime.block_size -
                1,

                length(
                    microphone_signal
                )
            )


        block =
            microphone_signal[
                start:stop
            ]


        #######################################################################
        # Add history for better wind estimation.
        #######################################################################

        append!(
            realtime.history,
            block
        )


        #######################################################################
        # Keep bounded history.
        #######################################################################

        if length(
            realtime.history
        ) > 4096

            deleteat!(
                realtime.history,
                1:
                (
                    length(
                        realtime.history
                    ) -
                    4096
                )
            )

        end


        #######################################################################
        # Estimate using current block.
        #######################################################################

        processed =
            process_wind!(
                realtime.processor,
                block
            )


        output[
            start:stop
        ] .=
            processed


        start =
            stop +
            1

    end


    return output

end


###############################################################################
# WIND ATTENUATION
###############################################################################

function calculate_attenuation(
    original,
    processed
)

    return db(
        rms(original) /
        (
            rms(processed) +
            EPSILON
        )
    )

end


###############################################################################
# WIND IMPROVEMENT
###############################################################################

function wind_band_reduction(
    original,
    processed
)

    original_energy =
        band_energy(
            original,
            20.0,
            300.0
        )


    processed_energy =
        band_energy(
            processed,
            20.0,
            300.0
        )


    return 10.0 *
           log10(
               (
                   original_energy +
                   EPSILON
               ) /
               (
                   processed_energy +
                   EPSILON
               )
           )

end


###############################################################################
# PROCESS COMPLETE WIND SCENARIO
###############################################################################

function run_wind_scenario(
    wind_speed;
    duration=5.0
)

    println()
    println(
        "============================================================"
    )

    println(
        " WIND SCENARIO: ",
        wind_speed,
        " m/s"
    )

    println(
        "============================================================"
    )


    ###########################################################################
    # Wind.
    ###########################################################################

    config =
        WindConfig(
            wind_speed
        )


    wind =
        generate_wind_noise(
            duration,
            config
        )


    ###########################################################################
    # Gusts.
    ###########################################################################

    gusts =
        generate_wind_gusts(
            duration,
            wind_speed
        )


    wind .+=
        gusts


    ###########################################################################
    # Speech.
    ###########################################################################

    speech =
        generate_speech_like_signal(
            duration
        )


    ###########################################################################
    # Outside microphone.
    ###########################################################################

    outside =
        speech +
        wind


    ###########################################################################
    # Inside microphone sees less wind.
    ###########################################################################

    inside =
        0.80 .* speech +
        0.20 .* wind +
        0.01 .* randn(
            length(wind)
        )


    ###########################################################################
    # Wind processor.
    ###########################################################################

    processor =
        WindProcessor()


    ###########################################################################
    # Estimate wind.
    ###########################################################################

    estimate_wind!(
        processor.estimator,
        outside
    )


    processor.current_state =
        processor.estimator.state


    update_filter!(
        processor
    )


    ###########################################################################
    # Adaptive microphone mix.
    ###########################################################################

    mixed =
        adaptive_microphone_mix(
            outside,
            inside,
            processor.current_state
        )


    ###########################################################################
    # Wind filtering.
    ###########################################################################

    filtered =
        process_wind!(
            processor,
            mixed
        )


    ###########################################################################
    # Measurements.
    ###########################################################################

    total_reduction =
        calculate_attenuation(
            outside,
            filtered
        )


    wind_reduction =
        wind_band_reduction(
            outside,
            filtered
        )


    speech_score =
        speech_preservation_score(
            speech,
            filtered
        )


    ###########################################################################
    # Report.
    ###########################################################################

    println(
        "Estimated wind speed: ",
        round(
            processor.estimator.estimated_speed,
            digits=2
        ),
        " m/s"
    )


    println(
        "Wind state: ",
        processor.current_state
    )


    println(
        "Spectral index: ",
        round(
            processor.estimator.spectral_index,
            digits=3
        )
    )


    println(
        "Filter cutoff: ",
        processor.filter_config.cutoff_hz,
        " Hz"
    )


    println(
        "Overall reduction: ",
        round(
            total_reduction,
            digits=2
        ),
        " dB"
    )


    println(
        "Low-frequency reduction: ",
        round(
            wind_reduction,
            digits=2
        ),
        " dB"
    )


    println(
        "Speech preservation score: ",
        round(
            speech_score,
            digits=3
        )
    )


    return (

        wind=wind,

        speech=speech,

        outside=outside,

        inside=inside,

        mixed=mixed,

        filtered=filtered,

        state=processor.current_state,

        estimated_speed=
            processor.estimator.estimated_speed,

        reduction=
            wind_reduction,

        speech_score=
            speech_score

    )

end


###############################################################################
# PLOT WIND SCENARIO
###############################################################################

function plot_wind_scenario(
    result;
    seconds=0.10
)

    n =
        min(
            length(
                result.outside
            ),

            Int(
                round(
                    seconds *
                    FS
                )
            )
        )


    t =
        collect(
            0:n-1
        ) ./ FS


    ###########################################################################
    # Original microphone.
    ###########################################################################

    plot(
        t,
        result.outside[
            1:n
        ],
        xlabel="Time (s)",
        ylabel="Amplitude",
        title="Microphone Signal Before Wind Processing",
        label="Original"
    )


    display(current())


    ###########################################################################
    # Filtered microphone.
    ###########################################################################

    plot(
        t,
        result.filtered[
            1:n
        ],
        xlabel="Time (s)",
        ylabel="Amplitude",
        title="Microphone Signal After Wind Processing",
        label="Processed"
    )


    display(current())


    ###########################################################################
    # Spectrum.
    ###########################################################################

    f1,
    m1 =
        spectrum(
            result.outside
        )


    f2,
    m2 =
        spectrum(
            result.filtered
        )


    indices1 =
        findall(
            (f1 .>= 20.0) .&
            (f1 .<= 5000.0)
        )


    indices2 =
        findall(
            (f2 .>= 20.0) .&
            (f2 .<= 5000.0)
        )


    plot(
        f1[indices1],
        20 .* log10.(
            m1[indices1] .+
            EPSILON
        ),
        xscale=:log10,
        xlabel="Frequency (Hz)",
        ylabel="Magnitude (dB)",
        title="Wind Processing Spectrum",
        label="Before"
    )


    plot!(
        f2[indices2],
        20 .* log10.(
            m2[indices2] .+
            EPSILON
        ),
        label="After"
    )


    display(current())

end


###############################################################################
# WIND SPEED SWEEP
###############################################################################

function wind_speed_sweep()

    speeds = [

        0.0,

        1.0,

        2.0,

        4.0,

        6.0,

        8.0,

        12.0,

        16.0,

        20.0

    ]


    reductions =
        Float64[]


    speech_scores =
        Float64[]


    states =
        WindState[]


    for speed in speeds

        result =
            run_wind_scenario(
                speed;
                duration=2.0
            )


        push!(
            reductions,
            result.reduction
        )


        push!(
            speech_scores,
            result.speech_score
        )


        push!(
            states,
            result.state
        )

    end


    ###########################################################################
    # Reduction plot.
    ###########################################################################

    plot(
        speeds,
        reductions,
        xlabel="Wind speed (m/s)",
        ylabel="Low-frequency reduction (dB)",
        title="Wind Cancellation Performance",
        marker=:circle,
        label="Reduction"
    )


    display(current())


    ###########################################################################
    # Speech preservation.
    ###########################################################################

    plot(
        speeds,
        speech_scores,
        xlabel="Wind speed (m/s)",
        ylabel="Speech preservation",
        title="Speech Preservation Under Wind",
        marker=:circle,
        label="Speech"
    )


    display(current())


    return (

        speeds=speeds,

        reductions=reductions,

        speech_scores=speech_scores,

        states=states

    )

end


###############################################################################
# WIND / SPEECH SEPARATION DEMONSTRATION
###############################################################################

function demonstrate_microphone_separation()

    duration =
        3.0


    wind =
        generate_wind_noise(
            duration,
            WindConfig(
                10.0
            )
        )


    speech =
        generate_speech_like_signal(
            duration
        )


    outside =
        speech +
        wind


    inside =
        0.85 .* speech +
        0.15 .* wind


    result =
        separate_wind_from_speech(
            outside,
            inside
        )


    println()
    println(
        "============================================================"
    )

    println(
        " TWO-MICROPHONE WIND SEPARATION"
    )

    println(
        "============================================================"
    )


    println(
        "Microphone correlation: ",
        round(
            result.correlation,
            digits=4
        )
    )


    println(
        "Estimated wind RMS: ",
        round(
            rms(result.wind),
            digits=5
        )
    )


    println(
        "Estimated speech RMS: ",
        round(
            rms(result.speech),
            digits=5
        )
    )


    return result

end


###############################################################################
# MAIN
###############################################################################

function main()

    println()
    println(
        "################################################################"
    )

    println(
        "# JULIA AIRPOD WIND-NOISE CANCELLATION"
    )

    println(
        "################################################################"
    )

    println()


    ###########################################################################
    # Moderate outdoor wind.
    ###########################################################################

    result =
        run_wind_scenario(
            8.0;
            duration=5.0
        )


    ###########################################################################
    # Plot.
    ###########################################################################

    plot_wind_scenario(
        result
    )


    ###########################################################################
    # Microphone separation.
    ###########################################################################

    separation =
        demonstrate_microphone_separation()


    ###########################################################################
    # Speed sweep.
    ###########################################################################

    sweep =
        wind_speed_sweep()


    ###########################################################################
    # Real-time processor demonstration.
    ###########################################################################

    realtime =
        RealTimeWindProcessor()


    processed =
        process_realtime!(
            realtime,
            result.outside
        )


    println()
    println(
        "Real-time processor completed."
    )


    println(
        "Samples processed: ",
        length(processed)
    )


    println(
        "Final estimated wind speed: ",
        round(
            realtime.processor.estimator.estimated_speed,
            digits=2
        ),
        " m/s"
    )


    return (

        scenario=result,

        separation=separation,

        sweep=sweep,

        realtime=processed

    )

end


###############################################################################
# RUN
###############################################################################

result =
    main()
    
    
    
    
    
    ###############################################################################
# AIRPOD AUTOMATIC EQ OPTIMISATION ENGINE
#
# Julia prototype for automatic equalisation of an AirPod-style earphone.
#
# Features:
#
#   1. Frequency-response modelling
#   2. Target-response generation
#   3. Parametric EQ bands
#   4. Peaking EQ filters
#   5. Low-shelf EQ
#   6. High-shelf EQ
#   7. Frequency-weighted optimisation
#   8. Boost/cut penalties
#   9. Smoothness penalties
#  10. Profile generation
#  11. Adaptive EQ
#  12. Response plotting
#
###############################################################################

using DSP
using FFTW
using LinearAlgebra
using Statistics
using Random
using Plots

Random.seed!(1234)

###############################################################################
# CONSTANTS
###############################################################################

const FS = 48_000

const EPSILON = 1e-10

const MIN_FREQ = 20.0

const MAX_FREQ = 20_000.0

###############################################################################
# FREQUENCY GRID
###############################################################################

function log_frequency_grid(
    n::Int=512
)

    return exp10.(
        range(
            log10(MIN_FREQ),
            log10(MAX_FREQ),
            length=n
        )
    )

end


###############################################################################
# EQ BAND
###############################################################################

struct EQBand

    frequency::Float64

    gain_db::Float64

    Q::Float64

    type::Symbol

end


###############################################################################
# EQ CONFIGURATION
###############################################################################

struct EQConfiguration

    bands::Vector{EQBand}

end


###############################################################################
# STANDARD EQ PROFILES
###############################################################################

function neutral_eq()

    return EQConfiguration(

        [

            EQBand(
                80.0,
                0.0,
                0.8,
                :peaking
            ),

            EQBand(
                250.0,
                0.0,
                0.8,
                :peaking
            ),

            EQBand(
                1000.0,
                0.0,
                1.0,
                :peaking
            ),

            EQBand(
                4000.0,
                0.0,
                1.0,
                :peaking
            ),

            EQBand(
                10000.0,
                0.0,
                0.8,
                :peaking
            )

        ]

    )

end


###############################################################################
# PROFILE: CLASSICAL
###############################################################################

function classical_profile()

    return EQConfiguration(

        [

            EQBand(
                80.0,
                1.5,
                0.7,
                :peaking
            ),

            EQBand(
                250.0,
                -1.0,
                0.8,
                :peaking
            ),

            EQBand(
                1000.0,
                0.0,
                1.0,
                :peaking
            ),

            EQBand(
                4000.0,
                1.5,
                0.9,
                :peaking
            ),

            EQBand(
                10000.0,
                2.0,
                0.8,
                :peaking
            )

        ]

    )

end


###############################################################################
# PROFILE: ROCK
###############################################################################

function rock_profile()

    return EQConfiguration(

        [

            EQBand(
                80.0,
                3.0,
                0.8,
                :peaking
            ),

            EQBand(
                250.0,
                -1.0,
                0.9,
                :peaking
            ),

            EQBand(
                1000.0,
                1.0,
                1.0,
                :peaking
            ),

            EQBand(
                4000.0,
                2.5,
                1.0,
                :peaking
            ),

            EQBand(
                10000.0,
                2.0,
                0.8,
                :peaking
            )

        ]

    )

end


###############################################################################
# PROFILE: ELECTRONIC
###############################################################################

function electronic_profile()

    return EQConfiguration(

        [

            EQBand(
                60.0,
                4.0,
                0.7,
                :peaking
            ),

            EQBand(
                150.0,
                2.5,
                0.8,
                :peaking
            ),

            EQBand(
                500.0,
                -1.5,
                1.0,
                :peaking
            ),

            EQBand(
                3000.0,
                1.0,
                1.0,
                :peaking
            ),

            EQBand(
                10000.0,
                3.0,
                0.8,
                :peaking
            )

        ]

    )

end


###############################################################################
# PROFILE: PODCAST
###############################################################################

function podcast_profile()

    return EQConfiguration(

        [

            EQBand(
                100.0,
                -2.0,
                0.8,
                :peaking
            ),

            EQBand(
                300.0,
                -1.0,
                1.0,
                :peaking
            ),

            EQBand(
                1500.0,
                2.0,
                1.0,
                :peaking
            ),

            EQBand(
                3500.0,
                2.5,
                1.0,
                :peaking
            ),

            EQBand(
                8000.0,
                0.5,
                0.8,
                :peaking
            )

        ]

    )

end


###############################################################################
# PROFILE: SPEECH
###############################################################################

function speech_profile()

    return EQConfiguration(

        [

            EQBand(
                80.0,
                -3.0,
                0.8,
                :peaking
            ),

            EQBand(
                250.0,
                -1.5,
                0.8,
                :peaking
            ),

            EQBand(
                1000.0,
                1.5,
                1.0,
                :peaking
            ),

            EQBand(
                3000.0,
                3.0,
                1.0,
                :peaking
            ),

            EQBand(
                6000.0,
                1.5,
                0.9,
                :peaking
            )

        ]

    )

end


###############################################################################
# PEAKING EQ RESPONSE
###############################################################################

function peaking_response(
    frequencies,
    band::EQBand
)

    A =
        10.0 ^
        (
            band.gain_db /
            40.0
        )


    ω0 =
        2π *
        band.frequency /
        FS


    α =
        sin(ω0) /
        (
            2.0 *
            band.Q
        )


    b0 =
        1.0 +
        α *
        A


    b1 =
        -2.0 *
        cos(ω0)


    b2 =
        1.0 -
        α *
        A


    a0 =
        1.0 +
        α /
        A


    a1 =
        -2.0 *
        cos(ω0)


    a2 =
        1.0 -
        α /
        A


    response =
        zeros(
            ComplexF64,
            length(frequencies)
        )


    for i in eachindex(
        frequencies
    )

        ω =
            2π *
            frequencies[i] /
            FS


        z =
            exp(
                -im *
                ω
            )


        numerator =
            b0 +
            b1 * z +
            b2 * z^2


        denominator =
            a0 +
            a1 * z +
            a2 * z^2


        response[i] =
            numerator /
            denominator

    end


    return response

end


###############################################################################
# LOW-SHELF RESPONSE
###############################################################################

function lowshelf_response(
    frequencies,
    frequency,
    gain_db
)

    ###########################################################################
    # Smooth approximation used for optimisation.
    ###########################################################################

    ratio =
        frequencies /
        frequency


    transition =
        1.0 ./ (
            1.0 .+
            ratio .^ 4
        )


    return 10 .^ (
        (
            gain_db .* transition
        ) ./ 20
    )

end


###############################################################################
# HIGH-SHELF RESPONSE
###############################################################################

function highshelf_response(
    frequencies,
    frequency,
    gain_db
)

    ratio =
        frequencies /
        frequency


    transition =
        1.0 .- (
            1.0 ./ (
                1.0 .+
                ratio .^ 4
            )
        )


    return 10 .^ (
        (
            gain_db .* transition
        ) ./ 20
    )

end


###############################################################################
# COMPLETE EQ RESPONSE
###############################################################################

function eq_response(
    frequencies,
    configuration::EQConfiguration
)

    response =
        ones(
            ComplexF64,
            length(frequencies)
        )


    for band in configuration.bands

        if band.type ==
           :peaking

            response .*=
                peaking_response(
                    frequencies,
                    band
                )

        elseif band.type ==
               :lowshelf

            response .*=
                lowshelf_response(
                    frequencies,
                    band.frequency,
                    band.gain_db
                )

        elseif band.type ==
               :highshelf

            response .*=
                highshelf_response(
                    frequencies,
                    band.frequency,
                    band.gain_db
                )

        end

    end


    return response

end


###############################################################################
# SYNTHETIC AIRPOD RESPONSE
###############################################################################

function synthetic_airpod_response(
    frequencies
)

    ###########################################################################
    # Conceptual response model.
    #
    # This deliberately represents an imperfect transducer rather than
    # claiming to reproduce any particular Apple product measurement.
    ###########################################################################

    response =
        zeros(
            length(frequencies)
        )


    for i in eachindex(
        frequencies
    )

        f =
            frequencies[i]


        bass =
            2.5 *
            exp(
                -(
                    log10(f / 100.0)
                )^2 /
                0.18
            )


        lower_mid =
            -1.8 *
            exp(
                -(
                    log10(f / 500.0)
                )^2 /
                0.12
            )


        presence =
            1.5 *
            exp(
                -(
                    log10(f / 3000.0)
                )^2 /
                0.15
            )


        treble =
            -2.0 *
            exp(
                -(
                    log10(f / 9000.0)
                )^2 /
                0.20
            )


        response[i] =
            bass +
            lower_mid +
            presence +
            treble

    end


    return response

end


###############################################################################
# TARGET CURVES
###############################################################################

function target_flat(
    frequencies
)

    return zeros(
        length(frequencies)
    )

end


###############################################################################
# WARM TARGET
###############################################################################

function target_warm(
    frequencies
)

    target =
        zeros(
            length(frequencies)
        )


    for i in eachindex(
        frequencies
    )

        f =
            frequencies[i]


        target[i] =
            2.0 *
            exp(
                -(
                    log10(f / 100.0)
                )^2 /
                0.25
            ) -
            0.8 *
            exp(
                -(
                    log10(f / 3000.0)
                )^2 /
                0.20
            )

    end


    return target

end


###############################################################################
# TARGET DETAIL
###############################################################################

function target_detail(
    frequencies
)

    target =
        zeros(
            length(frequencies)
        )


    for i in eachindex(
        frequencies
    )

        f =
            frequencies[i]


        target[i] =
            1.0 *
            exp(
                -(
                    log10(f / 3000.0)
                )^2 /
                0.15
            )


        target[i] +=
            1.5 *
            exp(
                -(
                    log10(f / 10000.0)
                )^2 /
                0.20
            )

    end


    return target

end


###############################################################################
# PERCEPTUAL WEIGHTING
###############################################################################

function perceptual_weights(
    frequencies
)

    weights =
        ones(
            length(
                frequencies
            )
        )


    for i in eachindex(
        frequencies
    )

        f =
            frequencies[i]


        if f < 60.0

            weights[i] = 0.5

        elseif f < 250.0

            weights[i] = 1.0

        elseif f < 4000.0

            weights[i] = 1.5

        elseif f < 10000.0

            weights[i] = 1.2

        else

            weights[i] = 0.8

        end

    end


    return weights

end


###############################################################################
# RESPONSE ERROR
###############################################################################

function response_error(
    actual,
    target,
    weights
)

    return sum(
        weights .* (
            actual .-
            target
        ).^2
    ) /
    sum(weights)

end


###############################################################################
# EQ REGULARISATION
###############################################################################

function eq_penalty(
    configuration::EQConfiguration
)

    penalty =
        0.0


    ###########################################################################
    # Penalise large boosts/cuts.
    ###########################################################################

    for band in configuration.bands

        penalty +=
            0.05 *
            band.gain_db^2

    end


    ###########################################################################
    # Penalise large changes between adjacent bands.
    ###########################################################################

    for i in 1:length(
        configuration.bands
    )-1

        g1 =
            configuration.bands[i].gain_db


        g2 =
            configuration.bands[i+1].gain_db


        penalty +=
            0.02 *
            (
                g2 -
                g1
            )^2

    end


    return penalty

end


###############################################################################
# COMPLETE COST FUNCTION
###############################################################################

function eq_cost(
    gains,
    frequencies,
    measured_response,
    target,
    weights,
    base_configuration
)

    bands =
        EQBand[]


    for i in eachindex(
        base_configuration.bands
    )

        old =
            base_configuration.bands[i]


        push!(
            bands,

            EQBand(
                old.frequency,
                gains[i],
                old.Q,
                old.type
            )
        )

    end


    configuration =
        EQConfiguration(
            bands
        )


    eq =
        eq_response(
            frequencies,
            configuration
        )


    eq_db =
        20 .* log10.(
            abs.(eq) .+
            EPSILON
        )


    final_response =
        measured_response +
        eq_db


    error =
        response_error(
            final_response,
            target,
            weights
        )


    penalty =
        eq_penalty(
            configuration
        )


    return error +
           penalty

end


###############################################################################
# RANDOM EQ OPTIMISER
###############################################################################

function optimise_eq(
    frequencies,
    measured_response,
    target;
    iterations=10_000
)

    configuration =
        neutral_eq()


    weights =
        perceptual_weights(
            frequencies
        )


    best_gains =
        [
            band.gain_db
            for band in
            configuration.bands
        ]


    best_cost =
        eq_cost(
            best_gains,
            frequencies,
            measured_response,
            target,
            weights,
            configuration
        )


    ###########################################################################
    # Random coordinate search.
    ###########################################################################

    for iteration in 1:iterations

        candidate =
            copy(
                best_gains
            )


        #######################################################################
        # Modify one or more EQ bands.
        #######################################################################

        number_changes =
            rand(
                1:length(candidate)
            )


        for j in 1:number_changes

            index =
                rand(
                    eachindex(candidate)
                )


            candidate[index] +=
                randn() *
                0.5


            candidate[index] =
                clamp(
                    candidate[index],
                    -8.0,
                    8.0
                )

        end


        candidate_cost =
            eq_cost(
                candidate,
                frequencies,
                measured_response,
                target,
                weights,
                configuration
            )


        if candidate_cost <
           best_cost

            best_cost =
                candidate_cost


            best_gains =
                candidate

        end

    end


    ###########################################################################
    # Construct final EQ.
    ###########################################################################

    final_bands =
        EQBand[]


    for i in eachindex(
        configuration.bands
    )

        old =
            configuration.bands[i]


        push!(
            final_bands,

            EQBand(
                old.frequency,
                best_gains[i],
                old.Q,
                old.type
            )
        )

    end


    return (
        configuration=EQConfiguration(
            final_bands
        ),

        cost=best_cost,

        gains=best_gains

    )

end


###############################################################################
# LOCAL REFINEMENT
###############################################################################

function refine_eq(
    result,
    frequencies,
    measured_response,
    target
)

    configuration =
        result.configuration


    weights =
        perceptual_weights(
            frequencies
        )


    gains =
        copy(
            result.gains
        )


    current_cost =
        result.cost


    step =
        0.25


    for iteration in 1:1000

        improved =
            false


        for i in eachindex(
            gains
        )

            for direction in (
                -1.0,
                1.0
            )

                candidate =
                    copy(
                        gains
                    )


                candidate[i] +=
                    direction *
                    step


                candidate[i] =
                    clamp(
                        candidate[i],
                        -8.0,
                        8.0
                    )


                cost =
                    eq_cost(
                        candidate,
                        frequencies,
                        measured_response,
                        target,
                        weights,
                        configuration
                    )


                if cost <
                   current_cost

                    gains =
                        candidate


                    current_cost =
                        cost


                    improved =
                        true

                end

            end

        end


        if !improved

            step *=
                0.5

        end


        if step <
           0.01

            break

        end

    end


    final_bands =
        EQBand[]


    for i in eachindex(
        configuration.bands
    )

        old =
            configuration.bands[i]


        push!(
            final_bands,

            EQBand(
                old.frequency,
                gains[i],
                old.Q,
                old.type
            )
        )

    end


    return (

        configuration=
            EQConfiguration(
                final_bands
            ),

        gains=gains,

        cost=current_cost

    )

end


###############################################################################
# APPLY EQ TO SIGNAL
###############################################################################

function apply_eq_to_signal(
    signal,
    configuration::EQConfiguration
)

    output =
        copy(signal)


    for band in configuration.bands

        if band.type ==
           :peaking

            ###################################################################
            # Convert peaking EQ to a biquad.
            ###################################################################

            A =
                10.0 ^
                (
                    band.gain_db /
                    40.0
                )


            ω0 =
                2π *
                band.frequency /
                FS


            α =
                sin(ω0) /
                (
                    2.0 *
                    band.Q
                )


            b0 =
                1 +
                α * A


            b1 =
                -2 *
                cos(ω0)


            b2 =
                1 -
                α * A


            a0 =
                1 +
                α / A


            a1 =
                -2 *
                cos(ω0)


            a2 =
                1 -
                α / A


            b =
                [
                    b0 / a0,
                    b1 / a0,
                    b2 / a0
                ]


            a =
                [
                    1.0,
                    a1 / a0,
                    a2 / a0
                ]


            output =
                filt(
                    DSP.Filters.Biquad(
                        b,
                        a
                    ),
                    output
                )

        end

    end


    return output

end


###############################################################################
# GAIN LIMITER
###############################################################################

function limit_eq_gain(
    signal,
    maximum=0.95
)

    peak =
        maximum(
            abs,
            signal
        )


    if peak >
       maximum

        return signal .*
               (
                   maximum /
                   peak
               )

    end


    return signal

end


###############################################################################
# TARGET MATCHING
###############################################################################

function evaluate_eq(
    frequencies,
    measured,
    target,
    configuration
)

    eq =
        eq_response(
            frequencies,
            configuration
        )


    eq_db =
        20 .* log10.(
            abs.(eq) .+
            EPSILON
        )


    final =
        measured +
        eq_db


    weights =
        perceptual_weights(
            frequencies
        )


    error =
        response_error(
            final,
            target,
            weights
        )


    return (

        response=final,

        error=error,

        rms_error=
            sqrt(error)

    )

end


###############################################################################
# PROFILE COMPARISON
###############################################################################

function evaluate_profiles(
    frequencies,
    measured
)

    profiles = Dict(

        "Neutral" =>
            neutral_eq(),

        "Classical" =>
            classical_profile(),

        "Rock" =>
            rock_profile(),

        "Electronic" =>
            electronic_profile(),

        "Podcast" =>
            podcast_profile(),

        "Speech" =>
            speech_profile()

    )


    target =
        target_flat(
            frequencies
        )


    results =
        Dict()


    for (
        name,
        configuration
    ) in profiles

        results[name] =
            evaluate_eq(
                frequencies,
                measured,
                target,
                configuration
            )

    end


    return results

end


###############################################################################
# ADAPTIVE EQ CONTEXT
###############################################################################

@enum ListeningContext begin

    MUSIC

    PODCAST

    SPEECH

    CINEMA

    GAMING

end


###############################################################################
# CONTEXT PROFILE
###############################################################################

function profile_for_context(
    context::ListeningContext
)

    if context == MUSIC

        return neutral_eq()

    elseif context == PODCAST

        return podcast_profile()

    elseif context == SPEECH

        return speech_profile()

    elseif context == CINEMA

        return classical_profile()

    elseif context == GAMING

        return electronic_profile()

    end

end


###############################################################################
# LOUDNESS COMPENSATION
###############################################################################

function loudness_compensation(
    frequencies,
    volume
)

    ###########################################################################
    # Simple conceptual equal-loudness compensation.
    #
    # Lower volumes receive more bass compensation.
    ###########################################################################

    compensation =
        zeros(
            length(
                frequencies
            )
        )


    bass_factor =
        clamp(
            (
                0.7 -
                volume
            ) *
            10.0,

            0.0,

            4.0
        )


    for i in eachindex(
        frequencies
    )

        f =
            frequencies[i]


        compensation[i] =
            bass_factor *
            exp(
                -(
                    log10(f / 100.0)
                )^2 /
                0.25
            )

    end


    return compensation

end


###############################################################################
# ADAPTIVE LOUDNESS EQ
###############################################################################

function apply_loudness_compensation(
    configuration::EQConfiguration,
    volume::Float64
)

    bands =
        EQBand[]


    for band in configuration.bands

        compensation =
            if band.frequency < 250.0

                (
                    0.7 -
                    volume
                ) *
                3.0

            else

                0.0

            end


        gain =
            band.gain_db +
            compensation


        gain =
            clamp(
                gain,
                -8.0,
                8.0
            )


        push!(
            bands,

            EQBand(
                band.frequency,
                gain,
                band.Q,
                band.type
            )

        )

    end


    return EQConfiguration(
        bands
    )

end


###############################################################################
# PLOT RESPONSE
###############################################################################

function plot_eq_response(
    frequencies,
    measured,
    target,
    configuration
)

    eq =
        eq_response(
            frequencies,
            configuration
        )


    eq_db =
        20 .* log10.(
            abs.(eq) .+
            EPSILON
        )


    final =
        measured +
        eq_db


    plot(
        frequencies,
        measured,
        xscale=:log10,
        xlabel="Frequency (Hz)",
        ylabel="Response (dB)",
        title="Automatic EQ Optimisation",
        label="Measured"
    )


    plot!(
        frequencies,
        target,
        label="Target"
    )


    plot!(
        frequencies,
        final,
        label="Optimised"
    )


    display(current())

end


###############################################################################
# EQ TABLE
###############################################################################

function print_eq(
    configuration::EQConfiguration
)

    println()
    println(
        "=========================================================="
    )

    println(
        " OPTIMISED EQ"
    )

    println(
        "=========================================================="
    )


    for (
        i,
        band
    ) in enumerate(
        configuration.bands
    )

        println(
            "Band ",
            i,
            ": ",
            round(
                band.frequency,
                digits=1
            ),
            " Hz   ",
            round(
                band.gain_db,
                digits=2
            ),
            " dB   Q=",
            round(
                band.Q,
                digits=2
            )
        )

    end


    println()

end


###############################################################################
# SIMULATE EAR RESPONSE VARIATION
###############################################################################

function generate_ear_variation(
    frequencies;
    variation_strength=1.0
)

    variation =
        zeros(
            length(
                frequencies
            )
        )


    for i in eachindex(
        frequencies
    )

        f =
            frequencies[i]


        #######################################################################
        # Individual low-frequency variation.
        #######################################################################

        variation[i] +=
            variation_strength *
            2.0 *
            sin(
                log(
                    f /
                    70.0
                )
            )


        #######################################################################
        # Midrange variation.
        #######################################################################

        variation[i] +=
            variation_strength *
            1.2 *
            sin(
                log(
                    f /
                    500.0
                ) *
                2.0
            )


        #######################################################################
        # Treble variation.
        #######################################################################

        variation[i] +=
            variation_strength *
            1.8 *
            sin(
                log(
                    f /
                    6000.0
                ) *
                1.5
            )

    end


    return variation

end


###############################################################################
# PERSONALISED EQ
###############################################################################

function personalise_eq(
    frequencies,
    base_response,
    target;
    iterations=5000
)

    ###########################################################################
    # Add simulated ear-to-ear variation.
    ###########################################################################

    personalised_response =
        base_response +
        generate_ear_variation(
            frequencies
        )


    ###########################################################################
    # Optimise.
    ###########################################################################

    result =
        optimise_eq(
            frequencies,
            personalised_response,
            target;
            iterations=iterations
        )


    result =
        refine_eq(
            result,
            frequencies,
            personalised_response,
            target
        )


    return (

        measured=
            personalised_response,

        result=result

    )

end


###############################################################################
# MAIN
###############################################################################

function main()

    println()
    println(
        "############################################################"
    )

    println(
        "# JULIA AIRPOD AUTOMATIC EQ ENGINE"
    )

    println(
        "############################################################"
    )

    println()


    ###########################################################################
    # Frequency grid.
    ###########################################################################

    frequencies =
        log_frequency_grid(
            512
        )


    ###########################################################################
    # Simulated AirPod response.
    ###########################################################################

    measured =
        synthetic_airpod_response(
            frequencies
        )


    ###########################################################################
    # Desired target.
    ###########################################################################

    target =
        target_flat(
            frequencies
        )


    ###########################################################################
    # Optimisation.
    ###########################################################################

    println(
        "Optimising EQ..."
    )


    result =
        optimise_eq(
            frequencies,
            measured,
            target;
            iterations=5000
        )


    ###########################################################################
    # Refinement.
    ###########################################################################

    result =
        refine_eq(
            result,
            frequencies,
            measured,
            target
        )


    ###########################################################################
    # Print final EQ.
    ###########################################################################

    print_eq(
        result.configuration
    )


    ###########################################################################
    # Evaluate.
    ###########################################################################

    evaluation =
        evaluate_eq(
            frequencies,
            measured,
            target,
            result.configuration
        )


    println(
        "Weighted response error: ",
        round(
            evaluation.error,
            digits=4
        )
    )


    println(
        "RMS response error: ",
        round(
            evaluation.rms_error,
            digits=4
        ),
        " dB"
    )


    ###########################################################################
    # Plot.
    ###########################################################################

    plot_eq_response(
        frequencies,
        measured,
        target,
        result.configuration
    )


    ###########################################################################
    # Personalised ear simulation.
    ###########################################################################

    personalised =
        personalise_eq(
            frequencies,
            measured,
            target;
            iterations=3000
        )


    println()
    println(
        "Personalised EQ:"
    )


    print_eq(
        personalised.result.result.configuration
    )


    ###########################################################################
    # Loudness compensation.
    ###########################################################################

    low_volume_eq =
        apply_loudness_compensation(
            result.configuration,
            0.35
        )


    println(
        "Low-volume EQ:"
    )


    print_eq(
        low_volume_eq
    )


    ###########################################################################
    # Context profiles.
    ###########################################################################

    println(
        "Available adaptive contexts:"
    )


    for context in instances(
        ListeningContext
    )

        println(
            "  ",
            context
        )

    end


    return (

        frequencies=frequencies,

        measured=measured,

        target=target,

        optimised=result,

        personalised=personalised,

        low_volume=low_volume_eq

    )

end


###############################################################################
# RUN
###############################################################################

result =
    main()
    
    
    
    
    
    
    # ============================================================
# AirPod Fit & Seal Detection
# Julia prototype
#
# Estimates earbud fit/seal quality from acoustic response.
#
# States:
#   GOOD
#   PARTIAL
#   POOR
#   OUT_OF_EAR
#
# This is a computational-acoustics prototype rather than
# Apple's actual AirPods implementation.
# ============================================================

using DSP
using FFTW
using LinearAlgebra
using Statistics
using Random
using Plots

# ------------------------------------------------------------
# GLOBAL PARAMETERS
# ------------------------------------------------------------

const FS = 48_000
const EPSILON = 1e-10

const TEST_DURATION = 0.50
const TEST_SAMPLES = Int(round(FS * TEST_DURATION))

# Frequency bands particularly useful for detecting seal quality
const LOW_BAND = (40.0, 300.0)
const MID_BAND = (300.0, 3000.0)
const HIGH_BAND = (3000.0, 12000.0)

# ------------------------------------------------------------
# FIT STATES
# ------------------------------------------------------------

@enum FitState begin
    GOOD
    PARTIAL
    POOR
    OUT_OF_EAR
end

# ------------------------------------------------------------
# FIT RESULT
# ------------------------------------------------------------

struct FitResult
    state::FitState
    seal_quality::Float64
    confidence::Float64

    low_frequency_energy::Float64
    low_mid_ratio::Float64
    spectral_slope::Float64
    leakage_index::Float64
    channel_balance::Float64
end

# ------------------------------------------------------------
# FREQUENCY VECTOR
# ------------------------------------------------------------

function frequency_vector(n::Int, fs::Float64)

    return collect(0:n-1) .* fs ./ n

end

# ------------------------------------------------------------
# LOG FREQUENCY SWEEP
# ------------------------------------------------------------

function log_sweep(
    duration::Float64,
    f_start::Float64,
    f_end::Float64,
    fs::Int
)

    n = Int(round(duration * fs))

    t = collect(0:n-1) ./ fs

    k = log(f_end / f_start) / duration

    phase = 2π * f_start .* (exp.(k .* t) .- 1.0) ./ k

    return sin.(phase)

end

# ------------------------------------------------------------
# TEST SIGNAL
# ------------------------------------------------------------

function generate_fit_test_signal()

    sweep = log_sweep(
        TEST_DURATION,
        30.0,
        12_000.0,
        FS
    )

    # Small low-level broadband component
    noise = 0.01 .* randn(length(sweep))

    return 0.8 .* sweep .+ noise

end

# ------------------------------------------------------------
# SYNTHETIC EAR / SEAL RESPONSE
#
# These functions simulate what different levels of leakage
# do to the measured microphone response.
# ------------------------------------------------------------

function seal_response(
    frequencies::Vector{Float64},
    quality::Float64
)

    response = ones(length(frequencies))

    for i in eachindex(frequencies)

        f = frequencies[i]

        # Excellent seal preserves bass.
        #
        # As seal quality decreases, low frequencies are
        # progressively attenuated.

        if f < 300

            leakage = 1.0 - quality

            attenuation =
                1.0 -
                leakage *
                (1.0 - f / 300.0) *
                0.75

            response[i] *= attenuation

        end

        # Poor seals also alter upper-mid response slightly.

        if f > 3000

            response[i] *=
                1.0 -
                0.05 * (1.0 - quality)

        end

    end

    return response

end

# ------------------------------------------------------------
# APPLY SYNTHETIC ACOUSTIC RESPONSE
# ------------------------------------------------------------

function apply_acoustic_response(
    signal::Vector{Float64},
    quality::Float64
)

    n = length(signal)

    spectrum = fft(signal)

    freqs = frequency_vector(n, FS)

    response = seal_response(freqs, quality)

    filtered = real.(ifft(spectrum .* response))

    return filtered

end

# ------------------------------------------------------------
# ADD MICROPHONE NOISE
# ------------------------------------------------------------

function add_microphone_noise(
    signal::Vector{Float64},
    noise_level::Float64
)

    return signal .+
           noise_level .* randn(length(signal))

end

# ------------------------------------------------------------
# POWER SPECTRUM
# ------------------------------------------------------------

function power_spectrum(signal::Vector{Float64})

    n = length(signal)

    spectrum = fft(signal)

    power = abs2.(spectrum) ./ n

    freqs = frequency_vector(n, FS)

    return freqs, power

end

# ------------------------------------------------------------
# BAND ENERGY
# ------------------------------------------------------------

function band_energy(
    frequencies::Vector{Float64},
    power::Vector{Float64},
    low::Float64,
    high::Float64
)

    indices = findall(
        (frequencies .>= low) .&
        (frequencies .<= high)
    )

    if isempty(indices)
        return EPSILON
    end

    return mean(power[indices]) + EPSILON

end

# ------------------------------------------------------------
# LOW-FREQUENCY ENERGY
# ------------------------------------------------------------

function low_frequency_energy(signal)

    freqs, power = power_spectrum(signal)

    return band_energy(
        freqs,
        power,
        LOW_BAND[1],
        LOW_BAND[2]
    )

end

# ------------------------------------------------------------
# LOW / MID RATIO
# ------------------------------------------------------------

function low_mid_ratio(signal)

    freqs, power = power_spectrum(signal)

    low = band_energy(
        freqs,
        power,
        LOW_BAND[1],
        LOW_BAND[2]
    )

    mid = band_energy(
        freqs,
        power,
        MID_BAND[1],
        MID_BAND[2]
    )

    return 10.0 * log10(low / mid)

end

# ------------------------------------------------------------
# SPECTRAL SLOPE
# ------------------------------------------------------------

function spectral_slope(signal)

    freqs, power = power_spectrum(signal)

    indices = findall(
        (freqs .>= 100.0) .&
        (freqs .<= 8000.0)
    )

    f = log10.(freqs[indices] .+ 1.0)
    p = 10.0 .* log10.(power[indices] .+ EPSILON)

    # Linear regression
    x̄ = mean(f)
    ȳ = mean(p)

    numerator = sum((f .- x̄) .* (p .- ȳ))
    denominator = sum((f .- x̄).^2)

    return numerator / (denominator + EPSILON)

end

# ------------------------------------------------------------
# LEAKAGE INDEX
#
# Larger value = greater estimated leakage.
# ------------------------------------------------------------

function leakage_index(signal)

    ratio = low_mid_ratio(signal)

    # Empirical reference.
    #
    # Better seal:
    #   stronger low-frequency energy
    #
    # Worse seal:
    #   lower LF/MF ratio

    reference = -5.0

    leakage = (reference - ratio) / 15.0

    return clamp(leakage, 0.0, 1.0)

end

# ------------------------------------------------------------
# CHANNEL BALANCE
# ------------------------------------------------------------

function channel_balance(
    left::Vector{Float64},
    right::Vector{Float64}
)

    left_energy = mean(abs2, left) + EPSILON
    right_energy = mean(abs2, right) + EPSILON

    difference =
        abs(
            10.0 *
            log10(left_energy / right_energy)
        )

    # Convert dB difference to 0–1 score.
    #
    # 0 dB = perfect balance
    # 10+ dB = severe mismatch

    return clamp(
        1.0 - difference / 10.0,
        0.0,
        1.0
    )

end

# ------------------------------------------------------------
# NORMALISE FEATURE
# ------------------------------------------------------------

function normalise_feature(
    x::Float64,
    low::Float64,
    high::Float64
)

    return clamp(
        (x - low) / (high - low),
        0.0,
        1.0
    )

end

# ------------------------------------------------------------
# SEAL QUALITY ESTIMATOR
# ------------------------------------------------------------

function estimate_seal_quality(signal)

    lf = low_frequency_energy(signal)

    ratio = low_mid_ratio(signal)

    leakage = leakage_index(signal)

    # Convert low-frequency ratio into a quality estimate.

    lf_quality =
        normalise_feature(
            ratio,
            -20.0,
            -2.0
        )

    leakage_quality =
        1.0 - leakage

    # Spectral shape contributes a smaller amount.

    slope = spectral_slope(signal)

    slope_quality =
        normalise_feature(
            slope,
            -40.0,
            5.0
        )

    quality =
        0.55 * lf_quality +
        0.30 * leakage_quality +
        0.15 * slope_quality

    return clamp(quality, 0.0, 1.0)

end

# ------------------------------------------------------------
# FIT STATE CLASSIFICATION
# ------------------------------------------------------------

function classify_fit(
    quality::Float64
)

    if quality >= 0.75

        return GOOD

    elseif quality >= 0.45

        return PARTIAL

    elseif quality >= 0.15

        return POOR

    else

        return OUT_OF_EAR

    end

end

# ------------------------------------------------------------
# CONFIDENCE ESTIMATION
# ------------------------------------------------------------

function estimate_confidence(
    quality::Float64
)

    # Confidence is highest when the signal is clearly inside
    # one of the classification regions.

    boundaries = [
        0.15,
        0.45,
        0.75
    ]

    distance =
        minimum(abs.(quality .- boundaries))

    confidence =
        clamp(
            0.55 + 2.0 * distance,
            0.0,
            0.99
        )

    return confidence

end

# ------------------------------------------------------------
# FULL FIT ANALYSIS
# ------------------------------------------------------------

function analyse_fit(
    left::Vector{Float64},
    right::Vector{Float64}
)

    left_quality =
        estimate_seal_quality(left)

    right_quality =
        estimate_seal_quality(right)

    # Combine both ears.

    overall_quality =
        0.5 *
        (left_quality + right_quality)

    state =
        classify_fit(
            overall_quality
        )

    confidence =
        estimate_confidence(
            overall_quality
        )

    lf =
        0.5 *
        (
            low_frequency_energy(left) +
            low_frequency_energy(right)
        )

    ratio =
        0.5 *
        (
            low_mid_ratio(left) +
            low_mid_ratio(right)
        )

    slope =
        0.5 *
        (
            spectral_slope(left) +
            spectral_slope(right)
        )

    leakage =
        0.5 *
        (
            leakage_index(left) +
            leakage_index(right)
        )

    balance =
        channel_balance(
            left,
            right
        )

    return FitResult(
        state,
        overall_quality,
        confidence,
        lf,
        ratio,
        slope,
        leakage,
        balance
    )

end

# ------------------------------------------------------------
# SIMULATE DIFFERENT EAR FITS
# ------------------------------------------------------------

function simulate_fit(
    signal,
    quality::Float64;
    channel_variation::Float64 = 0.0
)

    left_quality =
        clamp(
            quality + channel_variation,
            0.0,
            1.0
        )

    right_quality =
        clamp(
            quality - channel_variation,
            0.0,
            1.0
        )

    left =
        apply_acoustic_response(
            signal,
            left_quality
        )

    right =
        apply_acoustic_response(
            signal,
            right_quality
        )

    left =
        add_microphone_noise(
            left,
            0.003
        )

    right =
        add_microphone_noise(
            right,
            0.003
        )

    return left, right

end

# ------------------------------------------------------------
# FIT QUALITY TO STRING
# ------------------------------------------------------------

function fit_name(state::FitState)

    if state == GOOD
        return "GOOD FIT"

    elseif state == PARTIAL
        return "PARTIAL FIT"

    elseif state == POOR
        return "POOR FIT"

    else
        return "OUT OF EAR"

    end

end

# ------------------------------------------------------------
# ANC CONTROL RECOMMENDATION
# ------------------------------------------------------------

function recommended_anc_level(
    seal_quality::Float64
)

    if seal_quality >= 0.75

        return 1.0

    elseif seal_quality >= 0.45

        return 0.75

    elseif seal_quality >= 0.15

        return 0.40

    else

        return 0.0

    end

end

# ------------------------------------------------------------
# FIT-AWARE ANC CONTROLLER
# ------------------------------------------------------------

mutable struct FitAwareANCController

    target_anc::Float64
    current_anc::Float64

    smoothing::Float64

end

function update_anc!(
    controller::FitAwareANCController,
    fit::FitResult
)

    target =
        recommended_anc_level(
            fit.seal_quality
        )

    controller.target_anc = target

    controller.current_anc =
        controller.smoothing *
        controller.current_anc +
        (1.0 - controller.smoothing) *
        target

    return controller.current_anc

end

# ------------------------------------------------------------
# REFIT DETECTION
# ------------------------------------------------------------

function needs_refit(
    fit::FitResult
)

    return (
        fit.state == POOR ||
        fit.state == OUT_OF_EAR ||
        fit.channel_balance < 0.60
    )

end

# ------------------------------------------------------------
# LEFT / RIGHT SEAL ANALYSIS
# ------------------------------------------------------------

function individual_seal_quality(signal)

    return estimate_seal_quality(signal)

end

# ------------------------------------------------------------
# FIT MONITOR
# ------------------------------------------------------------

mutable struct FitMonitor

    history::Vector{Float64}

    window_size::Int

end

function FitMonitor(
    window_size::Int = 20
)

    return FitMonitor(
        Float64[],
        window_size
    )

end

function update!(
    monitor::FitMonitor,
    quality::Float64
)

    push!(
        monitor.history,
        quality
    )

    if length(monitor.history) >
       monitor.window_size

        popfirst!(
            monitor.history
        )

    end

    return mean(
        monitor.history
    )

end

# ------------------------------------------------------------
# MOVEMENT DETECTION
# ------------------------------------------------------------

function detect_fit_change(
    previous_quality::Float64,
    current_quality::Float64
)

    change =
        current_quality -
        previous_quality

    return (
        change = change,
        significant = abs(change) > 0.12
    )

end

# ------------------------------------------------------------
# CONTINUOUS FIT TRACKER
# ------------------------------------------------------------

mutable struct FitTracker

    previous_quality::Float64

    monitor::FitMonitor

end

function FitTracker()

    return FitTracker(
        1.0,
        FitMonitor()
    )

end

function process_fit!(
    tracker::FitTracker,
    left::Vector{Float64},
    right::Vector{Float64}
)

    result =
        analyse_fit(
            left,
            right
        )

    smoothed =
        update!(
            tracker.monitor,
            result.seal_quality
        )

    change =
        detect_fit_change(
            tracker.previous_quality,
            smoothed
        )

    tracker.previous_quality =
        smoothed

    return result, smoothed, change

end

# ------------------------------------------------------------
# FIT TEST SWEEP
# ------------------------------------------------------------

function run_fit_sweep(signal)

    qualities =
        collect(
            0.0:0.05:1.0
        )

    estimates =
        Float64[]

    for q in qualities

        left, right =
            simulate_fit(
                signal,
                q
            )

        result =
            analyse_fit(
                left,
                right
            )

        push!(
            estimates,
            result.seal_quality
        )

    end

    return qualities, estimates

end

# ------------------------------------------------------------
# PLOT FIT CLASSIFIER
# ------------------------------------------------------------

function plot_fit_classifier(
    true_quality,
    estimated_quality
)

    plot(
        true_quality,
        estimated_quality,
        xlabel = "True Simulated Seal Quality",
        ylabel = "Estimated Seal Quality",
        title = "AirPod Fit/Seal Detection",
        label = "Estimator",
        linewidth = 2
    )

    plot!(
        true_quality,
        true_quality,
        linestyle = :dash,
        label = "Ideal"
    )

end

# ------------------------------------------------------------
# PLOT SPECTRUM
# ------------------------------------------------------------

function plot_fit_spectrum(
    signal
)

    freqs, power =
        power_spectrum(signal)

    indices =
        findall(
            (freqs .>= 20.0) .&
            (freqs .<= 20_000.0)
        )

    plot(
        freqs[indices],
        10 .* log10.(
            power[indices] .+ EPSILON
        ),
        xscale = :log10,
        xlabel = "Frequency (Hz)",
        ylabel = "Power (dB)",
        title = "Earbud Acoustic Response",
        label = "Measured Response",
        linewidth = 1.5
    )

end

# ------------------------------------------------------------
# REPORT
# ------------------------------------------------------------

function print_fit_report(
    result::FitResult
)

    println()
    println("==============================================")
    println("        AIRPOD FIT / SEAL ANALYSIS")
    println("==============================================")

    println(
        "Fit state:              ",
        fit_name(result.state)
    )

    println(
        "Seal quality:           ",
        round(
            result.seal_quality,
            digits = 3
        )
    )

    println(
        "Confidence:             ",
        round(
            100.0 *
            result.confidence,
            digits = 1
        ),
        "%"
    )

    println(
        "Low-frequency energy:   ",
        round(
            result.low_frequency_energy,
            digits = 6
        )
    )

    println(
        "Low/Mid ratio:          ",
        round(
            result.low_mid_ratio,
            digits = 2
        ),
        " dB"
    )

    println(
        "Spectral slope:         ",
        round(
            result.spectral_slope,
            digits = 3
        )
    )

    println(
        "Leakage index:          ",
        round(
            result.leakage_index,
            digits = 3
        )
    )

    println(
        "Channel balance:        ",
        round(
            result.channel_balance,
            digits = 3
        )
    )

    println(
        "Recommended ANC:        ",
        round(
            100.0 *
            recommended_anc_level(
                result.seal_quality
            ),
            digits = 1
        ),
        "%"
    )

    println(
        "Refit required:         ",
        needs_refit(result)
    )

    println("==============================================")
    println()

end

# ------------------------------------------------------------
# DEMONSTRATION
# ------------------------------------------------------------

function main()

    println()
    println("AirPod Fit & Seal Detection")
    println("---------------------------")

    Random.seed!(42)

    # Generate acoustic test signal.

    signal =
        generate_fit_test_signal()

    # --------------------------------------------------------
    # GOOD FIT
    # --------------------------------------------------------

    println("\nTEST 1 — GOOD FIT")

    left_good,
    right_good =
        simulate_fit(
            signal,
            0.95,
            channel_variation = 0.02
        )

    result_good =
        analyse_fit(
            left_good,
            right_good
        )

    print_fit_report(
        result_good
    )

    # --------------------------------------------------------
    # PARTIAL FIT
    # --------------------------------------------------------

    println("\nTEST 2 — PARTIAL FIT")

    left_partial,
    right_partial =
        simulate_fit(
            signal,
            0.60,
            channel_variation = 0.05
        )

    result_partial =
        analyse_fit(
            left_partial,
            right_partial
        )

    print_fit_report(
        result_partial
    )

    # --------------------------------------------------------
    # POOR FIT
    # --------------------------------------------------------

    println("\nTEST 3 — POOR FIT")

    left_poor,
    right_poor =
        simulate_fit(
            signal,
            0.25,
            channel_variation = 0.10
        )

    result_poor =
        analyse_fit(
            left_poor,
            right_poor
        )

    print_fit_report(
        result_poor
    )

    # --------------------------------------------------------
    # OUT OF EAR
    # --------------------------------------------------------

    println("\nTEST 4 — OUT OF EAR")

    left_out,
    right_out =
        simulate_fit(
            signal,
            0.03,
            channel_variation = 0.01
        )

    result_out =
        analyse_fit(
            left_out,
            right_out
        )

    print_fit_report(
        result_out
    )

    # --------------------------------------------------------
    # FIT-AWARE ANC
    # --------------------------------------------------------

    println("\nFIT-AWARE ANC CONTROLLER")

    controller =
        FitAwareANCController(
            1.0,
            1.0,
            0.85
        )

    for result in [
        result_good,
        result_partial,
        result_poor,
        result_out
    ]

        anc =
            update_anc!(
                controller,
                result
            )

        println(
            fit_name(result.state),
            " → ANC = ",
            round(
                100.0 * anc,
                digits = 1
            ),
            "%"
        )

    end

    # --------------------------------------------------------
    # FIT SWEEP
    # --------------------------------------------------------

    println("\nRUNNING FIT SWEEP...")

    true_quality,
    estimated_quality =
        run_fit_sweep(
            signal
        )

    plot_fit_classifier(
        true_quality,
        estimated_quality
    )

    # --------------------------------------------------------
    # SPECTRUM
    # --------------------------------------------------------

    plot_fit_spectrum(
        left_good
    )

    println("\nAnalysis complete.")

end

# ------------------------------------------------------------
# RUN
# ------------------------------------------------------------

if abspath(PROGRAM_FILE) ==
   @__FILE__

    main()

end







# ============================================================
# AirPod Predictive Audio Processing
# Julia prototype
#
# Predicts the next acoustic environment from recent
# microphone/audio measurements.
#
# Uses:
#   - rolling feature extraction
#   - exponentially weighted state estimation
#   - autoregressive prediction
#   - multi-feature prediction
#   - confidence estimation
#   - environment classification
#   - predictive DSP control
#
# Conceptual prototype — not Apple's actual implementation.
# ============================================================

using DSP
using FFTW
using LinearAlgebra
using Statistics
using Random
using Plots

# ------------------------------------------------------------
# GLOBAL PARAMETERS
# ------------------------------------------------------------

const FS = 48_000
const EPSILON = 1e-10

const FRAME_SIZE = 1024
const HOP_SIZE = 512

const HISTORY_LENGTH = 30
const AR_ORDER = 8

# ------------------------------------------------------------
# ENVIRONMENT TYPES
# ------------------------------------------------------------

@enum EnvironmentState begin
    QUIET
    SPEECH
    OFFICE
    STREET
    TRAIN
    AIRCRAFT
    WIND
    MUSIC
    TRANSIENT
end

# ------------------------------------------------------------
# AUDIO FRAME
# ------------------------------------------------------------

struct AudioFeatures

    rms::Float64
    low_energy::Float64
    mid_energy::Float64
    high_energy::Float64

    spectral_centroid::Float64
    spectral_flatness::Float64
    zero_crossing_rate::Float64

end

# ------------------------------------------------------------
# PREDICTION RESULT
# ------------------------------------------------------------

struct PredictionResult

    predicted_rms::Float64
    predicted_low_energy::Float64
    predicted_mid_energy::Float64
    predicted_high_energy::Float64

    predicted_centroid::Float64
    predicted_flatness::Float64

    environment::EnvironmentState

    confidence::Float64

end

# ------------------------------------------------------------
# RMS
# ------------------------------------------------------------

function rms_energy(signal::Vector{Float64})

    return sqrt(
        mean(signal .^ 2) +
        EPSILON
    )

end

# ------------------------------------------------------------
# POWER SPECTRUM
# ------------------------------------------------------------

function spectrum(signal::Vector{Float64})

    window =
        DSP.Windows.hann(length(signal))

    x =
        signal .* window

    X =
        fft(x)

    n =
        length(signal)

    freqs =
        collect(0:n-1) .* FS ./ n

    power =
        abs2.(X) ./ n

    return freqs, power

end

# ------------------------------------------------------------
# BAND ENERGY
# ------------------------------------------------------------

function band_energy(
    freqs,
    power,
    low,
    high
)

    indices =
        findall(
            (freqs .>= low) .&
            (freqs .<= high)
        )

    if isempty(indices)
        return EPSILON
    end

    return mean(power[indices]) + EPSILON

end

# ------------------------------------------------------------
# SPECTRAL CENTROID
# ------------------------------------------------------------

function spectral_centroid(
    freqs,
    power
)

    numerator =
        sum(freqs .* power)

    denominator =
        sum(power) + EPSILON

    return numerator / denominator

end

# ------------------------------------------------------------
# SPECTRAL FLATNESS
# ------------------------------------------------------------

function spectral_flatness(power)

    positive =
        power[power .> EPSILON]

    if isempty(positive)
        return 0.0
    end

    geometric =
        exp(mean(log.(positive)))

    arithmetic =
        mean(positive)

    return geometric /
           (arithmetic + EPSILON)

end

# ------------------------------------------------------------
# ZERO CROSSING RATE
# ------------------------------------------------------------

function zero_crossing_rate(signal)

    crossings =
        sum(
            signal[1:end-1] .*
            signal[2:end] .< 0
        )

    return crossings /
           length(signal)

end

# ------------------------------------------------------------
# FEATURE EXTRACTION
# ------------------------------------------------------------

function extract_features(
    signal::Vector{Float64}
)

    freqs, power =
        spectrum(signal)

    low =
        band_energy(
            freqs,
            power,
            40.0,
            300.0
        )

    mid =
        band_energy(
            freqs,
            power,
            300.0,
            3000.0
        )

    high =
        band_energy(
            freqs,
            power,
            3000.0,
            12_000.0
        )

    return AudioFeatures(

        rms_energy(signal),

        low,
        mid,
        high,

        spectral_centroid(
            freqs,
            power
        ),

        spectral_flatness(power),

        zero_crossing_rate(signal)

    )

end

# ------------------------------------------------------------
# FEATURE VECTOR
# ------------------------------------------------------------

function feature_vector(
    f::AudioFeatures
)

    return [

        f.rms,
        f.low_energy,
        f.mid_energy,
        f.high_energy,
        f.spectral_centroid,
        f.spectral_flatness,
        f.zero_crossing_rate

    ]

end

# ------------------------------------------------------------
# NORMALISE FEATURE
# ------------------------------------------------------------

function normalise_features(
    X::Matrix{Float64}
)

    μ =
        mean(X, dims = 1)

    σ =
        std(X, dims = 1) .+
        EPSILON

    Z =
        (X .- μ) ./ σ

    return Z, μ, σ

end

# ------------------------------------------------------------
# AUTOREGRESSIVE MODEL
# ------------------------------------------------------------

struct ARModel

    coefficients::Vector{Float64}

    intercept::Float64

end

# ------------------------------------------------------------
# FIT AR MODEL
# ------------------------------------------------------------

function fit_ar(
    series::Vector{Float64},
    order::Int
)

    n =
        length(series)

    if n <= order + 2

        return ARModel(
            zeros(order),
            mean(series)
        )

    end

    rows =
        n - order

    X =
        zeros(rows, order)

    y =
        zeros(rows)

    for i in 1:rows

        index =
            order + i

        X[i, :] =
            reverse(
                series[
                    index-order:index-1
                ]
            )

        y[i] =
            series[index]

    end

    # Add intercept.

    X_aug =
        hcat(
            ones(rows),
            X
        )

    β =
        X_aug \ y

    return ARModel(
        β[2:end],
        β[1]
    )

end

# ------------------------------------------------------------
# AR PREDICTION
# ------------------------------------------------------------

function predict_ar(
    model::ARModel,
    history::Vector{Float64}
)

    order =
        length(model.coefficients)

    if length(history) < order

        return mean(history)

    end

    x =
        reverse(
            history[
                end-order+1:end
            ]
        )

    prediction =
        model.intercept +
        dot(
            model.coefficients,
            x
        )

    return prediction

end

# ------------------------------------------------------------
# MULTI-VARIABLE PREDICTOR
# ------------------------------------------------------------

mutable struct PredictiveAudioModel

    history::Vector{Vector{Float64}}

    models::Vector{ARModel}

    max_history::Int

    order::Int

end

function PredictiveAudioModel(
    ;
    max_history = HISTORY_LENGTH,
    order = AR_ORDER
)

    return PredictiveAudioModel(

        Vector{Vector{Float64}}(),

        ARModel[],

        max_history,

        order

    )

end

# ------------------------------------------------------------
# ADD FEATURE FRAME
# ------------------------------------------------------------

function update!(
    model::PredictiveAudioModel,
    features::AudioFeatures
)

    push!(
        model.history,
        feature_vector(features)
    )

    if length(model.history) >
       model.max_history

        popfirst!(
            model.history
        )

    end

end

# ------------------------------------------------------------
# TRAIN PREDICTIVE MODEL
# ------------------------------------------------------------

function train!(
    model::PredictiveAudioModel
)

    if length(model.history) <
       model.order + 3

        return false

    end

    matrix =
        reduce(
            hcat,
            model.history
        )'

    dimensions =
        size(matrix, 2)

    models =
        ARModel[]

    for d in 1:dimensions

        series =
            matrix[:, d]

        push!(
            models,
            fit_ar(
                series,
                model.order
            )
        )

    end

    model.models =
        models

    return true

end

# ------------------------------------------------------------
# PREDICT NEXT FEATURE VECTOR
# ------------------------------------------------------------

function predict(
    model::PredictiveAudioModel
)

    if isempty(model.models)

        return nothing

    end

    matrix =
        reduce(
            hcat,
            model.history
        )'

    prediction =
        zeros(
            size(matrix, 2)
        )

    for d in 1:size(matrix, 2)

        prediction[d] =
            predict_ar(
                model.models[d],
                matrix[:, d]
            )

    end

    return prediction

end

# ------------------------------------------------------------
# ENVIRONMENT CLASSIFICATION
# ------------------------------------------------------------

function classify_environment(
    features::Vector{Float64}
)

    rms =
        features[1]

    low =
        features[2]

    mid =
        features[3]

    high =
        features[4]

    centroid =
        features[5]

    flatness =
        features[6]

    # --------------------------------------------------------
    # QUIET
    # --------------------------------------------------------

    if rms < 0.01

        return QUIET
    end

    # --------------------------------------------------------
    # AIRCRAFT / ENGINE
    # --------------------------------------------------------

    if low > mid * 2.5 &&
       centroid < 1500.0

        return AIRCRAFT
    end

    # --------------------------------------------------------
    # WIND
    # --------------------------------------------------------

    if low > high * 1.5 &&
       flatness > 0.25

        return WIND
    end

    # --------------------------------------------------------
    # SPEECH
    # --------------------------------------------------------

    if centroid > 1000.0 &&
       centroid < 4000.0 &&
       flatness < 0.40

        return SPEECH
    end

    # --------------------------------------------------------
    # MUSIC
    # --------------------------------------------------------

    if mid > low * 0.4 &&
       high > low * 0.2

        return MUSIC
    end

    # --------------------------------------------------------
    # TRAIN
    # --------------------------------------------------------

    if low > mid &&
       centroid < 2000.0

        return TRAIN
    end

    # --------------------------------------------------------
    # STREET / GENERAL NOISE
    # --------------------------------------------------------

    if rms > 0.03

        return STREET
    end

    return OFFICE

end

# ------------------------------------------------------------
# ENVIRONMENT NAME
# ------------------------------------------------------------

function environment_name(
    state::EnvironmentState
)

    names = Dict(

        QUIET => "QUIET",
        SPEECH => "SPEECH",
        OFFICE => "OFFICE",
        STREET => "STREET",
        TRAIN => "TRAIN",
        AIRCRAFT => "AIRCRAFT",
        WIND => "WIND",
        MUSIC => "MUSIC",
        TRANSIENT => "TRANSIENT"

    )

    return names[state]

end

# ------------------------------------------------------------
# PREDICTION CONFIDENCE
# ------------------------------------------------------------

function prediction_confidence(
    history::Vector{Vector{Float64}},
    predicted::Vector{Float64}
)

    if length(history) < 5
        return 0.0
    end

    matrix =
        reduce(
            hcat,
            history
        )'

    current =
        matrix[end, :]

    difference =
        norm(
            predicted -
            current
        )

    scale =
        norm(current) +
        EPSILON

    relative_error =
        difference / scale

    confidence =
        exp(
            -relative_error
        )

    return clamp(
        confidence,
        0.0,
        1.0
    )

end

# ------------------------------------------------------------
# COMPLETE PREDICTION
# ------------------------------------------------------------

function predict_audio(
    model::PredictiveAudioModel
)

    predicted =
        predict(model)

    if predicted === nothing

        return nothing

    end

    confidence =
        prediction_confidence(
            model.history,
            predicted
        )

    state =
        classify_environment(
            predicted
        )

    return PredictionResult(

        predicted[1],
        predicted[2],
        predicted[3],
        predicted[4],

        predicted[5],
        predicted[6],

        state,

        confidence

    )

end

# ------------------------------------------------------------
# PREDICTIVE ANC
# ------------------------------------------------------------

function predictive_anc_level(
    prediction::PredictionResult
)

    rms =
        prediction.predicted_rms

    environment =
        prediction.environment

    if environment == AIRCRAFT

        base = 1.00

    elseif environment == TRAIN

        base = 0.90

    elseif environment == WIND

        base = 0.80

    elseif environment == STREET

        base = 0.75

    elseif environment == SPEECH

        base = 0.35

    elseif environment == OFFICE

        base = 0.45

    elseif environment == MUSIC

        base = 0.10

    else

        base = 0.20

    end

    # Scale by predicted noise intensity.

    intensity =
        clamp(
            rms * 15.0,
            0.0,
            1.0
        )

    anc =
        base * intensity

    # Never make a prediction with poor confidence
    # fully control the ANC system.

    confidence =
        prediction.confidence

    return clamp(
        anc * confidence +
        0.25 * (1.0 - confidence),
        0.0,
        1.0
    )

end

# ------------------------------------------------------------
# PREDICTIVE EQ STRATEGY
# ------------------------------------------------------------

function predictive_eq_bias(
    prediction::PredictionResult
)

    state =
        prediction.environment

    if state == AIRCRAFT ||
       state == TRAIN

        return -2.0

    elseif state == WIND

        return -1.0

    elseif state == SPEECH

        return 1.5

    elseif state == MUSIC

        return 0.0

    else

        return 0.0

    end

end

# ------------------------------------------------------------
# PREDICTIVE WIND CONTROL
# ------------------------------------------------------------

function predicted_wind_filter(
    prediction::PredictionResult
)

    if prediction.environment == WIND

        return 1.0

    end

    if prediction.predicted_low_energy >
       prediction.predicted_high_energy * 1.5

        return 0.70

    end

    return 0.20

end

# ------------------------------------------------------------
# SYNTHETIC ENVIRONMENTS
# ------------------------------------------------------------

function generate_noise(
    state::EnvironmentState,
    duration::Float64
)

    n =
        Int(round(
            duration * FS
        ))

    t =
        collect(0:n-1) ./ FS

    if state == QUIET

        return 0.002 .* randn(n)

    elseif state == AIRCRAFT

        engine =
            0.12 .* sin.(
                2π .* 120.0 .* t
            )

        harmonic =
            0.06 .* sin.(
                2π .* 240.0 .* t
            )

        noise =
            0.025 .* randn(n)

        return engine +
               harmonic +
               noise

    elseif state == TRAIN

        rumble =
            0.10 .* sin.(
                2π .* 80.0 .* t
            )

        noise =
            0.06 .* randn(n)

        return rumble +
               noise

    elseif state == WIND

        envelope =
            0.05 .+
            0.04 .* sin.(
                2π .* 0.7 .* t
            )

        return envelope .* randn(n)

    elseif state == SPEECH

        signal =
            0.08 .* randn(n)

        modulation =
            0.5 .+
            0.5 .* sin.(
                2π .* 4.0 .* t
            )

        return signal .* modulation

    elseif state == STREET

        low =
            0.04 .* randn(n)

        high =
            0.02 .* randn(n)

        return low + high

    elseif state == MUSIC

        return (
            0.08 .* sin.(2π .* 440.0 .* t) +
            0.04 .* sin.(2π .* 880.0 .* t) +
            0.02 .* randn(n)
        )

    else

        return 0.02 .* randn(n)

    end

end

# ------------------------------------------------------------
# CREATE TIME-VARYING ENVIRONMENT
# ------------------------------------------------------------

function generate_environment_sequence()

    states = [

        QUIET,
        OFFICE,
        STREET,
        TRAIN,
        TRAIN,
        AIRCRAFT,
        AIRCRAFT,
        AIRCRAFT,
        WIND,
        STREET,
        SPEECH,
        MUSIC

    ]

    return states

end

# ------------------------------------------------------------
# PROCESS ENVIRONMENT
# ------------------------------------------------------------

function process_environment(
    model::PredictiveAudioModel,
    signal::Vector{Float64}
)

    features =
        extract_features(
            signal
        )

    update!(
        model,
        features
    )

    trained =
        train!(model)

    if !trained

        return nothing

    end

    return predict_audio(
        model
    )

end

# ------------------------------------------------------------
# PREDICTION HISTORY
# ------------------------------------------------------------

function prediction_error(
    actual::Vector{Float64},
    predicted::Vector{Float64}
)

    denominator =
        norm(actual) +
        EPSILON

    return norm(
        actual - predicted
    ) / denominator

end

# ------------------------------------------------------------
# ADAPTIVE PREDICTION HORIZON
# ------------------------------------------------------------

function prediction_horizon(
    confidence::Float64
)

    # More confidence allows more aggressive prediction.

    if confidence > 0.85

        return 8

    elseif confidence > 0.65

        return 5

    elseif confidence > 0.40

        return 3

    else

        return 1

    end

end

# ------------------------------------------------------------
# PREDICTIVE PROCESSOR
# ------------------------------------------------------------

mutable struct PredictiveProcessor

    model::PredictiveAudioModel

    previous_prediction::Union{
        Nothing,
        PredictionResult
    }

    prediction_errors::Vector{Float64}

end

function PredictiveProcessor()

    return PredictiveProcessor(

        PredictiveAudioModel(),

        nothing,

        Float64[]

    )

end

# ------------------------------------------------------------
# PROCESS FRAME
# ------------------------------------------------------------

function process_frame!(
    processor::PredictiveProcessor,
    signal::Vector{Float64}
)

    features =
        extract_features(
            signal
        )

    # Compare current observation with
    # previous prediction.

    if processor.previous_prediction !== nothing

        previous =
            processor.previous_prediction

        current_vector =
            feature_vector(
                features
            )

        predicted_vector = [

            previous.predicted_rms,
            previous.predicted_low_energy,
            previous.predicted_mid_energy,
            previous.predicted_high_energy,
            previous.predicted_centroid,
            previous.predicted_flatness,
            features.zero_crossing_rate

        ]

        error =
            prediction_error(
                current_vector[1:6],
                predicted_vector[1:6]
            )

        push!(
            processor.prediction_errors,
            error
        )

    end

    update!(
        processor.model,
        features
    )

    train!(
        processor.model
    )

    result =
        predict_audio(
            processor.model
        )

    processor.previous_prediction =
        result

    return result

end

# ------------------------------------------------------------
# PLOT PREDICTION
# ------------------------------------------------------------

function plot_prediction(
    actual::Vector{Float64},
    predicted::Vector{Float64}
)

    plot(
        actual,
        label = "Actual",
        xlabel = "Frame",
        ylabel = "RMS Energy",
        title = "Predictive Audio Processing",
        linewidth = 2
    )

    plot!(
        predicted,
        label = "Predicted",
        linestyle = :dash,
        linewidth = 2
    )

end

# ------------------------------------------------------------
# REPORT
# ------------------------------------------------------------

function print_prediction_report(
    prediction::PredictionResult
)

    println()
    println("==============================================")
    println("       PREDICTIVE AUDIO PROCESSING")
    println("==============================================")

    println(
        "Predicted environment: ",
        environment_name(
            prediction.environment
        )
    )

    println(
        "Prediction confidence:  ",
        round(
            prediction.confidence * 100.0,
            digits = 1
        ),
        "%"
    )

    println(
        "Predicted RMS:          ",
        round(
            prediction.predicted_rms,
            digits = 5
        )
    )

    println(
        "Predicted LF energy:    ",
        round(
            prediction.predicted_low_energy,
            digits = 5
        )
    )

    println(
        "Predicted MF energy:    ",
        round(
            prediction.predicted_mid_energy,
            digits = 5
        )
    )

    println(
        "Predicted HF energy:    ",
        round(
            prediction.predicted_high_energy,
            digits = 5
        )
    )

    println(
        "Predicted centroid:     ",
        round(
            prediction.predicted_centroid,
            digits = 1
        ),
        " Hz"
    )

    println(
        "Predicted flatness:     ",
        round(
            prediction.predicted_flatness,
            digits = 4
        )
    )

    println(
        "Prediction horizon:     ",
        prediction_horizon(
            prediction.confidence
        ),
        " frames"
    )

    println(
        "Recommended ANC:        ",
        round(
            predictive_anc_level(
                prediction
            ) * 100.0,
            digits = 1
        ),
        "%"
    )

    println(
        "EQ bias:                ",
        round(
            predictive_eq_bias(
                prediction
            ),
            digits = 2
        ),
        " dB"
    )

    println(
        "Wind filtering:         ",
        round(
            predicted_wind_filter(
                prediction
            ) * 100.0,
            digits = 1
        ),
        "%"
    )

    println("==============================================")
    println()

end

# ------------------------------------------------------------
# DEMONSTRATION
# ------------------------------------------------------------

function main()

    println()
    println("AirPod Predictive Audio Processing")
    println("----------------------------------")

    Random.seed!(42)

    processor =
        PredictiveProcessor()

    states =
        generate_environment_sequence()

    actual_rms =
        Float64[]

    predicted_rms =
        Float64[]

    predicted_states =
        EnvironmentState[]

    confidences =
        Float64[]

    for state in states

        println(
            "\nEnvironment input: ",
            environment_name(state)
        )

        signal =
            generate_noise(
                state,
                FRAME_SIZE / FS
            )

        prediction =
            process_frame!(
                processor,
                signal
            )

        features =
            extract_features(
                signal
            )

        push!(
            actual_rms,
            features.rms
        )

        if prediction !== nothing

            push!(
                predicted_rms,
                prediction.predicted_rms
            )

            push!(
                predicted_states,
                prediction.environment
            )

            push!(
                confidences,
                prediction.confidence
            )

            print_prediction_report(
                prediction
            )

        else

            push!(
                predicted_rms,
                NaN
            )

            push!(
                confidences,
                0.0
            )

        end

    end

    # --------------------------------------------------------
    # PLOT
    # --------------------------------------------------------

    plot(
        1:length(actual_rms),
        actual_rms,
        label = "Actual RMS",
        xlabel = "Audio Frame",
        ylabel = "RMS",
        title = "Actual vs Predicted Acoustic Environment",
        linewidth = 2
    )

    plot!(
        1:length(predicted_rms),
        predicted_rms,
        label = "Predicted RMS",
        linestyle = :dash,
        linewidth = 2
    )

    # --------------------------------------------------------
    # FINAL PERFORMANCE
    # --------------------------------------------------------

    valid =
        findall(
            x -> !isnan(x),
            predicted_rms
        )

    if !isempty(valid)

        errors =
            Float64[]

        for i in valid

            push!(
                errors,
                abs(
                    actual_rms[i] -
                    predicted_rms[i]
                )
            )

        end

        println()
        println(
            "Mean prediction error: ",
            round(
                mean(errors),
                digits = 6
            )
        )

        println(
            "Mean confidence:       ",
            round(
                mean(confidences) * 100.0,
                digits = 1
            ),
            "%"
        )

    end

    println()
    println("Predictive processing complete.")

end

# ------------------------------------------------------------
# RUN
# ------------------------------------------------------------

if abspath(PROGRAM_FILE) ==
   @__FILE__

    main()

end







# ============================================================
# AirPod Computational Audio Personalisation
# Julia prototype
#
# Builds a personalised acoustic model for a listener.
#
# Features:
#   - left/right hearing-response model
#   - frequency sensitivity estimation
#   - personalised target generation
#   - personalised EQ optimisation
#   - channel compensation
#   - loudness preference modelling
#   - ANC preference modelling
#   - spatial-audio preference modelling
#   - profile learning over time
#   - confidence estimation
#
# Conceptual computational-audio prototype.
# ============================================================

using DSP
using FFTW
using LinearAlgebra
using Statistics
using Random
using Plots

# ------------------------------------------------------------
# GLOBAL PARAMETERS
# ------------------------------------------------------------

const FS = 48_000
const EPSILON = 1e-10

const MIN_FREQ = 20.0
const MAX_FREQ = 20_000.0

const NUM_FREQS = 256

const MAX_EQ_GAIN = 8.0

# ------------------------------------------------------------
# FREQUENCY GRID
# ------------------------------------------------------------

function frequency_grid()

    return exp10.(
        range(
            log10(MIN_FREQ),
            log10(MAX_FREQ),
            length = NUM_FREQS
        )
    )

end

const FREQUENCIES = frequency_grid()

# ------------------------------------------------------------
# EAR RESPONSE
# ------------------------------------------------------------

struct EarResponse

    frequencies::Vector{Float64}

    response_db::Vector{Float64}

end

# ------------------------------------------------------------
# PERSONAL HEARING MODEL
# ------------------------------------------------------------

struct PersonalHearingModel

    left::EarResponse

    right::EarResponse

    confidence::Float64

end

# ------------------------------------------------------------
# USER PREFERENCES
# ------------------------------------------------------------

struct AudioPreferences

    preferred_bass_db::Float64

    preferred_treble_db::Float64

    preferred_loudness_db::Float64

    preferred_anc::Float64

    preferred_spatial_width::Float64

end

# ------------------------------------------------------------
# PERSONAL AUDIO PROFILE
# ------------------------------------------------------------

mutable struct PersonalAudioProfile

    hearing::PersonalHearingModel

    preferences::AudioPreferences

    adaptation_rate::Float64

    number_of_sessions::Int

end

# ------------------------------------------------------------
# INTERPOLATION
# ------------------------------------------------------------

function interpolate_response(
    response::EarResponse,
    frequencies::Vector{Float64}
)

    result =
        similar(frequencies)

    for i in eachindex(frequencies)

        f =
            frequencies[i]

        if f <= response.frequencies[1]

            result[i] =
                response.response_db[1]

        elseif f >= response.frequencies[end]

            result[i] =
                response.response_db[end]

        else

            index =
                searchsortedlast(
                    response.frequencies,
                    f
                )

            f1 =
                response.frequencies[index]

            f2 =
                response.frequencies[index + 1]

            y1 =
                response.response_db[index]

            y2 =
                response.response_db[index + 1]

            α =
                (log(f) - log(f1)) /
                (log(f2) - log(f1))

            result[i] =
                y1 +
                α * (y2 - y1)

        end

    end

    return result

end

# ------------------------------------------------------------
# SYNTHETIC HEARING RESPONSE
#
# Represents an individual's acoustic sensitivity.
# ------------------------------------------------------------

function synthetic_hearing_response(
    frequencies;
    bass_sensitivity = 0.0,
    mid_sensitivity = 0.0,
    treble_sensitivity = 0.0
)

    response =
        zeros(length(frequencies))

    for i in eachindex(frequencies)

        f =
            frequencies[i]

        bass =
            exp(
                -((log10(f) -
                    log10(100.0)) / 0.45)^2
            )

        mid =
            exp(
                -((log10(f) -
                    log10(1000.0)) / 0.55)^2
            )

        treble =
            exp(
                -((log10(f) -
                    log10(7000.0)) / 0.45)^2
            )

        response[i] =
            bass_sensitivity * bass +
            mid_sensitivity * mid +
            treble_sensitivity * treble

    end

    return EarResponse(
        frequencies,
        response
    )

end

# ------------------------------------------------------------
# TARGET CURVE
# ------------------------------------------------------------

function neutral_target()

    return zeros(
        length(FREQUENCIES)
    )

end

# ------------------------------------------------------------
# PERSONAL TARGET
# ------------------------------------------------------------

function personal_target(
    preferences::AudioPreferences
)

    target =
        neutral_target()

    for i in eachindex(FREQUENCIES)

        f =
            FREQUENCIES[i]

        bass =
            exp(
                -((log10(f) -
                    log10(100.0)) / 0.50)^2
            )

        treble =
            exp(
                -((log10(f) -
                    log10(7000.0)) / 0.50)^2
            )

        target[i] =
            preferences.preferred_bass_db *
            bass +
            preferences.preferred_treble_db *
            treble

    end

    return target

end

# ------------------------------------------------------------
# EQ BAND
# ------------------------------------------------------------

struct EQBand

    frequency::Float64

    gain_db::Float64

    Q::Float64

end

# ------------------------------------------------------------
# EQ CONFIGURATION
# ------------------------------------------------------------

struct EQConfiguration

    bands::Vector{EQBand}

end

# ------------------------------------------------------------
# PEAKING EQ RESPONSE
# ------------------------------------------------------------

function peaking_response(
    frequencies::Vector{Float64},
    band::EQBand
)

    A =
        10.0^(band.gain_db / 40.0)

    ω0 =
        2π *
        band.frequency /
        FS

    α =
        sin(ω0) /
        (2.0 * band.Q)

    b0 =
        1.0 + α * A

    b1 =
        -2.0 * cos(ω0)

    b2 =
        1.0 - α * A

    a0 =
        1.0 + α / A

    a1 =
        -2.0 * cos(ω0)

    a2 =
        1.0 - α / A

    response =
        zeros(length(frequencies))

    for i in eachindex(frequencies)

        ω =
            2π *
            frequencies[i] /
            FS

        z1 =
            exp(-im * ω)

        z2 =
            exp(-im * 2ω)

        numerator =
            b0 +
            b1 * z1 +
            b2 * z2

        denominator =
            a0 +
            a1 * z1 +
            a2 * z2

        H =
            numerator /
            denominator

        response[i] =
            20.0 *
            log10(
                abs(H) +
                EPSILON
            )

    end

    return response

end

# ------------------------------------------------------------
# TOTAL EQ RESPONSE
# ------------------------------------------------------------

function eq_response(
    configuration::EQConfiguration
)

    response =
        zeros(
            length(FREQUENCIES)
        )

    for band in configuration.bands

        response .+=
            peaking_response(
                FREQUENCIES,
                band
            )

    end

    return response

end

# ------------------------------------------------------------
# TOTAL SYSTEM RESPONSE
# ------------------------------------------------------------

function personalised_system_response(
    ear::EarResponse,
    configuration::EQConfiguration
)

    hearing =
        interpolate_response(
            ear,
            FREQUENCIES
        )

    eq =
        eq_response(
            configuration
        )

    return hearing .+ eq

end

# ------------------------------------------------------------
# ERROR FUNCTION
# ------------------------------------------------------------

function personalisation_error(
    response::Vector{Float64},
    target::Vector{Float64}
)

    weights =
        ones(length(response))

    # Greater perceptual importance around mid frequencies.

    for i in eachindex(FREQUENCIES)

        f =
            FREQUENCIES[i]

        if 200.0 <= f <= 5000.0

            weights[i] = 1.3

        elseif f < 80.0

            weights[i] = 0.7

        elseif f > 12000.0

            weights[i] = 0.6

        end

    end

    error =
        sum(
            weights .* (response .- target).^2
        )

    return error /
           sum(weights)

end

# ------------------------------------------------------------
# EQ REGULARISATION
# ------------------------------------------------------------

function eq_regularisation(
    configuration::EQConfiguration
)

    penalty = 0.0

    for band in configuration.bands

        penalty +=
            0.02 *
            band.gain_db^2

        penalty +=
            0.002 *
            (1.0 / band.Q)

    end

    return penalty

end

# ------------------------------------------------------------
# OBJECTIVE
# ------------------------------------------------------------

function objective(
    ear::EarResponse,
    configuration::EQConfiguration,
    target::Vector{Float64}
)

    response =
        personalised_system_response(
            ear,
            configuration
        )

    return personalisation_error(
        response,
        target
    ) +
    eq_regularisation(
        configuration
    )

end

# ------------------------------------------------------------
# DEFAULT EQ
# ------------------------------------------------------------

function neutral_eq()

    frequencies = [

        60.0,
        120.0,
        250.0,
        500.0,
        1000.0,
        2000.0,
        4000.0,
        8000.0,
        12000.0

    ]

    bands =
        EQBand[]

    for f in frequencies

        push!(
            bands,
            EQBand(
                f,
                0.0,
                1.0
            )
        )

    end

    return EQConfiguration(
        bands
    )

end

# ------------------------------------------------------------
# COPY CONFIGURATION
# ------------------------------------------------------------

function copy_configuration(
    configuration::EQConfiguration
)

    bands =
        EQBand[]

    for band in configuration.bands

        push!(
            bands,
            EQBand(
                band.frequency,
                band.gain_db,
                band.Q
            )
        )

    end

    return EQConfiguration(
        bands
    )

end

# ------------------------------------------------------------
# RANDOM EQ OPTIMISATION
# ------------------------------------------------------------

function optimise_eq(
    ear::EarResponse,
    target::Vector{Float64};
    iterations = 1000
)

    current =
        neutral_eq()

    current_error =
        objective(
            ear,
            current,
            target
        )

    best =
        current

    best_error =
        current_error

    for iteration in 1:iterations

        candidate =
            copy_configuration(
                current
            )

        index =
            rand(
                1:length(candidate.bands)
            )

        band =
            candidate.bands[index]

        new_gain =
            clamp(
                band.gain_db +
                randn() * 0.7,
                -MAX_EQ_GAIN,
                MAX_EQ_GAIN
            )

        candidate.bands[index] =
            EQBand(
                band.frequency,
                new_gain,
                band.Q
            )

        error =
            objective(
                ear,
                candidate,
                target
            )

        if error < current_error

            current =
                candidate

            current_error =
                error

        end

        if error < best_error

            best =
                candidate

            best_error =
                error

        end

    end

    return best, best_error

end

# ------------------------------------------------------------
# LEFT / RIGHT EQ OPTIMISATION
# ------------------------------------------------------------

function optimise_stereo_eq(
    hearing::PersonalHearingModel,
    preferences::AudioPreferences
)

    target =
        personal_target(
            preferences
        )

    left_eq,
    left_error =
        optimise_eq(
            hearing.left,
            target
        )

    right_eq,
    right_error =
        optimise_eq(
            hearing.right,
            target
        )

    return (
        left_eq,
        right_eq,
        left_error,
        right_error
    )

end

# ------------------------------------------------------------
# LOUDNESS MODEL
# ------------------------------------------------------------

function loudness_gain(
    preferences::AudioPreferences
)

    return preferences.preferred_loudness_db

end

# ------------------------------------------------------------
# ANC PERSONALISATION
# ------------------------------------------------------------

function personalised_anc(
    preferences::AudioPreferences
)

    return clamp(
        preferences.preferred_anc,
        0.0,
        1.0
    )

end

# ------------------------------------------------------------
# SPATIAL PERSONALISATION
# ------------------------------------------------------------

function personalised_spatial_width(
    preferences::AudioPreferences
)

    return clamp(
        preferences.preferred_spatial_width,
        0.0,
        1.0
    )

end

# ------------------------------------------------------------
# PROFILE UPDATE
# ------------------------------------------------------------

function update_preference(
    old::Float64,
    observation::Float64,
    learning_rate::Float64
)

    return (
        (1.0 - learning_rate) * old +
        learning_rate * observation
    )

end

# ------------------------------------------------------------
# ADAPT USER PREFERENCES
# ------------------------------------------------------------

function learn_preferences!(
    profile::PersonalAudioProfile;

    observed_bass = nothing,
    observed_treble = nothing,
    observed_loudness = nothing,
    observed_anc = nothing,
    observed_spatial_width = nothing

)

    p =
        profile.preferences

    rate =
        profile.adaptation_rate

    bass =
        p.preferred_bass_db

    treble =
        p.preferred_treble_db

    loudness =
        p.preferred_loudness_db

    anc =
        p.preferred_anc

    spatial =
        p.preferred_spatial_width

    if observed_bass !== nothing

        bass =
            update_preference(
                bass,
                observed_bass,
                rate
            )

    end

    if observed_treble !== nothing

        treble =
            update_preference(
                treble,
                observed_treble,
                rate
            )

    end

    if observed_loudness !== nothing

        loudness =
            update_preference(
                loudness,
                observed_loudness,
                rate
            )

    end

    if observed_anc !== nothing

        anc =
            update_preference(
                anc,
                observed_anc,
                rate
            )

    end

    if observed_spatial_width !== nothing

        spatial =
            update_preference(
                spatial,
                observed_spatial_width,
                rate
            )

    end

    profile.preferences =
        AudioPreferences(
            bass,
            treble,
            loudness,
            anc,
            spatial
        )

    profile.number_of_sessions += 1

end

# ------------------------------------------------------------
# PERSONAL HEARING SIMULATION
# ------------------------------------------------------------

function generate_personal_hearing()

    left =
        synthetic_hearing_response(
            FREQUENCIES,
            bass_sensitivity = -1.5,
            mid_sensitivity = 0.2,
            treble_sensitivity = -2.5
        )

    right =
        synthetic_hearing_response(
            FREQUENCIES,
            bass_sensitivity = -0.5,
            mid_sensitivity = 0.0,
            treble_sensitivity = -1.5
        )

    return PersonalHearingModel(
        left,
        right,
        0.90
    )

end

# ------------------------------------------------------------
# INITIAL PROFILE
# ------------------------------------------------------------

function create_profile()

    hearing =
        generate_personal_hearing()

    preferences =
        AudioPreferences(

            2.0,    # bass preference
            1.0,    # treble preference
            0.0,    # loudness
            0.70,   # ANC
            0.70    # spatial width

        )

    return PersonalAudioProfile(

        hearing,
        preferences,

        0.08,

        0

    )

end

# ------------------------------------------------------------
# EQ REPORT
# ------------------------------------------------------------

function print_eq(
    configuration::EQConfiguration
)

    println()

    println(
        "Frequency (Hz) | Gain (dB) | Q"
    )

    println(
        "--------------------------------"
    )

    for band in configuration.bands

        println(
            lpad(
                string(
                    round(
                        band.frequency,
                        digits = 0
                    )
                ),
                14
            ),
            " | ",
            lpad(
                string(
                    round(
                        band.gain_db,
                        digits = 2
                    )
                ),
                9
            ),
            " | ",
            round(
                band.Q,
                digits = 2
            )
        )

    end

end

# ------------------------------------------------------------
# PROFILE REPORT
# ------------------------------------------------------------

function print_profile(
    profile::PersonalAudioProfile
)

    p =
        profile.preferences

    println()
    println("==============================================")
    println("        PERSONAL AUDIO PROFILE")
    println("==============================================")

    println(
        "Hearing confidence: ",
        round(
            profile.hearing.confidence * 100.0,
            digits = 1
        ),
        "%"
    )

    println(
        "Bass preference:    ",
        round(
            p.preferred_bass_db,
            digits = 2
        ),
        " dB"
    )

    println(
        "Treble preference:  ",
        round(
            p.preferred_treble_db,
            digits = 2
        ),
        " dB"
    )

    println(
        "Loudness preference:",
        round(
            p.preferred_loudness_db,
            digits = 2
        ),
        " dB"
    )

    println(
        "ANC preference:     ",
        round(
            p.preferred_anc * 100.0,
            digits = 1
        ),
        "%"
    )

    println(
        "Spatial width:      ",
        round(
            p.preferred_spatial_width * 100.0,
            digits = 1
        ),
        "%"
    )

    println(
        "Sessions learned:   ",
        profile.number_of_sessions
    )

    println("==============================================")

end

# ------------------------------------------------------------
# PLOT PERSONAL HEARING
# ------------------------------------------------------------

function plot_hearing_model(
    profile::PersonalAudioProfile
)

    left =
        profile.hearing.left.response_db

    right =
        profile.hearing.right.response_db

    plot(
        FREQUENCIES,
        left,
        xscale = :log10,
        xlabel = "Frequency (Hz)",
        ylabel = "Relative sensitivity (dB)",
        title = "Personal Hearing Model",
        label = "Left ear",
        linewidth = 2
    )

    plot!(
        FREQUENCIES,
        right,
        label = "Right ear",
        linewidth = 2
    )

    hline!(
        [0.0],
        linestyle = :dash,
        label = "Reference"
    )

end

# ------------------------------------------------------------
# PLOT PERSONAL TARGET
# ------------------------------------------------------------

function plot_target(
    preferences::AudioPreferences
)

    target =
        personal_target(
            preferences
        )

    plot(
        FREQUENCIES,
        target,
        xscale = :log10,
        xlabel = "Frequency (Hz)",
        ylabel = "Target gain (dB)",
        title = "Personalised Audio Target",
        label = "Target",
        linewidth = 2
    )

    hline!(
        [0.0],
        linestyle = :dash,
        label = "Neutral"
    )

end

# ------------------------------------------------------------
# PLOT COMPENSATION
# ------------------------------------------------------------

function plot_compensation(
    ear::EarResponse,
    configuration::EQConfiguration,
    target::Vector{Float64}
)

    original =
        interpolate_response(
            ear,
            FREQUENCIES
        )

    compensation =
        eq_response(
            configuration
        )

    final =
        original .+
        compensation

    plot(
        FREQUENCIES,
        original,
        xscale = :log10,
        xlabel = "Frequency (Hz)",
        ylabel = "Response (dB)",
        title = "Personalised Audio Compensation",
        label = "Original",
        linewidth = 2
    )

    plot!(
        FREQUENCIES,
        target,
        label = "Target",
        linewidth = 2
    )

    plot!(
        FREQUENCIES,
        final,
        label = "Personalised",
        linewidth = 2
    )

end

# ------------------------------------------------------------
# MAIN DEMONSTRATION
# ------------------------------------------------------------

function main()

    Random.seed!(42)

    println()
    println("AirPod Computational Audio Personalisation")
    println("------------------------------------------")

    # --------------------------------------------------------
    # CREATE USER PROFILE
    # --------------------------------------------------------

    profile =
        create_profile()

    print_profile(
        profile
    )

    # --------------------------------------------------------
    # CREATE PERSONAL TARGET
    # --------------------------------------------------------

    target =
        personal_target(
            profile.preferences
        )

    # --------------------------------------------------------
    # OPTIMISE BOTH EARS
    # --------------------------------------------------------

    println()
    println(
        "Optimising personalised stereo EQ..."
    )

    left_eq,
    right_eq,
    left_error,
    right_error =
        optimise_stereo_eq(
            profile.hearing,
            profile.preferences
        )

    println()
    println(
        "Left-ear optimisation error: ",
        round(
            left_error,
            digits = 5
        )
    )

    println(
        "Right-ear optimisation error: ",
        round(
            right_error,
            digits = 5
        )
    )

    # --------------------------------------------------------
    # LEFT EQ
    # --------------------------------------------------------

    println()
    println("LEFT EAR EQ")

    print_eq(
        left_eq
    )

    # --------------------------------------------------------
    # RIGHT EQ
    # --------------------------------------------------------

    println()
    println("RIGHT EAR EQ")

    print_eq(
        right_eq
    )

    # --------------------------------------------------------
    # OTHER PERSONAL SETTINGS
    # --------------------------------------------------------

    println()

    println(
        "Personalised loudness: ",
        round(
            loudness_gain(
                profile.preferences
            ),
            digits = 2
        ),
        " dB"
    )

    println(
        "Personalised ANC:      ",
        round(
            personalised_anc(
                profile.preferences
            ) * 100.0,
            digits = 1
        ),
        "%"
    )

    println(
        "Spatial width:         ",
        round(
            personalised_spatial_width(
                profile.preferences
            ) * 100.0,
            digits = 1
        ),
        "%"
    )

    # --------------------------------------------------------
    # LEARNING EVENT
    # --------------------------------------------------------

    println()
    println(
        "Learning from listener behaviour..."
    )

    learn_preferences!(
        profile,
        observed_bass = 3.0,
        observed_treble = 0.5,
        observed_loudness = 1.5,
        observed_anc = 0.80,
        observed_spatial_width = 0.75
    )

    print_profile(
        profile
    )

    # --------------------------------------------------------
    # PLOTS
    # --------------------------------------------------------

    plot_hearing_model(
        profile
    )

    plot_target(
        profile.preferences
    )

    plot_compensation(
        profile.hearing.left,
        left_eq,
        target
    )

    println()
    println(
        "Personalisation complete."
    )

end

# ------------------------------------------------------------
# RUN
# ------------------------------------------------------------

if abspath(PROGRAM_FILE) ==
   @__FILE__

    main()

end



