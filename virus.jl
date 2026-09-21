#!/usr/bin/env julia

# ============================================================
# NimbleAV - Small Virus Scanner in Julia
#
# Features:
#   - Recursive directory scanning
#   - SHA-256 hashing
#   - Known-malware hash database
#   - Byte signatures
#   - Lightweight heuristics
#   - Suspicion scoring
#   - CSV-style reporting
#
# Usage:
#   julia scanner.jl /path/to/scan
# ============================================================

using SHA
using Dates

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

const MAX_FILE_SIZE = 512 * 1024 * 1024       # 512 MB
const READ_CHUNK    = 1024 * 1024             # 1 MB

# Known malicious SHA-256 hashes can be added here.
const BAD_HASHES = Set{String}([
    # Example:
    # "0123456789abcdef..."
])

# Simple byte signatures.
#
# These are intentionally generic examples rather than
# signatures for a particular malware family.
const BYTE_SIGNATURES = [
    ("SuspiciousPowerShellMarker",
        UInt8[0x70,0x6F,0x77,0x65,0x72,0x73,0x68,0x65,0x6C,0x6C]),

    ("SuspiciousScriptDownloadMarker",
        UInt8[0x44,0x6F,0x77,0x6E,0x6C,0x6F,0x61,0x64,0x53,0x74,0x72,0x69,0x6E,0x67]),

    ("EmbeddedExecutableMarker",
        UInt8[0x4D,0x5A]),

    ("ELFExecutable",
        UInt8[0x7F,0x45,0x4C,0x46])
]

# ------------------------------------------------------------
# Utilities
# ------------------------------------------------------------

function readable_size(n::Integer)
    units = ["B", "KB", "MB", "GB"]

    x = Float64(n)
    i = 1

    while x >= 1024 && i < length(units)
        x /= 1024
        i += 1
    end

    return @sprintf("%.1f %s", x, units[i])
end


function sha256_file(path::String)
    ctx = SHA.sha256_ctx()

    open(path, "r") do io
        buffer = Vector{UInt8}(undef, READ_CHUNK)

        while !eof(io)
            n = readbytes!(io, buffer)

            if n > 0
                SHA.update!(ctx, buffer[1:n])
            end
        end
    end

    return bytes2hex(SHA.final!(ctx))
end


# ------------------------------------------------------------
# Byte pattern search
# ------------------------------------------------------------

function contains_pattern(data::Vector{UInt8},
                          pattern::Vector{UInt8})

    plen = length(pattern)
    dlen = length(data)

    plen == 0 && return false
    plen > dlen && return false

    for i in 1:(dlen - plen + 1)

        match = true

        @inbounds for j in 1:plen
            if data[i+j-1] != pattern[j]
                match = false
                break
            end
        end

        match && return true
    end

    return false
end


function scan_signatures(path::String)

    findings = String[]

    open(path, "r") do io

        # Read only the first 4 MB for lightweight scanning.
        data = read(io, min(MAX_FILE_SIZE, 4 * 1024 * 1024))

        for (name, signature) in BYTE_SIGNATURES

            if contains_pattern(data, signature)
                push!(findings, name)
            end
        end
    end

    return findings
end


# ------------------------------------------------------------
# Extension heuristics
# ------------------------------------------------------------

const SCRIPT_EXTENSIONS = Set([
    ".ps1",
    ".vbs",
    ".vbe",
    ".js",
    ".jse",
    ".bat",
    ".cmd",
    ".hta",
    ".wsf",
    ".wsh"
])

const EXECUTABLE_EXTENSIONS = Set([
    ".exe",
    ".dll",
    ".scr",
    ".com"
])

const ARCHIVE_EXTENSIONS = Set([
    ".zip",
    ".rar",
    ".7z",
    ".iso"
])


function extension_score(path::String)

    ext = lowercase(splitext(path)[2])

    if ext in SCRIPT_EXTENSIONS
        return 2
    elseif ext in EXECUTABLE_EXTENSIONS
        return 1
    elseif ext in ARCHIVE_EXTENSIONS
        return 1
    end

    return 0
end


# ------------------------------------------------------------
# Filename heuristics
# ------------------------------------------------------------

const SUSPICIOUS_NAMES = [
    "keylogger",
    "credential",
    "stealer",
    "ransom",
    "payload",
    "backdoor",
    "inject",
    "miner",
    "dropper"
]


function filename_score(path::String)

    name = lowercase(basename(path))
    score = 0

    for keyword in SUSPICIOUS_NAMES

        if occursin(keyword, name)
            score += 3
        end

    end

    return score
end


# ------------------------------------------------------------
# Entropy calculation
# ------------------------------------------------------------

function entropy(data::Vector{UInt8})

    isempty(data) && return 0.0

    counts = zeros(Int, 256)

    @inbounds for b in data
        counts[Int(b) + 1] += 1
    end

    result = 0.0
    n = length(data)

    for c in counts

        if c == 0
            continue
        end

        p = c / n
        result -= p * log2(p)
    end

    return result
end


function entropy_score(path::String)

    open(path, "r") do io

        data = read(io, min(1024 * 1024, MAX_FILE_SIZE))

        e = entropy(data)

        # High entropy can occur in encrypted/compressed data.
        # It is therefore only a weak signal.
        if e >= 7.8
            return 1
        end

    end

    return 0
end


# ------------------------------------------------------------
# Single-file scanner
# ------------------------------------------------------------

struct ScanResult

    path::String
    hash::String
    score::Int
    status::String
    findings::Vector{String}

end


function scan_file(path::String)

    findings = String[]
    score = 0

    # ----------------------------------------
    # File size
    # ----------------------------------------

    filesize = try
        stat(path).size
    catch
        return ScanResult(
            path,
            "",
            0,
            "ERROR",
            ["Unable to stat file"]
        )
    end

    if filesize > MAX_FILE_SIZE

        push!(
            findings,
            "File exceeds scanner size limit"
        )

        return ScanResult(
            path,
            "",
            0,
            "SKIPPED",
            findings
        )
    end

    # ----------------------------------------
    # Hash
    # ----------------------------------------

    hash = try
        sha256_file(path)
    catch err

        return ScanResult(
            path,
            "",
            0,
            "ERROR",
            ["Hashing failed: $(typeof(err))"]
        )
    end

    # ----------------------------------------
    # Known hash
    # ----------------------------------------

    if hash in BAD_HASHES

        push!(
            findings,
            "Known malicious SHA-256"
        )

        score += 100
    end

    # ----------------------------------------
    # Byte signatures
    # ----------------------------------------

    try

        sigs = scan_signatures(path)

        for sig in sigs
            push!(findings, "Signature: $sig")
            score += 10
        end

    catch

        push!(
            findings,
            "Signature scan failed"
        )
    end

    # ----------------------------------------
    # Filename heuristics
    # ----------------------------------------

    fs = filename_score(path)

    if fs > 0
        push!(
            findings,
            "Suspicious filename"
        )

        score += fs
    end

    # ----------------------------------------
    # Extension heuristics
    # ----------------------------------------

    es = extension_score(path)

    if es > 0

        push!(
            findings,
            "Potentially executable/script file"
        )

        score += es
    end

    # ----------------------------------------
    # Entropy
    # ----------------------------------------

    try

        entropy_points = entropy_score(path)

        if entropy_points > 0

            push!(
                findings,
                "High entropy"
            )

            score += entropy_points
        end

    catch

        # Entropy is optional.
    end

    # ----------------------------------------
    # Classification
    # ----------------------------------------

    status =
        if score >= 100
            "MALICIOUS"
        elseif score >= 10
            "SUSPICIOUS"
        else
            "CLEAN"
        end

    return ScanResult(
        path,
        hash,
        score,
        status,
        findings
    )
end


# ------------------------------------------------------------
# Recursive scanner
# ------------------------------------------------------------

function scan_directory(root::String)

    results = ScanResult[]

    for (dir, dirs, files) in walkdir(root)

        # Avoid common system pseudo-filesystems.
        dirs[:] = filter(
            d -> d != ".git" &&
                 d != "node_modules",
            dirs
        )

        for file in files

            path = joinpath(dir, file)

            try

                result = scan_file(path)

                push!(results, result)

                print_result(result)

            catch err

                println(
                    "[ERROR] $path :: ",
                    typeof(err)
                )

            end
        end
    end

    return results
end


# ------------------------------------------------------------
# Output
# ------------------------------------------------------------

function print_result(r::ScanResult)

    println()

    println(
        "[$(r.status)] ",
        r.path
    )

    println(
        "  SHA256: ",
        r.hash
    )

    println(
        "  Score:  ",
        r.score
    )

    if !isempty(r.findings)

        for finding in r.findings
            println("  -> ", finding)
        end

    end
end


function print_summary(results)

    clean = count(r -> r.status == "CLEAN", results)
    suspicious = count(r -> r.status == "SUSPICIOUS", results)
    malicious = count(r -> r.status == "MALICIOUS", results)
    skipped = count(r -> r.status == "SKIPPED", results)
    errors = count(r -> r.status == "ERROR", results)

    println()
    println("========================================")
    println("             SCAN COMPLETE")
    println("========================================")

    println("Files scanned : ", length(results))
    println("Clean         : ", clean)
    println("Suspicious    : ", suspicious)
    println("Malicious     : ", malicious)
    println("Skipped       : ", skipped)
    println("Errors        : ", errors)
end


# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

function main()

    if length(ARGS) != 1

        println(
            "Usage: julia scanner.jl <directory-or-file>"
        )

        exit(1)
    end

    target = abspath(ARGS[1])

    if !ispath(target)

        println("Path does not exist: ", target)
        exit(1)
    end

    println("========================================")
    println("              NimbleAV")
    println("       Lightweight Julia Scanner")
    println("========================================")

    println("Target: ", target)
    println("Started: ", now())

    results = ScanResult[]

    if isfile(target)

        push!(
            results,
            scan_file(target)
        )

        print_result(results[end])

    else

        results = scan_directory(target)

    end

    print_summary(results)

    println()
    println("Finished: ", now())
end


main()

