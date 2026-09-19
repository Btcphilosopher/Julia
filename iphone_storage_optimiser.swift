//  AureomStorageEngine.swift
//
//  Native iOS storage intelligence engine.
//  Swift 6 / Swift Concurrency
//

import Foundation
import Photos
import UniformTypeIdentifiers
import CryptoKit
import Observation

// ============================================================
// MARK: - Models
// ============================================================

enum StorageCategory: String, Codable, Sendable {
    case image
    case video
    case audio
    case document
    case archive
    case code
    case database
    case temporary
    case unknown
}

enum StorageAction: String, Codable, Sendable {
    case keep
    case review
    case duplicate
    case compress
    case archive
    case removeTemporary
    case removeCache
}

struct StorageObject: Identifiable, Codable, Sendable {

    let id: UUID

    let url: URL

    let filename: String
    let pathExtension: String

    let sizeBytes: Int64

    let created: Date?
    let modified: Date?
    let accessed: Date?

    let category: StorageCategory

    let partialHash: String?
    let fullHash: String?

    let isDirectory: Bool
    let isHidden: Bool

    let importanceScore: Double
    let reclaimScore: Double
    let compressionScore: Double
}

struct DuplicateGroup: Identifiable, Sendable {

    let id = UUID()

    let hash: String
    let files: [StorageObject]

    var totalBytes: Int64 {
        files.reduce(0) {
            $0 + $1.sizeBytes
        }
    }

    var recoverableBytes: Int64 {
        guard files.count > 1 else {
            return 0
        }

        return files
            .dropFirst()
            .reduce(0) {
                $0 + $1.sizeBytes
            }
    }
}

struct StorageSummary: Sendable {

    let totalBytes: Int64
    let usedBytes: Int64
    let freeBytes: Int64

    let imageBytes: Int64
    let videoBytes: Int64
    let audioBytes: Int64
    let documentBytes: Int64
    let temporaryBytes: Int64

    let duplicateBytes: Int64
    let potentiallyReclaimableBytes: Int64
}

// ============================================================
// MARK: - File Classification
// ============================================================

struct AureomFileClassifier {

    func classify(
        url: URL
    ) -> StorageCategory {

        let values =
            try? url.resourceValues(
                forKeys: [
                    .contentTypeKey,
                    .isDirectoryKey
                ]
            )

        if values?.isDirectory == true {
            return .unknown
        }

        guard
            let type = values?.contentType
        else {
            return classifyExtension(
                url.pathExtension
            )
        }

        if type.conforms(
            to: .image
        ) {
            return .image
        }

        if type.conforms(
            to: .movie
        ) || type.conforms(
            to: .video
        ) {
            return .video
        }

        if type.conforms(
            to: .audio
        ) {
            return .audio
        }

        if type.conforms(
            to: .archive
        ) {
            return .archive
        }

        if type.conforms(
            to: .sourceCode
        ) {
            return .code
        }

        if type.conforms(
            to: .database
        ) {
            return .database
        }

        if type.conforms(
            to: .text
        ) ||
        type.conforms(
            to: .pdf
        ) {
            return .document
        }

        return .unknown
    }

    private func classifyExtension(
        _ ext: String
    ) -> StorageCategory {

        switch ext.lowercased() {

        case "jpg", "jpeg", "png",
             "heic", "heif", "webp",
             "tiff", "gif":
            return .image

        case "mov", "mp4", "m4v",
             "avi", "mkv":
            return .video

        case "mp3", "m4a", "aac",
             "wav", "flac":
            return .audio

        case "pdf", "txt", "rtf",
             "doc", "docx",
             "xls", "xlsx",
             "ppt", "pptx":
            return .document

        case "zip", "tar", "gz",
             "bz2", "7z":
            return .archive

        case "swift", "py", "jl",
             "js", "ts", "rs",
             "c", "cpp", "h":
            return .code

        case "sqlite", "db":
            return .database

        case "tmp", "temp":
            return .temporary

        default:
            return .unknown
        }
    }
}

// ============================================================
// MARK: - Efficient Hashing
// ============================================================

actor AureomHasher {

    private let chunkSize = 64 * 1024

    func partialHash(
        url: URL
    ) -> String? {

        guard
            let handle =
                try? FileHandle(
                    forReadingFrom: url
                )
        else {
            return nil
        }

        defer {
            try? handle.close()
        }

        var hasher = SHA256()

        guard
            let first =
                try? handle.read(
                    upToCount: chunkSize
                )
        else {
            return nil
        }

        hasher.update(
            data: first
        )

        guard
            let attributes =
                try? FileManager.default
                    .attributesOfItem(
                        atPath: url.path
                    ),
            let size =
                attributes[
                    .size
                ] as? NSNumber
        else {
            return nil
        }

        let fileSize =
            size.int64Value

        if fileSize > Int64(chunkSize) {

            try? handle.seek(
                toOffset:
                    UInt64(
                        max(
                            0,
                            fileSize -
                            Int64(chunkSize)
                        )
                    )
            )

            if let last =
                try? handle.read(
                    upToCount: chunkSize
                ) {

                hasher.update(
                    data: last
                )
            }
        }

        return hasher
            .finalize()
            .map {
                String(
                    format: "%02x",
                    $0
                )
            }
            .joined()
    }

    func fullHash(
        url: URL
    ) -> String? {

        guard
            let handle =
                try? FileHandle(
                    forReadingFrom: url
                )
        else {
            return nil
        }

        defer {
            try? handle.close()
        }

        var hasher = SHA256()

        while true {

            guard
                let data =
                    try? handle.read(
                        upToCount: chunkSize
                    )
            else {
                return nil
            }

            guard
                let data,
                !data.isEmpty
            else {
                break
            }

            hasher.update(
                data: data
            )
        }

        return hasher
            .finalize()
            .map {
                String(
                    format: "%02x",
                    $0
                )
            }
            .joined()
    }
}

// ============================================================
// MARK: - Storage Intelligence
// ============================================================

struct AureomStorageIntelligence {

    func importance(
        category: StorageCategory,
        accessed: Date?,
        modified: Date?,
        size: Int64
    ) -> Double {

        var score = 0.5

        switch category {

        case .document:
            score += 0.20

        case .image:
            score += 0.15

        case .video:
            score += 0.15

        case .code:
            score += 0.20

        case .database:
            score += 0.20

        case .temporary:
            score -= 0.30

        default:
            break
        }

        if let accessed {

            let age =
                Date().timeIntervalSince(
                    accessed
                )

            let days =
                age / 86400.0

            if days < 7 {
                score += 0.15
            }
        }

        return clamp(
            score
        )
    }

    func reclaimScore(
        category: StorageCategory,
        accessed: Date?,
        size: Int64
    ) -> Double {

        var score = 0.0

        if category == .temporary {
            score += 0.85
        }

        if let accessed {

            let age =
                Date().timeIntervalSince(
                    accessed
                )

            let days =
                age / 86400.0

            if days > 365 {
                score += 0.15
            }
            else if days > 180 {
                score += 0.08
            }
        }

        if size > 1_000_000_000 {
            score += 0.10
        }

        return clamp(score)
    }

    func compressionScore(
        category: StorageCategory
    ) -> Double {

        switch category {

        case .document:
            return 0.85

        case .archive:
            return 0.05

        case .image:
            return 0.25

        case .video:
            return 0.10

        case .audio:
            return 0.15

        case .code:
            return 0.75

        default:
            return 0.30
        }
    }

    private func clamp(
        _ value: Double
    ) -> Double {

        min(
            max(
                value,
                0
            ),
            1
        )
    }
}

// ============================================================
// MARK: - Storage Scanner
// ============================================================

actor AureomStorageScanner {

    private let fileManager =
        FileManager.default

    private let classifier =
        AureomFileClassifier()

    private let hasher =
        AureomHasher()

    private let intelligence =
        AureomStorageIntelligence()

    func scan(
        roots: [URL]
    ) async -> [StorageObject] {

        var objects:
            [StorageObject] = []

        for root in roots {

            let keys:
                [URLResourceKey] = [

                    .isDirectoryKey,
                    .isHiddenKey,
                    .fileSizeKey,
                    .creationDateKey,
                    .contentModificationDateKey,
                    .contentAccessDateKey,
                    .contentTypeKey
                ]

            guard
                let enumerator =
                    fileManager.enumerator(
                        at: root,
                        includingPropertiesForKeys:
                            keys,
                        options: [
                            .skipsPackageDescendants
                        ]
                    )
            else {
                continue
            }

            for case let url as URL
                in enumerator {

                guard
                    let values =
                        try? url.resourceValues(
                            forKeys:
                                Set(keys)
                        )
                else {
                    continue
                }

                guard
                    values.isDirectory != true
                else {
                    continue
                }

                let size =
                    Int64(
                        values.fileSize ?? 0
                    )

                let category =
                    classifier.classify(
                        url: url
                    )

                let partial =
                    await hasher.partialHash(
                        url: url
                    )

                let importance =
                    intelligence.importance(
                        category: category,
                        accessed: values.contentAccessDate,
                        modified: values.contentModificationDate,
                        size: size
                    )

                let reclaim =
                    intelligence.reclaimScore(
                        category: category,
                        accessed: values.contentAccessDate,
                        size: size
                    )

                let compression =
                    intelligence.compressionScore(
                        category: category
                    )

                let object =
                    StorageObject(
                        id: UUID(),
                        url: url,
                        filename: url.lastPathComponent,
                        pathExtension:
                            url.pathExtension,
                        sizeBytes: size,
                        created:
                            values.creationDate,
                        modified:
                            values.contentModificationDate,
                        accessed:
                            values.contentAccessDate,
                        category: category,
                        partialHash: partial,
                        fullHash: nil,
                        isDirectory:
                            values.isDirectory ?? false,
                        isHidden:
                            values.isHidden ?? false,
                        importanceScore:
                            importance,
                        reclaimScore:
                            reclaim,
                        compressionScore:
                            compression
                    )

                objects.append(
                    object
                )
            }
        }

        return objects
    }
}

// ============================================================
// MARK: - Duplicate Engine
// ============================================================

struct AureomDuplicateEngine {

    func findDuplicates(
        objects: [StorageObject]
    ) -> [DuplicateGroup] {

        let candidates =
            Dictionary(
                grouping:
                    objects.filter {
                        $0.partialHash != nil
                    },
                by: {
                    "\($0.sizeBytes):\($0.partialHash!)"
                }
            )

        var groups:
            [DuplicateGroup] = []

        for (_, candidates) in candidates {

            guard
                candidates.count > 1
            else {
                continue
            }

            var grouped:
                [String: [StorageObject]] = [:]

            for object in candidates {

                guard
                    let hash =
                        object.partialHash
                else {
                    continue
                }

                grouped[hash, default: []]
                    .append(object)
            }

            for (hash, files)
                in grouped
                where files.count > 1 {

                groups.append(
                    DuplicateGroup(
                        hash: hash,
                        files: files
                    )
                )
            }
        }

        return groups
    }
}

// ============================================================
// MARK: - Storage Summary
// ============================================================

struct AureomStorageAnalyzer {

    func summary(
        objects: [StorageObject],
        capacity: Int64
    ) -> StorageSummary {

        func total(
            _ category: StorageCategory
        ) -> Int64 {

            objects
                .filter {
                    $0.category == category
                }
                .reduce(0) {
                    $0 + $1.sizeBytes
                }
        }

        let used =
            objects.reduce(0) {
                $0 + $1.sizeBytes
            }

        let duplicates =
            AureomDuplicateEngine()
                .findDuplicates(
                    objects: objects
                )
                .reduce(0) {
                    $0 + $1.recoverableBytes
                }

        let reclaimable =
            objects
                .filter {
                    $0.reclaimScore > 0.70
                }
                .reduce(0) {
                    $0 + $1.sizeBytes
                }

        return StorageSummary(
            totalBytes: capacity,
            usedBytes: used,
            freeBytes:
                max(
                    capacity - used,
                    0
                ),
            imageBytes:
                total(.image),
            videoBytes:
                total(.video),
            audioBytes:
                total(.audio),
            documentBytes:
                total(.document),
            temporaryBytes:
                total(.temporary),
            duplicateBytes:
                duplicates,
            potentiallyReclaimableBytes:
                reclaimable
        )
    }
}

// ============================================================
// MARK: - Safe Execution
// ============================================================

actor AureomStorageExecutor {

    private let fileManager =
        FileManager.default

    func removeTemporary(
        _ url: URL
    ) throws {

        guard
            fileManager.fileExists(
                atPath: url.path
            )
        else {
            return
        }

        try fileManager.removeItem(
            at: url
        )
    }

    func moveToArchive(
        _ source: URL,
        archive: URL
    ) throws {

        try fileManager.createDirectory(
            at: archive,
            withIntermediateDirectories: true
        )

        let destination =
            archive.appendingPathComponent(
                source.lastPathComponent
            )

        try fileManager.moveItem(
            at: source,
            to: destination
        )
    }
}

// ============================================================
// MARK: - Main Engine
// ============================================================

@MainActor
@Observable
final class AureomStorageEngine {

    private(set) var objects:
        [StorageObject] = []

    private(set) var summary:
        StorageSummary?

    private(set) var duplicateGroups:
        [DuplicateGroup] = []

    private(set) var scanning = false

    private let scanner =
        AureomStorageScanner()

    private let analyzer =
        AureomStorageAnalyzer()

    func scan(
        roots: [URL],
        capacity: Int64
    ) {

        scanning = true

        Task {

            let result =
                await scanner.scan(
                    roots: roots
                )

            let duplicates =
                AureomDuplicateEngine()
                    .findDuplicates(
                        objects: result
                    )

            let summary =
                analyzer.summary(
                    objects: result,
                    capacity: capacity
                )

            self.objects =
                result

            self.duplicateGroups =
                duplicates

            self.summary =
                summary

            self.scanning = false
        }
    }
}

Then put a SwiftUI interface over it:

import SwiftUI

struct AureomStorageView: View {

    @State
    private var engine =
        AureomStorageEngine()

    var body: some View {

        NavigationStack {

            ScrollView {

                VStack(
                    alignment: .leading,
                    spacing: 24
                ) {

                    storageHeader

                    if let summary =
                        engine.summary {

                        storageBreakdown(
                            summary
                        )

                        optimisationCard(
                            summary
                        )
                    }

                    duplicateSection

                    largeFilesSection
                }
                .padding()
            }
            .navigationTitle(
                "Storage"
            )
        }
    }

    private var storageHeader:
        some View {

        VStack(
            alignment: .leading,
            spacing: 8
        ) {

            Text(
                "Aureom Storage"
            )
            .font(
                .system(
                    size: 34,
                    weight: .bold,
                    design: .rounded
                )
            )

            Text(
                "Intelligent local storage management"
            )
            .foregroundStyle(
                .secondary
            )
        }
    }

    private func storageBreakdown(
        _ summary: StorageSummary
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 12
        ) {

            Text(
                ByteCountFormatter
                    .string(
                        fromByteCount:
                            summary.usedBytes,
                        countStyle:
                            .file
                    )
            )
            .font(
                .system(
                    size: 42,
                    weight: .bold
                )
            )

            Text("used")

            ProgressView(
                value:
                    Double(
                        summary.usedBytes
                    ),
                total:
                    Double(
                        max(
                            summary.totalBytes,
                            1
                        )
                    )
            )

            HStack {

                metric(
                    "Photos",
                    summary.imageBytes
                )

                metric(
                    "Video",
                    summary.videoBytes
                )

                metric(
                    "Documents",
                    summary.documentBytes
                )
            }
        }
    }

    private func metric(
        _ title: String,
        _ bytes: Int64
    ) -> some View {

        VStack(
            alignment: .leading
        ) {

            Text(title)
                .font(.caption)
                .foregroundStyle(
                    .secondary
                )

            Text(
                ByteCountFormatter
                    .string(
                        fromByteCount:
                            bytes,
                        countStyle:
                            .file
                    )
            )
            .font(
                .headline
            )
        }
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    private func optimisationCard(
        _ summary: StorageSummary
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            Text(
                "Potential recovery"
            )
            .font(.headline)

            Text(
                ByteCountFormatter.string(
                    fromByteCount:
                        summary
                            .potentiallyReclaimableBytes,
                    countStyle:
                        .file
                )
            )
            .font(
                .system(
                    size: 28,
                    weight: .bold
                )
            )

            Text(
                "Includes temporary files, "
                + "duplicates and other "
                + "high-confidence candidates."
            )
            .font(.caption)
            .foregroundStyle(
                .secondary
            )
        }
        .padding()
        .background(
            .regularMaterial,
            in:
                RoundedRectangle(
                    cornerRadius: 24
                )
        )
    }

    private var duplicateSection:
        some View {

        VStack(
            alignment: .leading
        ) {

            Text(
                "Duplicates"
            )
            .font(.title2.bold())

            if engine.duplicateGroups.isEmpty {

                Text(
                    "No duplicate groups detected."
                )
                .foregroundStyle(
                    .secondary
                )

            } else {

                ForEach(
                    engine.duplicateGroups
                ) { group in

                    HStack {

                        VStack(
                            alignment: .leading
                        ) {

                            Text(
                                "\(group.files.count) copies"
                            )

                            Text(
                                ByteCountFormatter
                                    .string(
                                        fromByteCount:
                                            group.recoverableBytes,
                                        countStyle:
                                            .file
                                    )
                                + " recoverable"
                            )
                            .font(.caption)
                            .foregroundStyle(
                                .secondary
                            )
                        }

                        Spacer()

                        Button("Review") {
                            // Open review flow.
                        }
                    }
                }
            }
        }
    }

    private var largeFilesSection:
        some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            Text(
                "Large files"
            )
            .font(.title2.bold())

            ForEach(
                engine.objects
                    .sorted {
                        $0.sizeBytes >
                        $1.sizeBytes
                    }
                    .prefix(20)
            ) { object in

                HStack {

                    VStack(
                        alignment: .leading
                    ) {

                        Text(
                            object.filename
                        )
                        .lineLimit(1)

                        Text(
                            object.category.rawValue
                        )
                        .font(.caption)
                        .foregroundStyle(
                            .secondary
                        )
                    }

                    Spacer()

                    Text(
                        ByteCountFormatter
                            .string(
                                fromByteCount:
                                    object.sizeBytes,
                                countStyle:
                                    .file
                            )
                    )
                    .font(.caption)
                }
            }
        }
    }
}
