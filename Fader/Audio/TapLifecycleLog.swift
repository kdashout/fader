import os

/// Tap lifecycle events, logged at `.notice` so they persist in the unified
/// log long enough to line up with a reported volume jump:
///
///     /usr/bin/log show --last 1h --style compact \
///         --predicate 'subsystem == "dev.pantafive.fader" AND category == "TapLifecycle"'
///
/// Every moment a turned-down app can reach the speakers at full volume —
/// a tap released, replaced, suspended, or missing while the app plays — is
/// logged here. Bundle IDs are public: they name apps, not user content.
let tapLifecycleLogger = Logger(subsystem: "dev.pantafive.fader", category: "TapLifecycle")
