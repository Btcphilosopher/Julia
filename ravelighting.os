# RAVE.LIGHT.OS

## Pure Julia — Advanced Electronic Music Lighting Control Engine

```julia
module RaveLightOS

using Dates
using Random
using Statistics

# ============================================================
# RAVE.LIGHT.OS
#
# Advanced lighting-control engine for:
#
#   • LED fixtures
#   • moving heads
#   • pixel bars
#   • strobes
#   • lasers (logical channel only)
#   • haze/fog systems
#   • architectural lighting
#   • video-reactive installations
#
# The engine produces ABSTRACT fixture commands.
#
# A hardware adapter can subsequently translate those commands
# into DMX, Art-Net, sACN, OSC, MIDI, etc.
#
# SAFETY:
# Physical lighting equipment should retain independent
# hardware safety systems, especially strobes, lasers,
# foggers and high-power fixtures.
# ============================================================


# ============================================================
# VERSION
# ============================================================

const VERSION = "1.0.0"


# ============================================================
# ENUMERATIONS
# ============================================================

@enum ShowState begin
    OFF
    IDLE
    ARMED
    RUNNING
    PAUSED
    BLACKOUT
    FAULT
end


@enum EffectMode begin
    STATIC
    PULSE
    STROBE
    CHASE
    WAVE
    COLOR_WASH
    BASS_REACTIVE
    BEAT_REACTIVE
    RANDOMIZED
end


@enum FixtureKind begin
    LED_BAR
    MOVING_HEAD
    PIXEL_PANEL
    STROBE_FIXTURE
    LASER_FIXTURE
    HAZE_MACHINE
    ARCHITECTURAL
end


@enum BeatDivision begin
    WHOLE
    HALF
    QUARTER
    EIGHTH
    SIXTEENTH
end


# ============================================================
# COLOR
# ============================================================

struct RGB
    r::Float64
    g::Float64
    b::Float64
end


function RGB(r::Real, g::Real, b::Real)

    RGB(
        clamp(Float64(r), 0.0, 1.0),
        clamp(Float64(g), 0.0, 1.0),
        clamp(Float64(b), 0.0, 1.0)
    )

end


const BLACK = RGB(0.0, 0.0, 0.0)
const WHITE = RGB(1.0, 1.0, 1.0)
const RED   = RGB(1.0, 0.0, 0.0)
const GREEN = RGB(0.0, 1.0, 0.0)
const BLUE  = RGB(0.0, 0.0, 1.0)


function scale(c::RGB, x::Real)

    RGB(
        c.r * x,
        c.g * x,
        c.b * x
    )

end


function lerp(a::RGB, b::RGB, x::Real)

    t = clamp(Float64(x), 0.0, 1.0)

    RGB(
        a.r + (b.r - a.r) * t,
        a.g + (b.g - a.g) * t,
        a.b + (b.b - a.b) * t
    )

end


# ============================================================
# LIGHTING PARAMETERS
# ============================================================

struct LightingState

    color::RGB

    intensity::Float64

    pan::Float64
    tilt::Float64

    zoom::Float64

    strobe::Float64

    haze::Float64

end


function LightingState()

    LightingState(
        WHITE,
        0.0,
        0.5,
        0.5,
        0.5,
        0.0,
        0.0
    )

end


# ============================================================
# FIXTURE
# ============================================================

mutable struct Fixture

    id::Int

    name::String

    kind::FixtureKind

    group::Symbol

    address::Int

    state::LightingState

    enabled::Bool

end


function Fixture(
    id::Int,
    name::String,
    kind::FixtureKind,
    group::Symbol,
    address::Int
)

    Fixture(
        id,
        name,
        kind,
        group,
        address,
        LightingState(),
        true
    )

end


# ============================================================
# FIXTURE COMMAND
# ============================================================

struct FixtureCommand

    fixture_id::Int

    intensity::Float64

    color::RGB

    pan::Float64

    tilt::Float64

    zoom::Float64

    strobe::Float64

    haze::Float64

end


function command(
    fixture::Fixture
)

    s = fixture.state

    FixtureCommand(

        fixture.id,

        s.intensity,

        s.color,

        s.pan,

        s.tilt,

        s.zoom,

        s.strobe,

        s.haze
    )

end


# ============================================================
# GROUP
# ============================================================

mutable struct FixtureGroup

    name::Symbol

    fixture_ids::Vector{Int}

end


FixtureGroup(name::Symbol) =
    FixtureGroup(name, Int[])


# ============================================================
# AUDIO ANALYSIS
# ============================================================

struct AudioFrame

    timestamp::Float64

    amplitude::Float64

    bass::Float64

    mid::Float64

    treble::Float64

    bpm::Float64

    beat::Bool

end


function AudioFrame()

    AudioFrame(
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        128.0,
        false
    )

end


# ============================================================
# BEAT CLOCK
# ============================================================

mutable struct BeatClock

    bpm::Float64

    phase::Float64

    last_beat::Float64

    beat_number::UInt64

end


function BeatClock(bpm::Real=128.0)

    BeatClock(
        clamp(Float64(bpm), 40.0, 240.0),
        0.0,
        0.0,
        UInt64(0)
    )

end


function beat_period(clock::BeatClock)

    60.0 / clock.bpm

end


function update!(
    clock::BeatClock,
    dt::Real
)

    clock.phase +=
        Float64(dt) /
        beat_period(clock)

    beat = false

    if clock.phase >= 1.0

        clock.phase -= 1.0

        clock.beat_number += 1

        clock.last_beat = 0.0

        beat = true

    else

        clock.last_beat += Float64(dt)

    end

    beat

end


# ============================================================
# SHOW CUE
# ============================================================

struct Cue

    name::Symbol

    duration::Float64

    effect::EffectMode

    group::Symbol

    color_a::RGB

    color_b::RGB

    intensity::Float64

end


# ============================================================
# CHASE
# ============================================================

struct Chase

    name::Symbol

    group::Symbol

    colors::Vector{RGB}

    speed::Float64

    division::BeatDivision

end


# ============================================================
# SAFETY CONFIGURATION
# ============================================================

struct SafetyConfig

    maximum_intensity::Float64

    maximum_strobe::Float64

    laser_enabled::Bool

    haze_enabled::Bool

end


function SafetyConfig()

    SafetyConfig(

        1.0,

        1.0,

        false,

        true
    )

end


# ============================================================
# SHOW ENGINE
# ============================================================

mutable struct ShowEngine

    state::ShowState

    fixtures::Dict{Int,Fixture}

    groups::Dict{Symbol,FixtureGroup}

    cues::Vector{Cue}

    chases::Dict{Symbol,Chase}

    current_cue::Int

    cue_elapsed::Float64

    clock::BeatClock

    audio::AudioFrame

    safety::SafetyConfig

    master::Float64

    global_time::Float64

end


function ShowEngine(;
    bpm=128.0
)

    ShowEngine(

        OFF,

        Dict{Int,Fixture}(),

        Dict{Symbol,FixtureGroup}(),

        Cue[],

        Dict{Symbol,Chase}(),

        0,

        0.0,

        BeatClock(bpm),

        AudioFrame(),

        SafetyConfig(),

        1.0,

        0.0
    )

end


# ============================================================
# FIXTURE REGISTRATION
# ============================================================

function add_fixture!(
    engine::ShowEngine,
    fixture::Fixture
)

    engine.fixtures[fixture.id] = fixture

    if !haskey(engine.groups, fixture.group)

        engine.groups[fixture.group] =
            FixtureGroup(fixture.group)

    end

    push!(
        engine.groups[fixture.group].fixture_ids,
        fixture.id
    )

    fixture

end


# ============================================================
# GROUP ACCESS
# ============================================================

function group_fixtures(
    engine::ShowEngine,
    group::Symbol
)

    if !haskey(engine.groups, group)

        return Fixture[]

    end

    [
        engine.fixtures[id]
        for id in engine.groups[group].fixture_ids
        if haskey(engine.fixtures, id)
    ]

end


# ============================================================
# SET GROUP
# ============================================================

function set_group!(
    engine::ShowEngine,
    group::Symbol;
    color=nothing,
    intensity=nothing,
    pan=nothing,
    tilt=nothing,
    zoom=nothing,
    strobe=nothing
)

    for fixture in group_fixtures(engine, group)

        if color !== nothing
            fixture.state =
                LightingState(
                    color,
                    fixture.state.intensity,
                    fixture.state.pan,
                    fixture.state.tilt,
                    fixture.state.zoom,
                    fixture.state.strobe,
                    fixture.state.haze
                )
        end

        if intensity !== nothing

            fixture.state =
                LightingState(
                    fixture.state.color,
                    clamp(Float64(intensity),0,1),
                    fixture.state.pan,
                    fixture.state.tilt,
                    fixture.state.zoom,
                    fixture.state.strobe,
                    fixture.state.haze
                )

        end

        if pan !== nothing

            fixture.state =
                LightingState(
                    fixture.state.color,
                    fixture.state.intensity,
                    clamp(Float64(pan),0,1),
                    fixture.state.tilt,
                    fixture.state.zoom,
                    fixture.state.strobe,
                    fixture.state.haze
                )

        end

        if tilt !== nothing

            fixture.state =
                LightingState(
                    fixture.state.color,
                    fixture.state.intensity,
                    fixture.state.pan,
                    clamp(Float64(tilt),0,1),
                    fixture.state.zoom,
                    fixture.state.strobe,
                    fixture.state.haze
                )

        end

        if zoom !== nothing

            fixture.state =
                LightingState(
                    fixture.state.color,
                    fixture.state.intensity,
                    fixture.state.pan,
                    fixture.state.tilt,
                    clamp(Float64(zoom),0,1),
                    fixture.state.strobe,
                    fixture.state.haze
                )

        end

        if strobe !== nothing

            fixture.state =
                LightingState(
                    fixture.state.color,
                    fixture.state.intensity,
                    fixture.state.pan,
                    fixture.state.tilt,
                    fixture.state.zoom,
                    clamp(Float64(strobe),0,1),
                    fixture.state.haze
                )

        end

    end

end


# ============================================================
# BLACKOUT
# ============================================================

function blackout!(
    engine::ShowEngine
)

    engine.state = BLACKOUT

    for fixture in values(engine.fixtures)

        fixture.state =
            LightingState(
                BLACK,
                0.0,
                fixture.state.pan,
                fixture.state.tilt,
                fixture.state.zoom,
                0.0,
                0.0
            )

    end

end


# ============================================================
# ARM
# ============================================================

function arm!(
    engine::ShowEngine
)

    if engine.state == FAULT

        return false

    end

    engine.state = ARMED

    true

end


# ============================================================
# START
# ============================================================

function start_show!(
    engine::ShowEngine
)

    if engine.state != ARMED

        return false

    end

    engine.state = RUNNING

    engine.current_cue = 1

    engine.cue_elapsed = 0.0

    true

end


# ============================================================
# PAUSE
# ============================================================

function pause!(
    engine::ShowEngine
)

    if engine.state == RUNNING

        engine.state = PAUSED

    end

end


# ============================================================
# RESUME
# ============================================================

function resume!(
    engine::ShowEngine
)

    if engine.state == PAUSED

        engine.state = RUNNING

    end

end


# ============================================================
# CUE REGISTRATION
# ============================================================

function add_cue!(
    engine::ShowEngine,
    cue::Cue
)

    push!(engine.cues, cue)

end


# ============================================================
# CUE TRANSITION
# ============================================================

function next_cue!(
    engine::ShowEngine
)

    if isempty(engine.cues)

        return

    end

    engine.current_cue =
        min(
            engine.current_cue + 1,
            length(engine.cues)
        )

    engine.cue_elapsed = 0.0

end


# ============================================================
# PULSE
# ============================================================

function pulse_value(
    phase::Real
)

    0.5 +
    0.5 *
    sin(
        2π * Float64(phase)
    )

end


# ============================================================
# EFFECT ENGINE
# ============================================================

function apply_effect!(
    engine::ShowEngine,
    cue::Cue,
    dt::Real
)

    fixtures =
        group_fixtures(
            engine,
            cue.group
        )

    isempty(fixtures) && return


    phase =
        engine.clock.phase


    if cue.effect == STATIC

        for f in fixtures

            f.state =
                LightingState(
                    cue.color_a,
                    cue.intensity,
                    f.state.pan,
                    f.state.tilt,
                    f.state.zoom,
                    0.0,
                    0.0
                )

        end


    elseif cue.effect == PULSE

        value =
            pulse_value(
                phase
            )

        for f in fixtures

            f.state =
                LightingState(
                    cue.color_a,
                    cue.intensity * value,
                    f.state.pan,
                    f.state.tilt,
                    f.state.zoom,
                    0.0,
                    0.0
                )

        end


    elseif cue.effect == COLOR_WASH

        value =
            pulse_value(
                phase
            )

        color =
            lerp(
                cue.color_a,
                cue.color_b,
                value
            )

        for f in fixtures

            f.state =
                LightingState(
                    color,
                    cue.intensity,
                    f.state.pan,
                    f.state.tilt,
                    f.state.zoom,
                    0.0,
                    0.0
                )

        end


    elseif cue.effect == BEAT_REACTIVE

        amplitude =
            clamp(
                engine.audio.amplitude,
                0.0,
                1.0
            )

        for f in fixtures

            f.state =
                LightingState(
                    cue.color_a,
                    cue.intensity *
                    amplitude,
                    f.state.pan,
                    f.state.tilt,
                    f.state.zoom,
                    0.0,
                    0.0
                )

        end


    elseif cue.effect == BASS_REACTIVE

        bass =
            clamp(
                engine.audio.bass,
                0.0,
                1.0
            )

        for f in fixtures

            f.state =
                LightingState(
                    cue.color_a,
                    cue.intensity * bass,
                    f.state.pan,
                    f.state.tilt,
                    f.state.zoom,
                    0.0,
                    0.0
                )

        end


    elseif cue.effect == STROBE

        intensity =
            cue.intensity

        strobe =
            clamp(
                engine.audio.amplitude,
                0.0,
                engine.safety.maximum_strobe
            )

        for f in fixtures

            f.state =
                LightingState(
                    cue.color_a,
                    intensity,
                    f.state.pan,
                    f.state.tilt,
                    f.state.zoom,
                    strobe,
                    0.0
                )

        end


    elseif cue.effect == WAVE

        n = length(fixtures)

        for (i,f) in enumerate(fixtures)

            local_phase =
                phase +
                (i-1) / max(n,1)

            value =
                pulse_value(
                    local_phase
                )

            f.state =
                LightingState(
                    cue.color_a,
                    cue.intensity * value,
                    f.state.pan,
                    f.state.tilt,
                    f.state.zoom,
                    0.0,
                    0.0
                )

        end


    elseif cue.effect == RANDOMIZED

        for f in fixtures

            f.state =
                LightingState(
                    RGB(
                        rand(),
                        rand(),
                        rand()
                    ),
                    cue.intensity,
                    rand(),
                    rand(),
                    rand(),
                    0.0,
                    0.0
                )

        end

    end

end


# ============================================================
# AUDIO INPUT
# ============================================================

function set_audio!(
    engine::ShowEngine,
    frame::AudioFrame
)

    engine.audio = frame

    if frame.bpm > 0

        engine.clock.bpm =
            clamp(
                frame.bpm,
                40.0,
                240.0
            )

    end

end


# ============================================================
# MASTER CONTROL
# ============================================================

function set_master!(
    engine::ShowEngine,
    value::Real
)

    engine.master =
        clamp(
            Float64(value),
            0.0,
            1.0
        )

end


# ============================================================
# SAFETY LIMITER
# ============================================================

function apply_safety!(
    engine::ShowEngine
)

    for fixture in values(engine.fixtures)

        state = fixture.state

        intensity =
            min(
                state.intensity,
                engine.safety.maximum_intensity
            )

        strobe =
            min(
                state.strobe,
                engine.safety.maximum_strobe
            )

        if fixture.kind == LASER_FIXTURE &&
           !engine.safety.laser_enabled

            intensity = 0.0

        end

        fixture.state =
            LightingState(
                state.color,
                intensity * engine.master,
                state.pan,
                state.tilt,
                state.zoom,
                strobe,
                state.haze
            )

    end

end


# ============================================================
# ENGINE UPDATE
# ============================================================

function update!(
    engine::ShowEngine,
    dt::Real
)

    dt = max(Float64(dt), 0.0)

    engine.global_time += dt

    beat =
        update!(
            engine.clock,
            dt
        )

    if engine.state != RUNNING

        return beat

    end


    if isempty(engine.cues)

        return beat

    end


    cue =
        engine.cues[
            engine.current_cue
        ]


    engine.cue_elapsed += dt


    apply_effect!(
        engine,
        cue,
        dt
    )


    if engine.cue_elapsed >=
       cue.duration

        if engine.current_cue <
           length(engine.cues)

            next_cue!(engine)

        end

    end


    apply_safety!(
        engine
    )


    beat

end


# ============================================================
# OUTPUT FRAME
# ============================================================

function output_frame(
    engine::ShowEngine
)

    [
        command(f)
        for f in values(engine.fixtures)
        if f.enabled
    ]

end


# ============================================================
# SERIALIZABLE COMMAND REPRESENTATION
# ============================================================

function command_tuple(
    c::FixtureCommand
)

    (

        fixture_id = c.fixture_id,

        intensity = c.intensity,

        r = c.color.r,

        g = c.color.g,

        b = c.color.b,

        pan = c.pan,

        tilt = c.tilt,

        zoom = c.zoom,

        strobe = c.strobe,

        haze = c.haze

    )

end


# ============================================================
# DIAGNOSTICS
# ============================================================

function status(
    engine::ShowEngine
)

    println()
    println("==============================================")
    println(" RAVE.LIGHT.OS")
    println("==============================================")

    println(
        "VERSION       : ",
        VERSION
    )

    println(
        "STATE         : ",
        engine.state
    )

    println(
        "BPM           : ",
        round(engine.clock.bpm, digits=2)
    )

    println(
        "BEAT          : ",
        engine.clock.beat_number
    )

    println(
        "CUE           : ",
        engine.current_cue
    )

    println(
        "MASTER        : ",
        round(engine.master, digits=3)
    )

    println(
        "FIXTURES      : ",
        length(engine.fixtures)
    )

    println(
        "GLOBAL TIME   : ",
        round(engine.global_time, digits=2),
        " s"
    )

    println(
        "=============================================="
    )

end


# ============================================================
# SHOW BUILDER
# ============================================================

function demo_show()

    engine =
        ShowEngine(
            bpm=132.0
        )


    # --------------------------------------------------------
    # FIXTURES
    # --------------------------------------------------------

    for i in 1:8

        add_fixture!(
            engine,
            Fixture(
                i,
                "LED-BAR-$i",
                LED_BAR,
                :backwall,
                i
            )
        )

    end


    for i in 9:12

        add_fixture!(
            engine,
            Fixture(
                i,
                "MOVING-HEAD-$i",
                MOVING_HEAD,
                :heads,
                i
            )
        )

    end


    for i in 13:16

        add_fixture!(
            engine,
            Fixture(
                i,
                "PIXEL-$i",
                PIXEL_PANEL,
                :pixels,
                i
            )
        )

    end


    add_fixture!(
        engine,
        Fixture(
            17,
            "STROBE-1",
            STROBE_FIXTURE,
            :strobes,
            17
        )
    )


    # --------------------------------------------------------
    # CUES
    # --------------------------------------------------------

    add_cue!(
        engine,
        Cue(
            :intro,
            8.0,
            STATIC,
            :backwall,
            BLUE,
            BLUE,
            0.35
        )
    )


    add_cue!(
        engine,
        Cue(
            :build,
            12.0,
            PULSE,
            :backwall,
            BLUE,
            WHITE,
            0.75
        )
    )


    add_cue!(
        engine,
        Cue(
            :drop,
            16.0,
            BASS_REACTIVE,
            :backwall,
            RED,
            RED,
            1.0
        )
    )


    add_cue!(
        engine,
        Cue(
            :wave,
            16.0,
            WAVE,
            :pixels,
            BLUE,
            WHITE,
            0.9
        )
    )


    add_cue!(
        engine,
        Cue(
            :heads,
            16.0,
            COLOR_WASH,
            :heads,
            RED,
            BLUE,
            0.8
        )
    )


    add_cue!(
        engine,
        Cue(
            :finale,
            8.0,
            BEAT_REACTIVE,
            :backwall,
            WHITE,
            WHITE,
            1.0
        )
    )


    engine

end


# ============================================================
# SIMULATED AUDIO ENGINE
# ============================================================

function simulated_audio(
    engine::ShowEngine
)

    t =
        engine.global_time

    bass =
        0.5 +
        0.5 *
        sin(
            2π *
            2.0 *
            t
        )

    mid =
        0.5 +
        0.5 *
        sin(
            2π *
            3.5 *
            t
        )

    treble =
        0.5 +
        0.5 *
        sin(
            2π *
            7.0 *
            t
        )

    amplitude =
        clamp(
            0.55*bass +
            0.30*mid +
            0.15*treble,
            0.0,
            1.0
        )

    AudioFrame(
        t,
        amplitude,
        bass,
        mid,
        treble,
        engine.clock.bpm,
        false
    )

end


# ============================================================
# SIMULATION
# ============================================================

function simulate!(
    engine::ShowEngine;
    seconds=30.0,
    timestep=0.02
)

    arm!(engine)

    start_show!(engine)


    steps =
        Int(
            ceil(
                seconds /
                timestep
            )
        )


    for _ in 1:steps

        audio =
            simulated_audio(
                engine
            )

        set_audio!(
            engine,
            audio
        )

        update!(
            engine,
            timestep
        )

        sleep(
            timestep
        )

    end

end


# ============================================================
# CONSOLE RENDERER
# ============================================================

function render_console(
    engine::ShowEngine
)

    frame =
        output_frame(
            engine
        )

    println()
    println(
        "FRAME ",
        round(
            engine.global_time,
            digits=2
        ),
        "s"
    )

    for c in frame

        println(
            "FIXTURE ",
            lpad(
                string(c.fixture_id),
                2
            ),
            " | INT ",
            round(c.intensity,digits=2),
            " | RGB ",
            (
                round(c.color.r,digits=2),
                round(c.color.g,digits=2),
                round(c.color.b,digits=2)
            ),
            " | PAN ",
            round(c.pan,digits=2),
            " | TILT ",
            round(c.tilt,digits=2)
        )

    end

end


# ============================================================
# EMERGENCY BLACKOUT
# ============================================================

function emergency_blackout!(
    engine::ShowEngine
)

    blackout!(engine)

    engine.master = 0.0

end


# ============================================================
# RECOVERY
# ============================================================

function recover!(
    engine::ShowEngine
)

    if engine.state == BLACKOUT

        engine.master = 1.0

        engine.state = ARMED

    end

end


# ============================================================
# TEST SUITE
# ============================================================

function self_test()

    engine =
        ShowEngine()


    # Fixture registration

    add_fixture!(
        engine,
        Fixture(
            1,
            "TEST",
            LED_BAR,
            :test,
            1
        )
    )


    @assert length(
        engine.fixtures
    ) == 1


    # Group creation

    @assert haskey(
        engine.groups,
        :test
    )


    # Safety

    engine.safety =
        SafetyConfig(
            0.5,
            0.25,
            false,
            true
        )


    set_group!(
        engine,
        :test,
        color=RED,
        intensity=1.0
    )


    apply_safety!(
        engine
    )


    fixture =
        engine.fixtures[1]


    @assert fixture.state.intensity <= 0.5


    # Blackout

    blackout!(
        engine
    )


    @assert fixture.state.intensity == 0.0


    println(
        "RAVE.LIGHT.OS SELF TEST: PASS"
    )

    true

end


# ============================================================
# PUBLIC API
# ============================================================

export

    ShowEngine,

    Fixture,

    FixtureGroup,

    FixtureCommand,

    Cue,

    Chase,

    RGB,

    AudioFrame,

    SafetyConfig,

    ShowState,

    EffectMode,

    FixtureKind,

    BeatDivision,

    add_fixture!,

    add_cue!,

    set_group!,

    set_audio!,

    set_master!,

    arm!,

    start_show!,

    pause!,

    resume!,

    update!,

    blackout!,

    emergency_blackout!,

    recover!,

    output_frame,

    command_tuple,

    status,

    render_console,

    simulate!,

    demo_show,

    self_test

end # module


# ============================================================
# EXAMPLE APPLICATION
# ============================================================

using .RaveLightOS


engine =
    RaveLightOS.demo_show()


RaveLightOS.self_test()


RaveLightOS.status(
    engine
)


# Start the simulated show.

RaveLightOS.arm!(
    engine
)

RaveLightOS.start_show!(
    engine


# Example realtime control loop.

for frame in 1:500

    audio =
        RaveLightOS.simulated_audio(
            engine
        )

    RaveLightOS.set_audio!(
        engine,
        audio
    )

    RaveLightOS.update!(
        engine,
        0.02
    )

    if frame % 50 == 0

        RaveLightOS.render_console(
            engine
        )

    end

end


# Emergency blackout example.

# RaveLightOS.emergency_blackout!(engine)
```

### System architecture

```text
                         RAVE.LIGHT.OS
                              │
             ┌────────────────┼────────────────┐
             │                │                │
             ▼                ▼                ▼
        AUDIO ENGINE       SHOW ENGINE      USER CONTROL
             │                │                │
       ┌─────┼─────┐          │          ┌─────┼─────┐
       │     │     │          │          │     │     │
      BASS  MID  TREBLE       │        CUES  MASTER BLACKOUT
       │     │     │          │          │
       └─────┴─────┘          │          │
             │                │          │
             ▼                ▼          ▼
          BEAT CLOCK ─────► EFFECT ENGINE
                              │
              ┌───────────────┼────────────────┐
              │               │                │
              ▼               ▼                ▼
           PULSE            WAVE          COLOR WASH
              │               │                │
              └───────────────┼────────────────┘
                              │
                              ▼
                        SAFETY LIMITER
                              │
                              ▼
                       OUTPUT FRAME
                              │
              ┌───────────────┼────────────────┐
              ▼               ▼                ▼
            DMX            ART-NET           sACN
              │               │                │
              └───────────────┼────────────────┘
                              ▼
                       LIGHTING HARDWARE
```
