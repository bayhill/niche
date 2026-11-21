import Foundation

/// Shared text formatting so every module writes sizes, savings and durations the same way.
public enum Format {
    /// "264 KB", "1.2 MB". Decimal units, like Finder.
    public static func bytes(_ count: Int64) -> String {
        let c = max(0, count)
        if c < 1000 { return "\(c) B" }
        let kb = Double(c) / 1000
        if kb < 999.5 { return "\(Int(kb.rounded())) KB" }
        let mb = kb / 1000
        if mb < 99.95 { return String(format: "%.1f MB", locale: Locale(identifier: "en_US_POSIX"), mb) }
        if mb < 999.5 { return "\(Int(mb.rounded())) MB" }
        return String(format: "%.1f GB", locale: Locale(identifier: "en_US_POSIX"), mb / 1000)
    }

    /// Size change as a signed percentage: "−78%" for a saving, "+12%" for growth, "0%" for none.
    /// - Parameter savedFraction: `1 - output/input` (0.78 = 78% smaller; negative = larger).
    public static func saving(_ savedFraction: Double) -> String {
        let pct = Int((abs(savedFraction) * 100).rounded())
        if pct == 0 { return "0%" }
        return savedFraction > 0 ? "\u{2212}\(pct)%" : "+\(pct)%"
    }

    /// Track position: "1:24", "1:02:03". With `remaining`, a real minus sign in front: "\u{2212}2:17".
    public static func playback(seconds: TimeInterval, remaining: Bool = false) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let body = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return remaining ? "\u{2212}" + body : body
    }

    /// How long ago something happened: "now" (under a minute), "4m", "1h", "3d". Rounds down.
    public static func age(seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// "1h 5m", "12m", "45s", "now" (also for past dates).
    public static func countdown(seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s <= 0 { return "now" }
        if s < 60 { return "\(s)s" }
        let m = Int((Double(s) / 60).rounded(.up))
        if m < 60 { return "\(m)m" }
        let h = m / 60, rem = m % 60
        return rem == 0 ? "\(h)h" : "\(h)h \(rem)m"
    }
}
