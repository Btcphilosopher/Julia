###############################################################
# INTELLIGENT MUSIC PLAYER + MUSIC ORGANISER
# Julia 1.x
#
# Single-file implementation
#
# Features:
#   - Artists
#   - Albums
#   - Singles
#   - EPs
#   - Compilations
#   - Multiple discs
#   - Natural sorting
#   - Intelligent artist/title normalisation
#   - Edition detection
#   - Duplicate detection
#   - Search
#   - Albums / Singles / Artists views
#   - Playlists
#   - Smart playlists
#   - Queue
#   - Favourites
#   - Play history
#   - Ratings
#   - Library statistics
#   - JSON persistence
#   - Intelligent organisation
#
# Recommended packages:
#
#   ] add JSON
#
###############################################################

module IntelligentMusicPlayer

using JSON
using Dates
using Random
using Unicode

###############################################################
# CONFIGURATION
###############################################################

Base.@kwdef mutable struct Config

    ignore_articles::Bool = true

    articles::Vector{String} = [
        "the",
        "a",
        "an"
    ]

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
        "radio edit",
        "radio",
        "live",
        "acoustic",
        "instrumental",
        "demo"
    ]

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

    fuzzy_threshold::Float64 = 0.82

    music_directory::String = "./Music"

    database_file::String = "./music_library.json"

    history_limit::Int = 1000
end


###############################################################
# MUSIC DATA MODEL
###############################################################

@enum ReleaseType begin
    ALBUM
    SINGLE
    EP
    COMPILATION
    SOUNDTRACK
    LIVE
    MIXTAPE
    UNKNOWN
end


mutable struct Track

    id::String

    title::String

    artist::String

    album::String

    album_artist::String

    year::Int

    track_number::Int

    disc_number::Int

    duration::Float64

    genre::String

    path::String

    release_type::ReleaseType

    edition::String

    featuring::Vector{String}

    composer::String

    publisher::String

    explicit::Bool

    favourite::Bool

    rating::Int

    play_count::Int

    last_played::Union{Nothing,DateTime}

end


mutable struct Album

    id::String

    title::String

    artist::String

    year::Int

    release_type::ReleaseType

    edition::String

    tracks::Vector{String}

    artwork::String
end


mutable struct Artist

    id::String

    name::String

    sort_name::String

    tracks::Vector{String}

    albums::Vector{String}

    singles::Vector{String}
end


mutable struct Playlist

    id::String

    name::String

    tracks::Vector{String}

    smart::Bool

    rule::String
end


mutable struct Library

    tracks::Dict{String,Track}

    albums::Dict{String,Album}

    artists::Dict{String,Artist}

    playlists::Dict{String,Playlist}

    queue::Vector{String}

    queue_position::Int

    history::Vector{String}

    current_track::Union{Nothing,String}

    config::Config
end


###############################################################
# ID GENERATION
###############################################################

function make_id(prefix::String)

    return prefix * "_" *
           string(Dates.value(now())) * "_" *
           randstring(8)

end


###############################################################
# STRING NORMALISATION
###############################################################

function normalise_string(
    value::AbstractString,
    config::Config
)

    s = Unicode.normalize(String(value))

    s = lowercase(s)

    s = replace(
        s,
        "&" => " and ",
        "+" => " and ",
        "_" => " "
    )

    s = replace(
        s,
        r"[^\p{L}\p{N}\s]" => " "
    )

    s = replace(
        s,
        r"\s+" => " "
    )

    return strip(s)

end


###############################################################
# ARTIST SORT NAME
###############################################################

function artist_sort_name(
    artist::AbstractString,
    config::Config
)

    s = normalise_string(
        artist,
        config
    )

    if config.ignore_articles

        for article in config.articles

            prefix = article * " "

            if startswith(s, prefix)

                s = s[
                    length(prefix)+1:end
                ]

                break

            end
        end
    end

    return s

end


###############################################################
# TITLE NORMALISATION
###############################################################

function normalise_title(
    title::AbstractString,
    config::Config
)

    s = lowercase(
        Unicode.normalize(String(title))
    )

    # Remove feature annotations
    s = replace(
        s,
        r"\s*\(feat\.?.*?\)"i => ""
    )

    s = replace(
        s,
        r"\s*\[feat\.?.*?\]"i => ""
    )

    # Remove edition suffixes
    for term in config.edition_terms

        escaped = replace(
            term,
            " " => "\\s+"
        )

        pattern = Regex(
            "\\s*[\\(\\[]?" *
            escaped *
            "[\\)\\]]?\\s*$",
            "i"
        )

        s = replace(
            s,
            pattern => ""
        )
    end

    s = replace(
        s,
        r"[^\p{L}\p{N}\s]" => " "
    )

    s = replace(
        s,
        r"\s+" => " "
    )

    return strip(s)

end


###############################################################
# NATURAL SORT
###############################################################

function natural_key(value::AbstractString)

    parts = Any[]

    for match in eachmatch(
        r"\d+|\D+",
        value
    )

        token = match.match

        if occursin(
            r"^\d+$",
            token
        )

            push!(
                parts,
                parse(Int, token)
            )

        else

            push!(
                parts,
                token
            )

        end

    end

    return parts

end


###############################################################
# RELEASE TYPE HELPERS
###############################################################

function release_symbol(
    value::ReleaseType
)

    return Symbol(
        lowercase(
            string(value)
        )
    )

end


function release_rank(
    type::ReleaseType,
    config::Config
)

    symbol = release_symbol(type)

    position = findfirst(
        ==(symbol),
        config.release_order
    )

    if isnothing(position)
        return 999
    end

    return position

end


###############################################################
# LIBRARY CREATION
###############################################################

function Library(
    config::Config = Config()
)

    return Library(
        Dict{String,Track}(),
        Dict{String,Album}(),
        Dict{String,Artist}(),
        Dict{String,Playlist}(),
        String[],
        1,
        String[],
        nothing,
        config
    )

end


###############################################################
# ADD TRACK
###############################################################

function add_track!(
    library::Library,
    track::Track
)

    library.tracks[track.id] = track

    organise_track!(
        library,
        track
    )

    return track

end


###############################################################
# ORGANISE TRACK
###############################################################

function organise_track!(
    library::Library,
    track::Track
)

    config = library.config

    ###########################################################
    # ARTIST
    ###########################################################

    artist_id = "artist_" *
        artist_sort_name(
            track.album_artist,
            config
        )

    if !haskey(
        library.artists,
        artist_id
    )

        library.artists[artist_id] =
            Artist(
                artist_id,
                track.album_artist,
                artist_sort_name(
                    track.album_artist,
                    config
                ),
                String[],
                String[],
                String[]
            )

    end

    artist = library.artists[
        artist_id
    ]

    if !(track.id in artist.tracks)

        push!(
            artist.tracks,
            track.id
        )

    end

    ###########################################################
    # ALBUM
    ###########################################################

    album_key =
        artist_sort_name(
            track.album_artist,
            config
        ) *
        "::" *
        normalise_title(
            track.album,
            config
        )

    album_id = "album_" *
        bytes2hex(
            sha256(album_key)
        )[1:16]

    if !haskey(
        library.albums,
        album_id
    )

        library.albums[album_id] =
            Album(
                album_id,
                track.album,
                track.album_artist,
                track.year,
                track.release_type,
                track.edition,
                String[],
                ""
            )

    end

    album = library.albums[
        album_id
    ]

    if !(track.id in album.tracks)

        push!(
            album.tracks,
            track.id
        )

    end

    if !(album_id in artist.albums)

        push!(
            artist.albums,
            album_id
        )

    end

    ###########################################################
    # SINGLE INDEX
    ###########################################################

    if track.release_type == SINGLE

        if !(album_id in artist.singles)

            push!(
                artist.singles,
                album_id
            )

        end

    end

end


###############################################################
# SORT TRACKS
###############################################################

function track_sort_key(
    library::Library,
    track::Track
)

    config = library.config

    return (

        natural_key(
            artist_sort_name(
                track.album_artist,
                config
            )
        ),

        natural_key(
            normalise_title(
                track.album,
                config
            )
        ),

        track.year,

        release_rank(
            track.release_type,
            config
        ),

        track.disc_number,

        track.track_number,

        natural_key(
            normalise_title(
                track.title,
                config
            )
        )
    )

end


function sorted_tracks(
    library::Library
)

    tracks = collect(
        values(
            library.tracks
        )
    )

    return sort(
        tracks,
        by = t -> track_sort_key(
            library,
            t
        )
    )

end


###############################################################
# SORT ARTISTS
###############################################################

function sorted_artists(
    library::Library
)

    artists = collect(
        values(
            library.artists
        )
    )

    return sort(
        artists,
        by = a -> natural_key(
            a.sort_name
        )
    )

end


###############################################################
# SORT ALBUMS
###############################################################

function sorted_albums(
    library::Library
)

    albums = collect(
        values(
            library.albums
        )
    )

    return sort(
        albums,
        by = a -> (

            natural_key(
                artist_sort_name(
                    a.artist,
                    library.config
                )
            ),

            a.year,

            release_rank(
                a.release_type,
                library.config
            ),

            natural_key(
                normalise_title(
                    a.title,
                    library.config
                )
            )
        )
    )

end


###############################################################
# SORT TRACKS INSIDE ALBUM
###############################################################

function album_tracks(
    library::Library,
    album_id::String
)

    if !haskey(
        library.albums,
        album_id
    )

        return Track[]

    end

    album = library.albums[
        album_id
    ]

    tracks = [
        library.tracks[id]
        for id in album.tracks
        if haskey(
            library.tracks,
            id
        )
    ]

    return sort(
        tracks,
        by = t -> (
            t.disc_number,
            t.track_number,
            natural_key(
                normalise_title(
                    t.title,
                    library.config
                )
            )
        )
    )

end


###############################################################
# SEARCH
###############################################################

function search_score(
    query::String,
    text::String
)

    q = lowercase(
        strip(query)
    )

    t = lowercase(
        strip(text)
    )

    if q == t
        return 1.0
    end

    if startswith(t, q)
        return 0.95
    end

    if occursin(q, t)
        return 0.90
    end

    # Token overlap
    qtokens = Set(
        split(q)
    )

    ttokens = Set(
        split(t)
    )

    if isempty(qtokens)
        return 0.0
    end

    overlap =
        length(
            intersect(
                qtokens,
                ttokens
            )
        ) /
        length(qtokens)

    return overlap * 0.8

end


function search(
    library::Library,
    query::String
)

    results = Vector{
        Tuple{Float64,Track}
    }()

    for track in values(
        library.tracks
    )

        fields = [
            track.title,
            track.artist,
            track.album,
            track.album_artist,
            track.genre,
            track.composer
        ]

        score = maximum(
            search_score(
                query,
                field
            )
            for field in fields
        )

        # Slight boost for title matches
        title_score = search_score(
            query,
            track.title
        )

        score += title_score * 0.2

        if score > 0.1

            push!(
                results,
                (
                    score,
                    track
                )
            )

        end
    end

    sort!(
        results,
        by = x -> -x[1]
    )

    return results

end


###############################################################
# PLAYLISTS
###############################################################

function create_playlist!(
    library::Library,
    name::String
)

    playlist = Playlist(
        make_id("playlist"),
        name,
        String[],
        false,
        ""
    )

    library.playlists[
        playlist.id
    ] = playlist

    return playlist

end


function add_to_playlist!(
    library::Library,
    playlist_id::String,
    track_id::String
)

    if !haskey(
        library.playlists,
        playlist_id
    )
        return false
    end

    if !haskey(
        library.tracks,
        track_id
    )
        return false
    end

    playlist =
        library.playlists[
            playlist_id
        ]

    if !(track_id in playlist.tracks)

        push!(
            playlist.tracks,
            track_id
        )

    end

    return true

end


###############################################################
# SMART PLAYLISTS
###############################################################

function create_smart_playlist!(
    library::Library,
    name::String,
    rule::String
)

    playlist = Playlist(
        make_id("smart"),
        name,
        String[],
        true,
        rule
    )

    library.playlists[
        playlist.id
    ] = playlist

    refresh_smart_playlist!(
        library,
        playlist.id
    )

    return playlist

end


function rule_matches(
    track::Track,
    rule::String
)

    r = lowercase(
        strip(rule)
    )

    ###########################################################
    # favourite
    ###########################################################

    if r == "favourite"

        return track.favourite

    end

    ###########################################################
    # high rated
    ###########################################################

    if r == "rating >= 4"

        return track.rating >= 4

    end

    ###########################################################
    # singles
    ###########################################################

    if r == "single"

        return track.release_type == SINGLE

    end

    ###########################################################
    # albums
    ###########################################################

    if r == "album"

        return track.release_type == ALBUM

    end

    ###########################################################
    # recent
    ###########################################################

    if startswith(
        r,
        "year >="
    )

        value = strip(
            replace(
                r,
                "year >=" => ""
            )
        )

        return track.year >=
            parse(Int, value)

    end

    ###########################################################
    # genre
    ###########################################################

    if startswith(
        r,
        "genre:"
    )

        genre = strip(
            replace(
                r,
                "genre:" => ""
            )
        )

        return lowercase(
            track.genre
        ) == genre

    end

    return false

end


function refresh_smart_playlist!(
    library::Library,
    playlist_id::String
)

    playlist =
        library.playlists[
            playlist_id
        ]

    empty!(
        playlist.tracks
    )

    for track in values(
        library.tracks
    )

        if rule_matches(
            track,
            playlist.rule
        )

            push!(
                playlist.tracks,
                track.id
            )

        end
    end

    return playlist

end


###############################################################
# FAVOURITES
###############################################################

function set_favourite!(
    library::Library,
    track_id::String,
    value::Bool = true
)

    if !haskey(
        library.tracks,
        track_id
    )
        return false
    end

    library.tracks[
        track_id
    ].favourite = value

    return true

end


###############################################################
# RATINGS
###############################################################

function rate!(
    library::Library,
    track_id::String,
    rating::Int
)

    if !haskey(
        library.tracks,
        track_id
    )
        return false
    end

    rating = clamp(
        rating,
        0,
        5
    )

    library.tracks[
        track_id
    ].rating = rating

    return true

end


###############################################################
# QUEUE
###############################################################

function clear_queue!(
    library::Library
)

    empty!(
        library.queue
    )

    library.queue_position = 1

end


function enqueue!(
    library::Library,
    track_id::String
)

    if haskey(
        library.tracks,
        track_id
    )

        push!(
            library.queue,
            track_id
        )

        return true

    end

    return false

end


function enqueue_tracks!(
    library::Library,
    tracks::Vector{Track}
)

    for track in tracks

        enqueue!(
            library,
            track.id
        )

    end

end


function next_track(
    library::Library
)

    if isempty(
        library.queue
    )

        return nothing

    end

    if library.queue_position >
       length(library.queue)

        return nothing

    end

    id =
        library.queue[
            library.queue_position
        ]

    library.queue_position += 1

    return library.tracks[id]

end


###############################################################
# AUDIO BACKEND
###############################################################

"""
This function is deliberately an abstraction.

A real application can replace this with:

    PortAudio
    LibSndFile
    GStreamer
    FFmpeg
    mpv
    VLC
    CoreAudio
    ALSA
    PipeWire

etc.
"""
function play_file(
    track::Track
)

    println()
    println(
        "▶ PLAYING: ",
        track.artist,
        " — ",
        track.title
    )

    println(
        "  Album: ",
        track.album
    )

    println(
        "  File: ",
        track.path
    )

    return true

end


###############################################################
# PLAY TRACK
###############################################################

function play!(
    library::Library,
    track_id::String
)

    if !haskey(
        library.tracks,
        track_id
    )

        return false

    end

    track =
        library.tracks[
            track_id
        ]

    success = play_file(
        track
    )

    if success

        track.play_count += 1

        track.last_played = now()

        library.current_track =
            track.id

        push!(
            library.history,
            track.id
        )

        # Keep history bounded
        if length(
            library.history
        ) > library.config.history_limit

            deleteat!(
                library.history,
                1
            )

        end

    end

    return success

end


###############################################################
# PLAY ALBUM
###############################################################

function play_album!(
    library::Library,
    album_id::String
)

    tracks = album_tracks(
        library,
        album_id
    )

    clear_queue!(
        library
    )

    enqueue_tracks!(
        library,
        tracks
    )

    next = next_track(
        library
    )

    if next !== nothing

        play!(
            library,
            next.id
        )

    end

end


###############################################################
# PLAY SINGLE
###############################################################

function play_single!(
    library::Library,
    track_id::String
)

    clear_queue!(
        library
    )

    enqueue!(
        library,
        track_id
    )

    next = next_track(
        library
    )

    if next !== nothing

        play!(
            library,
            next.id
        )

    end

end


###############################################################
# NEXT
###############################################################

function next!(
    library::Library
)

    track = next_track(
        library
    )

    if track === nothing

        println(
            "Queue finished."
        )

        return nothing

    end

    play!(
        library,
        track.id
    )

    return track

end


###############################################################
# SHUFFLE
###############################################################

function shuffle_queue!(
    library::Library
)

    if length(
        library.queue
    ) <= 1

        return

    end

    remaining =
        library.queue[
            library.queue_position:end
        ]

    shuffle!(
        remaining
    )

    library.queue[
        library.queue_position:end
    ] = remaining

end


###############################################################
# RECENTLY PLAYED
###############################################################

function recently_played(
    library::Library,
    n::Int = 20
)

    ids = reverse(
        library.history
    )

    ids = ids[
        1:min(
            n,
            length(ids)
        )
    ]

    return [
        library.tracks[id]
        for id in ids
        if haskey(
            library.tracks,
            id
        )
    ]

end


###############################################################
# MOST PLAYED
###############################################################

function most_played(
    library::Library,
    n::Int = 20
)

    tracks = collect(
        values(
            library.tracks
        )
    )

    sort!(
        tracks,
        by = t -> -t.play_count
    )

    return tracks[
        1:min(
            n,
            length(tracks)
        )
    ]

end


###############################################################
# DUPLICATE DETECTION
###############################################################

function duplicate_key(
    library::Library,
    track::Track
)

    return (

        artist_sort_name(
            track.artist,
            library.config
        ),

        normalise_title(
            track.title,
            library.config
        ),

        round(
            track.duration
        )

    )

end


function find_duplicates(
    library::Library
)

    groups =
        Dict{
            Tuple,
            Vector{Track}
        }()

    for track in values(
        library.tracks
    )

        key =
            duplicate_key(
                library,
                track
            )

        if !haskey(
            groups,
            key
        )

            groups[key] =
                Track[]

        end

        push!(
            groups[key],
            track
        )

    end

    return Dict(
        key => tracks
        for (key, tracks) in groups
        if length(tracks) > 1
    )

end


###############################################################
# LIBRARY STATISTICS
###############################################################

function statistics(
    library::Library
)

    tracks =
        collect(
            values(
                library.tracks
            )
        )

    albums =
        collect(
            values(
                library.albums
            )
        )

    artists =
        collect(
            values(
                library.artists
            )
        )

    total_seconds =
        sum(
            t.duration
            for t in tracks
        )

    favourites =
        count(
            t -> t.favourite,
            tracks
        )

    singles =
        count(
            t ->
                t.release_type ==
                SINGLE,
            tracks
        )

    album_tracks =
        count(
            t ->
                t.release_type ==
                ALBUM,
            tracks
        )

    return (

        tracks = length(tracks),

        albums = length(albums),

        artists = length(artists),

        singles = singles,

        album_tracks = album_tracks,

        favourites = favourites,

        hours =
            total_seconds / 3600,

        plays =
            sum(
                t.play_count
                for t in tracks
            )

    )

end


###############################################################
# IMPORT FROM SIMPLE CSV-LIKE FILE
###############################################################

function import_track!(
    library::Library,
    path::String;
    title::String,
    artist::String,
    album::String = "",
    album_artist::String = artist,
    year::Int = 0,
    track_number::Int = 1,
    disc_number::Int = 1,
    duration::Float64 = 0.0,
    genre::String = "",
    release_type::ReleaseType = ALBUM,
    edition::String = ""
)

    track = Track(

        make_id("track"),

        title,

        artist,

        isempty(album) ?
            title :
            album,

        album_artist,

        year,

        track_number,

        disc_number,

        duration,

        genre,

        path,

        release_type,

        edition,

        String[],

        "",

        "",

        false,

        false,

        0,

        0,

        nothing
    )

    add_track!(
        library,
        track
    )

    return track

end


###############################################################
# FILE NAME INTELLIGENCE
###############################################################

function parse_filename(
    filename::String
)

    base = splitext(
        basename(filename)
    )[1]

    # Try:
    #
    # Artist - Title
    #
    match = match(
        r"^(.*?)\s+-\s+(.*?)$",
        base
    )

    if match !== nothing

        artist = strip(
            match.captures[1]
        )

        title = strip(
            match.captures[2]
        )

        return (
            artist = artist,
            title = title
        )

    end

    return (
        artist = "",
        title = base
    )

end


###############################################################
# ORGANISE FILE PATH
###############################################################

function suggested_path(
    library::Library,
    track::Track
)

    artist =
        artist_sort_name(
            track.album_artist,
            library.config
        )

    album =
        track.album

    track_number =
        lpad(
            string(
                track.track_number
            ),
            2,
            '0'
        )

    filename =
        track_number *
        " - " *
        track.title

    return joinpath(
        artist,
        album,
        filename
    )

end


###############################################################
# SMART MUSIC FOLDERS
###############################################################

function organisation_report(
    library::Library
)

    report = String[]

    for track in sorted_tracks(
        library
    )

        old = track.path

        new = suggested_path(
            library,
            track
        )

        push!(
            report,
            old * " -> " * new
        )

    end

    return report

end


###############################################################
# JSON SERIALISATION
###############################################################

function track_dict(
    track::Track
)

    return Dict(

        "id" => track.id,
        "title" => track.title,
        "artist" => track.artist,
        "album" => track.album,
        "album_artist" => track.album_artist,
        "year" => track.year,
        "track_number" => track.track_number,
        "disc_number" => track.disc_number,
        "duration" => track.duration,
        "genre" => track.genre,
        "path" => track.path,
        "release_type" =>
            string(track.release_type),
        "edition" => track.edition,
        "featuring" => track.featuring,
        "composer" => track.composer,
        "publisher" => track.publisher,
        "explicit" => track.explicit,
        "favourite" => track.favourite,
        "rating" => track.rating,
        "play_count" => track.play_count

    )

end


function save_library(
    library::Library,
    filename::String =
        library.config.database_file
)

    data = Dict(

        "tracks" => [
            track_dict(t)
            for t in values(
                library.tracks
            )
        ],

        "playlists" => [
            Dict(
                "id" => p.id,
                "name" => p.name,
                "tracks" => p.tracks,
                "smart" => p.smart,
                "rule" => p.rule
            )
            for p in values(
                library.playlists
            )
        ],

        "history" =>
            library.history

    )

    open(
        filename,
        "w"
    ) do io

        JSON.print(
            io,
            data,
            2
        )

    end

    println(
        "Library saved to ",
        filename
    )

end


###############################################################
# LIBRARY DISPLAY
###############################################################

function show_track(
    track::Track
)

    println(
        lpad(
            string(
                track.track_number
            ),
            2,
            '0'
        ),
        "  ",
        track.artist,
        " — ",
        track.title
    )

end


function show_album(
    library::Library,
    album::Album
)

    println()
    println(
        album.title
    )

    println(
        album.artist,
        " (",
        album.year,
        ")"
    )

    println(
        "Type: ",
        album.release_type
    )

    println(
        "--------------------------------"
    )

    for track in album_tracks(
        library,
        album.id
    )

        show_track(
            track
        )

    end

end


function show_artist(
    library::Library,
    artist::Artist
)

    println()
    println(
        artist.name
    )

    println(
        "Albums: ",
        length(
            artist.albums
        )
    )

    println(
        "Tracks: ",
        length(
            artist.tracks
        )
    )

end


###############################################################
# COMMAND LINE INTERFACE
###############################################################

function print_help()

    println()
    println(
        "INTELLIGENT MUSIC PLAYER"
    )

    println(
        "--------------------------------------"
    )

    println(
        "search <query>"
    )

    println(
        "artists"
    )

    println(
        "albums"
    )

    println(
        "singles"
    )

    println(
        "stats"
    )

    println(
        "recent"
    )

    println(
        "mostplayed"
    )

    println(
        "queue"
    )

    println(
        "next"
    )

    println(
        "shuffle"
    )

    println(
        "duplicates"
    )

    println(
        "help"
    )

    println(
        "quit"
    )

end


###############################################################
# INTERACTIVE PLAYER
###############################################################

function run_cli!(
    library::Library
)

    print_help()

    while true

        print("\nmusic> ")

        input = readline()

        command =
            strip(input)

        if command == "quit"

            break

        elseif command == "help"

            print_help()

        elseif command == "artists"

            for artist in sorted_artists(
                library
            )

                println(
                    artist.name
                )

            end

        elseif command == "albums"

            for album in sorted_albums(
                library
            )

                println(
                    album.artist,
                    " — ",
                    album.title
                )

            end

        elseif command == "singles"

            singles = [
                t
                for t in values(
                    library.tracks
                )
                if t.release_type ==
                   SINGLE
            ]

            sort!(
                singles,
                by = t -> track_sort_key(
                    library,
                    t
                )
            )

            for track in singles

                show_track(
                    track
                )

            end

        elseif command == "stats"

            println(
                statistics(
                    library
                )
            )

        elseif command == "recent"

            for track in recently_played(
                library
            )

                show_track(
                    track
                )

            end

        elseif command == "mostplayed"

            for track in most_played(
                library
            )

                println(
                    track.play_count,
                    " plays — ",
                    track.artist,
                    " — ",
                    track.title
                )

            end

        elseif command == "queue"

            for (i, id) in enumerate(
                library.queue
            )

                marker =
                    i ==
                    library.queue_position ?
                    ">" :
                    " "

                track =
                    library.tracks[id]

                println(
                    marker,
                    " ",
                    track.artist,
                    " — ",
                    track.title
                )

            end

        elseif command == "next"

            next!(
                library
            )

        elseif command == "shuffle"

            shuffle_queue!(
                library
            )

            println(
                "Queue shuffled."
            )

        elseif command == "duplicates"

            duplicates =
                find_duplicates(
                    library
                )

            for (_, tracks) in duplicates

                println()

                for track in tracks

                    println(
                        track.artist,
                        " — ",
                        track.title,
                        " [",
                        track.path,
                        "]"
                    )

                end

            end

        elseif startswith(
            command,
            "search "
        )

            query =
                strip(
                    replace(
                        command,
                        "search " => ""
                    )
                )

            results =
                search(
                    library,
                    query
                )

            for (score, track) in results[1:min(20,length(results))]

                println(
                    round(score; digits=2),
                    "  ",
                    track.artist,
                    " — ",
                    track.title,
                    " [",
                    track.album,
                    "]"
                )

            end

        else

            println(
                "Unknown command. Type 'help'."
            )

        end

    end

end


###############################################################
# DEMONSTRATION LIBRARY
###############################################################

function demo_library()

    library = Library()

    ###########################################################
    # ALBUM
    ###########################################################

    import_track!(
        library,
        "/Music/Beatles/Abbey Road/01 - Come Together.flac",
        title = "Come Together",
        artist = "The Beatles",
        album = "Abbey Road",
        album_artist = "The Beatles",
        year = 1969,
        track_number = 1,
        duration = 259,
        genre = "Rock",
        release_type = ALBUM
    )

    import_track!(
        library,
        "/Music/Beatles/Abbey Road/02 - Something.flac",
        title = "Something",
        artist = "The Beatles",
        album = "Abbey Road",
        album_artist = "The Beatles",
        year = 1969,
        track_number = 2,
        duration = 182,
        genre = "Rock",
        release_type = ALBUM
    )

    ###########################################################
    # SINGLE
    ###########################################################

    import_track!(
        library,
        "/Music/Taylor Swift/Anti-Hero.flac",
        title = "Anti-Hero",
        artist = "Taylor Swift",
        album = "Anti-Hero",
        album_artist = "Taylor Swift",
        year = 2022,
        track_number = 1,
        duration = 200,
        genre = "Pop",
        release_type = SINGLE
    )

    ###########################################################
    # ANOTHER SINGLE
    ###########################################################

    import_track!(
        library,
        "/Music/A Band/Beautiful Song.flac",
        title = "Beautiful Song",
        artist = "A Band",
        album = "Beautiful Song",
        album_artist = "A Band",
        year = 2026,
        track_number = 1,
        duration = 300,
        genre = "Electronic",
        release_type = SINGLE
    )

    return library

end


###############################################################
# MAIN
###############################################################

function main()

    println()
    println(
        "AUREOM INTELLIGENT MUSIC PLAYER"
    )

    println(
        "Julia music library engine"
    )

    println()

    library =
        demo_library()

    stats =
        statistics(
            library
        )

    println(
        "Library loaded:"
    )

    println(
        "  Artists: ",
        stats.artists
    )

    println(
        "  Albums: ",
        stats.albums
    )

    println(
        "  Tracks: ",
        stats.tracks
    )

    println(
        "  Singles: ",
        stats.singles
    )

    println()

    run_cli!(
        library
    )

end


end # module


###############################################################
# RUN
###############################################################

using .IntelligentMusicPlayer

IntelligentMusicPlayer.main()

