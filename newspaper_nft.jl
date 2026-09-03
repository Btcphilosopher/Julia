module NewspaperNFT

using HTTP
using JSON3
using SQLite
using UUIDs
using Dates
using Base64

# ============================================================
# CONFIGURATION
# ============================================================

const TAPD_URL =
    get(
        ENV,
        "TAPD_URL",
        "https://127.0.0.1:8089"
    )

const TAPD_MACAROON =
    get(
        ENV,
        "TAPD_MACAROON",
        ""
    )

const DATABASE =
    get(
        ENV,
        "NFT_DATABASE",
        "newspaper_nfts.db"
    )

const DB =
    SQLite.DB(DATABASE)

# ============================================================
# DATABASE
# ============================================================

function initialise_database()

    SQLite.execute(DB, """
        CREATE TABLE IF NOT EXISTS collections (

            collection_id TEXT PRIMARY KEY,

            name TEXT NOT NULL,

            symbol TEXT NOT NULL,

            description TEXT,

            created_at TEXT NOT NULL
        )
    """)

    SQLite.execute(DB, """
        CREATE TABLE IF NOT EXISTS nfts (

            nft_id TEXT PRIMARY KEY,

            collection_id TEXT NOT NULL,

            article_id TEXT NOT NULL,

            asset_id TEXT,

            asset_group_key TEXT,

            metadata_uri TEXT,

            title TEXT,

            edition TEXT,

            status TEXT NOT NULL,

            created_at TEXT NOT NULL,

            FOREIGN KEY(collection_id)
                REFERENCES collections(collection_id)
        )
    """)

    SQLite.execute(DB, """
        CREATE TABLE IF NOT EXISTS transfers (

            transfer_id TEXT PRIMARY KEY,

            nft_id TEXT NOT NULL,

            sender TEXT,

            recipient TEXT,

            asset_address TEXT,

            proof TEXT,

            status TEXT NOT NULL,

            created_at TEXT NOT NULL
        )
    """)

end

# ============================================================
# HTTP HELPERS
# ============================================================

function tapd_headers()

    return [
        "Content-Type" =>
            "application/json",

        "Grpc-Metadata-macaroon" =>
            TAPD_MACAROON
    ]

end


function tapd_post(
    endpoint::String,
    payload
)

    response = HTTP.post(

        TAPD_URL * endpoint,

        tapd_headers(),

        JSON3.write(payload);

        status_exception=false
    )

    if response.status < 200 ||
       response.status >= 300

        error(
            "tapd request failed: " *
            string(response.status) *
            " " *
            String(response.body)
        )

    end

    return JSON3.read(
        response.body
    )

end


function tapd_get(endpoint::String)

    response = HTTP.get(

        TAPD_URL * endpoint,

        tapd_headers();

        status_exception=false
    )

    if response.status < 200 ||
       response.status >= 300

        error(
            "tapd request failed: " *
            string(response.status)
        )

    end

    return JSON3.read(
        response.body
    )

end

# ============================================================
# IDs
# ============================================================

new_id() =
    string(uuid4())


timestamp() =
    string(now(UTC))

# ============================================================
# COLLECTIONS
# ============================================================

struct Collection

    collection_id::String

    name::String

    symbol::String

    description::String

end


function create_collection(

    name::String,

    symbol::String,

    description::String=""

)

    id =
        new_id()

    SQLite.execute(

        DB,

        """
        INSERT INTO collections
        (
            collection_id,
            name,
            symbol,
            description,
            created_at
        )
        VALUES (?, ?, ?, ?, ?)
        """,

        (
            id,
            name,
            symbol,
            description,
            timestamp()
        )
    )

    return Collection(
        id,
        name,
        symbol,
        description
    )

end

# ============================================================
# NFT METADATA
# ============================================================

struct NFTMetadata

    name::String

    description::String

    article_id::String

    edition::String

    image_uri::String

    article_uri::String

end


function metadata_json(
    metadata::NFTMetadata
)

    return Dict(

        "name" =>
            metadata.name,

        "description" =>
            metadata.description,

        "article_id" =>
            metadata.article_id,

        "edition" =>
            metadata.edition,

        "image" =>
            metadata.image_uri,

        "article" =>
            metadata.article_uri,

        "type" =>
            "newspaper-collectible",

        "protocol" =>
            "taproot-assets"
    )

end

# ============================================================
# TAPROOT ASSET MINT
# ============================================================

"""
Mint a unique newspaper collectible.

For a true one-of-one NFT, the asset amount is 1.

The exact tapd mint request should be kept behind this
adapter because tapd API fields evolve between releases.
"""

function mint_unique_asset(

    name::String,

    metadata::NFTMetadata

)

    # Taproot Assets mint request.
    #
    # A unique asset has supply = 1.

    request = Dict(

        "asset_type" => "NORMAL",

        "name" =>
            name,

        "asset_meta" =>
            JSON3.write(
                metadata_json(metadata)
            ),

        "amount" =>
            "1"
    )

    return tapd_post(
        "/v1/taproot-assets/assets",
        request
    )

end

# ============================================================
# NFT RECORD
# ============================================================

function register_nft(

    collection_id::String,

    article_id::String,

    asset_id::String,

    group_key::String,

    metadata_uri::String,

    title::String,

    edition::String

)

    nft_id =
        new_id()

    SQLite.execute(

        DB,

        """
        INSERT INTO nfts
        (
            nft_id,
            collection_id,
            article_id,
            asset_id,
            asset_group_key,
            metadata_uri,
            title,
            edition,
            status,
            created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,

        (
            nft_id,
            collection_id,
            article_id,
            asset_id,
            group_key,
            metadata_uri,
            title,
            edition,
            "MINTED",
            timestamp()
        )
    )

    return nft_id

end

# ============================================================
# CREATE LIGHTNING ASSET ADDRESS
# ============================================================

"""
Create an address that another Lightning/Taproot Asset
wallet can use to receive the NFT.
"""

function create_receive_address(

    asset_id::String

)

    request = Dict(

        "asset_id" =>
            asset_id,

        "amt" =>
            "1"
    )

    result =
        tapd_post(
            "/v1/taproot-assets/addrs",
            request
        )

    return result

end

# ============================================================
# DECODE ADDRESS
# ============================================================

function decode_address(

    address::String

)

    return tapd_post(

        "/v1/taproot-assets/addrs/decode",

        Dict(
            "addr" => address
        )
    )

end

# ============================================================
# REGISTER RECEIVE
# ============================================================

function register_receive(

    address::String

)

    return tapd_post(

        "/v1/taproot-assets/addrs/receives",

        Dict(
            "addr" => address
        )
    )

end

# ============================================================
# SEND NFT
# ============================================================

"""
Send one NFT.

The actual Taproot Asset transfer is performed by tapd.

The recipient supplies a Taproot Asset address.
"""

function send_nft(

    nft_id::String,

    recipient_address::String

)

    result = tapd_post(

        "/v1/taproot-assets/send",

        Dict(

            "addr" =>
                recipient_address,

            "script_key" =>
                "",

            "sat_value" =>
                "0"
        )

    )

    transfer_id =
        new_id()

    SQLite.execute(

        DB,

        """
        INSERT INTO transfers
        (
            transfer_id,
            nft_id,
            recipient,
            asset_address,
            status,
            created_at
        )
        VALUES (?, ?, ?, ?, ?, ?)
        """,

        (
            transfer_id,
            nft_id,
            recipient_address,
            recipient_address,
            "SUBMITTED",
            timestamp()
        )
    )

    return (
        transfer_id =
            transfer_id,

        tapd_result =
            result
    )

end

# ============================================================
# LIST ASSETS
# ============================================================

function list_assets()

    return tapd_get(
        "/v1/taproot-assets/assets"
    )

end

# ============================================================
# LIST TRANSFERS
# ============================================================

function list_transfers()

    return tapd_get(
        "/v1/taproot-assets/assets/transfers"
    )

end

# ============================================================
# PROOF EXPORT
# ============================================================

"""
Export the cryptographic proof for an NFT.

Proofs are important because Taproot Assets transfers
depend on asset proofs in addition to the Bitcoin anchor.
"""

function export_proof(

    asset_id::String

)

    return tapd_post(

        "/v1/taproot-assets/proofs/export",

        Dict(
            "asset_id" => asset_id
        )
    )

end

# ============================================================
# PROOF VERIFY
# ============================================================

function verify_proof(

    proof::String

)

    return tapd_post(

        "/v1/taproot-assets/proofs/verify",

        Dict(
            "raw_proof" => proof
        )
    )

end

# ============================================================
# QUERY NFT
# ============================================================

function get_nft(

    nft_id::String

)

    rows = collect(

        SQLite.Query(

            DB,

            """
            SELECT *
            FROM nfts
            WHERE nft_id = ?
            """,

            (nft_id,)
        )
    )

    isempty(rows) &&
        return nothing

    return rows[1]

end

# ============================================================
# SERVER
# ============================================================

function json_response(

    data;

    status=200

)

    return HTTP.Response(

        status,

        [
            "Content-Type" =>
                "application/json"
        ],

        JSON3.write(data)
    )

end


function handler(req)

    method =
        String(req.method)

    path =
        String(req.target)

    # --------------------------------------------------------
    # HEALTH
    # --------------------------------------------------------

    if method == "GET" &&
       path == "/health"

        return json_response(

            Dict(
                "service" =>
                    "newspaper-nft",

                "status" =>
                    "online"
            )
        )

    end

    # --------------------------------------------------------
    # CREATE COLLECTION
    # --------------------------------------------------------

    if method == "POST" &&
       path == "/api/collections"

        body =
            JSON3.read(
                String(req.body)
            )

        collection =
            create_collection(

                String(body["name"]),

                String(body["symbol"]),

                get(
                    body,
                    "description",
                    ""
                )
            )

        return json_response(
            Dict(
                "collection_id" =>
                    collection.collection_id,

                "name" =>
                    collection.name,

                "symbol" =>
                    collection.symbol
            )
        )

    end

    # --------------------------------------------------------
    # LIST ASSETS
    # --------------------------------------------------------

    if method == "GET" &&
       path == "/api/assets"

        return json_response(
            list_assets()
        )

    end

    # --------------------------------------------------------
    # LIST TRANSFERS
    # --------------------------------------------------------

    if method == "GET" &&
       path == "/api/transfers"

        return json_response(
            list_transfers()
        )

    end

    return json_response(

        Dict(
            "error" =>
                "Not found"
        );

        status=404
    )

end

# ============================================================
# START
# ============================================================

function start(

    host="127.0.0.1",

    port=8090

)

    initialise_database()

    println(
        "Newspaper Taproot Asset NFT engine"
    )

    println(
        "Listening on $host:$port"
    )

    HTTP.serve(
        handler,
        host,
        port
    )

end

end
