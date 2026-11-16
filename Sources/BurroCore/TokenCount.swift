// Token counts as the app shows them everywhere (Chats, Home, Usage, Today, the Orchestrator's
// runs): "950", "12.5K", "500K", "1.2M", "3.4B". The decimal point is always a point and the
// suffixes are always K, M and B, whatever the Mac's language, so a count never reads "500,4K".
import Foundation

public enum TokenCount {
    public static func compact(_ value: Double) -> String {
        let value = value.isFinite ? max(0, value) : 0
        func scaled(_ amount: Double, _ suffix: String) -> String {
            let text = amount >= 99.95 ? String(format: "%.0f", amount) : String(format: "%.1f", amount)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }
        if value < 999.5 { return String(Int(value.rounded())) }
        if value < 999_500 { return scaled(value / 1000, "K") }
        if value < 999_500_000 { return scaled(value / 1_000_000, "M") }
        return scaled(value / 1_000_000_000, "B")
    }

    public static func compact(_ value: Int) -> String { compact(Double(value)) }
}
