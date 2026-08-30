module NetFishingAutomation

using LinearAlgebra
using Statistics
using Printf

# ============================================================
# AUTOMATED NET-FISHING / NET-HANDLING SIMULATOR
#
# Pure Julia
#
# Designed as a vessel-side automation and digital-twin model:
#
#   • Vessel position / heading
#   • Net deployment
#   • Net geometry
#   • Winch control
#   • Tension monitoring
#   • Depth monitoring
#   • Net retrieval
#   • Speed control
#   • Obstacle / seabed clearance monitoring
#   • Automatic stop conditions
#   • Fault detection
#   • Telemetry
#
# This is a simulation/control architecture rather than
# certified marine-control software.
# ============================================================


# ============================================================
# ENUMERATIONS
# ============================================================

@enum OperationState begin
    IDLE
    POSITIONING
    DEPLOYING
    FISHING
    RETRIEVING
    NET_SECURED
    COMPLETE
    FAULT
    EMERGENCY_STOP
end

@enum WinchState begin
    WINCH_STOPPED
    WINCH_PAYING_OUT
    WINCH_HAULING_IN
end


# ============================================================
# CONFIGURATION
# ============================================================

struct NetConfig

    net_length_m::Float64
    net_depth_m::Float64

    vessel_speed_ms::Float64

    deployment_speed_ms::Float64
    retrieval_speed_ms::Float64

    nominal_tension_n::Float64
    maximum_tension_n::Float64

    minimum_seabed_clearance_m::Float64

    maximum_wave_height_m::Float64

    timestep_s::Float64
end


function NetConfig(;
    net_length_m=500.0,
    net_depth_m=20.0,

    vessel_speed_ms=1.5,

    deployment_speed_ms=1.0,
    retrieval_speed_ms=0.8,

    nominal_tension_n=2000.0,
    maximum_tension_n=5000.0,

    minimum_seabed_clearance_m=3.0,

    maximum_wave_height_m=4.0,

    timestep_s=0.1
)

    NetConfig(
        Float64(net_length_m),
        Float64(net_depth_m),

        Float64(vessel_speed_ms),

        Float64(deployment_speed_ms),
        Float64(retrieval_speed_ms),

        Float64(nominal_tension_n),
        Float64(maximum_tension_n),

        Float64(minimum_seabed_clearance_m),

        Float64(maximum_wave_height_m),

        Float64(timestep_s)
    )
end


# ============================================================
# VESSEL
# ============================================================

mutable struct Vessel

    x_m::Float64
    y_m::Float64

    heading_rad::Float64

    speed_ms::Float64

    throttle::Float64

    rudder::Float64
end


# ============================================================
# NET
# ============================================================

mutable struct FishingNet

    length_deployed_m::Float64

    total_length_m::Float64

    target_depth_m::Float64

    actual_depth_m::Float64

    tension_n::Float64

    seabed_clearance_m::Float64

    deployed::Bool
    secured::Bool
end


# ============================================================
# WINCH
# ============================================================

mutable struct Winch

    state::WinchState

    line_speed_ms::Float64

    line_length_m::Float64

    tension_n::Float64

    motor_command::Float64
end


# ============================================================
# ENVIRONMENT
# ============================================================

struct MarineEnvironment

    depth_m::Float64

    current_x_ms::Float64
    current_y_ms::Float64

    wave_height_m::Float64

    wind_speed_ms::Float64

    restricted_area::Bool
end


# ============================================================
# CONTROLLER
# ============================================================

mutable struct FishingController

    config::NetConfig

    state::OperationState

    vessel::Vessel

    net::FishingNet

    winch::Winch

    environment::MarineEnvironment

    elapsed_s::Float64

    deployed_time_s::Float64

    retrieved_time_s::Float64

    fault_code::Symbol

    emergency_stop::Bool
end


# ============================================================
# TELEMETRY
# ============================================================

struct Telemetry

    time_s::Float64

    state::OperationState

    vessel_x_m::Float64
    vessel_y_m::Float64

    vessel_speed_ms::Float64

    net_length_m::Float64
    net_depth_m::Float64

    tension_n::Float64

    seabed_clearance_m::Float64

    winch_state::WinchState

    fault::Symbol
end


# ============================================================
# CREATE CONTROLLER
# ============================================================

function create_controller(
    config::NetConfig=NetConfig()
)

    vessel =
        Vessel(
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0
        )

    net =
        FishingNet(
            0.0,
            config.net_length_m,
            config.net_depth_m,
            0.0,
            0.0,
            0.0,
            false,
            false
        )

    winch =
        Winch(
            WINCH_STOPPED,
            0.0,
            0.0,
            0.0,
            0.0
        )

    environment =
        MarineEnvironment(
            50.0,
            0.0,
            0.0,
            1.0,
            5.0,
            false
        )

    FishingController(
        config,

        IDLE,

        vessel,
        net,
        winch,
        environment,

        0.0,
        0.0,
        0.0,

        :NONE,

        false
    )
end


# ============================================================
# DISTANCE
# ============================================================

distance(
    x1,
    y1,
    x2,
    y2
) =
    hypot(
        x2 - x1,
        y2 - y1
    )


# ============================================================
# WINCH COMMANDS
# ============================================================

function pay_out!(
    controller::FishingController
)

    controller.winch.state =
        WINCH_PAYING_OUT

    controller.winch.line_speed_ms =
        controller.config.deployment_speed_ms

    controller.winch.motor_command =
        1.0
end


function haul_in!(
    controller::FishingController
)

    controller.winch.state =
        WINCH_HAULING_IN

    controller.winch.line_speed_ms =
        controller.config.retrieval_speed_ms

    controller.winch.motor_command =
        -1.0
end


function stop_winch!(
    controller::FishingController
)

    controller.winch.state =
        WINCH_STOPPED

    controller.winch.line_speed_ms =
        0.0

    controller.winch.motor_command =
        0.0
end


# ============================================================
# TENSION MODEL
# ============================================================

function calculate_tension(
    controller::FishingController
)

    net =
        controller.net

    winch =
        controller.winch

    vessel =
        controller.vessel

    environment =
        controller.environment

    base =
        controller.config.nominal_tension_n

    speed_effect =
        500.0 *
        vessel.speed_ms

    deployment_effect =
        100.0 *
        abs(
            winch.line_speed_ms
        )

    depth_effect =
        10.0 *
        net.target_depth_m

    current_effect =
        250.0 *
        hypot(
            environment.current_x_ms,
            environment.current_y_ms
        )

    wave_effect =
        150.0 *
        environment.wave_height_m

    return max(
        0.0,
        base +
        speed_effect +
        deployment_effect +
        depth_effect +
        current_effect +
        wave_effect
    )
end


# ============================================================
# DEPTH CONTROL
# ============================================================

function calculate_net_depth(
    controller::FishingController
)

    net =
        controller.net

    environment =
        controller.environment

    # Simplified hydrodynamic model.
    depth =
        net.target_depth_m

    speed_factor =
        0.05 *
        controller.vessel.speed_ms

    current_factor =
        0.10 *
        hypot(
            environment.current_x_ms,
            environment.current_y_ms
        )

    depth -=
        speed_factor

    depth +=
        current_factor

    return clamp(
        depth,
        0.0,
        environment.depth_m
    )
end


# ============================================================
# SEABED CLEARANCE
# ============================================================

function calculate_clearance(
    controller::FishingController
)

    depth =
        controller.net.actual_depth_m

    seabed =
        controller.environment.depth_m

    return seabed - depth
end


# ============================================================
# SAFETY MONITOR
# ============================================================

function safety_monitor!(
    controller::FishingController
)

    config =
        controller.config

    environment =
        controller.environment

    net =
        controller.net

    # -----------------------------------------------
    # Excessive tension
    # -----------------------------------------------

    if net.tension_n >
       config.maximum_tension_n

        controller.state =
            FAULT

        controller.fault_code =
            :EXCESSIVE_NET_TENSION

        stop_winch!(
            controller
        )

        return false
    end

    # -----------------------------------------------
    # Insufficient seabed clearance
    # -----------------------------------------------

    if net.seabed_clearance_m <
       config.minimum_seabed_clearance_m

        controller.state =
            FAULT

        controller.fault_code =
            :INSUFFICIENT_SEABED_CLEARANCE

        stop_winch!(
            controller
        )

        return false
    end

    # -----------------------------------------------
    # Excessive waves
    # -----------------------------------------------

    if environment.wave_height_m >
       config.maximum_wave_height_m

        controller.state =
            FAULT

        controller.fault_code =
            :EXCESSIVE_SEA_STATE

        stop_winch!(
            controller
        )

        return false
    end

    # -----------------------------------------------
    # Restricted area
    # -----------------------------------------------

    if environment.restricted_area

        controller.state =
            FAULT

        controller.fault_code =
            :RESTRICTED_AREA

        stop_winch!(
            controller
        )

        return false
    end

    return true
end


# ============================================================
# VESSEL MOVEMENT
# ============================================================

function update_vessel!(
    controller::FishingController
)

    vessel =
        controller.vessel

    environment =
        controller.environment

    dt =
        controller.config.timestep_s

    vessel.speed_ms +=
        (
            vessel.throttle * 0.2 -
            vessel.speed_ms * 0.05
        ) * dt

    vessel.speed_ms =
        max(
            vessel.speed_ms,
            0.0
        )

    vessel.heading_rad +=
        vessel.rudder *
        0.05 *
        dt

    vessel.x_m +=
        vessel.speed_ms *
        cos(vessel.heading_rad) *
        dt +
        environment.current_x_ms *
        dt

    vessel.y_m +=
        vessel.speed_ms *
        sin(vessel.heading_rad) *
        dt +
        environment.current_y_ms *
        dt
end


# ============================================================
# NET MOVEMENT
# ============================================================

function update_net!(
    controller::FishingController
)

    net =
        controller.net

    winch =
        controller.winch

    dt =
        controller.config.timestep_s

    if winch.state ==
       WINCH_PAYING_OUT

        net.length_deployed_m +=
            winch.line_speed_ms *
            dt

        if net.length_deployed_m >=
           net.total_length_m

            net.length_deployed_m =
                net.total_length_m

            stop_winch!(
                controller
            )

            net.deployed =
                true

            controller.state =
                FISHING
        end

    elseif winch.state ==
           WINCH_HAULING_IN

        net.length_deployed_m -=
            winch.line_speed_ms *
            dt

        if net.length_deployed_m <= 0.0

            net.length_deployed_m =
                0.0

            stop_winch!(
                controller
            )

            net.secured =
                true

            controller.state =
                NET_SECURED
        end
    end

    net.actual_depth_m =
        calculate_net_depth(
            controller
        )

    net.seabed_clearance_m =
        calculate_clearance(
            controller
        )

    net.tension_n =
        calculate_tension(
            controller
        )

    controller.winch.tension_n =
        net.tension_n

    controller.winch.line_length_m =
        net.length_deployed_m
end


# ============================================================
# AUTOMATIC STATE MACHINE
# ============================================================

function controller_step!(
    controller::FishingController
)

    if controller.emergency_stop

        controller.state =
            EMERGENCY_STOP

        stop_winch!(
            controller
        )

        return
    end

    # --------------------------------------------------------
    # IDLE
    # --------------------------------------------------------

    if controller.state ==
       IDLE

        controller.vessel.throttle =
            0.0

        return
    end

    # --------------------------------------------------------
    # POSITIONING
    # --------------------------------------------------------

    if controller.state ==
       POSITIONING

        controller.vessel.throttle =
            0.5

        if controller.vessel.speed_ms >
           0.8

            controller.vessel.throttle =
                0.2

            pay_out!(
                controller
            )

            controller.state =
                DEPLOYING
        end

        return
    end

    # --------------------------------------------------------
    # DEPLOYING
    # --------------------------------------------------------

    if controller.state ==
       DEPLOYING

        controller.vessel.throttle =
            0.3

        if controller.net.length_deployed_m >
           0.0

            controller.deployed_time_s +=
                controller.config.timestep_s
        end

        return
    end

    # --------------------------------------------------------
    # FISHING
    # --------------------------------------------------------

    if controller.state ==
       FISHING

        controller.vessel.throttle =
            0.35

        # Maintain controlled net deployment.
        stop_winch!(
            controller
        )

        # Example automatic haul trigger.
        if controller.deployed_time_s >
           300.0

            haul_in!(
                controller
            )

            controller.state =
                RETRIEVING
        end

        controller.deployed_time_s +=
            controller.config.timestep_s

        return
    end

    # --------------------------------------------------------
    # RETRIEVING
    # --------------------------------------------------------

    if controller.state ==
       RETRIEVING

        controller.vessel.throttle =
            0.15

        controller.retrieved_time_s +=
            controller.config.timestep_s

        return
    end

    # --------------------------------------------------------
    # NET SECURED
    # --------------------------------------------------------

    if controller.state ==
       NET_SECURED

        controller.vessel.throttle =
            0.0

        controller.state =
            COMPLETE

        return
    end
end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(
    controller::FishingController
)

    controller.emergency_stop =
        true

    controller.state =
        EMERGENCY_STOP

    controller.vessel.throttle =
        0.0

    controller.vessel.rudder =
        0.0

    stop_winch!(
        controller
    )

    controller.fault_code =
        :EMERGENCY_STOP

    return controller
end


# ============================================================
# RESET
# ============================================================

function reset!(
    controller::FishingController
)

    controller.state =
        IDLE

    controller.emergency_stop =
        false

    controller.fault_code =
        :NONE

    controller.elapsed_s =
        0.0

    controller.deployed_time_s =
        0.0

    controller.retrieved_time_s =
        0.0

    controller.net.length_deployed_m =
        0.0

    controller.net.deployed =
        false

    controller.net.secured =
        false

    stop_winch!(
        controller
    )

    return controller
end


# ============================================================
# START OPERATION
# ============================================================

function start!(
    controller::FishingController
)

    controller.state =
        POSITIONING

    controller.vessel.throttle =
        0.4

    return controller
end


# ============================================================
# TELEMETRY
# ============================================================

function telemetry(
    controller::FishingController
)

    vessel =
        controller.vessel

    net =
        controller.net

    Telemetry(

        controller.elapsed_s,

        controller.state,

        vessel.x_m,
        vessel.y_m,

        vessel.speed_ms,

        net.length_deployed_m,
        net.actual_depth_m,

        net.tension_n,

        net.seabed_clearance_m,

        controller.winch.state,

        controller.fault_code
    )
end


# ============================================================
# SIMULATION STEP
# ============================================================

function step!(
    controller::FishingController
)

    dt =
        controller.config.timestep_s

    controller.elapsed_s +=
        dt

    update_vessel!(
        controller
    )

    update_net!(
        controller
    )

    safety_monitor!(
        controller
    )

    if controller.state != FAULT &&
       controller.state != EMERGENCY_STOP

        controller_step!(
            controller
        )
    end

    return telemetry(
        controller
    )
end


# ============================================================
# RUN SIMULATION
# ============================================================

function run!(
    controller::FishingController;
    max_time_s=900.0
)

    start!(
        controller
    )

    history =
        Telemetry[]

    while controller.elapsed_s <
          max_time_s

        sample =
            step!(
                controller
            )

        push!(
            history,
            sample
        )

        if controller.state ==
           COMPLETE ||
           controller.state ==
           FAULT ||
           controller.state ==
           EMERGENCY_STOP

            break
        end
    end

    return history
end


# ============================================================
# OPERATIONAL STATISTICS
# ============================================================

function statistics(
    history
)

    isempty(history) &&
        return (
            duration_s=0.0,
            maximum_tension_n=0.0,
            mean_tension_n=0.0,
            maximum_depth_m=0.0,
            minimum_clearance_m=0.0
        )

    tensions =
        [
            x.tension_n
            for x in history
        ]

    depths =
        [
            x.net_depth_m
            for x in history
        ]

    clearances =
        [
            x.seabed_clearance_m
            for x in history
        ]

    return (

        duration_s =
            last(history).time_s,

        maximum_tension_n =
            maximum(tensions),

        mean_tension_n =
            mean(tensions),

        maximum_depth_m =
            maximum(depths),

        minimum_clearance_m =
            minimum(clearances)
    )
end


# ============================================================
# REPORT
# ============================================================

function print_report(
    controller::FishingController,
    history
)

    stats =
        statistics(
            history
        )

    println()
    println(
        "=========================================================="
    )

    println(
        "          AUTOMATED NET HANDLING SIMULATOR"
    )

    println(
        "=========================================================="
    )

    @printf(
        "Operation time:          %.1f s\n",
        stats.duration_s
    )

    println(
        "Final state:             ",
        controller.state
    )

    @printf(
        "Net deployed:            %.1f m\n",
        controller.net.length_deployed_m
    )

    @printf(
        "Maximum tension:         %.1f N\n",
        stats.maximum_tension_n
    )

    @printf(
        "Mean tension:            %.1f N\n",
        stats.mean_tension_n
    )

    @printf(
        "Maximum net depth:       %.1f m\n",
        stats.maximum_depth_m
    )

    @printf(
        "Minimum seabed clearance: %.1f m\n",
        stats.minimum_clearance_m
    )

    println(
        "Fault:                   ",
        controller.fault_code
    )

    println(
        "=========================================================="
    )
end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    config =
        NetConfig(
            net_length_m=500.0,
            net_depth_m=20.0,

            vessel_speed_ms=1.5,

            deployment_speed_ms=1.0,
            retrieval_speed_ms=0.8,

            nominal_tension_n=2000.0,
            maximum_tension_n=5000.0,

            minimum_seabed_clearance_m=3.0,

            maximum_wave_height_m=4.0,

            timestep_s=0.1
        )

    controller =
        create_controller(
            config
        )

    println()
    println(
        "Starting automated net-handling simulation..."
    )

    history =
        run!(
            controller;
            max_time_s=900.0
        )

    print_report(
        controller,
        history
    )

    println()
    println(
        "State transitions:"
    )

    previous =
        nothing

    for sample in history

        if sample.state != previous

            @printf(
                "%8.1f s | %-18s | net %7.1f m | tension %7.1f N\n",
                sample.time_s,
                string(sample.state),
                sample.net_length_m,
                sample.tension_n
            )

            previous =
                sample.state
        end
    end

    return controller, history
end


end # module


# ============================================================
# RUN
# ============================================================

using .NetFishingAutomation

NetFishingAutomation.demo()
