```julia
module MacBookDiagnosticEngine

using Statistics
using LinearAlgebra
using Dates

# ============================================================
# MacBook Diagnostic Intelligence
#
# Julia is responsible for:
#
#   telemetry normalisation
#   anomaly detection
#   subsystem scoring
#   fault correlation
#   confidence estimation
#   severity classification
#   repair recommendations
#
# It DOES NOT directly repair the machine.
#
# Swift / RecoveryOS should remain responsible for privileged
# operations.
# ============================================================


# ============================================================
# ENUMERATIONS
# ============================================================

@enum Severity begin
    INFO
    NOTICE
    WARNING
    ERROR
    CRITICAL
end

@enum Subsystem begin
    BOOT
    STORAGE
    FILESYSTEM
    CPU
    GPU
    MEMORY
    THERMAL
    BATTERY
    POWER
    NETWORK
    DISPLAY
    AUDIO
    INPUT
    USB
    THUNDERBOLT
    CAMERA
    SECURITY
    OS
    KERNEL
end

@enum FaultType begin
    NONE
    HARDWARE_FAILURE
    HARDWARE_DEGRADATION
    THERMAL_LIMIT
    POWER_ANOMALY
    STORAGE_FAILURE
    FILESYSTEM_CORRUPTION
    MEMORY_ERROR
    GPU_FAILURE
    CPU_INSTABILITY
    BATTERY_DEGRADATION
    NETWORK_FAILURE
    DRIVER_FAILURE
    KERNEL_FAILURE
    BOOT_FAILURE
    SECURITY_ANOMALY
    PERFORMANCE_DEGRADATION
    UNKNOWN
end


# ============================================================
# BASIC TELEMETRY
# ============================================================

struct Measurement
    name::String
    value::Float64
    unit::String
    timestamp::DateTime
end


struct DiagnosticSample
    subsystem::Subsystem
    metric::String
    value::Float64
    timestamp::DateTime
end


# ============================================================
# FINDING
# ============================================================

struct DiagnosticFinding

    subsystem::Subsystem
    severity::Severity
    fault::FaultType

    title::String
    description::String

    confidence::Float64

    metric::String
    observed::Float64
    expected::Float64

    recommendation::String
end


# ============================================================
# MAC SYSTEM SNAPSHOT
# ============================================================

struct SystemSnapshot

    # Boot
    boot_time_seconds::Float64
    boot_failures::Int
    kernel_panics::Int

    # Storage
    storage_total_gb::Float64
    storage_free_gb::Float64
    storage_read_errors::Int
    storage_write_errors::Int
    storage_temperature_c::Float64
    storage_health_percent::Float64

    # Filesystem
    filesystem_errors::Int
    filesystem_check_failures::Int

    # CPU
    cpu_usage_percent::Float64
    cpu_temperature_c::Float64
    cpu_throttle_percent::Float64
    cpu_error_count::Int

    # GPU
    gpu_usage_percent::Float64
    gpu_temperature_c::Float64
    gpu_error_count::Int
    gpu_driver_resets::Int

    # Memory
    memory_total_gb::Float64
    memory_used_gb::Float64
    memory_pressure_percent::Float64
    memory_errors::Int
    swap_used_gb::Float64

    # Thermal
    fan_rpm::Float64
    thermal_pressure_percent::Float64

    # Battery
    battery_capacity_percent::Float64
    battery_cycle_count::Int
    battery_temperature_c::Float64
    battery_voltage_v::Float64
    battery_current_a::Float64

    # Power
    charger_connected::Bool
    charging_watts::Float64
    power_events::Int
    unexpected_shutdowns::Int

    # Network
    network_latency_ms::Float64
    packet_loss_percent::Float64
    wifi_signal_percent::Float64
    network_disconnects::Int

    # Display
    display_error_count::Int
    display_refresh_hz::Float64

    # Input
    keyboard_error_count::Int
    trackpad_error_count::Int

    # USB / Thunderbolt
    usb_error_count::Int
    thunderbolt_error_count::Int

    # Camera / Audio
    camera_error_count::Int
    audio_error_count::Int

    # Security
    secure_boot_enabled::Bool
    security_events::Int
    unexpected_privilege_events::Int

    # OS / Kernel
    os_error_count::Int
    kernel_error_count::Int

end


# ============================================================
# UTILITY FUNCTIONS
# ============================================================

clamp01(x) = clamp(x, 0.0, 1.0)


function safe_ratio(a, b)

    if b == 0
        return 0.0
    end

    return a / b
end


function severity_from_score(score)

    if score >= 0.90
        return CRITICAL
    elseif score >= 0.70
        return ERROR
    elseif score >= 0.45
        return WARNING
    elseif score >= 0.20
        return NOTICE
    else
        return INFO
    end
end


# ============================================================
# STORAGE DIAGNOSTICS
# ============================================================

function diagnose_storage(s::SystemSnapshot)

    findings = DiagnosticFinding[]

    free_ratio =
        safe_ratio(
            s.storage_free_gb,
            s.storage_total_gb
        )

    if s.storage_health_percent < 50

        push!(
            findings,
            DiagnosticFinding(
                STORAGE,
                CRITICAL,
                STORAGE_FAILURE,
                "Storage health severely degraded",
                "Storage health telemetry is substantially below normal.",
                0.96,
                "storage_health",
                s.storage_health_percent,
                100.0,
                "Back up user data and perform hardware/storage diagnostics."
            )
        )

    elseif s.storage_health_percent < 75

        push!(
            findings,
            DiagnosticFinding(
                STORAGE,
                WARNING,
                HARDWARE_DEGRADATION,
                "Storage health degraded",
                "Storage health is below the expected operating range.",
                0.85,
                "storage_health",
                s.storage_health_percent,
                100.0,
                "Monitor storage health and verify backups."
            )
        )
    end


    if s.storage_read_errors > 0

        confidence =
            min(
                0.99,
                0.70 +
                0.05 *
                log1p(s.storage_read_errors)
            )

        push!(
            findings,
            DiagnosticFinding(
                STORAGE,
                ERROR,
                STORAGE_FAILURE,
                "Storage read errors detected",
                "The storage subsystem has reported read errors.",
                confidence,
                "read_errors",
                s.storage_read_errors,
                0.0,
                "Run non-destructive storage diagnostics and verify backups."
            )
        )
    end


    if s.storage_write_errors > 0

        push!(
            findings,
            DiagnosticFinding(
                STORAGE,
                CRITICAL,
                STORAGE_FAILURE,
                "Storage write errors detected",
                "The storage subsystem has reported write failures.",
                0.98,
                "write_errors",
                s.storage_write_errors,
                0.0,
                "Stop destructive repair attempts and secure a current backup."
            )
        )
    end


    if free_ratio < 0.10

        push!(
            findings,
            DiagnosticFinding(
                STORAGE,
                WARNING,
                PERFORMANCE_DEGRADATION,
                "Very low free storage",
                "The startup volume has unusually little free capacity.",
                0.90,
                "free_storage_ratio",
                free_ratio,
                0.20,
                "Free additional storage before interpreting performance problems as hardware faults."
            )
        )
    end


    if s.storage_temperature_c > 70

        push!(
            findings,
            DiagnosticFinding(
                STORAGE,
                WARNING,
                THERMAL_LIMIT,
                "Storage temperature elevated",
                "Storage temperature is above the preferred operating range.",
                0.86,
                "storage_temperature",
                s.storage_temperature_c,
                50.0,
                "Check thermal conditions and workload before further diagnosis."
            )
        )
    end

    return findings
end


# ============================================================
# FILESYSTEM
# ============================================================

function diagnose_filesystem(s::SystemSnapshot)

    findings = DiagnosticFinding[]

    if s.filesystem_errors > 0

        severity =
            s.filesystem_errors > 10 ?
            CRITICAL : ERROR

        confidence =
            min(
                0.99,
                0.70 +
                0.03 *
                log1p(s.filesystem_errors)
            )

        push!(
            findings,
            DiagnosticFinding(
                FILESYSTEM,
                severity,
                FILESYSTEM_CORRUPTION,
                "Filesystem errors detected",
                "Filesystem telemetry indicates possible structural errors.",
                confidence,
                "filesystem_errors",
                s.filesystem_errors,
                0.0,
                "Run a read-only filesystem verification before attempting repair."
            )
        )
    end


    if s.filesystem_check_failures > 0

        push!(
            findings,
            DiagnosticFinding(
                FILESYSTEM,
                ERROR,
                FILESYSTEM_CORRUPTION,
                "Filesystem verification failed",
                "One or more filesystem verification operations failed.",
                0.94,
                "filesystem_check_failures",
                s.filesystem_check_failures,
                0.0,
                "Preserve user data and escalate to Recovery-based filesystem diagnostics."
            )
        )
    end

    return findings
end


# ============================================================
# CPU
# ============================================================

function diagnose_cpu(s::SystemSnapshot)

    findings = DiagnosticFinding[]

    if s.cpu_temperature_c > 95

        push!(
            findings,
            DiagnosticFinding(
                CPU,
                CRITICAL,
                THERMAL_LIMIT,
                "CPU temperature extremely high",
                "CPU temperature is at a level associated with thermal protection.",
                0.97,
                "cpu_temperature",
                s.cpu_temperature_c,
                80.0,
                "Reduce workload and investigate cooling and thermal management."
            )
        )

    elseif s.cpu_temperature_c > 90

        push!(
            findings,
            DiagnosticFinding(
                CPU,
                WARNING,
                THERMAL_LIMIT,
                "CPU temperature elevated",
                "CPU temperature is higher than expected.",
                0.88,
                "cpu_temperature",
                s.cpu_temperature_c,
                75.0,
                "Inspect thermal load, cooling and sustained CPU utilisation."
            )
        )
    end


    if s.cpu_throttle_percent > 30

        push!(
            findings,
            DiagnosticFinding(
                CPU,
                WARNING,
                THERMAL_LIMIT,
                "CPU throttling detected",
                "CPU performance appears to be constrained by thermal or power conditions.",
                0.91,
                "cpu_throttle",
                s.cpu_throttle_percent,
                0.0,
                "Correlate CPU temperature, power and fan telemetry."
            )
        )
    end


    if s.cpu_error_count > 0

        push!(
            findings,
            DiagnosticFinding(
                CPU,
                ERROR,
                CPU_INSTABILITY,
                "CPU error events detected",
                "CPU-related error telemetry was reported.",
                0.91,
                "cpu_errors",
                s.cpu_error_count,
                0.0,
                "Run hardware diagnostics and examine system logs."
            )
        )
    end

    return findings
end


# ============================================================
# GPU
# ============================================================

function diagnose_gpu(s::SystemSnapshot)

    findings = DiagnosticFinding[]

    if s.gpu_error_count > 0

        push!(
            findings,
            DiagnosticFinding(
                GPU,
                ERROR,
                GPU_FAILURE,
                "GPU errors detected",
                "Graphics hardware or driver telemetry contains error events.",
                0.92,
                "gpu_errors",
                s.gpu_error_count,
                0.0,
                "Run graphics diagnostics and correlate with display and kernel events."
            )
        )
    end


    if s.gpu_driver_resets > 0

        push!(
            findings,
            DiagnosticFinding(
                GPU,
                WARNING,
                DRIVER_FAILURE,
                "GPU driver resets detected",
                "The graphics subsystem has experienced one or more resets.",
                0.89,
                "gpu_driver_resets",
                s.gpu_driver_resets,
                0.0,
                "Inspect graphics logs and correlate with application crashes."
            )
        )
    end


    if s.gpu_temperature_c > 95

        push!(
            findings,
            DiagnosticFinding(
                GPU,
                CRITICAL,
                THERMAL_LIMIT,
                "GPU temperature extremely high",
                "GPU temperature is at an unusually high level.",
                0.95,
                "gpu_temperature",
                s.gpu_temperature_c,
                80.0,
                "Reduce GPU workload and investigate thermal behaviour."
            )
        )
    end

    return findings
end


# ============================================================
# MEMORY
# ============================================================

function diagnose_memory(s::SystemSnapshot)

    findings = DiagnosticFinding[]

    if s.memory_errors > 0

        push!(
            findings,
            DiagnosticFinding(
                MEMORY,
                CRITICAL,
                MEMORY_ERROR,
                "Memory errors detected",
                "Memory diagnostics or hardware telemetry reported errors.",
                0.98,
                "memory_errors",
                s.memory_errors,
                0.0,
                "Run dedicated memory diagnostics and preserve important data."
            )
        )
    end


    if s.memory_pressure_percent > 90

        push!(
            findings,
            DiagnosticFinding(
                MEMORY,
                WARNING,
                PERFORMANCE_DEGRADATION,
                "Severe memory pressure",
                "The system is operating with very high memory pressure.",
                0.94,
                "memory_pressure",
                s.memory_pressure_percent,
                60.0,
                "Identify memory-intensive processes before assuming hardware failure."
            )
        )
    end


    if s.swap_used_gb >
       max(4.0, 0.25 * s.memory_total_gb)

        push!(
            findings,
            DiagnosticFinding(
                MEMORY,
                NOTICE,
                PERFORMANCE_DEGRADATION,
                "Heavy swap activity",
                "The system is using substantial swap storage.",
                0.86,
                "swap_used_gb",
                s.swap_used_gb,
                1.0,
                "Investigate memory pressure and active workloads."
            )
        )
    end

    return findings
end


# ============================================================
# THERMAL
# ============================================================

function diagnose_thermal(s::SystemSnapshot)

    findings = DiagnosticFinding[]

    if s.thermal_pressure_percent > 90

        push!(
            findings,
            DiagnosticFinding(
                THERMAL,
                CRITICAL,
                THERMAL_LIMIT,
                "Severe thermal pressure",
                "System thermal telemetry indicates sustained high thermal pressure.",
                0.96,
                "thermal_pressure",
                s.thermal_pressure_percent,
                20.0,
                "Reduce load and inspect thermal management."
            )
        )

    elseif s.thermal_pressure_percent > 70

        push!(
            findings,
            DiagnosticFinding(
                THERMAL,
                WARNING,
                THERMAL_LIMIT,
                "Elevated thermal pressure",
                "Thermal management is operating under significant load.",
                0.89,
                "thermal_pressure",
                s.thermal_pressure_percent,
                20.0,
                "Correlate CPU/GPU temperature, fan speed and power consumption."
            )
        )
    end


    if s.fan_rpm > 7000

        push!(
            findings,
            DiagnosticFinding(
                THERMAL,
                WARNING,
                THERMAL_LIMIT,
                "Very high fan speed",
                "Cooling hardware is operating at unusually high speed.",
                0.82,
                "fan_rpm",
                s.fan_rpm,
                3000.0,
                "Investigate sustained thermal load."
            )
        )
    end

    return findings
end


# ============================================================
# BATTERY
# ============================================================

function diagnose_battery(s::SystemSnapshot)

    findings = DiagnosticFinding[]

    if s.battery_capacity_percent < 70

        push!(
            findings,
            DiagnosticFinding(
                BATTERY,
                WARNING,
                BATTERY_DEGRADATION,
                "Battery capacity significantly degraded",
                "Reported maximum capacity is substantially below nominal capacity.",
                0.95,
                "battery_capacity",
                s.battery_capacity_percent,
                100.0,
                "Consider battery service after confirming the measurement."
            )
        )
    end


    if s.battery_cycle_count > 1000

        push!(
            findings,
            DiagnosticFinding(
                BATTERY,
                NOTICE,
                BATTERY_DEGRADATION,
                "High battery cycle count",
                "The battery has accumulated a high number of charge cycles.",
                0.82,
                "cycle_count",
                s.battery_cycle_count,
                500.0,
                "Monitor capacity and charging behaviour."
            )
        )
    end


    if s.battery_temperature_c > 45

        push!(
            findings,
            DiagnosticFinding(
                BATTERY,
                WARNING,
                THERMAL_LIMIT,
                "Battery temperature elevated",
                "Battery temperature is above a preferred operating range.",
                0.90,
                "battery_temperature",
                s.battery_temperature_c,
                30.0,
                "Reduce thermal load and investigate charging conditions."
            )
        )
    end

    return findings
end


# ============================================================
# POWER
# ============================================================

function diagnose_power(s::SystemSnapshot)

    findings = DiagnosticFinding[]

    if s.unexpected_shutdowns > 0

        push!(
            findings,
            DiagnosticFinding(
                POWER,
                ERROR,
                POWER_ANOMALY,
                "Unexpected shutdowns detected",
                "The machine has recorded one or more unexpected shutdown events.",
                0.91,
                "unexpected_shutdowns",
                s.unexpected_shutdowns,
                0.0,
                "Correlate shutdowns with battery, thermal, kernel and power events."
            )
        )
    end


    if s.charger_connected &&
       s.charging_watts < 5 &&
       s.battery_capacity_percent < 95

        push!(
            findings,
            DiagnosticFinding(
                POWER,
                WARNING,
                POWER_ANOMALY,
                "Charging power unexpectedly low",
                "The system reports a connected charger but unusually low charging power.",
                0.84,
                "charging_watts",
                s.charging_watts,
                20.0,
                "Check charger, cable, port and power-management telemetry."
            )
        )
    end

    return findings
end


# ============================================================
# NETWORK
# ============================================================

function diagnose_network(s::SystemSnapshot)

    findings = DiagnosticFinding[]

    if s.packet_loss_percent > 5

        push!(
            findings,
            DiagnosticFinding(
                NETWORK,
                WARNING,
                NETWORK_FAILURE,
                "High packet loss",
                "Network telemetry indicates substantial packet loss.",
                0.92,
                "packet_loss",
                s.packet_loss_percent,
                0.0,
                "Check Wi-Fi signal, access point and network path."
            )
        )
    end


    if s.network_latency_ms > 150

        push!(
            findings,
            DiagnosticFinding(
                NETWORK,
                NOTICE,
                NETWORK_FAILURE,
                "High network latency",
                "Measured network latency is substantially elevated.",
                0.86,
                "latency",
                s.network_latency_ms,
                30.0,
                "Check local wireless conditions and upstream network latency."
            )
        )
    end


    if s.network_disconnects > 5

        push!(
            findings,
            DiagnosticFinding(
                NETWORK,
                WARNING,
                NETWORK_FAILURE,
                "Repeated network disconnections",
                "Multiple network disconnect events were observed.",
                0.89,
                "disconnects",
                s.network_disconnects,
                0.0,
                "Inspect Wi-Fi/network interface and system logs."
            )
        )
    end

    return findings
end


# ============================================================
# BOOT
# ============================================================

function diagnose_boot(s::SystemSnapshot)

    findings = DiagnosticFinding[]

    if s.boot_failures > 0

        push!(
            findings,
            DiagnosticFinding(
                BOOT,
                ERROR,
                BOOT_FAILURE,
                "Boot failures detected",
                "The machine has recorded unsuccessful boot attempts.",
                0.94,
                "boot_failures",
                s.boot_failures,
                0.0,
                "Inspect boot configuration, filesystem integrity and system logs."
            )
        )
    end


    if s.boot_time_seconds > 120

        push!(
            findings,
            DiagnosticFinding(
                BOOT,
                WARNING,
                PERFORMANCE_DEGRADATION,
                "Unusually long boot time",
                "Boot duration is significantly longer than expected.",
                0.85,
                "boot_time",
                s.boot_time_seconds,
                30.0,
                "Correlate storage, filesystem, login services and system errors."
            )
        )
    end


    if s.kernel_panics > 0

        push!(
            findings,
            DiagnosticFinding(
                KERNEL,
                CRITICAL,
                KERNEL_FAILURE,
                "Kernel panic history detected",
                "One or more kernel panic events have been recorded.",
                0.98,
                "kernel_panics",
                s.kernel_panics,
                0.0,
                "Inspect panic reports and correlate hardware, driver and OS events."
            )
        )
    end

    return findings
end


# ============================================================
# SECURITY
# ============================================================

function diagnose_security(s::SystemSnapshot)

    findings = DiagnosticFinding[]

    if !s.secure_boot_enabled

        push!(
            findings,
            DiagnosticFinding(
                SECURITY,
                WARNING,
                SECURITY_ANOMALY,
                "Secure boot configuration requires review",
                "The reported secure boot state is not enabled.",
                0.90,
                "secure_boot",
                0.0,
                1.0,
                "Verify the intended Secure Boot configuration."
            )
        )
    end


    if s.unexpected_privilege_events > 0

        push!(
            findings,
            DiagnosticFinding(
                SECURITY,
                ERROR,
                SECURITY_ANOMALY,
                "Unexpected privilege events",
                "Security telemetry contains unexpected privilege-related events.",
                0.90,
                "privilege_events",
                s.unexpected_privilege_events,
                0.0,
                "Review security logs and authenticated administrative activity."
            )
        )
    end

    return findings
end


# ============================================================
# PERIPHERALS
# ============================================================

function diagnose_peripherals(s::SystemSnapshot)

    findings = DiagnosticFinding[]

    if s.keyboard_error_count > 0

        push!(
            findings,
            DiagnosticFinding(
                INPUT,
                WARNING,
                HARDWARE_DEGRADATION,
                "Keyboard errors detected",
                "Keyboard subsystem telemetry contains errors.",
                0.85,
                "keyboard_errors",
                s.keyboard_error_count,
                0.0,
                "Test individual keys and inspect input-device diagnostics."
            )
        )
    end


    if s.trackpad_error_count > 0

        push!(
            findings,
            DiagnosticFinding(
                INPUT,
                WARNING,
                HARDWARE_DEGRADATION,
                "Trackpad errors detected",
                "Trackpad subsystem telemetry contains errors.",
                0.85,
                "trackpad_errors",
                s.trackpad_error_count,
                0.0,
                "Run input-device diagnostics."
            )
        )
    end


    if s.usb_error_count > 0

        push!(
            findings,
            DiagnosticFinding(
                USB,
                WARNING,
                HARDWARE_DEGRADATION,
                "USB errors detected",
                "USB subsystem telemetry contains error events.",
                0.88,
                "usb_errors",
                s.usb_error_count,
                0.0,
                "Test ports independently and inspect USB device logs."
            )
        )
    end


    if s.thunderbolt_error_count > 0

        push!(
            findings,
            DiagnosticFinding(
                THUNDERBOLT,
                WARNING,
                HARDWARE_DEGRADATION,
                "Thunderbolt errors detected",
                "Thunderbolt subsystem telemetry contains errors.",
                0.88,
                "thunderbolt_errors",
                s.thunderbolt_error_count,
                0.0,
                "Test cables, peripherals and ports independently."
            )
        )
    end


    if s.camera_error_count > 0

        push!(
            findings,
            DiagnosticFinding(
                CAMERA,
                WARNING,
                HARDWARE_DEGRADATION,
                "Camera errors detected",
                "Camera subsystem telemetry contains errors.",
                0.86,
                "camera_errors",
                s.camera_error_count,
                0.0,
                "Test camera access and inspect camera subsystem logs."
            )
        )
    end


    if s.audio_error_count > 0

        push!(
            findings,
            DiagnosticFinding(
                AUDIO,
                WARNING,
                HARDWARE_DEGRADATION,
                "Audio errors detected",
                "Audio subsystem telemetry contains errors.",
                0.86,
                "audio_errors",
                s.audio_error_count,
                0.0,
                "Test speakers, microphones and audio routing."
            )
        )
    end

    return findings
end


# ============================================================
# CROSS-SUBSYSTEM CORRELATION
# ============================================================

function correlate_findings(
    findings::Vector{DiagnosticFinding},
    s::SystemSnapshot
)

    correlated = DiagnosticFinding[]

    # --------------------------------------------------------
    # Thermal + CPU
    # --------------------------------------------------------

    cpu_thermal =
        any(
            f ->
                f.subsystem == CPU &&
                f.fault == THERMAL_LIMIT,
            findings
        )

    high_thermal =
        s.thermal_pressure_percent > 70

    if cpu_thermal && high_thermal

        push!(
            correlated,
            DiagnosticFinding(
                THERMAL,
                ERROR,
                THERMAL_LIMIT,
                "Cross-subsystem thermal problem",
                "CPU temperature, CPU behaviour and system thermal pressure are correlated.",
                0.95,
                "thermal_correlation",
                s.thermal_pressure_percent,
                20.0,
                "Investigate cooling, workload and power-management behaviour."
            )
        )
    end


    # --------------------------------------------------------
    # Storage + Filesystem + Boot
    # --------------------------------------------------------

    storage_problem =
        any(
            f ->
                f.subsystem == STORAGE &&
                f.severity >= ERROR,
            findings
        )

    filesystem_problem =
        any(
            f ->
                f.subsystem == FILESYSTEM &&
                f.severity >= ERROR,
            findings
        )

    boot_problem =
        any(
            f ->
                f.subsystem == BOOT &&
                f.severity >= ERROR,
            findings
        )

    if storage_problem &&
       filesystem_problem &&
       boot_problem

        push!(
            correlated,
            DiagnosticFinding(
                STORAGE,
                CRITICAL,
                STORAGE_FAILURE,
                "Storage/filesystem/boot fault cluster",
                "Storage, filesystem and boot anomalies occur together.",
                0.97,
                "fault_cluster",
                1.0,
                0.0,
                "Prioritise data preservation and non-destructive storage diagnostics."
            )
        )
    end


    # --------------------------------------------------------
    # GPU + Display + Kernel
    # --------------------------------------------------------

    gpu_problem =
        any(
            f ->
                f.subsystem == GPU &&
                f.severity >= ERROR,
            findings
        )

    display_problem =
        s.display_error_count > 0

    kernel_problem =
        s.kernel_error_count > 0

    if gpu_problem &&
       display_problem &&
       kernel_problem

        push!(
            correlated,
            DiagnosticFinding(
                GPU,
                CRITICAL,
                GPU_FAILURE,
                "Graphics fault cluster",
                "GPU, display and kernel telemetry indicate a correlated graphics problem.",
                0.94,
                "graphics_fault_cluster",
                1.0,
                0.0,
                "Collect graphics and kernel diagnostics before attempting system repair."
            )
        )
    end


    # --------------------------------------------------------
    # Battery + Power
    # --------------------------------------------------------

    if s.unexpected_shutdowns > 0 &&
       s.battery_capacity_percent < 75

        push!(
            correlated,
            DiagnosticFinding(
                POWER,
                ERROR,
                POWER_ANOMALY,
                "Battery/power correlation",
                "Unexpected shutdowns coincide with substantially degraded battery capacity.",
                0.89,
                "battery_power_correlation",
                s.battery_capacity_percent,
                100.0,
                "Investigate battery and power-management telemetry."
            )
        )
    end


    return correlated
end


# ============================================================
# OVERALL HEALTH
# ============================================================

function finding_weight(
    severity::Severity
)

    if severity == CRITICAL
        return 1.00
    elseif severity == ERROR
        return 0.75
    elseif severity == WARNING
        return 0.45
    elseif severity == NOTICE
        return 0.20
    else
        return 0.05
    end
end


function overall_health(
    findings::Vector{DiagnosticFinding}
)

    if isempty(findings)
        return 100.0
    end

    total =
        sum(
            finding_weight(f.severity)
            for f in findings
        )

    # Saturating penalty prevents 50 warnings from
    # overwhelming one genuinely critical finding.
    penalty =
        100 *
        (
            1 -
            exp(-0.20 * total)
        )

    return clamp(
        100 - penalty,
        0,
        100
    )
end


# ============================================================
# PRIMARY FAULT
# ============================================================

function determine_primary_fault(
    findings::Vector{DiagnosticFinding}
)

    isempty(findings) &&
        return NONE

    sorted =
        sort(
            findings,
            by = f ->
                (
                    Int(f.severity),
                    f.confidence
                ),
            rev = true
        )

    return sorted[1].fault
end


# ============================================================
# DIAGNOSTIC REPORT
# ============================================================

struct DiagnosticReport

    timestamp::DateTime

    health_score::Float64

    primary_fault::FaultType

    findings::Vector{DiagnosticFinding}

    critical_count::Int
    error_count::Int
    warning_count::Int

end


# ============================================================
# COMPLETE DIAGNOSTIC
# ============================================================

function diagnose(
    s::SystemSnapshot
)

    findings = DiagnosticFinding[]

    append!(
        findings,
        diagnose_boot(s)
    )

    append!(
        findings,
        diagnose_storage(s)
    )

    append!(
        findings,
        diagnose_filesystem(s)
    )

    append!(
        findings,
        diagnose_cpu(s)
    )

    append!(
        findings,
        diagnose_gpu(s)
    )

    append!(
        findings,
        diagnose_memory(s)
    )

    append!(
        findings,
        diagnose_thermal(s)
    )

    append!(
        findings,
        diagnose_battery(s)
    )

    append!(
        findings,
        diagnose_power(s)
    )

    append!(
        findings,
        diagnose_network(s)
    )

    append!(
        findings,
        diagnose_security(s)
    )

    append!(
        findings,
        diagnose_peripherals(s)
    )

    # Cross-system reasoning
    append!(
        findings,
        correlate_findings(
            findings,
            s
        )
    )

    health =
        overall_health(findings)

    primary =
        determine_primary_fault(findings)

    DiagnosticReport(
        now(),
        health,
        primary,
        findings,

        count(
            f -> f.severity == CRITICAL,
            findings
        ),

        count(
            f -> f.severity == ERROR,
            findings
        ),

        count(
            f -> f.severity == WARNING,
            findings
        )
    )
end


# ============================================================
# REPORT OUTPUT
# ============================================================

function print_report(
    report::DiagnosticReport
)

    println()
    println("=" ^ 70)
    println("              MACBOOK DIAGNOSTIC REPORT")
    println("=" ^ 70)

    println()
    println(
        "Timestamp: ",
        report.timestamp
    )

    println(
        "Health score: ",
        round(
            report.health_score,
            digits = 1
        ),
        "/100"
    )

    println(
        "Primary fault: ",
        report.primary_fault
    )

    println()
    println(
        "Critical: ",
        report.critical_count
    )

    println(
        "Errors:   ",
        report.error_count
    )

    println(
        "Warnings: ",
        report.warning_count
    )

    println()
    println("-" ^ 70)

    for (index, finding) in
        enumerate(report.findings)

        println()

        println(
            "[",
            index,
            "] ",
            finding.severity
        )

        println(
            "Subsystem: ",
            finding.subsystem
        )

        println(
            "Fault: ",
            finding.fault
        )

        println(
            "Title: ",
            finding.title
        )

        println(
            "Description: ",
            finding.description
        )

        println(
            "Confidence: ",
            round(
                finding.confidence * 100,
                digits = 1
            ),
            "%"
        )

        println(
            "Recommendation: ",
            finding.recommendation
        )
    end

    println()
    println("=" ^ 70)
end


# ============================================================
# HISTORICAL BASELINE
# ============================================================

struct Baseline

    mean::Float64
    standard_deviation::Float64
end


function make_baseline(
    values::Vector{Float64}
)

    isempty(values) &&
        return Baseline(0, 0)

    μ = mean(values)

    σ =
        length(values) > 1 ?
        std(values) :
        0.0

    return Baseline(
        μ,
        σ
    )
end


function anomaly_score(
    value::Float64,
    baseline::Baseline
)

    if baseline.standard_deviation < 1e-9
        return 0.0
    end

    z =
        abs(
            value -
            baseline.mean
        ) /
        baseline.standard_deviation

    return clamp01(
        z / 6
    )
end


# ============================================================
# ADAPTIVE DIAGNOSTICS
# ============================================================

mutable struct HistoricalDatabase

    metrics::Dict{
        String,
        Vector{Float64}
    }
end


HistoricalDatabase() =
    HistoricalDatabase(
        Dict{String, Vector{Float64}}()
    )


function record!(
    db::HistoricalDatabase,
    metric::String,
    value::Float64
)

    if !haskey(
        db.metrics,
        metric
    )

        db.metrics[metric] =
            Float64[]
    end

    push!(
        db.metrics[metric],
        value
    )

    # Keep bounded history
    if length(
        db.metrics[metric]
    ) > 1000

        deleteat!(
            db.metrics[metric],
            1
        )
    end
end


function adaptive_anomaly(
    db::HistoricalDatabase,
    metric::String,
    value::Float64
)

    if !haskey(
        db.metrics,
        metric
    )

        return 0.0
    end

    values =
        db.metrics[metric]

    baseline =
        make_baseline(values)

    return anomaly_score(
        value,
        baseline
    )
end


# ============================================================
# FAULT CORRELATION GRAPH
# ============================================================

struct FaultGraph

    edges::Dict{
        Tuple{Subsystem,Subsystem},
        Float64
    }
end


function default_fault_graph()

    edges = Dict{
        Tuple{Subsystem,Subsystem},
        Float64
    }()

    edges[(CPU, THERMAL)] = 0.9
    edges[(GPU, THERMAL)] = 0.9
    edges[(BATTERY, POWER)] = 0.9
    edges[(STORAGE, FILESYSTEM)] = 0.95
    edges[(FILESYSTEM, BOOT)] = 0.9
    edges[(GPU, DISPLAY)] = 0.9
    edges[(GPU, KERNEL)] = 0.8
    edges[(NETWORK, OS)] = 0.6
    edges[(USB, THUNDERBOLT)] = 0.7
    edges[(MEMORY, KERNEL)] = 0.8
    edges[(CPU, KERNEL)] = 0.8

    return FaultGraph(edges)
end


function correlation_strength(
    graph::FaultGraph,
    a::Subsystem,
    b::Subsystem
)

    if haskey(
        graph.edges,
        (a, b)
    )

        return graph.edges[(a, b)]
    end

    if haskey(
        graph.edges,
        (b, a)
    )

        return graph.edges[(b, a)]
    end

    return 0.0
end


# ============================================================
# REPAIR PRIORITY
# ============================================================

struct RepairPriority

    finding::DiagnosticFinding

    priority::Float64

end


function prioritise_repairs(
    report::DiagnosticReport
)

    priorities =
        RepairPriority[]

    for finding in report.findings

        severity =
            finding_weight(
                finding.severity
            )

        confidence =
            finding.confidence

        priority =
            0.70 * severity +
            0.30 * confidence

        push!(
            priorities,
            RepairPriority(
                finding,
                priority
            )
        )
    end

    return sort(
        priorities,
        by = x -> x.priority,
        rev = true
    )
end


# ============================================================
# EXAMPLE SNAPSHOT
# ============================================================

function example_snapshot()

    SystemSnapshot(

        # Boot
        42.0,
        0,
        0,

        # Storage
        1000.0,
        220.0,
        0,
        0,
        42.0,
        96.0,

        # Filesystem
        0,
        0,

        # CPU
        74.0,
        72.0,
        3.0,
        0,

        # GPU
        40.0,
        68.0,
        0,
        0,

        # Memory
        32.0,
        21.0,
        68.0,
        0,
        2.0,

        # Thermal
        2800.0,
        32.0,

        # Battery
        91.0,
        310,
        31.0,
        12.3,
        1.2,

        # Power
        true,
        48.0,
        0,
        0,

        # Network
        22.0,
        0.2,
        87.0,
        0,

        # Display
        0,
        120.0,

        # Input
        0,
        0,

        # USB / Thunderbolt
        0,
        0,

        # Camera / Audio
        0,
        0,

        # Security
        true,
        0,
        0,

        # OS / Kernel
        0,
        0
    )
end


# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    snapshot =
        example_snapshot()

    report =
        diagnose(snapshot)

    print_report(report)

    println()

    println(
        "Repair priorities:"
    )

    priorities =
        prioritise_repairs(report)

    for item in
        first(
            priorities,
            min(5, length(priorities))
        )

        println(
            round(
                item.priority,
                digits = 3
            ),
            " | ",
            item.finding.subsystem,
            " | ",
            item.finding.title
        )
    end

    return report
end


end # module
```


