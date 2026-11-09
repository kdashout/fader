import AudioToolbox
import CoreAudio
import Foundation
import os

extension ProcessTap {
    /// `suspendIdleTaps` (default on) parks a tap's IO after 30 s of silence.
    /// Off keeps every tap running — a little CPU while idle, in exchange for
    /// no suspend/resume switch in front of the app's next sound.
    static var suspendsWhenIdle: Bool {
        UserDefaults.standard.object(forKey: "suspendIdleTaps") as? Bool ?? true
    }

    /// Park long-idle IO without letting the process escape at full volume.
    /// `.muted` keeps native output silent while the aggregate is stopped; one
    /// shared lightweight watcher resumes IO as soon as the process runs again.
    @MainActor
    func updatePlaybackState(isPlaying: Bool) {
        guard isPlaying != isProcessPlaying else { return }
        isProcessPlaying = isPlaying
        idleTask?.cancel()
        idleTask = nil

        if isPlaying {
            if isSuspended { resumeIO() }
            return
        }
        guard Self.suspendsWhenIdle else { return }

        idleTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(30), tolerance: .seconds(2))
            } catch {
                return
            }
            guard let self, !isProcessPlaying else { return }
            idleTask = nil
            suspendIO()
        }
    }

    /// Safe to call away from the main actor. Core Audio property reads are
    /// synchronous IPC and can take milliseconds even though they use no CPU.
    nonisolated var hasRunningOutput: Bool {
        processObjectIDs.contains(where: { $0.readProcessIsRunningOutput() })
    }

    @MainActor
    func resumeAfterOutputStarted() {
        guard isSuspended else { return }
        isProcessPlaying = true
        resumeIO()
    }

    @MainActor
    func stopIdleLifecycle() {
        idleTask?.cancel()
        idleTask = nil
        if isSuspended { ProcessTapWakeMonitor.shared.unwatch(self) }
        isSuspended = false
    }

    @MainActor
    private func suspendIO() {
        guard !isSuspended, aggregateID.isValid, let procID else { return }
        do {
            try setTapMuteBehavior(.muted)
            do {
                try checked(AudioDeviceStop(aggregateID, procID), "suspend aggregate device")
            } catch {
                try? setTapMuteBehavior(.mutedWhenTapped)
                throw error
            }
            isSuspended = true
            ProcessTapWakeMonitor.shared.watch(self)
            tapLifecycleLogger.notice("Suspended idle tap for \(self.label, privacy: .public)")
        } catch {
            tapLifecycleLogger.error("Failed to suspend idle tap for \(self.label, privacy: .public): \(error.localizedDescription)")
        }
    }

    @MainActor
    private func resumeIO() {
        guard isSuspended, aggregateID.isValid, let procID else { return }
        idleTask?.cancel()
        idleTask = nil
        do {
            try checked(AudioDeviceStart(aggregateID, procID), "resume aggregate device")
            isSuspended = false
            ProcessTapWakeMonitor.shared.unwatch(self)
            do {
                try setTapMuteBehavior(.mutedWhenTapped)
            } catch {
                // `.muted` plus a running reader still produces correct output;
                // keep audio alive and report the HAL problem for diagnostics.
                Self.logger.error("Failed to restore tap mute behavior: \(error.localizedDescription)")
            }
            tapLifecycleLogger.notice("Resumed tap for \(self.label, privacy: .public)")
            onOutputResumed?()
        } catch {
            tapLifecycleLogger.error("Failed to resume tap for \(self.label, privacy: .public): \(error.localizedDescription)")
            // Destroying the tap would restore native audio at full volume;
            // stay silent and let MixerEngine build a replacement.
            holdSilent()
            onBroken?()
        }
    }

    @MainActor
    func holdSilent() {
        tapLifecycleLogger.notice("Holding tap for \(self.label, privacy: .public) silent")
        isHeld = true
        stopIdleLifecycle()
        do {
            try setTapMuteBehavior(.muted)
        } catch {
            Self.logger.error("Failed to hold tap silent: \(error.localizedDescription)")
        }
        if aggregateID.isValid, let procID {
            AudioDeviceStop(aggregateID, procID)
        }
    }

    @MainActor
    private func setTapMuteBehavior(_ behavior: CATapMuteBehavior) throws {
        guard tapID.isValid, let tapDescription else { return }
        let previous = tapDescription.muteBehavior
        tapDescription.muteBehavior = behavior
        do {
            try tapID.writeObjectReference(kAudioTapPropertyDescription, value: tapDescription)
        } catch {
            tapDescription.muteBehavior = previous
            throw error
        }
    }
}
