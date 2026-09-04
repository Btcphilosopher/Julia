module RailTVM

using Dates
using Statistics

# ============================================================
# RailTVM.jl
# Railway Ticket Vending Machine + Touchscreen Optimiser
# ============================================================

export Station,
       Destination,
       Fare,
       JourneyRequest,
       TouchEvent,
       TVMSession,
       TouchOptimizer,
       TicketMachine,
       recommend_destinations,
       calculate_fare,
       optimise_screen,
       start_journey!,
       select_destination!,
       select_ticket!,
       complete_payment!,
       print_ticket!,
       render_screen


# ============================================================
# DATA TYPES
# ============================================================

struct Station
    code::String
    name::String
end


struct Destination
    station::Station
    popularity::Float64
    average_daily_transactions::Int
end


struct Fare
    origin::String
    destination::String

    ticket_type::String

    adult_price::Float64
    child_price::Float64

    railcard_discount::Float64

    valid_from::Int
    valid_until::Int
end


mutable struct JourneyRequest

    origin::Union{String,Nothing}
    destination::Union{String,Nothing}

    travel_date::Union{Date,Nothing}
    departure_time::Union{Time,Nothing}

    adults::Int
    children::Int

    railcard::Union{String,Nothing}

    ticket_type::Union{String,Nothing}

end


# ============================================================
# TOUCH EVENTS
# ============================================================

struct TouchEvent

    x::Float64
    y::Float64

    width::Float64
    height::Float64

    timestamp::DateTime

end


# ============================================================
# SESSION
# ============================================================

mutable struct TVMSession

    request::JourneyRequest

    current_screen::String

    interaction_count::Int

    start_time::DateTime

    last_touch::Union{DateTime,Nothing}

    completed::Bool

end


# ============================================================
# TOUCH OPTIMISER
# ============================================================

mutable struct TouchOptimizer

    screen_width::Int
    screen_height::Int

    minimum_touch_target::Float64

    preferred_columns::Int

    max_primary_options::Int

    accessibility_mode::Bool

    large_text::Bool

    high_contrast::Bool
end


# ============================================================
# TICKET MACHINE
# ============================================================

mutable struct TicketMachine

    station::Station

    destinations::Vector{Destination}

    fares::Vector{Fare}

    active_sessions::Int

    transactions::Int

    revenue::Float64

    printer_available::Bool

    card_reader_available::Bool

    cash_acceptor_available::Bool

    smartcard_available::Bool

end


# ============================================================
# MACHINE FACTORY
# ============================================================

function create_machine()

    kings_cross =
        Station("KGX", "London King's Cross")

    destinations = [

        Destination(
            Station("YRK", "York"),
            0.94,
            420
        ),

        Destination(
            Station("LDS", "Leeds"),
            0.82,
            360
        ),

        Destination(
            Station("EDB", "Edinburgh"),
            0.75,
            240
        ),

        Destination(
            Station("PBO", "Peterborough"),
            0.63,
            180
        ),

        Destination(
            Station("NCL", "Newcastle"),
            0.58,
            170
        ),

        Destination(
            Station("CAM", "Cambridge"),
            0.54,
            140
        )
    ]

    fares = Fare[]

    for destination in destinations

        push!(
            fares,
            Fare(
                "KGX",
                destination.station.code,
                "Anytime",
                70.0,
                35.0,
                0.34,
                0,
                2359
            )
        )

        push!(
            fares,
            Fare(
                "KGX",
                destination.station.code,
                "Off-Peak",
                50.0,
                25.0,
                0.34,
                1000,
                1600
            )
        )

    end

    return TicketMachine(

        kings_cross,

        destinations,

        fares,

        0,

        0,

        0.0,

        true,
        true,
        true,
        true

    )

end


# ============================================================
# SESSION FACTORY
# ============================================================

function create_session(machine::TicketMachine)

    request = JourneyRequest(

        machine.station.code,

        nothing,
        nothing,
        nothing,

        1,
        0,

        nothing,
        nothing

    )

    machine.active_sessions += 1

    return TVMSession(

        request,

        "HOME",

        0,

        now(),

        nothing,

        false

    )

end


# ============================================================
# DESTINATION RECOMMENDER
# ============================================================

function recommend_destinations(
    machine::TicketMachine;
    limit=6
)

    destinations =
        sort(
            machine.destinations,
            by = x -> -x.popularity
        )

    return destinations[
        1:min(limit, length(destinations))
    ]

end


# ============================================================
# DESTINATION SELECTION
# ============================================================

function select_destination!(
    session::TVMSession,
    station::Station
)

    session.request.destination =
        station.code

    session.current_screen =
        "JOURNEY_OPTIONS"

    session.interaction_count += 1

    session.last_touch = now()

    return station
end


# ============================================================
# FARE ENGINE
# ============================================================

function calculate_fare(
    machine::TicketMachine,
    request::JourneyRequest
)

    request.destination === nothing &&
        error("Destination not selected")

    candidates = filter(
        f ->
            f.origin ==
            request.origin &&
            f.destination ==
            request.destination,
        machine.fares
    )

    isempty(candidates) &&
        error("No fare available")

    # Prefer a fare compatible with requested type.
    if request.ticket_type !== nothing

        filtered = filter(
            f ->
                f.ticket_type ==
                request.ticket_type,
            candidates
        )

        if !isempty(filtered)

            candidates = filtered

        end

    end

    fare = first(candidates)

    adult_price =
        fare.adult_price

    child_price =
        fare.child_price

    if request.railcard !== nothing

        adult_price *=
            1.0 - fare.railcard_discount

    end

    total =
        request.adults * adult_price +
        request.children * child_price

    return total
end


# ============================================================
# TICKET SELECTION
# ============================================================

function select_ticket!(
    session::TVMSession,
    ticket_type::String
)

    session.request.ticket_type =
        ticket_type

    session.current_screen =
        "PASSENGERS"

    session.interaction_count += 1

    session.last_touch = now()

    return ticket_type
end


# ============================================================
# TOUCHSCREEN LAYOUT
# ============================================================

struct ScreenButton

    id::String

    label::String

    x::Float64
    y::Float64

    width::Float64
    height::Float64

    importance::Float64

end


# ============================================================
# SCREEN OPTIMISATION
# ============================================================

function optimise_screen(
    optimizer::TouchOptimizer,
    options::Vector{String}
)

    n =
        min(
            length(options),
            optimizer.max_primary_options
        )

    options =
        options[1:n]

    columns =
        optimizer.preferred_columns

    rows =
        ceil(Int, n / columns)

    margin = 40.0

    usable_width =
        optimizer.screen_width -
        2 * margin

    usable_height =
        optimizer.screen_height -
        2 * margin -
        160

    button_width =
        usable_width / columns -
        20

    button_height =
        usable_height / rows -
        20

    buttons = ScreenButton[]

    for i in 1:n

        row =
            div(i - 1, columns)

        col =
            mod(i - 1, columns)

        x =
            margin +
            col *
            (button_width + 20)

        y =
            margin +
            160 +
            row *
            (button_height + 20)

        push!(
            buttons,
            ScreenButton(

                "OPTION_$i",

                options[i],

                x,
                y,

                button_width,
                button_height,

                1.0
            )
        )
    end

    return buttons
end


# ============================================================
# HOME SCREEN
# ============================================================

function home_screen(
    machine::TicketMachine,
    optimizer::TouchOptimizer
)

    destinations =
        recommend_destinations(
            machine;
            limit=optimizer.max_primary_options
        )

    labels =
        [d.station.name for d in destinations]

    buttons =
        optimise_screen(
            optimizer,
            labels
        )

    println()
    println(
        "=============================================="
    )

    println(
        "             RAILWAY TICKET MACHINE"
    )

    println(
        "             WHERE ARE YOU GOING?"
    )

    println(
        "=============================================="
    )

    for b in buttons

        println(
            "[ ",
            b.label,
            " ]"
        )

    end

    println()
    println(
        "[ SEARCH DESTINATION ]"
    )

    println(
        "[ COLLECT PREPAID TICKET ]"
    )

    return buttons
end


# ============================================================
# PAYMENT
# ============================================================

function complete_payment!(
    machine::TicketMachine,
    session::TVMSession,
    amount::Float64;
    method="CARD"
)

    amount <= 0 &&
        error("Invalid payment")

    if method == "CARD" &&
       !machine.card_reader_available

        error("Card reader unavailable")

    elseif method == "CASH" &&
           !machine.cash_acceptor_available

        error("Cash unavailable")
    end

    machine.transactions += 1

    machine.revenue += amount

    session.current_screen =
        "PRINTING"

    session.interaction_count += 1

    return true
end


# ============================================================
# TICKET PRINTING
# ============================================================

function print_ticket!(
    machine::TicketMachine,
    session::TVMSession
)

    if !machine.printer_available

        session.current_screen =
            "STAFF_ASSISTANCE"

        return false
    end

    println(
        "\nPRINTING TICKET..."
    )

    sleep(0.2)

    println(
        "Ticket issued successfully."
    )

    session.completed = true

    session.current_screen =
        "COMPLETE"

    machine.active_sessions -= 1

    return true
end


# ============================================================
# ACCESSIBILITY OPTIMISER
# ============================================================

function accessibility_profile!(
    optimizer::TouchOptimizer;
    large_text=true,
    high_contrast=true
)

    optimizer.accessibility_mode =
        true

    optimizer.large_text =
        large_text

    optimizer.high_contrast =
        high_contrast

    # Fewer, larger buttons.
    optimizer.preferred_columns = 2

    optimizer.max_primary_options = 4

    return optimizer
end


# ============================================================
# RENDER
# ============================================================

function render_screen(
    machine::TicketMachine,
    session::TVMSession,
    optimizer::TouchOptimizer
)

    if session.current_screen == "HOME"

        return home_screen(
            machine,
            optimizer
        )

    elseif session.current_screen ==
           "JOURNEY_OPTIONS"

        println(
            "\nJOURNEY OPTIONS"
        )

        println(
            "[ SINGLE ]"
        )

        println(
            "[ RETURN ]"
        )

        println(
            "[ RAILCARD / DISCOUNT ]"
        )

    elseif session.current_screen ==
           "PASSENGERS"

        println(
            "\nPASSENGERS"
        )

        println(
            "Adults: ",
            session.request.adults
        )

        println(
            "Children: ",
            session.request.children
        )

        println(
            "[ + ADULT ] [ + CHILD ]"
        )

        println(
            "[ CONTINUE ]"
        )

    elseif session.current_screen ==
           "PRINTING"

        println(
            "\nPLEASE WAIT"
        )

        println(
            "YOUR TICKET IS BEING PRINTED"
        )

    elseif session.current_screen ==
           "COMPLETE"

        println(
            "\nTHANK YOU"
        )

        println(
            "PLEASE TAKE YOUR TICKET"
        )
    end

end


# ============================================================
# OPTIMISATION METRICS
# ============================================================

function session_metrics(
    session::TVMSession
)

    elapsed =
        Dates.value(
            now() -
            session.start_time
        ) / 1000

    return (

        interaction_count =
            session.interaction_count,

        elapsed_seconds =
            elapsed,

        completed =
            session.completed

    )

end


end # module
