import Foundation

/// Heuristic parser for pasted task lists and short goals (same behaviour as the Android app).
public enum RoughInputParser {
    public struct AvailabilityHint: Equatable, Sendable {
        public var date: LocalDate
        public var start: LocalTime?
        public var minutes: Int?
    }

    public struct Result: Sendable {
        public var tasks: [PlannerTask]
        public var availability: AvailabilityHint?
    }

    static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "half an": 0.5, "fifteen": 15, "twenty": 20, "thirty": 30, "forty five": 45,
    ]
    static let numberPattern = "(\\d+(?:\\.\\d+)?|half an|forty[- ]five|a|an|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty)"
    static let durationRegex = try! NSRegularExpression(
        pattern: "\\(?\\b\(numberPattern)\\s*(h|hr|hrs|hour|hours|m|min|mins|minute|minutes)\\b\\)?", options: [.caseInsensitive])
    static let availabilityRegex = try! NSRegularExpression(pattern: "\\b(i have|i've got|i got|i'm free|i am free|free for|available)\\b", options: [.caseInsensitive])
    static let fillerPrefix = try! NSRegularExpression(
        pattern: "^(please\\s+)?(help me( to)?|i need to|i have to|i must|i want to|i should|remind me to|plan( out)?|also|then|and|to)\\s+",
        options: [.caseInsensitive])
    static let bullet = try! NSRegularExpression(pattern: "^\\s*([-*•]|\\d+[.)]|\\[ ?\\])\\s*")
    static let sentenceSplit = try! NSRegularExpression(pattern: "\\n|;|\\?(?=\\s|$)|\\.(?=\\s|$)")
    static let commaSplit = try! NSRegularExpression(pattern: "(?<=[a-z]),\\s+")
    static let clauseSplit = try! NSRegularExpression(pattern: "\\s+(?:and then|and also|then|and)\\s+", options: [.caseInsensitive])
    static let weekdayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    // MARK: regex helpers
    static func ns(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }
    static func split(_ s: String, _ re: NSRegularExpression) -> [String] {
        var out: [String] = []
        var last = s.startIndex
        for m in re.matches(in: s, range: ns(s)) {
            guard let r = Range(m.range, in: s) else { continue }
            out.append(String(s[last..<r.lowerBound]))
            last = r.upperBound
        }
        out.append(String(s[last...]))
        return out
    }
    static func matches(_ s: String, _ re: NSRegularExpression) -> Bool { re.firstMatch(in: s, range: ns(s)) != nil }
    static func replace(_ s: String, _ re: NSRegularExpression, _ with: String = "") -> String {
        re.stringByReplacingMatches(in: s, range: ns(s), withTemplate: with)
    }
    static func groups(_ m: NSTextCheckingResult, in s: String) -> [String] {
        (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }

    public static func parse(_ text: String, today: LocalDate, workEnds: LocalTime = LocalTime(17, 30)) -> Result {
        var availability: AvailabilityHint?
        var tasks: [PlannerTask] = []
        let sentences = split(text, sentenceSplit)
            .flatMap { line in matches(line, bullet) ? [line] : split(line, commaSplit) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for sentence in sentences {
            if availability == nil && matches(sentence, availabilityRegex) {
                availability = parseAvailability(sentence, today: today, workEnds: workEnds)
                continue
            }
            for clause in split(replace(sentence, bullet), clauseSplit) {
                if let t = parseTask(clause, today: today, index: tasks.count) { tasks.append(t) }
            }
        }
        return Result(tasks: tasks, availability: availability)
    }

    static func nextWeekday(_ today: LocalDate, _ weekday: Int, orSame: Bool) -> LocalDate {
        var diff = (weekday - today.weekday + 7) % 7
        if diff == 0 && !orSame { diff = 7 }
        return today.plusDays(diff)
    }

    static func parseAvailability(_ sentence: String, today: LocalDate, workEnds: LocalTime) -> AvailabilityHint {
        let lower = sentence.lowercased()
        let minutes = durationRegex.firstMatch(in: lower, range: ns(lower)).map { toMinutes(groups($0, in: lower)) }
        var date = today
        if lower.contains("tomorrow") { date = today.plusDays(1) }
        else if let i = weekdayNames.firstIndex(where: { lower.contains($0) }) { date = nextWeekday(today, i + 1, orSame: false) }
        var start: LocalTime?
        if lower.contains("after work") { start = workEnds }
        else if lower.contains("morning") { start = LocalTime(8, 0) }
        else if lower.contains("lunch") { start = LocalTime(12, 30) }
        else if lower.contains("afternoon") { start = LocalTime(14, 0) }
        else if lower.contains("evening") || lower.contains("tonight") { start = LocalTime(18, 30) }
        else if let re = try? NSRegularExpression(pattern: "\\bat (\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)?"),
                let m = re.firstMatch(in: lower, range: ns(lower)) {
            let g = groups(m, in: lower)
            var h = Int(g[1]) ?? 0
            let mm = Int(g[2]) ?? 0
            if g[3] == "pm" && h < 12 { h += 12 }
            if g[3] == "am" && h == 12 { h = 0 }
            if (0...23).contains(h) && (0...59).contains(mm) { start = LocalTime(h, mm) }
        }
        return AvailabilityHint(date: date, start: start, minutes: minutes)
    }

    static func parseTask(_ raw: String, today: LocalDate, index: Int) -> PlannerTask? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix(",") || t.hasSuffix("!") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        let lower0 = t.lowercased()
        var priority = PlanPriority.none
        if lower0.contains("!low") || lower0.contains("(low)") { priority = .low }
        else if raw.contains("!!") || ["urgent", "asap", "important", "!high"].contains(where: { lower0.contains($0) }) { priority = .high }
        else if raw.trimmingCharacters(in: .whitespaces).hasSuffix("!") || lower0.contains("!med") { priority = .medium }
        t = replace(t, try! NSRegularExpression(pattern: "!+(low|med|medium|high)?", options: [.caseInsensitive]))
        t = replace(t, try! NSRegularExpression(pattern: "\\b(urgent|asap)\\b", options: [.caseInsensitive]))

        var duration: Int?
        if let m = durationRegex.firstMatch(in: t, range: ns(t)), let r = Range(m.range, in: t) {
            duration = toMinutes(groups(m, in: t))
            t.removeSubrange(r)
        }
        var deadline: LocalDateTime?
        let dayRe = try! NSRegularExpression(pattern: "\\b(by |before |due )?(today|tonight|tomorrow(?:'s)?)\\b", options: [.caseInsensitive])
        if let m = dayRe.firstMatch(in: t, range: ns(t)), let r = Range(m.range, in: t) {
            let g = groups(m, in: t)
            let day = g[2].lowercased().hasPrefix("tomorrow") ? today.plusDays(1) : today
            deadline = LocalDateTime(day, LocalTime(23, 59))
            if !g[1].isEmpty { t.removeSubrange(r) }
        }
        let byRe = try! NSRegularExpression(pattern: "\\b(by|before|due) (monday|tuesday|wednesday|thursday|friday|saturday|sunday)\\b", options: [.caseInsensitive])
        if let m = byRe.firstMatch(in: t, range: ns(t)), let r = Range(m.range, in: t) {
            let g = groups(m, in: t)
            if let i = weekdayNames.firstIndex(of: g[2].lowercased()) {
                deadline = LocalDateTime(nextWeekday(today, i + 1, orSame: true), LocalTime(23, 59))
            }
            t.removeSubrange(r)
        }
        t = replace(t, try! NSRegularExpression(pattern: "\\s{2,}"), " ")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,-:()"))
        for _ in 0..<3 { t = replace(t, fillerPrefix).trimmingCharacters(in: .whitespaces) }
        if t.count < 2 { return nil }
        let title = t.prefix(1).uppercased() + t.dropFirst()
        return PlannerTask(id: "draft-\(index)", title: title, durationMinutes: duration ?? defaultDuration(title),
                           priority: priority, deadline: deadline)
    }

    static func toMinutes(_ g: [String]) -> Int {
        let key = g[1].lowercased().replacingOccurrences(of: "-", with: " ")
        let n = Double(key) ?? numberWords[key] ?? 1
        let minutes = g[2].lowercased().hasPrefix("h") ? n * 60 : n
        return min(720, max(5, Int(minutes)))
    }

    public static func defaultDuration(_ title: String) -> Int {
        let l = title.lowercased()
        if ["revise", "study", "exam", "essay", "write", "assignment", "project"].contains(where: { l.contains($0) }) { return 60 }
        if ["errand", "shopping", "groceries", "gym", "workout", "clean"].contains(where: { l.contains($0) }) { return 45 }
        if ["call", "email", "text", "pay", "book", "reply"].contains(where: { l.contains($0) }) { return 15 }
        return 30
    }
}
