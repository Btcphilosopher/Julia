###############################################################
# AUREOM MUSIC METADATA STANDARDISER
#
# Standardises music metadata into a consistent internal model.
#
# Handles:
#   - Artist names
#   - Album artists
#   - Album titles
#   - Track titles
#   - Featuring artists
#   - Disc numbers
#   - Track numbers
#   - Release years
#   - Genres
#   - Album types
#   - Compilation flags
#   - Sort names
#   - Search names
#   - Edition / version information
#   - Explicit tags
#   - ISRC / catalogue numbers
#   - Metadata confidence
#
# This module standardises metadata IN MEMORY.
# It does not overwrite audio files.
#
###############################################################

module AureomMusicStandardiser

using Dates
using Unicode


###############################################################
# ENUMERATIONS
###############################################################

@enum ReleaseType begin

    ALBUM

    EP

    SINGLE

    COMPILATION

    LIVE

    SOUNDTRACK

    MIXTAPE

    BOOTLEG

    UNKNOWN

end


###############################################################
# STANDARD TRACK
###############################################################

mutable struct StandardTrack

    # Identity

    title::String

    artist::String

    album::String

    album_artist::String

    sort_artist::String

    sort_album_artist::String

    sort_album::String

    sort_title::String

    # Release

    release_type::ReleaseType

    release_year::Int

    release_date::Union{
        Nothing,
        Date
    }

    edition::String

    # Track position

    disc_number::Int

    disc_total::Int

    track_number::Int

    track_total::Int

    # Classification

    genres::Vector{String}

    compilation::Bool

    explicit::Bool

    # Credits

    featuring::Vector{String}

    composers::Vector{String}

    producers::Vector{String}

    # External IDs

    isrc::String

    catalog_number::String

    barcode::String

    musicbrainz_track_id::String

    musicbrainz_release_id::String

    musicbrainz_artist_id::String

    # Technical

    source_file::String

    metadata_confidence::Float64

end


###############################################################
# STANDARDISER CONFIG
###############################################################

Base.@kwdef mutable struct StandardiserConfig

    remove_articles_from_sort_names::Bool = true

    articles::Vector{String} = [

        "the",
        "a",
        "an"

    ]

    normalise_ampersands::Bool = true

    normalise_quotes::Bool = true

    normalise_dashes::Bool = true

    normalise_whitespace::Bool = true

    remove_file_extensions::Bool = true

    infer_release_type::Bool = true

    infer_featuring_artists::Bool = true

    infer_explicit::Bool = true

    clean_edition_names::Bool = true

    minimum_year::Int = 1900

    maximum_year::Int =
        year(today()) + 2

end


###############################################################
# TEXT NORMALISATION
###############################################################

function clean_text(
    value::AbstractString,
    config::StandardiserConfig
)

    s =
        String(value)

    ###########################################################
    # Unicode
    ###########################################################

    s =
        Unicode.normalize(
            s
        )

    ###########################################################
    # Quotes
    ###########################################################

    if config.normalise_quotes

        s =
            replace(
                s,
                '“' => '"',
                '”' => '"',
                '‘' => '\'',
                '’' => '\''
            )

    end

    ###########################################################
    # Ampersands
    ###########################################################

    if config.normalise_ampersands

        s =
            replace(
                s,
                r"\s*&\s*" => " & "
            )

    end

    ###########################################################
    # Dashes
    ###########################################################

    if config.normalise_dashes

        s =
            replace(
                s,
                '–' => '-',
                '—' => '-',
                '−' => '-'
            )

    end

    ###########################################################
    # Whitespace
    ###########################################################

    if config.normalise_whitespace

        s =
            replace(
                s,
                r"\s+" => " "
            )

    end

    return strip(
        s
    )

end


###############################################################
# NORMALISED SEARCH STRING
###############################################################

function search_normalise(
    value::AbstractString
)

    s =
        lowercase(
            String(value)
        )

    s =
        Unicode.normalize(
            s
        )

    s =
        replace(
            s,
            r"[^\p{L}\p{N}\s]" => " "
        )

    s =
        replace(
            s,
            r"\s+" => " "
        )

    return strip(
        s
    )

end


###############################################################
# SORT NAME
###############################################################

function make_sort_name(
    value::AbstractString,
    config::StandardiserConfig
)

    s =
        clean_text(
            value,
            config
        )

    if !config.remove_articles_from_sort_names

        return s

    end

    lower =
        lowercase(s)

    for article in config.articles

        prefix =
            article * " "

        if startswith(
            lower,
            prefix
        )

            return s[
                length(prefix)+1:end
            ] *
            ", " *
            s[
                1:length(prefix)-1
            ]

        end

    end

    return s

end


###############################################################
# CLEAN ARTIST
###############################################################

function standardise_artist(
    artist::AbstractString,
    config::StandardiserConfig
)

    s =
        clean_text(
            artist,
            config
        )

    # Remove common accidental tag prefixes.

    prefixes = [

        "artist:",
        "artist -",
        "artist - "

    ]

    lower =
        lowercase(s)

    for prefix in prefixes

        if startswith(
            lower,
            prefix
        )

            s =
                strip(
                    s[
                        length(prefix)+1:end
                    ]
                )

            break

        end

    end

    return s

end


###############################################################
# CLEAN ALBUM
###############################################################

function standardise_album(
    album::AbstractString,
    config::StandardiserConfig
)

    s =
        clean_text(
            album,
            config
        )

    # Common malformed release suffixes.

    replacements = [

        r"\s+\[Explicit\]$" => "",

        r"\s+\(Explicit\)$" => "",

        r"\s+\[Clean\]$" => "",

        r"\s+\(Clean\)$" => ""

    ]

    for replacement in replacements

        s =
            replace(
                s,
                replacement
            )

    end

    return strip(s)

end


###############################################################
# CLEAN TRACK TITLE
###############################################################

function standardise_title(
    title::AbstractString,
    config::StandardiserConfig
)

    s =
        clean_text(
            title,
            config
        )

    ###########################################################
    # Remove obvious track-number prefixes
    #
    # 01 - Song
    # 01. Song
    # 1 Song
    ###########################################################

    s =
        replace(
            s,
            r"^\d{1,3}\s*[-.]\s*" => ""
        )

    ###########################################################
    # Remove obvious disc prefixes
    ###########################################################

    s =
        replace(
            s,
            r"^\d+\s*-\s*\d+\s*[-.]\s*" => ""
        )

    return strip(s)

end


###############################################################
# FEATURE EXTRACTION
###############################################################

function extract_features(
    title::String
)

    featuring =
        String[]

    cleaned =
        title

    ###########################################################
    # feat.
    ###########################################################

    pattern =
        r"\s*[\(\[]?\s*(?:feat\.|featuring|ft\.)\s+([^\)\]]+)[\)\]]?"

    match_result =
        match(
            pattern,
            cleaned;
            overlap = false
        )

    if match_result !== nothing

        names =
            match_result.captures[1]

        if names !== nothing

            for name in split(
                names,
                r"\s*(?:,|&|\band\b)\s*"
            )

                name =
                    strip(
                        name
                    )

                if !isempty(name)

                    push!(
                        featuring,
                        name
                    )

                end

            end

        end

        cleaned =
            replace(
                cleaned,
                pattern => ""
            )

    end

    return (

        strip(cleaned),

        unique(featuring)

    )

end


###############################################################
# EDITION EXTRACTION
###############################################################

function extract_edition(
    album::String
)

    patterns = [

        r"\s*\((Deluxe(?: Edition)?)\)$"i,

        r"\s*\((Expanded(?: Edition)?)\)$"i,

        r"\s*\((Special(?: Edition)?)\)$"i,

        r"\s*\((Anniversary(?: Edition)?)\)$"i,

        r"\s*\[(Deluxe(?: Edition)?)\]$"i,

        r"\s*\[(Expanded(?: Edition)?)\]$"i,

        r"\s*\[(Remastered)\]$"i,

        r"\s*\((Remastered)\)$"i

    ]

    for pattern in patterns

        m =
            match(
                pattern,
                album
            )

        if m !== nothing

            edition =
                strip(
                    m.captures[1]
                )

            base =
                replace(
                    album,
                    pattern => ""
                )

            return (
                strip(base),
                edition
            )

        end

    end

    return (
        album,
        ""
    )

end


###############################################################
# EXPLICIT DETECTION
###############################################################

function detect_explicit(
    title::String,
    album::String,
    existing::Bool,
    config::StandardiserConfig
)

    if !config.infer_explicit

        return existing

    end

    text =
        lowercase(
            title *
            " " *
            album
        )

    explicit_patterns = [

        "[explicit]",

        "(explicit)",

        "explicit",

        "[dirty]",

        "(dirty)"

    ]

    for pattern in
        explicit_patterns

        if occursin(
            pattern,
            text
        )

            return true

        end

    end

    return existing

end


###############################################################
# RELEASE TYPE INFERENCE
###############################################################

function infer_release_type(
    album::String,
    track_count::Int,
    existing::ReleaseType,
    config::StandardiserConfig
)

    if !config.infer_release_type

        return existing

    end

    if existing != UNKNOWN

        return existing

    end

    lower =
        lowercase(
            album
        )

    ###########################################################
    # SINGLE
    ###########################################################

    if occursin(
        r"\bsingle\b",
        lower
    )

        return SINGLE

    end

    ###########################################################
    # EP
    ###########################################################

    if occursin(
        r"\bep\b",
        lower
    )

        return EP

    end

    ###########################################################
    # COMPILATION
    ###########################################################

    if occursin(
        r"\b(compilation|greatest hits|best of)\b",
        lower
    )

        return COMPILATION

    end

    ###########################################################
    # TRACK COUNT HEURISTIC
    ###########################################################

    if track_count == 1

        return SINGLE

    elseif track_count <= 6

        return EP

    else

        return ALBUM

    end

end


###############################################################
# GENRE STANDARDISATION
###############################################################

const GENRE_MAP = Dict(

    "hip hop" => "Hip-Hop",

    "hip-hop" => "Hip-Hop",

    "hiphop" => "Hip-Hop",

    "r&b" => "R&B",

    "rnb" => "R&B",

    "rhythm and blues" => "R&B",

    "edm" => "Electronic",

    "electronica" => "Electronic",

    "electronic music" => "Electronic",

    "drum and bass" => "Drum & Bass",

    "dnb" => "Drum & Bass",

    "uk garage" => "UK Garage",

    "synthpop" => "Synth-Pop",

    "synth pop" => "Synth-Pop",

    "indie rock" => "Indie Rock",

    "alt rock" => "Alternative Rock",

    "alternative" => "Alternative",

    "rock & roll" => "Rock & Roll",

    "rock n roll" => "Rock & Roll"

)


function standardise_genre(
    genre::AbstractString
)

    cleaned =
        search_normalise(
            genre
        )

    if haskey(
        GENRE_MAP,
        cleaned
    )

        return GENRE_MAP[
            cleaned
        ]

    end

    # Title case ordinary genres.

    return titlecase(
        cleaned
    )

end


function standardise_genres(
    genres::Vector{String}
)

    result =
        String[]

    for genre in genres

        g =
            standardise_genre(
                genre
            )

        if !isempty(g) &&
           !(g in result)

            push!(
                result,
                g
            )

        end

    end

    return result

end


###############################################################
# YEAR VALIDATION
###############################################################

function standardise_year(
    year_value,
    config::StandardiserConfig
)

    year =
        try

            Int(year_value)

        catch

            0

        end

    if year <
       config.minimum_year ||
       year >
       config.maximum_year

        return 0

    end

    return year

end


###############################################################
# DATE
###############################################################

function standardise_date(
    value
)

    if value === nothing

        return nothing

    end

    if value isa Date

        return value

    end

    text =
        strip(
            String(value)
        )

    formats = [

        dateformat"yyyy-mm-dd",

        dateformat"yyyy/mm/dd",

        dateformat"dd/mm/yyyy"

    ]

    for format in formats

        try

            return Date(
                text,
                format
            )

        catch

        end

    end

    return nothing

end


###############################################################
# TRACK NUMBER
###############################################################

function clean_track_number(
    value
)

    if value isa Integer

        return Int(value)

    end

    text =
        strip(
            String(value)
        )

    # "03/12"

    m =
        match(
            r"^(\d+)\s*/\s*(\d+)$",
            text
        )

    if m !== nothing

        return (

            parse(
                Int,
                m.captures[1]
            ),

            parse(
                Int,
                m.captures[2]
            )

        )

    end

    # "03"

    m =
        match(
            r"^\d+$",
            text
        )

    if m !== nothing

        return (
            parse(
                Int,
                text
            ),
            0
        )

    end

    return (
        0,
        0
    )

end


###############################################################
# DISC NUMBER
###############################################################

function clean_disc_number(
    value
)

    if value isa Integer

        return (
            Int(value),
            0
        )

    end

    text =
        strip(
            String(value)
        )

    m =
        match(
            r"^(\d+)\s*/\s*(\d+)$",
            text
        )

    if m !== nothing

        return (

            parse(
                Int,
                m.captures[1]
            ),

            parse(
                Int,
                m.captures[2]
            )

        )

    end

    m =
        match(
            r"^\d+$",
            text
        )

    if m !== nothing

        return (
            parse(
                Int,
                text
            ),
            0
        )

    end

    return (
        1,
        1
    )

end


###############################################################
# STANDARDISE ONE TRACK
###############################################################

function standardise!(
    track::StandardTrack;

    config::StandardiserConfig =
        StandardiserConfig(),

    album_track_count::Int = 0

)

    ###########################################################
    # BASIC TEXT
    ###########################################################

    track.artist =
        standardise_artist(
            track.artist,
            config
        )

    track.album_artist =
        standardise_artist(
            track.album_artist,
            config
        )

    track.album =
        standardise_album(
            track.album,
            config
        )

    track.title =
        standardise_title(
            track.title,
            config
        )


    ###########################################################
    # FEATURED ARTISTS
    ###########################################################

    if config.infer_featuring_artists

        cleaned,
        featuring =
            extract_features(
                track.title
            )

        track.title =
            cleaned

        append!(
            track.featuring,
            featuring
        )

        track.featuring =
            unique(
                track.featuring
            )

    end


    ###########################################################
    # EDITION
    ###########################################################

    if config.clean_edition_names

        base,
        edition =
            extract_edition(
                track.album
            )

        if isempty(
            track.edition
        )

            track.edition =
                edition

        end

        track.album =
            base

    end


    ###########################################################
    # SORT NAMES
    ###########################################################

    track.sort_artist =
        make_sort_name(
            track.artist,
            config
        )

    track.sort_album_artist =
        make_sort_name(
            track.album_artist,
            config
        )

    track.sort_album =
        make_sort_name(
            track.album,
            config
        )

    track.sort_title =
        make_sort_name(
            track.title,
            config
        )


    ###########################################################
    # SEARCH
    ###########################################################

    track.title =
        clean_text(
            track.title,
            config
        )

    track.album =
        clean_text(
            track.album,
            config
        )


    ###########################################################
    # EXPLICIT
    ###########################################################

    track.explicit =
        detect_explicit(
            track.title,
            track.album,
            track.explicit,
            config
        )


    ###########################################################
    # GENRES
    ###########################################################

    track.genres =
        standardise_genres(
            track.genres
        )


    ###########################################################
    # RELEASE DATE
    ###########################################################

    track.release_date =
        standardise_date(
            track.release_date
        )


    ###########################################################
    # RELEASE YEAR
    ###########################################################

    if track.release_year == 0 &&
       track.release_date !== nothing

        track.release_year =
            year(
                track.release_date
            )

    end

    track.release_year =
        standardise_year(
            track.release_year,
            config
        )


    ###########################################################
    # RELEASE TYPE
    ###########################################################

    track.release_type =
        infer_release_type(
            track.album,
            album_track_count,
            track.release_type,
            config
        )


    ###########################################################
    # NUMBERS
    ###########################################################

    track.disc_number =
        max(
            track.disc_number,
            1
        )

    track.track_number =
        max(
            track.track_number,
            1
        )


    ###########################################################
    # CONFIDENCE
    ###########################################################

    track.metadata_confidence =
        calculate_confidence(
            track
        )

    return track

end


###############################################################
# CONFIDENCE
###############################################################

function calculate_confidence(
    track::StandardTrack
)

    score =
        0.0

    ###########################################################
    # BASIC IDENTITY
    ###########################################################

    if !isempty(
        track.title
    )

        score += 0.20

    end

    if !isempty(
        track.artist
    )

        score += 0.20

    end

    if !isempty(
        track.album
    )

        score += 0.20

    end

    if !isempty(
        track.album_artist
    )

        score += 0.10

    end

    ###########################################################
    # POSITION
    ###########################################################

    if track.track_number > 0

        score += 0.10

    end

    ###########################################################
    # YEAR
    ###########################################################

    if track.release_year > 0

        score += 0.05

    end

    ###########################################################
    # GENRE
    ###########################################################

    if !isempty(
        track.genres
    )

        score += 0.05

    end

    ###########################################################
    # IDs
    ###########################################################

    if !isempty(
        track.musicbrainz_track_id
    )

        score += 0.05

    end

    if !isempty(
        track.isrc
    )

        score += 0.05

    end

    return clamp(
        score,
        0.0,
        1.0
    )

end


###############################################################
# STANDARDISE LIBRARY
###############################################################

function standardise_library!(
    tracks::Vector{
        StandardTrack
    };

    config::StandardiserConfig =
        StandardiserConfig()

)

    ###########################################################
    # Determine track counts
    ###########################################################

    album_counts =
        Dict{
            String,
            Int
        }()

    for track in tracks

        key =
            search_normalise(
                track.album
            )

        album_counts[key] =
            get(
                album_counts,
                key,
                0
            ) + 1

    end


    ###########################################################
    # Standardise
    ###########################################################

    for track in tracks

        count =
            get(
                album_counts,
                search_normalise(
                    track.album
                ),
                0
            )

        standardise!(
            track,
            config = config,
            album_track_count = count
        )

    end


    ###########################################################
    # Resolve album artists
    ###########################################################

    infer_album_artists!(
        tracks
    )


    ###########################################################
    # Sort
    ###########################################################

    sort!(
        tracks,
        by = track -> (

            search_normalise(
                track.sort_album_artist
            ),

            search_normalise(
                track.sort_album
            ),

            track.disc_number,

            track.track_number

        )
    )

    return tracks

end


###############################################################
# ALBUM ARTIST INFERENCE
###############################################################

function infer_album_artists!(
    tracks::Vector{
        StandardTrack
    }
)

    groups =
        Dict{
            String,
            Vector{
                StandardTrack
            }
        }()

    for track in tracks

        key =
            search_normalise(
                track.album
            )

        if !haskey(
            groups,
            key
        )

            groups[key] =
                StandardTrack[]

        end

        push!(
            groups[key],
            track
        )

    end


    for group in values(
        groups
    )

        if isempty(
            group
        )

            continue

        end

        # Existing album artist wins.

        existing =
            findfirst(
                t ->
                    !isempty(
                        t.album_artist
                    ),
                group
            )

        if existing !== nothing

            canonical =
                group[existing].album_artist

            for track in group

                if isempty(
                    track.album_artist
                )

                    track.album_artist =
                        canonical

                end

            end

        else

            # If every track has same artist,
            # use that artist.

            artists =
                unique(
                    t.artist
                    for t in group
                )

            if length(artists) == 1

                for track in group

                    track.album_artist =
                        first(artists)

                end

            end

        end

    end

    return tracks

end


###############################################################
# DUPLICATE METADATA DETECTION
###############################################################

function metadata_key(
    track::StandardTrack
)

    return (

        search_normalise(
            track.artist
        ),

        search_normalise(
            track.album
        ),

        track.disc_number,

        track.track_number,

        search_normalise(
            track.title
        )

    )

end


function find_metadata_duplicates(
    tracks::Vector{
        StandardTrack
    }
)

    groups =
        Dict{
            Tuple,
            Vector{
                StandardTrack
            }
        }()

    for track in tracks

        key =
            metadata_key(
                track
            )

        if !haskey(
            groups,
            key
        )

            groups[key] =
                StandardTrack[]

        end

        push!(
            groups[key],
            track
        )

    end

    return Dict(

        key => value

        for (
            key,
            value
        ) in groups

        if length(value) > 1

    )

end


###############################################################
# ALBUM ID
###############################################################

function album_key(
    track::StandardTrack
)

    return (

        search_normalise(
            track.album_artist
        ),

        search_normalise(
            track.album
        ),

        track.release_year,

        track.edition

    )

end


###############################################################
# GROUP INTO ALBUMS
###############################################################

function group_albums(
    tracks::Vector{
        StandardTrack
    }
)

    albums =
        Dict{
            Tuple,
            Vector{
                StandardTrack
            }
        }()

    for track in tracks

        key =
            album_key(
                track
            )

        if !haskey(
            albums,
            key
        )

            albums[key] =
                StandardTrack[]

        end

        push!(
            albums[key],
            track
        )

    end


    ###########################################################
    # Sort tracks inside each album
    ###########################################################

    for album in values(
        albums
    )

        sort!(
            album,
            by = x -> (

                x.disc_number,

                x.track_number

            )
        )

    end

    return albums

end


###############################################################
# PRINT REPORT
###############################################################

function report(
    tracks::Vector{
        StandardTrack
    }
)

    println()
    println(
        "AUREOM MUSIC METADATA REPORT"
    )
    println(
        "================================"
    )

    println(
        "Tracks: ",
        length(tracks)
    )

    albums =
        group_albums(
            tracks
        )

    println(
        "Albums: ",
        length(albums)
    )

    duplicates =
        find_metadata_duplicates(
            tracks
        )

    println(
        "Potential duplicates: ",
        length(duplicates)
    )

    confidence =
        isempty(tracks) ?
        0.0 :
        sum(
            t.metadata_confidence
            for t in tracks
        ) /
        length(tracks)

    println(
        "Average metadata confidence: ",
        round(
            confidence * 100;
            digits = 1
        ),
        "%"
    )

    println()

    for track in tracks

        println(
            track.album_artist,
            " — ",
            track.album,
            " — ",
            track.track_number,
            ". ",
            track.title
        )

        println(
            "    Type: ",
            track.release_type
        )

        println(
            "    Year: ",
            track.release_year
        )

        println(
            "    Confidence: ",
            round(
                track.metadata_confidence * 100;
                digits = 1
            ),
            "%"
        )

    end

end


###############################################################
# EXAMPLE
###############################################################

function demo()

    tracks = [

        StandardTrack(

            "01 - Come Together",

            "The Beatles",

            "Abbey Road",

            "",

            "",

            "",

            "",

            "",

            UNKNOWN,

            1969,

            nothing,

            "",

            1,

            1,

            1,

            17,

            ["rock", "Rock & Roll"],

            false,

            false,

            String[],

            String[],

            String[],

            "",

            "",

            "",

            "",

            "",

            "",

            "",

            "./music/01 - Come Together.flac",

            0.0

        ),

        StandardTrack(

            "Something (feat. Example Artist)",

            "The Beatles",

            "Abbey Road (Remastered)",

            "The Beatles",

            "",

            "",

            "",

            "",

            UNKNOWN,

            1969,

            nothing,

            "",

            1,

            1,

            2,

            17,

            ["rock"],

            false,

            false,

            String[],

            String[],

            String[],

            "",

            "",

            "",

            "",

            "",

            "",

            "",

            "./music/02 - Something.flac",

            0.0

        )

    ]

    config =
        StandardiserConfig()

    standardise_library!(
        tracks,
        config = config
    )

    report(
        tracks
    )

    return tracks

end


end # module


###############################################################
# RUN
###############################################################

using .AureomMusicStandardiser

tracks =
    AureomMusicStandardiser.demo()
    
