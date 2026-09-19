For an Aureom-style system, I'd make Julia the storage optimisation brain and Swift the native iOS filesystem/API layer.

                 iPhone Storage
                       │
                       ▼
              Swift Storage Agent
                       │
        ┌──────────────┼──────────────┐
        │              │              │
    Documents       Media         App Data
        │              │              │
        └──────────────┼──────────────┘
                       ▼
                Julia Optimiser
                       │
       ┌───────────────┼────────────────┐
       │               │                │
   duplication     compression       lifecycle
   detection       opportunity       prediction
       │               │                │
       └───────────────┼────────────────┘
                       ▼
                Storage Policy
                       │
                       ▼
                 Swift Executor
1. Julia storage intelligence

I'd start with a proper storage model rather than simply sorting files by size.

module AureomStorage

using Statistics
using Dates
using SHA

export StorageObject
export StorageState
export StorageAnalysis
export analyse!
export optimisation_score
export duplicate_score
export classify_object

# ---------------------------------------------------------
# Storage object
# ---------------------------------------------------------

struct StorageObject

    identifier::String
    path::String

    size_bytes::Int64

    created::DateTime
    modified::DateTime
    accessed::DateTime

    media_type::Symbol

    is_cached::Bool
    is_temporary::Bool

    hash::String
end


# ---------------------------------------------------------
# Storage state
# ---------------------------------------------------------

mutable struct StorageState

    capacity_bytes::Int64
    used_bytes::Int64
    free_bytes::Int64

    objects::Vector{StorageObject}

    duplicate_bytes::Int64
    reclaimable_bytes::Int64
    compressible_bytes::Int64

    last_analysis::DateTime
end


function StorageState(capacity::Int64)

    StorageState(
        capacity,
        0,
        capacity,
        StorageObject[],
        0,
        0,
        0,
        now()
    )
end


# ---------------------------------------------------------
# File classification
# ---------------------------------------------------------

function classify_object(
    object::StorageObject
)

    if object.is_temporary
        return :temporary

    elseif object.is_cached
        return :cache

    elseif object.media_type == :video
        return :video

    elseif object.media_type == :image
        return :image

    elseif object.media_type == :audio
        return :audio

    elseif object.media_type == :document
        return :document

    else
        return :other
    end
end


# ---------------------------------------------------------
# Duplicate probability
# ---------------------------------------------------------

function duplicate_score(
    a::StorageObject,
    b::StorageObject
)

    if a.size_bytes != b.size_bytes
        return 0.0
    end

    if isempty(a.hash) || isempty(b.hash)
        return 0.0
    end

    return a.hash == b.hash ? 1.0 : 0.0
end


# ---------------------------------------------------------
# Optimisation score
# ---------------------------------------------------------

function optimisation_score(
    object::StorageObject
)

    age_days =
        Dates.value(
            now() - object.accessed
        ) / (1000 * 60 * 60 * 24)

    score = 0.0

    # Temporary files are highly reclaimable.

    if object.is_temporary
        score += 0.90
    end

    # Cached content.

    if object.is_cached
        score += 0.70
    end

    # Old files.

    if age_days > 365
        score += 0.20

    elseif age_days > 180
        score += 0.10
    end

    # Large objects deserve inspection.

    if object.size_bytes > 1_000_000_000
        score += 0.10
    end

    return clamp(score, 0.0, 1.0)
end


# ---------------------------------------------------------
# Full analysis
# ---------------------------------------------------------

function analyse!(
    state::StorageState
)

    state.used_bytes =
        sum(
            object.size_bytes
            for object in state.objects
        )

    state.free_bytes =
        max(
            state.capacity_bytes -
            state.used_bytes,
            0
        )

    state.reclaimable_bytes = 0

    for object in state.objects

        score =
            optimisation_score(object)

        if score > 0.75

            state.reclaimable_bytes +=
                object.size_bytes
        end
    end

    state.last_analysis = now()

    return state
end

end

That is the foundation.

But the interesting bit is storage recycling.

2. Don't just delete files — build a lifecycle model

Julia could classify storage into:

             STORAGE OBJECT

                   │
        ┌──────────┼──────────┐
        ↓          ↓          ↓
      ACTIVE     COLD       DEAD
        │          │          │
        │          │          └── temporary
        │          │              duplicate
        │          │              expired cache
        │          │
        │          └───────────── compress/archive
        │
        └──────────────────────── keep

Then create a policy:

@enum StorageAction begin
    KEEP
    COMPRESS
    ARCHIVE
    REVIEW
    DELETE_CACHE
    DELETE_TEMPORARY
end


function recommend_action(
    object::StorageObject
)

    score =
        optimisation_score(object)

    if object.is_temporary
        return DELETE_TEMPORARY

    elseif object.is_cached &&
           score > 0.75
        return DELETE_CACHE

    elseif score > 0.80
        return REVIEW

    elseif score > 0.55
        return COMPRESS

    else
        return KEEP
    end
end

The crucial design decision is that Julia recommends; Swift executes only permitted operations.

That makes the system much safer.

3. Swift native storage scanner

Swift can inspect your app's accessible filesystem.

import Foundation

struct StorageObject: Identifiable {

    let id = UUID()

    let url: URL
    let size: Int64

    let created: Date
    let modified: Date
    let accessed: Date

    let isDirectory: Bool
}

Scanner:

final class AureomStorageScanner {

    func scan(
        directory: URL
    ) throws -> [StorageObject] {

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .contentAccessDateKey
        ]

        let urls =
            FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [
                    .skipsHiddenFiles
                ]
            )

        var objects: [StorageObject] = []

        for case let url as URL in urls ?? [] {

            let values =
                try url.resourceValues(
                    forKeys: Set(keys)
                )

            guard
                let isDirectory = values.isDirectory,
                let created = values.creationDate,
                let modified = values.contentModificationDate,
                let accessed = values.contentAccessDate
            else {
                continue
            }

            let size =
                Int64(values.fileSize ?? 0)

            objects.append(
                StorageObject(
                    url: url,
                    size: size,
                    created: created,
                    modified: modified,
                    accessed: accessed,
                    isDirectory: isDirectory
                )
            )
        }

        return objects
    }
}
4. Duplicate detection

This is where Julia becomes useful.

Swift can calculate hashes:

import CryptoKit

func sha256(
    file url: URL
) throws -> String {

    let data =
        try Data(contentsOf: url)

    let digest =
        SHA256.hash(data: data)

    return digest
        .map {
            String(format: "%02x", $0)
        }
        .joined()
}

Then Julia receives:

photo_A.heic
SHA256 = 71A...
4.8 MB

photo_B.heic
SHA256 = 71A...
4.8 MB

photo_C.heic
SHA256 = 923...
3.9 MB

and determines:

Duplicate group

A + B

Recoverable:
4.8 MB

For millions of objects, I'd actually use a two-stage hash:

size
 ↓
first 64 KB
 ↓
last 64 KB
 ↓
full SHA-256 only if necessary

That dramatically reduces unnecessary I/O.

5. Intelligent compression

You could also make Julia determine whether a file is worth compressing.

For example:

function compression_priority(
    object::StorageObject
)

    # Already compressed media usually
    # receives little benefit.

    if object.media_type == :video
        return 0.10

    elseif object.media_type == :image
        return 0.30

    elseif object.media_type == :document
        return 0.80

    elseif object.media_type == :audio
        return 0.20

    else
        return 0.50
    end
end

Then your system could recognise:

2.1 GB videos
    → probably don't recompress

850 MB PNG screenshots
    → high optimisation potential

420 MB PDFs
    → moderate/high optimisation potential

2.8 GB temporary data
    → reclaimable

1.3 GB duplicate photos
    → reclaimable
6. Swift execution layer

Never let the optimisation engine blindly delete things.

enum StorageAction {

    case keep
    case review
    case deleteTemporary
    case deleteCache
    case compress
}

Then:

final class AureomStorageExecutor {

    func execute(
        _ action: StorageAction,
        url: URL
    ) throws {

        switch action {

        case .keep:
            break

        case .review:
            // Surface to UI.
            break

        case .deleteTemporary:

            try FileManager.default.removeItem(
                at: url
            )

        case .deleteCache:

            try FileManager.default.removeItem(
                at: url
            )

        case .compress:

            try compress(
                url: url
            )
        }
    }

    private func compress(
        url: URL
    ) throws {

        // Compression implementation.
        // Do not destroy the source until
        // the replacement has been verified.
    }
}

I'd make deletion transactional:

identify
   ↓
analyse
   ↓
recommend
   ↓
user/system authorisation
   ↓
create replacement / backup
   ↓
verify
   ↓
delete original
   ↓
verify free space

rather than:

"Julia says delete it"
        ↓
DELETE
7. Storage forecasting

This is where Julia gets particularly interesting.

It can learn your storage trajectory:

function daily_storage_rate(
    history::Vector{Tuple{DateTime,Int64}}
)

    length(history) < 2 &&
        return 0.0

    first_time, first_size = first(history)
    last_time, last_size = last(history)

    days =
        Dates.value(
            last_time - first_time
        ) / (1000 * 60 * 60 * 24)

    days <= 0 &&
        return 0.0

    return (
        last_size -
        first_size
    ) / days
end

Then:

function days_until_full(
    used::Int64,
    capacity::Int64,
    daily_growth::Float64
)

    daily_growth <= 0 &&
        return Inf

    free =
        capacity - used

    return free / daily_growth
end

So the system could tell you:

AUREOM STORAGE INTELLIGENCE

Capacity             256 GB
Used                 214.7 GB
Free                  41.3 GB

Growth rate          +1.84 GB/week

Estimated full       22.4 weeks

Potential recovery   18.7 GB

────────────────────────────

Duplicates            6.2 GB
Temporary              3.1 GB
Caches                 4.8 GB
Compressible           4.6 GB

Recommended recovery  18.7 GB
And I'd take it one step further

Rather than making this a simple "cleaner", build it as an iOS storage operating intelligence layer:

             AUREOM STORAGE OS
                    │
       ┌────────────┼────────────┐
       │            │            │
       ▼            ▼            ▼
   DISCOVERY     MODELLING    FORECASTING
       │            │            │
       ▼            ▼            ▼
   filesystem    Julia AI     growth model
   metadata      duplicate    future demand
   media         analysis     capacity
       │            │            │
       └────────────┼────────────┘
                    ▼
             OPTIMISATION PLAN
                    │
       ┌────────────┼────────────┐
       ▼            ▼            ▼
    reclaim       compress     archive
       │            │            │
       └────────────┼────────────┘
                    ▼
              Swift executor

The Julia layer should not be thought of as a file cleaner. It becomes a predictive storage model that knows what the storage is, how quickly it is changing, what is redundant, what is safely reclaimable, and what will become important later.

For an actual iPhone implementation, the next layer I'd add is Photo Library + app-cache + Files-provider integration, because those are much more useful than simply scanning the app's own sandbox. That still has to respect Apple's sandbox, privacy permissions, and APIs—you cannot turn a third-party app into a root-level iOS storage manager.

