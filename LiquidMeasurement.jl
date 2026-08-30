module LiquidMeasurement

using Statistics
using Printf

# ============================================================
# LIQUID MEASUREMENT / TANK GAUGING ENGINE
# Pure Julia
#
# Features:
#   - Tank level measurement
#   - Volume calculation
#   - Cylindrical / rectangular tanks
#   - Hydrostatic level measurement
#   - Ultrasonic / radar-style measurement simulation
#   - 4-20 mA signal conversion
#   - Sensor calibration
#   - Moving-average filtering
#   - Exponential filtering
#   - Density compensation
#   - Flow-rate measurement
#   - Totalised volume
#   - High / low alarms
#   - Rate-of-change alarms
#   - Sensor fault detection
#   - Measurement confidence
#   - Digital twin simulation
#
# This is simulation / supervisory software.
# Real instrumentation requires validated hardware,
# calibration procedures and safety systems.
# ============================================================


# ============================================================
# ENUMS
# ============================================================

@enum TankGeometry begin
    CYLINDRICAL
    RECTANGULAR
end

@enum SensorType begin
    RADAR
    ULTRASONIC
    HYDROSTATIC
    FLOAT
end

@enum SensorState begin
    SENSOR_OK
    SENSOR_WARNING
    SENSOR_FAULT
end


# ============================================================
# TANK
# ============================================================

mutable struct Tank

    name::Symbol

    geometry::TankGeometry

    height_m::Float64

    diameter_m::Float64

    length_m::Float64
    width_m::Float64

    level_m::Float64

    density_kg_m3::Float64

    temperature_c::Float64

    volume_m3::Float64
end


# ============================================================
# SENSOR
# ============================================================

mutable struct LevelSensor

    name::Symbol

    sensor_type::SensorType

    range_min_m::Float64
    range_max_m::Float64

    accuracy_m::Float64

    noise_std_m::Float64

    offset_m::Float64

    gain::Float64

    state::SensorState

    signal_ma::Float64

    raw_level_m::Float64
    filtered_level_m::Float64

    last_level_m::Float64

    confidence::Float64

    fault_code::Symbol
end


# ============================================================
# FLOW SENSOR
# ============================================================

mutable struct FlowSensor

    name::Symbol

    range_min_m3_h::Float64
    range_max_m3_h::Float64

    accuracy_fraction::Float64

    noise_std_m3_h::Float64

    flow_m3_h::Float64

    filtered_flow_m3_h::Float64

    totalised_m3::Float64

    signal_ma::Float64

    state::SensorState
end


# ============================================================
# MEASUREMENT FILTER
# ============================================================

mutable struct Filter

    window_size::Int

    samples::Vector{Float64}

    alpha::Float64

    moving_average::Float64

    exponential_average::Float64
end


# ============================================================
# ALARM LIMITS
# ============================================================

mutable struct AlarmLimits

    high_level_m::Float64
    high_high_level_m::Float64

    low_level_m::Float64
    low_low_level_m::Float64

    maximum_rate_m_h::Float64

    alarms::Vector{Symbol}
end


# ============================================================
# MEASUREMENT SYSTEM
# ============================================================

mutable struct MeasurementSystem

    tank::Tank

    level_sensor::LevelSensor

    flow_sensor::FlowSensor

    level_filter::Filter

    flow_filter::Filter

    alarms::AlarmLimits

    elapsed_h::Float64

    measured_volume_m3::Float64

    measurement_error_m::Float64

    measurement_confidence::Float64
end


# ============================================================
# TANK GEOMETRY
# ============================================================

function tank_area(
    tank::Tank
)

    if tank.geometry ==
       CYLINDRICAL

        return π *
               (tank.diameter_m / 2)^2

    elseif tank.geometry ==
           RECTANGULAR

        return tank.length_m *
               tank.width_m
    end

    return 0.0
end


function calculate_volume(
    tank::Tank,
    level_m::Float64
)

    level =
        clamp(
            level_m,
            0.0,
            tank.height_m
        )

    if tank.geometry ==
       CYLINDRICAL

        return π *
               (tank.diameter_m / 2)^2 *
               level

    elseif tank.geometry ==
           RECTANGULAR

        return tank.length_m *
               tank.width_m *
               level
    end

    return 0.0
end


function update_volume!(
    tank::Tank
)

    tank.volume_m3 =
        calculate_volume(
            tank,
            tank.level_m
        )

    return tank.volume_m3
end


# ============================================================
# TANK CONSTRUCTION
# ============================================================

function create_cylindrical_tank(
    name;
    height_m=10.0,
    diameter_m=5.0,
    level_m=5.0,
    density_kg_m3=1000.0,
    temperature_c=20.0
)

    tank =
        Tank(

            name,

            CYLINDRICAL,

            height_m,

            diameter_m,

            0.0,
            0.0,

            level_m,

            density_kg_m3,

            temperature_c,

            0.0
        )

    update_volume!(
        tank
    )

    return tank
end


function create_rectangular_tank(
    name;
    height_m=5.0,
    length_m=10.0,
    width_m=8.0,
    level_m=2.5,
    density_kg_m3=1000.0,
    temperature_c=20.0
)

    tank =
        Tank(

            name,

            RECTANGULAR,

            height_m,

            0.0,

            length_m,
            width_m,

            level_m,

            density_kg_m3,

            temperature_c,

            0.0
        )

    update_volume!(
        tank
    )

    return tank
end


# ============================================================
# SENSOR CONSTRUCTION
# ============================================================

function create_level_sensor(
    name,
    sensor_type;
    range_min_m=0.0,
    range_max_m=10.0,
    accuracy_m=0.005,
    noise_std_m=0.002
)

    LevelSensor(

        name,

        sensor_type,

        range_min_m,
        range_max_m,

        accuracy_m,

        noise_std_m,

        0.0,
        1.0,

        SENSOR_OK,

        4.0,

        0.0,
        0.0,

        0.0,

        1.0,

        :NONE
    )
end


function create_flow_sensor(
    name;
    range_min_m3_h=0.0,
    range_max_m3_h=1000.0
)

    FlowSensor(

        name,

        range_min_m3_h,
        range_max_m3_h,

        0.01,

        1.0,

        0.0,
        0.0,

        0.0,

        4.0,

        SENSOR_OK
    )
end


# ============================================================
# FILTER
# ============================================================

function create_filter(
    window_size=10;
    alpha=0.2
)

    Filter(

        window_size,

        Float64[],

        alpha,

        0.0,

        0.0
    )
end


function filter_value!(
    filter::Filter,
    value::Float64
)

    push!(
        filter.samples,
        value
    )

    if length(
        filter.samples
    ) > filter.window_size

        popfirst!(
            filter.samples
        )
    end

    filter.moving_average =
        mean(
            filter.samples
        )

    if filter.exponential_average == 0.0

        filter.exponential_average =
            value

    else

        filter.exponential_average =
            filter.alpha * value +
            (1.0 - filter.alpha) *
            filter.exponential_average
    end

    return filter.exponential_average
end


# ============================================================
# HYDROSTATIC MEASUREMENT
# ============================================================

function pressure_from_level(
    level_m,
    density_kg_m3;
    g=9.80665
)

    return (
        density_kg_m3 *
        g *
        level_m
    )
end


function level_from_pressure(
    pressure_pa,
    density_kg_m3;
    g=9.80665
)

    return pressure_pa /
           (
               density_kg_m3 *
               g
           )
end


# ============================================================
# SENSOR SIMULATION
# ============================================================

function measure_level!(
    sensor::LevelSensor,
    tank::Tank
)

    true_level =
        tank.level_m

    noise =
        randn() *
        sensor.noise_std_m

    measured =
        true_level +
        sensor.offset_m +
        noise

    measured =
        sensor.gain *
        measured

    if sensor.sensor_type ==
       HYDROSTATIC

        pressure =
            pressure_from_level(
                true_level,
                tank.density_kg_m3
            )

        measured =
            level_from_pressure(
                pressure,
                tank.density_kg_m3
            ) +
            sensor.offset_m +
            noise
    end

    if measured <
       sensor.range_min_m ||
       measured >
       sensor.range_max_m

        sensor.state =
            SENSOR_FAULT

        sensor.fault_code =
            :OUT_OF_RANGE

        sensor.confidence =
            0.0

    else

        sensor.state =
            SENSOR_OK

        sensor.fault_code =
            :NONE

        sensor.confidence =
            1.0
    end

    sensor.last_level_m =
        sensor.raw_level_m

    sensor.raw_level_m =
        measured

    sensor.signal_ma =
        level_to_4_20ma(
            measured,
            sensor.range_min_m,
            sensor.range_max_m
        )

    return measured
end


# ============================================================
# 4-20mA
# ============================================================

function level_to_4_20ma(
    level,
    minimum,
    maximum
)

    fraction =
        (level - minimum) /
        max(
            maximum - minimum,
            1e-9
        )

    fraction =
        clamp(
            fraction,
            0.0,
            1.0
        )

    return 4.0 +
           16.0 *
           fraction
end


function ma_to_level(
    current_ma,
    minimum,
    maximum
)

    fraction =
        (
            current_ma -
            4.0
        ) / 16.0

    fraction =
        clamp(
            fraction,
            0.0,
            1.0
        )

    return minimum +
           fraction *
           (
               maximum -
               minimum
           )
end


# ============================================================
# FLOW MEASUREMENT
# ============================================================

function measure_flow!(
    sensor::FlowSensor,
    true_flow::Float64,
    dt_h::Float64
)

    noise =
        randn() *
        sensor.noise_std_m3_h

    measured =
        true_flow *
        (
            1.0 +
            sensor.accuracy_fraction *
            randn()
        ) +
        noise

    measured =
        max(
            measured,
            0.0
        )

    if measured >
       sensor.range_max_m3_h

        sensor.state =
            SENSOR_FAULT

        return
    end

    sensor.state =
        SENSOR_OK

    sensor.flow_m3_h =
        measured

    sensor.signal_ma =
        4.0 +
        16.0 *
        (
            measured -
            sensor.range_min_m3_h
        ) /
        max(
            sensor.range_max_m3_h -
            sensor.range_min_m3_h,
            1e-9
        )

    sensor.totalised_m3 +=
        measured *
        dt_h

    return measured
end


# ============================================================
# CALIBRATION
# ============================================================

function calibrate_level_sensor!(
    sensor::LevelSensor,
    reference_level_m::Float64,
    observed_level_m::Float64
)

    sensor.offset_m =
        reference_level_m -
        observed_level_m

    return sensor
end


function two_point_calibration!(
    sensor::LevelSensor,
    reference_low::Float64,
    observed_low::Float64,
    reference_high::Float64,
    observed_high::Float64
)

    observed_span =
        observed_high -
        observed_low

    reference_span =
        reference_high -
        reference_low

    sensor.gain =
        reference_span /
        max(
            observed_span,
            1e-9
        )

    sensor.offset_m =
        reference_low -
        sensor.gain *
        observed_low

    return sensor
end


# ============================================================
# ALARMS
# ============================================================

function create_alarm_limits(
    tank::Tank
)

    AlarmLimits(

        tank.height_m * 0.90,

        tank.height_m * 0.95,

        tank.height_m * 0.10,

        tank.height_m * 0.05,

        tank.height_m * 0.20,

        Symbol[]
    )
end


function check_alarms!(
    system::MeasurementSystem
)

    empty!(
        system.alarms.alarms
    )

    level =
        system.level_sensor.filtered_level_m

    previous =
        system.level_sensor.last_level_m

    rate =
        abs(
            level -
            previous
        ) /
        max(
            1.0 / 3600.0,
            1e-9
        )

    if level >=
       system.alarms.high_high_level_m

        push!(
            system.alarms.alarms,
            :HIGH_HIGH_LEVEL
        )

    elseif level >=
           system.alarms.high_level_m

        push!(
            system.alarms.alarms,
            :HIGH_LEVEL
        )
    end

    if level <=
       system.alarms.low_low_level_m

        push!(
            system.alarms.alarms,
            :LOW_LOW_LEVEL
        )

    elseif level <=
           system.alarms.low_level_m

        push!(
            system.alarms.alarms,
            :LOW_LEVEL
        )
    end

    if rate >
       system.alarms.maximum_rate_m_h

        push!(
            system.alarms.alarms,
            :RAPID_LEVEL_CHANGE
        )
    end

    if system.level_sensor.state ==
       SENSOR_FAULT

        push!(
            system.alarms.alarms,
            :LEVEL_SENSOR_FAULT
        )
    end

    if system.flow_sensor.state ==
       SENSOR_FAULT

        push!(
            system.alarms.alarms,
            :FLOW_SENSOR_FAULT
        )
    end

    return system.alarms.alarms
end


# ============================================================
# SYSTEM CONSTRUCTION
# ============================================================

function create_system(
    tank::Tank
)

    level_sensor =
        create_level_sensor(
            :LEVEL_SENSOR,
            RADAR;

            range_min_m=0.0,
            range_max_m=tank.height_m,

            accuracy_m=0.005,
            noise_std_m=0.002
        )

    flow_sensor =
        create_flow_sensor(
            :FLOW_SENSOR;

            range_min_m3_h=0.0,
            range_max_m3_h=2000.0
        )

    MeasurementSystem(

        tank,

        level_sensor,

        flow_sensor,

        create_filter(
            10;
            alpha=0.15
        ),

        create_filter(
            10;
            alpha=0.20
        ),

        create_alarm_limits(
            tank
        ),

        0.0,

        tank.volume_m3,

        0.0,

        1.0
    )
end


# ============================================================
# MEASUREMENT UPDATE
# ============================================================

function update!(
    system::MeasurementSystem;
    true_flow_m3_h=0.0,
    dt_h=1.0 / 60.0
)

    system.elapsed_h +=
        dt_h

    # --------------------------------------------------------
    # Measure level
    # --------------------------------------------------------

    raw_level =
        measure_level!(
            system.level_sensor,
            system.tank
        )

    filtered_level =
        filter_value!(
            system.level_filter,
            raw_level
        )

    system.level_sensor.filtered_level_m =
        filtered_level

    # --------------------------------------------------------
    # Convert level → volume
    # --------------------------------------------------------

    system.measured_volume_m3 =
        calculate_volume(
            system.tank,
            filtered_level
        )

    # --------------------------------------------------------
    # Flow
    # --------------------------------------------------------

    measured_flow =
        measure_flow!(
            system.flow_sensor,
            true_flow_m3_h,
            dt_h
        )

    if measured_flow !== nothing

        filtered_flow =
            filter_value!(
                system.flow_filter,
                measured_flow
            )

        system.flow_sensor.filtered_flow_m3_h =
            filtered_flow
    end

    # --------------------------------------------------------
    # Measurement error
    # --------------------------------------------------------

    system.measurement_error_m =
        filtered_level -
        system.tank.level_m

    system.measurement_confidence =
        calculate_confidence(
            system
        )

    # --------------------------------------------------------
    # Alarms
    # --------------------------------------------------------

    check_alarms!(
        system
    )

    return system
end


# ============================================================
# CONFIDENCE
# ============================================================

function calculate_confidence(
    system::MeasurementSystem
)

    if system.level_sensor.state ==
       SENSOR_FAULT

        return 0.0
    end

    error =
        abs(
            system.measurement_error_m
        )

    accuracy =
        system.level_sensor.accuracy_m

    confidence =
        exp(
            -error /
            max(
                accuracy,
                1e-6
            )
        )

    return clamp(
        confidence,
        0.0,
        1.0
    )
end


# ============================================================
# INVENTORY MASS
# ============================================================

function liquid_mass(
    system::MeasurementSystem
)

    return system.measured_volume_m3 *
           system.tank.density_kg_m3
end


# ============================================================
# DENSITY COMPENSATION
# ============================================================

function update_density!(
    tank::Tank,
    density_kg_m3::Float64
)

    tank.density_kg_m3 =
        max(
            density_kg_m3,
            0.0
        )
end


# ============================================================
# DIGITAL TWIN
# ============================================================

function simulate_tank!(
    system::MeasurementSystem,
    duration_h::Float64;
    inlet_flow_m3_h=100.0,
    outlet_flow_m3_h=50.0,
    timestep_s=1.0
)

    steps =
        Int(
            ceil(
                duration_h *
                3600.0 /
                timestep_s
            )
        )

    dt_h =
        timestep_s /
        3600.0

    net_flow =
        inlet_flow_m3_h -
        outlet_flow_m3_h

    true_flow =
        inlet_flow_m3_h

    for _ in 1:steps

        system.tank.level_m +=
            (
                net_flow *
                dt_h
            ) /
            tank_area(
                system.tank
            )

        system.tank.level_m =
            clamp(
                system.tank.level_m,
                0.0,
                system.tank.height_m
            )

        update_volume!(
            system.tank
        )

        update!(
            system;
            true_flow_m3_h=true_flow,
            dt_h=dt_h
        )
    end

    return system
end


# ============================================================
# REPORT
# ============================================================

function print_report(
    system::MeasurementSystem
)

    tank =
        system.tank

    sensor =
        system.level_sensor

    flow =
        system.flow_sensor

    println()
    println(
        "=========================================================="
    )

    println(
        "             LIQUID MEASUREMENT SYSTEM"
    )

    println(
        "=========================================================="
    )

    println(
        "Tank:                   ",
        tank.name
    )

    println(
        "Geometry:               ",
        tank.geometry
    )

    @printf(
        "True level:             %.3f m\n",
        tank.level_m
    )

    @printf(
        "Measured level:         %.3f m\n",
        sensor.raw_level_m
    )

    @printf(
        "Filtered level:         %.3f m\n",
        sensor.filtered_level_m
    )

    @printf(
        "Measured volume:        %.3f m³\n",
        system.measured_volume_m3
    )

    @printf(
        "Liquid mass:            %.1f kg\n",
        liquid_mass(system)
    )

    @printf(
        "Density:                %.1f kg/m³\n",
        tank.density_kg_m3
    )

    @printf(
        "Temperature:            %.1f °C\n",
        tank.temperature_c
    )

    println()

    println(
        "LEVEL SENSOR"
    )

    println(
        "Type:                   ",
        sensor.sensor_type
    )

    @printf(
        "4-20 mA signal:         %.3f mA\n",
        sensor.signal_ma
    )

    @printf(
        "Measurement error:      %.5f m\n",
        system.measurement_error_m
    )

    @printf(
        "Confidence:             %.2f %%\n",
        system.measurement_confidence * 100
    )

    println()

    println(
        "FLOW SENSOR"
    )

    @printf(
        "Flow:                   %.2f m³/h\n",
        flow.filtered_flow_m3_h
    )

    @printf(
        "Totalised volume:       %.3f m³\n",
        flow.totalised_m3
    )

    println()

    if isempty(
        system.alarms.alarms
    )

        println(
            "ALARMS:                 NONE"
        )

    else

        println(
            "ALARMS:"
        )

        for alarm in
            system.alarms.alarms

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
# DEMO
# ============================================================

function demo()

    tank =
        create_cylindrical_tank(
            :STORAGE_TANK;

            height_m=12.0,

            diameter_m=8.0,

            level_m=5.0,

            density_kg_m3=998.0,

            temperature_c=18.0
        )

    system =
        create_system(
            tank
        )

    println(
        "Starting liquid measurement simulation..."
    )

    simulate_tank!(
        system,
        2.0;

        inlet_flow_m3_h=120.0,

        outlet_flow_m3_h=50.0,

        timestep_s=1.0
    )

    print_report(
        system
    )

    return system
end


end # module


# ============================================================
# RUN
# ============================================================

using .LiquidMeasurement

LiquidMeasurement.demo()
