import GRDB
@testable import Legulus
import XCTest

/// Pins `v20_sample_conditions`: `local_samples` gets the weather,
/// climate and astronomy values of a sample as one JSON column. Samples
/// from before have none.
final class DatabaseMigrationV20Tests: XCTestCase {
    func testMigration_AddsConditionsAndKeepsRows() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue, upTo: "v19_photo_attempts")
        let columnsBefore = try queue.read { try $0.columns(in: "local_samples").map(\.name) }
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO local_samples
              (id, sample_id, user_id, collecting_day, latitude, longitude, begin_date, is_all_day, timezone,
               notes, marked, location_source, version, sync_status, created_at, updated_at)
            VALUES ('s1', '260519/1', 'u1', '2026-05-19', 49.79, 9.94, '2026-05-19 12:00:00.000', 0,
                    'Europe/Berlin', '', 0, 0, 1, 'synced', '2026-05-19 12:00:00.000', '2026-05-19 12:00:00.000')
            """)
        }

        try Database.makeMigrator().migrate(queue)

        try queue.read { db in
            let columns = try db.columns(in: "local_samples").map(\.name)
            XCTAssertEqual(Array(columns.prefix(columnsBefore.count)), columnsBefore)
            XCTAssertTrue(columns.contains("conditions"))
            let sample = try XCTUnwrap(LocalSample.fetchOne(db, key: "s1"))
            XCTAssertNil(sample.conditions, "a sample from before has never been processed")
            XCTAssertEqual(sample.sampleID, "260519/1")
        }
    }
}
