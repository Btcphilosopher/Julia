module ParcelSort

export Parcel,
       Chute,
       SorterConfig,
       SortResult,
       create_sorter,
       add_parcel!,
       process_parcel!,
       process_batch!,
       sort_parcels!,
       sorter_status,
       reset!,
       shutdown!,
       print_status,
       print_result

using Dates
using UUIDs

# ============================================================
# DATA TYPES
# ============================================================

@enum ParcelPriority begin
    STANDARD
    EXPRESS
    PRIORITY
end

@enum ParcelStatus begin
    CREATED
    QUEUED
    SORTED
    REJECTED
    EXCEPTION
end

struct Parcel
    id::UUID
    tracking_id::String
    weight_kg::Float64
    length_cm::Float64
    width_cm::Float64
    height_cm::Float64
    destination::String
    postcode::String
    service::String
    priority::ParcelPriority
    created_at::DateTime
end

mutable struct ParcelState
    parcel::Parcel
    status::ParcelStatus
    assigned_chute::Union{Nothing,String}
    processed_at::Union{Nothing,DateTime}
    reason::String
end

struct Chute
    id::String
    destination::String
    max_weight_kg::Float64
    max_parcels::Int
end

mutable struct ChuteState
    chute::Chute
    parcels::Vector{UUID}
    total_weight_kg::Float64
    active::Bool
end

struct SorterConfig
    max_weight_kg::Float64
    max_length_cm::Float64
    max_width_cm::Float64
    max_height_cm::Float64
    default_chute::String
end

mutable struct SortResult
    processed::Int
    sorted::Int
    rejected::Int
    exceptions::Int
    total_weight_kg::Float64
    processing_time_ms::Float64
    parcels::Vector{ParcelState}
end

mutable struct Sorter
    config::SorterConfig
    chutes::Dict{String,ChuteState}
    parcels::Dict{UUID,ParcelState}
    destination_map::Dict{String,String}
    postcode_rules::Vector{Tuple{Regex,String}}
    queue::Vector{UUID}
    running::Bool
    processed_count::Int
    sorted_count::Int
    rejected_count::Int
    exception_count::Int
    total_weight_kg::Float64
    started_at::DateTime
end


# ============================================================
# CONSTRUCTORS
# ============================================================

function create_sorter(
    config::SorterConfig,
    chutes::Vector{Chute};
    destination_map=Dict{String,String}(),
    postcode_rules=Tuple{Regex,String}[]
)

    chute_states = Dict{String,ChuteState}()

    for chute in chutes
        chute_states[chute.id] = ChuteState(
            chute,
            UUID[],
            0.0,
            true
        )
    end

    Sorter(
        config,
        chute_states,
        Dict{UUID,ParcelState}(),
        destination_map,
        postcode_rules,
        UUID[],
        true,
        0,
        0,
        0,
        0,
        0.0,
        now()
    )
end


# ============================================================
# VALIDATION
# ============================================================

function validate_parcel(
    sorter::Sorter,
    parcel::Parcel
)::Tuple{Bool,String}

    if parcel.weight_kg <= 0
        return false, "Invalid parcel weight"
    end

    if parcel.weight_kg > sorter.config.max_weight_kg
        return false, "Parcel exceeds sorter weight limit"
    end

    if parcel.length_cm <= 0 ||
       parcel.width_cm <= 0 ||
       parcel.height_cm <= 0
        return false, "Invalid parcel dimensions"
    end

    if parcel.length_cm > sorter.config.max_length_cm
        return false, "Parcel exceeds maximum length"
    end

    if parcel.width_cm > sorter.config.max_width_cm
        return false, "Parcel exceeds maximum width"
    end

    if parcel.height_cm > sorter.config.max_height_cm
        return false, "Parcel exceeds maximum height"
    end

    if isempty(strip(parcel.tracking_id))
        return false, "Missing tracking ID"
    end

    if isempty(strip(parcel.postcode)) &&
       isempty(strip(parcel.destination))
        return false, "Missing destination"
    end

    return true, ""
end


# ============================================================
# PARCEL CREATION
# ============================================================

function Parcel(
    tracking_id::String,
    weight_kg::Real,
    length_cm::Real,
    width_cm::Real,
    height_cm::Real,
    destination::String,
    postcode::String;
    service::String="STANDARD",
    priority::ParcelPriority=STANDARD
)

    Parcel(
        uuid4(),
        tracking_id,
        Float64(weight_kg),
        Float64(length_cm),
        Float64(width_cm),
        Float64(height_cm),
        destination,
        postcode,
        service,
        priority,
        now()
    )
end


# ============================================================
# ROUTING
# ============================================================

function destination_route(
    sorter::Sorter,
    parcel::Parcel
)::String

    # Exact destination match
    if haskey(sorter.destination_map, parcel.destination)
        return sorter.destination_map[parcel.destination]
    end

    # Exact postcode match
    if haskey(sorter.destination_map, parcel.postcode)
        return sorter.destination_map[parcel.postcode]
    end

    # Regex postcode routing
    for (pattern, chute_id) in sorter.postcode_rules
        if occursin(pattern, parcel.postcode)
            return chute_id
        end
    end

    return sorter.config.default_chute
end


# ============================================================
# CHUTE CAPACITY
# ============================================================

function chute_available(
    chute_state::ChuteState,
    parcel::Parcel
)::Tuple{Bool,String}

    if !chute_state.active
        return false, "Chute inactive"
    end

    if length(chute_state.parcels) >=
       chute_state.chute.max_parcels

        return false, "Chute parcel capacity reached"
    end

    if chute_state.total_weight_kg +
       parcel.weight_kg >
       chute_state.chute.max_weight_kg

        return false, "Chute weight capacity reached"
    end

    return true, ""
end


# ============================================================
# QUEUE
# ============================================================

function add_parcel!(
    sorter::Sorter,
    parcel::Parcel
)

    sorter.running ||
        throw(ArgumentError("Sorter is not running"))

    valid, reason = validate_parcel(sorter, parcel)

    state = ParcelState(
        parcel,
        valid ? QUEUED : REJECTED,
        nothing,
        nothing,
        reason
    )

    sorter.parcels[parcel.id] = state

    if valid
        push!(sorter.queue, parcel.id)
    else
        sorter.rejected_count += 1
    end

    return parcel.id
end


# ============================================================
# SINGLE PARCEL PROCESSING
# ============================================================

function process_parcel!(
    sorter::Sorter,
    parcel_id::UUID
)::ParcelState

    haskey(sorter.parcels, parcel_id) ||
        throw(KeyError(parcel_id))

    state = sorter.parcels[parcel_id]

    if state.status != QUEUED
        return state
    end

    parcel = state.parcel

    route = destination_route(sorter, parcel)

    # Unknown/default route
    if !haskey(sorter.chutes, route)

        state.status = EXCEPTION
        state.reason = "No valid chute for destination"
        state.processed_at = now()

        sorter.exception_count += 1

        return state
    end

    chute_state = sorter.chutes[route]

    available, reason =
        chute_available(chute_state, parcel)

    if !available

        state.status = EXCEPTION
        state.reason = reason
        state.processed_at = now()

        sorter.exception_count += 1

        return state
    end

    # Assign parcel
    push!(
        chute_state.parcels,
        parcel.id
    )

    chute_state.total_weight_kg +=
        parcel.weight_kg

    state.assigned_chute = route
    state.status = SORTED
    state.processed_at = now()
    state.reason = "Successfully sorted"

    sorter.processed_count += 1
    sorter.sorted_count += 1
    sorter.total_weight_kg += parcel.weight_kg

    return state
end


# ============================================================
# BATCH PROCESSING
# ============================================================

function process_batch!(
    sorter::Sorter;
    maximum::Int=typemax(Int)
)

    processed = 0

    while !isempty(sorter.queue) &&
          processed < maximum

        parcel_id = popfirst!(sorter.queue)

        process_parcel!(
            sorter,
            parcel_id
        )

        processed += 1
    end

    return processed
end


# ============================================================
# BATCH INGESTION + SORTING
# ============================================================

function sort_parcels!(
    sorter::Sorter,
    parcels::AbstractVector{Parcel}
)

    start_time = time_ns()

    states = ParcelState[]

    for parcel in parcels

        id = add_parcel!(
            sorter,
            parcel
        )

        push!(
            states,
            sorter.parcels[id]
        )
    end

    process_batch!(sorter)

    elapsed_ms =
        (time_ns() - start_time) / 1_000_000

    return SortResult(
        length(parcels),
        sorter.sorted_count,
        sorter.rejected_count,
        sorter.exception_count,
        sorter.total_weight_kg,
        elapsed_ms,
        states
    )
end


# ============================================================
# PRIORITY QUEUE
# ============================================================

function priority_value(
    priority::ParcelPriority
)

    if priority == PRIORITY
        return 3
    elseif priority == EXPRESS
        return 2
    else
        return 1
    end
end


function reorder_queue!(
    sorter::Sorter
)

    sort!(
        sorter.queue,
        by = id -> begin
            state = sorter.parcels[id]

            (
                -priority_value(
                    state.parcel.priority
                ),
                state.parcel.created_at
            )
        end
    )

    return nothing
end


# ============================================================
# PRIORITY-AWARE BATCH PROCESSING
# ============================================================

function process_priority_batch!(
    sorter::Sorter;
    maximum::Int=typemax(Int)
)

    reorder_queue!(sorter)

    return process_batch!(
        sorter;
        maximum=maximum
    )
end


# ============================================================
# CHUTE MANAGEMENT
# ============================================================

function activate_chute!(
    sorter::Sorter,
    chute_id::String
)

    haskey(sorter.chutes, chute_id) ||
        throw(KeyError(chute_id))

    sorter.chutes[chute_id].active = true

    return nothing
end


function deactivate_chute!(
    sorter::Sorter,
    chute_id::String
)

    haskey(sorter.chutes, chute_id) ||
        throw(KeyError(chute_id))

    sorter.chutes[chute_id].active = false

    return nothing
end


# ============================================================
# RETRIEVE PARCEL
# ============================================================

function get_parcel(
    sorter::Sorter,
    tracking_id::String
)

    for state in values(sorter.parcels)

        if state.parcel.tracking_id ==
           tracking_id

            return state
        end
    end

    return nothing
end


# ============================================================
# STATUS
# ============================================================

function sorter_status(sorter::Sorter)

    chute_status = Dict{String,NamedTuple}()

    for (id, state) in sorter.chutes

        chute_status[id] = (
            destination = state.chute.destination,
            parcels = length(state.parcels),
            weight_kg = state.total_weight_kg,
            max_parcels = state.chute.max_parcels,
            max_weight_kg = state.chute.max_weight_kg,
            active = state.active
        )
    end

    return (
        running = sorter.running,
        queue_length = length(sorter.queue),
        parcels_registered = length(sorter.parcels),
        processed = sorter.processed_count,
        sorted = sorter.sorted_count,
        rejected = sorter.rejected_count,
        exceptions = sorter.exception_count,
        total_weight_kg = sorter.total_weight_kg,
        chutes = chute_status
    )
end


# ============================================================
# REPORTING
# ============================================================

function print_status(sorter::Sorter)

    s = sorter_status(sorter)

    println()
    println("======================================================")
    println("                 PARCEL SORTER")
    println("======================================================")

    println("Running:              ", s.running)
    println("Queue:                ", s.queue_length)
    println("Registered parcels:   ", s.parcels_registered)
    println("Processed:            ", s.processed)
    println("Sorted:               ", s.sorted)
    println("Rejected:             ", s.rejected)
    println("Exceptions:           ", s.exceptions)
    println("Total weight:         ",
            round(s.total_weight_kg, digits=2),
            " kg")

    println()
    println("CHUTES")
    println("------------------------------------------------------")

    for (id, c) in s.chutes

        utilisation =
            c.max_parcels > 0 ?
            100 * c.parcels / c.max_parcels :
            0.0

        println(
            rpad(id, 12),
            " ",
            rpad(c.destination, 18),
            " parcels=",
            c.parcels,
            "/",
            c.max_parcels,
            " weight=",
            round(c.weight_kg, digits=1),
            "kg utilisation=",
            round(utilisation, digits=1),
            "% active=",
            c.active
        )
    end

    println("------------------------------------------------------")
end


function print_result(result::SortResult)

    println()
    println("======================================================")
    println("               SORTING RESULT")
    println("======================================================")

    println("Input parcels:        ", result.processed)
    println("Sorted:               ", result.sorted)
    println("Rejected:             ", result.rejected)
    println("Exceptions:           ", result.exceptions)
    println(
        "Total weight:         ",
        round(result.total_weight_kg, digits=2),
        " kg"
    )

    println(
        "Processing time:      ",
        round(result.processing_time_ms, digits=3),
        " ms"
    )

    if result.processing_time_ms > 0
        rate =
            result.processed /
            (result.processing_time_ms / 1000)

        println(
            "Throughput:           ",
            round(rate, digits=1),
            " parcels/sec"
        )
    end

    println()
    println("PARCEL ROUTES")
    println("------------------------------------------------------")

    for state in result.parcels

        println(
            state.parcel.tracking_id,
            " → ",
            state.assigned_chute === nothing ?
            "EXCEPTION" :
            state.assigned_chute,
            " [",
            state.status,
            "]"
        )
    end

    println("------------------------------------------------------")
end


# ============================================================
# RESET
# ============================================================

function reset!(sorter::Sorter)

    empty!(sorter.parcels)
    empty!(sorter.queue)

    for state in values(sorter.chutes)

        empty!(state.parcels)

        state.total_weight_kg = 0.0
        state.active = true
    end

    sorter.processed_count = 0
    sorter.sorted_count = 0
    sorter.rejected_count = 0
    sorter.exception_count = 0
    sorter.total_weight_kg = 0.0
    sorter.started_at = now()

    return nothing
end


# ============================================================
# SHUTDOWN
# ============================================================

function shutdown!(sorter::Sorter)

    sorter.running = false

    return nothing
end


# ============================================================
# DEMO DATA GENERATOR
# ============================================================

function generate_demo_parcels(n::Int)

    destinations = [
        ("London", "SW"),
        ("Birmingham", "B"),
        ("Manchester", "M"),
        ("Leeds", "LS"),
        ("Liverpool", "L"),
        ("Bristol", "BS"),
        ("Cardiff", "CF"),
        ("Sheffield", "S")
    ]

    services = [
        "STANDARD",
        "NEXT_DAY",
        "EXPRESS"
    ]

    parcels = Parcel[]

    for i in 1:n

        destination, prefix =
            destinations[
                mod1(i, length(destinations))
            ]

        priority =
            if i % 10 == 0
                PRIORITY
            elseif i % 4 == 0
                EXPRESS
            else
                STANDARD
            end

        service =
            if priority == PRIORITY
                "SAME_DAY"
            elseif priority == EXPRESS
                "EXPRESS"
            else
                "STANDARD"
            end

        postcode =
            prefix *
            string(rand(10:99)) *
            " " *
            string(rand(1:9)) *
            "AA"

        push!(
            parcels,
            Parcel(
                "PKG-" *
                lpad(string(i), 8, '0'),
                rand() * 20 + 0.2,
                rand() * 70 + 10,
                rand() * 40 + 10,
                rand() * 40 + 5,
                destination,
                postcode;
                service=service,
                priority=priority
            )
        )
    end

    return parcels
end


# ============================================================
# EXPORT DEMO GENERATOR
# ============================================================

export generate_demo_parcels,
       activate_chute!,
       deactivate_chute!,
       get_parcel,
       process_priority_batch!

end
