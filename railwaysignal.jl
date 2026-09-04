using Dates

# ============================================================
# RHINO RAIL
# AUTOMATIC RAILWAY SIGNALLING / INTERLOCKING SIMULATOR
#
# Prototype / simulation only
# ============================================================

# ============================================================
# ENUMERATION-LIKE CONSTANTS
# ============================================================

const RED    = :RED
const YELLOW = :YELLOW
const GREEN  = :GREEN

const CLEAR   = :CLEAR
const OCCUPIED = :OCCUPIED

const NORMAL  = :NORMAL
const REVERSE = :REVERSE

const UNLOCKED = :UNLOCKED
const LOCKED   = :LOCKED

# ============================================================
# TRACK SECTION
# ============================================================

mutable struct TrackSection

    id::String

    occupied::Bool

    length_m::Float64

    speed_limit_kmh::Float64
end

# ============================================================
# POINT / SWITCH
# ============================================================

mutable struct Point

    id::String

    position::Symbol

    commanded_position::Symbol

    locked::Bool

    detected::Bool
end

# ============================================================
# SIGNAL
# ============================================================

mutable struct Signal

    id::String

    aspect::Symbol

    route_locked::Bool
end

# ============================================================
# ROUTE
# ============================================================

mutable struct Route

    id::String

    entry_signal::String

    exit_signal::String

    track_sections::Vector{String}

    required_points::Dict{String,Symbol}

    conflicting_routes::Vector{String}

    locked::Bool

    established::Bool

    occupied::Bool
end

# ============================================================
# TRAIN
# ============================================================

mutable struct Train

    id::String

    position::String

    speed_kmh::Float64

    destination::String

    route_id::Union{Nothing,String}
end

# ============================================================
# INTERLOCKING
# ============================================================

mutable struct Interlocking

    tracks::Dict{String,TrackSection}

    points::Dict{String,Point}

    signals::Dict{String,Signal}

    routes::Dict{String,Route}

    trains::Dict{String,Train}

    emergency_stop::Bool

    system_ok::Bool

    event_log::Vector{String}
end

# ============================================================
# LOGGING
# ============================================================

function log_event!(ixl, message)

    timestamp = Dates.format(
        now(),
        "yyyy-mm-dd HH:MM:SS"
    )

    entry = "[$timestamp] $message"

    push!(ixl.event_log, entry)

    println(entry)
end

# ============================================================
# TRACK CREATION
# ============================================================

function add_track!(
    ixl,
    id,
    length_m,
    speed_limit
)

    ixl.tracks[id] = TrackSection(
        id,
        false,
        length_m,
        speed_limit
    )
end

# ============================================================
# POINT CREATION
# ============================================================

function add_point!(ixl, id)

    ixl.points[id] = Point(
        id,
        NORMAL,
        NORMAL,
        false,
        true
    )
end

# ============================================================
# SIGNAL CREATION
# ============================================================

function add_signal!(ixl, id)

    ixl.signals[id] = Signal(
        id,
        RED,
        false
    )
end

# ============================================================
# ROUTE CREATION
# ============================================================

function add_route!(
    ixl,
    id,
    entry_signal,
    exit_signal,
    tracks,
    points,
    conflicts
)

    ixl.routes[id] = Route(
        id,
        entry_signal,
        exit_signal,
        tracks,
        points,
        conflicts,
        false,
        false,
        false
    )
end

# ============================================================
# TRACK CLEAR CHECK
# ============================================================

function track_is_clear(ixl, track_id)

    if !haskey(ixl.tracks, track_id)
        return false
    end

    return !ixl.tracks[track_id].occupied
end

function route_tracks_clear(ixl, route)

    for track_id in route.track_sections

        if !track_is_clear(ixl, track_id)
            return false
        end
    end

    return true
end

# ============================================================
# POINT POSITION CHECK
# ============================================================

function points_correct(ixl, route)

    for (point_id, required_position)
        in route.required_points

        if !haskey(ixl.points, point_id)
            return false
        end

        point = ixl.points[point_id]

        if !point.detected
            return false
        end

        if point.position != required_position
            return false
        end
    end

    return true
end

# ============================================================
# POINT CONFLICT CHECK
# ============================================================

function conflicting_point_operation(
    ixl,
    point_id
)

    point = ixl.points[point_id]

    return point.locked
end

# ============================================================
# SET POINTS
# ============================================================

function set_point!(
    ixl,
    point_id,
    position
)

    if !haskey(ixl.points, point_id)

        log_event!(
            ixl,
            "POINT ERROR: unknown point $point_id"
        )

        return false
    end

    point = ixl.points[point_id]

    if point.locked

        log_event!(
            ixl,
            "POINT $point_id COMMAND REJECTED: LOCKED"
        )

        return false
    end

    # --------------------------------------------------------
    # SAFETY CHECK
    # Do not move a point if its associated track is occupied.
    # --------------------------------------------------------

    for track in values(ixl.tracks)

        if track.occupied

            log_event!(
                ixl,
                "POINT $point_id movement blocked by occupied track"
            )

            return false
        end
    end

    point.commanded_position = position

    log_event!(
        ixl,
        "POINT $point_id commanded $position"
    )

    # Simulated point-machine operation

    sleep(0.1)

    point.position = position

    point.detected = true

    log_event!(
        ixl,
        "POINT $point_id detection = $position"
    )

    return true
end

# ============================================================
# LOCK POINTS
# ============================================================

function lock_route_points!(
    ixl,
    route
)

    for (point_id, position)
        in route.required_points

        point = ixl.points[point_id]

        if point.position != position
            return false
        end

        point.locked = true

        log_event!(
            ixl,
            "POINT $point_id LOCKED $position"
        )
    end

    return true
end

# ============================================================
# UNLOCK ROUTE POINTS
# ============================================================

function unlock_route_points!(
    ixl,
    route
)

    for point_id in keys(route.required_points)

        ixl.points[point_id].locked = false

        log_event!(
            ixl,
            "POINT $point_id RELEASED"
        )
    end
end

# ============================================================
# ROUTE CONFLICT CHECK
# ============================================================

function conflicting_route_active(
    ixl,
    route
)

    for conflict_id in route.conflicting_routes

        if haskey(ixl.routes, conflict_id)

            conflict = ixl.routes[conflict_id]

            if conflict.established ||
               conflict.locked

                return true
            end
        end
    end

    return false
end

# ============================================================
# ROUTE SAFETY VALIDATION
# ============================================================

function route_safe(ixl, route)

    # Emergency condition

    if ixl.emergency_stop
        return false
    end

    # System health

    if !ixl.system_ok
        return false
    end

    # Track detection

    if !route_tracks_clear(ixl, route)

        log_event!(
            ixl,
            "ROUTE $(route.id) REJECTED: TRACK OCCUPIED"
        )

        return false
    end

    # Point detection

    if !points_correct(ixl, route)

        log_event!(
            ixl,
            "ROUTE $(route.id) REJECTED: POINTS NOT PROVED"
        )

        return false
    end

    # Conflicting route

    if conflicting_route_active(ixl, route)

        log_event!(
            ixl,
            "ROUTE $(route.id) REJECTED: CONFLICT"
        )

        return false
    end

    return true
end

# ============================================================
# SET ROUTE
# ============================================================

function set_route!(
    ixl,
    route_id
)

    if !haskey(ixl.routes, route_id)

        log_event!(
            ixl,
            "ROUTE ERROR: $route_id does not exist"
        )

        return false
    end

    route = ixl.routes[route_id]

    if route.established

        log_event!(
            ixl,
            "ROUTE $route_id already established"
        )

        return true
    end

    log_event!(
        ixl,
        "ROUTE REQUEST: $route_id"
    )

    # --------------------------------------------------------
    # POSITION POINTS
    # --------------------------------------------------------

    for (point_id, required_position)
        in route.required_points

        point = ixl.points[point_id]

        if point.locked &&
           point.position != required_position

            log_event!(
                ixl,
                "ROUTE $route_id FAILED: POINT LOCK CONFLICT"
            )

            return false
        end

        if point.position != required_position

            if !set_point!(
                ixl,
                point_id,
                required_position
            )

                return false
            end
        end
    end

    # --------------------------------------------------------
    # PROVE ROUTE SAFE
    # --------------------------------------------------------

    if !route_safe(ixl, route)

        log_event!(
            ixl,
            "ROUTE $route_id FAILED SAFETY PROOF"
        )

        return false
    end

    # --------------------------------------------------------
    # LOCK POINTS
    # --------------------------------------------------------

    if !lock_route_points!(
        ixl,
        route
    )

        return false
    end

    route.locked = true
    route.established = true

    # --------------------------------------------------------
    # CLEAR SIGNAL
    # --------------------------------------------------------

    signal = ixl.signals[
        route.entry_signal
    ]

    signal.route_locked = true

    signal.aspect = GREEN

    log_event!(
        ixl,
        "SIGNAL $(signal.id) -> GREEN"
    )

    log_event!(
        ixl,
        "ROUTE $route_id ESTABLISHED"
    )

    return true
end

# ============================================================
# RESTORE SIGNAL
# ============================================================

function restore_signal!(
    ixl,
    route_id
)

    route = ixl.routes[route_id]

    signal = ixl.signals[
        route.entry_signal
    ]

    signal.aspect = RED

    log_event!(
        ixl,
        "SIGNAL $(signal.id) -> RED"
    )

    # Route remains locked if a train has entered.
    if route.occupied

        log_event!(
            ixl,
            "ROUTE $route_id REMAINS LOCKED: TRAIN PRESENT"
        )

        return
    end

    route.established = false
    route.locked = false

    signal.route_locked = false

    unlock_route_points!(
        ixl,
        route
    )

    log_event!(
        ixl,
        "ROUTE $route_id RELEASED"
    )
end

# ============================================================
# TRAIN ENTRY
# ============================================================

function train_enter!(
    ixl,
    train_id,
    track_id
)

    if !haskey(ixl.trains, train_id)

        log_event!(
            ixl,
            "TRAIN ERROR: $train_id UNKNOWN"
        )

        return false
    end

    train = ixl.trains[train_id]

    if !haskey(ixl.tracks, track_id)

        return false
    end

    track = ixl.tracks[track_id]

    if track.occupied

        log_event!(
            ixl,
            "TRAIN $train_id BLOCKED: TRACK OCCUPIED"
        )

        return false
    end

    track.occupied = true

    train.position = track_id

    if train.route_id !== nothing

        route = ixl.routes[
            train.route_id
        ]

        route.occupied = true
    end

    log_event!(
        ixl,
        "TRAIN $train_id ENTERED $track_id"
    )

    # Signal automatically returns to danger

    if train.route_id !== nothing

        route = ixl.routes[
            train.route_id
        ]

        signal = ixl.signals[
            route.entry_signal
        ]

        signal.aspect = RED

        log_event!(
            ixl,
            "SIGNAL $(signal.id) -> RED (TRAIN PASSED)"
        )
    end

    return true
end

# ============================================================
# TRAIN LEAVES TRACK
# ============================================================

function train_clear!(
    ixl,
    train_id,
    track_id
)

    if !haskey(ixl.tracks, track_id)
        return false
    end

    ixl.tracks[
        track_id
    ].occupied = false

    log_event!(
        ixl,
        "TRACK $track_id CLEARED"
    )

    if haskey(ixl.trains, train_id)

        train = ixl.trains[train_id]

        train.position = "BETWEEN"
    end

    return true
end

# ============================================================
# ROUTE RELEASE
# ============================================================

function release_route!(
    ixl,
    route_id
)

    route = ixl.routes[route_id]

    if route.occupied

        log_event!(
            ixl,
            "ROUTE $route_id RELEASE BLOCKED: TRAIN PRESENT"
        )

        return false
    end

    route.established = false
    route.locked = false

    signal = ixl.signals[
        route.entry_signal
    ]

    signal.aspect = RED
    signal.route_locked = false

    unlock_route_points!(
        ixl,
        route
    )

    log_event!(
        ixl,
        "ROUTE $route_id FULLY RELEASED"
    )

    return true
end

# ============================================================
# AUTOMATIC SIGNAL LOGIC
# ============================================================

function update_signals!(ixl)

    if ixl.emergency_stop

        for signal in values(ixl.signals)

            signal.aspect = RED
        end

        return
    end

    for route in values(ixl.routes)

        if !route.established
            continue
        end

        signal = ixl.signals[
            route.entry_signal
        ]

        # If route becomes occupied, don't leave
        # the entrance signal showing proceed.

        if route.occupied

            signal.aspect = RED

            continue
        end

        # Safe route -> green

        if route_safe(ixl, route)

            signal.aspect = GREEN

        else

            signal.aspect = RED
        end
    end
end

# ============================================================
# EMERGENCY STOP
# ============================================================

function emergency_stop!(ixl)

    ixl.emergency_stop = true

    for signal in values(ixl.signals)

        signal.aspect = RED
    end

    log_event!(
        ixl,
        "!!! EMERGENCY STOP ACTIVE !!!"
    )
end

# ============================================================
# EMERGENCY RESET
# ============================================================

function reset_emergency!(ixl)

    ixl.emergency_stop = false

    log_event!(
        ixl,
        "Emergency condition reset"
    )

    update_signals!(ixl)
end

# ============================================================
# SIGNAL DISPLAY
# ============================================================

function signal_status(ixl)

    println()
    println("SIGNALS")
    println("--------------------------------")

    for signal in values(ixl.signals)

        println(
            signal.id,
            " : ",
            signal.aspect
        )
    end
end

# ============================================================
# POINT DISPLAY
# ============================================================

function point_status(ixl)

    println()
    println("POINTS")
    println("--------------------------------")

    for point in values(ixl.points)

        println(
            point.id,
            " : ",
            point.position,
            " | ",
            point.locked ?
            "LOCKED" :
            "FREE"
        )
    end
end

# ============================================================
# TRACK DISPLAY
# ============================================================

function track_status(ixl)

    println()
    println("TRACK CIRCUITS")
    println("--------------------------------")

    for track in values(ixl.tracks)

        println(
            track.id,
            " : ",
            track.occupied ?
            "OCCUPIED" :
            "CLEAR"
        )
    end
end

# ============================================================
# ROUTE DISPLAY
# ============================================================

function route_status(ixl)

    println()
    println("ROUTES")
    println("--------------------------------")

    for route in values(ixl.routes)

        println(
            route.id,
            " : ",
            route.established ?
            "ESTABLISHED" :
            "NOT SET",
            " | ",
            route.occupied ?
            "TRAIN PRESENT" :
            "CLEAR"
        )
    end
end

# ============================================================
# COMPLETE SYSTEM DISPLAY
# ============================================================

function system_status(ixl)

    println()
    println("============================================================")
    println("              RHINO RAIL INTERLOCKING")
    println("============================================================")

    println(
        "SYSTEM: ",
        ixl.system_ok ?
        "HEALTHY" :
        "FAULT"
    )

    println(
        "EMERGENCY: ",
        ixl.emergency_stop ?
        "ACTIVE" :
        "CLEAR"
    )

    track_status(ixl)
    point_status(ixl)
    signal_status(ixl)
    route_status(ixl)

    println("============================================================")
end

# ============================================================
# BUILD DEMONSTRATION RAILWAY
#
# Layout:
#
#       B2
#        \
# A1 ---- P1 ---- B1
#
#       A2
#
# Simplified conceptual junction
# ============================================================

function create_demo_interlocking()

    tracks = Dict{String,TrackSection}()
    points = Dict{String,Point}()
    signals = Dict{String,Signal}()
    routes = Dict{String,Route}()
    trains = Dict{String,Train}()

    ixl = Interlocking(
        tracks,
        points,
        signals,
        routes,
        trains,
        false,
        true,
        String[]
    )

    # --------------------------------------------------------
    # TRACKS
    # --------------------------------------------------------

    add_track!(
        ixl,
        "T1",
        800.0,
        125.0
    )

    add_track!(
        ixl,
        "T2",
        600.0,
        80.0
    )

    add_track!(
        ixl,
        "T3",
        700.0,
        125.0
    )

    add_track!(
        ixl,
        "T4",
        900.0,
        125.0
    )

    # --------------------------------------------------------
    # POINT
    # --------------------------------------------------------

    add_point!(
        ixl,
        "P1"
    )

    # --------------------------------------------------------
    # SIGNALS
    # --------------------------------------------------------

    add_signal!(
        ixl,
        "S1"
    )

    add_signal!(
        ixl,
        "S2"
    )

    add_signal!(
        ixl,
        "S3"
    )

    # --------------------------------------------------------
    # ROUTE A
    #
    # S1 -> S2
    #
    # P1 NORMAL
    # --------------------------------------------------------

    add_route!(
        ixl,
        "R1",
        "S1",
        "S2",
        ["T1", "T2"],
        Dict(
            "P1" => NORMAL
        ),
        ["R2"]
    )

    # --------------------------------------------------------
    # ROUTE B
    #
    # S1 -> S3
    #
    # P1 REVERSE
    # --------------------------------------------------------

    add_route!(
        ixl,
        "R2",
        "S1",
        "S3",
        ["T1", "T3"],
        Dict(
            "P1" => REVERSE
        ),
        ["R1"]
    )

    # --------------------------------------------------------
    # TRAIN
    # --------------------------------------------------------

    trains["TR100"] = Train(
        "TR100",
        "T4",
        0.0,
        "S2",
        nothing
    )

    return ixl
end

# ============================================================
# DEMONSTRATION
# ============================================================

function demonstration()

    ixl = create_demo_interlocking()

    println()
    println("============================================================")
    println(" RHINO RAIL AUTOMATIC SIGNALLING SIMULATION")
    println("============================================================")

    system_status(ixl)

    # --------------------------------------------------------
    # REQUEST ROUTE R1
    # --------------------------------------------------------

    println()
    println("REQUESTING ROUTE R1")
    println("--------------------------------")

    set_route!(
        ixl,
        "R1"
    )

    system_status(ixl)

    # --------------------------------------------------------
    # ASSIGN TRAIN
    # --------------------------------------------------------

    train = ixl.trains["TR100"]

    train.route_id = "R1"

    println()
    println("TRAIN TR100 ASSIGNED TO R1")

    # --------------------------------------------------------
    # TRAIN ENTERS
    # --------------------------------------------------------

    println()
    println("TRAIN APPROACHING...")

    train_enter!(
        ixl,
        "TR100",
        "T1"
    )

    update_signals!(ixl)

    system_status(ixl)

    # --------------------------------------------------------
    # TRAIN CLEARS T1
    # --------------------------------------------------------

    println()
    println("TRAIN CLEARS T1")

    train_clear!(
        ixl,
        "TR100",
        "T1"
    )

    # --------------------------------------------------------
    # TRAIN ENTERS T2
    # --------------------------------------------------------

    println()
    println("TRAIN ENTERS T2")

    train_enter!(
        ixl,
        "TR100",
        "T2"
    )

    update_signals!(ixl)

    system_status(ixl)

    # --------------------------------------------------------
    # TRAIN CLEARS ROUTE
    # --------------------------------------------------------

    println()
    println("TRAIN CLEARS T2")

    train_clear!(
        ixl,
        "TR100",
        "T2"
    )

    ixl.routes["R1"].occupied = false

    release_route!(
        ixl,
        "R1"
    )

    system_status(ixl)

    # --------------------------------------------------------
    # TEST CONFLICT
    # --------------------------------------------------------

    println()
    println("============================================================")
    println(" CONFLICT TEST")
    println("============================================================")

    println()
    println("Attempting R1 and R2 simultaneously...")

    success1 = set_route!(
        ixl,
        "R1"
    )

    success2 = set_route!(
        ixl,
        "R2"
    )

    println()
    println(
        "R1 result: ",
        success1
    )

    println(
        "R2 result: ",
        success2
    )

    # --------------------------------------------------------
    # EMERGENCY TEST
    # --------------------------------------------------------

    println()
    println("============================================================")
    println(" EMERGENCY TEST")
    println("============================================================")

    emergency_stop!(
        ixl
    )

    system_status(ixl)

    println()
    println("Resetting emergency state...")

    reset_emergency!(
        ixl
    )

    system_status(ixl)

    println()
    println("Simulation complete.")
end

# ============================================================
# RUN
# ============================================================

demonstration()
