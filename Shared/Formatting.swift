import Foundation
import PlannerCore
import SwiftUI

extension LocalDate {
    /// Midnight of this date in the current time zone (for DatePicker bindings and formatting).
    var asDate: Date {
        var cal = Calendar.current
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    init(_ date: Date) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        self.init(c.year!, c.month!, c.day!)
    }
}

extension LocalTime {
    var asDate: Date { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date() }
    init(_ date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        self.init(c.hour ?? 0, c.minute ?? 0)
    }
}

enum Fmt {
    static func date(_ d: LocalDate, today: LocalDate = .today()) -> String {
        if d == today { return "Today" }
        if d == today.plusDays(1) { return "Tomorrow" }
        if d == today.plusDays(-1) { return "Yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(d.year == today.year ? "EEEdMMM" : "dMMMy")
        return f.string(from: d.asDate)
    }

    static func time(_ t: LocalTime) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: t.asDate)
    }

    static func priorityMarks(_ p: Int) -> String { ["", "!", "!!", "!!!"][max(0, min(3, p))] }
    static func priorityLabel(_ p: Int) -> String { ["No priority", "Low", "Medium", "High"][max(0, min(3, p))] }

    static func priorityColor(_ p: Int) -> Color {
        switch p {
        case 3: return Color(red: 0.83, green: 0.18, blue: 0.18)
        case 2: return Color(red: 0.96, green: 0.49, blue: 0.0)
        case 1: return Color(red: 0.1, green: 0.46, blue: 0.82)
        default: return .secondary
        }
    }

    static func color(_ argb: Int?) -> Color {
        guard let argb else { return .secondary }
        let r = Double((argb >> 16) & 0xFF) / 255, g = Double((argb >> 8) & 0xFF) / 255, b = Double(argb & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }

    static func listIcon(_ key: String?) -> String {
        switch key {
        case "personal": return "person.fill"
        case "work": return "briefcase.fill"
        case "study": return "graduationcap.fill"
        case "fitness": return "figure.run"
        case "travel": return "airplane"
        case "wishlist": return "gift.fill"
        case "family": return "birthday.cake.fill"
        case "home": return "house.fill"
        case "shopping": return "cart.fill"
        default: return "list.bullet"
        }
    }

    static let iconKeys = ["personal", "work", "study", "fitness", "travel", "wishlist", "family", "home", "shopping"]
    static let listColors: [Int] = [0xFF5C6BC0, 0xFF00897B, 0xFF8E24AA, 0xFFE53935, 0xFF039BE5, 0xFFF4511E, 0xFFD81B60, 0xFF7CB342, 0xFF6D4C41]
}
