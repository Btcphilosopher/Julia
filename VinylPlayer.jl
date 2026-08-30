module VinylPlayer

using FFTW
using Statistics
using Printf

# ============================================================
# VINYL PLAYER
#
# Pure Julia
#
# Digital simulation of an analogue turntable.
#
# Features:
#   - 33 1/3 RPM
#   - 45 RPM
#   - Variable pitch
#   - Turntable acceleration
#   - Wow
#   - Flutter
#   - Needle/stylus response
#   - RIAA-style playback EQ approximation
#   - Vinyl noise
#   - Crackle
#   - Cueing
#   - Crossfade
#   - Looping
#   - Stereo playback
#   - Waveform analysis
#   - Track library
# ============================================================


# ============================================================
# CONSTANTS
# ============================================================

const RPM_33 = 33.333333333333336
const RPM_45 = 45.0

const DEFAULT_SAMPLE_RATE = 44100


# ============================================================
# TRACK
# ============================================================

struct Track

    id::Int

    title::String
    artist::String
    album::String

    samples::Matrix{Float64}

    sample_rate::Int

    duration_s::Float64

    rpm::Float64
end


function Track(
    id::Int,
    title::String,
    artist::String,
    album::String,
    samples::Matrix{Float64},
    sample_rate::Int,
    rpm::Float64
)

    duration =
        size(samples, 1) /
        sample_rate

    Track(
        id,
        title,
        artist,
        album,
        samples,
        sample_rate,
        duration,
        rpm
    )
end


# ============================================================
# RECORD
# ============================================================

struct Record

    title::String
    artist::String
    album::String

    rpm::Float64

    diameter_inches::Float64

    tracks::Vector{Track}
end


# ============================================================
# TURNTABLE
# ============================================================

mutable struct Turntable

    rpm::Float64

    target_rpm::Float64

    pitch_percent::Float64

    pitch_range_percent::Float64

    platter_speed::Float64

    acceleration::Float64

    wow_amount::Float64

    flutter_amount::Float64

    stylus_wear::Float64

    tracking_error::Float64

    noise_level::Float64

    crackle_level::Float64
end


function Turntable(;
    rpm=RPM_33,
    pitch_range_percent=8.0
)

    Turntable(
        rpm,
        rpm,
        0.0,
        pitch_range_percent,
        rpm,
        50.0,
        0.0005,
        0.0002,
        0.0,
        0.0,
        0.002,
        0.001
    )
end


# ============================================================
# CARTRIDGE
# ============================================================

struct Cartridge

    name::String

    output_mV::Float64

    compliance::Float64

    tracking_force_g::Float64

    channel_separation_dB::Float64

    frequency_response_low_Hz::Float64

    frequency_response_high_Hz::Float64
end


# ============================================================
# STYLUS
# ============================================================

struct Stylus

    name::String

    tip_radius_um::Float64

    contact_area::Float64

    wear_rate::Float64
end


# ============================================================
# PHONO PREAMP
# ============================================================

struct PhonoStage

    gain_dB::Float64

    riaa_enabled::Bool

    low_cut_Hz::Float64

    high_cut_Hz::Float64

    saturation_level::Float64
end


# ============================================================
# PLAYER STATE
# ============================================================

mutable struct PlayerState

    record::Union{Record,Nothing}

    track::Union{Track,Nothing}

    position_s::Float64

    playing::Bool

    cueing::Bool

    looping::Bool

    loop_start_s::Float64

    loop_end_s::Float64

    volume::Float64

    crossfader::Float64

    left_gain::Float64

    right_gain::Float64
end


function PlayerState()

    PlayerState(
        nothing,
        nothing,
        0.0,
        false,
        false,
        false,
        0.0,
        0.0,
        1.0,
        0.0,
        1.0,
        1.0
    )
end


# ============================================================
# VINYL LIBRARY
# ============================================================

mutable struct VinylLibrary

    records::Vector{Record}
end


VinylLibrary() =
    VinylLibrary(Record[])


function add_record!(
    library::VinylLibrary,
    record::Record
)

    push!(
        library.records,
        record
    )

    return record
end


function find_record(
    library::VinylLibrary,
    title::String
)

    for record in library.records

        if lowercase(record.title) ==
           lowercase(title)

            return record
        end
    end

    return nothing
end


# ============================================================
# TURNTABLE SPEED
# ============================================================

function set_speed!(
    turntable::Turntable,
    rpm::Float64
)

    rpm in
        (RPM_33, RPM_45) ||
        error("Supported speeds: 33⅓ and 45 RPM.")

    turntable.target_rpm =
        rpm

    return turntable
end


function set_pitch!(
    turntable::Turntable,
    pitch_percent::Float64
)

    abs(pitch_percent) <=
        turntable.pitch_range_percent ||
        error("Pitch outside configured range.")

    turntable.pitch_percent =
        pitch_percent

    return turntable
end


function update_platter!(
    turntable::Turntable,
    dt::Float64
)

    target =
        turntable.target_rpm *
        (
            1.0 +
            turntable.pitch_percent /
            100.0
        )

    difference =
        target -
        turntable.platter_speed

    change =
        sign(difference) *
        min(
            abs(difference),
            turntable.acceleration *
            dt
        )

    turntable.platter_speed +=
        change

    return turntable.platter_speed
end


# ============================================================
# WOW
# ============================================================

function wow_multiplier(
    turntable::Turntable,
    time_s::Float64
)

    amount =
        turntable.wow_amount

    1.0 +
    amount *
    sin(
        2π *
        0.5 *
        time_s
    )
end


# ============================================================
# FLUTTER
# ============================================================

function flutter_multiplier(
    turntable::Turntable,
    time_s::Float64
)

    amount =
        turntable.flutter_amount

    1.0 +
    amount *
    sin(
        2π *
        7.0 *
        time_s
    )
end


# ============================================================
# EFFECTIVE RPM
# ============================================================

function effective_rpm(
    turntable::Turntable,
    time_s::Float64
)

    turntable.platter_speed *
    wow_multiplier(
        turntable,
        time_s
    ) *
    flutter_multiplier(
        turntable,
        time_s
    )
end


# ============================================================
# SAMPLE POSITION
# ============================================================

function playback_rate(
    turntable::Turntable,
    track::Track,
    time_s::Float64
)

    rpm =
        effective_rpm(
            turntable,
            time_s
        )

    rpm /
    track.rpm
end


# ============================================================
# VINYL NOISE
# ============================================================

function vinyl_noise(
    turntable::Turntable,
    n::Int
)

    turntable.noise_level *
    randn(n)
end


# ============================================================
# VINYL CRACKLE
# ============================================================

function vinyl_crackle(
    turntable::Turntable,
    n::Int
)

    signal =
        zeros(Float64, n)

    for i in 1:n

        if rand() <
           turntable.crackle_level

            amplitude =
                0.05 +
                0.20 *
                rand()

            signal[i] =
                amplitude *
                (
                    rand() >
                    0.5 ?
                    1.0 :
                    -1.0
                )
        end
    end

    signal
end


# ============================================================
# RIAA PLAYBACK EQ
#
# Simplified analogue-style shelving approximation.
# ============================================================

function riaa_filter(
    samples::Vector{Float64},
    sample_rate::Int
)

    output =
        similar(samples)

    low_state =
        0.0

    high_state =
        0.0

    low_alpha =
        exp(
            -2π *
            50.0 /
            sample_rate
        )

    high_alpha =
        exp(
            -2π *
            2122.0 /
            sample_rate
        )

    for i in eachindex(samples)

        x =
            samples[i]

        low_state =
            low_alpha *
            low_state +
            (1.0 -
             low_alpha) *
            x

        high_state =
            high_alpha *
            high_state +
            (1.0 -
             high_alpha) *
            x

        output[i] =
            x +
            0.7 *
            low_state -
            0.25 *
            high_state
    end

    output
end


# ============================================================
# CARTRIDGE RESPONSE
# ============================================================

function cartridge_response(
    samples::Vector{Float64},
    cartridge::Cartridge,
    sample_rate::Int
)

    gain =
        cartridge.output_mV /
        5.0

    result =
        samples .* gain

    return result
end


# ============================================================
# STYLUS RESPONSE
# ============================================================

function stylus_response(
    samples::Vector{Float64},
    stylus::Stylus,
    sample_rate::Int
)

    wear =
        stylus.wear_rate

    damping =
        clamp(
            1.0 -
            wear,
            0.5,
            1.0
        )

    return samples .* damping
end


# ============================================================
# STEREO SEPARATION
# ============================================================

function apply_channel_separation!(
    samples::Matrix{Float64},
    separation_dB::Float64
)

    separation =
        10.0 ^
        (-separation_dB / 20.0)

    n =
        size(samples, 1)

    for i in 1:n

        left =
            samples[i, 1]

        right =
            samples[i, 2]

        samples[i, 1] =
            left +
            separation * right

        samples[i, 2] =
            right +
            separation * left
    end

    samples
end


# ============================================================
# SATURATION
# ============================================================

function saturate(
    x::Float64,
    level::Float64
)

    if level <= 0
        return x
    end

    tanh(
        x * level
    ) /
    tanh(level)
end


function apply_saturation!(
    samples::Matrix{Float64},
    stage::PhonoStage
)

    for i in axes(samples, 1)

        samples[i, 1] =
            saturate(
                samples[i, 1],
                stage.saturation_level
            )

        samples[i, 2] =
            saturate(
                samples[i, 2],
                stage.saturation_level
            )
    end

    samples
end


# ============================================================
# LOAD TRACK
# ============================================================

function load_track!(
    player::PlayerState,
    record::Record,
    track_index::Int
)

    1 <= track_index <=
        length(record.tracks) ||
        error("Invalid track.")

    player.record =
        record

    player.track =
        record.tracks[track_index]

    player.position_s =
        0.0

    player.playing =
        false

    return player.track
end


# ============================================================
# CUE
# ============================================================

function cue!(
    player::PlayerState,
    position_s::Float64
)

    player.track === nothing &&
        error("No track loaded.")

    player.position_s =
        clamp(
            position_s,
            0.0,
            player.track.duration_s
        )

    player.cueing =
        true

    return player.position_s
end


# ============================================================
# PLAY / STOP
# ============================================================

function play!(
    player::PlayerState
)

    player.track === nothing &&
        error("No track loaded.")

    player.playing =
        true

    player.cueing =
        false

    return player
end


function stop!(
    player::PlayerState
)

    player.playing =
        false

    return player
end


# ============================================================
# LOOP
# ============================================================

function set_loop!(
    player::PlayerState,
    start_s::Float64,
    end_s::Float64
)

    player.track === nothing &&
        error("No track loaded.")

    start_s < end_s ||
        error("Invalid loop.")

    end_s <=
        player.track.duration_s ||
        error("Loop exceeds track.")

    player.loop_start_s =
        start_s

    player.loop_end_s =
        end_s

    player.looping =
        true

    return player
end


function disable_loop!(
    player::PlayerState
)

    player.looping =
        false

    return player
end


# ============================================================
# CROSSFADE
# ============================================================

function crossfade(
    left::Matrix{Float64},
    right::Matrix{Float64},
    position::Float64
)

    p =
        clamp(
            position,
            0.0,
            1.0
        )

    left_gain =
        cos(
            p * π / 2
        )

    right_gain =
        sin(
            p * π / 2
        )

    n =
        min(
            size(left, 1),
            size(right, 1)
        )

    result =
        zeros(Float64, n, 2)

    for i in 1:n

        result[i, 1] =
            left[i, 1] *
            left_gain +
            right[i, 1] *
            right_gain

        result[i, 2] =
            left[i, 2] *
            left_gain +
            right[i, 2] *
            right_gain
    end

    result
end


# ============================================================
# PLAYBACK BUFFER
# ============================================================

function render_audio(
    player::PlayerState,
    turntable::Turntable,
    cartridge::Cartridge,
    stylus::Stylus,
    phono::PhonoStage,
    duration_s::Float64
)

    player.track === nothing &&
        error("No track loaded.")

    track =
        player.track

    fs =
        track.sample_rate

    n =
        Int(
            round(
                duration_s * fs
            )
        )

    output =
        zeros(Float64, n, 2)

    for i in 1:n

        time =
            (i - 1) / fs

        source_time =
            player.position_s +
            time *
            playback_rate(
                turntable,
                track,
                time
            )

        # Loop

        if player.looping &&
           source_time >=
           player.loop_end_s

            source_time =
                player.loop_start_s +
                mod(
                    source_time -
                    player.loop_start_s,
                    player.loop_end_s -
                    player.loop_start_s
                )
        end

        if source_time >=
           track.duration_s

            break
        end

        index =
            Int(
                floor(
                    source_time *
                    fs
                )
            ) + 1

        if index >= 1 &&
           index <= size(track.samples, 1)

            output[i, 1] =
                track.samples[index, 1]

            output[i, 2] =
                track.samples[index, 2]
        end
    end

    # Cartridge

    output[:, 1] =
        cartridge_response(
            output[:, 1],
            cartridge,
            fs
        )

    output[:, 2] =
        cartridge_response(
            output[:, 2],
            cartridge,
            fs
        )

    # Stylus

    output[:, 1] =
        stylus_response(
            output[:, 1],
            stylus,
            fs
        )

    output[:, 2] =
        stylus_response(
            output[:, 2],
            stylus,
            fs
        )

    # RIAA

    if phono.riaa_enabled

        output[:, 1] =
            riaa_filter(
                output[:, 1],
                fs
            )

        output[:, 2] =
            riaa_filter(
                output[:, 2],
                fs
            )
    end

    # Vinyl surface noise

    noise_left =
        vinyl_noise(
            turntable,
            n
        )

    noise_right =
        vinyl_noise(
            turntable,
            n
        )

    crackle_left =
        vinyl_crackle(
            turntable,
            n
        )

    crackle_right =
        vinyl_crackle(
            turntable,
            n
        )

    output[:, 1] .+=
        noise_left +
        crackle_left

    output[:, 2] .+=
        noise_right +
        crackle_right

    # Volume

    output .*=
        player.volume

    # Phono saturation

    apply_saturation!(
        output,
        phono
    )

    return output
end


# ============================================================
# WAVEFORM ANALYSIS
# ============================================================

function waveform_peaks(
    samples::Matrix{Float64}
)

    left =
        samples[:, 1]

    right =
        samples[:, 2]

    (
        maximum(abs.(left)),
        maximum(abs.(right))
    )
end


# ============================================================
# RMS
# ============================================================

function rms(
    samples::Vector{Float64}
)

    sqrt(
        mean(
            samples .^ 2
        )
    )
end


function stereo_rms(
    samples::Matrix{Float64}
)

    (
        rms(samples[:, 1]),
        rms(samples[:, 2])
    )
end


# ============================================================
# SPECTRUM
# ============================================================

function spectrum(
    samples::Vector{Float64},
    sample_rate::Int
)

    n =
        length(samples)

    window =
        0.5 .-
        0.5 .* cos.(
            2π .* (
                0:n-1
            ) ./ max(n - 1, 1)
        )

    transformed =
        fft(
            samples .* window
        )

    frequencies =
        collect(
            0:div(n, 2)
        ) .* sample_rate ./ n

    magnitude =
        abs.(
            transformed[
                1:div(n, 2)+1
            ]
        )

    return (
        frequencies,
        magnitude
    )
end


# ============================================================
# SPEED REPORT
# ============================================================

function speed_report(
    turntable::Turntable
)

    println()
    println(
        "VINYL TURNTABLE"
    )
    println(
        "-----------------------------"
    )

    @printf(
        "Target RPM:       %.3f\n",
        turntable.target_rpm
    )

    @printf(
        "Actual RPM:       %.3f\n",
        turntable.platter_speed
    )

    @printf(
        "Pitch:            %+.2f %%\n",
        turntable.pitch_percent
    )

    @printf(
        "Wow:              %.4f %%\n",
        turntable.wow_amount * 100
    )

    @printf(
        "Flutter:          %.4f %%\n",
        turntable.flutter_amount * 100
    )

    println(
        "-----------------------------"
    )
end


# ============================================================
# PLAYER STATUS
# ============================================================

function status(
    player::PlayerState,
    turntable::Turntable
)

    println()
    println(
        "=========================================="
    )
    println(
        "              VINYL PLAYER"
    )
    println(
        "=========================================="
    )

    if player.track === nothing

        println(
            "NO RECORD"
        )

    else

        println(
            player.track.artist,
            " — ",
            player.track.title
        )

        println(
            player.track.album
        )

        @printf(
            "Position: %.2f / %.2f s\n",
            player.position_s,
            player.track.duration_s
        )
    end

    println()

    println(
        player.playing ?
        "● PLAYING" :
        "■ STOPPED"
    )

    println(
        player.cueing ?
        "CUE MODE" :
        ""
    )

    speed_report(
        turntable
    )

    println(
        "=========================================="
    )
end


# ============================================================
# DEMO RECORD
# ============================================================

function demo_track()

    fs =
        DEFAULT_SAMPLE_RATE

    duration =
        10.0

    n =
        Int(
            duration * fs
        )

    samples =
        zeros(Float64, n, 2)

    # Synthetic demonstration audio:
    # bass + mid + high-frequency content.

    for i in 1:n

        t =
            (i - 1) / fs

        signal =
            0.35 *
            sin(
                2π * 80 * t
            ) +

            0.20 *
            sin(
                2π * 440 * t
            ) +

            0.08 *
            sin(
                2π * 3000 * t
            )

        samples[i, 1] =
            signal

        samples[i, 2] =
            signal
    end

    Track(
        1,
        "Side A Demo",
        "OpenAllHours",
        "The Vinyl Test Record",
        samples,
        fs,
        RPM_33
    )
end


function demo_record()

    track =
        demo_track()

    Record(
        "The Vinyl Test Record",
        "OpenAllHours",
        "Demo Pressing",
        RPM_33,
        12.0,
        [track]
    )
end


# ============================================================
# DEMO
# ============================================================

function demo()

    println()
    println(
        "OPEN VINYL — PURE JULIA"
    )
    println()

    library =
        VinylLibrary()

    record =
        demo_record()

    add_record!(
        library,
        record
    )

    turntable =
        Turntable()

    cartridge =
        Cartridge(
            "Moving Magnet",
            5.0,
            20.0,
            1.8,
            25.0,
            20.0,
            20000.0
        )

    stylus =
        Stylus(
            "Elliptical",
            8.0,
            1.0,
            0.01
        )

    phono =
        PhonoStage(
            40.0,
            true,
            20.0,
            20000.0,
            0.05
        )

    player =
        PlayerState()

    load_track!(
        player,
        record,
        1
    )

    set_speed!(
        turntable,
        RPM_33
    )

    set_pitch!(
        turntable,
        0.0
    )

    play!(
        player
    )

    # Spin platter up.

    for i in 1:100

        update_platter!(
            turntable,
            0.01
        )
    end

    status(
        player,
        turntable
    )

    # Render 2 seconds.

    audio =
        render_audio(
            player,
            turntable,
            cartridge,
            stylus,
            phono,
            2.0
        )

    println()

    (
        left_peak,
        right_peak
    ) =
        waveform_peaks(audio)

    (
        left_rms,
        right_rms
    ) =
        stereo_rms(audio)

    @printf(
        "Left peak:       %.4f\n",
        left_peak
    )

    @printf(
        "Right peak:      %.4f\n",
        right_peak
    )

    @printf(
        "Left RMS:        %.4f\n",
        left_rms
    )

    @printf(
        "Right RMS:       %.4f\n",
        right_rms
    )

    frequencies,
    magnitudes =
        spectrum(
            audio[:, 1],
            DEFAULT_SAMPLE_RATE
        )

    peak_index =
        argmax(
            magnitudes[2:end]
        ) + 1

    @printf(
        "Dominant frequency: %.2f Hz\n",
        frequencies[peak_index]
    )

    println()
    println(
        "Vinyl simulation complete."
    )

    return audio
end


# ============================================================
# EXPORTS
# ============================================================

export Track
export Record
export Turntable
export Cartridge
export Stylus
export PhonoStage
export PlayerState
export VinylLibrary

export add_record!
export find_record

export set_speed!
export set_pitch!
export update_platter!

export load_track!
export cue!
export play!
export stop!

export set_loop!
export disable_loop!

export render_audio

export waveform_peaks
export stereo_rms
export spectrum

export speed_report
export status

export demo


end # module VinylPlayer


# ============================================================
# RUN DEMO
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .VinylPlayer

    VinylPlayer.demo()

end
