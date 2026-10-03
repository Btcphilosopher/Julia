```julia
module AppleRetailDemo

using Dates
using Statistics
using UUIDs

# ============================================================
# DEVICE TYPES
# ============================================================

@enum DeviceType begin
    iPhone
    iPad
    Mac
    AppleWatch
    AppleVision
    AppleTV
end


@enum DemoState begin
    BOOTING
    READY
    DEMONSTRATING
    IDLE
    RESETTING
    ERROR_STATE
    OFFLINE
end


@enum DemoExperience begin
    GENERAL
    CAMERA
    DISPLAY
    PERFORMANCE
    GAMING
    AUDIO
    ACCESSIBILITY
    AI
    ECOSYSTEM
    PRODUCTIVITY
end


@enum ContentPriority begin
    LOW
    NORMAL
    HIGH
    CRITICAL
end


# ============================================================
# DEVICE MODEL
# ============================================================

mutable struct DemoDevice

    id::UUID

    serial::String
    name::String

    device_type::DeviceType

    model::String
    os_version::String

    state::DemoState

    battery::Float64
    temperature::Float64

    cpu_load::Float64
    memory_pressure::Float64

    display_brightness::Float64

    last_interaction::DateTime
    last_reset::DateTime
    last_health_check::DateTime

    demo_count::Int

    active_experience::Union{Nothing,DemoExperience}

    online::Bool
end


function DemoDevice(
    serial::String,
    name::String,
    device_type::DeviceType;
    model="Unknown",
    os_version="Unknown"
)

    return DemoDevice(

        uuid4(),

        serial,
        name,

        device_type,

        model,
        os_version,

        BOOTING,

        100.0,
        25.0,

        0.0,
        0.0,

        0.75,

        now(),
        now(),
        now(),

        0,

        nothing,

        true
    )
end


# ============================================================
# DEMO CONTENT
# ============================================================

struct DemoContent

    id::UUID

    title::String
    description::String

    experience::DemoExperience

    duration_seconds::Int

    priority::ContentPriority

    compatible_devices::Vector{DeviceType}

    asset_identifier::String

    enabled::Bool
end


function DemoContent(
    title,
    description,
    experience,
    duration_seconds;
    priority=NORMAL,
    compatible_devices=DeviceType[
        iPhone,
        iPad,
        Mac,
        AppleWatch,
        AppleVision,
        AppleTV
    ],
    asset_identifier=""
)

    return DemoContent(

        uuid4(),

        title,
        description,

        experience,

        duration_seconds,

        priority,

        compatible_devices,

        asset_identifier,

        true
    )
end


# ============================================================
# DEMO SESSION
# ============================================================

mutable struct DemoSession

    id::UUID

    device_id::UUID
    content_id::UUID

    started_at::DateTime
    ended_at::Union{Nothing,DateTime}

    interactions::Int

    completed::Bool
end


function start_session(
    device::DemoDevice,
    content::DemoContent
)

    device.state = DEMONSTRATING

    device.active_experience =
        content.experience

    device.last_interaction = now()

    device.demo_count += 1

    return DemoSession(

        uuid4(),

        device.id,
        content.id,

        now(),
        nothing,

        0,

        false
    )
end


function end_session!(
    session::DemoSession,
    device::DemoDevice
)

    session.ended_at = now()
    session.completed = true

    device.active_experience = nothing
    device.state = READY

    return session
end


# ============================================================
# DEVICE HEALTH
# ============================================================

struct DeviceHealth

    battery_score::Float64
    thermal_score::Float64
    cpu_score::Float64
    memory_score::Float64

    overall_score::Float64

    recommended_action::Symbol
end


function clamp01(x)

    return clamp(x, 0.0, 1.0)

end


function battery_score(device::DemoDevice)

    return clamp01(device.battery / 100)

end


function thermal_score(device::DemoDevice)

    # Comfortable demo temperature:
    # approximately 20–35 °C.

    if device.temperature <= 35

        return 1.0

    elseif device.temperature <= 45

        return 1.0 -
               (device.temperature - 35) / 20

    else

        return 0.2
    end
end


function cpu_score(device::DemoDevice)

    return clamp01(
        1.0 - device.cpu_load
    )
end


function memory_score(device::DemoDevice)

    return clamp01(
        1.0 - device.memory_pressure
    )
end


function health(device::DemoDevice)

    b = battery_score(device)
    t = thermal_score(device)
    c = cpu_score(device)
    m = memory_score(device)

    overall =
        0.35*b +
        0.30*t +
        0.15*c +
        0.20*m

    action =
        if overall > 0.85
            :continue
        elseif overall > 0.65
            :monitor
        elseif overall > 0.45
            :cool
        else
            :reset
        end

    return DeviceHealth(
        b,
        t,
        c,
        m,
        overall,
        action
    )
end


# ============================================================
# DEMO POLICY
# ============================================================

struct DemoPolicy

    inactivity_timeout::Int

    maximum_session::Int

    minimum_battery::Float64

    maximum_temperature::Float64

    reset_after_sessions::Int

    reset_after_minutes::Int

    health_check_interval::Int
end


function default_policy()

    return DemoPolicy(

        90,       # inactivity
        600,      # max session

        20.0,     # battery

        42.0,     # temperature

        50,       # sessions

        180,      # minutes

        30        # health check
    )
end


# ============================================================
# DEMO SCHEDULER
# ============================================================

mutable struct DemoScheduler

    queue::Vector{DemoContent}

end


DemoScheduler() =
    DemoScheduler(DemoContent[])


function add_content!(
    scheduler::DemoScheduler,
    content::DemoContent
)

    push!(
        scheduler.queue,
        content
    )

    sort!(
        scheduler.queue,
        by = x -> Int(x.priority),
        rev = true
    )

    return scheduler
end


function compatible_content(
    device::DemoDevice,
    scheduler::DemoScheduler
)

    return [

        content

        for content in scheduler.queue

        if content.enabled &&
           device.device_type in
           content.compatible_devices

    ]
end


function next_demo(
    device::DemoDevice,
    scheduler::DemoScheduler
)

    available =
        compatible_content(
            device,
            scheduler
        )

    isempty(available) &&
        return nothing

    return first(available)
end


# ============================================================
# INACTIVITY ENGINE
# ============================================================

function idle_seconds(
    device::DemoDevice
)

    return Dates.value(
        now() - device.last_interaction
    ) / 1000
end


function should_return_to_demo(
    device::DemoDevice,
    policy::DemoPolicy
)

    return idle_seconds(device) >=
           policy.inactivity_timeout
end


function register_interaction!(
    device::DemoDevice
)

    device.last_interaction = now()

    if device.state == IDLE

        device.state = READY

    end

    return nothing
end


# ============================================================
# RESET ENGINE
# ============================================================

struct ResetDecision

    required::Bool
    reason::Symbol
    urgency::Int
end


function reset_decision(
    device::DemoDevice,
    policy::DemoPolicy
)

    if !device.online

        return ResetDecision(
            true,
            :offline,
            100
        )
    end

    if device.battery <
       policy.minimum_battery

        return ResetDecision(
            true,
            :low_battery,
            90
        )
    end

    if device.temperature >
       policy.maximum_temperature

        return ResetDecision(
            true,
            :thermal,
            100
        )
    end

    if device.demo_count >=
       policy.reset_after_sessions

        return ResetDecision(
            true,
            :session_limit,
            70
        )
    end

    minutes =
        Dates.value(
            now() - device.last_reset
        ) / 60000

    if minutes >=
       policy.reset_after_minutes

        return ResetDecision(
            true,
            :time_limit,
            60
        )
    end

    return ResetDecision(
        false,
        :none,
        0
    )
end


function reset_device!(
    device::DemoDevice
)

    device.state = RESETTING

    device.active_experience = nothing

    # In a real implementation Swift would
    # execute the approved reset operation.

    device.demo_count = 0

    device.last_reset = now()
    device.last_interaction = now()

    device.state = READY

    return true
end


# ============================================================
# CONTENT ROTATION
# ============================================================

mutable struct ContentRotation

    index::Int

    last_rotation::DateTime

    interval_seconds::Int
end


function ContentRotation(
    interval_seconds=300
)

    return ContentRotation(
        1,
        now(),
        interval_seconds
    )
end


function rotate!(
    rotation::ContentRotation,
    content::Vector{DemoContent}
)

    isempty(content) &&
        return nothing

    rotation.index += 1

    if rotation.index > length(content)

        rotation.index = 1

    end

    rotation.last_rotation = now()

    return content[rotation.index]
end


# ============================================================
# MULTI-DEVICE STORE
# ============================================================

mutable struct RetailStore

    name::String

    devices::Dict{UUID,DemoDevice}

    content::DemoScheduler

    policy::DemoPolicy
end


function RetailStore(
    name::String
)

    return RetailStore(

        name,

        Dict{UUID,DemoDevice}(),

        DemoScheduler(),

        default_policy()
    )
end


function register_device!(
    store::RetailStore,
    device::DemoDevice
)

    store.devices[device.id] = device

    device.state = READY

    return device.id
end


function remove_device!(
    store::RetailStore,
    id::UUID
)

    pop!(
        store.devices,
        id,
        nothing
    )

    return nothing
end


# ============================================================
# STORE HEALTH
# ============================================================

struct StoreHealth

    device_count::Int

    online_count::Int

    average_health::Float64

    thermal_warnings::Int

    battery_warnings::Int

    reset_required::Int
end


function store_health(
    store::RetailStore
)

    devices =
        collect(
            values(store.devices)
        )

    isempty(devices) &&
        return StoreHealth(
            0, 0, 0, 0, 0, 0
        )

    health_values =
        health.(devices)

    average =
        mean(
            x.overall_score
            for x in health_values
        )

    thermal =
        count(
            d -> d.temperature >
                  store.policy.maximum_temperature,
            devices
        )

    battery =
        count(
            d -> d.battery <
                  store.policy.minimum_battery,
            devices
        )

    resets =
        count(
            d -> reset_decision(
                d,
                store.policy
            ).required,
            devices
        )

    online =
        count(
            d -> d.online,
            devices
        )

    return StoreHealth(

        length(devices),

        online,

        average,

        thermal,

        battery,

        resets
    )
end


# ============================================================
# EXPERIENCE ENGINE
# ============================================================

struct ExperienceRecommendation

    device_id::UUID

    content_id::Union{Nothing,UUID}

    reason::Symbol

    priority::Int
end


function recommend_experience(
    device::DemoDevice,
    scheduler::DemoScheduler
)

    h = health(device)

    if h.recommended_action == :reset

        return ExperienceRecommendation(
            device.id,
            nothing,
            :device_needs_reset,
            100
        )
    end

    content =
        next_demo(
            device,
            scheduler
        )

    if content === nothing

        return ExperienceRecommendation(
            device.id,
            nothing,
            :no_content,
            0
        )
    end

    reason =
        device.state == READY ?
        :ready_for_demo :
        :rotate_content

    return ExperienceRecommendation(
        device.id,
        content.id,
        reason,
        Int(content.priority)
    )
end


# ============================================================
# TELEMETRY
# ============================================================

struct TelemetryPoint

    timestamp::DateTime

    battery::Float64
    temperature::Float64

    cpu_load::Float64
    memory_pressure::Float64

    interaction::Bool
end


mutable struct TelemetryDatabase

    points::Dict{UUID,Vector{TelemetryPoint}}
end


TelemetryDatabase() =
    TelemetryDatabase(
        Dict{UUID,Vector{TelemetryPoint}}()
    )


function record!(
    db::TelemetryDatabase,
    device::DemoDevice;
    interaction=false
)

    point =
        TelemetryPoint(

            now(),

            device.battery,
            device.temperature,

            device.cpu_load,
            device.memory_pressure,

            interaction
        )

    if !haskey(
        db.points,
        device.id
    )

        db.points[device.id] =
            TelemetryPoint[]
    end

    push!(
        db.points[device.id],
        point
    )

    device.last_health_check = now()

    return point
end


# ============================================================
# DEMO DIGITAL TWIN
# ============================================================

mutable struct DeviceTwin

    device_id::UUID

    expected_battery::Float64
    expected_temperature::Float64

    expected_cpu::Float64
    expected_memory::Float64

    anomaly_score::Float64
end


function create_twin(
    device::DemoDevice
)

    return DeviceTwin(

        device.id,

        device.battery,
        device.temperature,

        device.cpu_load,
        device.memory_pressure,

        0.0
    )
end


function update_twin!(
    twin::DeviceTwin,
    device::DemoDevice
)

    deviations = [

        abs(
            device.battery -
            twin.expected_battery
        ) / 100,

        abs(
            device.temperature -
            twin.expected_temperature
        ) / 50,

        abs(
            device.cpu_load -
            twin.expected_cpu
        ),

        abs(
            device.memory_pressure -
            twin.expected_memory
        )
    ]

    twin.anomaly_score =
        mean(deviations)

    return twin
end


# ============================================================
# STORE DEMO CONTROLLER
# ============================================================

mutable struct DemoController

    store::RetailStore

    telemetry::TelemetryDatabase

    twins::Dict{UUID,DeviceTwin}
end


function DemoController(
    store::RetailStore
)

    return DemoController(

        store,

        TelemetryDatabase(),

        Dict{UUID,DeviceTwin}()
    )
end


function initialise!(
    controller::DemoController
)

    for device in
        values(controller.store.devices)

        controller.twins[device.id] =
            create_twin(device)

        device.state = READY
    end

    return controller
end


function tick!(
    controller::DemoController
)

    store = controller.store

    for device in
        values(store.devices)

        # ------------------------------------------------
        # Telemetry
        # ------------------------------------------------

        record!(
            controller.telemetry,
            device
        )

        # ------------------------------------------------
        # Digital twin
        # ------------------------------------------------

        twin =
            controller.twins[device.id]

        update_twin!(
            twin,
            device
        )

        # ------------------------------------------------
        # Health
        # ------------------------------------------------

        h =
            health(device)

        # ------------------------------------------------
        # Thermal protection
        # ------------------------------------------------

        if h.recommended_action == :cool

            device.state = IDLE

        elseif h.recommended_action == :reset

            decision =
                reset_decision(
                    device,
                    store.policy
                )

            if decision.required

                reset_device!(
                    device
                )
            end
        end

        # ------------------------------------------------
        # Inactivity
        # ------------------------------------------------

        if should_return_to_demo(
            device,
            store.policy
        )

            if device.state == READY

                device.state = IDLE
            end
        end
    end

    return nothing
end


# ============================================================
# DASHBOARD DATA
# ============================================================

struct DeviceDashboardRow

    id::UUID
    name::String
    type::DeviceType

    state::DemoState

    battery::Float64
    temperature::Float64

    health::Float64
    anomaly::Float64
end


function dashboard(
    controller::DemoController
)

    rows = DeviceDashboardRow[]

    for device in
        values(controller.store.devices)

        h =
            health(device)

        twin =
            controller.twins[device.id]

        push!(
            rows,

            DeviceDashboardRow(

                device.id,

                device.name,
                device.device_type,

                device.state,

                device.battery,
                device.temperature,

                h.overall_score,
                twin.anomaly_score
            )
        )
    end

    return rows
end


# ============================================================
# DEMO STORE SIMULATOR
# ============================================================

function example_store()

    store =
        RetailStore(
            "Apple Store Demo Environment"
        )

    # --------------------------------------------------------
    # Devices
    # --------------------------------------------------------

    iphone =
        DemoDevice(
            "DEMO-IP-001",
            "iPhone Display 01",
            iPhone;
            model="iPhone",
            os_version="iOS"
        )

    ipad =
        DemoDevice(
            "DEMO-IPAD-001",
            "iPad Display 01",
            iPad;
            model="iPad",
            os_version="iPadOS"
        )

    mac =
        DemoDevice(
            "DEMO-MAC-001",
            "Mac Display 01",
            Mac;
            model="Mac",
            os_version="macOS"
        )

    watch =
        DemoDevice(
            "DEMO-WATCH-001",
            "Apple Watch Display 01",
            AppleWatch;
            model="Apple Watch",
            os_version="watchOS"
        )

    register_device!(
        store,
        iphone
    )

    register_device!(
        store,
        ipad
    )

    register_device!(
        store,
        mac
    )

    register_device!(
        store,
        watch
    )

    # --------------------------------------------------------
    # Demo experiences
    # --------------------------------------------------------

    add_content!(
        store.content,

        DemoContent(
            "Camera Experience",
            "Demonstrate computational photography.",
            CAMERA,
            180;
            priority=HIGH,
            compatible_devices=[
                iPhone,
                iPad
            ]
        )
    )

    add_content!(
        store.content,

        DemoContent(
            "Display Experience",
            "Demonstrate colour, HDR and motion.",
            DISPLAY,
            120;
            priority=HIGH
        )
    )

    add_content!(
        store.content,

        DemoContent(
            "Performance Experience",
            "Demonstrate CPU/GPU performance.",
            PERFORMANCE,
            240;
            priority=NORMAL,
            compatible_devices=[
                iPhone,
                iPad,
                Mac
            ]
        )
    )

    add_content!(
        store.content,

        DemoContent(
            "Accessibility Experience",
            "Demonstrate accessibility features.",
            ACCESSIBILITY,
            180;
            priority=NORMAL
        )
    )

    add_content!(
        store.content,

        DemoContent(
            "Apple Ecosystem",
            "Demonstrate continuity between devices.",
            ECOSYSTEM,
            300;
            priority=HIGH,
            compatible_devices=[
                iPhone,
                iPad,
                Mac,
                AppleWatch
            ]
        )
    )

    return store
end


# ============================================================
# DEMO
# ============================================================

function demo()

    store =
        example_store()

    controller =
        DemoController(store)

    initialise!(
        controller
    )

    println()
    println("========================================")
    println(" APPLE RETAIL DEMO INTELLIGENCE")
    println("========================================")

    println()

    println(
        "Devices: ",
        length(store.devices)
    )

    println(
        "Content: ",
        length(store.content.queue)
    )

    println()

    # Run simulated control cycles.

    for cycle in 1:5

        println(
            "Control cycle ",
            cycle
        )

        tick!(
            controller
        )

        for row in
            dashboard(controller)

            println(

                row.name,
                " | ",
                row.state,
                " | Battery ",
                round(row.battery, digits=1),
                "% | Temp ",
                round(row.temperature, digits=1),
                "°C | Health ",
                round(
                    row.health * 100,
                    digits=1
                ),
                "%"
            )
        end

        println()
    end

    # Store-level health.

    sh =
        store_health(store)

    println(
        "STORE HEALTH"
    )

    println(
        "Devices: ",
        sh.device_count
    )

    println(
        "Online: ",
        sh.online_count
    )

    println(
        "Average health: ",
        round(
            sh.average_health * 100,
            digits=1
        ),
        "%"
    )

    println(
        "Thermal warnings: ",
        sh.thermal_warnings
    )

    println(
        "Battery warnings: ",
        sh.battery_warnings
    )

    println(
        "Resets required: ",
        sh.reset_required
    )

    return controller
end


export
    DeviceType,
    DemoState,
    DemoExperience,
    ContentPriority,

    DemoDevice,
    DemoContent,
    DemoSession,

    DemoPolicy,
    DemoScheduler,

    RetailStore,
    DemoController,

    DeviceHealth,
    StoreHealth,

    DeviceTwin,
    TelemetryDatabase,

    register_device!,
    add_content!,
    start_session,
    end_session!,
    record_interaction!,
    reset_device!,

    health,
    store_health,
    dashboard,

    initialise!,
    tick!,

    example_store,
    demo


end # module
```


