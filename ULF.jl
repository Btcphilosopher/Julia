###############################################################
# ULF VIBRATION ENGINE
#
# Ultra-Low-Frequency Vibration Analysis & Simulation
#
# Frequency range:
#     approximately 0.01 - 20 Hz
#
# Capabilities:
#     - Synthetic vibration generation
#     - Multi-frequency signals
#     - Chirp / frequency sweep
#     - Noise modelling
#     - Band-pass filtering
#     - FFT
#     - PSD
#     - RMS
#     - Peak detection
#     - Spectral analysis
###############################################################

using FFTW
using DSP
using Statistics
using LinearAlgebra
using CSV
using DataFrames
using Plots

###############################################################
# CONFIGURATION
###############################################################

struct ULFConfig
    sample_rate::Float64
    duration::Float64
    low_frequency::Float64
    high_frequency::Float64
end

config = ULFConfig(
    100.0,       # Hz
    300.0,       # seconds
    0.01,        # minimum frequency
    20.0         # maximum frequency
)

###############################################################
# TIME VECTOR
###############################################################

function time_vector(cfg::ULFConfig)

    N = Int(round(cfg.sample_rate * cfg.duration))

    return collect(0:N-1) ./ cfg.sample_rate

end


###############################################################
# BASIC SINUSOID
###############################################################

function vibration_sine(
    t;
    frequency=1.0,
    amplitude=1.0,
    phase=0.0
)

    return amplitude .* sin.(2π .* frequency .* t .+ phase)

end


###############################################################
# MULTI-FREQUENCY VIBRATION
###############################################################

function multi_frequency_vibration(
    t,
    frequencies,
    amplitudes;
    phases=zeros(length(frequencies))
)

    signal = zeros(length(t))

    for i in eachindex(frequencies)

        signal .+= amplitudes[i] .* sin.(
            2π .* frequencies[i] .* t .+
            phases[i]
        )

    end

    return signal

end


###############################################################
# LOW-FREQUENCY DRIFT
###############################################################

function generate_drift(
    t;
    amplitude=1.0,
    frequency=0.02
)

    return amplitude .* sin.(2π .* frequency .* t)

end


###############################################################
# STOCHASTIC VIBRATION
###############################################################

function stochastic_vibration(
    n;
    amplitude=1.0
)

    return amplitude .* randn(n)

end


###############################################################
# BAND-LIMITED STOCHASTIC VIBRATION
###############################################################

function band_limited_noise(
    t,
    fs;
    low=0.01,
    high=10.0,
    amplitude=1.0
)

    x = randn(length(t))

    wn = Butterworth(4)

    hp = digitalfilter(
        Highpass(low; fs=fs),
        wn
    )

    x = filtfilt(hp, x)

    lp = digitalfilter(
        Lowpass(high; fs=fs),
        wn
    )

    x = filtfilt(lp, x)

    return amplitude .* x

end


###############################################################
# FREQUENCY SWEEP / CHIRP
###############################################################

function vibration_chirp(
    t;
    f_start=0.01,
    f_end=20.0,
    amplitude=1.0
)

    T = maximum(t)

    # logarithmic sweep
    k = log(f_end / f_start) / T

    phase = 2π .* f_start .* (
        exp.(k .* t) .- 1
    ) ./ k

    return amplitude .* sin.(phase)

end


###############################################################
# COMBINED ULF SIGNAL
###############################################################

function generate_ulf_signal(cfg)

    t = time_vector(cfg)

    signal = zeros(length(t))

    # Very-low-frequency structural movement
    signal .+= vibration_sine(
        t;
        frequency=0.025,
        amplitude=0.5
    )

    # Building / machine mode
    signal .+= vibration_sine(
        t;
        frequency=0.80,
        amplitude=0.25
    )

    # Secondary mode
    signal .+= vibration_sine(
        t;
        frequency=3.20,
        amplitude=0.12
    )

    # Low-frequency environmental noise
    signal .+= 0.05 .* band_limited_noise(
        t,
        cfg.sample_rate;
        low=0.01,
        high=5.0
    )

    return t, signal

end


###############################################################
# DETREND
###############################################################

function remove_trend(signal)

    return detrend(signal)

end


###############################################################
# BAND-PASS FILTER
###############################################################

function ulf_bandpass(
    signal,
    fs;
    low=0.01,
    high=20.0,
    order=4
)

    filter_design = Butterworth(order)

    bp = digitalfilter(
        Bandpass(low, high; fs=fs),
        filter_design
    )

    return filtfilt(bp, signal)

end


###############################################################
# RMS
###############################################################

function vibration_rms(signal)

    return sqrt(mean(signal .^ 2))

end


###############################################################
# PEAK AMPLITUDE
###############################################################

function peak_amplitude(signal)

    return maximum(abs.(signal))

end


###############################################################
# FFT ANALYSIS
###############################################################

function vibration_fft(signal, fs)

    N = length(signal)

    spectrum = fft(signal)

    frequencies = collect(0:N-1) .* fs ./ N

    magnitude = abs.(spectrum) ./ N

    # Single-sided spectrum

    half = 1:div(N, 2)

    return (
        frequencies[half],
        2 .* magnitude[half]
    )

end


###############################################################
# POWER SPECTRAL DENSITY
###############################################################

function vibration_psd(signal, fs)

    p = welch_pgram(
        signal,
        1024,
        fs=fs
    )

    frequencies = freq(p)

    power = power(p)

    return frequencies, power

end


###############################################################
# DOMINANT FREQUENCIES
###############################################################

function dominant_frequencies(
    signal,
    fs;
    n_peaks=10,
    minimum_frequency=0.01
)

    frequencies, magnitude =
        vibration_fft(signal, fs)

    valid = frequencies .>= minimum_frequency

    frequencies = frequencies[valid]
    magnitude = magnitude[valid]

    peaks = findmaxima(magnitude)

    indices = peaks[1]

    if isempty(indices)
        return DataFrame(
            frequency=Float64[],
            amplitude=Float64[]
        )
    end

    amplitudes = magnitude[indices]
    freqs = frequencies[indices]

    order = sortperm(
        amplitudes,
        rev=true
    )

    count = min(
        n_peaks,
        length(order)
    )

    return DataFrame(
        frequency=freqs[order[1:count]],
        amplitude=amplitudes[order[1:count]]
    )

end


###############################################################
# SPECTRAL CENTROID
###############################################################

function spectral_centroid(
    signal,
    fs
)

    frequencies, magnitude =
        vibration_fft(signal, fs)

    numerator =
        sum(frequencies .* magnitude)

    denominator =
        sum(magnitude)

    return numerator / denominator

end


###############################################################
# ZERO CROSSINGS
###############################################################

function zero_crossing_rate(signal)

    crossings = 0

    for i in 2:length(signal)

        if sign(signal[i]) != sign(signal[i-1])
            crossings += 1
        end

    end

    return crossings / length(signal)

end


###############################################################
# TIME-DOMAIN STATISTICS
###############################################################

function vibration_statistics(signal)

    return Dict(
        "mean" => mean(signal),
        "std" => std(signal),
        "rms" => vibration_rms(signal),
        "peak" => peak_amplitude(signal),
        "peak_to_peak" =>
            maximum(signal) - minimum(signal),
        "crest_factor" =>
            peak_amplitude(signal) /
            vibration_rms(signal)
    )

end


###############################################################
# SAVE RAW SIGNAL
###############################################################

function save_signal(
    filename,
    t,
    signal
)

    df = DataFrame(
        time=t,
        vibration=signal
    )

    CSV.write(filename, df)

end


###############################################################
# PLOT TIME SERIES
###############################################################

function plot_time_signal(
    t,
    signal;
    seconds=60
)

    n = min(
        length(t),
        Int(round(seconds / (t[2] - t[1])))
    )

    return plot(
        t[1:n],
        signal[1:n],
        xlabel="Time (s)",
        ylabel="Amplitude",
        title="Ultra-Low-Frequency Vibration",
        legend=false,
        linewidth=1.2
    )

end


###############################################################
# PLOT FFT
###############################################################

function plot_spectrum(
    signal,
    fs;
    max_frequency=20
)

    f, a = vibration_fft(
        signal,
        fs
    )

    valid = f .<= max_frequency

    return plot(
        f[valid],
        a[valid],
        xlabel="Frequency (Hz)",
        ylabel="Amplitude",
        title="ULF Vibration Spectrum",
        legend=false,
        xscale=:log10,
        linewidth=1.5
    )

end


###############################################################
# PLOT PSD
###############################################################

function plot_psd(
    signal,
    fs;
    max_frequency=20
)

    f, p = vibration_psd(
        signal,
        fs
    )

    valid = f .<= max_frequency

    return plot(
        f[valid],
        p[valid],
        xlabel="Frequency (Hz)",
        ylabel="Power",
        title="ULF Power Spectral Density",
        legend=false,
        xscale=:log10,
        yscale=:log10,
        linewidth=1.5
    )

end


###############################################################
# MAIN ANALYSIS PIPELINE
###############################################################

function analyze_ulf(
    signal,
    fs
)

    println()
    println("======================================")
    println(" ULF VIBRATION ANALYSIS")
    println("======================================")

    stats = vibration_statistics(signal)

    println("Mean:          ", stats["mean"])
    println("Standard Dev:  ", stats["std"])
    println("RMS:           ", stats["rms"])
    println("Peak:          ", stats["peak"])
    println(
        "Peak-to-Peak:  ",
        stats["peak_to_peak"]
    )

    println(
        "Crest Factor:  ",
        stats["crest_factor"]
    )

    println(
        "Spectral Centroid: ",
        spectral_centroid(
            signal,
            fs
        ),
        " Hz"
    )

    println()
    println("Dominant frequencies:")
    println()

    peaks = dominant_frequencies(
        signal,
        fs
    )

    println(peaks)

    return peaks

end


###############################################################
# EXAMPLE RUN
###############################################################

t, raw_signal =
    generate_ulf_signal(config)

###############################################################
# CONDITION SIGNAL
###############################################################

clean_signal =
    remove_trend(raw_signal)

filtered_signal =
    ulf_bandpass(
        clean_signal,
        config.sample_rate;
        low=config.low_frequency,
        high=config.high_frequency
    )

###############################################################
# ANALYSIS
###############################################################

results = analyze_ulf(
    filtered_signal,
    config.sample_rate
)

###############################################################
# EXPORT
###############################################################

save_signal(
    "ulf_vibration_data.csv",
    t,
    filtered_signal
)

###############################################################
# VISUALISATION
###############################################################

p1 = plot_time_signal(
    t,
    filtered_signal;
    seconds=120
)

p2 = plot_spectrum(
    filtered_signal,
    config.sample_rate
)

p3 = plot_psd(
    filtered_signal,
    config.sample_rate
)

display(p1)
display(p2)
display(p3)

println()
println("ULF analysis complete.")
println("Data written to ulf_vibration_data.csv")
