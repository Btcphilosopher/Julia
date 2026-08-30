module OilPumpingAutomation

using Printf

# ============================================================
# AUTOMATED OIL PUMPING / PIPELINE SIMULATOR
# Pure Julia
#
# Models:
#   - Storage tanks
#   - Pump stations
#   - Pipeline segments
#   - Flow control
#   - Pressure monitoring
#   - Tank level control
#   - Pump sequencing
#   - Leak detection
#   - Overpressure protection
#   - Emergency shutdown
#   - Automatic restart logic
#   - Energy-aware pump scheduling
#
# This is a supervisory simulation/control model, not
# certified safety-critical machinery control software.
# ============================================================


# ============================================================
# STATES
# ============================================================

@enum PumpState begin
    STOPPED
    STARTING
    RUNNING
    STOPPING
    FAULT
    EMERGENCY_STOP
end

@enum SystemState begin
    OFFLINE
    STARTUP
    OPERATING
    SHUTDOWN
    ALARM
    ESD
end


# ============================================================
# TANK
# ============================================================

mutable struct Tank

    name::Symbol

    capacity_m3::Float64
    level_m3::Float64

    minimum_level_m3::Float64
    maximum_level_m3::Float64

    inlet_flow_m3_h::Float64
    outlet_flow_m3_h::Float64

    temperature_c::Float64

    alarm_high::Bool
    alarm_low::Bool
end


# ============================================================
# PUMP
# ============================================================

mutable struct Pump

    name::Symbol

    state::PumpState

    rated_flow_m3_h::Float64
    rated_head_m::Float64

    speed_percent::Float64

    efficiency::Float64

    suction_pressure_bar::Float64
    discharge_pressure_bar::Float64

    vibration_mm_s::Float64
    temperature_c::Float64

    power_kw::Float64

    starts::Int
    running_hours::Float64

    fault::Symbol
end


# ============================================================
# PIPELINE
# ============================================================

mutable struct Pipeline

    name::Symbol

    length_km::Float64
    diameter_mm::Float64

    roughness_mm::Float64

    inlet_pressure_bar::Float64
    outlet_pressure_bar::Float64

    flow_m3_h::Float64

    maximum_pressure_bar::Float64

    leak_estimate_m3_h::Float64

    pressure_drop_bar::Float64
end


# ============================================================
# VALVE
# ============================================================

mutable struct Valve

    name::Symbol

    opening_percent::Float64

    minimum_opening_percent::Float64
    maximum_opening_percent::Float64

    flow_coefficient::Float64

    failed::Bool
end


# ============================================================
# CONTROLLER
# ============================================================

mutable struct PumpController

    target_flow_m3_h::Float64

    target_pressure_bar::Float64

    flow_tolerance_m3_h::Float64

    pressure_tolerance_bar::Float64

    proportional_gain::Float64

    integral_gain::Float64

    integral_error::Float64

    maximum_speed_percent::Float64

    minimum_speed_percent::Float64
end


# ============================================================
# OIL SYSTEM
# ============================================================

mutable struct OilSystem

    state::SystemState

    source::Tank
    destination::Tank

    pumps::Vector{Pump}

    pipeline::Pipeline

    valve::Valve

    controller::PumpController

    elapsed_hours::Float64

    transferred_m3::Float64

    energy_kwh::Float64

    alarms::Vector{Symbol}

    emergency_stop::Bool
end


# ============================================================
# CONSTRUCTION
# ============================================================

function create_tank(
    name;
    capacity_m3=10000.0,
    initial_level_m3=5000.0
)

    return Tank(

        name,

        capacity_m3,

        initial_level_m3,

        capacity_m3 * 0.10,
        capacity_m3 * 0.90,

        0.0,
        0.0,

        25.0,

        false,
        false
    )
end


function create_pump(
    name;
    rated_flow_m3_h=1000.0,
    rated_head_m=100.0
)

    return Pump(

        name,

        STOPPED,

        rated_flow_m3_h,
        rated_head_m,

        0.0,

        0.82,

        1.0,
        1.0,

        0.0,
        25.0,

        0.0,

        0,
        0.0,

        :NONE
    )
end


function create_pipeline()

    return Pipeline(

        :MAIN_PIPELINE,

        25.0,

        500.0,

        0.045,

        1.0,
        1.0,

        0.0,

        80.0,

        0.0,

        0.0
    )
end


function create_valve()

    return Valve(

        :FLOW_CONTROL,

        50.0,

        5.0,
        100.0,

        1.0,

        false
    )
end


function create_controller(;
    target_flow_m3_h=1200.0,
    target_pressure_bar=35.0
)

    return PumpController(

        target_flow_m3_h,
        target_pressure_bar,

        20.0,
        2.0,

        0.04,
        0.01,

        0.0,

        100.0,
        30.0
    )
end


function create_system()

    source =
        create_tank(
            :SOURCE_TANK;
            capacity_m3=20000.0,
            initial_level_m3=15000.0
        )

    destination =
        create_tank(
            :DESTINATION_TANK;
            capacity_m3=20000.0,
            initial_level_m3=3000.0
        )

    pumps =
        Pump[

            create_pump(
                :PUMP_1;
                rated_flow_m3_h=1000.0
            ),

            create_pump(
                :PUMP_2;
                rated_flow_m3_h=1000.0
            ),

            create_pump(
                :PUMP_3;
                rated_flow_m3_h=1000.0
            )
        ]

    OilSystem(

        OFFLINE,

        source,
        destination,

        pumps,

        create_pipeline(),

        create_valve(),

        create_controller(),

        0.0,

        0.0,

        0.0,

        Symbol[],

        false
    )
end


# ============================================================
# TANK MONITORING
# ============================================================

function update_tank_alarms!(
    tank::Tank
)

    tank.alarm_high =
        tank.level_m3 >=
        tank.maximum_level_m3

    tank.alarm_low =
        tank.level_m3 <=
        tank.minimum_level_m3

end


# ============================================================
# HYDRAULIC MODEL
# ============================================================

function calculate_pressure_drop(
    pipeline::Pipeline,
    flow_m3_h::Float64
)

    # Simplified hydraulic approximation.
    # Not a substitute for a validated hydraulic model.

    flow =
        max(
            flow_m3_h,
            0.0
        )

    diameter_m =
        pipeline.diameter_mm /
        1000.0

    area =
        π *
        diameter_m^2 /
        4.0

    flow_m3_s =
        flow / 3600.0

    velocity =
        flow_m3_s /
        max(area, 1e-9)

    # Simplified resistance coefficient.
    resistance =
        0.0025 *
        pipeline.length_km /
        max(
            diameter_m,
            0.01
        )

    pressure_drop =
        resistance *
        velocity^2

    return pressure_drop
end


# ============================================================
# PUMP CURVE
# ============================================================

function pump_flow(
    pump::Pump
)

    if pump.state != RUNNING &&
       pump.state != STARTING

        return 0.0
    end

    speed =
        pump.speed_percent /
        100.0

    return pump.rated_flow_m3_h *
           speed
end


function pump_pressure(
    pump::Pump
)

    speed =
        pump.speed_percent /
        100.0

    return pump.rated_head_m *
           speed^2 *
           0.0980665
end


# ============================================================
# POWER MODEL
# ============================================================

function pump_power(
    pump::Pump,
    flow_m3_h::Float64,
    pressure_bar::Float64
)

    flow_m3_s =
        flow_m3_h / 3600.0

    pressure_pa =
        pressure_bar *
        100000.0

    hydraulic_power =
        flow_m3_s *
        pressure_pa

    return hydraulic_power /
           max(
               pump.efficiency,
               0.10
           ) /
           1000.0
end


# ============================================================
# PUMP START
# ============================================================

function start_pump!(
    system::OilSystem,
    pump::Pump
)

    if pump.state ==
       FAULT

        return false
    end

    if system.source.alarm_low

        push!(
            system.alarms,
            :SOURCE_LOW_LEVEL
        )

        return false
    end

    if system.destination.alarm_high

        push!(
            system.alarms,
            :DESTINATION_HIGH_LEVEL
        )

        return false
    end

    pump.state =
        STARTING

    pump.speed_percent =
        system.controller.minimum_speed_percent

    pump.starts +=
        1

    return true
end


# ============================================================
# PUMP RAMP
# ============================================================

function ramp_pump!(
    pump::Pump,
    target_speed::Float64,
    dt_hours::Float64
)

    ramp_rate =
        10.0

    if pump.speed_percent <
       target_speed

        pump.speed_percent =
            min(
                target_speed,
                pump.speed_percent +
                ramp_rate *
                dt_hours *
                60.0
            )

    else

        pump.speed_percent =
            max(
                target_speed,
                pump.speed_percent -
                ramp_rate *
                dt_hours *
                60.0
            )
    end

    if pump.speed_percent >=
       30.0

        pump.state =
            RUNNING
    end
end


# ============================================================
# PID-LIKE FLOW CONTROL
# ============================================================

function controller_step!(
    controller::PumpController,
    measured_flow::Float64,
    measured_pressure::Float64,
    dt_hours::Float64
)

    flow_error =
        controller.target_flow_m3_h -
        measured_flow

    pressure_error =
        controller.target_pressure_bar -
        measured_pressure

    error =
        flow_error /
        max(
            controller.target_flow_m3_h,
            1.0
        )

    error +=
        0.15 *
        pressure_error

    controller.integral_error +=
        error *
        dt_hours

    controller.integral_error =
        clamp(
            controller.integral_error,
            -10.0,
            10.0
        )

    adjustment =
        controller.proportional_gain *
        error * 100.0 +

        controller.integral_gain *
        controller.integral_error *
        100.0

    return adjustment
end


# ============================================================
# DETERMINE ACTIVE PUMPS
# ============================================================

function active_pumps(
    system::OilSystem
)

    return [
        p for p in system.pumps
        if p.state == RUNNING ||
           p.state == STARTING
    ]
end


# ============================================================
# FLOW CALCULATION
# ============================================================

function calculate_system_flow!(
    system::OilSystem
)

    pumps =
        active_pumps(
            system
        )

    pump_flow_total =
        sum(
            pump_flow(p)
            for p in pumps
        )

    valve_factor =
        clamp(
            system.valve.opening_percent /
            100.0,
            0.0,
            1.0
        )

    pipeline_flow =
        pump_flow_total *
        valve_factor

    system.pipeline.flow_m3_h =
        pipeline_flow

    system.pipeline.pressure_drop_bar =
        calculate_pressure_drop(
            system.pipeline,
            pipeline_flow
        )

    pump_pressure_total =
        isempty(pumps) ?
        0.0 :
        mean(
            pump_pressure(p)
            for p in pumps
        )

    system.pipeline.inlet_pressure_bar =
        pump_pressure_total

    system.pipeline.outlet_pressure_bar =
        max(
            0.0,
            pump_pressure_total -
            system.pipeline.pressure_drop_bar
        )

    return pipeline_flow
end


# ============================================================
# AUTOMATIC PUMP CONTROL
# ============================================================

function control_pumps!(
    system::OilSystem,
    measured_flow::Float64
)

    active =
        active_pumps(
            system
        )

    measured_pressure =
        system.pipeline.inlet_pressure_bar

    adjustment =
        controller_step!(
            system.controller,
            measured_flow,
            measured_pressure,
            1.0 / 60.0
        )

    target_speed =
        clamp(
            70.0 + adjustment,
            system.controller.minimum_speed_percent,
            system.controller.maximum_speed_percent
        )

    if isempty(active)

        start_pump!(
            system,
            system.pumps[1]
        )

    end

    active =
        active_pumps(
            system
        )

    for pump in active

        if pump.state ==
           STARTING

            ramp_pump!(
                pump,
                target_speed,
                1.0 / 60.0
            )

        else

            pump.speed_percent =
                target_speed
        end
    end

    # Automatic parallel pump staging.
    if measured_flow >
       system.controller.target_flow_m3_h * 1.20

        if length(active) > 1

            # Reduce the speed of secondary pumps.
            for pump in active[2:end]

                pump.speed_percent =
                    max(
                        40.0,
                        pump.speed_percent -
                        5.0
                    )
            end
        end

    elseif measured_flow <
           system.controller.target_flow_m3_h * 0.75

        if length(active) <
           length(system.pumps)

            for pump in system.pumps

                if pump.state ==
                   STOPPED

                    start_pump!(
                        system,
                        pump
                    )

                    break
                end
            end
        end
    end
end


# ============================================================
# LEAK DETECTION
# ============================================================

function detect_leak!(
    system::OilSystem
)

    source_change =
        system.source.outlet_flow_m3_h

    destination_change =
        system.destination.inlet_flow_m3_h

    expected =
        system.pipeline.flow_m3_h

    imbalance =
        abs(
            source_change -
            destination_change
        )

    if imbalance >
       max(
           expected * 0.05,
           5.0
       )

        system.pipeline.leak_estimate_m3_h =
            imbalance

        push!(
            system.alarms,
            :POSSIBLE_LEAK
        )

        return true
    end

    system.pipeline.leak_estimate_m3_h =
        0.0

    return false
end


# ============================================================
# SAFETY CHECK
# ============================================================

function safety_check!(
    system::OilSystem
)

    empty!(
        system.alarms
    )

    update_tank_alarms!(
        system.source
    )

    update_tank_alarms!(
        system.destination
    )

    if system.source.alarm_low

        push!(
            system.alarms,
            :LOW_SOURCE_LEVEL
        )
    end

    if system.destination.alarm_high

        push!(
            system.alarms,
            :HIGH_DESTINATION_LEVEL
        )
    end

    if system.pipeline.inlet_pressure_bar >
       system.pipeline.maximum_pressure_bar

        push!(
            system.alarms,
            :OVERPRESSURE
        )

        return false
    end

    if system.pipeline.outlet_pressure_bar <
       1.0 &&
       system.pipeline.flow_m3_h > 100.0

        push!(
            system.alarms,
            :LOW_DISCHARGE_PRESSURE
        )

        return false
    end

    detect_leak!(
        system
    )

    if :POSSIBLE_LEAK in
       system.alarms

        return false
    end

    return true
end


# ============================================================
# EMERGENCY SHUTDOWN
# ============================================================

function emergency_shutdown!(
    system::OilSystem,
    reason::Symbol
)

    system.emergency_stop =
        true

    system.state =
        ESD

    push!(
        system.alarms,
        reason
    )

    for pump in
        system.pumps

        pump.state =
            EMERGENCY_STOP

        pump.speed_percent =
            0.0

        pump.power_kw =
            0.0
    end

    system.valve.opening_percent =
        0.0

    return system
end


# ============================================================
# NORMAL SHUTDOWN
# ============================================================

function shutdown!(
    system::OilSystem
)

    system.state =
        SHUTDOWN

    for pump in
        system.pumps

        pump.state =
            STOPPING

        pump.speed_percent =
            0.0

        pump.power_kw =
            0.0
    end

    system.valve.opening_percent =
        0.0
end


# ============================================================
# PROCESS UPDATE
# ============================================================

function update!(
    system::OilSystem;
    dt_hours=1.0 / 60.0
)

    if system.state ==
       ESD

        return
    end

    if system.emergency_stop

        emergency_shutdown!(
            system,
            :EMERGENCY_STOP
        )

        return
    end

    flow =
        calculate_system_flow!(
            system
        )

    if system.state ==
       STARTUP

        system.state =
            OPERATING
    end

    if system.state ==
       OPERATING

        control_pumps!(
            system,
            flow
        )
    end

    flow =
        calculate_system_flow!(
            system
        )

    # --------------------------------------------------------
    # Tank mass balance
    # --------------------------------------------------------

    transferred =
        flow *
        dt_hours

    available =
        max(
            0.0,
            system.source.level_m3 -
            system.source.minimum_level_m3
        )

    capacity =
        max(
            0.0,
            system.destination.maximum_level_m3 -
            system.destination.level_m3
        )

    transferred =
        min(
            transferred,
            available,
            capacity
        )

    system.source.level_m3 -=
        transferred

    system.destination.level_m3 +=
        transferred

    system.source.outlet_flow_m3_h =
        flow

    system.destination.inlet_flow_m3_h =
        flow

    system.transferred_m3 +=
        transferred

    system.elapsed_hours +=
        dt_hours

    # --------------------------------------------------------
    # Pump power
    # --------------------------------------------------------

    for pump in
        system.pumps

        if pump.state ==
           RUNNING

            pump.power_kw =
                pump_power(
                    pump,
                    pump_flow(pump),
                    max(
                        system.pipeline.inlet_pressure_bar,
                        0.1
                    )
                )

            pump.running_hours +=
                dt_hours

        else

            pump.power_kw =
                0.0
        end
    end

    total_power =
        sum(
            p.power_kw
            for p in system.pumps
        )

    system.energy_kwh +=
        total_power *
        dt_hours

    # --------------------------------------------------------
    # Safety
    # --------------------------------------------------------

    safe =
        safety_check!(
            system
        )

    if !safe

        emergency_shutdown!(
            system,
            :AUTOMATIC_SAFETY_SHUTDOWN
        )
    end
end


# ============================================================
# START SYSTEM
# ============================================================

function start!(
    system::OilSystem
)

    if system.state != OFFLINE &&
       system.state != SHUTDOWN

        return false
    end

    system.emergency_stop =
        false

    system.state =
        STARTUP

    system.valve.opening_percent =
        25.0

    start_pump!(
        system,
        system.pumps[1]
    )

    return true
end


# ============================================================
# STATUS
# ============================================================

function status(
    system::OilSystem
)

    println()
    println(
        "=========================================================="
    )

    println(
        "             AUTOMATED OIL PUMPING SYSTEM"
    )

    println(
        "=========================================================="
    )

    println(
        "System state:       ",
        system.state
    )

    println(
        "Source tank:        ",
        system.source.level_m3,
        " m³"
    )

    println(
        "Destination tank:   ",
        system.destination.level_m3,
        " m³"
    )

    println(
        "Pipeline flow:      ",
        round(
            system.pipeline.flow_m3_h,
            digits=2
        ),
        " m³/h"
    )

    println(
        "Inlet pressure:     ",
        round(
            system.pipeline.inlet_pressure_bar,
            digits=2
        ),
        " bar"
    )

    println(
        "Outlet pressure:    ",
        round(
            system.pipeline.outlet_pressure_bar,
            digits=2
        ),
        " bar"
    )

    println(
        "Valve position:     ",
        round(
            system.valve.opening_percent,
            digits=1
        ),
        " %"
    )

    println(
        "Transferred:        ",
        round(
            system.transferred_m3,
            digits=2
        ),
        " m³"
    )

    println(
        "Energy consumed:    ",
        round(
            system.energy_kwh,
            digits=2
        ),
        " kWh"
    )

    println()
    println(
        "PUMPS"
    )

    for pump in
        system.pumps

        @printf(
            "%-10s %-15s speed=%6.1f%% flow=%8.1f m³/h power=%8.1f kW\n",
            String(pump.name),
            String(pump.state),
            pump.speed_percent,
            pump_flow(pump),
            pump.power_kw
        )
    end

    println()

    if isempty(system.alarms)

        println(
            "Alarms:             NONE"
        )

    else

        println(
            "Alarms:"
        )

        for alarm in
            unique(system.alarms)

            println(
                "  ⚠ ",
                alarm
            )
        end
    end

    println(
        "=========================================================="
    )
end


# ============================================================
# SIMULATION
# ============================================================

function simulate!(
    system::OilSystem,
    duration_hours::Float64;
    timestep_minutes=1.0
)

    start!(
        system
    )

    steps =
        Int(
            ceil(
                duration_hours *
                60.0 /
                timestep_minutes
            )
        )

    for _ in 1:steps

        update!(
            system;

            dt_hours =
                timestep_minutes /
                60.0
        )

        if system.state ==
           ESD

            break
        end
    end

    return system
end


# ============================================================
# DEMO
# ============================================================

function demo()

    system =
        create_system()

    println(
        "Starting automated oil transfer..."
    )

    simulate!(
        system,
        4.0
    )

    status(
        system
    )

    return system
end


end # module


# ============================================================
# RUN
# ============================================================

using .OilPumpingAutomation

OilPumpingAutomation.demo()
