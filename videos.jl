###############################################################
# AUREOM VIDEO LIBRARY
#
# Films + TV + Music Videos
#
# Designed to sit beside:
#
#     IntelligentMusicPlayer
#
# in the same Julia application.
#
# Features:
#   - Films
#   - TV series
#   - Seasons
#   - Episodes
#   - TV specials
#   - Music videos
#   - Collections / franchises
#   - Genres
#   - Directors
#   - Cast
#   - Years
#   - Ratings
#   - Favourites
#   - Watch history
#   - Continue watching
#   - Resume position
#   - Watch statistics
#   - Search
#   - Smart collections
#   - Queue
#   - Natural sorting
#   - Duplicate detection
#   - Filesystem organisation
#
###############################################################

module IntelligentVideoLibrary

using JSON
using Dates
using Random
using Unicode


###############################################################
# CONFIGURATION
###############################################################

Base.@kwdef mutable struct VideoConfig

    video_directory::String = "./Videos"

    database_file::String =
        "./video_library.json"

    ignore_articles::Bool = true

    articles::Vector{String} = [
        "the",
        "a",
        "an"
    ]

    watch_history_limit::Int = 1000

    resume_threshold::Float64 = 0.05

    completion_threshold::Float64 = 0.90

end


###############################################################
# VIDEO TYPES
###############################################################

@enum VideoType begin

    FILM

    TV_EPISODE

    TV_SPECIAL

    MUSIC_VIDEO

    TRAILER

    CONCERT

    DOCUMENTARY

    SHORT_FILM

    UNKNOWN

end


###############################################################
# VIDEO ITEM
###############################################################

mutable struct Video

    id::String

    title::String

    sort_title::String

    video_type::VideoType

    year::Int

    duration::Float64

    path::String

    thumbnail::String

    description::String

    genres::Vector{String}

    director::String

    writers::Vector{String}

    cast::Vector{String}

    studio::String

    country::String

    language::String

    rating::Float64

    explicit::Bool

    favourite::Bool

    watched::Bool

    watch_count::Int

    resume_position::Float64

    last_watched::Union{
        Nothing,
        DateTime
    }

    date_added::DateTime

    # TV metadata

    series_id::String

    series_name::String

    season_number::Int

    episode_number::Int

    episode_title::String

    # Music video metadata

    music_artist::String

    music_track::String

    music_album::String

    music_year::Int

end


###############################################################
# FILM COLLECTION
###############################################################

mutable struct FilmCollection

    id::String

    name::String

    films::Vector{String}

    description::String

end


###############################################################
# TV SERIES
###############################################################

mutable struct TVSeries

    id::String

    name::String

    sort_name::String

    year::Int

    description::String

    genres::Vector{String}

    network::String

    seasons::Vector{Int}

    episodes::Vector{String}

    artwork::String

end


###############################################################
# SMART COLLECTION
###############################################################

mutable struct SmartCollection

    id::String

    name::String

    rule::String

    videos::Vector{String}

end


###############################################################
# VIDEO LIBRARY
###############################################################

mutable struct VideoLibrary

    videos::Dict{
        String,
        Video
    }

    films::Dict{
        String,
        Video
    }

    series::Dict{
        String,
        TVSeries
    }

    collections::Dict{
        String,
        FilmCollection
    }

    smart_collections::Dict{
        String,
        SmartCollection
    }

    watch_history::Vector{
        String
    }

    queue::Vector{
        String
    }

    queue_position::Int

    current_video::Union{
        Nothing,
        String
    }

    config::VideoConfig

end


###############################################################
# CONSTRUCTOR
###############################################################

function VideoLibrary(
    config::VideoConfig =
        VideoConfig()
)

    return VideoLibrary(

        Dict{String,Video}(),

        Dict{String,Video}(),

        Dict{String,TVSeries}(),

        Dict{
            String,
            FilmCollection
        }(),

        Dict{
            String,
            SmartCollection
        }(),

        String[],

        String[],

        1,

        nothing,

        config

    )

end


###############################################################
# ID
###############################################################

function make_id(
    prefix::String
)

    return prefix *
        "_" *
        string(
            Dates.value(now())
        ) *
        "_" *
        randstring(8)

end


###############################################################
# NORMALISATION
###############################################################

function normalise(
    text::AbstractString,
    config::VideoConfig
)

    s = Unicode.normalize(
        String(text)
    )

    s = lowercase(s)

    s = replace(
        s,
        "&" => " and "
    )

    s = replace(
        s,
        r"[^\p{L}\p{N}\s]" => " "
    )

    s = replace(
        s,
        r"\s+" => " "
    )

    s = strip(s)

    if config.ignore_articles

        for article in config.articles

            prefix =
                article * " "

            if startswith(
                s,
                prefix
            )

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
# NATURAL SORTING
###############################################################

function natural_key(
    text::AbstractString
)

    result = Any[]

    for match in eachmatch(
        r"\d+|\D+",
        text
    )

        token =
            match.match

        if occursin(
            r"^\d+$",
            token
        )

            push!(
                result,
                parse(
                    Int,
                    token
                )
            )

        else

            push!(
                result,
                token
            )

        end

    end

    return result

end


###############################################################
# ADD VIDEO
###############################################################

function add_video!(
    library::VideoLibrary,
    video::Video
)

    library.videos[
        video.id
    ] = video

    if video.video_type == FILM

        library.films[
            video.id
        ] = video

    end

    if video.video_type ==
       TV_EPISODE ||
       video.video_type ==
       TV_SPECIAL

        register_tv_episode!(
            library,
            video
        )

    end

    return video

end


###############################################################
# REGISTER TV
###############################################################

function register_tv_episode!(
    library::VideoLibrary,
    video::Video
)

    series_name =
        video.series_name

    if isempty(series_name)

        return

    end

    series_id =
        "series_" *
        normalise(
            series_name,
            library.config
        )

    video.series_id =
        series_id

    if !haskey(
        library.series,
        series_id
    )

        library.series[
            series_id
        ] = TVSeries(

            series_id,

            series_name,

            normalise(
                series_name,
                library.config
            ),

            video.year,

            video.description,

            copy(
                video.genres
            ),

            video.studio,

            Int[],

            String[],

            video.thumbnail

        )

    end

    series =
        library.series[
            series_id
        ]

    if !(video.id in
         series.episodes)

        push!(
            series.episodes,
            video.id
        )

    end

    if !(video.season_number in
         series.seasons)

        push!(
            series.seasons,
            video.season_number
        )

    end

    sort!(
        series.seasons
    )

end


###############################################################
# FILM SORT
###############################################################

function film_sort_key(
    library::VideoLibrary,
    film::Video
)

    return (

        natural_key(
            film.sort_title
        ),

        film.year,

        film.duration

    )

end


function films(
    library::VideoLibrary
)

    result =
        collect(
            values(
                library.films
            )
        )

    return sort(
        result,
        by = x ->
            film_sort_key(
                library,
                x
            )
    )

end


###############################################################
# TV SORT
###############################################################

function series_sort_key(
    library::VideoLibrary,
    series::TVSeries
)

    return (

        natural_key(
            series.sort_name
        ),

        series.year

    )

end


function sorted_series(
    library::VideoLibrary
)

    result =
        collect(
            values(
                library.series
            )
        )

    return sort(
        result,
        by = x ->
            series_sort_key(
                library,
                x
            )
    )

end


###############################################################
# SERIES EPISODES
###############################################################

function series_episodes(
    library::VideoLibrary,
    series_id::String
)

    if !haskey(
        library.series,
        series_id
    )

        return Video[]

    end

    series =
        library.series[
            series_id
        ]

    episodes = [

        library.videos[id]

        for id in series.episodes

        if haskey(
            library.videos,
            id
        )

    ]

    return sort(
        episodes,
        by = x -> (

            x.season_number,

            x.episode_number,

            natural_key(
                normalise(
                    x.episode_title,
                    library.config
                )
            )

        )
    )

end


###############################################################
# SEASON
###############################################################

function season_episodes(
    library::VideoLibrary,
    series_id::String,
    season_number::Int
)

    return [

        video

        for video in
            series_episodes(
                library,
                series_id
            )

        if video.season_number ==
           season_number

    ]

end


###############################################################
# MUSIC VIDEO SORT
###############################################################

function music_videos(
    library::VideoLibrary
)

    videos = [

        v

        for v in values(
            library.videos
        )

        if v.video_type ==
           MUSIC_VIDEO

    ]

    return sort(
        videos,
        by = v -> (

            natural_key(
                normalise(
                    v.music_artist,
                    library.config
                )
            ),

            v.music_year,

            natural_key(
                normalise(
                    v.music_track,
                    library.config
                )
            )

        )
    )

end


###############################################################
# SEARCH
###############################################################

function text_score(
    query::String,
    text::String
)

    q =
        lowercase(
            strip(query)
        )

    t =
        lowercase(
            strip(text)
        )

    if isempty(q) ||
       isempty(t)

        return 0.0

    end

    if q == t

        return 1.0

    end

    if startswith(
        t,
        q
    )

        return 0.95

    end

    if occursin(
        q,
        t
    )

        return 0.90

    end

    qtokens =
        Set(split(q))

    ttokens =
        Set(split(t))

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
    library::VideoLibrary,
    query::String
)

    results =
        Vector{
            Tuple{
                Float64,
                Video
            }
        }()

    for video in values(
        library.videos
    )

        fields = String[

            video.title,

            video.sort_title,

            video.description,

            video.director,

            video.series_name,

            video.episode_title,

            video.music_artist,

            video.music_track,

            video.music_album,

            video.studio

        ]

        append!(
            fields,
            video.cast
        )

        append!(
            fields,
            video.genres
        )

        score =
            maximum(
                text_score(
                    query,
                    field
                )
                for field in fields
            )

        # Title gets additional weight

        score +=
            text_score(
                query,
                video.title
            ) * 0.25

        if score > 0.1

            push!(
                results,
                (
                    score,
                    video
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
# WATCH STATE
###############################################################

function watch_progress(
    video::Video
)

    if video.duration <= 0

        return 0.0

    end

    return clamp(
        video.resume_position /
        video.duration,

        0.0,

        1.0
    )

end


###############################################################
# PLAY VIDEO
###############################################################

function play_video_backend(
    video::Video
)

    println()

    println(
        "▶ PLAYING VIDEO"
    )

    println(
        video.title
    )

    if video.video_type ==
       TV_EPISODE

        println(
            "S",
            video.season_number,
            " E",
            video.episode_number,
            " — ",
            video.episode_title
        )

    end

    println(
        video.path
    )

    return true

end


###############################################################
# START PLAYBACK
###############################################################

function play!(
    library::VideoLibrary,
    video_id::String
)

    if !haskey(
        library.videos,
        video_id
    )

        return false

    end

    video =
        library.videos[
            video_id
        ]

    success =
        play_video_backend(
            video
        )

    if success

        library.current_video =
            video.id

        video.watch_count += 1

        video.last_watched =
            now()

        push!(
            library.watch_history,
            video.id
        )

        if length(
            library.watch_history
        ) >
        library.config.watch_history_limit

            deleteat!(
                library.watch_history,
                1
            )

        end

    end

    return success

end


###############################################################
# UPDATE POSITION
###############################################################

function update_position!(
    library::VideoLibrary,
    video_id::String,
    seconds::Float64
)

    if !haskey(
        library.videos,
        video_id
    )

        return false

    end

    video =
        library.videos[
            video_id
        ]

    video.resume_position =
        clamp(
            seconds,
            0.0,
            video.duration
        )

    progress =
        watch_progress(
            video
        )

    if progress >=
       library.config.completion_threshold

        video.watched = true

        video.resume_position = 0.0

    elseif progress >=
           library.config.resume_threshold

        video.watched = false

    end

    return true

end


###############################################################
# MARK WATCHED
###############################################################

function mark_watched!(
    library::VideoLibrary,
    video_id::String,
    value::Bool = true
)

    if !haskey(
        library.videos,
        video_id
    )

        return false

    end

    video =
        library.videos[
            video_id
        ]

    video.watched = value

    if value

        video.resume_position =
            0.0

    end

    return true

end


###############################################################
# FAVOURITE
###############################################################

function favourite!(
    library::VideoLibrary,
    video_id::String,
    value::Bool = true
)

    if !haskey(
        library.videos,
        video_id
    )

        return false

    end

    library.videos[
        video_id
    ].favourite = value

    return true

end


###############################################################
# CONTINUE WATCHING
###############################################################

function continue_watching(
    library::VideoLibrary
)

    videos = [

        video

        for video in values(
            library.videos
        )

        if !video.watched &&
           video.resume_position > 0

    ]

    return sort(
        videos,
        by = x ->
            x.last_watched === nothing ?
            DateTime(1900) :
            x.last_watched,
        rev = true
    )

end


###############################################################
# RECENTLY WATCHED
###############################################################

function recently_watched(
    library::VideoLibrary,
    n::Int = 20
)

    ids =
        reverse(
            library.watch_history
        )

    ids =
        ids[
            1:min(
                n,
                length(ids)
            )
        ]

    return [

        library.videos[id]

        for id in ids

        if haskey(
            library.videos,
            id
        )

    ]

end


###############################################################
# QUEUE
###############################################################

function clear_queue!(
    library::VideoLibrary
)

    empty!(
        library.queue
    )

    library.queue_position =
        1

end


function enqueue!(
    library::VideoLibrary,
    video_id::String
)

    if haskey(
        library.videos,
        video_id
    )

        push!(
            library.queue,
            video_id
        )

        return true

    end

    return false

end


function next!(
    library::VideoLibrary
)

    if library.queue_position >
       length(library.queue)

        return nothing

    end

    id =
        library.queue[
            library.queue_position
        ]

    library.queue_position += 1

    play!(
        library,
        id
    )

    return library.videos[id]

end


###############################################################
# FILM COLLECTIONS
###############################################################

function create_collection!(
    library::VideoLibrary,
    name::String,
    description::String = ""
)

    collection =
        FilmCollection(

            make_id(
                "collection"
            ),

            name,

            String[],

            description

        )

    library.collections[
        collection.id
    ] = collection

    return collection

end


function add_to_collection!(
    library::VideoLibrary,
    collection_id::String,
    video_id::String
)

    if !haskey(
        library.collections,
        collection_id
    )

        return false

    end

    if !haskey(
        library.videos,
        video_id
    )

        return false

    end

    collection =
        library.collections[
            collection_id
        ]

    if !(video_id in
         collection.films)

        push!(
            collection.films,
            video_id
        )

    end

    return true

end


###############################################################
# SMART COLLECTIONS
###############################################################

function create_smart_collection!(
    library::VideoLibrary,
    name::String,
    rule::String
)

    collection =
        SmartCollection(

            make_id(
                "smart"
            ),

            name,

            rule,

            String[]

        )

    library.smart_collections[
        collection.id
    ] = collection

    refresh_smart_collection!(
        library,
        collection.id
    )

    return collection

end


function matches_rule(
    video::Video,
    rule::String
)

    r =
        lowercase(
            strip(rule)
        )

    ###########################################################
    # FAVOURITES
    ###########################################################

    if r == "favourite"

        return video.favourite

    end

    ###########################################################
    # UNWATCHED
    ###########################################################

    if r == "unwatched"

        return !video.watched

    end

    ###########################################################
    # FILMS
    ###########################################################

    if r == "film"

        return video.video_type ==
               FILM

    end

    ###########################################################
    # MUSIC VIDEOS
    ###########################################################

    if r == "music video"

        return video.video_type ==
               MUSIC_VIDEO

    end

    ###########################################################
    # TV
    ###########################################################

    if r == "tv"

        return video.video_type ==
               TV_EPISODE ||
               video.video_type ==
               TV_SPECIAL

    end

    ###########################################################
    # RECENT FILMS
    ###########################################################

    if startswith(
        r,
        "year >="
    )

        value =
            strip(
                replace(
                    r,
                    "year >=" => ""
                )
            )

        return video.year >=
            parse(
                Int,
                value
            )

    end

    ###########################################################
    # GENRE
    ###########################################################

    if startswith(
        r,
        "genre:"
    )

        genre =
            strip(
                replace(
                    r,
                    "genre:" => ""
                )
            )

        return any(
            lowercase(g) == genre
            for g in video.genres
        )

    end

    ###########################################################
    # HIGH RATING
    ###########################################################

    if r == "rating >= 8"

        return video.rating >= 8

    end

    return false

end


function refresh_smart_collection!(
    library::VideoLibrary,
    collection_id::String
)

    collection =
        library.smart_collections[
            collection_id
        ]

    empty!(
        collection.videos
    )

    for video in values(
        library.videos
    )

        if matches_rule(
            video,
            collection.rule
        )

            push!(
                collection.videos,
                video.id
            )

        end

    end

    return collection

end


###############################################################
# DUPLICATES
###############################################################

function duplicate_key(
    library::VideoLibrary,
    video::Video
)

    return (

        normalise(
            video.title,
            library.config
        ),

        video.year,

        round(
            video.duration
        )

    )

end


function duplicates(
    library::VideoLibrary
)

    groups =
        Dict{
            Tuple,
            Vector{Video}
        }()

    for video in values(
        library.videos
    )

        key =
            duplicate_key(
                library,
                video
            )

        if !haskey(
            groups,
            key
        )

            groups[key] =
                Video[]

        end

        push!(
            groups[key],
            video
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
# VIDEO STATISTICS
###############################################################

function statistics(
    library::VideoLibrary
)

    videos =
        collect(
            values(
                library.videos
            )
        )

    films =
        count(
            v ->
                v.video_type ==
                FILM,
            videos
        )

    episodes =
        count(
            v ->
                v.video_type ==
                TV_EPISODE,
            videos
        )

    music =
        count(
            v ->
                v.video_type ==
                MUSIC_VIDEO,
            videos
        )

    watched =
        count(
            v ->
                v.watched,
            videos
        )

    favourites =
        count(
            v ->
                v.favourite,
            videos
        )

    duration =
        sum(
            v.duration
            for v in videos
        )

    return (

        videos = length(videos),

        films = films,

        tv_episodes = episodes,

        music_videos = music,

        series = length(
            library.series
        ),

        watched = watched,

        unwatched =
            length(videos) -
            watched,

        favourites = favourites,

        hours =
            duration / 3600,

        watch_count =
            sum(
                v.watch_count
                for v in videos
            )

    )

end


###############################################################
# FILE ORGANISATION
###############################################################

function suggested_path(
    library::VideoLibrary,
    video::Video
)

    ###########################################################
    # FILM
    ###########################################################

    if video.video_type ==
       FILM

        return joinpath(

            "Films",

            string(
                video.title,
                " (",
                video.year,
                ")"
            ),

            string(
                video.title,
                " (",
                video.year,
                ").mkv"
            )

        )

    end

    ###########################################################
    # TV
    ###########################################################

    if video.video_type ==
       TV_EPISODE ||
       video.video_type ==
       TV_SPECIAL

        season =
            "Season " *
            string(
                video.season_number
            )

        filename =
            "S" *
            lpad(
                string(
                    video.season_number
                ),
                2,
                '0'
            ) *
            "E" *
            lpad(
                string(
                    video.episode_number
                ),
                2,
                '0'
            ) *
            " - " *
            video.episode_title

        return joinpath(

            "TV",

            video.series_name,

            season,

            filename * ".mkv"

        )

    end

    ###########################################################
    # MUSIC VIDEO
    ###########################################################

    if video.video_type ==
       MUSIC_VIDEO

        return joinpath(

            "Music Videos",

            video.music_artist,

            video.music_track *
            ".mp4"

        )

    end

    return joinpath(
        "Other",
        video.title * ".mkv"
    )

end


###############################################################
# ORGANISATION REPORT
###############################################################

function organisation_report(
    library::VideoLibrary
)

    report = String[]

    for video in values(
        library.videos
    )

        destination =
            suggested_path(
                library,
                video
            )

        push!(
            report,
            video.path *
            " -> " *
            destination
        )

    end

    return report

end


###############################################################
# DISPLAY
###############################################################

function show_video(
    video::Video
)

    if video.video_type ==
       TV_EPISODE

        println(

            "S",
            video.season_number,

            "E",

            video.episode_number,

            "  ",

            video.series_name,

            " — ",

            video.episode_title

        )

    elseif video.video_type ==
           MUSIC_VIDEO

        println(

            "♪  ",

            video.music_artist,

            " — ",

            video.music_track

        )

    else

        println(

            video.title,

            " (",

            video.year,

            ")"

        )

    end

end


###############################################################
# CLI
###############################################################

function help()

    println()
    println(
        "AUREOM VIDEO"
    )

    println(
        "--------------------------------"
    )

    println(
        "films"
    )

    println(
        "series"
    )

    println(
        "musicvideos"
    )

    println(
        "continue"
    )

    println(
        "recent"
    )

    println(
        "stats"
    )

    println(
        "search <query>"
    )

    println(
        "unwatched"
    )

    println(
        "duplicates"
    )

    println(
        "queue"
    )

    println(
        "next"
    )

    println(
        "help"
    )

    println(
        "quit"
    )

end


###############################################################
# CLI LOOP
###############################################################

function run_cli!(
    library::VideoLibrary
)

    help()

    while true

        print("\nvideo> ")

        command =
            strip(
                readline()
            )

        #######################################################
        # QUIT
        #######################################################

        if command ==
           "quit"

            break

        #######################################################
        # HELP
        #######################################################

        elseif command ==
               "help"

            help()

        #######################################################
        # FILMS
        #######################################################

        elseif command ==
               "films"

            for film in films(
                library
            )

                show_video(
                    film
                )

            end

        #######################################################
        # SERIES
        #######################################################

        elseif command ==
               "series"

            for series in
                sorted_series(
                    library
                )

                println(
                    series.name,
                    " (",
                    series.year,
                    ")"
                )

                println(
                    "  Seasons: ",
                    length(
                        series.seasons
                    )
                )

                println(
                    "  Episodes: ",
                    length(
                        series.episodes
                    )
                )

            end

        #######################################################
        # MUSIC VIDEOS
        #######################################################

        elseif command ==
               "musicvideos"

            for video in
                music_videos(
                    library
                )

                show_video(
                    video
                )

            end

        #######################################################
        # CONTINUE
        #######################################################

        elseif command ==
               "continue"

            for video in
                continue_watching(
                    library
                )

                progress =
                    round(
                        watch_progress(
                            video
                        ) * 100;
                        digits = 1
                    )

                println(
                    progress,
                    "%  "
                )

                show_video(
                    video
                )

            end

        #######################################################
        # RECENT
        #######################################################

        elseif command ==
               "recent"

            for video in
                recently_watched(
                    library
                )

                show_video(
                    video
                )

            end

        #######################################################
        # STATS
        #######################################################

        elseif command ==
               "stats"

            println(
                statistics(
                    library
                )
            )

        #######################################################
        # UNWATCHED
        #######################################################

        elseif command ==
               "unwatched"

            for video in values(
                library.videos
            )

                if !video.watched

                    show_video(
                        video
                    )

                end

            end

        #######################################################
        # DUPLICATES
        #######################################################

        elseif command ==
               "duplicates"

            groups =
                duplicates(
                    library
                )

            for (_, videos) in
                groups

                println()

                for video in videos

                    println(
                        video.title,
                        " — ",
                        video.path
                    )

                end

            end

        #######################################################
        # QUEUE
        #######################################################

        elseif command ==
               "queue"

            for (
                i,
                id
            ) in enumerate(
                library.queue
            )

                video =
                    library.videos[
                        id
                    ]

                marker =
                    i ==
                    library.queue_position ?
                    ">" :
                    " "

                print(
                    marker,
                    " "
                )

                show_video(
                    video
                )

            end

        #######################################################
        # NEXT
        #######################################################

        elseif command ==
               "next"

            next!(
                library
            )

        #######################################################
        # SEARCH
        #######################################################

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

            for (
                score,
                video
            ) in results[
                1:min(
                    20,
                    length(results)
                )
            ]

                println(
                    round(
                        score;
                        digits = 2
                    ),
                    "  "
                )

                show_video(
                    video
                )

            end

        else

            println(
                "Unknown command."
            )

        end

    end

end


###############################################################
# DEMO DATA
###############################################################

function demo_library()

    library =
        VideoLibrary()

    ###########################################################
    # FILM
    ###########################################################

    film = Video(

        make_id("film"),

        "Blade Runner 2049",

        normalise(
            "Blade Runner 2049",
            library.config
        ),

        FILM,

        2017,

        9840.0,

        "/Videos/Blade Runner 2049.mkv",

        "",

        "A science-fiction film.",

        ["Science Fiction", "Drama"],

        "Denis Villeneuve",

        ["Hampton Fancher"],

        ["Ryan Gosling", "Harrison Ford"],

        "Warner Bros.",

        "USA",

        "English",

        8.0,

        false,

        false,

        false,

        0,

        0.0,

        nothing,

        now(),

        "",

        "",

        0,

        0,

        "",

        "",

        "",

        "",

        0

    )

    add_video!(
        library,
        film
    )

    ###########################################################
    # TV EPISODE
    ###########################################################

    episode = Video(

        make_id("episode"),

        "Episode 1",

        "episode 1",

        TV_EPISODE,

        2026,

        3000.0,

        "/Videos/Example Show/S01E01.mkv",

        "",

        "First episode.",

        ["Drama"],

        "",

        String[],

        String[],

        "Aureom Studios",

        "UK",

        "English",

        8.5,

        false,

        false,

        false,

        0,

        0.0,

        nothing,

        now(),

        "",

        "Example Show",

        1,

        1,

        "The Beginning",

        "",

        "",

        "",

        0

    )

    add_video!(
        library,
        episode
    )

    ###########################################################
    # MUSIC VIDEO
    ###########################################################

    music = Video(

        make_id("musicvideo"),

        "The Song",

        "song",

        MUSIC_VIDEO,

        2026,

        240.0,

        "/Videos/Music Videos/Artist/The Song.mp4",

        "",

        "",

        ["Pop"],

        "",

        String[],

        String[],

        "",

        "",

        "English",

        0.0,

        false,

        false,

        false,

        0,

        0.0,

        nothing,

        now(),

        "",

        "",

        0,

        0,

        "",

        "Example Artist",

        "The Song",

        "The Album",

        2026

    )

    add_video!(
        library,
        music
    )

    return library

end


###############################################################
# MAIN
###############################################################

function main()

    println()
    println(
        "AUREOM VIDEO LIBRARY"
    )

    println(
        "Intelligent Films / TV / Music Videos"
    )

    library =
        demo_library()

    stats =
        statistics(
            library
        )

    println()

    println(
        "Films: ",
        stats.films
    )

    println(
        "TV episodes: ",
        stats.tv_episodes
    )

    println(
        "Music videos: ",
        stats.music_videos
    )

    println(
        "Series: ",
        stats.series
    )

    run_cli!(
        library
    )

end


end # module


###############################################################
# START
###############################################################

using .IntelligentVideoLibrary

IntelligentVideoLibrary.main()

