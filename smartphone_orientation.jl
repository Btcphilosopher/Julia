.

smartphone_orientation/
├── Project.toml
├── src/
│   ├── SmartphoneOrientation.jl
│   ├── sensors.jl
│   ├── orientation.jl
│   ├── filtering.jl
│   ├── transition.jl
│   ├── animation.jl
│   ├── rendering.jl
│   ├── layout.jl
│   ├── power.jl
│   ├── optimisation.jl
│   └── simulation.jl
│
├── data/
│   ├── sensor_samples.csv
│   ├── device_profiles.csv
│   └── transition_profiles.csv
│
├── test/
│   └── runtests.jl
│
└── examples/
    └── orientation_simulation.jl
Project.toml
name = "SmartphoneOrientation"
uuid = "f71b5e4e-2b31-4b4d-a0b5-81d2d7a7a001"
authors = ["Orientation Optimisation Research"]
version = "0.1.0"

[deps]
CSV = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3a2e7e"
Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
Statistics = "10745b16-90b1-5c2f-98f3-4d4d9c1a9b2a"
JuMP = "4076af6c-e467-56ae-b986-b466b2749572"
HiGHS = "87dc4568-4c63-4a98-9c4c-9f4f1a4a9f0c"

[compat]
julia = "1.10"
src/SmartphoneOrientation.jl
module SmartphoneOrientation

using CSV
using DataFrames
using Dates
using Statistics
using JuMP
using HiGHS

include("sensors.jl")
include("orientation.jl")
include("filtering.jl")
include("transition.jl")
include("animation.jl")
include("rendering.jl")
include("layout.jl")
include("power.jl")
include("optimisation.jl")
include("simulation.jl")

export SensorSample,
       OrientationState,
       TransitionProfile,
       detect_orientation,
       filter_orientation,
       transition_duration,
       animation_progress,
       optimise_transition,
       simulate_rotation

end
src/sensors.jl
struct SensorSample

    timestamp::Float64

    ax::Float64
    ay::Float64
    az::Float64

    gx::Float64
    gy::Float64
    gz::Float64

end


struct OrientationState

    pitch::Float64
    roll::Float64
    yaw::Float64

    confidence::Float64

end
src/orientation.jl

Use the accelerometer to estimate the device's gravity vector and distinguish portrait/landscape states.

function detect_orientation(
    sample::SensorSample
)

    ax = sample.ax
    ay = sample.ay

    if abs(ax) > abs(ay)

        if ax > 0
            return :landscape_right
        else
            return :landscape_left
        end

    else

        if ay > 0
            return :portrait
        else
            return :portrait_upside_down
        end

    end

end


function orientation_angle(
    sample::SensorSample
)

    return atan(
        sample.ax,
        sample.ay
    )

end
src/filtering.jl

This prevents the phone from rapidly switching portrait → landscape → portrait because of sensor noise.

function moving_average(
    values::Vector{Float64},
    window::Int
)

    result =
        similar(values)

    for i in eachindex(values)

        first =
            max(
                1,
                i - window + 1
            )

        result[i] =
            mean(
                values[first:i]
            )

    end

    return result

end


function filter_orientation(
    angles::Vector{Float64};
    window::Int = 5
)

    return moving_average(
        angles,
        window
    )

end
src/transition.jl
struct TransitionProfile

    minimum_angle::Float64
    trigger_angle::Float64

    minimum_duration_ms::Float64
    maximum_duration_ms::Float64

    settling_time_ms::Float64

end


function transition_duration(
    angle_degrees::Float64,
    profile::TransitionProfile
)

    fraction =
        clamp(
            abs(angle_degrees) /
            90.0,
            0.0,
            1.0
        )

    return profile.minimum_duration_ms +
           fraction *
           (
               profile.maximum_duration_ms -
               profile.minimum_duration_ms
           )

end
src/animation.jl

Here we model the visual rotation.

function ease_in_out(
    x::Float64
)

    x = clamp(x, 0.0, 1.0)

    return (
        x < 0.5
        ?
        2x^2
        :
        1 - (-2x + 2)^2 / 2
    )

end


function animation_progress(
    elapsed_ms::Float64,
    duration_ms::Float64
)

    raw =
        elapsed_ms /
        duration_ms

    return ease_in_out(
        raw
    )

end


function rotation_angle(
    progress::Float64,
    start_angle::Float64,
    end_angle::Float64
)

    return start_angle +
           progress *
           (
               end_angle -
               start_angle
           )

end
src/rendering.jl

The model can account for the expensive portion of the transition.

struct RenderingProfile

    refresh_rate_hz::Float64

    render_time_ms::Float64

    layout_time_ms::Float64

    gpu_power_w::Float64

end


function frame_budget_ms(
    profile::RenderingProfile
)

    return 1000.0 /
           profile.refresh_rate_hz

end


function dropped_frame_probability(
    profile::RenderingProfile
)

    budget =
        frame_budget_ms(profile)

    excess =
        max(
            0.0,
            profile.render_time_ms -
            budget
        )

    return clamp(
        excess / budget,
        0.0,
        1.0
    )

end
src/layout.jl

This models the actual UI restructuring.

struct LayoutProfile

    portrait_width::Int
    portrait_height::Int

    landscape_width::Int
    landscape_height::Int

    layout_recalculation_ms::Float64

end


function target_dimensions(
    profile::LayoutProfile,
    orientation::Symbol
)

    if orientation == :portrait

        return (
            profile.portrait_width,
            profile.portrait_height
        )

    elseif orientation == :landscape

        return (
            profile.landscape_width,
            profile.landscape_height
        )

    else

        error(
            "Unsupported orientation"
        )

    end

end
src/power.jl
function transition_energy_mwh(
    rendering::RenderingProfile,
    duration_ms::Float64
)

    hours =
        duration_ms /
        3_600_000.0

    return (
        rendering.gpu_power_w *
        hours
    ) / 1000.0

end
src/optimisation.jl

This is where Julia can find a transition configuration that balances:

responsiveness
animation smoothness
sensor stability
rendering workload
battery consumption
frame drops
orientation detection delay
function optimise_transition(
    profile::TransitionProfile,
    rendering::RenderingProfile
)

    durations =
        range(
            profile.minimum_duration_ms,
            profile.maximum_duration_ms,
            length = 100
        )

    best_duration =
        profile.maximum_duration_ms

    best_score =
        Inf

    for duration in durations

        dropped =
            dropped_frame_probability(
                rendering
            )

        energy =
            transition_energy_mwh(
                rendering,
                duration
            )

        latency =
            duration +
            profile.settling_time_ms

        # Weighted engineering objective.
        #
        # These weights are deliberately
        # configurable rather than claiming
        # a universal "best" UX.

        score =
            0.50 * latency +
            0.30 * dropped * 100.0 +
            0.20 * energy

        if score < best_score

            best_score =
                score

            best_duration =
                duration

        end

    end

    return (
        duration_ms = best_duration,
        score = best_score
    )

end
src/simulation.jl
function simulate_rotation(
    profile::TransitionProfile,
    rendering::RenderingProfile;
    start_angle::Float64 = 0.0,
    end_angle::Float64 = 90.0
)

    duration =
        transition_duration(
            abs(
                end_angle -
                start_angle
            ),
            profile
        )

    timestep = 1000.0 /
               rendering.refresh_rate_hz

    times =
        collect(
            0.0:timestep:duration
        )

    angles = Float64[]

    for t in times

        progress =
            animation_progress(
                t,
                duration
            )

        angle =
            rotation_angle(
                progress,
                start_angle,
                end_angle
            )

        push!(
            angles,
            angle
        )

    end

    return DataFrame(
        time_ms = times,
        angle_deg = angles
    )

end
examples/orientation_simulation.jl
using Pkg

Pkg.activate(
    joinpath(
        @__DIR__,
        ".."
    )
)

using SmartphoneOrientation

profile =
    TransitionProfile(
        15.0,
        45.0,
        120.0,
        350.0,
        50.0
    )

rendering =
    RenderingProfile(
        120.0,
        5.0,
        3.0,
        2.5
    )

println()
println("==============================")
println(" SMARTPHONE ORIENTATION ENGINE")
println("==============================")
println()

result =
    optimise_transition(
        profile,
        rendering
    )

println(
    "Optimised transition: ",
    round(
        result.duration_ms,
        digits=2
    ),
    " ms"
)

println(
    "Objective score: ",
    round(
        result.score,
        digits=3
    )
)

simulation =
    simulate_rotation(
        profile,
        rendering
    )

println(
    "Frames simulated: ",
    nrow(simulation)
)

println(
    "Final angle: ",
    simulation.angle_deg[end],
    "°"
)
test/runtests.jl
using Test

using Pkg

Pkg.activate(
    joinpath(
        @__DIR__,
        ".."
    )
)

using SmartphoneOrientation

@testset "Orientation" begin

    sample =
        SensorSample(
            0.0,
            0.1,
            0.9,
            0.0,
            0.0,
            0.0,
            0.0
        )

    @test detect_orientation(sample) ==
          :portrait

end


@testset "Animation" begin

    @test animation_progress(
        0.0,
        300.0
    ) == 0.0

    @test animation_progress(
        300.0,
        300.0
    ) == 1.0

end


@testset "Optimisation" begin

    profile =
        TransitionProfile(
            15.0,
            45.0,
            100.0,
            300.0,
            50.0
        )

    rendering =
        RenderingProfile(
            120.0,
            5.0,
            3.0,
            2.0
        )

    result =
        optimise_transition(
            profile,
            rendering
        )

    @test result.duration_ms >=
          profile.minimum_duration_ms

    @test result.duration_ms <=
          profile.maximum_duration_ms

end

println(
    "All orientation tests passed."
)
