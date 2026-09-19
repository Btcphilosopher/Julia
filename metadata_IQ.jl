###############################################################
# AUREOM MUSIC METADATA INTELLIGENCE
#
# Small ML-style metadata inference engine.
#
# Evidence sources:
#
#   1. Existing embedded metadata
#   2. Filename
#   3. Directory structure
#   4. Neighbouring tracks
#   5. MusicBrainz
#   6. Optional fingerprint identification
#
# The engine does NOT blindly overwrite metadata.
#
# Every proposed value receives:
#
#       confidence ∈ [0, 1]
#
# The library can then decide:
#
#   >= 0.90  automatic
#   >= 0.75  probably safe
#   >= 0.55  ask user
#   <  0.55  leave unchanged
#
###############################################################

module AureomMetadataAI

using HTTP
using JSON3
using Dates
using SHA


###############################################################
# CONFIG
###############################################################

Base.@kwdef mutable struct AIConfig

    musicbrainz_url::String =
        "https://musicbrainz.org/ws/2"

    user_agent::String =
        "AureomMusic/1.0 (metadata@example.com)"

    automatic_threshold::Float64 =
        0.90

    suggestion_threshold::Float64 =
        0.75

    minimum_threshold::Float64 =
        0.55

    request_delay::Float64 =
        1.05

end


###############################################################
# EVIDENCE
###############################################################

struct Evidence

    source::Symbol

    value::String

    confidence::Float64

    reason::String

end


###############################################################
# INFERRED FIELD
###############################################################

struct InferredField

    field::Symbol

    value::String

    confidence::Float64

    evidence::Vector{Evidence}

end


###############################################################
# METADATA PREDICTION
###############################################################

mutable struct MetadataPrediction

    fields::Dict{
        Symbol,
        InferredField
    }

end


MetadataPrediction() =
    MetadataPrediction(
        Dict{Symbol,InferredField}()
    )


###############################################################
# SAFE NORMALISATION
###############################################################

function normalise(
    value::AbstractString
)

    s =
        lowercase(
            strip(
                String(value)
            )
        )

    s =
        replace(
            s,
            r"\.[a-zA-Z0-9]{2,5}$" => ""
        )

    s =
        replace(
            s,
            '_' => ' '
        )

    s =
        replace(
            s,
            r"\s+" => " "
        )

    return strip(s)

end


###############################################################
# TOKEN SIMILARITY
###############################################################

function similarity(
    a::String,
    b::String
)

    a =
        normalise(a)

    b =
        normalise(b)

    if isempty(a) ||
       isempty(b)

        return 0.0

    end

    if a == b

        return 1.0

    end

    at =
        Set(
            split(a)
        )

    bt =
        Set(
            split(b)
        )

    intersection =
        length(
            intersect(at, bt)
        )

    union_size =
        length(
            union(at, bt)
        )

    if union_size == 0

        return 0.0

    end

    return intersection /
           union_size

end


###############################################################
# FILENAME PARSER
###############################################################

function parse_filename(
    filename::String
)

    name =
        replace(
            basename(filename),
            r"\.[^.]+$" => ""
        )

    name =
        replace(
            name,
            '_' => ' '
        )

    ###########################################################
    # Artist - Title
    ###########################################################

    m =
        match(
            r"^(.+?)\s+-\s+(.+)$",
            name
        )

    if m !== nothing

        return Dict(

            :artist =>
                strip(
                    m.captures[1]
                ),

            :title =>
                strip(
                    m.captures[2]
                )

        )

    end

    ###########################################################
    # 01 Artist - Title
    ###########################################################

    m =
        match(
            r"^\d{1,3}\s*[-.]\s*(.+?)\s+-\s+(.+)$",
            name
        )

    if m !== nothing

        return Dict(

            :artist =>
                strip(
                    m.captures[1]
                ),

            :title =>
                strip(
                    m.captures[2]
                )

        )

    end

    ###########################################################
    # Track number only
    ###########################################################

    m =
        match(
            r"^\d{1,3}\s*[-.]\s*(.+)$",
            name
        )

    if m !== nothing

        return Dict(

            :title =>
                strip(
                    m.captures[1]
                )

        )

    end

    return Dict(
        :title => name
    )

end


###############################################################
# FOLDER INFERENCE
###############################################################

function infer_from_path(
    filepath::String
)

    parts =
        splitpath(
            filepath
        )

    result =
        Dict{Symbol,String}()

    if length(parts) < 2

        return result

    end

    filename =
        parts[end]

    directories =
        parts[
            1:end-1
        ]

    ###########################################################
    # Look for year
    ###########################################################

    for directory in
        directories

        m =
            match(
                r"^(19|20)\d{2}$",
                directory
            )

        if m !== nothing

            result[:year] =
                directory

        end

    end


    ###########################################################
    # Common structure:
    #
    # Music/
    #   Artist/
    #       Album/
    #           01 - Track.flac
    ###########################################################

    if length(directories) >= 2

        result[:album] =
            directories[end]

        result[:artist] =
            directories[end-1]

    end

    return result

end


###############################################################
# LOCAL EVIDENCE
###############################################################

function local_evidence(
    filepath::String,
    existing::Dict{Symbol,String}
)

    evidence =
        Dict{
            Symbol,
            Vector{Evidence}
        }()

    for field in [
        :artist,
        :album,
        :title,
        :year
    ]

        evidence[field] =
            Evidence[]

    end


    ###########################################################
    # Existing tags
    ###########################################################

    for (
        field,
        value
    ) in existing

        if !isempty(
            value
        )

            push!(
                evidence[field],
                Evidence(
                    :embedded,
                    value,
                    0.95,
                    "Existing embedded metadata"
                )
            )

        end

    end


    ###########################################################
    # Filename
    ###########################################################

    filename =
        parse_filename(
            filepath
        )

    for (
        field,
        value
    ) in filename

        push!(
            get!(
                evidence,
                field,
                Evidence[]
            ),
            Evidence(
                :filename,
                value,
                field == :title ?
                    0.82 :
                    0.70,
                "Inferred from filename"
            )
        )

    end


    ###########################################################
    # Folder structure
    ###########################################################

    folders =
        infer_from_path(
            filepath
        )

    for (
        field,
        value
    ) in folders

        push!(
            get!(
                evidence,
                field,
                Evidence[]
            ),
            Evidence(
                :folder,
                value,
                0.68,
                "Inferred from directory structure"
            )
        )

    end

    return evidence

end


###############################################################
# EVIDENCE COMBINATION
#
# This is the small "ML" layer.
#
# Multiple weak signals agreeing become strong evidence.
###############################################################

function combine_evidence(
    evidence::Vector{Evidence}
)

    if isempty(
        evidence
    )

        return nothing

    end

    ###########################################################
    # Group identical values.
    ###########################################################

    groups =
        Dict{
            String,
            Vector{Evidence}
        }()

    for item in evidence

        key =
            normalise(
                item.value
            )

        push!(
            get!(
                groups,
                key,
                Evidence[]
            ),
            item
        )

    end


    ###########################################################
    # Score each candidate.
    ###########################################################

    candidates = []

    for (
        value,
        items
    ) in groups

        score =
            0.0

        #######################################################
        # Independent evidence accumulation
        #######################################################

        remaining =
            1.0

        for item in items

            contribution =
                item.confidence *
                remaining

            score +=
                contribution

            remaining *=
                1.0 -
                item.confidence * 0.35

        end

        #######################################################
        # Agreement bonus
        #######################################################

        if length(items) >= 2

            score +=
                0.08

        end

        if length(items) >= 3

            score +=
                0.07

        end

        score =
            clamp(
                score,
                0.0,
                1.0
            )

        push!(
            candidates,
            (
                value =
                    first(items).value,

                score =
                    score,

                evidence =
                    items
            )
        )

    end


    ###########################################################
    # Best candidate
    ###########################################################

    sort!(
        candidates,
        by = x -> x.score,
        rev = true
    )

    best =
        first(
            candidates
        )

    return best

end


###############################################################
# MUSICBRAINZ SEARCH
###############################################################

function musicbrainz_search(
    artist::String,
    title::String;
    config::AIConfig =
        AIConfig()
)

    query =
        "recording:\"" *
        title *
        "\" AND artist:\"" *
        artist *
        "\""

    url =
        config.musicbrainz_url *
        "/recording/"

    response =
        HTTP.get(
            url,
            [
                "User-Agent",
                config.user_agent
            ],
            query = [
                "query" => query,
                "fmt" => "json",
                "limit" => "5"
            ]
        )

    data =
        JSON3.read(
            String(
                response.body
            )
        )

    sleep(
        config.request_delay
    )

    return data

end


###############################################################
# MUSICBRAINZ CANDIDATE SCORING
###############################################################

function score_musicbrainz_candidate(
    candidate,
    artist::String,
    title::String,
    album::String
)

    score =
        0.0

    ###########################################################
    # Title
    ###########################################################

    if haskey(
        candidate,
        :title
    )

        title_score =
            similarity(
                title,
                String(
                    candidate.title
                )
            )

        score +=
            title_score *
            0.40

    end


    ###########################################################
    # Artist
    ###########################################################

    if haskey(
        candidate,
        Symbol("artist-credit")
    )

        credits =
            candidate[
                Symbol("artist-credit")
            ]

        if length(credits) > 0

            candidate_artist =
                String(
                    credits[1].name
                )

            artist_score =
                similarity(
                    artist,
                    candidate_artist
                )

            score +=
                artist_score *
                0.40

        end

    end


    ###########################################################
    # Release
    ###########################################################

    if haskey(
        candidate,
        :releases
    )

        releases =
            candidate.releases

        if length(releases) > 0

            release =
                releases[1]

            if haskey(
                release,
                :title
            )

                album_score =
                    similarity(
                        album,
                        String(
                            release.title
                        )
                    )

                score +=
                    album_score *
                    0.20

            end

        end

    end

    return clamp(
        score,
        0.0,
        1.0
    )

end


###############################################################
# REMOTE ENRICHMENT
###############################################################

function enrich_from_musicbrainz!(
    prediction::MetadataPrediction,
    artist::String,
    title::String,
    album::String;

    config::AIConfig =
        AIConfig()

)

    try

        response =
            musicbrainz_search(
                artist,
                title;
                config = config
            )

        recordings =
            response.recordings

        if length(
            recordings
        ) == 0

            return prediction

        end

        best =
            nothing

        best_score =
            0.0

        for candidate in
            recordings

            score =
                score_musicbrainz_candidate(
                    candidate,
                    artist,
                    title,
                    album
                )

            if score >
               best_score

                best =
                    candidate

                best_score =
                    score

            end

        end


        if best === nothing

            return prediction

        end


        #######################################################
        # Title
        #######################################################

        if haskey(
            best,
            :title
        )

            value =
                String(
                    best.title
                )

            prediction.fields[:title] =
                InferredField(
                    :title,
                    value,
                    best_score,
                    [
                        Evidence(
                            :musicbrainz,
                            value,
                            best_score,
                            "Matched MusicBrainz recording"
                        )
                    ]
                )

        end


        #######################################################
        # IDs
        #######################################################

        if haskey(
            best,
            :id
        )

            value =
                String(
                    best.id
                )

            prediction.fields[
                :musicbrainz_track_id
            ] =
                InferredField(
                    :musicbrainz_track_id,
                    value,
                    best_score,
                    [
                        Evidence(
                            :musicbrainz,
                            value,
                            best_score,
                            "MusicBrainz recording ID"
                        )
                    ]
                )

        end


    catch error

        @warn(
            "MusicBrainz lookup failed",
            error
        )

    end

    return prediction

end


###############################################################
# MAIN INFERENCE ENGINE
###############################################################

function infer_metadata(
    filepath::String,
    existing::Dict{Symbol,String};

    config::AIConfig =
        AIConfig(),

    remote::Bool = true

)

    prediction =
        MetadataPrediction()


    ###########################################################
    # Local evidence
    ###########################################################

    evidence =
        local_evidence(
            filepath,
            existing
        )


    ###########################################################
    # Resolve local fields
    ###########################################################

    for (
        field,
        items
    ) in evidence

        result =
            combine_evidence(
                items
            )

        if result !== nothing

            prediction.fields[field] =
                InferredField(
                    field,
                    result.value,
                    result.score,
                    result.evidence
                )

        end

    end


    ###########################################################
    # Remote intelligence
    ###########################################################

    if remote

        artist =
            get(
                existing,
                :artist,
                get(
                    Dict(
                        k => v.value
                        for (
                            k,
                            v
                        ) in prediction.fields
                    ),
                    :artist,
                    ""
                )
            )

        title =
            get(
                existing,
                :title,
                get(
                    Dict(
                        k => v.value
                        for (
                            k,
                            v
                        ) in prediction.fields
                    ),
                    :title,
                    ""
                )
            )

        album =
            get(
                existing,
                :album,
                get(
                    Dict(
                        k => v.value
                        for (
                            k,
                            v
                        ) in prediction.fields
                    ),
                    :album,
                    ""
                )
            )

        if !isempty(
            artist
        ) &&
        !isempty(
            title
        )

            enrich_from_musicbrainz!(
                prediction,
                artist,
                title,
                album;
                config = config
            )

        end

    end


    return prediction

end


###############################################################
# DECISION ENGINE
###############################################################

function automatic_changes(
    prediction::MetadataPrediction;

    config::AIConfig =
        AIConfig()

)

    changes =
        Dict{
            Symbol,
            String
        }()

    for (
        field,
        result
    ) in prediction.fields

        if result.confidence >=
           config.automatic_threshold

            changes[field] =
                result.value

        end

    end

    return changes

end


###############################################################
# USER REVIEW
###############################################################

function suggestions(
    prediction::MetadataPrediction;

    config::AIConfig =
        AIConfig()

)

    result = []

    for (
        field,
        prediction_field
    ) in prediction.fields

        if prediction_field.confidence >=
           config.suggestion_threshold &&
           prediction_field.confidence <
           config.automatic_threshold

            push!(
                result,
                prediction_field
            )

        end

    end

    return result

end


###############################################################
# HUMAN-READABLE EXPLANATION
###############################################################

function explain(
    prediction::MetadataPrediction
)

    println()
    println(
        "AUREOM METADATA INTELLIGENCE"
    )
    println(
        "============================="
    )

    for (
        field,
        result
    ) in prediction.fields

        println()
        println(
            field,
            " = ",
            result.value
        )

        println(
            "confidence: ",
            round(
                result.confidence * 100;
                digits = 1
            ),
            "%"
        )

        for evidence in
            result.evidence

            println(
                "  • ",
                evidence.source,
                ": ",
                evidence.reason,
                " (",
                round(
                    evidence.confidence * 100;
                    digits = 1
                ),
                "%)"
            )

        end

    end

end


###############################################################
# EXAMPLE
###############################################################

function demo()

    filepath =
        "/Music/The Beatles/Abbey Road/01 - Come Together.flac"

    existing =
        Dict{Symbol,String}(

            :artist =>
                "The Beatles",

            :title =>
                "",

            :album =>
                "Abbey Road",

            :year =>
                ""

        )


    config =
        AIConfig(
            user_agent =
                "AureomMusic/1.0 (contact@example.com)"
        )


    prediction =
        infer_metadata(
            filepath,
            existing;
            config = config,
            remote = false
        )


    explain(
        prediction
    )


    println()
    println(
        "AUTOMATIC CHANGES"
    )
    println(
        "-----------------"
    )

    changes =
        automatic_changes(
            prediction;
            config = config
        )

    for (
        field,
        value
    ) in changes

        println(
            field,
            " => ",
            value
        )

    end


    return prediction

end


end # module


###############################################################
# RUN
###############################################################

using .AureomMetadataAI

AureomMetadataAI.demo()
