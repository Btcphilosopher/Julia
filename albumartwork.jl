###############################################################
# AUREOM ARTWORK ENGINE
#
# Intelligent album / single artwork resolver
#
# Julia 1.x
#
# Packages:
#
#   ] add HTTP JSON3 Images FileIO ImageIO
#
# The system:
#
#   1. Normalises artist + album
#   2. Queries MusicBrainz
#   3. Queries Cover Art Archive
#   4. Retrieves candidate artwork
#   5. Scores candidates
#   6. Selects best artwork
#   7. Caches artwork locally
#   8. Avoids unnecessary repeat downloads
#
###############################################################

module AureomArtwork

using HTTP
using JSON3
using Dates
using SHA
using FileIO
using Images
using ImageIO


###############################################################
# CONFIG
###############################################################

Base.@kwdef mutable struct ArtworkConfig

    cache_directory::String =
        "./Artwork"

    minimum_width::Int =
        500

    preferred_width::Int =
        1000

    minimum_square_ratio::Float64 =
        0.90

    request_delay::Float64 =
        1.1

    user_agent::String =
        "AureomMusic/1.0 (artwork library)"

end


###############################################################
# ARTWORK CANDIDATE
###############################################################

struct ArtworkCandidate

    url::String

    thumbnail_url::String

    width::Int

    height::Int

    image_type::String

    front::Bool

    back::Bool

    score::Float64

    source::String

end


###############################################################
# RESOLVED ARTWORK
###############################################################

struct ArtworkResult

    found::Bool

    path::String

    url::String

    width::Int

    height::Int

    score::Float64

    source::String

end


###############################################################
# NORMALISATION
###############################################################

function normalise(
    value::String
)

    s =
        lowercase(
            strip(value)
        )

    s =
        replace(
            s,
            "&" => "and"
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

    return strip(s)

end


###############################################################
# CANONICAL ARTIST
###############################################################

function canonical_artist(
    artist::String
)

    s =
        normalise(
            artist
        )

    # Ignore leading articles

    for article in [
        "the",
        "a",
        "an"
    ]

        prefix =
            article * " "

        if startswith(
            s,
            prefix
        )

            s =
                s[
                    length(prefix)+1:end
                ]

            break

        end

    end

    return s

end


###############################################################
# CANONICAL ALBUM
###############################################################

function canonical_album(
    album::String
)

    s =
        normalise(
            album
        )

    # Remove common release suffixes

    suffixes = [

        "deluxe edition",
        "deluxe",

        "expanded edition",
        "expanded",

        "remastered",
        "remaster",

        "anniversary edition",
        "anniversary",

        "special edition",
        "special"

    ]

    for suffix in suffixes

        if endswith(
            s,
            suffix
        )

            s =
                strip(
                    s[
                        1:
                        length(s) -
                        length(suffix)
                    ]
                )

        end

    end

    return s

end


###############################################################
# MUSICBRAINZ SEARCH
###############################################################

function musicbrainz_search(
    artist::String,
    album::String,
    config::ArtworkConfig
)

    query =
        "artist:" *
        "\"" *
        artist *
        "\"" *
        " AND release:" *
        "\"" *
        album *
        "\""

    encoded =
        HTTP.escapeuri(
            query
        )

    url =
        "https://musicbrainz.org/ws/2/release/" *
        "?query=" *
        encoded *
        "&fmt=json&limit=10"

    headers = [

        "User-Agent" =>
            config.user_agent,

        "Accept" =>
            "application/json"

    ]

    response =
        HTTP.get(
            url,
            headers
        )

    return JSON3.read(
        String(
            response.body
        )
    )

end


###############################################################
# RELEASE MATCH SCORE
###############################################################

function release_match_score(
    artist::String,
    album::String,
    release
)

    wanted_artist =
        canonical_artist(
            artist
        )

    wanted_album =
        canonical_album(
            album
        )

    release_title =
        canonical_album(
            String(
                release.title
            )
        )

    score = 0.0

    ###########################################################
    # ALBUM
    ###########################################################

    if release_title ==
       wanted_album

        score += 0.60

    elseif occursin(
        wanted_album,
        release_title
    ) ||
    occursin(
        release_title,
        wanted_album
    )

        score += 0.40

    end

    ###########################################################
    # ARTIST
    ###########################################################

    if haskey(
        release,
        :artist-credit
    )

        for credit in
            release["artist-credit"]

            if haskey(
                credit,
                :artist
            )

                candidate =
                    canonical_artist(
                        String(
                            credit.artist.name
                        )
                    )

                if candidate ==
                   wanted_artist

                    score += 0.40

                end

            end

        end

    end

    return score

end


###############################################################
# BEST MUSICBRAINZ RELEASE
###############################################################

function find_best_release(
    artist::String,
    album::String,
    config::ArtworkConfig
)

    data =
        musicbrainz_search(
            artist,
            album,
            config
        )

    if !haskey(
        data,
        :releases
    )

        return nothing

    end

    releases =
        data.releases

    best =
        nothing

    best_score =
        -Inf

    for release in releases

        score =
            release_match_score(
                artist,
                album,
                release
            )

        if score >
           best_score

            best_score =
                score

            best =
                release

        end

    end

    if best_score < 0.4

        return nothing

    end

    return best

end


###############################################################
# COVER ART ARCHIVE
###############################################################

function cover_art_url(
    release_id::String
)

    return (
        "https://coverartarchive.org/" *
        "release/" *
        release_id
    )

end


###############################################################
# QUERY COVER ART
###############################################################

function get_cover_art(
    release_id::String,
    config::ArtworkConfig
)

    url =
        cover_art_url(
            release_id
        )

    headers = [

        "User-Agent" =>
            config.user_agent,

        "Accept" =>
            "application/json"

    ]

    response =
        HTTP.get(
            url,
            headers
        )

    return JSON3.read(
        String(
            response.body
        )
    )

end


###############################################################
# EXTRACT CANDIDATES
###############################################################

function artwork_candidates(
    data
)

    candidates =
        ArtworkCandidate[]

    if !haskey(
        data,
        :images
    )

        return candidates

    end

    for image in
        data.images

        front =
            haskey(
                image,
                :front
            ) ?
            Bool(image.front) :
            false

        back =
            haskey(
                image,
                :back
            ) ?
            Bool(image.back) :
            false

        width =
            haskey(
                image,
                :width
            ) ?
            Int(image.width) :
            0

        height =
            haskey(
                image,
                :height
            ) ?
            Int(image.height) :
            0

        full =
            haskey(
                image,
                :image
            ) ?
            String(image.image) :
            ""

        thumb =
            haskey(
                image,
                :thumbnails
            ) &&
            haskey(
                image.thumbnails,
                Symbol("500")
            ) ?
            String(
                image.thumbnails[Symbol("500")]
            ) :
            ""

        push!(
            candidates,

            ArtworkCandidate(

                full,

                thumb,

                width,

                height,

                "image",

                front,

                back,

                0.0,

                "Cover Art Archive"

            )

        )

    end

    return candidates

end


###############################################################
# IMAGE QUALITY SCORE
###############################################################

function quality_score(
    candidate::ArtworkCandidate,
    config::ArtworkConfig
)

    score = 0.0

    ###########################################################
    # FRONT COVER
    ###########################################################

    if candidate.front

        score += 50

    end

    ###########################################################
    # BACK COVER PENALTY
    ###########################################################

    if candidate.back

        score -= 35

    end

    ###########################################################
    # RESOLUTION
    ###########################################################

    width =
        candidate.width

    height =
        candidate.height

    if width >=
       config.preferred_width

        score += 20

    elseif width >=
           config.minimum_width

        score += 10

    else

        score -= 20

    end

    ###########################################################
    # SQUARENESS
    ###########################################################

    if height > 0

        ratio =
            min(width, height) /
            max(width, height)

        if ratio >=
           config.minimum_square_ratio

            score += 20

        else

            score -= 20

        end

    end

    ###########################################################
    # EXTREME RESOLUTION
    ###########################################################

    if width >= 2000 &&
       height >= 2000

        score += 5

    end

    return score

end


###############################################################
# SCORE CANDIDATES
###############################################################

function score_candidates(
    candidates::Vector{
        ArtworkCandidate
    },
    config::ArtworkConfig
)

    scored =
        ArtworkCandidate[]

    for candidate in candidates

        score =
            quality_score(
                candidate,
                config
            )

        push!(
            scored,

            ArtworkCandidate(

                candidate.url,

                candidate.thumbnail_url,

                candidate.width,

                candidate.height,

                candidate.image_type,

                candidate.front,

                candidate.back,

                score,

                candidate.source

            )

        )

    end

    return sort(
        scored,
        by = x -> -x.score
    )

end


###############################################################
# CACHE KEY
###############################################################

function artwork_cache_key(
    artist::String,
    album::String
)

    input =
        canonical_artist(
            artist
        ) *
        "::" *
        canonical_album(
            album
        )

    return bytes2hex(
        sha256(
            input
        )
    )

end


###############################################################
# CACHE PATH
###############################################################

function artwork_path(
    config::ArtworkConfig,
    artist::String,
    album::String
)

    key =
        artwork_cache_key(
            artist,
            album
        )

    mkpath(
        config.cache_directory
    )

    return joinpath(

        config.cache_directory,

        key * ".jpg"

    )

end


###############################################################
# DOWNLOAD ARTWORK
###############################################################

function download_artwork(
    candidate::ArtworkCandidate,
    path::String,
    config::ArtworkConfig
)

    if isempty(
        candidate.url
    )

        return false

    end

    try

        response =
            HTTP.get(
                candidate.url,
                [
                    "User-Agent" =>
                        config.user_agent
                ]
            )

        open(
            path,
            "w"
        ) do io

            write(
                io,
                response.body
            )

        end

        return true

    catch error

        println(
            "Artwork download failed: ",
            error
        )

        return false

    end

end


###############################################################
# VERIFY IMAGE
###############################################################

function verify_artwork(
    path::String
)

    try

        image =
            load(
                path
            )

        size_image =
            size(image)

        if length(
            size_image
        ) < 2

            return false

        end

        width =
            size_image[2]

        height =
            size_image[1]

        if width < 100 ||
           height < 100

            return false

        end

        return true

    catch

        return false

    end

end


###############################################################
# MAIN ARTWORK RESOLVER
###############################################################

function resolve_artwork(
    artist::String,
    album::String;

    config::ArtworkConfig =
        ArtworkConfig()

)

    ###########################################################
    # CACHE
    ###########################################################

    cached =
        artwork_path(
            config,
            artist,
            album
        )

    if isfile(
        cached
    )

        return ArtworkResult(

            true,

            cached,

            "",

            0,

            0,

            100.0,

            "local cache"

        )

    end


    ###########################################################
    # MUSICBRAINZ
    ###########################################################

    println(
        "Searching artwork: ",
        artist,
        " — ",
        album
    )

    release =
        try

            find_best_release(
                artist,
                album,
                config
            )

        catch error

            println(
                "MusicBrainz error: ",
                error
            )

            nothing

        end

    if release === nothing

        return ArtworkResult(
            false,
            "",
            "",
            0,
            0,
            0.0,
            ""
        )

    end


    ###########################################################
    # RELEASE ID
    ###########################################################

    release_id =
        String(
            release.id
        )

    println(
        "Matched release: ",
        release.title
    )

    println(
        "Release ID: ",
        release_id
    )


    ###########################################################
    # COVER ART
    ###########################################################

    data =
        try

            get_cover_art(
                release_id,
                config
            )

        catch error

            println(
                "Cover Art Archive error: ",
                error
            )

            return ArtworkResult(
                false,
                "",
                "",
                0,
                0,
                0.0,
                ""
            )

        end


    ###########################################################
    # CANDIDATES
    ###########################################################

    candidates =
        artwork_candidates(
            data
        )

    if isempty(
        candidates
    )

        return ArtworkResult(
            false,
            "",
            "",
            0,
            0,
            0.0,
            ""
        )

    end


    ###########################################################
    # SCORE
    ###########################################################

    scored =
        score_candidates(
            candidates,
            config
        )

    best =
        first(
            scored
        )

    println(
        "Selected artwork:"
    )

    println(
        "  Resolution: ",
        best.width,
        " × ",
        best.height
    )

    println(
        "  Score: ",
        best.score
    )


    ###########################################################
    # DOWNLOAD
    ###########################################################

    success =
        download_artwork(
            best,
            cached,
            config
        )

    if !success

        return ArtworkResult(
            false,
            "",
            best.url,
            best.width,
            best.height,
            best.score,
            best.source
        )

    end


    ###########################################################
    # VERIFY
    ###########################################################

    if !verify_artwork(
        cached
    )

        rm(
            cached,
            force = true
        )

        return ArtworkResult(
            false,
            "",
            best.url,
            best.width,
            best.height,
            best.score,
            best.source
        )

    end


    return ArtworkResult(

        true,

        cached,

        best.url,

        best.width,

        best.height,

        best.score,

        best.source

    )

end


###############################################################
# BATCH PROCESS LIBRARY
###############################################################

function resolve_library_artwork!(
    library,
    config::ArtworkConfig =
        ArtworkConfig()
)

    results =
        Dict{
            String,
            ArtworkResult
        }()

    ###########################################################
    # GROUP ALBUMS
    ###########################################################

    albums =
        Dict{
            Tuple,
            Vector
        }()

    for track in values(
        library.tracks
    )

        key = (

            canonical_artist(
                track.album_artist
            ),

            canonical_album(
                track.album
            )

        )

        if !haskey(
            albums,
            key
        )

            albums[key] =
                []

        end

        push!(
            albums[key],
            track
        )

    end


    ###########################################################
    # RESOLVE
    ###########################################################

    for (
        key,
        tracks
    ) in albums

        track =
            first(
                tracks
            )

        result =
            resolve_artwork(

                track.album_artist,

                track.album,

                config = config

            )

        results[
            track.album
        ] = result

        #######################################################
        # ATTACH TO TRACK METADATA
        #######################################################

        if result.found

            # Every track in this release receives
            # the same artwork reference.

            for item in tracks

                # Assumes Track can be extended with artwork
                # in the larger application.

                println(
                    "Artwork assigned: ",
                    item.title
                )

            end

        end

        sleep(
            config.request_delay
        )

    end

    return results

end


###############################################################
# SAVE ARTWORK INDEX
###############################################################

function save_index(
    results,
    filename::String =
        "./artwork_index.json"
)

    data =
        Dict()

    for (
        album,
        result
    ) in results

        data[album] = Dict(

            "found" =>
                result.found,

            "path" =>
                result.path,

            "url" =>
                result.url,

            "width" =>
                result.width,

            "height" =>
                result.height,

            "score" =>
                result.score,

            "source" =>
                result.source

        )

    end

    open(
        filename,
        "w"
    ) do io

        JSON3.write(
            io,
            data
        )

    end

end


###############################################################
# SINGLE ARTWORK
###############################################################

function resolve_single_artwork(
    artist::String,
    title::String;
    config::ArtworkConfig =
        ArtworkConfig()
)

    return resolve_artwork(
        artist,
        title,
        config = config
    )

end


###############################################################
# DEMO
###############################################################

function demo()

    config =
        ArtworkConfig()

    result =
        resolve_artwork(
            "The Beatles",
            "Abbey Road",
            config = config
        )

    println()

    if result.found

        println(
            "Artwork found!"
        )

        println(
            "Path: ",
            result.path
        )

        println(
            "Source: ",
            result.source
        )

        println(
            "Resolution: ",
            result.width,
            " × ",
            result.height
        )

        println(
            "Score: ",
            result.score
        )

    else

        println(
            "No artwork found."
        )

    end

end


end # module


###############################################################
# RUN DEMO
###############################################################

using .AureomArtwork

AureomArtwork.demo()

