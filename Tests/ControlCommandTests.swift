import Foundation
import Testing

@Suite("fader:// control commands")
struct ControlCommandTests {
    private func command(_ string: String) -> ControlCommand? {
        URL(string: string).flatMap(ControlCommand.init(url:))
    }

    @Test("volume nudges, sets, and mute toggles parse")
    func parsesCommands() {
        #expect(command("fader://volume?app=com.apple.Safari&by=0.02")
            == .adjustVolume(bundleID: "com.apple.Safari", by: 0.02))
        #expect(command("fader://volume?app=com.apple.Safari&by=-0.02")
            == .adjustVolume(bundleID: "com.apple.Safari", by: -0.02))
        #expect(command("fader://volume?app=com.apple.Safari&to=0.5")
            == .setVolume(bundleID: "com.apple.Safari", to: 0.5))
        #expect(command("fader://mute?app=com.apple.Safari") == .toggleMute(bundleID: "com.apple.Safari"))
    }

    @Test("mute-all takes an explicit on or off and no app")
    func parsesMuteAll() {
        #expect(command("fader://mute-all?on=1") == .muteAll(true))
        #expect(command("fader://mute-all?on=true") == .muteAll(true))
        #expect(command("fader://mute-all?on=0") == .muteAll(false))
        #expect(command("fader://mute-all?on=false") == .muteAll(false))
        #expect(command("fader://mute-all") == nil)
        #expect(command("fader://mute-all?on=maybe") == nil)
    }

    @Test("missing app, missing value, unknown action, or other scheme are ignored")
    func rejectsMalformed() {
        #expect(command("fader://volume?by=0.02") == nil)
        #expect(command("fader://volume?app=&by=0.02") == nil)
        #expect(command("fader://volume?app=com.apple.Safari") == nil)
        #expect(command("fader://volume?app=com.apple.Safari&by=loud") == nil)
        #expect(command("fader://volume?app=com.apple.Safari&by=nan") == nil)
        #expect(command("fader://solo?app=com.apple.Safari") == nil)
        #expect(command("https://volume?app=com.apple.Safari&by=0.02") == nil)
    }

    @Test("a run of nudges lands exactly on unity so the tap is released")
    func nudgesReachUnity() {
        var position: Float = 0.5
        for _ in 0 ..< 25 {
            position = ControlCommand.nudged(position, by: 0.02)
        }
        #expect(position == 1.0)
    }

    @Test("nudges clamp to the slider range")
    func nudgesClamp() {
        #expect(ControlCommand.nudged(0.99, by: 0.05) == 1.0)
        #expect(ControlCommand.nudged(0.01, by: -0.05) == 0)
    }
}
