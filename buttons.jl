# Julia Button Response Speed Optimiser

A modular Julia system for reducing software button latency.

```text
button_optimizer/
├── Project.toml
├── src/
│   ├── ButtonOptimizer.jl
│   ├── button.jl
│   ├── input.jl
│   ├── debounce.jl
│   ├── event_queue.jl
│   ├── rendering.jl
│   ├── animation.jl
│   ├── latency.jl
│   ├── simulation.jl
│   └── optimisation.jl
├── examples/
│   └── optimise_button.jl
└── test/
    └── runtests.jl
```

## `Project.toml`

```toml
name = "ButtonOptimizer"
uuid = "4d7a9e21-8f42-4c1a-b123-123456789abc"
authors = ["UI Performance Research"]
version = "0.1.0"

[deps]
Random = "9a3f8284-686f-5f34-9a9f-3a7b1d6c8b6f"
Statistics = "10745b16-90c0-5a5c-9e9b-0d4d5b3a8c6e"
```

# Main module

## `src/ButtonOptimizer.jl`

```julia
module ButtonOptimizer

using Random
using Statistics

include("button.jl")
include("input.jl")
include("debounce.jl")
include("event_queue.jl")
include("rendering.jl")
include("animation.jl")
include("latency.jl")
include("simulation.jl")
include("optimisation.jl")

export ButtonConfig
export InputEvent
export ButtonResult

export default_button
export simulate
export optimise_button
export response_latency

end
```

# Button configuration

## `src/button.jl`

```julia
struct ButtonConfig

    debounce_ms::Float64

    event_processing_ms::Float64

    render_latency_ms::Float64

    animation_duration_ms::Float64

    frame_rate::Float64

    event_batching_ms::Float64

    animation_enabled::Bool
end

function default_button()

    return ButtonConfig(
        25.0,
        2.0,
        8.0,
        120.0,
        60.0,
        8.0,
        true
    )
end
```

The important variables are:

```text
debounce
   ↓
input event
   ↓
event processing
   ↓
state update
   ↓
render
   ↓
animation
```

# Input events

## `src/input.jl`

```julia
struct InputEvent

    timestamp_ms::Float64

    button_id::Int

    event_type::Symbol
end

function create_press(
    timestamp_ms::Float64,
    button_id::Int=1
)

    return InputEvent(
        timestamp_ms,
        button_id,
        :press
    )
end
```

# Debouncing

## `src/debounce.jl`

Debouncing prevents one physical press from generating several logical presses.

```julia
function debounce_events(
    events::Vector{InputEvent},
    debounce_ms::Float64
)

    isempty(events) && return events

    output =
        InputEvent[]

    last_event =
        -Inf

    for event in events

        if event.timestamp_ms -
           last_event >= debounce_ms

            push!(
                output,
                event
            )

            last_event =
                event.timestamp_ms
        end
    end

    return output
end
```

# Event queue

## `src/event_queue.jl`

```julia
function process_event(
    event::InputEvent,
    config::ButtonConfig
)

    return event.timestamp_ms +
           config.debounce_ms +
           config.event_processing_ms
end
```

A high-performance UI should avoid unnecessarily waiting for another event batch before changing button state.

# Rendering

## `src/rendering.jl`

```julia
function next_frame_time(
    timestamp_ms::Float64,
    frame_rate::Float64
)

    frame =
        1000.0 /
        frame_rate

    return ceil(
        timestamp_ms / frame
    ) * frame
end

function rendering_latency(
    timestamp_ms::Float64,
    config::ButtonConfig
)

    frame_time =
        next_frame_time(
            timestamp_ms,
            config.frame_rate
        )

    return frame_time -
           timestamp_ms +
           config.render_latency_ms
end
```

# Animation

## `src/animation.jl`

```julia
function animation_latency(
    config::ButtonConfig
)

    if !config.animation_enabled
        return 0.0
    end

    # Visual response begins immediately;
    # duration is therefore not automatically
    # added to input latency.

    return 0.0
end

function animation_progress(
    elapsed_ms::Float64,
    duration_ms::Float64
)

    if duration_ms <= 0
        return 1.0
    end

    return clamp(
        elapsed_ms /
        duration_ms,
        0.0,
        1.0
    )
end
```

This distinction is important: a 120 ms press animation does **not** necessarily mean the UI has 120 ms of input latency. The button can visually respond on the first rendered frame.

# Latency calculation

## `src/latency.jl`

```julia
function response_latency(
    config::ButtonConfig;
    input_timestamp_ms::Float64=0.0
)

    processed =
        process_event(
            create_press(
                input_timestamp_ms
            ),
            config
        )

    render_delay =
        rendering_latency(
            processed,
            config
        )

    return (
        processed -
        input_timestamp_ms +
        render_delay
    )
end
```

# Simulation

## `src/simulation.jl`

```julia
struct ButtonResult

    latency_ms::Float64

    debounce_ms::Float64

    processing_ms::Float64

    rendering_ms::Float64

    animation_ms::Float64

    perceived_response_ms::Float64
end

function simulate(
    config::ButtonConfig;
    presses::Int=1000,
    jitter_ms::Float64=2.0,
    seed::Int=42
)

    rng =
        MersenneTwister(seed)

    latencies =
        Float64[]

    for _ in 1:presses

        jitter =
            randn(rng) *
            jitter_ms

        base =
            response_latency(config)

        push!(
            latencies,
            max(
                0.0,
                base + jitter
            )
        )
    end

    return ButtonResult(
        mean(latencies),
        config.debounce_ms,
        config.event_processing_ms,
        config.render_latency_ms,
        config.animation_duration_ms,
        percentile(latencies, 50)
    )
end
```

# Optimisation

## `src/optimisation.jl`

The optimiser searches for a configuration that reduces response latency while retaining a sensible debounce period.

```julia
function optimise_button(
    ;
    debounce_range=5.0:5.0:40.0,
    processing_range=0.5:0.5:5.0,
    render_range=1.0:1.0:12.0,
    frame_rates=[60.0, 90.0, 120.0]
)

    best_score = Inf
    best_config = nothing
    best_result = nothing

    for debounce in debounce_range

        for processing in processing_range

            for render in render_range

                for fps in frame_rates

                    config =
                        ButtonConfig(
                            debounce,
                            processing,
                            render,
                            80.0,
                            fps,
                            0.0,
                            true
                        )

                    result =
                        simulate(
                            config
                        )

                    # Penalise excessively aggressive
                    # debounce settings.

                    safety_penalty =
                        debounce < 10.0 ?
                        5.0 :
                        0.0

                    score =
                        result.latency_ms +
                        safety_penalty

                    if score < best_score

                        best_score =
                            score

                        best_config =
                            config

                        best_result =
                            result
                    end
                end
            end
        end
    end

    return (
        config = best_config,
        result = best_result,
        score = best_score
    )
end
```

# Example

## `examples/optimise_button.jl`

```julia
include(
    joinpath(
        @__DIR__,
        "..",
        "src",
        "ButtonOptimizer.jl"
    )
)

using .ButtonOptimizer

default =
    default_button()

baseline =
    simulate(default)

println("================================")
println("JULIA BUTTON SPEED OPTIMISER")
println("================================")

println(
    "Baseline response: ",
    round(
        baseline.latency_ms,
        digits=2
    ),
    " ms"
)

optimised =
    optimise_button()

println()
println("OPTIMISED")

println(
    "Debounce: ",
    optimised.config.debounce_ms,
    " ms"
)

println(
    "Processing: ",
    optimised.config.event_processing_ms,
    " ms"
)

println(
    "Frame rate: ",
    optimised.config.frame_rate,
    " Hz"
)

println(
    "Response: ",
    round(
        optimised.result.latency_ms,
        digits=2
    ),
    " ms"
)
```

# Tests

## `test/runtests.jl`

```julia
using Test

include(
    joinpath(
        @__DIR__,
        "..",
        "src",
        "ButtonOptimizer.jl"
    )
)

using .ButtonOptimizer

@testset "Button Optimiser" begin

    config =
        default_button()

    @test config.debounce_ms > 0
    @test config.frame_rate >= 30

    latency =
        response_latency(config)

    @test latency >= 0

    result =
        simulate(
            config;
            presses=100
        )

    @test result.latency_ms >= 0
    @test isfinite(result.latency_ms)

    optimised =
        optimise_button()

    @test optimised.score < Inf
end
```

# High-speed architecture

For a genuinely fast interface, the pipeline should look like this:

```text
              USER PRESS
                  │
                  ▼
        ┌──────────────────┐
        │ HARDWARE INPUT   │
        └────────┬─────────┘
                 │
                 ▼
        ┌──────────────────┐
        │ EVENT DETECTION  │
        │     ~0–few ms    │
        └────────┬─────────┘
                 │
                 ▼
        ┌──────────────────┐
        │ MINIMAL DEBOUNCE │
        └────────┬─────────┘
                 │
                 ▼
        ┌──────────────────┐
        │ STATE UPDATE     │
        │ immediately      │
        └────────┬─────────┘
                 │
                 ▼
        ┌──────────────────┐
        │ NEXT FRAME       │
        │ 60/90/120 Hz     │
        └────────┬─────────┘
                 │
                 ▼
        ┌──────────────────┐
        │ VISUAL FEEDBACK  │
        └──────────────────┘
```

The optimisation target is therefore **not simply "make the animation faster."**

It is:

```text
INPUT
  ↓
minimum necessary debounce
  ↓
immediate state mutation
  ↓
minimum event-queue delay
  ↓
next available render frame
  ↓
immediate visual acknowledgement
```

For a production UI, I'd also separate **activation latency** from **animation completion time**. A button can acknowledge a press almost immediately while still using a polished 80–150 ms visual transition.

A further version could connect this Julia model to **real UI telemetry**, measuring thousands of presses and optimising the actual application's event-to-pixel latency rather than relying on simulated timings.

