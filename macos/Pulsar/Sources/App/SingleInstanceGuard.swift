import Foundation

/// Single-instance guard backed by a POSIX advisory file lock (`flock`).
///
/// Pulsar can be launched two ways *at once*: by its LaunchAgent
/// (`team.yourorbit.Pulsar`, `RunAtLoad` at login) AND by a GUI/LaunchServices
/// launch (`open -a Pulsar`, or a double-click). Without a guard BOTH processes
/// draw the floating overlay + drone swarm and BOTH try to bind
/// 127.0.0.1:7865 — the user sees a DUPLICATED head. The port clash can't
/// arbitrate this: the loser's Hummingbird bind just throws and is swallowed
/// (see `PulsarHTTPServer.start()`), leaving that instance alive with its own
/// overlay. So we need an explicit guard.
///
/// Why `flock` (not a pidfile, not an NSRunningApplication scan, not the port):
///   • Atomic + race-free — the kernel grants the exclusive lock to exactly one
///     process even if two launch simultaneously. A pidfile has a check-then-write
///     TOCTOU window; this doesn't.
///   • Self-healing — the lock is tied to the open fd, so a crash/kill releases
///     it automatically when the process dies. There is no such thing as a stale
///     `flock` to reap, unlike a pidfile whose PID may have been recycled.
///   • Deterministic survivor — "first to acquire wins". The LaunchAgent instance
///     starts at login, well before any manual launch, so it holds the lock and a
///     later GUI double-launch defers to it (exits). That's exactly the required
///     ordering: the GUI newcomer defers to the LaunchAgent instance, never the
///     reverse.
///
/// Crash recovery is unaffected: when the sole instance genuinely crashes the
/// kernel drops the lock, and launchd's `KeepAlive{SuccessfulExit=false}`
/// relaunch re-acquires it cleanly on the next process. A duplicate that defers
/// exits with status 0 (a *successful* exit), so it never triggers that
/// KeepAlive relaunch — no thrash loop.
enum SingleInstanceGuard {
    /// The held lock file descriptor, retained for the entire process lifetime
    /// so the advisory lock is never released until this process exits (the
    /// kernel closes the fd on death). Written exactly once, on the main thread
    /// during launch, then never mutated — hence `nonisolated(unsafe)`.
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    /// Try to become the sole running instance.
    ///
    /// - Returns: `true` if this process now holds the lock (proceed with
    ///   launch), `false` if another live instance already holds it (the caller
    ///   must exit immediately, before creating the status item / overlay /
    ///   HTTP server).
    ///
    /// On any *unexpected* error (can't open the lockfile, `flock` fails for a
    /// reason other than "already locked") this fails OPEN — returns `true` —
    /// so a permissions hiccup degrades to the pre-guard behaviour rather than
    /// bricking launch entirely.
    @discardableResult
    static func acquire() -> Bool {
        let lockURL = PulsarConfig.shared.storageRoot
            .appendingPathComponent("pulsar.lock")

        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            NSLog("[Pulsar] single-instance guard: could not open lockfile at \(lockURL.path) (errno \(errno)); proceeding unguarded")
            return true
        }

        // Non-blocking exclusive lock. Success → we own the singleton. Failure
        // with EWOULDBLOCK → another live instance holds it → this is a duplicate.
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            close(fd)
            if err == EWOULDBLOCK {
                NSLog("[Pulsar] single-instance guard: another instance already holds the lock — this launch is a duplicate and will exit")
                return false
            }
            NSLog("[Pulsar] single-instance guard: flock failed (errno \(err)); proceeding unguarded")
            return true
        }

        // Hold the fd open for the process lifetime. Never close it — closing
        // would release the lock and re-open the duplicate window.
        lockFD = fd
        return true
    }
}
