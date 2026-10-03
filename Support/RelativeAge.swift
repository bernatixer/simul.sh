import Foundation

/// Compact "how long ago": now, 5m, 3h, 4d, 2w, 4mo, 1y.
enum RelativeAge {
    static func short(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 14 { return "\(days)d" }
        if days < 60 { return "\(days / 7)w" }
        if days < 365 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }

    /// Time until something, a bit more precise: 45m, 2h 10m, 3d 4h.
    static func countdown(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        if minutes < 60 { return "\(max(1, minutes))m" }
        let (hours, restMinutes) = (minutes / 60, minutes % 60)
        if hours < 24 { return restMinutes == 0 ? "\(hours)h" : "\(hours)h \(restMinutes)m" }
        let (days, restHours) = (hours / 24, hours % 24)
        return restHours == 0 ? "\(days)d" : "\(days)d \(restHours)h"
    }
}
