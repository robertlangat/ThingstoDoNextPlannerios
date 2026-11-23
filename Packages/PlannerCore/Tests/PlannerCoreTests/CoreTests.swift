import XCTest
@testable import PlannerCore

final class RecurrenceTests: XCTestCase {
    func d(_ s: String) -> LocalDate { LocalDate(iso: s)! }

    func testLocalDateArithmetic() {
        XCTAssertEqual(LocalDate(1970, 1, 1).epochDay, 0)
        XCTAssertEqual(d("2026-11-16").weekday, 1) // Monday
        XCTAssertEqual(LocalDate(epochDay: d("2024-02-28").epochDay + 1), d("2024-02-29"))
        XCTAssertEqual(d("2026-01-31").plusMonths(1), d("2026-02-28"))
        XCTAssertNil(LocalDate(iso: "2026-02-30"))
    }

    func testMonthlyOn31stClampsWithoutDrifting() {
        let got = RecurrenceEngine.occurrences(d("2027-01-31"), RecurrenceRule(.MONTHLY), from: d("2027-01-01"), to: d("2027-06-30"))
        XCTAssertEqual(got, ["2027-01-31", "2027-02-28", "2027-03-31", "2027-04-30", "2027-05-31", "2027-06-30"].map(d))
    }

    func testYearlyFeb29() {
        let got = RecurrenceEngine.first(5, d("2024-02-29"), RecurrenceRule(.YEARLY))
        XCTAssertEqual(got, ["2024-02-29", "2025-02-28", "2026-02-28", "2027-02-28", "2028-02-29"].map(d))
    }

    func testWeekdaysAndCustomWeekly() {
        XCTAssertEqual(RecurrenceEngine.first(3, d("2026-11-13"), RecurrenceRule(.WEEKDAYS)), ["2026-11-13", "2026-11-16", "2026-11-17"].map(d))
        let rule = RecurrenceRule(.WEEKLY, interval: 2, byDays: [1, 3])
        XCTAssertEqual(RecurrenceEngine.first(4, d("2026-11-18"), rule), ["2026-11-18", "2026-11-30", "2026-12-02", "2026-12-14"].map(d))
    }

    func testCountIncludesExDatesAndUntilInclusive() {
        let rule = RecurrenceRule(.DAILY, end: .count(3), exDates: [d("2026-11-16")])
        XCTAssertEqual(RecurrenceEngine.occurrences(d("2026-11-15"), rule, from: d("2026-11-01"), to: d("2026-12-31")), [d("2026-11-15"), d("2026-11-17")])
        let until = RecurrenceRule(.DAILY, end: .until(d("2026-11-17")))
        XCTAssertEqual(RecurrenceEngine.occurrences(d("2026-11-15"), until, from: d("2026-11-01"), to: d("2027-01-01")).count, 3)
    }

    func testFormatMatchesAndroid() {
        let rule = RecurrenceRule(.WEEKLY, interval: 3, byDays: [5, 1], end: .count(12), exDates: [d("2026-12-25")])
        XCTAssertEqual(rule.format(), "FREQ=WEEKLY;INTERVAL=3;BYDAY=MO,FR;COUNT=12;EXDATE=2026-12-25")
        XCTAssertEqual(RecurrenceRule.parse(rule.format()), rule)
        XCTAssertNil(RecurrenceRule.parse("garbage"))
    }

    func testSplitKeepsTotal() {
        let start = d("2026-11-01")
        let (old, new) = RecurrenceEngine.split(start, RecurrenceRule(.DAILY, end: .count(10)), at: d("2026-11-04"))
        XCTAssertEqual(old?.end, .count(3))
        XCTAssertEqual(new.end, .count(7))
        let (old2, _) = RecurrenceEngine.split(start, RecurrenceRule(.WEEKLY), at: d("2026-11-22"))
        XCTAssertEqual(old2?.end, .until(d("2026-11-21")))
        XCTAssertNil(RecurrenceEngine.split(start, RecurrenceRule(.DAILY), at: start).0)
    }
}

final class ReminderTests: XCTestCase {
    let nairobi = TimeZone(identifier: "Africa/Nairobi")!
    let london = TimeZone(identifier: "Europe/London")!
    let nine = LocalTime(9, 0)
    func d(_ s: String) -> LocalDate { LocalDate(iso: s)! }
    func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    func task(_ date: String = "2026-11-16", time: LocalTime? = LocalTime(18, 0), rule: RecurrenceRule? = nil,
              offsets: [Int] = [0], done: Set<LocalDate> = [], deleted: Bool = false) -> ReminderTask {
        ReminderTask(taskId: "t1", title: "T", startDate: d(date), time: time, rule: rule, offsets: offsets, completedDates: done, deleted: deleted)
    }

    func testAtTimeAndBefore() {
        let got = ReminderPlanner.desired(tasks: [task(offsets: [0, 30])], snoozes: [], now: iso("2026-11-16T05:00:00Z"), tz: nairobi, allDayTime: nine)
        XCTAssertEqual(got.map(\.fireAt), [iso("2026-11-16T14:30:00Z"), iso("2026-11-16T15:00:00Z")])
    }

    func testDSTGapAndOverlap() {
        let gap = ReminderPlanner.fireDate(d("2027-03-28"), LocalTime(1, 30), offsetMinutes: 0, tz: london, allDayTime: nine)
        XCTAssertEqual(gap, iso("2027-03-28T01:30:00Z")) // 02:30 BST
        let overlap = ReminderPlanner.fireDate(d("2026-10-25"), LocalTime(1, 30), offsetMinutes: 0, tz: london, allDayTime: nine)
        XCTAssertEqual(overlap, iso("2026-10-25T00:30:00Z")) // first 01:30 (BST)
        XCTAssertEqual(ReminderPlanner.fireDate(d("2027-03-28"), nine, offsetMinutes: 0, tz: london, allDayTime: nine), iso("2027-03-28T08:00:00Z"))
    }

    func testTimeZoneChangeKeepsWallClockAndKey() {
        let t = task("2026-11-20", time: nine)
        let now = iso("2026-11-16T00:00:00Z")
        let a = ReminderPlanner.desired(tasks: [t], snoozes: [], now: now, tz: nairobi, allDayTime: nine).first!
        let b = ReminderPlanner.desired(tasks: [t], snoozes: [], now: now, tz: london, allDayTime: nine).first!
        XCTAssertEqual(a.fireAt, iso("2026-11-20T06:00:00Z"))
        XCTAssertEqual(b.fireAt, iso("2026-11-20T09:00:00Z"))
        XCTAssertEqual(a.key, b.key)
    }

    func testEditCompleteDeleteAndSnoozeDoNotDuplicate() {
        let now = iso("2026-11-16T00:00:00Z")
        let first = ReminderPlanner.desired(tasks: [task()], snoozes: [], now: now, tz: nairobi, allDayTime: nine)
        let existing = Dictionary(uniqueKeysWithValues: first.map { ($0.key, $0.fireAt) })
        let edited = ReminderPlanner.desired(tasks: [task(time: LocalTime(19, 0))], snoozes: [], now: now, tz: nairobi, allDayTime: nine)
        let plan = ReminderPlanner.diff(edited, existing: existing)
        XCTAssertEqual(plan.schedule.map(\.key), first.map(\.key))
        XCTAssertTrue(plan.cancel.isEmpty)
        let deleted = ReminderPlanner.desired(tasks: [task(deleted: true)], snoozes: [], now: now, tz: nairobi, allDayTime: nine)
        XCTAssertEqual(ReminderPlanner.diff(deleted, existing: existing).cancel, Set(existing.keys))
        let completed = ReminderPlanner.desired(tasks: [task(done: [d("2026-11-16")])], snoozes: [], now: now, tz: nairobi, allDayTime: nine)
        XCTAssertTrue(completed.isEmpty)
        let s = Snooze(taskId: "t1", date: d("2026-11-16"), until: now.addingTimeInterval(600))
        let snoozed = ReminderPlanner.desired(tasks: [task()], snoozes: [s, s], now: now, tz: nairobi, allDayTime: nine)
        XCTAssertEqual(snoozed.filter(\.isSnooze).count, 1)
    }

    func testRecurringSkipsCompletedOccurrenceAndCapsAt60() {
        let now = iso("2026-11-16T00:00:00Z")
        let t = task(rule: RecurrenceRule(.DAILY), offsets: [0, 5, 10], done: [d("2026-11-16")])
        let got = ReminderPlanner.desired(tasks: [t], snoozes: [], now: now, tz: nairobi, allDayTime: nine)
        XCTAssertFalse(got.contains { $0.occurrenceDate == d("2026-11-16") })
        XCTAssertEqual(got.count, 60)
    }
}

final class SyncTests: XCTestCase {
    let now: Int64 = 1_800_000_000_000
    func v(_ ms: Int64, _ c: Int64 = 0) -> Int64 { (ms << 16) | c }
    func rec(_ id: String, _ version: Int64, _ dev: String, deleted: Bool = false, title: String? = nil, seen: Int64 = 0) -> SyncRecord {
        SyncRecord(type: "task", id: id, version: version, deviceId: dev, deleted: deleted, data: ["title": .string(title ?? id)], seenDeleteVersion: seen)
    }

    func testUnionWithoutDuplicates() {
        let r = SyncMerger.merge(local: [rec("a", v(now), "phone"), rec("s", v(now), "phone")],
                                 remote: [rec("b", v(now), "tab"), rec("s", v(now), "phone")], nowMillis: now)
        XCTAssertEqual(Set(r.merged.map(\.id)), ["a", "b", "s"])
        XCTAssertEqual(r.changedLocally.map(\.id), ["b"])
        XCTAssertTrue(r.remoteNeedsUpdate)
    }

    func testDeletionStaysDeletedAndUndoRestores() {
        let tomb = rec("a", v(now - 1000), "phone", deleted: true)
        let offline = rec("a", v(now), "tab", title: "renamed")
        XCTAssertTrue(SyncMerger.merge(local: [offline], remote: [tomb], nowMillis: now).merged[0].deleted)
        XCTAssertTrue(SyncMerger.merge(local: [tomb], remote: [offline], nowMillis: now).merged[0].deleted)
        let undo = rec("a", v(now), "phone", seen: tomb.version)
        XCTAssertFalse(SyncMerger.merge(local: [undo], remote: [tomb], nowMillis: now).merged[0].deleted)
    }

    func testLastWriterWinsAndDeterministicTie() {
        let r = SyncMerger.merge(local: [rec("x", v(now), "phone", title: "p")], remote: [rec("x", v(now, 1), "tab", title: "t")], nowMillis: now)
        XCTAssertEqual(r.merged[0].data["title"], .string("t"))
        let a = rec("x", v(now), "aaa", title: "A"), b = rec("x", v(now), "bbb", title: "B")
        XCTAssertEqual(SyncMerger.merge(local: [a], remote: [b], nowMillis: now).merged[0].data["title"], .string("B"))
        XCTAssertEqual(SyncMerger.merge(local: [b], remote: [a], nowMillis: now).merged[0].data["title"], .string("B"))
    }

    func testIdempotentRoundTripAndPurge() throws {
        let local = [rec("a", v(now), "p"), rec("b", v(now), "p", deleted: true)]
        let first = SyncMerger.merge(local: local, remote: [], nowMillis: now)
        let decoded = try SnapshotCodec.decode(SnapshotCodec.encode(SyncSnapshot(generatedBy: "p", generatedAt: now, records: first.merged))).records
        let second = SyncMerger.merge(local: local, remote: decoded, nowMillis: now)
        XCTAssertTrue(second.changedLocally.isEmpty)
        XCTAssertFalse(second.remoteNeedsUpdate)
        let old = rec("z", v(now - SyncMerger.tombstoneRetentionMillis - 1), "p", deleted: true)
        let purged = SyncMerger.merge(local: [old], remote: [old], nowMillis: now)
        XCTAssertTrue(purged.merged.isEmpty)
        XCTAssertEqual(purged.purgeLocally, ["task:z"])
    }

    func testHLCMonotonic() {
        var wall: Int64 = 1000
        let c = HybridLogicalClock(wall: { wall })
        let a = c.now(); wall = 500
        XCTAssertGreaterThan(c.now(), a)
        c.observe(v(5000)); XCTAssertGreaterThan(c.now(), v(5000))
    }

    /// A snapshot written by the Android app must load on iOS (shared Google Drive file).
    func testReadsAndroidSnapshot() throws {
        let android = """
        {"schemaVersion":1,"generatedBy":"android-device","generatedAt":1800000000000,"records":[
        {"type":"list","id":"L1","version":117964800000000000,"deviceId":"android","deleted":false,"seenDeleteVersion":0,"data":{"name":"Work","color":4278225275,"icon":"work","sortOrder":1}},
        {"type":"task","id":"T1","version":117964800000000001,"deviceId":"android","deleted":false,"seenDeleteVersion":0,"data":{"listId":"L1","title":"Pay rent","notes":"","priority":3,"starred":true,"dueDate":20847,"dueTimeMinutes":540,"rrule":"FREQ=MONTHLY","completed":false,"completedAt":null,"reminderOffsets":"0,30","estimatedMinutes":15,"seriesParentId":null,"createdAt":1700000000000,"sortOrder":1700000000000}},
        {"type":"occurrence","id":"T1@2027-01-31","version":117964800000000002,"deviceId":"android","deleted":false,"seenDeleteVersion":0,"data":{"taskId":"T1","date":20849,"completed":true,"completedAt":1800000000000}}
        ]}
        """
        let snap = try SnapshotCodec.decode(Data(android.utf8))
        var db = Database()
        SyncMapping.apply(snap.records, purge: [], to: &db)
        XCTAssertEqual(db.lists.first?.color, 4_278_225_275)
        let t = try XCTUnwrap(db.tasks.first)
        XCTAssertEqual(t.title, "Pay rent")
        XCTAssertEqual(t.dueTime, LocalTime(9, 0))
        XCTAssertEqual(t.reminderOffsets, [0, 30])
        XCTAssertEqual(t.rule, RecurrenceRule(.MONTHLY))
        XCTAssertEqual(db.occurrences.first?.id, "T1@2027-01-31")
        // and back out again with identical keys/fields
        let again = SyncMapping.records(db)
        XCTAssertEqual(Set(again.map(\.key)), Set(snap.records.map(\.key)))
        XCTAssertEqual(again.first { $0.id == "T1" }?.data["reminderOffsets"], .string("0,30"))
        XCTAssertEqual(again.first { $0.id == "T1" }?.data["dueDate"], .int(20847))
    }

    func testRejectsNewerSchema() {
        XCTAssertThrowsError(try SnapshotCodec.decode(Data(#"{"schemaVersion":99,"records":[]}"#.utf8)))
        XCTAssertThrowsError(try SnapshotCodec.decode(Data("nope".utf8)))
    }
}

final class PlannerTests: XCTestCase {
    let today = LocalDate(2026, 11, 16)
    func t(_ h: Int, _ m: Int = 0) -> LocalDateTime { LocalDateTime(today, LocalTime(h, m)) }

    func testParsesExamplePrompt() {
        let r = RoughInputParser.parse("I have two hours after work. Help me revise for an exam and plan tomorrow's errands.", today: today)
        XCTAssertEqual(r.availability?.minutes, 120)
        XCTAssertEqual(r.availability?.start, LocalTime(17, 30))
        XCTAssertEqual(r.tasks.map(\.title), ["Revise for an exam", "Tomorrow's errands"])
        XCTAssertEqual(r.tasks[0].durationMinutes, 60)
        XCTAssertEqual(r.tasks[1].deadline, LocalDateTime(today.plusDays(1), LocalTime(23, 59)))
    }

    func testParsesBullets() {
        let r = RoughInputParser.parse("- Pay rent urgent 10m\n- Gym (1.5h)\n* call mum !low\n3. Write essay by friday", today: today)
        XCTAssertEqual(r.tasks.map(\.title), ["Pay rent", "Gym", "Call mum", "Write essay"])
        XCTAssertEqual(r.tasks.map(\.durationMinutes), [10, 90, 15, 60])
        XCTAssertEqual(r.tasks[0].priority, .high)
        XCTAssertEqual(r.tasks[2].priority, .low)
        XCTAssertEqual(r.tasks[3].deadline?.date, LocalDate(2026, 11, 20))
    }

    func testOfflinePlannerOrdersAndAvoidsBusy() {
        let req = PlanRequest(
            tasks: [PlannerTask(id: "1", title: "Low", priority: .low), PlannerTask(id: "2", title: "Urgent", priority: .high),
                    PlannerTask(id: "3", title: "Due", deadline: t(19))],
            availability: [TimeWindow(t(17, 30), t(19, 30))],
            busy: [BusyBlock(title: "Dinner", window: TimeWindow(t(18), t(18, 30)))], bufferMinutes: 0)
        let draft = OfflinePlanner.plan(req)
        let by = Dictionary(uniqueKeysWithValues: draft.items.map { ($0.task.title, $0) })
        XCTAssertEqual(by["Due"]?.slot?.start, t(17, 30))
        XCTAssertEqual(by["Urgent"]?.slot?.start, t(18, 30))
        XCTAssertEqual(by["Low"]?.slot?.start, t(19))
        XCTAssertEqual(draft.source, .offline)
        let huge = OfflinePlanner.plan(PlanRequest(tasks: [PlannerTask(id: "h", title: "Huge", durationMinutes: 240)],
                                                   availability: [TimeWindow(t(18), t(20))], busy: []))
        XCTAssertTrue(huge.items[0].flags.contains(.unscheduled))
    }

    func testAIValidatorWithBackendMockResponse() throws {
        let json = #"{"model":"mock","summary":"Mock plan with 2 tasks","tasks":[{"title":"Revise for an exam","durationMinutes":30,"priority":"high","start":"2026-11-16T17:30","subtasks":[]},{"title":"Tomorrow's errands.","durationMinutes":9999,"priority":"medium","start":"17:45","subtasks":["Bank",3]},{"title":"  "}]}"#
        let draft = try AIPlanValidator.validate(Data(json.utf8), planDate: today, busy: [], availability: [TimeWindow(t(17), t(23))])
        XCTAssertEqual(draft.source, .ai)
        XCTAssertEqual(draft.modelName, "mock")
        XCTAssertEqual(draft.items.count, 2)
        XCTAssertEqual(draft.items[1].task.durationMinutes, 720)
        XCTAssertEqual(draft.items[1].task.subtasks, ["Bank"])
        XCTAssertTrue(draft.items[1].flags.contains(.overlapsDraft))
        XCTAssertThrowsError(try AIPlanValidator.validate(Data("<html>".utf8), planDate: today, busy: [], availability: []))
    }
}

final class ViewTests: XCTestCase {
    let today = LocalDate(2026, 11, 16)

    func makeData() -> AppData {
        func task(_ id: String, _ date: LocalDate?, rrule: String? = nil, priority: Int = 0, starred: Bool = false, completed: Bool = false, listId: String? = nil) -> TaskItem {
            var t = TaskItem(id: id, listId: listId, title: "Task \(id)", createdAt: 0, version: 1, deviceId: "d")
            t.dueDate = date; t.rrule = rrule; t.priority = priority; t.starred = starred; t.completed = completed
            return t
        }
        var db = Database()
        db.tasks = [task("today", today, priority: 3), task("late", today.plusDays(-2)), task("next", today.plusDays(3), starred: true),
                    task("undated", nil), task("done", today, completed: true),
                    task("daily", today.plusDays(-5), rrule: "FREQ=DAILY", listId: "work")]
        db.occurrences = [Occurrence(taskId: "daily", date: today, completed: true, completedAt: 1, version: 1, deviceId: "d")]
        return AppData(db)
    }

    func testTodayInboxStarredCompletedSearchFilters() {
        let data = makeData()
        let sections = Dictionary(uniqueKeysWithValues: TaskViews.build(.today, data, today: today, query: "", filters: Filters()).map { ($0.title ?? "", $0.items.map(\.task.id)) })
        XCTAssertTrue(sections["Overdue"]!.contains("late"))
        XCTAssertEqual(sections["Today"], ["today"])
        XCTAssertEqual(Set(sections["Done today"]!), ["done", "daily"])
        XCTAssertFalse(TaskViews.build(.inbox, data, today: today, query: "", filters: Filters())[0].items.contains { $0.task.id == "daily" })
        XCTAssertEqual(TaskViews.build(.starred, data, today: today, query: "", filters: Filters())[0].items.map(\.task.id), ["next"])
        XCTAssertEqual(Set(TaskViews.build(.completed, data, today: today, query: "", filters: Filters())[0].items.map(\.task.id)), ["done", "daily"])
        XCTAssertEqual(TaskViews.build(.inbox, data, today: today, query: "task undated", filters: Filters())[0].items.map(\.task.id), ["undated"])
        XCTAssertEqual(TaskViews.build(.inbox, data, today: today, query: "", filters: Filters(priorities: [3], date: .today))[0].items.map(\.task.id), ["today"])
        XCTAssertEqual(TaskViews.focus(data, today: today).first?.task.id, "today")
    }

    func testProgressCountsOccurrences() {
        let s = ProgressCalculator.compute(makeData(), today: today)
        // today: "today" (open), "done" (done), daily's occurrence today (done)
        XCTAssertEqual(s.today, Ratio(2, 3))
        // week Mon 16 - Sun 22: today, next, done + 7 daily occurrences (1 done)
        XCTAssertEqual(s.thisWeek, Ratio(2, 10))
        // "late" + daily occurrences on the 11th-15th
        XCTAssertEqual(s.overdue, 6)
        XCTAssertEqual(s.byList["work"], Ratio(1, 7))
    }
}
