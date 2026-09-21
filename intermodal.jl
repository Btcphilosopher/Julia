#!/usr/bin/env julia

# ============================================================
# INTERMODAL CONTAINER UNIVERSAL ID
# CUIN
#
# Globally unique numeric container identification system
#
# Dependencies:
#
#   ] add QRCoders
#
# ============================================================

using SHA
using QRCoders
using Printf
using Dates


# ============================================================
# SYSTEM CONSTANTS
# ============================================================

const CUIN_VERSION = 1

# Container classes
const CONTAINER_DRY       = 10
const CONTAINER_REEFER    = 20
const CONTAINER_TANK      = 30
const CONTAINER_OPEN_TOP  = 40
const CONTAINER_FLAT_RACK = 50
const CONTAINER_SPECIAL   = 90


# ============================================================
# CONTAINER RECORD
# ============================================================

struct Container

    class::Int
    owner::Int
    year::Int
    serial::Int

end


# ============================================================
# CHECK DIGIT
#
# Weighted modular checksum.
#
# This is designed to catch:
#   - single digit errors
#   - many transpositions
#   - accidental truncation
# ============================================================

function check_digit(body::String)

    digits =
        [parse(Int, c) for c in body]

    weights =
        [7, 3, 1, 9, 7, 3, 1, 9, 7, 3,
         1, 9, 7, 3, 1, 9, 7, 3, 1, 9,
         7, 3, 1, 9, 7, 3, 1, 9, 7, 3]

    total = 0

    for i in eachindex(digits)

        weight =
            weights[
                mod1(i, length(weights))
            ]

        total +=
            digits[i] * weight
    end

    return mod(total, 10)
end


# ============================================================
# FORMAT BODY
# ============================================================

function container_body(c::Container)

    return @sprintf(
        "%02d%04d%02d%011d",
        c.class,
        c.owner,
        mod(c.year, 100),
        c.serial
    )
end


# ============================================================
# CREATE CUIN
# ============================================================

function make_cuin(c::Container)

    body =
        container_body(c)

    check =
        check_digit(body)

    return body * string(check)
end


# ============================================================
# VALIDATE CUIN
# ============================================================

function valid_cuin(id::String)

    if length(id) != 20
        return false
    end

    if !all(isdigit, id)
        return false
    end

    body =
        id[1:19]

    supplied =
        parse(Int, id[20])

    calculated =
        check_digit(body)

    return supplied == calculated
end


# ============================================================
# PARSE CUIN
# ============================================================

function parse_cuin(id::String)

    if !valid_cuin(id)
        error("Invalid CUIN")
    end

    class =
        parse(Int, id[1:2])

    owner =
        parse(Int, id[3:6])

    year =
        parse(Int, id[7:8])

    serial =
        parse(Int, id[9:19])

    return Container(
        class,
        owner,
        year,
        serial
    )
end


# ============================================================
# OWNER IDENTIFIER
# ============================================================

"""
Create a deterministic four-digit owner identifier.

In a production implementation this would come from a
centrally allocated registry.
"""

function owner_code(name::String)

    digest =
        bytes2hex(
            sha256(
                lowercase(strip(name))
            )
        )

    value =
        parse(
            UInt64,
            digest[1:12],
            base=16
        )

    return Int(mod(value, UInt64(10000)))
end


# ============================================================
# SERIAL GENERATOR
# ============================================================

"""
Generate a deterministic serial number from:

    owner
    manufacturing year
    local manufacturing sequence
"""

function make_serial(
    owner::Int,
    year::Int,
    sequence::Int
)

    seed =
        "$(owner)-$(year)-$(sequence)"

    digest =
        sha256(seed)

    value =
        zero(UInt64)

    for b in digest[1:8]

        value =
            (value << 8) |
            UInt64(b)
    end

    return Int(
        mod(
            value,
            UInt64(100_000_000_000)
        )
    )
end


# ============================================================
# CONTAINER CREATOR
# ============================================================

function create_container(
    owner_name::String,
    year::Int,
    sequence::Int;
    class::Int = CONTAINER_DRY
)

    owner =
        owner_code(
            owner_name
        )

    serial =
        make_serial(
            owner,
            year,
            sequence
        )

    container =
        Container(
            class,
            owner,
            year,
            serial
        )

    return container
end


# ============================================================
# QR PAYLOAD
# ============================================================

function qr_payload(
    container::Container
)

    id =
        make_cuin(container)

    return """
CUIN:$id
VERSION:$CUIN_VERSION
CLASS:$(container.class)
OWNER:$(container.owner)
YEAR:$(container.year)
SERIAL:$(container.serial)
"""
end


# ============================================================
# QR GENERATOR
# ============================================================

function generate_qr(
    container::Container,
    filename::String
)

    payload =
        qr_payload(container)

    qr =
        qrcode(payload)

    save(
        filename,
        qr
    )

    return payload
end


# ============================================================
# BATCH GENERATOR
# ============================================================

function generate_batch(
    owner_name::String,
    year::Int,
    quantity::Int;
    class::Int = CONTAINER_DRY
)

    containers =
        Container[]

    for sequence in 1:quantity

        container =
            create_container(
                owner_name,
                year,
                sequence,
                class=class
            )

        push!(
            containers,
            container
        )
    end

    return containers
end


# ============================================================
# CSV EXPORT
# ============================================================

function export_csv(
    containers,
    filename
)

    open(filename, "w") do io

        println(
            io,
            "CUIN,CLASS,OWNER,YEAR,SERIAL"
        )

        for c in containers

            id =
                make_cuin(c)

            println(
                io,
                "$id," *
                "$(c.class)," *
                "$(c.owner)," *
                "$(c.year)," *
                "$(c.serial)"
            )
        end
    end
end


# ============================================================
# DISPLAY
# ============================================================

function display_container(
    c::Container
)

    id =
        make_cuin(c)

    println()
    println(
        "======================================"
    )

    println(
        "INTERMODAL CONTAINER"
    )

    println(
        "======================================"
    )

    println(
        "CUIN:       ",
        id
    )

    println(
        "Class:      ",
        c.class
    )

    println(
        "Owner:      ",
        c.owner
    )

    println(
        "Year:       ",
        c.year
    )

    println(
        "Serial:     ",
        c.serial
    )

    println(
        "Valid:      ",
        valid_cuin(id)
    )

    println(
        "======================================"
    )
end


# ============================================================
# EXAMPLE
# ============================================================

function main()

    println(
        "CUIN Container Identity System"
    )

    println()

    # Fictional container operator.
    owner =
        "Aureom Intermodal"

    year =
        2026

    container =
        create_container(
            owner,
            year,
            1
        )

    display_container(
        container
    )

    # Create QR.
    generate_qr(
        container,
        "container_$(make_cuin(container)).png"
    )

    # Generate 1,000 containers.
    fleet =
        generate_batch(
            owner,
            year,
            1_000
        )

    export_csv(
        fleet,
        "container_registry.csv"
    )

    println()
    println(
        "Generated ",
        length(fleet),
        " container identities."
    )

    println(
        "Registry exported."
    )
end


main()
