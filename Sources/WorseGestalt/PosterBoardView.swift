//
//  PosterBoardView.swift
//  worsegestalt
//
//  Import, apply and reset `.tendies` wallpapers. The engine lives in
//  PosterBoardEngine.swift; this file is only the page.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UniformTypeIdentifiers

struct PosterBoardView: View {
    @StateObject private var engine = PosterBoardEngine()
    @State private var isImporting = false
    @State private var pendingDelete: PosterBoardPack?
    @State private var confirmReset = false
    @State private var confirmResetAll = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                importSection
                packsSection
                deviceSection
                notesSection
            }
            .navigationTitle("PosterBoard")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if engine.isBusy { ProgressView() }
                }
            }
            .fileImporter(isPresented: $isImporting,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    Task {
                        for url in urls {
                            await engine.importPack(from: url)
                        }
                    }
                case .failure(let error):
                    AlertCenter.show("Import failed: \(error.localizedDescription)")
                }
            }
            .task {
                await engine.locateIfNeeded()
            }
            .confirmationDialog("Reset installed wallpapers?",
                                isPresented: $confirmReset,
                                titleVisibility: .visible) {
                Button("Remove wallpapers installed by WorstGestalt", role: .destructive) {
                    Task { await engine.reset() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes only the descriptor folders this app installed. The store "
                    + "database, your own wallpapers and the wallpaper you currently have "
                    + "selected are left alone.")
            }
            .confirmationDialog("Clear every provider folder?",
                                isPresented: $confirmResetAll,
                                titleVisibility: .visible) {
                Button("Remove every provider folder", role: .destructive) {
                    Task { await engine.resetAll() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This also removes wallpapers installed by other apps and the device's "
                    + "own gallery descriptors. Use it only to recover from a pack that did "
                    + "not install cleanly.")
            }
            .alert("Remove pack?",
                   isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                   )) {
                Button("Remove", role: .destructive) {
                    if let pack = pendingDelete {
                        engine.remove(pack)
                    }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDelete = nil
                }
            } message: {
                Text(pendingDelete?.name ?? "")
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section("Status") {
            HStack(alignment: .top, spacing: 8) {
                if engine.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(engine.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let location = engine.location {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Structure version \(location.structureVersion)",
                          systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(location.storePath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            } else {
                Button {
                    Task { await engine.locate(force: true) }
                } label: {
                    Label("Locate PosterBoard", systemImage: "magnifyingglass")
                }
                .disabled(engine.isBusy)
            }
        }
    }

    private var importSection: some View {
        Section("Wallpaper packs") {
            Button {
                isImporting = true
            } label: {
                Label("Import .tendies", systemImage: "square.and.arrow.down")
            }
            .disabled(engine.isBusy)

            Text("Descriptor packs and container snapshots are supported. A container is "
                + "installed as its descriptor folders — the stale database and preference "
                + "files inside it are not copied.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var packsSection: some View {
        Section("Imported") {
            if engine.packs.isEmpty {
                Text("No packs imported yet.")
                    .foregroundStyle(.secondary)
            }

            ForEach(engine.packs) { pack in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.name)
                                .font(.headline)
                            Text(pack.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Apply") {
                            Task { await engine.apply(pack) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(engine.isBusy)
                    }

                    if pack.isContainer {
                        Label("Container snapshot — only descriptors are installed",
                              systemImage: "shippingbox")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else {
                        HStack {
                            Text("Provider")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("Provider", selection: Binding(
                                get: { pack.provider },
                                set: { engine.setProvider($0, for: pack) }
                            )) {
                                ForEach(PosterBoardProvider.allCases) { provider in
                                    Text(provider.label).tag(provider)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .disabled(engine.isBusy)
                        }
                    }
                    if pack.descriptorCount > PosterBoardImports.descriptorLimit {
                        Label("More than \(PosterBoardImports.descriptorLimit) descriptors; "
                                + "the pack will be refused.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
                .swipeActions(edge: .leading) {
                    Button {
                        Task { await engine.apply(pack) }
                    } label: {
                        Label("Apply", systemImage: "checkmark.circle")
                    }
                    .tint(.green)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = pack
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var deviceSection: some View {
        Section("Device") {
            Button {
                engine.openPosterBoard()
            } label: {
                Label("Open PosterBoard", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(engine.isBusy)

            Button {
                engine.respring()
            } label: {
                Label("Respring", systemImage: "arrow.clockwise")
            }

            Button {
                Task { await engine.locate(force: true) }
            } label: {
                Label("Rescan container", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(engine.isBusy)

            Button(role: .destructive) {
                confirmReset = true
            } label: {
                Label("Reset installed wallpapers", systemImage: "trash")
            }
            .disabled(engine.isBusy)

            Button(role: .destructive) {
                confirmResetAll = true
            } label: {
                Label("Clear every provider folder…", systemImage: "trash.slash")
            }
            .disabled(engine.isBusy)
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            Text("Each descriptor is copied under a fresh UUID and its identifier fields are "
                + "rewritten so PosterBoard can resolve it. A pack may carry at most "
                + "\(PosterBoardImports.descriptorLimit) descriptors.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("A bare descriptor pack does not name its provider; use the Provider menu on "
                + "the pack. Container snapshots use the extension already in their path.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Legacy `.wallpaper` bundle packs are not converted. Import a pack that already "
                + "contains descriptor folders (`descriptors/…` or a `versions/` tree).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Reset removes only the folders this app installed. Use “Clear every provider "
                + "folder” only to recover from another app's pack or an interrupted install.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("The store's SQLite database is not stitched from a backup. If a wallpaper "
                + "does not appear after a respring, reset the installed wallpapers and try a "
                + "descriptor-only pack.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
