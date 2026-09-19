1. Julia — ranking/search intelligence
module AureomSearch

using LinearAlgebra
using Statistics

export SearchDocument,
       SearchQuery,
       SearchResult,
       tokenize,
       score_document,
       rank_documents

# ============================================================
# Document
# ============================================================

struct SearchDocument
    id::String
    title::String
    body::String
    path::String
    kind::String
    modified::Float64
    accessed::Float64
end

struct SearchQuery
    text::String
    tokens::Vector{String}
end

struct SearchResult
    id::String
    score::Float64
end

# ============================================================
# Tokenisation
# ============================================================

function tokenize(text::String)

    text = lowercase(text)

    # Remove punctuation.
    text = replace(
        text,
        r"[^\p{L}\p{N}\s]" => " "
    )

    tokens =
        split(text)

    # Remove extremely short tokens.
    tokens =
        filter(
            x -> length(x) > 1,
            tokens
        )

    return unique(tokens)
end

# ============================================================
# Query
# ============================================================

function SearchQuery(
    text::String
)

    SearchQuery(
        text,
        tokenize(text)
    )
end

# ============================================================
# Term frequency
# ============================================================

function term_frequency(
    token::String,
    tokens::Vector{String}
)

    count =
        sum(
            x -> x == token,
            tokens
        )

    return count /
           max(
               length(tokens),
               1
           )
end

# ============================================================
# String similarity
# ============================================================

function prefix_score(
    query::String,
    candidate::String
)

    q =
        lowercase(query)

    c =
        lowercase(candidate)

    if startswith(c, q)
        return 1.0
    end

    if occursin(q, c)
        return 0.55
    end

    return 0.0
end

# ============================================================
# Title scoring
# ============================================================

function title_score(
    query::SearchQuery,
    document::SearchDocument
)

    titleTokens =
        tokenize(
            document.title
        )

    score = 0.0

    for token in query.tokens

        if token in titleTokens
            score += 1.0
        end

        score +=
            prefix_score(
                token,
                document.title
            ) * 0.75
    end

    return score /
           max(
               length(query.tokens),
               1
           )
end

# ============================================================
# Body scoring
# ============================================================

function body_score(
    query::SearchQuery,
    document::SearchDocument
)

    bodyTokens =
        tokenize(
            document.body
        )

    score = 0.0

    for token in query.tokens

        score +=
            term_frequency(
                token,
                bodyTokens
            )
    end

    return score
end

# ============================================================
# File-type bonus
# ============================================================

function kind_bonus(
    query::SearchQuery,
    document::SearchDocument
)

    q =
        lowercase(
            query.text
        )

    kind =
        lowercase(
            document.kind
        )

    if occursin(
        kind,
        q
    )
        return 0.20
    end

    return 0.0
end

# ============================================================
# Recency
# ============================================================

function recency_score(
    document::SearchDocument
)

    age =
        max(
            time() -
            document.modified,
            0
        )

    days =
        age / 86400

    # Exponential decay.
    return exp(
        -days / 180
    )
end

# ============================================================
# Access frequency proxy
# ============================================================

function access_score(
    document::SearchDocument
)

    age =
        max(
            time() -
            document.accessed,
            0
        )

    days =
        age / 86400

    return exp(
        -days / 90
    )
end

# ============================================================
# Complete ranking function
# ============================================================

function score_document(
    query::SearchQuery,
    document::SearchDocument
)

    title =
        title_score(
            query,
            document
        )

    body =
        body_score(
            query,
            document
        )

    recent =
        recency_score(
            document
        )

    accessed =
        access_score(
            document
        )

    kind =
        kind_bonus(
            query,
            document
        )

    score =
          0.55 * title
        + 0.20 * body
        + 0.10 * recent
        + 0.10 * accessed
        + 0.05 * kind

    return score
end

# ============================================================
# Ranking
# ============================================================

function rank_documents(
    queryText::String,
    documents::Vector{SearchDocument};
    limit::Int = 50
)

    query =
        SearchQuery(
            queryText
        )

    results =
        SearchResult[]

    for document in documents

        score =
            score_document(
                query,
                document
            )

        if score > 0
            push!(
                results,
                SearchResult(
                    document.id,
                    score
                )
            )
        end
    end

    sort!(
        results,
        by = x -> x.score,
        rev = true
    )

    return first(
        results,
        min(
            limit,
            length(results)
        )
    )
end

end

This gives you a proper ranking layer rather than simply doing:

filename.contains(query)
2. Swift native search index

I'd use SQLite locally rather than repeatedly scanning the filesystem.

import Foundation
import SQLite3

final class AureomSearchIndex {

    private var database:
        OpaquePointer?

    init() {

        let url =
            FileManager.default
                .urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                )[0]
                .appendingPathComponent(
                    "AureomSearch.sqlite"
                )

        try? FileManager.default
            .createDirectory(
                at:
                    url.deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

        sqlite3_open(
            url.path,
            &database
        )

        createTables()
    }

    deinit {
        sqlite3_close(database)
    }

    private func createTables() {

        let sql = """

        CREATE TABLE IF NOT EXISTS documents (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            body TEXT,
            path TEXT NOT NULL,
            kind TEXT,
            modified REAL,
            accessed REAL
        );

        CREATE INDEX IF NOT EXISTS
        documents_title_index
        ON documents(title);

        CREATE INDEX IF NOT EXISTS
        documents_kind_index
        ON documents(kind);

        """

        sqlite3_exec(
            database,
            sql,
            nil,
            nil,
            nil
        )
    }

    func insert(
        id: String,
        title: String,
        body: String,
        path: String,
        kind: String,
        modified: Date,
        accessed: Date
    ) {

        let sql = """

        INSERT OR REPLACE INTO documents
        (id, title, body, path, kind, modified, accessed)
        VALUES (?, ?, ?, ?, ?, ?, ?);

        """

        var statement:
            OpaquePointer?

        sqlite3_prepare_v2(
            database,
            sql,
            -1,
            &statement,
            nil
        )

        defer {
            sqlite3_finalize(
                statement
            )
        }

        sqlite3_bind_text(
            statement,
            1,
            id,
            -1,
            SQLITE_TRANSIENT
        )

        sqlite3_bind_text(
            statement,
            2,
            title,
            -1,
            SQLITE_TRANSIENT
        )

        sqlite3_bind_text(
            statement,
            3,
            body,
            -1,
            SQLITE_TRANSIENT
        )

        sqlite3_bind_text(
            statement,
            4,
            path,
            -1,
            SQLITE_TRANSIENT
        )

        sqlite3_bind_text(
            statement,
            5,
            kind,
            -1,
            SQLITE_TRANSIENT
        )

        sqlite3_bind_double(
            statement,
            6,
            modified.timeIntervalSince1970
        )

        sqlite3_bind_double(
            statement,
            7,
            accessed.timeIntervalSince1970
        )

        sqlite3_step(
            statement
        )
    }
}
3. Swift search engine

The user-facing search layer should be asynchronous so typing doesn't block the UI.

import Foundation

struct AureomSearchResult:
    Identifiable,
    Sendable {

    let id: String
    let title: String
    let path: String
    let kind: String
    let score: Double
}

actor AureomSearchEngine {

    private let index:
        AureomSearchIndex

    init(
        index:
            AureomSearchIndex
    ) {

        self.index =
            index
    }

    func search(
        _ query: String
    ) async
        -> [AureomSearchResult] {

        guard
            !query
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                .isEmpty
        else {
            return []
        }

        // Candidate retrieval happens locally.
        let candidates =
            retrieveCandidates(
                query:
                    query
            )

        // Ranking layer.
        return rank(
            query:
                query,
            candidates:
                candidates
        )
    }

    private func retrieveCandidates(
        query: String
    ) -> [AureomSearchResult] {

        // In production this would query SQLite
        // using FTS5 rather than scan every object.

        return []
    }

    private func rank(
        query: String,
        candidates:
            [AureomSearchResult]
    ) -> [AureomSearchResult] {

        candidates.sorted {
            $0.score >
            $1.score
        }
    }
}

The next important improvement is SQLite FTS5.

Instead of:

10,000 files
     ↓
Swift loops over everything

you want:

QUERY
 ↓
SQLite FTS5
 ↓
50–500 candidates
 ↓
Julia ranking
 ↓
top 20 results

That makes the system substantially faster as the index grows.

4. SwiftUI search interface
import SwiftUI

struct AureomSearchView:
    View {

    @State
    private var query = ""

    @State
    private var results:
        [AureomSearchResult] = []

    @State
    private var searching = false

    private let engine:
        AureomSearchEngine

    init(
        engine:
            AureomSearchEngine
    ) {

        self.engine =
            engine
    }

    var body: some View {

        NavigationStack {

            List(results) { result in

                HStack(
                    spacing: 14
                ) {

                    Image(
                        systemName:
                            icon(
                                for:
                                    result.kind
                            )
                    )
                    .font(
                        .title3
                    )

                    VStack(
                        alignment:
                            .leading,
                        spacing:
                            3
                    ) {

                        Text(
                            result.title
                        )
                        .font(
                            .headline
                        )

                        Text(
                            result.path
                        )
                        .font(
                            .caption
                        )
                        .foregroundStyle(
                            .secondary
                        )
                        .lineLimit(1)
                    }

                    Spacer()

                    Text(
                        String(
                            format:
                                "%.2f",
                            result.score
                        )
                    )
                    .font(
                        .caption.monospaced()
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }
            }
            .navigationTitle(
                "Search"
            )
            .searchable(
                text:
                    $query,
                prompt:
                    "Search everything"
            )
            .onChange(
                of:
                    query
            ) {

                Task {

                    searching = true

                    let output =
                        await engine.search(
                            query
                        )

                    results =
                        output

                    searching = false
                }
            }
        }
    }

    private func icon(
        for kind: String
    ) -> String {

        switch kind {

        case "image":
            return "photo"

        case "video":
            return "video"

        case "document":
            return "doc.text"

        case "audio":
            return "waveform"

        case "code":
            return "chevron.left.forwardslash.chevron.right"

        default:
            return "doc"
        }
    }
}
