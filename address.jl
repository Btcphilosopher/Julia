############################################################
# ADDRESS SORTING ROBOT
# Julia prototype
#
# Pipeline:
#
# Camera
#   ↓
# OCR
#   ↓
# Address parser
#   ↓
# Geographic understanding
#   ↓
# Sorting-zone classifier
#   ↓
# Robotic-arm destination
#
############################################################

using Random
using Statistics

############################################################
# 1. DATA STRUCTURES
############################################################

struct Address
    raw_text::String
    house_number::Union{String,Nothing}
    street::Union{String,Nothing}
    town::Union{String,Nothing}
    county::Union{String,Nothing}
    postcode::Union{String,Nothing}
end

struct Location
    town::String
    county::String
    latitude::Float64
    longitude::Float64
end

struct SortingDecision
    address::Address
    location::Union{Location,Nothing}
    zone::String
    bin::Int
    confidence::Float64
end


############################################################
# 2. SIMULATED CAMERA / OCR
############################################################

"""
Pretend that a camera has scanned a parcel label.

A real implementation could replace this with:
    - camera image
    - OCR engine
    - neural network
    - barcode/QR reader
"""
function scan_label(image_id::String)

    # Simulated OCR output
    examples = Dict(

        "parcel01" =>
            "42 HIGH STREET\nYORK\nYO1 8QR",

        "parcel02" =>
            "17 KING STREET\nMANCHESTER\nM2 4AA",

        "parcel03" =>
            "8 QUEEN ROAD\nLEEDS\nLS1 2AB",

        "parcel04" =>
            "91 VICTORIA ROAD\nSHEFFIELD\nS1 3AA",

        "parcel05" =>
            "12 CASTLE STREET\nEDINBURGH\nEH1 2AB"
    )

    if haskey(examples, image_id)
        return examples[image_id]
    end

    return ""
end


############################################################
# 3. TEXT NORMALISATION
############################################################

function normalise_text(text::String)

    text = uppercase(text)

    # Convert unusual punctuation to spaces
    text = replace(text, "," => " ")
    text = replace(text, "." => " ")

    # Collapse repeated whitespace
    text = join(split(text), " ")

    return text
end


############################################################
# 4. POSTCODE RECOGNITION
############################################################

"""
Very simplified UK postcode detector.

A production system would use a considerably more
sophisticated postcode grammar and validation database.
"""

function find_postcode(text::String)

    tokens = split(text)

    for token in tokens

        # Common simplified pattern:
        # YO1, M2, LS1, S1, EH1 etc.
        if occursin(r"^[A-Z]{1,2}[0-9]{1,2}$", token)

            index = findfirst(==(token), tokens)

            if index !== nothing && index < length(tokens)

                candidate = token * " " * tokens[index + 1]

                if occursin(
                    r"^[A-Z]{1,2}[0-9]{1,2} [0-9][A-Z]{2}$",
                    candidate
                )
                    return candidate
                end
            end
        end
    end

    return nothing
end


############################################################
# 5. ADDRESS PARSER
############################################################

function parse_address(raw::String)

    text = normalise_text(raw)

    lines = split(raw, '\n')

    lines = [
        strip(uppercase(x))
        for x in lines
        if !isempty(strip(x))
    ]

    house_number = nothing
    street = nothing
    town = nothing
    county = nothing

    # Find postcode first
    postcode = find_postcode(text)

    ########################################################
    # HOUSE NUMBER + STREET
    ########################################################

    if length(lines) >= 1

        first_line = lines[1]

        match_result = match(
            r"^([0-9]+[A-Z]?)\s+(.+)$",
            first_line
        )

        if match_result !== nothing

            house_number = match_result.captures[1]
            street = match_result.captures[2]

        else

            street = first_line

        end
    end

    ########################################################
    # TOWN
    ########################################################

    if length(lines) >= 2
        town = lines[2]
    end

    ########################################################
    # SIMPLE COUNTY INFERENCE
    ########################################################

    if town == "YORK"
        county = "NORTH YORKSHIRE"

    elseif town == "MANCHESTER"
        county = "GREATER MANCHESTER"

    elseif town == "LEEDS"
        county = "WEST YORKSHIRE"

    elseif town == "SHEFFIELD"
        county = "SOUTH YORKSHIRE"

    elseif town == "EDINBURGH"
        county = "CITY OF EDINBURGH"

    end

    return Address(
        raw,
        house_number,
        street,
        town,
        county,
        postcode
    )
end


############################################################
# 6. MACHINE'S "KNOWLEDGE" OF LOCATIONS
############################################################

"""
This is the robot's internal geographical knowledge.

A real system could contain millions of postcode polygons,
addresses, GPS coordinates and sorting routes.
"""

postcode_database = Dict(

    "YO1 8QR" => Location(
        "YORK",
        "NORTH YORKSHIRE",
        53.9590,
        -1.0815
    ),

    "M2 4AA" => Location(
        "MANCHESTER",
        "GREATER MANCHESTER",
        53.4808,
        -2.2426
    ),

    "LS1 2AB" => Location(
        "LEEDS",
        "WEST YORKSHIRE",
        53.8008,
        -1.5491
    ),

    "S1 3AA" => Location(
        "SHEFFIELD",
        "SOUTH YORKSHIRE",
        53.3811,
        -1.4701
    ),

    "EH1 2AB" => Location(
        "EDINBURGH",
        "CITY OF EDINBURGH",
        55.9533,
        -3.1883
    )
)


############################################################
# 7. GEOGRAPHIC REASONING
############################################################

function locate_address(
    address::Address,
    database
)

    if address.postcode !== nothing

        postcode = address.postcode

        if haskey(database, postcode)

            return database[postcode]

        end
    end

    return nothing
end


############################################################
# 8. SORTING NETWORK
############################################################

"""
The warehouse has physical sorting zones.

The machine has learned/been configured with:

    geographic location → conveyor zone → physical bin
"""

sorting_zones = Dict(

    "YORK"       => ("NORTH", 1),
    "LEEDS"      => ("NORTH", 2),
    "SHEFFIELD"  => ("NORTH", 3),
    "MANCHESTER" => ("NORTHWEST", 4),
    "EDINBURGH"  => ("SCOTLAND", 5)
)


############################################################
# 9. DECISION ENGINE
############################################################

function decide_sort(
    address::Address,
    location::Union{Location,Nothing}
)

    if location === nothing

        return SortingDecision(
            address,
            nothing,
            "UNKNOWN",
            -1,
            0.05
        )
    end

    town = location.town

    if haskey(sorting_zones, town)

        zone, bin = sorting_zones[town]

        confidence = 0.99

        return SortingDecision(
            address,
            location,
            zone,
            bin,
            confidence
        )
    end

    return SortingDecision(
        address,
        location,
        "MANUAL_CHECK",
        -1,
        0.40
    )
end


############################################################
# 10. ROBOTIC ARM SIMULATION
############################################################

function move_robot_to_bin(bin::Int)

    if bin < 0
        println("ROBOT: No valid destination.")
        return
    end

    println("ROBOT: Moving arm...")
    sleep(0.2)

    println("ROBOT: Rotating toward BIN $bin")
    sleep(0.2)

    println("ROBOT: Positioning gripper...")
    sleep(0.2)

    println("ROBOT: RELEASE")
    println("ROBOT: Parcel placed in BIN $bin")

end


############################################################
# 11. COMPLETE PERCEPTION PIPELINE
############################################################

function process_parcel(image_id::String)

    println()
    println("======================================")
    println("NEW PARCEL")
    println("======================================")

    ########################################################
    # CAMERA
    ########################################################

    println("CAMERA: scanning label...")

    raw_text = scan_label(image_id)

    println()
    println("OCR OUTPUT:")
    println(raw_text)

    ########################################################
    # LANGUAGE UNDERSTANDING
    ########################################################

    println()
    println("AI: interpreting address...")

    address = parse_address(raw_text)

    println("House:   ", address.house_number)
    println("Street:  ", address.street)
    println("Town:    ", address.town)
    println("County:  ", address.county)
    println("Postcode:", address.postcode)

    ########################################################
    # GEOLOCATION
    ########################################################

    println()
    println("AI: locating address...")

    location = locate_address(
        address,
        postcode_database
    )

    if location !== nothing

        println(
            "LOCATION: ",
            location.town,
            ", ",
            location.county
        )

        println(
            "GPS: ",
            location.latitude,
            ", ",
            location.longitude
        )

    else

        println("LOCATION UNKNOWN")

    end

    ########################################################
    # SORTING
    ########################################################

    println()
    println("AI: determining sorting destination...")

    decision = decide_sort(
        address,
        location
    )

    println(
        "ZONE: ",
        decision.zone
    )

    println(
        "BIN: ",
        decision.bin
    )

    println(
        "CONFIDENCE: ",
        round(decision.confidence * 100, digits=1),
        "%"
    )

    ########################################################
    # ROBOT
    ########################################################

    println()
    println("ROBOTIC SYSTEM:")

    if decision.confidence >= 0.90

        move_robot_to_bin(
            decision.bin
        )

    else

        println(
            "ROBOT: Sending parcel to manual inspection."
        )

    end

    return decision
end


############################################################
# 12. TEST THE MACHINE
############################################################

process_parcel("parcel01")

process_parcel("parcel02")

process_parcel("parcel03")

process_parcel("parcel04")

process_parcel("parcel05")

