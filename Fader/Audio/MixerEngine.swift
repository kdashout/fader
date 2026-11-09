import CoreAudio
import Foundation
import Observation
import os

/// The heart of Fader: binds the process list to per-app volume state and
/// owns one ProcessTap per app played through Fader. Bypassed apps (the
/// default) stay untouched — no tap, no processing, bit-perfect native
/// playback. The choice is the user's, per app, and doesn't follow the
/// slider: a tapped app keeps its tap at 100%, so it never flips between
/// paths while it plays.
@MainActor
@Observable
final class MixerEngine {
    private static let logger = Logger(subsystem: "dev.pantafive.fader", category: "MixerEngine")

    let processMonitor = AudioProcessMonitor()
    let systemVolume = SystemVolumeController()
    let deviceMonitor = AudioDeviceMonitor()
    let inputVolume = SystemVolumeController(direction: .input)
    let inputDeviceMonitor = AudioDeviceMonitor(direction: .input)
    let bluetooth = BluetoothAudioMonitor()
    let multiOutput = MultiOutputController()

    /// Set when tap creation fails with a permission-shaped error.
    private(set) var needsAudioCapturePermission = false

    /// False until the first successful HAL contact; the UI shows a waiting
    /// state while the audio system is unreachable.
    private(set) var isStarted = false

    private(set) var volumes: [String: AppVolume] = [:] {
        didSet {
            // Apps played through Fader are listed as soon as they have an
            // audio process, so their tap is up before their first sound.
            processMonitor.pinnedBundleIDs = Set(volumes.filter(\.value.throughFader).keys)
        }
    }

    @ObservationIgnored var taps: [String: ProcessTap] = [:]
    /// One volume control per pinned-and-present device, keyed by UID — each
    /// routed output gets its own slider, like multi-output members.
    @ObservationIgnored private var routeVolumes: [String: DeviceVolumeController] = [:]
    @ObservationIgnored private let store = VolumeStore()
    @ObservationIgnored private let globalMute = GlobalMute()
    /// True while a `fader://mute-all` hold is in effect; new per-app taps start ducked.
    var isAllMuted: Bool { globalMute.isMuted }
    @ObservationIgnored private var deviceListener: HALListener?
    @ObservationIgnored private var serviceRestartListener: HALListener?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var rebuildPending: Set<String> = []
    @ObservationIgnored var tapFailures = 0
    @ObservationIgnored var retryTask: Task<Void, Never>?
    @ObservationIgnored var routingTask: Task<Void, Never>?
    @ObservationIgnored var bluetoothRefreshTask: Task<Void, Never>?
    @ObservationIgnored var wakeResyncTask: Task<Void, Never>?
    @ObservationIgnored private var powerMonitor: AudioPowerMonitor?

    #if RENDER_SHOTS
        /// Render harness only: mark the engine started and publish per-app
        /// volumes plus the per-device controllers backing routed-app sliders;
        /// callers seed the child monitors directly. No HAL contact.
        func seedForRender(volumes: [String: AppVolume],
                           routeVolumes: [String: DeviceVolumeController] = [:]) {
            self.volumes = volumes
            self.routeVolumes = routeVolumes
            isStarted = true
        }
    #endif

    func start() {
        volumes = store.load()
        tapLifecycleLogger.notice("Started with saved volumes for \(self.volumes.count) apps")
        processMonitor.start()
        systemVolume.start()
        deviceMonitor.start()
        inputVolume.start()
        inputDeviceMonitor.start()
        multiOutput.start()
        bluetooth.refresh()

        installHALListeners()

        observeApps()
        observeDevices()
        powerMonitor = AudioPowerMonitor(
            onSleep: { [weak self] in self?.prepareForSleep() },
            onWake: { [weak self] in self?.recoverAfterWake() }
        )
        powerMonitor?.start()
        syncTaps()
        isStarted = true
    }

    func volume(for app: AudioApp) -> AppVolume {
        volumes[app.bundleID] ?? AppVolume()
    }

    func setVolume(_ value: Float, for app: AudioApp) {
        var entry = volumes[app.bundleID] ?? AppVolume()
        entry.volume = max(0, min(1, value))
        apply(entry, to: app)
    }

    func toggleMute(for app: AudioApp) {
        var entry = volumes[app.bundleID] ?? AppVolume()
        entry.isMuted.toggle()
        apply(entry, to: app)
    }

    /// Puts an app's audio through Fader (tapped from now on, at any volume)
    /// or back on its native path.
    func setThroughFader(_ on: Bool, for app: AudioApp) {
        var entry = volumes[app.bundleID] ?? AppVolume()
        entry.throughFader = on
        apply(entry, to: app)
    }

    /// Runs a `fader://` command. An app that is not playing right now keeps
    /// the new value, and its tap picks it up once the app makes sound.
    func perform(_ command: ControlCommand) {
        switch command {
        case let .adjustVolume(bundleID, delta):
            var entry = volumes[bundleID] ?? AppVolume()
            entry.volume = ControlCommand.nudged(entry.volume, by: delta)
            apply(entry, toBundleID: bundleID)
        case let .setVolume(bundleID, position):
            var entry = volumes[bundleID] ?? AppVolume()
            entry.volume = max(0, min(1, position))
            apply(entry, toBundleID: bundleID)
        case let .toggleMute(bundleID):
            var entry = volumes[bundleID] ?? AppVolume()
            entry.isMuted.toggle()
            apply(entry, toBundleID: bundleID)
        case let .muteAll(muted):
            for tap in taps.values {
                tap.isDucked = muted
            }
            guard let outputs = try? resolvedOutputs(for: AppVolume()) else { return }
            globalMute.setMuted(muted, outputs: outputs, excluding: taps.values.flatMap(\.processObjectIDs))
        }
    }

    private func apply(_ entry: AppVolume, toBundleID bundleID: String) {
        if let app = processMonitor.apps.first(where: { $0.bundleID == bundleID }) {
            apply(entry, to: app)
        } else {
            volumes[bundleID] = entry.isNeutral ? nil : entry
            scheduleSave()
        }
    }

    /// Adds a device to the active outputs, building the multi-output route
    /// on the first pairing.
    func pair(_ device: AudioDevice) {
        let current = deviceMonitor.devices.first { $0.id == deviceMonitor.defaultDeviceID }
        multiOutput.pair(device, currentDefault: current)
    }

    func unpair(_ device: AudioDevice) {
        multiOutput.remove(device)
    }

    /// Back to 100%, unmuted. A tapped app stays on Fader.
    func reset(_ app: AudioApp) {
        var entry = volumes[app.bundleID] ?? AppVolume()
        entry.volume = 1.0
        entry.isMuted = false
        apply(entry, to: app)
    }

    /// Smooths the volume jump when Fader exits. A tap mutes the app's native
    /// output and re-renders it attenuated, so destroying the tap restores the
    /// native output at full — an abrupt jump (and click) up from whatever
    /// level the app was held at. There is no per-app system volume to keep,
    /// so the app does return to full; ramping each tap to unity first and
    /// letting the IO proc render the ramp means the native output un-mutes at
    /// the level it is about to play, a smooth rise instead of a slam. Muted
    /// taps render silence and can't fade audibly, so they restore as-is.
    func fadeOutAndStop() {
        tapLifecycleLogger.notice("Quitting; releasing \(self.taps.count) taps to native output")
        let fading = taps.values.filter { !$0.isMuted && $0.volume < 0.999 }
        if !fading.isEmpty {
            for tap in fading {
                tap.volume = 1.0
            }
            // ~5× the 30 ms gain ramp: long enough for the rendered level to
            // reach unity before teardown un-mutes the native output. Blocking
            // is fine here — this only runs from applicationWillTerminate, and
            // the IO proc rendering the ramp lives on its own queue.
            Thread.sleep(forTimeInterval: 0.15)
        }
        for tap in taps.values {
            tap.invalidate()
        }
        taps.removeAll()
        globalMute.invalidate()
    }

    // MARK: - Private

    func discardHALBoundState() {
        tapLifecycleLogger.notice("Discarding \(self.taps.count) taps bound to the old audio service")
        for tap in taps.values {
            tap.invalidate()
        }
        taps.removeAll()
        globalMute.invalidate()
        rebuildPending.removeAll()
        routeVolumes.removeAll()
    }

    func installHALListeners() {
        // Rebuild taps when the default output device changes — each aggregate
        // is pinned to a concrete device UID.
        deviceListener = AudioObjectID.system.listen(kAudioHardwarePropertyDefaultOutputDevice) {
            Task { @MainActor [weak self] in self?.reconcileTapRouting() }
        }
        serviceRestartListener = AudioObjectID.system.listen(kAudioHardwarePropertyServiceRestarted) {
            Task { @MainActor [weak self] in self?.recoverAfterAudioServiceRestart() }
        }
    }

    private func observeApps() {
        // Re-sync taps whenever the app list changes (launch/quit).
        withObservationTracking {
            _ = processMonitor.apps
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncTaps()
                self?.observeApps()
            }
        }
    }

    private func observeDevices() {
        // A HAL device appearing or vanishing usually IS a Bluetooth event;
        // refresh the paired list so the disconnected section tracks reality.
        withObservationTracking {
            _ = deviceMonitor.devices
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshBluetoothSoon()
                self.multiOutput.handleDevicesChanged(present: self.deviceMonitor.devices)
                self.reconcileTapRouting()
                self.observeDevices()
            }
        }
    }

    /// A bypassed app's volume and mute are kept but not applied. A tapped
    /// app keeps its tap at 100% too — its audio then comes out of Fader's
    /// process, so capture that excludes the app itself (Discord screen
    /// share) picks it up; bypass the app to avoid that.
    private func apply(_ entry: AppVolume, to app: AudioApp) {
        volumes[app.bundleID] = entry.isNeutral ? nil : entry
        scheduleSave()

        if !entry.throughFader {
            releaseTap(app.bundleID, reason: "bypassed")
        } else if let tap = taps[app.bundleID] {
            tap.volume = entry.volume
            tap.isMuted = entry.isMuted
        } else {
            installTap(for: app, entry: entry)
        }
    }

    /// Slider drags call apply per pixel; coalesce the UserDefaults write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            store.save(volumes)
        }
    }

    /// Ensures every running app played through Fader has a live tap covering
    /// its current process set, and every other tap is released.
    func syncTaps() {
        let apps = AudioApp.coalescedByBundleID(processMonitor.apps)
        let running = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0) })

        for (bundleID, tap) in taps {
            guard let app = running[bundleID], let entry = volumes[bundleID], entry.throughFader else {
                releaseTap(bundleID, reason: running[bundleID] == nil ? "app left the audio process list" : "bypassed")
                continue
            }
            // A browser that spawns a new media child needs the tap rebuilt —
            // the old one keeps muting only the processes it was born with.
            if tap.processObjectIDs != app.objectIDs || rebuildPending.contains(bundleID) {
                installTap(for: app, entry: entry)
            } else {
                tap.updatePlaybackState(isPlaying: app.isPlaying)
            }
        }
        for (bundleID, entry) in volumes where entry.throughFader {
            guard taps[bundleID] == nil, let app = running[bundleID] else { continue }
            installTap(for: app, entry: entry)
        }
        syncRouteVolumes()
        logUnprotectedPlayback(apps)
    }

    /// An app played through Fader with no tap is heard at full volume — the
    /// jump itself. Logged on every sync it persists through.
    private func logUnprotectedPlayback(_ apps: [AudioApp]) {
        for app in apps where app.isPlaying {
            guard let entry = volumes[app.bundleID], entry.throughFader, taps[app.bundleID] == nil else { continue }
            tapLifecycleLogger.warning("Unprotected: \(app.bundleID, privacy: .public) plays at full volume with no tap")
        }
    }

    /// Keeps one DeviceVolumeController alive per pinned-and-present device,
    /// dropping controllers for devices no longer pinned or gone from the HAL.
    /// Rebuilt whenever routes or the device list change.
    private func syncRouteVolumes() {
        let pinned = Set(volumes.values.flatMap(\.outputDeviceUIDs))
            .filter { uid in deviceMonitor.devices.contains { $0.uid == uid } }
        for uid in routeVolumes.keys where !pinned.contains(uid) {
            routeVolumes[uid] = nil
        }
        for uid in pinned where routeVolumes[uid] == nil {
            guard let device = deviceMonitor.devices.first(where: { $0.uid == uid }) else { continue }
            routeVolumes[uid] = DeviceVolumeController(deviceID: device.id)
        }
    }

    /// Make-before-break: the replacement starts before the old tap goes, so
    /// the app is never left on its native output at full volume in between.
    private func installTap(for app: AudioApp, entry: AppVolume) {
        let bundleID = app.bundleID
        let old = taps[bundleID]
        do {
            guard let tap = try makeTap(for: app, entry: entry, replacing: old) else {
                releaseTap(bundleID, reason: "multi-output is active")
                return
            }
            taps[bundleID] = tap
            if tap.isHeld {
                rebuildPending.insert(bundleID)
                scheduleTapRetry()
            } else {
                rebuildPending.remove(bundleID)
                tapFailures = 0
                needsAudioCapturePermission = false
            }
            if let old { retire(old) }
        } catch {
            Self.logger.error("Tap failed for \(bundleID): \(error.localizedDescription)")
            if let halError = error as? HALError, halError.isPermissionDenied {
                needsAudioCapturePermission = true
                if old == nil { return }
            }
            scheduleTapRetry()
            // A tap that still renders keeps attenuating the processes it has;
            // only one that can't play anymore needs holding silent.
            guard let old else { return }
            switch TapRebuildPolicy.brokenTap(isAlive: old.isAlive, isHeld: old.isHeld) {
            case .hold:
                rebuildPending.insert(bundleID)
                old.holdSilent()
            case .keepPlaying:
                break
            }
        }
    }

    /// Rebuilds only the taps that no longer play where they should, so
    /// unrelated apps don't blip. Stale = resolved targets changed (object IDs
    /// too — devices re-publish under an old UID), aggregate died, or resolve
    /// failed; a wedged tap keeps its app muted until its replacement runs.
    func reconcileTapRouting() {
        for (bundleID, tap) in taps {
            guard let entry = volumes[bundleID] else { continue }
            let desired = try? resolvedOutputs(for: entry)
            let alive = tap.isAlive
            if let desired, desired == tap.activatedOutputs, alive { continue }
            let why = desired == nil ? "outputs unresolved" : alive ? "outputs changed" : "aggregate died"
            tapLifecycleLogger.notice("Rebuilding tap for \(bundleID, privacy: .public): \(why, privacy: .public)")
            rebuildPending.insert(bundleID)
        }
        syncTaps()
    }

    private func rebuildTap(for app: AudioApp, entry: AppVolume) {
        if !entry.throughFader {
            releaseTap(app.bundleID, reason: "bypassed")
        } else {
            installTap(for: app, entry: entry)
        }
        syncRouteVolumes()
    }
}

// MARK: - Per-app routing

extension MixerEngine {
    /// The UIDs an app is pinned to, present or not — drives the route chips.
    func routeUIDs(for app: AudioApp) -> [String] {
        volumes[app.bundleID]?.outputDeviceUIDs ?? []
    }

    /// Name of a pinned device by UID, when it is still present.
    func routeDeviceName(forUID uid: String) -> String? {
        deviceMonitor.devices.first { $0.uid == uid }?.name
    }

    /// The volume control backing a pinned device's own slider, if present.
    func routeVolume(forUID uid: String) -> (any VolumeControlling)? {
        routeVolumes[uid]
    }

    /// Pins an app's audio to another output device, on top of any already
    /// pinned. The tap IS the route, so routing puts a bypassed app through
    /// Fader, and the tap is rebuilt to fan its aggregate out to the new set.
    func route(_ app: AudioApp, to device: AudioDevice) {
        var entry = volumes[app.bundleID] ?? AppVolume()
        guard !entry.outputDeviceUIDs.contains(device.uid) else { return }
        entry.outputDeviceUIDs.append(device.uid)
        entry.throughFader = true
        volumes[app.bundleID] = entry
        scheduleSave()
        rebuildTap(for: app, entry: entry)
    }

    /// Drops one pinned device. The app keeps playing on whatever remains, and
    /// returns to the default once the last pin is gone.
    func unroute(_ app: AudioApp, from uid: String) {
        guard var entry = volumes[app.bundleID], entry.outputDeviceUIDs.contains(uid) else { return }
        entry.outputDeviceUIDs.removeAll { $0 == uid }
        volumes[app.bundleID] = entry.isNeutral ? nil : entry
        scheduleSave()
        rebuildTap(for: app, entry: entry)
    }

    /// Clears every route, returning the app to the default output. Drops the
    /// tap when nothing else (volume or mute) keeps the app non-neutral.
    func clearRoute(for app: AudioApp) {
        guard var entry = volumes[app.bundleID], !entry.outputDeviceUIDs.isEmpty else { return }
        entry.outputDeviceUIDs.removeAll()
        volumes[app.bundleID] = entry.isNeutral ? nil : entry
        scheduleSave()
        rebuildTap(for: app, entry: entry)
    }
}
