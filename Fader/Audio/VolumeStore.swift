import Foundation

/// Per-app volume settings persisted across launches, keyed by bundle identifier.
struct AppVolume: Codable, Equatable {
    var volume: Float = 1.0
    var isMuted: Bool = false
    /// UIDs of the output devices this app is pinned to, clock first; empty to
    /// follow the system default. A pinned app always needs a tap (the tap IS
    /// the route), so a non-empty list is never neutral even at unity gain.
    var outputDeviceUIDs: [String] = []
    /// The user chose to play this app through Fader. Only these apps get a
    /// tap, and they keep it at any volume — 100% included — so the app never
    /// switches between its native path and Fader's while it runs. Off (the
    /// default) leaves the app's audio untouched; its slider does nothing.
    var throughFader: Bool = false

    /// Bypassed at unity gain, unmuted, and following the default output —
    /// nothing worth saving.
    var isNeutral: Bool { !throughFader && volume == 1.0 && !isMuted && outputDeviceUIDs.isEmpty }

    init(volume: Float = 1.0, isMuted: Bool = false, outputDeviceUIDs: [String] = [], throughFader: Bool = false) {
        self.volume = volume
        self.isMuted = isMuted
        self.outputDeviceUIDs = outputDeviceUIDs
        self.throughFader = throughFader
    }

    private enum CodingKeys: String, CodingKey {
        case volume, isMuted, outputDeviceUIDs, outputDeviceUID, throughFader
    }

    /// Tolerates the pre-multi-route blob, which stored a single
    /// `outputDeviceUID` — without this the whole dictionary would fail to
    /// decode and every saved volume would be lost on upgrade.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        if let list = try container.decodeIfPresent([String].self, forKey: .outputDeviceUIDs) {
            outputDeviceUIDs = list
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID) {
            outputDeviceUIDs = [legacy]
        } else {
            outputDeviceUIDs = []
        }
        // Before the choice existed only adjusted apps were saved, and every
        // one of them was tapped — keep them on Fader.
        throughFader = try container.decodeIfPresent(Bool.self, forKey: .throughFader) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(volume, forKey: .volume)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(outputDeviceUIDs, forKey: .outputDeviceUIDs)
        try container.encode(throughFader, forKey: .throughFader)
    }
}

/// Persists app volumes as a single JSON blob in UserDefaults.
struct VolumeStore {
    private static let key = "appVolumes"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String: AppVolume] {
        defaults.loadJSON([String: AppVolume].self, forKey: Self.key) ?? [:]
    }

    func save(_ volumes: [String: AppVolume]) {
        // Neutral entries carry no information — drop them to keep the blob minimal.
        defaults.saveJSON(volumes.filter { !$0.value.isNeutral }, forKey: Self.key)
    }
}
