//
//  PosterBoardZip.swift
//  worsegestalt
//
//  A small ZIP reader for `.tendies` wallpaper packs.
//
//  A pack is an ordinary ZIP archive whose entries are descriptor folders.
//  Rather than pulling in ZIPFoundation (or a zlib module) we read the central
//  directory ourselves and inflate method-8 entries with Compression's
//  COMPRESSION_ZLIB, which is raw DEFLATE (RFC 1951) on Apple platforms.
//
//  Only the parts of ZIP the packs actually use are implemented: stored and
//  deflated entries, the Zip64 end record, and the Zip64 extra field. Entries
//  that are symlinks are refused; junk (`__MACOSX`, `.DS_Store`, AppleDouble)
//  is skipped. Dotfiles that are *not* junk are kept, because PosterBoard
//  descriptors use `.com.apple.posterkit.provider.contents.configurableOptions
//  .plist` as a real payload.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Compression
import Foundation

struct PosterBoardZipError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum PosterBoardZip {
    /// A pack has no business being larger than this on a phone.
    static let maxArchiveBytes = 256 * 1024 * 1024
    static let maxEntries = 8_192
    static let maxEntryBytes = 128 * 1024 * 1024
    static let maxExpandedBytes = 1_024 * 1024 * 1024

    private struct Record {
        let path: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
        let isDirectory: Bool
        let isSymlink: Bool
    }

    // MARK: - Public API

    /// The sanitised entry paths in the archive, without inflating anything.
    /// This is enough to count descriptors and detect a `container/` pack.
    static func entryPaths(at url: URL) throws -> [String] {
        let data = try load(url)
        return try data.withUnsafeBytes { raw in
            try records(in: raw).map(\.path)
        }
    }

    /// Extract every safe entry under `destination`.
    ///
    /// - Returns: the number of regular files written.
    @discardableResult
    static func extract(at url: URL, to destination: URL) throws -> Int {
        let data = try load(url)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        return try data.withUnsafeBytes { raw in
            let entries = try records(in: raw)
            var expanded = 0
            var written = 0

            for entry in entries {
                if entry.isSymlink {
                    throw PosterBoardZipError(message: "\(url.lastPathComponent) contains a symlink "
                        + "(\(entry.path)); refusing to extract it.")
                }
                let target = destination.appendingPathComponent(entry.path)

                if entry.isDirectory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }

                guard entry.uncompressedSize <= maxEntryBytes else {
                    throw PosterBoardZipError(message: "\(entry.path) expands to more than "
                        + "\(maxEntryBytes / (1024 * 1024)) MB.")
                }
                guard expanded <= maxExpandedBytes - entry.uncompressedSize else {
                    throw PosterBoardZipError(message: "\(url.lastPathComponent) expands to more than "
                        + "\(maxExpandedBytes / (1024 * 1024)) MB.")
                }
                expanded += entry.uncompressedSize

                let payload = try payload(for: entry, in: raw)
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try payload.write(to: target, options: .atomic)
                written += 1
            }
            return written
        }
    }

    // MARK: - Reading the archive

    private static func load(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxArchiveBytes else {
            throw PosterBoardZipError(message: "\(url.lastPathComponent) is larger than "
                + "\(maxArchiveBytes / (1024 * 1024)) MB.")
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maxArchiveBytes else {
            throw PosterBoardZipError(message: "\(url.lastPathComponent) is larger than "
                + "\(maxArchiveBytes / (1024 * 1024)) MB.")
        }
        guard data.count >= 4, data[0] == 0x50, data[1] == 0x4B else {
            throw PosterBoardZipError(message: "\(url.lastPathComponent) is not a ZIP archive.")
        }
        return data
    }

    private static func records(in raw: UnsafeRawBufferPointer) throws -> [Record] {
        let count = raw.count
        guard count >= 22 else {
            throw PosterBoardZipError(message: "The archive is too short to be a ZIP.")
        }

        // The end-of-central-directory record can be followed by a comment of
        // up to 64 KB, so scan backwards through that window.
        var eocd = -1
        let lowerBound = max(0, count - 22 - 65_535)
        var cursor = count - 22
        while cursor >= lowerBound {
            if readU32(raw, cursor) == 0x0605_4B50 {
                eocd = cursor
                break
            }
            cursor -= 1
        }
        guard eocd >= 0 else {
            throw PosterBoardZipError(message: "The ZIP central directory was not found.")
        }

        var entryCount = Int(readU16(raw, eocd + 10))
        var directorySize = Int(readU32(raw, eocd + 12))
        var directoryOffset = Int(readU32(raw, eocd + 16))

        // Zip64 end-of-central-directory record + locator.
        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF,
           eocd >= 20,
           readU32(raw, eocd - 20) == 0x0706_4B50 {
            let zip64Offset = readU64Int(raw, eocd - 20 + 8)
            if let zip64Offset,
               zip64Offset <= count - 56,
               readU32(raw, zip64Offset) == 0x0606_4B50,
               let zip64Entries = readU64Int(raw, zip64Offset + 32),
               let zip64Size = readU64Int(raw, zip64Offset + 40),
               let zip64Directory = readU64Int(raw, zip64Offset + 48) {
                entryCount = zip64Entries
                directorySize = zip64Size
                directoryOffset = zip64Directory
            } else {
                throw PosterBoardZipError(message: "The Zip64 directory record is malformed.")
            }
        }

        guard entryCount >= 0, entryCount <= maxEntries else {
            throw PosterBoardZipError(message: "The pack contains \(entryCount) entries; "
                + "the limit is \(maxEntries).")
        }
        guard directoryOffset >= 0,
              directorySize >= 0,
              directoryOffset <= count,
              directorySize <= count - directoryOffset else {
            throw PosterBoardZipError(message: "The ZIP central directory is out of bounds.")
        }

        var result: [Record] = []
        result.reserveCapacity(entryCount)
        var pointer = directoryOffset

        for _ in 0..<entryCount {
            guard pointer + 46 <= count,
                  readU32(raw, pointer) == 0x0201_4B50 else {
                throw PosterBoardZipError(message: "A ZIP central-directory entry is malformed.")
            }

            let flags = readU16(raw, pointer + 8)
            let method = readU16(raw, pointer + 10)
            let compressedRaw = readU32(raw, pointer + 20)
            let uncompressedRaw = readU32(raw, pointer + 24)
            let nameLength = Int(readU16(raw, pointer + 28))
            let extraLength = Int(readU16(raw, pointer + 30))
            let commentLength = Int(readU16(raw, pointer + 32))
            let externalAttributes = readU32(raw, pointer + 38)
            let localRaw = readU32(raw, pointer + 42)

            var compressed = Int(compressedRaw)
            var uncompressed = Int(uncompressedRaw)
            var localOffset = Int(localRaw)

            let nameStart = pointer + 46
            guard nameStart + nameLength <= count,
                  nameStart + nameLength + extraLength + commentLength <= count else {
                throw PosterBoardZipError(message: "A ZIP entry name is out of bounds.")
            }

            if uncompressedRaw == 0xFFFF_FFFF
                || compressedRaw == 0xFFFF_FFFF
                || localRaw == 0xFFFF_FFFF {
                let zip64 = zip64Values(
                    in: raw,
                    extraStart: nameStart + nameLength,
                    extraLength: extraLength,
                    needUncompressed: uncompressedRaw == 0xFFFF_FFFF,
                    needCompressed: compressedRaw == 0xFFFF_FFFF,
                    needOffset: localRaw == 0xFFFF_FFFF
                )
                if let value = zip64.uncompressed { uncompressed = value }
                if let value = zip64.compressed { compressed = value }
                if let value = zip64.offset { localOffset = value }
            }

            let nameData = Data(raw[nameStart..<nameStart + nameLength])
            let rawName = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""

            let isDirectory = rawName.hasSuffix("/")
            pointer = nameStart + nameLength + extraLength + commentLength

            guard let path = sanitisedPath(rawName) else { continue }
            guard flags & 0x0001 == 0 else {
                throw PosterBoardZipError(message: "\(path) is encrypted; .tendies packs "
                    + "must be unencrypted.")
            }
            guard compressed >= 0,
                  uncompressed >= 0,
                  compressed <= maxArchiveBytes,
                  uncompressed <= maxEntryBytes else {
                throw PosterBoardZipError(message: "\(path) exceeds the safe ZIP entry size.")
            }

            let isSymlink = ((externalAttributes >> 16) & 0xF000) == 0xA000
            result.append(Record(path: path,
                                 method: method,
                                 compressedSize: compressed,
                                 uncompressedSize: uncompressed,
                                 localOffset: localOffset,
                                 isDirectory: isDirectory,
                                 isSymlink: isSymlink))
        }

        return result
    }

    /// Values from a Zip64 extended-information field (tag 0x0001), in the
    /// order the spec defines: uncompressed, compressed, local-header offset.
    private static func zip64Values(in raw: UnsafeRawBufferPointer,
                                    extraStart: Int,
                                    extraLength: Int,
                                    needUncompressed: Bool,
                                    needCompressed: Bool,
                                    needOffset: Bool)
        -> (uncompressed: Int?, compressed: Int?, offset: Int?) {
        var cursor = extraStart
        let end = extraStart + extraLength
        while cursor + 4 <= end {
            let tag = readU16(raw, cursor)
            let size = Int(readU16(raw, cursor + 2))
            let body = cursor + 4
            guard size >= 0, body + size <= end else { break }
            if tag == 0x0001 {
                var valueCursor = body
                let valueEnd = body + size

                func next() -> Int? {
                    guard valueCursor + 8 <= valueEnd,
                          let value = readU64Int(raw, valueCursor) else { return nil }
                    valueCursor += 8
                    return value
                }

                var uncompressed: Int?
                var compressed: Int?
                var offset: Int?
                if needUncompressed { uncompressed = next() }
                if needCompressed { compressed = next() }
                if needOffset { offset = next() }
                return (uncompressed, compressed, offset)
            }
            cursor = body + size
        }
        return (nil, nil, nil)
    }

    private static func payload(for entry: Record,
                                in raw: UnsafeRawBufferPointer) throws -> Data {
        let count = raw.count
        guard entry.localOffset >= 0,
              entry.localOffset + 30 <= count,
              readU32(raw, entry.localOffset) == 0x0403_4B50 else {
            throw PosterBoardZipError(message: "\(entry.path) has a malformed local header.")
        }

        let nameLength = Int(readU16(raw, entry.localOffset + 26))
        let extraLength = Int(readU16(raw, entry.localOffset + 28))
        let dataOffset = entry.localOffset + 30 + nameLength + extraLength

        guard dataOffset >= 0,
              dataOffset + entry.compressedSize <= count else {
            throw PosterBoardZipError(message: "\(entry.path) points outside the archive.")
        }

        let range = dataOffset..<dataOffset + entry.compressedSize
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else {
                throw PosterBoardZipError(message: "\(entry.path) is stored but its sizes "
                    + "disagree.")
            }
            return Data(raw[range])
        case 8:
            let compressed = Data(raw[range])
            return try inflateRaw(compressed,
                                  expected: entry.uncompressedSize,
                                  name: entry.path)
        default:
            throw PosterBoardZipError(message: "\(entry.path) uses unsupported ZIP "
                + "compression method \(entry.method).")
        }
    }

    private static func inflateRaw(_ source: Data,
                                   expected: Int,
                                   name: String) throws -> Data {
        if expected == 0 { return Data() }
        guard !source.isEmpty else {
            throw PosterBoardZipError(message: "\(name) is empty but should expand to "
                + "\(expected) bytes.")
        }

        var output = [UInt8](repeating: 0, count: expected)
        let produced = output.withUnsafeMutableBytes { destination -> Int in
            source.withUnsafeBytes { sourceBytes -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = sourceBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(destinationBase,
                                                 expected,
                                                 sourceBase,
                                                 source.count,
                                                 nil,
                                                 COMPRESSION_ZLIB)
            }
        }

        guard produced == expected else {
            throw PosterBoardZipError(message: "\(name) did not inflate to its declared size "
                + "(\(produced) of \(expected) bytes).")
        }
        return Data(output)
    }

    // MARK: - Paths

    private static let junkNames: Set<String> = [
        "__macosx",
        ".ds_store",
        ".appledouble",
    ]

    private static func sanitisedPath(_ raw: String) -> String? {
        var value = raw.replacingOccurrences(of: "\\", with: "/")
        if value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.hasPrefix("~") else { return nil }

        var pieces: [String] = []
        for component in value.split(separator: "/", omittingEmptySubsequences: true) {
            let piece = String(component)
            if piece == "." || piece == ".." { return nil }
            if junkNames.contains(piece.lowercased()) || piece.hasPrefix("._") { return nil }
            pieces.append(piece)
        }
        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: "/")
    }

    // MARK: - Little-endian readers

    private static func readU16(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= raw.count else { return 0 }
        return UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
    }

    private static func readU32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= raw.count else { return 0 }
        return UInt32(raw[offset])
            | (UInt32(raw[offset + 1]) << 8)
            | (UInt32(raw[offset + 2]) << 16)
            | (UInt32(raw[offset + 3]) << 24)
    }

    private static func readU64(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= raw.count else { return 0 }
        let low = UInt64(readU32(raw, offset))
        let high = UInt64(readU32(raw, offset + 4))
        return low | (high << 32)
    }

    /// A 64-bit offset/size as an `Int`, or nil when it cannot be one. The
    /// unchecked `Int(UInt64)` conversion traps on overflow, and this parser
    /// runs on files chosen by the user.
    private static func readU64Int(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> Int? {
        guard offset >= 0, offset + 8 <= raw.count else { return nil }
        return Int(exactly: readU64(raw, offset))
    }
}
