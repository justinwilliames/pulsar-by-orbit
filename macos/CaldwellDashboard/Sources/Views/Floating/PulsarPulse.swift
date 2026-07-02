import Foundation

/// The single source of truth for the Pulsar "heartbeat" glow pulse, shared by
/// the floating head (`FloatingPortraitView`) and the caption bubble
/// (`SubtitleBubbleView`) so they breathe in lockstep.
///
/// Both views drive their glow from `TimelineView(.animation)`, whose clock is
/// `Date().timeIntervalSinceReferenceDate` — an absolute, process-wide clock.
/// Feeding that same time through the same `beatPeriod` + `heartbeat()` here
/// guarantees identical phase without any explicit handshake: two independent
/// timelines computing `pulse(at: t)` are automatically phase-locked.
enum PulsarPulse {
    /// Pulsar beat period, seconds. One "pulse" per beat. Must match the head.
    static let beatPeriod: Double = 1.4

    /// 0…1 beat phase across one period.
    static func phase(at time: Double) -> Double {
        fmod(time, beatPeriod) / beatPeriod
    }

    /// Maps a 0…1 beat phase to a 0…1 intensity with a fast attack and a soft
    /// exponential decay — the characteristic pulsar "throb". Identical to the
    /// head's heartbeat shape.
    static func heartbeat(_ phase: Double) -> Double {
        if phase < 0.12 {
            return phase / 0.12                      // 0 → 1 attack
        }
        let decay = (phase - 0.12) / 0.88            // 0 → 1 over the rest
        return exp(-decay * 3.2)                     // 1 → ~0.04 fade
    }

    /// Convenience: the live pulse intensity (0…1) at an absolute timeline time.
    static func pulse(at time: Double) -> Double {
        heartbeat(phase(at: time))
    }
}
