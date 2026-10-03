import Foundation

/// One rate-limit window, e.g. Claude's 5-hour session or the weekly cap.
struct UsageWindow: Equatable {
    var label: String     // "5h", "Week"
    var percent: Double   // 0…100
    var resetsAt: Date?
}

/// Plan usage for one agent, as the agent itself reports it (Simul never
/// handles credentials; see UsageRefresher).
struct AgentUsage: Equatable {
    var agentID: String
    var windows: [UsageWindow]
    /// When the agent last refreshed these numbers.
    var updatedAt: Date?
}

enum UsageLimits {
    /// Claude's `/usage` prints prose; the structured numbers land in
    /// `~/.claude.json` → `cachedUsageUtilization`, read after each refresh.
    static func claude(configFile: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")) -> AgentUsage? {
        guard let data = try? Data(contentsOf: configFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any]
        else { return nil }

        let windows = [("five_hour", "5h"), ("seven_day", "Week")].compactMap { key, label -> UsageWindow? in
            guard let window = utilization[key] as? [String: Any],
                  let percent = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(label: label, percent: percent, resetsAt: isoDate(window["resets_at"]))
        }
        guard !windows.isEmpty else { return nil }
        let fetched = (cached["fetchedAtMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return AgentUsage(agentID: "claude", windows: windows, updatedAt: fetched)
    }

    /// Parses Codex's live `account/rateLimits/read` result (from
    /// `codex app-server`).
    static func codexAppServer(result: [String: Any], fetchedAt: Date) -> AgentUsage? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
            guard let window = limits[key] as? [String: Any],
                  let percent = (window["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue ?? 0
            let resets = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return UsageWindow(label: windowLabel(minutes: minutes), percent: percent, resetsAt: resets)
        }
        return windows.isEmpty ? nil : AgentUsage(agentID: "codex", windows: windows, updatedAt: fetchedAt)
    }

    static func windowLabel(minutes: Int) -> String {
        switch minutes {
        case 10080: "Week"
        case let m where m >= 1440 && m % 1440 == 0: "\(m / 1440)d"
        case let m where m >= 60 && m % 60 == 0: "\(m / 60)h"
        default: "\(minutes)m"
        }
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
