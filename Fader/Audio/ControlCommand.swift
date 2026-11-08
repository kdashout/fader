import Foundation

/// A per-app volume command arriving through the `fader://` URL scheme, so a
/// keyboard knob or a script can drive an app's fader without the popover:
///
///     fader://volume?app=com.apple.Safari&by=0.02   nudge by a slider step
///     fader://volume?app=com.apple.Safari&to=0.5    set the slider position
///     fader://mute?app=com.apple.Safari             toggle mute
///     fader://mute-all?on=1                         silence every app (0 restores)
///
/// Values are slider positions (0...1), the same scale the UI shows, not
/// gains. Kept pure and free of HAL imports so it unit-tests in the hostless
/// bundle.
enum ControlCommand: Equatable {
    case adjustVolume(bundleID: String, by: Float)
    case setVolume(bundleID: String, to: Float)
    case toggleMute(bundleID: String)
    case muteAll(Bool)

    static let scheme = "fader"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        if url.host?.lowercased() == "mute-all" {
            switch components.value(for: "on")?.lowercased() {
            case "1", "true": self = .muteAll(true)
            case "0", "false": self = .muteAll(false)
            default: return nil
            }
            return
        }

        guard let bundleID = components.value(for: "app"), !bundleID.isEmpty else { return nil }

        switch url.host?.lowercased() {
        case "volume":
            if let delta = components.value(for: "by").flatMap(Float.init), delta.isFinite {
                self = .adjustVolume(bundleID: bundleID, by: delta)
            } else if let position = components.value(for: "to").flatMap(Float.init), position.isFinite {
                self = .setVolume(bundleID: bundleID, to: position)
            } else {
                return nil
            }
        case "mute":
            self = .toggleMute(bundleID: bundleID)
        default:
            return nil
        }
    }

    /// The slider position a nudge lands on, snapped to whole percent so a run
    /// of steps reaches exactly 1.0: at unity the app's tap is released and its
    /// audio plays untouched, which 0.99999 from float drift would never do.
    static func nudged(_ position: Float, by delta: Float) -> Float {
        let snapped = ((position + delta) * 100).rounded() / 100
        return max(0, min(1, snapped))
    }
}

private extension URLComponents {
    func value(for name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}
