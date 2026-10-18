import Foundation

/// Bounded fresh browse questions after a previously seen PC disappears.
/// Repeated removals/dial failures join the existing episode, rather than
/// postponing it or turning an absent PC into a permanent polling loop.
struct BrowseRecovery {
    static let delays: [TimeInterval] = [2.5, 10, 30]

    private struct Episode {
        let started: Date
        var next = 0
        var requiresRestart = false
    }
    private var episodes: [String: Episode] = [:]

    mutating func missing(_ name: String, now: Date) {
        if episodes[name] == nil { episodes[name] = Episode(started: now) }
    }

    /// A failed dial can leave a stale, fully populated row in the current
    /// browse. Require one fresh browser before trusting that row again.
    mutating func dialFailed(_ name: String, now: Date) {
        if episodes[name]?.next == Self.delays.count { episodes[name] = nil }
        missing(name, now: now)
        episodes[name]?.requiresRestart = true
    }

    /// Call only for an actual browser callback, never a debounced/cached row
    /// or a path-monitor redraw. TXT-less results do not prove recovery.
    mutating func observed(_ names: Set<String>) {
        for name in names where episodes[name]?.requiresRestart == false {
            episodes[name] = nil
        }
    }

    var nextDeadline: Date? {
        episodes.values.compactMap { episode in
            episode.next < Self.delays.count
                ? episode.started.addingTimeInterval(Self.delays[episode.next]) : nil
        }.min()
    }

    /// Several due PCs share one restart. A late timer skips elapsed slots
    /// rather than issuing a burst of restarts after sleep or a busy runloop.
    mutating func takeDue(now: Date) -> [String] {
        var due: [String] = []
        for (name, var episode) in episodes {
            let elapsed = now.timeIntervalSince(episode.started)
            guard episode.next < Self.delays.count, elapsed >= Self.delays[episode.next] else { continue }
            due.append(name)
            while episode.next < Self.delays.count, elapsed >= Self.delays[episode.next] {
                episode.next += 1
            }
            episode.requiresRestart = false
            episodes[name] = episode
        }
        return due.sorted()
    }
}
