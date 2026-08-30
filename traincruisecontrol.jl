module TrainCruiseControl

using Printf
using Statistics

export TrainConfig,
       SpeedSection,
       TrainState,
       ControlCommand,
       CruiseController,
       create_controller,
       update!,
       generate_speed_profile,
       braking_distance,
       permitted_speed,
       run_simulation,
       print_report


# ============================================================
# TRAIN CRUISE CONTROL / ATO SIMULATOR
#
# Pure Julia — no external packages.
#
# Intended as a simulation / control-development framework.
#
# Architecture:
#
#   Route data
#        ↓
#   Speed-profile generator
#        ↓
#   Target speed
#        ↓
#   Cruise controller
#        ↓
#   Traction / coast / brake command
#        ↓
#   Train dynamics
#        ↓
#   Position + speed feedback
#        └───────────────┐
#                        ↓
#                  Controller
#
# Multiple operating speeds are supported:
#
#   40 / 60 / 80 / 100 / 110 / 125 / 140 / 160 / 200 km/h
#
# IMPORTANT:
# This is a simulation/control algorithm, not a railway
# safety-certified ATP/ATO implementation. Real trains require
# independent safety protection and validated braking models.
#
# ============================================================


# ============================================================
# SPEED CONVERSION
# ============================================================

kmh_to_ms(v) = Float64(v) / 3.6
ms_to_kmh(v) = Float64(v) * 3.6


# ============================================================
# TRAIN CONFIGURATION
# ============================================================

struct TrainConfig

    mass_tonnes::Float64

    max_speed_kmh::Float64

    max_acceleration_ms2::Float64
    service_brake_ms2::Float64
    emergency_brake_ms2::Float64

    traction_power_kw::Float64
    regenerative_power_kw::Float64

    rolling_resistance::Float64
    aerodynamic_drag::Float64

    controller_gain::Float64
    braking_margin_m::Float64

    timestep_s::Float64
end


function TrainConfig(;
    mass_tonnes=450.0,
    max_speed_kmh=200.0,
    max_acceleration_ms2=0.7,
    service_brake_ms2=0.8,
    emergency_brake_ms2=1.2,
    traction_power_kw=6000.0,
    regenerative_power_kw=4000.0,
    rolling_resistance=0.0015,
    aerodynamic_drag=0.0003,
    controller_gain=0.12,
    braking_margin_m=100.0,
    timestep_s=0.1
)

    TrainConfig(
        Float64(mass_tonnes),
        Float64(max_speed_kmh),
        Float64(max_acceleration_ms2),
        Float64(service_brake_ms2),
        Float64(emergency_brake_ms2),
        Float64(traction_power_kw),
        Float64(regenerative_power_kw),
        Float64(rolling_resistance),
        Float64(aerodynamic_drag),
        Float64(controller_gain),
        Float64(braking_margin_m),
        Float64(timestep_s)
    )
end


# ============================================================
# SPEED SECTION
# ============================================================

"""
A section of railway with a maximum permitted speed.

start_m and end_m are measured from the route origin.
"""
struct SpeedSection

    start_m::Float64
    end_m::Float64

    speed_limit_kmh::Float64
end


# ============================================================
# TRAIN STATE
# ============================================================

mutable struct TrainState

    time_s::Float64

    position_m::Float64
    speed_ms::Float64

    acceleration_ms2::Float64

    target_speed_ms::Float64

    traction::Float64
    brake::Float64

    energy_kwh::Float64
    regenerative_energy_kwh::Float64

    stopped::Bool
end


# ============================================================
# CONTROL COMMAND
# ============================================================

struct ControlCommand

    traction::Float64
    brake::Float64

    mode::Symbol

    target_speed_ms::Float64
end


# ============================================================
# CONTROLLER
# ============================================================

mutable struct CruiseController

    config::TrainConfig

    route::Vector{SpeedSection}

    target_speed_kmh::Float64

    enabled::Bool

    speed_hold_band_kmh::Float64

    coasting_band_kmh::Float64

    emergency_limit_kmh::Float64

    previous_error::Float64
end


function create_controller(
    config::TrainConfig,
    route::Vector{SpeedSection};
    target_speed_kmh=120.0,
    speed_hold_band_kmh=1.0,
    coasting_band_kmh=3.0,
    emergency_limit_kmh=5.0
)

    CruiseController(
        config,
        route,
        Float64(target_speed_kmh),
        true,
        Float64(speed_hold_band_kmh),
        Float64(coasting_band_kmh),
        Float64(emergency_limit_kmh),
        0.0
    )
end


# ============================================================
# SPEED LIMIT LOOKUP
# ============================================================

function permitted_speed(
    controller::CruiseController,
    position_m::Float64
)

    for section in controller.route

        if position_m >= section.start_m &&
           position_m < section.end_m

            return min(
                section.speed_limit_kmh,
                controller.config.max_speed_kmh
            )
        end
    end

    return 0.0
end


# ============================================================
# NEXT SPEED RESTRICTION
# ============================================================

function next_restriction(
    controller::CruiseController,
    position_m::Float64
)

    current =
        permitted_speed(
            controller,
            position_m
        )

    best_distance = Inf
    best_speed = current

    for section in controller.route

        if section.start_m > position_m &&
           section.speed_limit_kmh < current

            distance =
                section.start_m -
                position_m

            if distance < best_distance

                best_distance = distance
                best_speed =
                    section.speed_limit_kmh
            end
        end
    end

    return best_distance, best_speed
end


# ============================================================
# BRAKING DISTANCE
# ============================================================

"""
Distance required to reduce speed from v_initial to
v_target using constant service braking.

d = (v² - u²) / (2a)
"""
function braking_distance(
    v_initial_ms::Real,
    v_target_ms::Real,
    deceleration_ms2::Real
)

    vi = max(Float64(v_initial_ms), 0.0)
    vt = max(Float64(v_target_ms), 0.0)
    a = max(Float64(deceleration_ms2), 1e-6)

    if vi <= vt
        return 0.0
    end

    return (
        vi^2 - vt^2
    ) / (
        2a
    )
end


# ============================================================
# TARGET SPEED
# ============================================================

function generate_target_speed(
    controller::CruiseController,
    state::TrainState
)

    permitted =
        permitted_speed(
            controller,
            state.position_m
        )

    # Driver-selected target cannot exceed
    # the permitted route speed.
    desired =
        min(
            controller.target_speed_kmh,
            permitted,
            controller.config.max_speed_kmh
        )

    distance_to_limit,
    next_limit =
        next_restriction(
            controller,
            state.position_m
        )

    if isfinite(distance_to_limit)

        target_ms =
            kmh_to_ms(next_limit)

        braking_distance_required =
            braking_distance(
                state.speed_ms,
                target_ms,
                controller.config.service_brake_ms2
            ) +
            controller.config.braking_margin_m

        # Begin reducing the target speed early enough
        # to make the restriction.
        if distance_to_limit <=
           braking_distance_required

            desired =
                min(
                    desired,
                    next_limit
                )
        end
    end

    return kmh_to_ms(desired)
end


# ============================================================
# CRUISE CONTROL
# ============================================================

function update!(
    controller::CruiseController,
    state::TrainState
)

    if !controller.enabled

        return ControlCommand(
            0.0,
            0.0,
            :MANUAL,
            state.speed_ms
        )
    end

    target =
        generate_target_speed(
            controller,
            state
        )

    actual =
        state.speed_ms

    error =
        target - actual

    controller.previous_error =
        error

    target_kmh =
        ms_to_kmh(target)

    actual_kmh =
        ms_to_kmh(actual)

    # --------------------------------------------------------
    # OVERSPEED PROTECTION
    # --------------------------------------------------------

    permitted =
        permitted_speed(
            controller,
            state.position_m
        )

    overspeed =
        actual_kmh -
        permitted

    if overspeed >
       controller.emergency_limit_kmh

        return ControlCommand(
            0.0,
            1.0,
            :EMERGENCY_BRAKE,
            target
        )
    end

    # --------------------------------------------------------
    # SERVICE BRAKING
    # --------------------------------------------------------

    if actual_kmh >
       target_kmh +
       controller.coasting_band_kmh

        brake_strength =
            clamp(
                abs(error) /
                20.0,
                0.0,
                1.0
            )

        return ControlCommand(
            0.0,
            brake_strength,
            :BRAKING,
            target
        )
    end

    # --------------------------------------------------------
    # COAST
    # --------------------------------------------------------

    if actual_kmh >
       target_kmh +
       controller.speed_hold_band_kmh

        return ControlCommand(
            0.0,
            0.0,
            :COASTING,
            target
        )
    end

    # --------------------------------------------------------
    # ACCELERATION
    # --------------------------------------------------------

    if actual_kmh <
       target_kmh -
       controller.speed_hold_band_kmh

        traction =
            clamp(
                controller.config.controller_gain *
                error,
                0.0,
                1.0
            )

        return ControlCommand(
            traction,
            0.0,
            :TRACTION,
            target
        )
    end

    # --------------------------------------------------------
    # SPEED HOLD
    # --------------------------------------------------------

    return ControlCommand(
        0.0,
        0.0,
        :CRUISE,
        target
    )
end


# ============================================================
# TRAIN RESISTANCE
# ============================================================

function resistance_acceleration(
    config::TrainConfig,
    speed_ms::Float64
)

    # Simplified Davis-like resistance model.
    #
    # This is deliberately a simulation model, not a
    # vehicle-specific validated resistance equation.

    resistance =
        config.rolling_resistance +
        config.aerodynamic_drag *
        speed_ms^2

    return resistance
end


# ============================================================
# TRAIN DYNAMICS
# ============================================================

function apply_command!(
    state::TrainState,
    config::TrainConfig,
    command::ControlCommand;
    gradient_percent=0.0
)

    dt =
        config.timestep_s

    # --------------------------------------------------------
    # Traction acceleration
    # --------------------------------------------------------

    traction_acceleration =
        command.traction *
        config.max_acceleration_ms2

    # --------------------------------------------------------
    # Braking acceleration
    # --------------------------------------------------------

    brake_acceleration =
        command.brake *
        config.service_brake_ms2

    if command.mode ==
       :EMERGENCY_BRAKE

        brake_acceleration =
            config.emergency_brake_ms2
    end

    # --------------------------------------------------------
    # Resistance
    # --------------------------------------------------------

    resistance =
        resistance_acceleration(
            config,
            state.speed_ms
        )

    # --------------------------------------------------------
    # Gradient
    # --------------------------------------------------------

    gradient_acceleration =
        9.81 *
        gradient_percent /
        100.0

    # Positive gradient = uphill
    # therefore subtract it.

    acceleration =
        traction_acceleration -
        brake_acceleration -
        resistance -
        gradient_acceleration

    # --------------------------------------------------------
    # Integrate velocity
    # --------------------------------------------------------

    new_speed =
        state.speed_ms +
        acceleration * dt

    new_speed =
        max(
            0.0,
            new_speed
        )

    # Prevent numerical overspeed above configured max.
    max_speed =
        kmh_to_ms(
            config.max_speed_kmh
        )

    new_speed =
        min(
            new_speed,
            max_speed
        )

    # --------------------------------------------------------
    # Integrate position
    # --------------------------------------------------------

    average_speed =
        (
            state.speed_ms +
            new_speed
        ) / 2

    state.position_m +=
        average_speed * dt

    state.speed_ms =
        new_speed

    state.acceleration_ms2 =
        acceleration

    state.traction =
        command.traction

    state.brake =
        command.brake

    state.target_speed_ms =
        command.target_speed_ms

    state.time_s += dt

    state.stopped =
        new_speed < 0.01

    # --------------------------------------------------------
    # Energy
    # --------------------------------------------------------

    traction_energy =
        command.traction *
        config.traction_power_kw *
        dt /
        3600

    state.energy_kwh +=
        max(
            traction_energy,
            0.0
        )

    regen =
        command.brake *
        config.regenerative_power_kw *
        dt /
        3600

    state.regenerative_energy_kwh +=
        max(
            regen,
            0.0
        )

    return state
end


# ============================================================
# SPEED PROFILE GENERATOR
# ============================================================

"""
Generate a discrete speed profile for a route.

Returns a vector of:

(position_m, permitted_speed_kmh)
"""
function generate_speed_profile(
    controller::CruiseController;
    step_m=100.0
)

    maximum_position =
        maximum(
            section.end_m
            for section in controller.route
        )

    profile =
        Tuple{Float64,Float64}[]

    position = 0.0

    while position <= maximum_position

        speed =
            permitted_speed(
                controller,
                position
            )

        push!(
            profile,
            (
                position,
                speed
            )
        )

        position +=
            step_m
    end

    return profile
end


# ============================================================
# MULTI-SPEED PROFILE
# ============================================================

"""
Construct a route with multiple speed sections.

Example:

0–5 km       60 km/h
5–15 km      100 km/h
15–25 km     125 km/h
25–35 km     160 km/h
35–45 km     200 km/h
45–50 km      80 km/h
"""
function create_multispeed_route()

    return [
        SpeedSection(
            0.0,
            5_000.0,
            60.0
        ),

        SpeedSection(
            5_000.0,
            15_000.0,
            100.0
        ),

        SpeedSection(
            15_000.0,
            25_000.0,
            125.0
        ),

        SpeedSection(
            25_000.0,
            35_000.0,
            160.0
        ),

        SpeedSection(
            35_000.0,
            45_000.0,
            200.0
        ),

        SpeedSection(
            45_000.0,
            50_000.0,
            80.0
        )
    ]
end


# ============================================================
# SIMULATION
# ============================================================

function run_simulation(
    controller::CruiseController;
    initial_speed_kmh=0.0,
    max_time_s=2_000.0,
    gradient_function=nothing
)

    state =
        TrainState(
            0.0,
            0.0,
            kmh_to_ms(initial_speed_kmh),
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            false
        )

    history =
        NamedTuple[]

    route_end =
        maximum(
            section.end_m
            for section in controller.route
        )

    while state.time_s < max_time_s &&
          state.position_m < route_end

        command =
            update!(
                controller,
                state
            )

        gradient =
            if gradient_function === nothing
                0.0
            else
                gradient_function(
                    state.position_m
                )
            end

        apply_command!(
            state,
            controller.config,
            command;
            gradient_percent=gradient
        )

        push!(
            history,
            (
                time_s = state.time_s,
                position_m = state.position_m,
                speed_kmh = ms_to_kmh(
                    state.speed_ms
                ),
                target_speed_kmh =
                    ms_to_kmh(
                        state.target_speed_ms
                    ),
                permitted_speed_kmh =
                    permitted_speed(
                        controller,
                        state.position_m
                    ),
                acceleration_ms2 =
                    state.acceleration_ms2,
                traction =
                    state.traction,
                brake =
                    state.brake,
                mode =
                    command.mode,
                energy_kwh =
                    state.energy_kwh,
                regenerative_energy_kwh =
                    state.regenerative_energy_kwh
            )
        )

        # Safety guard
        if command.mode == :EMERGENCY_BRAKE &&
           state.speed_ms < 0.01

            break
        end
    end

    return state, history
end


# ============================================================
# MULTIPLE DRIVER SPEED SETTINGS
# ============================================================

"""
Set the driver's desired cruise speed.

The controller will never intentionally command above
the route permitted speed.
"""
function set_cruise_speed!(
    controller::CruiseController,
    speed_kmh::Real
)

    controller.target_speed_kmh =
        clamp(
            Float64(speed_kmh),
            0.0,
            controller.config.max_speed_kmh
        )

    return controller.target_speed_kmh
end


# ============================================================
# DRIVER SPEED MODES
# ============================================================

function set_speed_mode!(
    controller::CruiseController,
    mode::Symbol
)

    speeds = Dict(
        :SLOW       => 60.0,
        :REGIONAL   => 100.0,
        :FAST       => 125.0,
        :EXPRESS    => 160.0,
        :HIGH_SPEED => 200.0
    )

    haskey(speeds, mode) ||
        throw(
            ArgumentError(
                "Unknown speed mode"
            )
        )

    set_cruise_speed!(
        controller,
        speeds[mode]
    )

    return controller
end


# ============================================================
# REPORT
# ============================================================

function print_report(
    final_state::TrainState,
    history
)

    println()
    println(
        "======================================================"
    )

    println(
        "             TRAIN CRUISE CONTROL"
    )

    println(
        "======================================================"
    )

    @printf(
        "Run time:              %.1f s\n",
        final_state.time_s
    )

    @printf(
        "Distance:              %.2f km\n",
        final_state.position_m / 1000
    )

    @printf(
        "Final speed:           %.1f km/h\n",
        ms_to_kmh(
            final_state.speed_ms
        )
    )

    @printf(
        "Energy consumed:       %.2f kWh\n",
        final_state.energy_kwh
    )

    @printf(
        "Regenerative energy:   %.2f kWh\n",
        final_state.regenerative_energy_kwh
    )

    if !isempty(history)

        maximum_speed =
            maximum(
                h.speed_kmh
                for h in history
            )

        average_speed =
            mean(
                h.speed_kmh
                for h in history
            )

        @printf(
            "Maximum speed:         %.1f km/h\n",
            maximum_speed
        )

        @printf(
            "Average speed:         %.1f km/h\n",
            average_speed
        )
    end

    println()
    println(
        "======================================================"
    )
end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    config =
        TrainConfig(
            mass_tonnes=450.0,
            max_speed_kmh=200.0,
            max_acceleration_ms2=0.7,
            service_brake_ms2=0.8,
            emergency_brake_ms2=1.2,
            traction_power_kw=6000.0,
            regenerative_power_kw=4000.0,
            timestep_s=0.1
        )

    route =
        create_multispeed_route()

    controller =
        create_controller(
            config,
            route;
            target_speed_kmh=160.0
        )

    # Example 160 km/h cruise setting.
    set_speed_mode!(
        controller,
        :EXPRESS
    )

    # Example variable gradient.
    gradient(x) =
        1.0 *
        sin(
            x / 5_000
        )

    final_state,
    history =
        run_simulation(
            controller;
            initial_speed_kmh=0.0,
            max_time_s=2_000.0,
            gradient_function=gradient
        )

    print_report(
        final_state,
        history
    )

    return final_state, history
end


end # module


# ============================================================
# EXECUTE DEMO
# ============================================================

using .TrainCruiseControl

TrainCruiseControl.demo()
