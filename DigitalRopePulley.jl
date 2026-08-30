module DigitalRopePulley

using Dates
using Printf

# ============================================================
# DIGITAL ROPE PULLEY SYSTEM
#
# Pure Julia
#
# Digital twin / controller simulation for a weighted
# rope-and-pulley mechanism.
#
# MODEL
#
#   motor / operator
#          │
#          ▼
#      drive pulley
#          │
#       rope/cable
#          │
#      ┌───┴───┐
#      │       │
#   fixed    movable
#   pulley   pulley
#                │
#                ▼
#              LOAD
#
# FEATURES
#   - Rope position
#   - Rope velocity
#   - Rope acceleration
#   - Pulley RPM
#   - Mechanical advantage
#   - Weighted load
#   - Counterweight
#   - Gravity
#   - Rope tension
#   - Friction
#   - Efficiency
#   - Force estimation
#   - Encoder simulation
#   - Load-cell simulation
#   - Overload protection
#   - Travel limits
#   - Slack detection
#   - Emergency stop
#   - State machine
#   - Event log
#   - Position controller
#   - Velocity controller
#   - Simulation loop
#
# IMPORTANT
#
# This is a simulation/reference implementation.
# It is NOT suitable as the sole safety controller for a
# real lifting system.
# ============================================================


# ============================================================
# PHYSICAL CONSTANTS
# ============================================================

const GRAVITY = 9.80665


# ============================================================
# CONFIGURATION
# ============================================================

struct PulleyConfig

    rope_radius_m::Float64

    drive_radius_m::Float64

    pulley_inertia_kgm2::Float64

    rope_mass_kg_per_m::Float64

    friction_coefficient::Float64

    efficiency::Float64

    mechanical_advantage::Int

    maximum_load_kg::Float64

    maximum_rope_tension_N::Float64

    maximum_velocity_mps::Float64

    maximum_acceleration_mps2::Float64

    lower_limit_m::Float64

    upper_limit_m::Float64

    slack_tension_N::Float64

    encoder_counts_per_rev::Int
end


function PulleyConfig(;
    rope_radius_m=0.006,
    drive_radius_m=0.050,
    pulley_inertia_kgm2=0.01,
    rope_mass_kg_per_m=0.05,
    friction_coefficient=0.03,
    efficiency=0.90,
    mechanical_advantage=2,
    maximum_load_kg=100.0,
    maximum_rope_tension_N=1500.0,
    maximum_velocity_mps=1.0,
    maximum_acceleration_mps2=2.0,
    lower_limit_m=0.0,
    upper_limit_m=2.0,
    slack_tension_N=5.0,
    encoder_counts_per_rev=4096
)

    PulleyConfig(
        rope_radius_m,
        drive_radius_m,
        pulley_inertia_kgm2,
        rope_mass_kg_per_m,
        friction_coefficient,
        efficiency,
        mechanical_advantage,
        maximum_load_kg,
        maximum_rope_tension_N,
        maximum_velocity_mps,
        maximum_acceleration_mps2,
        lower_limit_m,
        upper_limit_m,
        slack_tension_N,
        encoder_counts_per_rev
    )
end


# ============================================================
# LOAD
# ============================================================

mutable struct WeightedLoad

    mass_kg::Float64

    position_m::Float64

    velocity_mps::Float64

    acceleration_mps2::Float64

    target_position_m::Float64
end


function WeightedLoad(
    mass_kg::Float64;
    position_m=0.0
)

    WeightedLoad(
        mass_kg,
        position_m,
        0.0,
        0.0,
        position_m
    )
end


# ============================================================
# COUNTERWEIGHT
# ============================================================

mutable struct Counterweight

    mass_kg::Float64

    position_m::Float64
end


Counterweight(
    mass_kg::Float64
) =
    Counterweight(
        mass_kg,
        0.0
    )


# ============================================================
# ROPE
# ============================================================

mutable struct RopeState

    total_length_m::Float64

    pulled_length_m::Float64

    tension_N::Float64

    tension_left_N::Float64

    tension_right_N::Float64

    slack::Bool

    stretched::Float64
end


function RopeState(
    total_length_m::Float64
)

    RopeState(
        total_length_m,
        0.0,
        0.0,
        0.0,
        0.0,
        false,
        0.0
    )
end


# ============================================================
# DRIVE
# ============================================================

mutable struct DriveState

    angle_rad::Float64

    angular_velocity_radps::Float64

    angular_acceleration_radps2::Float64

    torque_Nm::Float64
end


DriveState() =
    DriveState(
        0.0,
        0.0,
        0.0,
        0.0
    )


# ============================================================
# SENSOR STATE
# ============================================================

mutable struct SensorState

    encoder_position_m::Float64

    encoder_velocity_mps::Float64

    load_cell_N::Float64

    motor_torque_Nm::Float64

    limit_lower::Bool

    limit_upper::Bool
end


SensorState() =
    SensorState(
        0.0,
        0.0,
        0.0,
        0.0,
        false,
        false
    )


# ============================================================
# SYSTEM STATE
# ============================================================

@enum SystemState begin

    IDLE

    READY

    MOVING

    HOLDING

    OVERLOAD

    SLACK

    LIMIT

    ESTOP

    FAULT
end


# ============================================================
# EVENT
# ============================================================

struct PulleyEvent

    timestamp::DateTime

    event::Symbol

    message::String
end


mutable struct EventLog

    events::Vector{PulleyEvent}
end


EventLog() =
    EventLog(
        PulleyEvent[]
    )


function log!(
    eventlog::EventLog,
    event::Symbol,
    message::String
)

    push!(
        eventlog.events,
        PulleyEvent(
            now(),
            event,
            message
        )
    )
end


# ============================================================
# PID CONTROLLER
# ============================================================

mutable struct PIDController

    kp::Float64

    ki::Float64

    kd::Float64

    integral::Float64

    previous_error::Float64

    output_min::Float64

    output_max::Float64
end


function PIDController(;
    kp=50.0,
    ki=5.0,
    kd=10.0,
    output_min=-100.0,
    output_max=100.0
)

    PIDController(
        kp,
        ki,
        kd,
        0.0,
        0.0,
        output_min,
        output_max
    )
end


function reset!(
    pid::PIDController
)

    pid.integral = 0.0
    pid.previous_error = 0.0
end


function pid_step!(
    pid::PIDController,
    target::Float64,
    measured::Float64,
    dt::Float64
)

    error =
        target -
        measured

    pid.integral +=
        error * dt

    derivative =
        dt > 0 ?
        (
            error -
            pid.previous_error
        ) / dt :
        0.0

    output =
        pid.kp * error +
        pid.ki * pid.integral +
        pid.kd * derivative

    output =
        clamp(
            output,
            pid.output_min,
            pid.output_max
        )

    pid.previous_error =
        error

    output
end


# ============================================================
# MAIN SYSTEM
# ============================================================

mutable struct DigitalPulleySystem

    config::PulleyConfig

    load::WeightedLoad

    counterweight::Counterweight

    rope::RopeState

    drive::DriveState

    sensors::SensorState

    state::SystemState

    position_controller::PIDController

    eventlog::EventLog

    target_velocity_mps::Float64

    target_force_N::Float64

    enabled::Bool
end


function DigitalPulleySystem(
    config::PulleyConfig,
    load::WeightedLoad,
    counterweight::Counterweight,
    rope_length_m::Float64
)

    DigitalPulleySystem(
        config,
        load,
        counterweight,
        RopeState(
            rope_length_m
        ),
        DriveState(),
        SensorState(),
        IDLE,
        PIDController(
            kp=100.0,
            ki=5.0,
            kd=20.0,
            output_min=-100.0,
            output_max=100.0
        ),
        EventLog(),
        0.0,
        0.0,
        false
    )
end


# ============================================================
# MECHANICAL ADVANTAGE
# ============================================================

function mechanical_advantage(
    system::DigitalPulleySystem
)

    system.config.mechanical_advantage
end


# ============================================================
# LOAD FORCE
# ============================================================

function gravitational_force(
    mass_kg::Float64
)

    mass_kg *
    GRAVITY
end


function load_weight(
    system::DigitalPulleySystem
)

    gravitational_force(
        system.load.mass_kg
    )
end


# ============================================================
# IDEAL ROPE FORCE
# ============================================================

function ideal_rope_force(
    system::DigitalPulleySystem
)

    load_weight(system) /
    mechanical_advantage(system)
end


# ============================================================
# FRICTION
# ============================================================

function friction_force(
    system::DigitalPulleySystem
)

    μ =
        system.config.friction_coefficient

    load_weight(system) *
    μ
end


# ============================================================
# REQUIRED INPUT FORCE
# ============================================================

function required_input_force(
    system::DigitalPulleySystem
)

    ideal =
        ideal_rope_force(
            system
        )

    friction =
        friction_force(
            system
        )

    (ideal + friction) /
    system.config.efficiency
end


# ============================================================
# ROPE TENSION
# ============================================================

function calculate_tension(
    system::DigitalPulleySystem
)

    load_force =
        load_weight(
            system
        )

    advantage =
        mechanical_advantage(
            system
        )

    friction =
        friction_force(
            system
        )

    tension =
        (
            load_force /
            advantage
        ) +
        friction

    tension =
        tension /
        system.config.efficiency

    return tension
end


# ============================================================
# MOTOR TORQUE
# ============================================================

function force_to_torque(
    system::DigitalPulleySystem,
    force_N::Float64
)

    force_N *
    system.config.drive_radius_m
end


function required_drive_torque(
    system::DigitalPulleySystem
)

    force_to_torque(
        system,
        required_input_force(
            system
        )
    )
end


# ============================================================
# POSITION ↔ ROTATION
# ============================================================

function rope_to_angle(
    system::DigitalPulleySystem,
    rope_m::Float64
)

    rope_m /
    system.config.drive_radius_m
end


function angle_to_rope(
    system::DigitalPulleySystem,
    angle_rad::Float64
)

    angle_rad *
    system.config.drive_radius_m
end


function rpm_from_velocity(
    system::DigitalPulleySystem,
    velocity_mps::Float64
)

    circumference =
        2π *
        system.config.drive_radius_m

    rev_per_second =
        velocity_mps /
        circumference

    rev_per_second *
    60.0
end


# ============================================================
# SENSOR SIMULATION
# ============================================================

function update_sensors!(
    system::DigitalPulleySystem
)

    cfg =
        system.config

    # Encoder

    system.sensors.encoder_position_m =
        system.load.position_m

    system.sensors.encoder_velocity_mps =
        system.load.velocity_mps

    # Load cell

    system.sensors.load_cell_N =
        system.rope.tension_N

    # Motor torque

    system.sensors.motor_torque_Nm =
        system.drive.torque_Nm

    # Travel limits

    system.sensors.limit_lower =
        system.load.position_m <=
        cfg.lower_limit_m

    system.sensors.limit_upper =
        system.load.position_m >=
        cfg.upper_limit_m
end


# ============================================================
# SAFETY MONITOR
# ============================================================

function safety_check!(
    system::DigitalPulleySystem
)

    cfg =
        system.config

    load =
        system.load

    rope =
        system.rope

    sensors =
        system.sensors

    # ----------------------------------------
    # Load limit
    # ----------------------------------------

    if load.mass_kg >
       cfg.maximum_load_kg

        system.state =
            OVERLOAD

        system.enabled =
            false

        log!(
            system.eventlog,
            :OVERLOAD,
            "Load exceeds configured limit"
        )

        return false
    end

    # ----------------------------------------
    # Tension limit
    # ----------------------------------------

    if rope.tension_N >
       cfg.maximum_rope_tension_N

        system.state =
            OVERLOAD

        system.enabled =
            false

        log!(
            system.eventlog,
            :OVER_TENSION,
            "Rope tension exceeds configured limit"
        )

        return false
    end

    # ----------------------------------------
    # Velocity limit
    # ----------------------------------------

    if abs(
        load.velocity_mps
    ) >
       cfg.maximum_velocity_mps

        system.state =
            FAULT

        system.enabled =
            false

        log!(
            system.eventlog,
            :OVERSPEED,
            "Velocity exceeds configured limit"
        )

        return false
    end

    # ----------------------------------------
    # Acceleration limit
    # ----------------------------------------

    if abs(
        load.acceleration_mps2
    ) >
       cfg.maximum_acceleration_mps2

        system.state =
            FAULT

        system.enabled =
            false

        log!(
            system.eventlog,
            :OVER_ACCELERATION,
            "Acceleration exceeds configured limit"
        )

        return false
    end

    # ----------------------------------------
    # Slack rope
    # ----------------------------------------

    if rope.tension_N <
       cfg.slack_tension_N

        rope.slack =
            true

        system.state =
            SLACK

        system.enabled =
            false

        log!(
            system.eventlog,
            :SLACK_ROPE,
            "Rope tension below safe threshold"
        )

        return false

    else

        rope.slack =
            false
    end

    # ----------------------------------------
    # Lower limit
    # ----------------------------------------

    if sensors.limit_lower &&
       load.velocity_mps < 0

        system.state =
            LIMIT

        system.enabled =
            false

        log!(
            system.eventlog,
            :LOWER_LIMIT,
            "Lower travel limit reached"
        )

        return false
    end

    # ----------------------------------------
    # Upper limit
    # ----------------------------------------

    if sensors.limit_upper &&
       load.velocity_mps > 0

        system.state =
            LIMIT

        system.enabled =
            false

        log!(
            system.eventlog,
            :UPPER_LIMIT,
            "Upper travel limit reached"
        )

        return false
    end

    return true
end


# ============================================================
# ENABLE
# ============================================================

function enable!(
    system::DigitalPulleySystem
)

    system.state in
        (
            OVERLOAD,
            FAULT,
            ESTOP,
            SLACK
        ) &&
        return false

    system.enabled =
        true

    system.state =
        READY

    log!(
        system.eventlog,
        :ENABLED,
        "System enabled"
    )

    true
end


# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(
    system::DigitalPulleySystem
)

    system.enabled =
        false

    system.drive.torque_Nm =
        0.0

    system.load.velocity_mps =
        0.0

    system.load.acceleration_mps2 =
        0.0

    system.state =
        ESTOP

    log!(
        system.eventlog,
        :ESTOP,
        "Emergency stop activated"
    )
end


# ============================================================
# RESET
# ============================================================

function reset_system!(
    system::DigitalPulleySystem
)

    system.state =
        IDLE

    system.enabled =
        false

    system.drive.torque_Nm =
        0.0

    system.load.velocity_mps =
        0.0

    system.load.acceleration_mps2 =
        0.0

    system.rope.slack =
        false

    reset!(
        system.position_controller
    )

    log!(
        system.eventlog,
        :RESET,
        "System reset"
    )
end


# ============================================================
# TARGET POSITION
# ============================================================

function set_target_position!(
    system::DigitalPulleySystem,
    position_m::Float64
)

    cfg =
        system.config

    position_m =
        clamp(
            position_m,
            cfg.lower_limit_m,
            cfg.upper_limit_m
        )

    system.load.target_position_m =
        position_m

    log!(
        system.eventlog,
        :TARGET_POSITION,
        "Target position set"
    )
end


# ============================================================
# POSITION CONTROL
# ============================================================

function position_control!(
    system::DigitalPulleySystem,
    dt::Float64
)

    system.enabled ||
        return 0.0

    target =
        system.load.target_position_m

    actual =
        system.load.position_m

    control =
        pid_step!(
            system.position_controller,
            target,
            actual,
            dt
        )

    max_force =
        system.config.maximum_rope_tension_N

    requested_force =
        clamp(
            control,
            -max_force,
            max_force
        )

    torque =
        force_to_torque(
            system,
            requested_force
        )

    system.drive.torque_Nm =
        torque

    torque
end


# ============================================================
# PHYSICAL SIMULATION
# ============================================================

function simulate_step!(
    system::DigitalPulleySystem,
    dt::Float64
)

    dt > 0 ||
        error("dt must be positive.")

    update_sensors!(
        system
    )

    if !safety_check!(
        system
    )

        system.drive.torque_Nm =
            0.0

        return
    end

    # ----------------------------------------
    # Controller
    # ----------------------------------------

    position_control!(
        system,
        dt
    )

    # ----------------------------------------
    # Mechanical force
    # ----------------------------------------

    input_force =
        system.drive.torque_Nm /
        system.config.drive_radius_m

    effective_force =
        input_force *
        system.config.efficiency

    # ----------------------------------------
    # Load force
    # ----------------------------------------

    gravitational =
        load_weight(
            system
        )

    mechanical_advantage_value =
        mechanical_advantage(
            system
        )

    supporting_force =
        effective_force *
        mechanical_advantage_value

    net_force =
        supporting_force -
        gravitational

    # ----------------------------------------
    # Friction
    # ----------------------------------------

    friction =
        friction_force(
            system
        )

    if abs(
        system.load.velocity_mps
    ) > 1e-9

        net_force -=
            sign(
                system.load.velocity_mps
            ) *
            friction
    end

    # ----------------------------------------
    # Acceleration
    # ----------------------------------------

    acceleration =
        net_force /
        system.load.mass_kg

    acceleration =
        clamp(
            acceleration,
            -system.config.maximum_acceleration_mps2,
            system.config.maximum_acceleration_mps2
        )

    system.load.acceleration_mps2 =
        acceleration

    # ----------------------------------------
    # Velocity
    # ----------------------------------------

    system.load.velocity_mps +=
        acceleration *
        dt

    system.load.velocity_mps =
        clamp(
            system.load.velocity_mps,
            -system.config.maximum_velocity_mps,
            system.config.maximum_velocity_mps
        )

    # ----------------------------------------
    # Position
    # ----------------------------------------

    system.load.position_m +=
        system.load.velocity_mps *
        dt

    # ----------------------------------------
    # Hard travel limits
    # ----------------------------------------

    if system.load.position_m <=
       system.config.lower_limit_m

        system.load.position_m =
            system.config.lower_limit_m

        if system.load.velocity_mps < 0

            system.load.velocity_mps =
                0.0
        end
    end

    if system.load.position_m >=
       system.config.upper_limit_m

        system.load.position_m =
            system.config.upper_limit_m

        if system.load.velocity_mps > 0

            system.load.velocity_mps =
                0.0
        end
    end

    # ----------------------------------------
    # Rope
    # ----------------------------------------

    system.rope.pulled_length_m =
        system.load.position_m *
        system.config.mechanical_advantage

    system.rope.tension_N =
        calculate_tension(
            system
        )

    system.rope.tension_left_N =
        system.rope.tension_N

    system.rope.tension_right_N =
        system.rope.tension_N

    # ----------------------------------------
    # Drive angle
    # ----------------------------------------

    system.drive.angle_rad =
        rope_to_angle(
            system,
            system.rope.pulled_length_m
        )

    system.drive.angular_velocity_radps =
        system.load.velocity_mps *
        system.config.mechanical_advantage /
        system.config.drive_radius_m

    system.drive.angular_acceleration_radps2 =
        system.load.acceleration_mps2 *
        system.config.mechanical_advantage /
        system.config.drive_radius_m

    update_sensors!(
        system
    )

    system.state =
        abs(
            system.load.velocity_mps
        ) < 1e-4 ?
        HOLDING :
        MOVING
end


# ============================================================
# SIMULATION
# ============================================================

function simulate!(
    system::DigitalPulleySystem,
    duration_s::Float64;
    dt=0.001
)

    duration_s >= 0 ||
        error("Invalid duration.")

    steps =
        Int(
            ceil(
                duration_s / dt
            )
        )

    history =
        NamedTuple[]

    for step in 1:steps

        simulate_step!(
            system,
            dt
        )

        push!(
            history,
            (
                time =
                    step * dt,

                position =
                    system.load.position_m,

                velocity =
                    system.load.velocity_mps,

                acceleration =
                    system.load.acceleration_mps2,

                tension =
                    system.rope.tension_N,

                torque =
                    system.drive.torque_Nm,

                state =
                    system.state
            )
        )

        if system.state in
            (
                ESTOP,
                OVERLOAD,
                FAULT,
                SLACK
            )

            break
        end
    end

    history
end


# ============================================================
# ENERGY
# ============================================================

function potential_energy(
    system::DigitalPulleySystem
)

    system.load.mass_kg *
    GRAVITY *
    system.load.position_m
end


function kinetic_energy(
    system::DigitalPulleySystem
)

    0.5 *
    system.load.mass_kg *
    system.load.velocity_mps^2
end


function total_load_energy(
    system::DigitalPulleySystem
)

    potential_energy(system) +
    kinetic_energy(system)
end


# ============================================================
# POWER
# ============================================================

function mechanical_power(
    system::DigitalPulleySystem
)

    system.rope.tension_N *
    abs(
        system.load.velocity_mps
    )
end


# ============================================================
# DIAGNOSTICS
# ============================================================

function diagnostics(
    system::DigitalPulleySystem
)

    (
        state =
            system.state,

        position_m =
            system.load.position_m,

        velocity_mps =
            system.load.velocity_mps,

        acceleration_mps2 =
            system.load.acceleration_mps2,

        load_kg =
            system.load.mass_kg,

        tension_N =
            system.rope.tension_N,

        required_force_N =
            required_input_force(system),

        required_torque_Nm =
            required_drive_torque(system),

        rpm =
            rpm_from_velocity(
                system,
                system.load.velocity_mps
            ),

        mechanical_advantage =
            mechanical_advantage(system),

        efficiency =
            system.config.efficiency,

        power_W =
            mechanical_power(system),

        potential_energy_J =
            potential_energy(system),

        kinetic_energy_J =
            kinetic_energy(system),

        rope_slack =
            system.rope.slack,

        lower_limit =
            system.sensors.limit_lower,

        upper_limit =
            system.sensors.limit_upper
    )
end


function print_diagnostics(
    system::DigitalPulleySystem
)

    d =
        diagnostics(system)

    println()
    println(
        "="^60
    )

    println(
        "          DIGITAL ROPE PULLEY"
    )

    println(
        "="^60
    )

    println(
        "State:                 ",
        d.state
    )

    @printf(
        "Load:                  %.2f kg\n",
        d.load_kg
    )

    @printf(
        "Position:              %.3f m\n",
        d.position_m
    )

    @printf(
        "Velocity:              %.3f m/s\n",
        d.velocity_mps
    )

    @printf(
        "Acceleration:          %.3f m/s²\n",
        d.acceleration_mps2
    )

    @printf(
        "Rope tension:          %.2f N\n",
        d.tension_N
    )

    @printf(
        "Required input force:  %.2f N\n",
        d.required_force_N
    )

    @printf(
        "Drive torque:          %.2f Nm\n",
        d.required_torque_Nm
    )

    @printf(
        "Drive speed:           %.2f RPM\n",
        d.rpm
    )

    @printf(
        "Mechanical advantage:  %d\n",
        d.mechanical_advantage
    )

    @printf(
        "Efficiency:            %.1f %%\n",
        d.efficiency * 100
    )

    @printf(
        "Mechanical power:      %.2f W\n",
        d.power_W
    )

    @printf(
        "Potential energy:      %.2f J\n",
        d.potential_energy_J
    )

    @printf(
        "Kinetic energy:        %.2f J\n",
        d.kinetic_energy_J
    )

    println(
        "Rope slack:             ",
        d.rope_slack
    )

    println(
        "Lower limit:            ",
        d.lower_limit
    )

    println(
        "Upper limit:            ",
        d.upper_limit
    )

    println(
        "="^60
    )
end


# ============================================================
# EVENT REPORT
# ============================================================

function print_events(
    system::DigitalPulleySystem
)

    println()
    println(
        "="^70
    )

    println(
        "                 EVENT LOG"
    )

    println(
        "="^70
    )

    for event in
        system.eventlog.events

        println(
            event.timestamp,
            " | ",
            event.event,
            " | ",
            event.message
        )
    end

    println(
        "="^70
    )
end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println()
    println(
        "DIGITAL ROPE PULLEY"
    )

    println(
        "Pure Julia mechanical simulation"
    )

    println()

    config =
        PulleyConfig(
            mechanical_advantage=2,
            maximum_load_kg=100.0,
            maximum_rope_tension_N=1500.0,
            maximum_velocity_mps=0.75,
            maximum_acceleration_mps2=1.5,
            upper_limit_m=2.0
        )

    load =
        WeightedLoad(
            50.0;
            position_m=0.10
        )

    counterweight =
        Counterweight(
            10.0
        )

    system =
        DigitalPulleySystem(
            config,
            load,
            counterweight,
            10.0
        )

    # ----------------------------------------
    # Start system
    # ----------------------------------------

    enable!(
        system
    )

    # ----------------------------------------
    # Move load
    # ----------------------------------------

    set_target_position!(
        system,
        1.50
    )

    history =
        simulate!(
            system,
            5.0;
            dt=0.002
        )

    println()

    println(
        "Simulation samples: ",
        length(history)
    )

    print_diagnostics(
        system
    )

    print_events(
        system
    )

    return history
end


# ============================================================
# EXPORTS
# ============================================================

export PulleyConfig
export WeightedLoad
export Counterweight
export RopeState
export DriveState
export SensorState
export DigitalPulleySystem
export SystemState

export enable!
export reset_system!
export emergency_stop!

export set_target_position!
export position_control!

export calculate_tension
export required_input_force
export required_drive_torque

export simulate_step!
export simulate!

export diagnostics
export print_diagnostics
export print_events

export potential_energy
export kinetic_energy
export total_load_energy
export mechanical_power

export demo


end # module DigitalRopePulley


# ============================================================
# RUN DEMO
# ============================================================

if abspath(PROGRAM_FILE) == @__FILE__

    using .DigitalRopePulley

    DigitalRopePulley.demo()

end
