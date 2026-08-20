//
//  Manifests.swift
//  TmuxAgentWatch
//
//  Bundled agent-detection manifests, converted from herdr's TOMLs
//  (Apache-2.0; see NOTICE) by scripts/convert-manifests.py. Keyed by the
//  manifest `id` field, which is the canonical agent label.
//

import Foundation

nonisolated enum Manifests {
    /// Compiled manifest for a manifest id. `nil` when the manifest is
    /// missing or failed to compile at startup; the agent then falls back to
    /// known-agent-Idle.
    static func get(_ manifestID: String) -> CompiledManifest? {
        compiled[manifestID]
    }

    static let compiled: [String: CompiledManifest] = {
        var map: [String: CompiledManifest] = [:]
        for manifest in loadBundled() {
            do {
                map[manifest.id] = try compileManifest(manifest)
            } catch {
                NSLog("warning: bundled manifest %@ failed to compile: %@", manifest.id, "\(error)")
            }
        }
        return map
    }()

    static func loadBundled() -> [ManifestJSON] {
        guard let url = Bundle.main.url(forResource: "manifests", withExtension: "json")
            ?? bundleForTests()?.url(forResource: "manifests", withExtension: "json")
        else {
            NSLog("warning: manifests.json missing from bundle")
            return []
        }
        do {
            return try JSONDecoder().decode([ManifestJSON].self, from: Data(contentsOf: url))
        } catch {
            NSLog("warning: manifests.json failed to decode: %@", "\(error)")
            return []
        }
    }

    /// Unit tests run inside the host app but resolve resources through the
    /// app bundle already; this hook exists for non-hosted contexts.
    private static func bundleForTests() -> Bundle? {
        Bundle.allBundles.first { $0.url(forResource: "manifests", withExtension: "json") != nil }
    }
}
