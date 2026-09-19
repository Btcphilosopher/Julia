module IntelligentMusicSort

using Unicode

export Track,
       MusicSortConfig,
       intelligent_sort,
       sort_artists,
       sort_albums,
       sort_tracks,
       normalise_name,
       normalise_title


# ============================================================
# DATA MODEL
# ============================================================

struct Track
    id::String
    title::String
    artist::String
    album::String
    album_artist::String
    year::Int
    track_number::Int
    disc_number::Int
    duration::Float64

    # album / release metadata
    release_type::Symbol
    edition::String
    explicit::Bool
end


# ============================================================
# CONFIGURATION
# ============================================================

Base.@kwdef struct MusicSortConfig

    # Ignore leading articles when alphabetising.
    ignore_articles::Bool = true

    # Articles recognised by the sorter.
    articles::Vector{String} = ["the", "a", "an"]

    # Remove punctuation during comparison.
    strip_punctuation::Bool = true

    # Case-insensitive sorting.
    case_insensitive::Bool = true

    # Natural number ordering.
    natural_numbers::Bool = true

    # Group album editions together.
    group_editions::Bool = true

    # Preferred release ordering.
    release_order::Vector{Symbol} = [
        :album,
        :ep,
        :single,
        :compilation,
        :soundtrack,
        :live,
        :mixtape,
        :unknown
    ]

    # Common suffixes which should not dominate alphabetical order.
    edition_terms::Vector{String} = [
        "deluxe edition",
        "deluxe",
        "expanded edition",
        "expanded",
        "remastered",
        "remaster",
        "anniversary edition",
        "anniversary",
        "special edition",
        "special",
        "bonus tracks",
        "bonus",
        "live",
        "acoustic",
        "radio edit",
        "edit"
    ]
end


# ============================================================
# TEXT NORMALISATION
# ============================================================

"""
    normalise_name(name, config)

Convert an artist/name into a canonical comparison representation.
"""
function normalise_name(
    name::AbstractString,
    config::MusicSortConfig = MusicSortConfig()
)

    s = String(name)

    # Unicode normalisation
    s = Unicode.normalize(s)

    # Lowercase
    if config.case_insensitive
        s = lowercase(s)
    end

    # Replace common separators
    s = replace(s,
        "&" => " and ",
        "+" => " and ",
        "_" => " ",
        "-" => " "
    )

    # Remove punctuation
    if config.strip_punctuation
        s = replace(s, r"[^\p{L}\p{N}\s]" => " ")
    end

    # Collapse whitespace
    s = replace(s, r"\s+" => " ")
    s = strip(s)

    # Ignore leading article
    if config.ignore_articles
        for article in config.articles
            prefix = article * " "

            if startswith(s, prefix)
                s = s[length(prefix)+1:end]
                break
            end
        end
    end

    return s
end


"""
    normalise_title(title, config)

Normalise a song or album title while preserving useful semantics.
"""
function normalise_title(
    title::AbstractString,
    config::MusicSortConfig = MusicSortConfig()
)

    s = String(title)

    s = Unicode.normalize(s)

    if config.case_insensitive
        s = lowercase(s)
    end

    # Remove common feature notation from primary sorting.
    s = replace(s,
        r"\s*\(feat\.?.*?\)"i => "",
        r"\s*\[feat\.?.*?\]"i => "",
        r"\s+ft\.?.*$"i => ""
    )

    # Remove edition suffixes.
    for term in config.edition_terms
        pattern = Regex(
            "\\s*[\\(\\[]?\\b" *
            replace(term, " " => "\\s+") *
            "\\b[\\)\\]]?\\s*$",
            "i"
        )

        s = replace(s, pattern => "")
    end

    if config.strip_punctuation
        s = replace(s, r"[^\p{L}\p{N}\s]" => " ")
    end

    s = replace(s, r"\s+" => " ")
    s = strip(s)

    return s
end


# ============================================================
# NATURAL SORTING
# ============================================================

"""
Split a string into textual and numeric components.

"Album 10" becomes:
["album ", 10]

allowing:

Album 2
Album 9
Album 10

instead of ordinary lexicographic ordering.
"""
function natural_key(s::AbstractString)

    parts = Any[]

    for m in eachmatch(r"\d+|\D+", s)

        token = m.match

        if occursin(r"^\d+$", token)
            push!(parts, parse(Int, token))
        else
            push!(parts, token)
        end
    end

    return parts
end


# ============================================================
# EDITION ANALYSIS
# ============================================================

function detect_edition(
    album::AbstractString,
    config::MusicSortConfig
)

    s = lowercase(album)

    for term in config.edition_terms

        if occursin(term, s)
            return term
        end

    end

    return ""
end


function edition_rank(
    album::AbstractString,
    config::MusicSortConfig
)

    edition = detect_edition(album, config)

    if edition == ""
        return 0
    end

    # Original/default release gets highest priority.
    if edition in ["remastered", "remaster"]
        return 2
    elseif edition in ["deluxe edition", "deluxe"]
        return 3
    elseif edition in ["expanded edition", "expanded"]
        return 4
    elseif edition in ["anniversary edition", "anniversary"]
        return 5
    elseif edition in ["live"]
        return 6
    else
        return 10
    end
end


# ============================================================
# RELEASE TYPE
# ============================================================

function release_rank(
    type::Symbol,
    config::MusicSortConfig
)

    i = findfirst(==(type), config.release_order)

    return isnothing(i) ? length(config.release_order) + 1 : i
end


# ============================================================
# TRACK SORT KEY
# ============================================================

function track_key(
    track::Track,
    config::MusicSortConfig
)

    artist = normalise_name(track.album_artist, config)

    album = normalise_title(track.album, config)

    title = normalise_title(track.title, config)

    return (

        # Primary artist grouping
        natural_key(artist),

        # Album grouping
        natural_key(album),

        # Release year
        track.year,

        # Edition grouping
        edition_rank(track.album, config),

        # Disc
        track.disc_number,

        # Track position
        track.track_number,

        # Finally title
        natural_key(title),

        # Stable ID
        track.id
    )
end


# ============================================================
# MAIN TRACK SORT
# ============================================================

function intelligent_sort(
    tracks::Vector{Track};
    config::MusicSortConfig = MusicSortConfig()
)

    return sort(
        tracks,
        by = x -> track_key(x, config)
    )
end


# ============================================================
# ARTIST SORTING
# ============================================================

function sort_artists(
    artists::Vector{String};
    config::MusicSortConfig = MusicSortConfig()
)

    return sort(
        artists,
        by = x -> natural_key(
            normalise_name(x, config)
        )
    )
end


# ============================================================
# ALBUM SORTING
# ============================================================

function sort_albums(
    albums::Vector{Track};
    config::MusicSortConfig = MusicSortConfig()
)

    return sort(
        albums,
        by = x -> (

            natural_key(
                normalise_name(
                    x.album_artist,
                    config
                )
            ),

            x.year,

            release_rank(
                x.release_type,
                config
            ),

            edition_rank(
                x.album,
                config
            ),

            natural_key(
                normalise_title(
                    x.album,
                    config
                )
            )
        )
    )
end


# ============================================================
# SMART GROUPING
# ============================================================

"""
Group tracks into albums.

Returns:

Dict(
    album_key => [Track, Track, ...]
)
"""
function group_albums(
    tracks::Vector{Track};
    config::MusicSortConfig = MusicSortConfig()
)

    groups = Dict{String, Vector{Track}}()

    for track in tracks

        key = string(
            normalise_name(track.album_artist, config),
            "::",
            normalise_title(track.album, config)
        )

        if !haskey(groups, key)
            groups[key] = Track[]
        end

        push!(groups[key], track)
    end

    # Sort tracks within each album
    for (_, album_tracks) in groups

        sort!(
            album_tracks,
            by = x -> (
                x.disc_number,
                x.track_number,
                natural_key(
                    normalise_title(
                        x.title,
                        config
                    )
                )
            )
        )

    end

    return groups
end


# ============================================================
# SMART DUPLICATE DETECTION
# ============================================================

"""
Generate a comparison key useful for detecting likely duplicates.

Examples:

"AC/DC"
"A.C.D.C."

can resolve to the same comparison representation.
"""
function duplicate_key(
    track::Track;
    config::MusicSortConfig = MusicSortConfig()
)

    return (

        normalise_name(
            track.artist,
            config
        ),

        normalise_title(
            track.title,
            config
        ),

        round(track.duration; digits = 0)
    )
end


function find_duplicates(
    tracks::Vector{Track};
    config::MusicSortConfig = MusicSortConfig()
)

    index = Dict{Tuple, Vector{Track}}()

    for track in tracks

        key = duplicate_key(
            track;
            config = config
        )

        if !haskey(index, key)
            index[key] = Track[]
        end

        push!(index[key], track)
    end

    return Dict(
        k => v
        for (k, v) in index
        if length(v) > 1
    )
end


end # module

