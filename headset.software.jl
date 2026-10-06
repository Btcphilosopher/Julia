# ==============================================================
# HEADSET AUDIO ENGINE — JULIA
# Prototype architecture for a modern wireless headset
#
# Modules:
#   • microphone input
#   • noise reduction
#   • equaliser
#   • dynamic range compressor
#   • spatial stereo processing
#   • volume control
#   • battery / thermal telemetry
#   • headset state management
#
# Julia 1.10+
# ==============================================================

using FFTW
using LinearAlgebra

# --------------------------------------------------------------
# HEADSET CONFIGURATION
# --------------------------------------------------------------

struct HeadsetConfig
    sample_rate::Int
    channels::Int
    block_size::Int

    master_volume::Float64

    bass_gain::Float64
    mid_gain::Float64
    treble_gain::Float64

    spatial_width::Float64

    noise_reduction::Float64
    compression_ratio::Float64
end

config = HeadsetConfig(
    48_000,     # sample rate
    2,          # stereo
    256,        # samples/block

    0.75,       # volume

    1.5,        # bass
    0.0,        # mids
    2.0,        # treble

    1.15,       # stereo width

    0.65,       # noise reduction
    3.0         # compression ratio
)

# --------------------------------------------------------------
# HEADSET STATE
# --------------------------------------------------------------

mutable struct HeadsetState

    connected::Bool

    bluetooth::Bool

    battery::Float64

    temperature::Float64

    volume::Float64

    anc_enabled::Bool

    transparency_enabled::Bool

    spatial_audio::Bool

    muted::Bool

end

state = HeadsetState(
    false,
    false,
    1.0,
    25.0,
    config.master_volume,
    true,
    false,
    true,
    false
)

# --------------------------------------------------------------
# BATTERY MODEL
# --------------------------------------------------------------

function update_battery!(
    state::HeadsetState,
    audio_power::Float64,
    dt::Float64
)

    # Approximate power consumption
    base_consumption = 0.000002
    audio_consumption = audio_power * 0.000004

    state.battery -=
        (base_consumption + audio_consumption) * dt

    state.battery =
        clamp(state.battery, 0.0, 1.0)

    return state.battery
end

# --------------------------------------------------------------
# SIMPLE LOW-PASS FILTER
# --------------------------------------------------------------

mutable struct LowPass

    α::Float64
    previous::Float64

end

function LowPass(
    cutoff::Float64,
    sample_rate::Int
)

    α =
        1.0 -
        exp(
            -2π * cutoff /
            sample_rate
        )

    return LowPass(α, 0.0)
end

function process!(
    filter::LowPass,
    x::Vector{Float64}
)

    y = similar(x)

    for i in eachindex(x)

        filter.previous +=
            filter.α *
            (x[i] - filter.previous)

        y[i] = filter.previous
    end

    return y
end

# --------------------------------------------------------------
# HIGH-PASS FILTER
# --------------------------------------------------------------

mutable struct HighPass

    α::Float64
    previous_input::Float64
    previous_output::Float64

end

function HighPass(
    cutoff::Float64,
    sample_rate::Int
)

    α =
        exp(
            -2π * cutoff /
            sample_rate
        )

    return HighPass(
        α,
        0.0,
        0.0
    )
end

function process!(
    filter::HighPass,
    x::Vector{Float64}
)

    y = similar(x)

    for i in eachindex(x)

        y[i] =
            filter.α *
            (
                filter.previous_output +
                x[i] -
                filter.previous_input
            )

        filter.previous_input = x[i]
        filter.previous_output = y[i]

    end

    return y
end

# --------------------------------------------------------------
# THREE-BAND EQUALISER
# --------------------------------------------------------------

mutable struct Equaliser

    bass::LowPass
    treble::HighPass

    bass_gain::Float64
    mid_gain::Float64
    treble_gain::Float64

end

function Equaliser(config)

    return Equaliser(

        LowPass(
            250.0,
            config.sample_rate
        ),

        HighPass(
            4000.0,
            config.sample_rate
        ),

        10.0^(config.bass_gain / 20),
        10.0^(config.mid_gain / 20),
        10.0^(config.treble_gain / 20)
    )
end

function process!(
    eq::Equaliser,
    x::Vector{Float64}
)

    bass =
        process!(eq.bass, x)

    treble =
        process!(eq.treble, x)

    mid =
        x .- bass .- treble

    return (
        eq.bass_gain .* bass +
        eq.mid_gain .* mid +
        eq.treble_gain .* treble
    )
end

# --------------------------------------------------------------
# DYNAMIC RANGE COMPRESSOR
# --------------------------------------------------------------

struct Compressor

    threshold::Float64
    ratio::Float64
    attack::Float64
    release::Float64

end

compressor =
    Compressor(
        0.55,
        3.0,
        0.01,
        0.10
    )

function compress(
    c::Compressor,
    x::Vector{Float64}
)

    y = similar(x)

    for i in eachindex(x)

        level = abs(x[i])

        if level > c.threshold

            excess =
                level -
                c.threshold

            compressed =
                c.threshold +
                excess / c.ratio

            y[i] =
                sign(x[i]) *
                compressed

        else

            y[i] = x[i]

        end
    end

    return y
end

# --------------------------------------------------------------
# NOISE REDUCTION
#
# Spectral attenuation of low-energy frequency bins.
# --------------------------------------------------------------

function noise_reduce(
    x::Vector{Float64},
    strength::Float64
)

    N = length(x)

    spectrum =
        fft(x)

    magnitude =
        abs.(spectrum)

    threshold =
        median(magnitude) *
        (1.0 + 4.0 * strength)

    for i in eachindex(spectrum)

        if magnitude[i] < threshold

            spectrum[i] *=
                (1.0 - strength)
        end
    end

    return real(
        ifft(spectrum)
    )
end

# --------------------------------------------------------------
# STEREO SPATIAL PROCESSOR
#
# Mid/side processing:
#
#     M = L + R
#     S = L - R
#
# Increasing S increases perceived width.
# --------------------------------------------------------------

function spatial_process(
    left::Vector{Float64},
    right::Vector{Float64},
    width::Float64
)

    mid =
        (left + right) ./ 2

    side =
        (left - right) ./ 2

    side .*= width

    L =
        mid + side

    R =
        mid - side

    return L, R
end

# --------------------------------------------------------------
# MASTER VOLUME
# --------------------------------------------------------------

function apply_volume!(
    x::Vector{Float64},
    volume::Float64
)

    x .*= volume

    # Prevent digital clipping
    x .= clamp.(x, -1.0, 1.0)

    return x
end

# --------------------------------------------------------------
# COMPLETE AUDIO PIPELINE
# --------------------------------------------------------------

mutable struct AudioEngine

    config::HeadsetConfig

    equaliser::Equaliser

    compressor::Compressor

end

engine =
    AudioEngine(
        config,
        Equaliser(config),
        compressor
    )

function process_audio!(
    engine::AudioEngine,
    state::HeadsetState,
    left::Vector{Float64},
    right::Vector{Float64}
)

    # ----------------------------------------------------------
    # MUTE
    # ----------------------------------------------------------

    if state.muted

        return (
            zeros(length(left)),
            zeros(length(right))
        )

    end

    # ----------------------------------------------------------
    # NOISE REDUCTION
    # ----------------------------------------------------------

    if state.anc_enabled

        left =
            noise_reduce(
                left,
                engine.config.noise_reduction
            )

        right =
            noise_reduce(
                right,
                engine.config.noise_reduction
            )
    end

    # ----------------------------------------------------------
    # EQUALISER
    # ----------------------------------------------------------

    left =
        process!(
            engine.equaliser,
            left
        )

    right =
        process!(
            engine.equaliser,
            right
        )

    # ----------------------------------------------------------
    # COMPRESSION
    # ----------------------------------------------------------

    left =
        compress(
            engine.compressor,
            left
        )

    right =
        compress(
            engine.compressor,
            right
        )

    # ----------------------------------------------------------
    # SPATIAL AUDIO
    # ----------------------------------------------------------

    if state.spatial_audio

        left, right =
            spatial_process(
                left,
                right,
                engine.config.spatial_width
            )
    end

    # ----------------------------------------------------------
    # MASTER VOLUME
    # ----------------------------------------------------------

    apply_volume!(
        left,
        state.volume
    )

    apply_volume!(
        right,
        state.volume
    )

    return left, right
end

# --------------------------------------------------------------
# HEADSET COMMAND INTERFACE
# --------------------------------------------------------------

function connect!(
    state::HeadsetState
)

    state.connected = true
    state.bluetooth = true

    println("Headset connected.")

end

function disconnect!(
    state::HeadsetState
)

    state.connected = false
    state.bluetooth = false

    println("Headset disconnected.")

end

function set_volume!(
    state::HeadsetState,
    volume::Float64
)

    state.volume =
        clamp(volume, 0.0, 1.0)

end

function toggle_anc!(
    state::HeadsetState
)

    state.anc_enabled =
        !state.anc_enabled

end

function toggle_spatial!(
    state::HeadsetState
)

    state.spatial_audio =
        !state.spatial_audio

end

# --------------------------------------------------------------
# DIAGNOSTICS
# --------------------------------------------------------------

function diagnostics(
    state::HeadsetState
)

    println()
    println("================ HEADSET =================")
    println(
        "Connection:   ",
        state.connected
    )
    println(
        "Bluetooth:    ",
        state.bluetooth
    )
    println(
        "Battery:      ",
        round(
            state.battery * 100,
            digits = 1
        ),
        "%"
    )
    println(
        "Temperature:  ",
        round(
            state.temperature,
            digits = 1
        ),
        " °C"
    )
    println(
        "Volume:       ",
        round(
            state.volume * 100,
            digits = 1
        ),
        "%"
    )
    println(
        "ANC:          ",
        state.anc_enabled
    )
    println(
        "Transparency: ",
        state.transparency_enabled
    )
    println(
        "Spatial:      ",
        state.spatial_audio
    )
    println("==========================================")
end

# --------------------------------------------------------------
# DEMONSTRATION
# --------------------------------------------------------------

connect!(state)

diagnostics(state)

# Simulated audio block
N = config.block_size

t =
    (0:N-1) ./ config.sample_rate

left =
    0.5 .* sin.(2π * 440 .* t)

right =
    0.5 .* sin.(2π * 442 .* t)

# Process audio
output_left,
output_right =
    process_audio!(
        engine,
        state,
        left,
        right
    )

# Estimate audio power
audio_power =
    mean(
        output_left.^2 +
        output_right.^2
    )

update_battery!(
    state,
    audio_power,
    N / config.sample_rate
)

println()
println(
    "Processed ",
    N,
    " samples."
)

println(
    "Peak output: ",
    maximum(
        abs.(
            vcat(
                output_left,
                output_right
            )
        )
    )
)

diagnostics(state)

