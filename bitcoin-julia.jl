```julia
module JuliaBitcoin

using SHA
using Random
using Serialization
using Dates

# ============================================================
# CONFIGURATION
# ============================================================

const COIN = Int64(100_000_000)

struct ChainConfig
    name::String
    symbol::String
    block_reward::Int64
    halving_interval::Int64
    target_block_time::Int64
    difficulty_window::Int64
    max_block_size::Int64
end

const MAINNET =
    ChainConfig(
        "Julia Bitcoin",
        "JBTC",
        50 * COIN,
        210_000,
        600,
        2_016,
        1_000_000
    )

# ============================================================
# HASHING
# ============================================================

bytes(x::AbstractString) = Vector{UInt8}(codeunits(x))

function hash256(data::Vector{UInt8})
    return sha256(sha256(data))
end

function hexhash(h::Vector{UInt8})
    return bytes2hex(h)
end

function hash_string(x)
    return hexhash(hash256(bytes(string(x))))
end

# ============================================================
# TRANSACTION TYPES
# ============================================================

struct OutPoint
    txid::String
    index::Int
end

struct TxInput
    previous::OutPoint
    signature::String
    public_key::String
end

struct TxOutput
    value::Int64
    address::String
end

mutable struct Transaction
    version::Int
    inputs::Vector{TxInput}
    outputs::Vector{TxOutput}
    locktime::Int64
end

function transaction_payload(tx::Transaction)

    io = IOBuffer()

    write(io, tx.version)

    for input in tx.inputs
        write(io, input.previous.txid)
        write(io, input.previous.index)
        write(io, input.signature)
        write(io, input.public_key)
    end

    for output in tx.outputs
        write(io, output.value)
        write(io, output.address)
    end

    write(io, tx.locktime)

    return take!(io)
end

function txid(tx::Transaction)
    return hexhash(hash256(transaction_payload(tx)))
end

# ============================================================
# COINBASE TRANSACTIONS
# ============================================================

function coinbase_transaction(
    address::String,
    reward::Int64,
    height::Int
)

    input = TxInput(
        OutPoint("0"^64, -1),
        string("coinbase-", height),
        ""
    )

    output = TxOutput(
        reward,
        address
    )

    return Transaction(
        1,
        [input],
        [output],
        0
    )
end

# ============================================================
# WALLET
# ============================================================

mutable struct Wallet
    private_key::String
    public_key::String
    address::String
end

function new_wallet()

    private_key =
        bytes2hex(rand(UInt8, 32))

    # This is intentionally a simplified public-key construction.
    # Replace with real secp256k1 for production.
    public_key =
        hash_string(private_key)

    address =
        "J" * first(public_key, 39)

    return Wallet(
        private_key,
        public_key,
        address
    )
end

function sign_message(wallet::Wallet, message::String)

    # DEVELOPMENT SIGNATURE ONLY.
    #
    # A production implementation must use
    # secp256k1 ECDSA or Schnorr signatures.

    return hash_string(
        wallet.private_key * message
    )
end

# ============================================================
# UTXO SET
# ============================================================

mutable struct UTXOSet

    outputs::Dict{OutPoint,TxOutput}

end

UTXOSet() =
    UTXOSet(
        Dict{OutPoint,TxOutput}()
    )

function add_utxo!(
    utxo::UTXOSet,
    txid_value::String,
    index::Int,
    output::TxOutput
)

    utxo.outputs[
        OutPoint(txid_value, index)
    ] = output

end

function remove_utxo!(
    utxo::UTXOSet,
    point::OutPoint
)

    delete!(utxo.outputs, point)

end

function get_utxo(
    utxo::UTXOSet,
    point::OutPoint
)

    return get(
        utxo.outputs,
        point,
        nothing
    )

end

function balance(
    utxo::UTXOSet,
    address::String
)

    total = Int64(0)

    for output in values(utxo.outputs)

        if output.address == address
            total += output.value
        end

    end

    return total
end

# ============================================================
# TRANSACTION VALIDATION
# ============================================================

function is_coinbase(tx::Transaction)

    length(tx.inputs) == 1 &&
    tx.inputs[1].previous.txid == "0"^64

end

function transaction_fee(
    tx::Transaction,
    utxo::UTXOSet
)

    input_value = Int64(0)

    for input in tx.inputs

        previous =
            get_utxo(
                utxo,
                input.previous
            )

        previous === nothing &&
            return nothing

        input_value += previous.value

    end

    output_value =
        sum(x.value for x in tx.outputs)

    return input_value - output_value
end

function validate_transaction(
    tx::Transaction,
    utxo::UTXOSet
)

    is_coinbase(tx) &&
        return true

    isempty(tx.inputs) &&
        return false

    isempty(tx.outputs) &&
        return false

    seen =
        Set{OutPoint}()

    input_value = Int64(0)

    for input in tx.inputs

        if input.previous in seen
            return false
        end

        push!(
            seen,
            input.previous
        )

        previous =
            get_utxo(
                utxo,
                input.previous
            )

        previous === nothing &&
            return false

        input_value +=
            previous.value

        # Simplified signature check.
        #
        # Real Bitcoin validation must execute
        # Script / witness programs.

        isempty(input.signature) &&
            return false

    end

    output_value =
        sum(
            output.value
            for output in tx.outputs
        )

    output_value < 0 &&
        return false

    input_value < output_value &&
        return false

    return true
end

# ============================================================
# APPLY TRANSACTION
# ============================================================

function apply_transaction!(
    utxo::UTXOSet,
    tx::Transaction
)

    id = txid(tx)

    if !is_coinbase(tx)

        for input in tx.inputs
            remove_utxo!(
                utxo,
                input.previous
            )
        end

    end

    for (index, output) in
        enumerate(tx.outputs)

        add_utxo!(
            utxo,
            id,
            index - 1,
            output
        )

    end

end

# ============================================================
# BLOCK
# ============================================================

mutable struct BlockHeader

    version::Int

    previous_hash::String

    merkle_root::String

    timestamp::Int64

    bits::Int64

    nonce::UInt64

end

mutable struct Block

    header::BlockHeader

    transactions::Vector{Transaction}

end

# ============================================================
# MERKLE TREE
# ============================================================

function merkle_root(
    transactions::Vector{Transaction}
)

    isempty(transactions) &&
        return "0"^64

    hashes =
        [
            txid(tx)
            for tx in transactions
        ]

    while length(hashes) > 1

        if isodd(length(hashes))
            push!(
                hashes,
                hashes[end]
            )
        end

        next_level =
            String[]

        for i in
            1:2:length(hashes)

            combined =
                hashes[i] *
                hashes[i + 1]

            push!(
                next_level,
                hash_string(combined)
            )

        end

        hashes = next_level

    end

    return hashes[1]
end

# ============================================================
# BLOCK HASH
# ============================================================

function header_bytes(
    h::BlockHeader
)

    io = IOBuffer()

    write(io, h.version)
    write(io, h.previous_hash)
    write(io, h.merkle_root)
    write(io, h.timestamp)
    write(io, h.bits)
    write(io, h.nonce)

    return take!(io)

end

function block_hash(
    block::Block
)

    return hexhash(
        hash256(
            header_bytes(
                block.header
            )
        )
    )

end

# ============================================================
# PROOF OF WORK
# ============================================================

function valid_pow(
    block::Block
)

    h =
        block_hash(block)

    return startswith(
        h,
        "0" ^ block.header.bits
    )

end

function mine!(
    block::Block;
    max_nonce::UInt64 = typemax(UInt64)
)

    nonce = UInt64(0)

    while nonce < max_nonce

        block.header.nonce =
            nonce

        if valid_pow(block)
            return true
        end

        nonce += 1

    end

    return false
end

# ============================================================
# MEMPOOL
# ============================================================

mutable struct Mempool

    transactions::Dict{
        String,
        Transaction
    }

end

Mempool() =
    Mempool(
        Dict{
            String,
            Transaction
        }()
    )

function add_transaction!(
    pool::Mempool,
    tx::Transaction,
    utxo::UTXOSet
)

    validate_transaction(
        tx,
        utxo
    ) || return false

    id = txid(tx)

    pool.transactions[id] = tx

    return true
end

function remove_transaction!(
    pool::Mempool,
    id::String
)

    delete!(
        pool.transactions,
        id
    )

end

# ============================================================
# BLOCKCHAIN
# ============================================================

mutable struct Blockchain

    config::ChainConfig

    blocks::Vector{Block}

    utxo::UTXOSet

    mempool::Mempool

end

function genesis_block(
    config::ChainConfig,
    address::String
)

    tx =
        coinbase_transaction(
            address,
            config.block_reward,
            0
        )

    header =
        BlockHeader(
            1,
            "0"^64,
            merkle_root([tx]),
            Int64(time()),
            2,
            0
        )

    block =
        Block(
            header,
            [tx]
        )

    while !valid_pow(block)

        block.header.nonce += 1

    end

    return block
end

function new_blockchain(
    config::ChainConfig = MAINNET
)

    wallet =
        new_wallet()

    block =
        genesis_block(
            config,
            wallet.address
        )

    utxo =
        UTXOSet()

    apply_transaction!(
        utxo,
        block.transactions[1]
    )

    return Blockchain(
        config,
        [block],
        utxo,
        Mempool()
    )
end

# ============================================================
# CHAIN VALIDATION
# ============================================================

function validate_block(
    chain::Blockchain,
    block::Block
)

    previous =
        chain.blocks[end]

    block.header.previous_hash ==
        block_hash(previous) ||
        return false

    block.header.merkle_root ==
        merkle_root(block.transactions) ||
        return false

    valid_pow(block) ||
        return false

    isempty(block.transactions) &&
        return false

    return true
end

# ============================================================
# MINING
# ============================================================

function select_transactions(
    chain::Blockchain
)

    selected =
        Transaction[]

    # Coinbase first
    for tx in values(
        chain.mempool.transactions
    )

        validate_transaction(
            tx,
            chain.utxo
        ) || continue

        push!(
            selected,
            tx
        )

    end

    return selected
end

function mine_block!(
    chain::Blockchain,
    miner_address::String
)

    transactions =
        select_transactions(chain)

    reward =
        chain.config.block_reward

    # Add transaction fees.
    fees = Int64(0)

    for tx in transactions

        fee =
            transaction_fee(
                tx,
                chain.utxo
            )

        fee !== nothing &&
            (fees += fee)

    end

    coinbase =
        coinbase_transaction(
            miner_address,
            reward + fees,
            length(chain.blocks)
        )

    all_transactions =
        vcat(
            [coinbase],
            transactions
        )

    previous =
        chain.blocks[end]

    header =
        BlockHeader(
            1,
            block_hash(previous),
            merkle_root(
                all_transactions
            ),
            Int64(time()),
            previous.header.bits,
            0
        )

    block =
        Block(
            header,
            all_transactions
        )

    println(
        "Mining block ",
        length(chain.blocks),
        "..."
    )

    mine!(block)

    validate_block(
        chain,
        block
    ) || error(
        "Mined block failed validation"
    )

    # Apply transactions atomically.
    for tx in block.transactions

        if !is_coinbase(tx)

            validate_transaction(
                tx,
                chain.utxo
            ) || error(
                "Invalid transaction"
            )

        end

        apply_transaction!(
            chain.utxo,
            tx
        )

    end

    push!(
        chain.blocks,
        block
    )

    for tx in transactions

        remove_transaction!(
            chain.mempool,
            txid(tx)
        )

    end

    return block
end

# ============================================================
# WALLET TRANSACTIONS
# ============================================================

function spend(
    wallet::Wallet,
    chain::Blockchain,
    destination::String,
    amount::Int64;
    fee::Int64 = 1_000
)

    amount > 0 ||
        error("Amount must be positive")

    balance_value =
        balance(
            chain.utxo,
            wallet.address
        )

    balance_value >= amount + fee ||
        error("Insufficient funds")

    selected =
        Tuple{OutPoint,TxOutput}[]

    total = Int64(0)

    for (point, output)
        in chain.utxo.outputs

        if output.address ==
            wallet.address

            push!(
                selected,
                (point, output)
            )

            total += output.value

            total >= amount + fee &&
                break
        end
    end

    inputs =
        TxInput[]

    for (point, output)
        in selected

        message =
            string(
                point.txid,
                ":",
                point.index,
                ":",
                destination,
                ":",
                amount
            )

        signature =
            sign_message(
                wallet,
                message
            )

        push!(
            inputs,
            TxInput(
                point,
                signature,
                wallet.public_key
            )
        )

    end

    outputs =
        TxOutput[
            TxOutput(
                amount,
                destination
            )
        ]

    change =
        total -
        amount -
        fee

    if change > 0

        push!(
            outputs,
            TxOutput(
                change,
                wallet.address
            )
        )

    end

    tx =
        Transaction(
            1,
            inputs,
            outputs,
            0
        )

    add_transaction!(
        chain.mempool,
        tx,
        chain.utxo
    ) || error(
        "Transaction rejected"
    )

    return tx
end

# ============================================================
# BLOCK EXPLORER
# ============================================================

function blockchain_info(
    chain::Blockchain
)

    latest =
        chain.blocks[end]

    return (
        blocks = length(chain.blocks),
        height = length(chain.blocks) - 1,
        latest_hash = block_hash(latest),
        transactions =
            sum(
                length(b.transactions)
                for b in chain.blocks
            ),
        utxos =
            length(chain.utxo.outputs),
        mempool =
            length(
                chain.mempool.transactions
            )
    )

end

function print_chain(
    chain::Blockchain
)

    println()
    println(
        "=============================="
    )
    println(
        "      JULIA BITCOIN NODE"
    )
    println(
        "=============================="
    )

    info =
        blockchain_info(chain)

    println(
        "Height:      ",
        info.height
    )

    println(
        "Blocks:      ",
        info.blocks
    )

    println(
        "Transactions:",
        info.transactions
    )

    println(
        "UTXOs:       ",
        info.utxos
    )

    println(
        "Mempool:     ",
        info.mempool
    )

    println(
        "Latest hash: ",
        info.latest_hash
    )

    println(
        "=============================="
    )

end

# ============================================================
# PERSISTENCE
# ============================================================

function save_node(
    chain::Blockchain,
    path::String
)

    open(path, "w") do io

        serialize(
            io,
            chain
        )

    end

end

function load_node(
    path::String
)

    open(path, "r") do io

        return deserialize(io)

    end

end

# ============================================================
# NODE
# ============================================================

mutable struct Node

    id::String

    wallet::Wallet

    chain::Blockchain

    peers::Vector{String}

end

function new_node()

    wallet =
        new_wallet()

    chain =
        new_blockchain()

    return Node(
        string(
            "node-",
            first(
                hash_string(
                    wallet.address
                ),
                12
            )
        ),
        wallet,
        chain,
        String[]
    )

end

function node_status(
    node::Node
)

    println(
        "Node: ",
        node.id
    )

    println(
        "Address: ",
        node.wallet.address
    )

    println(
        "Balance: ",
        balance(
            node.chain.utxo,
            node.wallet.address
        ) / COIN,
        " JBTC"
    )

    println(
        "Peers: ",
        length(node.peers)
    )

    print_chain(
        node.chain
    )

end

# ============================================================
# DEMONSTRATION
# ============================================================

function demo()

    println(
        "\nStarting Julia Bitcoin...\n"
    )

    node =
        new_node()

    println(
        "Created wallet:"
    )

    println(
        "  ",
        node.wallet.address
    )

    println()

    # Genesis reward
    node_status(node)

    # Create another wallet
    alice =
        new_wallet()

    println(
        "\nAlice address:"
    )

    println(
        alice.address
    )

    # Spend part of miner's genesis reward
    println(
        "\nCreating transaction..."
    )

    tx =
        spend(
            node.wallet,
            node.chain,
            alice.address,
            10 * COIN;
            fee = 10_000
        )

    println(
        "Transaction ID:"
    )

    println(
        txid(tx)
    )

    println(
        "\nMempool transactions: ",
        length(
            node.chain.mempool.transactions
        )
    )

    # Mine
    println(
        "\nMining..."
    )

    mine_block!(
        node.chain,
        node.wallet.address
    )

    println(
        "\nAfter mining:"
    )

    node_status(node)

    println(
        "\nAlice balance: ",
        balance(
            node.chain.utxo,
            alice.address
        ) / COIN,
        " JBTC"
    )

    # Save chain
    save_node(
        node.chain,
        "juliabitcoin.dat"
    )

    println(
        "\nBlockchain saved."
    )

    return node
end

end # module
```

