import XCTest
@testable import PlannerCore

final class OperationsTests: XCTestCase {
    let ops = TaskOperations(clock: HybridLogicalClock(), deviceId: "phone")
    let today = LocalDate.today()

    func testCreateCompleteUndoDelete() throws {
        var db = Database()
        let id = ops.create(TaskDraft(title: "Buy milk"), in: &db)
        ops.setCompleted(id, occurrence: nil, completed: true, in: &db)
        XCTAssertTrue(db.tasks.find(id)!.completed)
        ops.setCompleted(id, occurrence: nil, completed: false, in: &db)
        XCTAssertFalse(db.tasks.find(id)!.completed)
        let token = try XCTUnwrap(ops.delete(id, in: &db))
        XCTAssertTrue(AppData(db).tasks.isEmpty)
        ops.undo(token, in: &db)
        XCTAssertEqual(AppData(db).tasks.map(\.title), ["Buy milk"])
    }

    func testPerOccurrenceCompletion() {
        var db = Database()
        let rent = ops.create(TaskDraft(title: "Rent", dueDate: LocalDate(2027, 1, 31), rule: RecurrenceRule(.MONTHLY)), in: &db)
        ops.setCompleted(rent, occurrence: LocalDate(2027, 2, 28), completed: true, in: &db)
        let data = AppData(db)
        XCTAssertEqual(data.completedDates(rent), [LocalDate(2027, 2, 28)])
        let march = data.occurrences(from: LocalDate(2027, 3, 1), to: LocalDate(2027, 3, 31))
        XCTAssertEqual(march.map(\.date), [LocalDate(2027, 3, 31)])
        XCTAssertFalse(march[0].completed)
    }

    func testRecurringEditsNeverDuplicateReminders() throws {
        var db = Database()
        let id = ops.create(TaskDraft(title: "Stretch", dueDate: today, dueTime: LocalTime(23, 0), rule: RecurrenceRule(.DAILY), reminderOffsets: [0, 10]), in: &db)
        var d = try XCTUnwrap(ops.draft(of: id, in: db))
        d.title = "Stretch longer"; d.dueDate = today.plusDays(3)
        ops.update(id, d, scope: .thisAndFuture, occurrence: today.plusDays(3), in: &db)
        var single = try XCTUnwrap(ops.draft(of: id, in: db)); single.title = "Moved once"
        ops.update(id, single, scope: .thisOccurrence, occurrence: today.plusDays(1), in: &db)

        let alarms = ReminderPlanner.desired(tasks: db.reminderTasks(), snoozes: [], now: Date(), tz: .current, allDayTime: LocalTime(9, 0), horizonDays: 10)
        let slots = alarms.map { "\($0.occurrenceDate)#\($0.key.split(separator: "#").last!)" }
        XCTAssertEqual(slots.count, Set(slots).count)
        XCTAssertEqual(AppData(db).tasks.count, 3)
    }

    func testSyncedDeletionStaysDeletedAndRestoreDoesNotDuplicate() {
        var phone = Database()
        let id = ops.create(TaskDraft(title: "Old"), in: &phone)
        let before = SyncMapping.records(phone).first { $0.id == id }!
        _ = ops.delete(id, in: &phone)
        var offline = before
        offline.version = SyncMapping.records(phone).first { $0.id == id }!.version + 1000
        offline.deviceId = "tablet"; offline.data["title"] = .string("Edited offline")
        let m = SyncMerger.merge(local: SyncMapping.records(phone), remote: [offline], nowMillis: Int64(Date().timeIntervalSince1970 * 1000))
        SyncMapping.apply(m.changedLocally, purge: m.purgeLocally, to: &phone)
        XCTAssertTrue(AppData(phone).tasks.isEmpty)

        var fresh = Database()
        let exported = SyncMapping.records(phone)
        for _ in 0..<2 {
            let r = SyncMerger.merge(local: SyncMapping.records(fresh), remote: exported, nowMillis: Int64(Date().timeIntervalSince1970 * 1000))
            SyncMapping.apply(r.changedLocally, purge: r.purgeLocally, to: &fresh)
        }
        XCTAssertEqual(fresh.tasks.count, 1)
    }

    func testListsAndStarterLists() {
        var db = Database()
        let l = ops.createList("Errands", color: 0xFF00897B, icon: "shopping", in: &db)
        let t = ops.create(TaskDraft(title: "Bread", listId: l), in: &db)
        ops.deleteList(l, in: &db)
        XCTAssertNil(db.tasks.find(t)!.listId)
        ops.addStarterLists(["work", "study"], in: &db)
        ops.addStarterLists(["work"], in: &db)
        XCTAssertEqual(AppData(db).lists.map(\.name).sorted(), ["Study", "Work"])
    }
}
