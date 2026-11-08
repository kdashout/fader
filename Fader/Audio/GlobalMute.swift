import CoreAudio
import Foundation
import os

/// Silences every app at once for as long as something holds it — push-to-talk
/// dictation, so the mic does not pick up the speakers — without switching the
/// output device.
///
/// Flipping a tap's mute behavior would cut the sound off with a click, so the
/// hold instead routes all audio through Fader and fades it out: one global
/// ProcessTap starts at unity (indistinguishable from native output) and ramps
/// to silence over the same 30 ms curve as a volume change. On release it ramps
/// back to unity and is torn down, which hands the apps back their native
/// output at the level they were already playing.
///
/// Two kinds of process stay out of the global tap: Fader itself, whose
/// re-rendered output would otherwise feed back into the tap, and apps that
/// already have a per-app tap, which would otherwise play twice. MixerEngine
/// ducks those per-app taps alongside.
@MainActor
final class GlobalMute {
    static let logger = Logger(subsystem: "dev.pantafive.fader", category: "GlobalMute")

    private var tap: ProcessTap?
    private var releaseTask: Task<Void, Never>?
    private(set) var isMuted = false

    func setMuted(_ muted: Bool, outputs: [ProcessTap.Output], excluding perAppProcesses: [AudioObjectID]) {
        guard muted != isMuted else { return }
        isMuted = muted
        muted ? fadeOut(outputs: outputs, excluding: perAppProcesses) : fadeIn()
    }

    func invalidate() {
        releaseTask?.cancel()
        releaseTask = nil
        tap?.invalidate()
        tap = nil
        isMuted = false
    }

    private func fadeOut(outputs: [ProcessTap.Output], excluding perAppProcesses: [AudioObjectID]) {
        releaseTask?.cancel()
        releaseTask = nil
        // Pressed again while the last release was still fading in: turn it around.
        if let tap {
            tap.isDucked = true
            return
        }
        guard let ownProcess = Self.ownProcessObjectID() else {
            // Without excluding ourselves the tap would capture its own output.
            Self.logger.error("Could not find Fader's own audio process; not muting")
            return
        }
        let tap = ProcessTap(allProcessesExcluding: [ownProcess] + perAppProcesses)
        do {
            try tap.activate(outputs: outputs)
        } catch {
            Self.logger.error("Failed to mute all apps: \(error.localizedDescription)")
            tap.invalidate()
            return
        }
        tap.isDucked = true
        self.tap = tap
        Self.logger.notice("All apps fading out")
    }

    private func fadeIn() {
        guard let tap else { return }
        tap.isDucked = false
        Self.logger.notice("All apps fading in")
        releaseTask = Task { @MainActor [weak self] in
            // ~5× the 30 ms gain ramp, as when a per-app tap is retired.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.tap === tap else { return }
            tap.invalidate()
            self.tap = nil
            releaseTask = nil
        }
    }

    private static func ownProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var object = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            .system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object.isValid ? object : nil
    }
}
