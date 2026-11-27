//
//  PosterBoardEngine.swift
//  worsegestalt
//
//  PosterBoard wallpapers, written from the on-device store layout. A
//  `.tendies` pack is a ZIP of descriptor directories, and each descriptor
//  becomes a folder under
//
//      <PosterBoard container>/Library/Application Support/
//          PRBPosterExtensionDataStore/<structure version>/
//          Extensions/<provider>/descriptors/<UUID>
//
//  The descriptor's own files carry three identity fields. They have to agree
//  with each other or PosterBoard cannot resolve the wallpaper, so an import
//  copies the folder under a fresh UUID and rewrites those fields. Mercury is
//  the exception: its folder name and identifiers are its own lookup key, so
//  they are preserved byte for byte.
//
//  This is a *gallery* descriptor install, not a configuration install. The
//  files go straight into `descriptors/`; adding a role sidecar or changing the
//  wallpaper family would make PosterBoard treat the descriptor as an
//  unregistered lock-screen configuration and render the empty 9:41
//  placeholder. Provider folders are never invented — the write goes to the
//  structure version where the provider extension already exists, under the
//  legacy Collections bundle id the store was built with.
//
//  This is intentionally descriptor-only. GoldenNugget also stitches the
//  store's SQLite database from a device backup; we do not. A `container/`
//  pack is treated as a convenient way to carry descriptor folders — the
//  stale database and preference files inside it are *not* written.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation

// MARK: - Errors and results

struct PosterBoardError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PosterBoardLocation: Equatable, Sendable {
    let container: String
    let structureVersion: Int

    /// `<container>/Library/Application Support/PRBPosterExtensionDataStore/<v>`.
    var storePath: String {
        "\(container)/Library/Application Support/\(PosterBoardInstaller.storeDirectoryName)/\(structureVersion)"
    }
}

struct PosterBoardApplyResult: Sendable {
    let count: Int
    let location: PosterBoardLocation
}

struct PosterBoardResetResult: Sendable {
    let removed: Int
    let failed: Int
    let location: PosterBoardLocation
}

// MARK: - Packs

/// Which provider a bare descriptor pack is installed under.
///
/// A pack that ships `descriptors/<UUID>` does not say which extension owns
/// it. A container snapshot does (the extension is in the path), and the path
/// markers (`video-descriptor`, `mercury`) are strong hints, but a plain
/// descriptor pack needs the user's answer. It is remembered by file name, the
/// same way GoldenNugget keeps `TendieItem.posterType`.
enum PosterBoardProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case collections
    case photos
    case mercury

    var id: String { rawValue }

    var label: String {
        switch self {
        case .collections: return "Collections"
        case .photos: return "Suggested Photos"
        case .mercury: return "Mercury"
        }
    }

    var extensionID: String {
        switch self {
        case .collections: return PosterBoardInstaller.collectionsExtension
        case .photos: return PosterBoardInstaller.photosExtension
        case .mercury: return PosterBoardInstaller.mercuryExtension
        }
    }
}

enum PosterBoardPackPreferences {
    private static let providersKey = "PosterBoardPackProviders"

    static func provider(for name: String) -> PosterBoardProvider? {
        let stored = UserDefaults.standard.dictionary(forKey: providersKey)?[name] as? String
        return stored.flatMap(PosterBoardProvider.init(rawValue:))
    }

    static func setProvider(_ provider: PosterBoardProvider, for name: String) {
        var stored = UserDefaults.standard.dictionary(forKey: providersKey) ?? [:]
        stored[name] = provider.rawValue
        UserDefaults.standard.set(stored, forKey: providersKey)
        UserDefaults.standard.synchronize()
    }
}

private let posterBoardDescriptorContainerNames: Set<String> = [
    "descriptor",
    "descriptors",
    "ordered-descriptor",
    "ordered-descriptors",
    "video-descriptor",
    "video-descriptors",
]

/// An imported `.tendies` pack in the app's Documents directory.
struct PosterBoardPack: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let descriptorCount: Int
    let isContainer: Bool
    /// The provider used for descriptors whose path does not name one.
    let provider: PosterBoardProvider

    var id: String { url.path }

    init(url: URL) throws {
        let paths = try PosterBoardZip.entryPaths(at: url)

        var descriptors = Set<String>()
        var container = false

        for path in paths {
            let lower = path.lowercased()
            let components = lower.split(separator: "/").map(String.init)

            if lower == "container"
                || lower.hasPrefix("container/")
                || lower.contains("/container/") {
                container = true
            }

            for (index, component) in components.enumerated()
            where posterBoardDescriptorContainerNames.contains(component) {
                guard index + 1 < components.count else { continue }
                descriptors.insert(components.prefix(index + 2).joined(separator: "/"))
            }

            // Some packs omit the `descriptors/` wrapper and put a bare
            // `<UUID>/versions/...` tree at the archive root.
            if let versionsIndex = components.firstIndex(of: "versions"), versionsIndex > 0 {
                let parent = components[versionsIndex - 1]
                if parent.count >= 32 {
                    descriptors.insert(
                        components.prefix(versionsIndex).joined(separator: "/")
                    )
                }
            }
        }

        // A pack may also be a single descriptor with `versions/` at its root.
        if descriptors.isEmpty, !container {
            let rootIsDescriptor = paths.contains { path in
                let lower = path.lowercased()
                return lower.hasPrefix("versions/")
                    || lower == "wallpaper.plist"
                    || lower == "com.apple.posterkit.provider.descriptor.identifier"
            }
            if rootIsDescriptor { descriptors.insert("/") }
        }

        guard !descriptors.isEmpty else {
            throw PosterBoardError(message: "\(url.lastPathComponent) holds no PosterBoard "
                + "descriptor folders; this build installs descriptors only"
                + (container ? " (its database and preferences are not imported)." : "."))
        }

        self.url = url
        self.name = url.lastPathComponent
        self.descriptorCount = descriptors.count
        self.isContainer = container
        self.provider = PosterBoardPackPreferences.provider(for: url.lastPathComponent)
            ?? Self.inferProvider(from: paths)
    }

    private static func inferProvider(from paths: [String]) -> PosterBoardProvider {
        var inferred: PosterBoardProvider = .collections
        for path in paths {
            let components = path.lowercased().split(separator: "/").map(String.init)
            if components.contains(where: { $0.contains("mercuryposter") })
                || components.contains("mercury") {
                return .mercury
            }
            if components.contains(where: { $0.contains("photosposterprovider") })
                || components.contains("video-descriptor")
                || components.contains("video-descriptors") {
                inferred = .photos
            }
        }
        return inferred
    }

    var summary: String {
        if isContainer {
            return descriptorCount == 0
                ? "container snapshot (no descriptors)"
                : "container snapshot · \(descriptorCount) descriptor(s)"
        }
        return descriptorCount == 1 ? "1 descriptor" : "\(descriptorCount) descriptors"
    }
}

enum PosterBoardImports {
    /// The reference caps a selection at ten because PosterBoard's picker gets
    /// unusable past that. We enforce the same limit at apply time.
    static let descriptorLimit = 10

    static var directory: URL {
        URL(fileURLWithPath: BQ.documents(), isDirectory: true)
            .appendingPathComponent("PosterBoard/Imports", isDirectory: true)
    }

    static func load() -> [PosterBoardPack] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().compactMap { name in
            try? PosterBoardPack(url: directory.appendingPathComponent(name))
        }
    }

    static func importPack(from source: URL) throws -> PosterBoardPack {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueDestination(for: source.lastPathComponent)
        try? fm.removeItem(at: destination)

        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            throw PosterBoardError(message: "Could not copy \(source.lastPathComponent) into the app: "
                + error.localizedDescription)
        }

        do {
            return try PosterBoardPack(url: destination)
        } catch {
            // Not a pack: leave nothing behind for the next launch to trip on.
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    static func remove(_ pack: PosterBoardPack) {
        try? FileManager.default.removeItem(at: pack.url)
    }

    private static func uniqueDestination(for name: String) -> URL {
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        if !existing.contains(name) { return directory.appendingPathComponent(name) }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            if !existing.contains(candidate) {
                return directory.appendingPathComponent(candidate)
            }
            index += 1
        }
    }
}

// MARK: - Installer

enum PosterBoardInstaller {
    static let collectionsExtension = "com.apple.WallpaperKit.CollectionsPoster"
    static let mercuryExtension = "com.apple.MercuryPoster"
    static let photosExtension = "com.apple.PhotosUIPrivate.PhotosPosterProvider"
    static let modernCollectionsExtension = "com.apple.Posters.CollectionsPosterApp"

    static let storeDirectoryName = "PRBPosterExtensionDataStore"
    static let fallbackStructureVersion = 61
    static let identifierRange = 9_999...99_999

    private static let cacheKey = "PosterBoardContainerPath"
    private static let installedKey = "PosterBoardInstalledDescriptors"

    private static let junkNames: Set<String> = [
        "__macosx",
        ".ds_store",
        ".appledouble",
    ]

    /// One descriptor folder this app installed, remembered so Reset removes
    /// only our own wallpapers instead of every provider folder on the device.
    /// `version` is optional so records written by earlier builds still decode.
    private struct InstalledDescriptor: Codable {
        let provider: String
        let name: String
        let version: Int?
    }

    private struct ResetGroup: Hashable {
        let provider: String
        let version: Int
    }

    private static func recordedDescriptors() -> [InstalledDescriptor] {
        guard let data = UserDefaults.standard.data(forKey: installedKey),
              let records = try? JSONDecoder().decode([InstalledDescriptor].self, from: data)
        else { return [] }
        return records
    }

    private static func saveRecordedDescriptors(_ records: [InstalledDescriptor]) {
        let defaults = UserDefaults.standard
        if records.isEmpty {
            defaults.removeObject(forKey: installedKey)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: installedKey)
        }
        defaults.synchronize()
    }

    private static var workDirectory: URL {
        URL(fileURLWithPath: BQ.documents(), isDirectory: true)
            .appendingPathComponent("PosterBoard/Work", isDirectory: true)
    }

    // MARK: Locating the container

    /// Find (or accept a cached) `com.apple.PosterBoard` data container and the
    /// numeric structure version inside it.
    static func locate(force: Bool = false,
                       progress: @escaping @Sendable (String) -> Void = { _ in })
        throws -> PosterBoardLocation {
        guard BQ.coreInit() else {
            throw PosterBoardError(message: "The sandbox escape engine did not initialise.")
        }

        let defaults = UserDefaults.standard
        if !force,
           let cached = defaults.string(forKey: cacheKey),
           !cached.isEmpty,
           let version = storeVersion(of: cached) {
            return PosterBoardLocation(container: cached, structureVersion: version)
        }

        let roots = [
            "/var/mobile/Containers/Data/Application",
            "/var/containers/Data/System",
            "/var/mobile/Containers/Data/InternalDaemon",
            "/var/mobile/Containers/Data/PluginKitPlugin",
        ]

        var scanned = 0
        for root in roots {
            let candidates = inodeChildren(of: root)
            progress("Scanning \(root) (\(candidates.count) candidate(s))…")
            for candidate in candidates {
                if scanned >= 400 { break }
                scanned += 1
                if let version = storeVersion(of: candidate) {
                    defaults.set(candidate, forKey: cacheKey)
                    defaults.synchronize()
                    BQ.log("PosterBoard: container \(candidate), structure version \(version)")
                    return PosterBoardLocation(container: candidate,
                                               structureVersion: version)
                }
            }
            if scanned >= 400 { break }
        }

        throw PosterBoardError(message: "PosterBoard's container was not found. Open PosterBoard "
            + "once, then tap Rescan container.")
    }

    /// Escape into `container` and read the numeric `PRBPosterExtensionDataStore`
    /// directories. The highest one is the newest layout; `61` is only the
    /// fallback when the store has no version directory at all.
    private static func storeVersion(of container: String) -> Int? {
        let (handle, link) = BQ.escape(container)
        guard handle >= 0 else { return nil }
        defer { BQ.endEscape(handle) }

        let base = link ?? container
        let store = base + "/Library/Application Support/" + storeDirectoryName
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: store, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        let versions = ((try? fm.contentsOfDirectory(atPath: store)) ?? [])
            .compactMap(Int.init)
        // The structure version is Apple's layout generation. Without the
        // device database to read it from, the highest numeric directory is the
        // newest (and therefore active) one. 61 is the oldest layout and only
        // used when the store itself is empty.
        return versions.max() ?? fallbackStructureVersion
    }

    /// All numeric store layouts, newest first. The highest number is not
    /// necessarily the layout the providers live in: a device can carry an
    /// empty newer version alongside the version PosterBoard actually uses.
    private static func storeVersions(of container: String) -> [Int] {
        let (handle, link) = BQ.escape(container)
        guard handle >= 0 else { return [] }
        defer { BQ.endEscape(handle) }

        let base = link ?? container
        let store = base + "/Library/Application Support/" + storeDirectoryName
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: store, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }

        return ((try? fm.contentsOfDirectory(atPath: store)) ?? [])
            .compactMap(Int.init)
            .sorted(by: >)
    }

    /// Pick the store version that already has a folder for `provider`, and
    /// return its `descriptors` path. Inventing a provider folder produces an
    /// unregistered folder that PosterBoard renders as an empty 9:41 wallpaper,
    /// so only the `descriptors` child may be created here.
    private static func resolvedDescriptorDirectory(container: String,
                                                     provider: String)
        throws -> (path: String, version: Int) {
        let versions = storeVersions(of: container)
        let (handle, link) = BQ.escape(container)
        guard handle >= 0 else {
            throw PosterBoardError(message: "Could not escape to the PosterBoard container: "
                + "\(BQ.escapeError(handle) ?? "unknown error").")
        }
        defer { BQ.endEscape(handle) }
        let base = link ?? container
        let fm = FileManager.default

        for version in versions {
            let providerPath = (base as NSString).appendingPathComponent(
                "Library/Application Support/\(storeDirectoryName)/\(version)"
                + "/Extensions/\(provider)"
            )
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: providerPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            return (descriptorDirectory(container: container,
                                        version: version,
                                        provider: provider),
                    version)
        }

        throw PosterBoardError(message: "PosterBoard has no \(provider) folder in its store. "
            + "Open PosterBoard once and create a wallpaper with that provider, then try again.")
    }

    // MARK: Applying a pack

    static func apply(pack: PosterBoardPack,
                      progress: @escaping @Sendable (String) -> Void = { _ in })
        throws -> PosterBoardApplyResult {
        guard BQ.coreInit() else {
            throw PosterBoardError(message: "The sandbox escape engine did not initialise.")
        }

        let location = try locate(progress: progress)
        let fm = FileManager.default
        // A previous run that was killed leaves its unpack behind; the work
        // root exists only for the duration of an apply.
        try? fm.removeItem(at: workDirectory)
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let work = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        progress("Extracting \(pack.name)…")
        _ = try PosterBoardZip.extract(at: pack.url, to: work)

        let sources = discoverDescriptors(in: work,
                                          defaultProvider: pack.provider.extensionID)
        guard !sources.isEmpty else {
            throw PosterBoardError(message: "No PosterBoard descriptors were found in \(pack.name).")
        }
        guard sources.count <= PosterBoardImports.descriptorLimit else {
            throw PosterBoardError(message: "\(pack.name) carries \(sources.count) descriptors; "
                + "PosterBoard's picker is limited to \(PosterBoardImports.descriptorLimit). "
                + "Split the pack or remove some descriptors first.")
        }

        var installed: [(target: String, name: String)] = []
        let previousRecords = recordedDescriptors()
        var records = previousRecords
        do {
            for (index, source) in sources.enumerated() {
                progress("Installing \(index + 1) of \(sources.count)…")

                // Keep the provider the pack actually names. Re-routing legacy
                // Collections descriptors to the modern bundle makes the store
                // look in a provider folder it does not own; gallery
                // descriptors belong under
                // com.apple.WallpaperKit.CollectionsPoster.
                let provider = source.provider
                let mercury = provider == mercuryExtension
                let (target, version) = try resolvedDescriptorDirectory(
                    container: location.container,
                    provider: provider
                )
                try ensureDirectory(container: location.container, target: target)

                // MercuryPoster looks its wallpapers up by the textual name in
                // the descriptor folder. Renaming it to a UUID produces a blank
                // wallpaper with the stock 9:41 clock, so leave it alone.
                let name = mercury ? source.url.lastPathComponent : UUID().uuidString.uppercased()
                let identifier = Int.random(in: identifierRange)

                let (handle, link) = BQ.escape(target)
                guard handle >= 0 else {
                    throw PosterBoardError(message: "Could not escape to \(provider) "
                        + "descriptors: \(BQ.escapeError(handle) ?? "unknown error").")
                }

                let base = link ?? target
                let destination = URL(fileURLWithPath: base).appendingPathComponent(name)
                do {
                    try copyDescriptor(from: source.url, to: destination)
                    if !mercury {
                        try rewriteDescriptor(at: destination, identifier: identifier)
                    }
                } catch {
                    try? fm.removeItem(at: destination)
                    BQ.endEscape(handle)
                    throw error
                }
                BQ.endEscape(handle)

                installed.append((target: target, name: name))
                // Record as each descriptor lands: if the app is killed before
                // the run finishes, the next Reset still knows what to remove.
                records.append(InstalledDescriptor(provider: provider, name: name, version: version))
                saveRecordedDescriptors(records)
            }
        } catch {
            progress("Rolling back…")
            for item in installed.reversed() {
                removeInstalled(target: item.target, name: item.name)
            }
            saveRecordedDescriptors(previousRecords)
            throw error
        }

        progress("Installed \(installed.count) wallpaper(s).")
        BQ.log("PosterBoard: installed \(installed.count) descriptor(s) from \(pack.name)")
        return PosterBoardApplyResult(count: installed.count, location: location)
    }

    // MARK: Resetting

    /// Remove only the descriptor folders this app installed. Other provider
    /// folders — including the device's own wallpapers — are left untouched.
    static func reset(progress: @escaping @Sendable (String) -> Void = { _ in })
        throws -> PosterBoardResetResult {
        guard BQ.coreInit() else {
            throw PosterBoardError(message: "The sandbox escape engine did not initialise.")
        }

        let location = try locate(progress: progress)
        let records = recordedDescriptors()
        guard !records.isEmpty else {
            return PosterBoardResetResult(removed: 0, failed: 0, location: location)
        }

        let fm = FileManager.default
        let (handle, link) = BQ.escape(location.container)
        guard handle >= 0 else {
            throw PosterBoardError(message: "Could not escape to the PosterBoard container: "
                + "\(BQ.escapeError(handle) ?? "unknown error").")
        }
        defer { BQ.endEscape(handle) }
        let base = link ?? location.container

        var removed = 0
        var remaining: [InstalledDescriptor] = []
        // The provider folder can live under an older structure version than
        // the one reported by locate(), so remember the version each install
        // actually used instead of assuming the newest one.
        let grouped = Dictionary(grouping: records) {
            ResetGroup(provider: $0.provider,
                       version: $0.version ?? location.structureVersion)
        }
        for (group, entries) in grouped.sorted(by: {
            $0.key.provider < $1.key.provider
                || ($0.key.provider == $1.key.provider && $0.key.version > $1.key.version)
        }) {
            progress("Clearing \(group.provider)…")
            let directory = (base as NSString).appendingPathComponent(
                "Library/Application Support/\(storeDirectoryName)/\(group.version)"
                + "/Extensions/\(group.provider)/descriptors"
            )
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            for entry in entries {
                let path = (directory as NSString).appendingPathComponent(entry.name)
                guard fm.fileExists(atPath: path) else { continue }
                do {
                    try fm.removeItem(atPath: path)
                    removed += 1
                } catch {
                    BQ.log("PosterBoard reset: could not remove \(entry.name): \(error)")
                    remaining.append(entry)
                }
            }
        }

        saveRecordedDescriptors(remaining)

        BQ.log("PosterBoard reset: removed \(removed) installed descriptor(s), "
            + "\(remaining.count) left behind")
        return PosterBoardResetResult(removed: removed,
                                      failed: remaining.count,
                                      location: location)
    }

    /// Remove every descriptor from the PosterBoard providers. This is the
    /// escape hatch for packs installed by another app (or by a run that was
    /// killed before it could record its folders), so it is deliberately
    /// separate from `reset()` and the UI asks twice.
    static func resetAll(progress: @escaping @Sendable (String) -> Void = { _ in })
        throws -> PosterBoardResetResult {
        guard BQ.coreInit() else {
            throw PosterBoardError(message: "The sandbox escape engine did not initialise.")
        }

        let location = try locate(progress: progress)
        let fm = FileManager.default
        let (handle, link) = BQ.escape(location.container)
        guard handle >= 0 else {
            throw PosterBoardError(message: "Could not escape to the PosterBoard container: "
                + "\(BQ.escapeError(handle) ?? "unknown error").")
        }
        defer { BQ.endEscape(handle) }
        let base = link ?? location.container

        var providers: Set<String> = [
            collectionsExtension,
            mercuryExtension,
            photosExtension,
            modernCollectionsExtension,
        ]
        providers.formUnion(recordedDescriptors().map(\.provider))

        var removed = 0
        var failed = 0
        // Descriptors can live in an older structure version even when the
        // store carries newer empty layouts, so "every provider" has to mean
        // every structure version, not just the newest one locate() reported.
        let versions = storeVersions(of: location.container)
        for provider in providers.sorted() {
            for version in versions.isEmpty ? [location.structureVersion] : versions {
                progress("Clearing \(provider) (version \(version))…")
                let directory = (base as NSString).appendingPathComponent(
                    "Library/Application Support/\(storeDirectoryName)/\(version)"
                    + "/Extensions/\(provider)/descriptors"
                )
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: directory, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }

                let items = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
                for item in items {
                    do {
                        try fm.removeItem(atPath: (directory as NSString).appendingPathComponent(item))
                        removed += 1
                    } catch {
                        failed += 1
                        BQ.log("PosterBoard reset: could not remove \(item): \(error)")
                    }
                }
            }
        }

        saveRecordedDescriptors([])

        BQ.log("PosterBoard reset-all: removed \(removed) descriptor(s), \(failed) left behind")
        return PosterBoardResetResult(removed: removed, failed: failed, location: location)
    }

    // MARK: Descriptor discovery

    private struct DescriptorSource {
        let url: URL
        let provider: String
    }

    private static func discoverDescriptors(in root: URL,
                                            defaultProvider: String) -> [DescriptorSource] {
        let fm = FileManager.default
        var result: [DescriptorSource] = []
        var seen = Set<String>()

        func add(_ url: URL) {
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            result.append(DescriptorSource(url: url,
                                           provider: provider(for: url) ?? defaultProvider))
        }

        func looksLikeDescriptor(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            return names.contains("versions")
                || names.contains("providerInfo.plist")
                || names.contains("com.apple.posterkit.provider.descriptor.identifier")
        }

        func walk(_ directory: URL, includingConfigurations: Bool) {
            let children = (try? fm.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                        options: [])) ?? []
            for child in children {
                let name = child.lastPathComponent
                if isJunk(name) { continue }

                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true,
                      values?.isSymbolicLink != true else { continue }

                // `configurations/` holds the wallpapers that are already set,
                // not the gallery. Installing those again duplicates whatever
                // the device currently has selected. They are only a fallback
                // for a snapshot that carries no gallery descriptors at all.
                if !includingConfigurations,
                   name.lowercased() == "configurations" {
                    continue
                }

                if posterBoardDescriptorContainerNames.contains(name.lowercased()) {
                    let candidates = (try? fm.contentsOfDirectory(at: child,
                                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [])) ?? []
                    for candidate in candidates where !isJunk(candidate.lastPathComponent) {
                        if looksLikeDescriptor(candidate) { add(candidate) }
                    }
                    // Nothing inside a descriptor tree is another descriptor.
                    continue
                }

                if looksLikeDescriptor(child) {
                    add(child)
                    continue
                }

                walk(child, includingConfigurations: includingConfigurations)
            }
        }

        // A single-descriptor pack puts `versions/` at the extraction root.
        if looksLikeDescriptor(root) {
            add(root)
        } else {
            walk(root, includingConfigurations: false)
            if result.isEmpty {
                walk(root, includingConfigurations: true)
            }
        }
        return result.sorted { $0.url.path < $1.url.path }
    }

    /// Which provider extension owns a descriptor. A container-style path names
    /// it directly under `Extensions/`; a bare pack has to be inferred from the
    /// marker folder or the descriptor's own name.
    private static func provider(for url: URL) -> String? {
        let components = url.pathComponents
        if let index = components.lastIndex(where: {
            let lower = $0.lowercased()
            return lower == "descriptors" || lower == "configurations"
        }), index > 0 {
            let candidate = components[index - 1]
            if candidate.hasPrefix("com.apple."), candidate != "com.apple.PosterBoard" {
                return candidate
            }
        }

        let lowerComponents = url.pathComponents.map { $0.lowercased() }
        if lowerComponents.contains(where: { $0.contains("mercuryposter") })
            || lowerComponents.contains("mercury") {
            return mercuryExtension
        }
        if lowerComponents.contains(where: { $0.contains("photosposterprovider") })
            || lowerComponents.contains("video-descriptor")
            || lowerComponents.contains("video-descriptors") {
            return photosExtension
        }
        if lowerComponents.contains(where: { $0.contains("collectionsposter") }) {
            return collectionsExtension
        }

        return nil
    }

    // MARK: Descriptor files

    private static func descriptorDirectory(container: String,
                                            version: Int,
                                            provider: String) -> String {
        "\(container)/Library/Application Support/\(storeDirectoryName)/\(version)/"
            + "Extensions/\(provider)/descriptors"
    }

    /// Create a provider's descriptor directory through the container escape.
    /// The descriptor-directory escape itself fails when the directory is
    /// missing, so this has to happen first.
    private static func ensureDirectory(container: String, target: String) throws {
        let (handle, link) = BQ.escape(container)
        guard handle >= 0 else {
            throw PosterBoardError(message: "Could not escape to the PosterBoard container: "
                + "\(BQ.escapeError(handle) ?? "unknown error").")
        }
        defer { BQ.endEscape(handle) }

        let base = link ?? container
        let prefix = container + "/"
        guard target.hasPrefix(prefix) else {
            throw PosterBoardError(message: "Refusing to create a descriptor directory outside "
                + "the PosterBoard container.")
        }
        let relative = String(target.dropFirst(prefix.count))
        let path = (base as NSString).appendingPathComponent(relative)

        do {
            try FileManager.default.createDirectory(atPath: path,
                                                    withIntermediateDirectories: true)
        } catch {
            throw PosterBoardError(message: "Could not create \(path): "
                + error.localizedDescription)
        }
    }

    private static func copyDescriptor(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let children = try fm.contentsOfDirectory(at: source,
                                                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                  options: [])
        for child in children {
            let name = child.lastPathComponent
            if isJunk(name) { continue }

            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }

            let target = destination.appendingPathComponent(name)
            if values.isDirectory == true {
                try copyDescriptor(from: child, to: target)
            } else {
                try fm.copyItem(at: child, to: target)
            }
        }
    }

    /// Stamp the three identity fields with the same random identifier used by
    /// the folder name. This is the gallery path: no role sidecar and no
    /// family/name rewrite. Those belong to a configuration install, and a
    /// descriptor rewritten that way but never registered in the store renders
    /// as an empty 9:41 wallpaper.
    private static func rewriteDescriptor(at root: URL, identifier: Int) throws {
        let fm = FileManager.default

        // Third-party packs usually omit the identity sidecar. PosterKit then
        // invents one that disagrees with the userInfo / Wallpaper.plist ids,
        // so stamp it with the same random id. An existing sidecar is replaced
        // too: the pack's UUID no longer matches its new directory name.
        let identifierFile = root.appendingPathComponent(
            "com.apple.posterkit.provider.descriptor.identifier"
        )
        try Data(String(identifier).utf8).write(to: identifierFile, options: .atomic)

        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [],
                                             errorHandler: { url, error in
                                                 BQ.log("PosterBoard: enumerate \(url.path) failed: \(error)")
                                                 return true
                                             }) else { return }

        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            switch file.lastPathComponent {
            case "com.apple.posterkit.provider.contents.userInfo":
                try setPlistValue(identifier,
                                  forKey: "wallpaperRepresentingIdentifier",
                                  at: file)
            case "Wallpaper.plist":
                try setPlistValue(identifier, forKey: "identifier", at: file)
            default:
                continue
            }
        }
    }

    /// Change one value without changing the plist's original format.
    /// Converting a binary descriptor plist to XML changes its bytes for no
    /// benefit and has broken providers in the past.
    private static func setPlistValue(_ value: Int, forKey key: String, at url: URL) throws {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = try PropertyListSerialization.propertyList(from: data,
                                                                    options: [],
                                                                    format: &format)
                as? [String: Any] else {
            throw PosterBoardError(message: "\(url.lastPathComponent) is a plist but not a dictionary.")
        }
        plist[key] = value
        let updated = try PropertyListSerialization.data(fromPropertyList: plist,
                                                        format: format,
                                                        options: 0)
        try updated.write(to: url, options: .atomic)
    }

    // MARK: Cleanup

    private static func removeInstalled(target: String, name: String) {
        let (handle, link) = BQ.escape(target)
        guard handle >= 0 else { return }
        defer { BQ.endEscape(handle) }
        let path = ((link ?? target) as NSString).appendingPathComponent(name)
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func isJunk(_ name: String) -> Bool {
        let lower = name.lowercased()
        return junkNames.contains(lower) || name.hasPrefix("._")
    }

    // MARK: - Opening PosterBoard

    @MainActor
    static func openPosterBoard() -> Bool {
        typealias Send0 = @convention(c) (UnsafeMutableRawPointer, Selector) -> UnsafeMutableRawPointer?
        typealias Send1 = @convention(c) (UnsafeMutableRawPointer, Selector, NSString) -> Bool

        // LSApplicationWorkspace lives in MobileCoreServices and is not loaded
        // by default in a normal app process.
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
               RTLD_NOW)

        if let cls = NSClassFromString("LSApplicationWorkspace"),
           let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") {
            let send0 = unsafeBitCast(symbol, to: Send0.self)
            let send1 = unsafeBitCast(symbol, to: Send1.self)
            let classPointer = unsafeBitCast(cls, to: UnsafeMutableRawPointer.self)
            if let workspace = send0(classPointer,
                                     NSSelectorFromString("defaultWorkspace")) {
                let opened = send1(workspace,
                                   NSSelectorFromString("openApplicationWithBundleID:"),
                                   "com.apple.PosterBoard" as NSString)
                if opened { return true }
            }
        }

        return false
    }

    // MARK: - inode → path

    private typealias FSGetPathFn = @convention(c) (UnsafeMutablePointer<CChar>?,
                                                    Int,
                                                    UnsafePointer<fsid_t>?,
                                                    UInt64) -> Int

    private static let fsgetpathFunction: FSGetPathFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fsgetpath") else {
            return nil
        }
        return unsafeBitCast(symbol, to: FSGetPathFn.self)
    }()

    /// List the direct children of `root` by walking inode numbers through
    /// `fsgetpath` (the `bad_query_list` walk from the BQ escape engine). This
    /// is the only way to see inside these roots from a sandboxed process:
    /// directory listing is denied, but `fsgetpath` maps an inode to its path
    /// without needing read access to the parent.
    private static func inodeChildren(of root: String) -> [String] {
        var status = statfs()
        guard statfs(root, &status) == 0,
              let fsgetpath = fsgetpathFunction else { return [] }

        var fileSystemID = status.f_fsid
        let normalisedRoot = root.hasPrefix("/private/var/")
            ? String(root.dropFirst("/private".count))
            : root
        var buffer = [CChar](repeating: 0, count: 2_048)
        var result: [String] = []

        for inode in 1...400_000 {
            let length = withUnsafePointer(to: &fileSystemID) { fileSystemPointer in
                buffer.withUnsafeMutableBufferPointer { bufferPointer in
                    fsgetpath(bufferPointer.baseAddress,
                              bufferPointer.count,
                              fileSystemPointer,
                              UInt64(inode))
                }
            }
            guard length > 0 else { continue }

            let path = String(cString: buffer)
            let normalised = path.hasPrefix("/private/var/")
                ? String(path.dropFirst("/private".count))
                : path
            guard normalised.hasPrefix(normalisedRoot + "/") else { continue }

            let tail = normalised.dropFirst(normalisedRoot.count + 1)
            guard !tail.contains("/") else { continue }

            result.append(normalised)
            if result.count >= 500 { break }
        }
        return result
    }
}

// MARK: - UI state

@MainActor
final class PosterBoardEngine: ObservableObject {
    @Published private(set) var packs: [PosterBoardPack] = []
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Ready."
    @Published private(set) var location: PosterBoardLocation?

    init() {
        reload()
    }

    func reload() {
        packs = PosterBoardImports.load()
    }

    func locateIfNeeded() async {
        guard location == nil, !isBusy else { return }
        await performLocate(force: false, alertOnFailure: false)
    }

    func locate(force: Bool) async {
        await performLocate(force: force, alertOnFailure: true)
    }

    private func performLocate(force: Bool, alertOnFailure: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        status = "Looking for PosterBoard…"
        defer { isBusy = false }

        do {
            let found = try await Task.detached(priority: .userInitiated) {
                try PosterBoardInstaller.locate(force: force) { line in
                    UILogger.log("PosterBoard: \(line)")
                }
            }.value
            location = found
            status = "PosterBoard store: version \(found.structureVersion)."
        } catch {
            status = error.localizedDescription
            if alertOnFailure {
                AlertCenter.show(error.localizedDescription)
            }
        }
    }

    func importPack(from url: URL) async {
        guard !isBusy else { return }
        isBusy = true
        status = "Importing \(url.lastPathComponent)…"
        defer { isBusy = false }

        do {
            let pack = try await Task.detached(priority: .userInitiated) {
                try PosterBoardImports.importPack(from: url)
            }.value
            reload()
            status = "Imported \(pack.name) — \(pack.summary)."
        } catch {
            status = error.localizedDescription
            AlertCenter.show(error.localizedDescription)
        }
    }

    func apply(_ pack: PosterBoardPack) async {
        guard !isBusy else { return }
        isBusy = true
        status = "Applying \(pack.name)…"
        defer { isBusy = false }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try PosterBoardInstaller.apply(pack: pack) { line in
                    UILogger.log("PosterBoard: \(line)")
                }
            }.value
            location = result.location
            status = "Installed \(result.count) wallpaper(s). Respring or open PosterBoard to see them."
            UILogger.log("PosterBoard: \(status)")
        } catch {
            status = error.localizedDescription
            UILogger.log("PosterBoard: \(error.localizedDescription)")
            AlertCenter.show(error.localizedDescription)
        }
    }

    func reset() async {
        guard !isBusy else { return }
        isBusy = true
        status = "Clearing installed wallpapers…"
        defer { isBusy = false }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try PosterBoardInstaller.reset() { line in
                    UILogger.log("PosterBoard: \(line)")
                }
            }.value
            location = result.location
            status = result.removed == 0
                ? "No wallpapers installed by WorstGestalt to remove."
                : "Removed \(result.removed) descriptor folder(s)"
                    + (result.failed > 0 ? "; \(result.failed) could not be removed." : ".")
                    + " Respring to refresh PosterBoard."
            UILogger.log("PosterBoard: \(status)")
        } catch {
            status = error.localizedDescription
            UILogger.log("PosterBoard: \(error.localizedDescription)")
            AlertCenter.show(error.localizedDescription)
        }
    }

    func resetAll() async {
        guard !isBusy else { return }
        isBusy = true
        status = "Clearing every provider folder…"
        defer { isBusy = false }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try PosterBoardInstaller.resetAll() { line in
                    UILogger.log("PosterBoard: \(line)")
                }
            }.value
            location = result.location
            status = "Removed \(result.removed) descriptor folder(s) from every provider"
                + (result.failed > 0 ? "; \(result.failed) could not be removed." : ".")
                + " Respring to refresh PosterBoard."
            UILogger.log("PosterBoard: \(status)")
        } catch {
            status = error.localizedDescription
            UILogger.log("PosterBoard: \(error.localizedDescription)")
            AlertCenter.show(error.localizedDescription)
        }
    }

    func remove(_ pack: PosterBoardPack) {
        PosterBoardImports.remove(pack)
        reload()
        status = "Removed \(pack.name)."
    }

    func setProvider(_ provider: PosterBoardProvider, for pack: PosterBoardPack) {
        PosterBoardPackPreferences.setProvider(provider, for: pack.name)
        reload()
        status = "\(pack.name) will use \(provider.label) for descriptors without a provider path."
    }

    func openPosterBoard() {
        if PosterBoardInstaller.openPosterBoard() {
            status = "Opening PosterBoard…"
        } else {
            status = "Could not open PosterBoard; open it from the Home Screen."
        }
    }

    func respring() {
        if !NeoSpring.trigger() {
            RespringAsset.materialize()
            BQ.respring()
        }
    }
}
