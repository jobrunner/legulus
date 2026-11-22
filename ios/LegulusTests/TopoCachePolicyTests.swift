@testable import Legulus
import XCTest

final class TopoCachePolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// After a failure the tile server is left alone for a while; the
    /// Apple map stands in at once instead of after the deadline.
    func testFailureGate_BlocksForTheCooldown() {
        var gate = TopoFailureGate(cooldown: 300)
        XCTAssertTrue(gate.allows(at: t0))
        gate.recordFailure(at: t0)
        XCTAssertFalse(gate.allows(at: t0.addingTimeInterval(299)))
        XCTAssertTrue(gate.allows(at: t0.addingTimeInterval(300)))
    }

    func testFailureGate_SuccessClears() {
        var gate = TopoFailureGate(cooldown: 300)
        gate.recordFailure(at: t0)
        gate.recordSuccess()
        XCTAssertTrue(gate.allows(at: t0.addingTimeInterval(1)))
    }

    /// The least recently used files go until the rest fits the limit.
    func testPrune_DropsOldestUntilUnderLimit() {
        let entries = [
            TopoCacheEntry(name: "new", size: 400, used: t0.addingTimeInterval(30)),
            TopoCacheEntry(name: "old", size: 400, used: t0),
            TopoCacheEntry(name: "mid", size: 400, used: t0.addingTimeInterval(10))
        ]
        XCTAssertEqual(TopoCacheEntry.toDelete(entries, limit: 900), ["old"])
        XCTAssertEqual(TopoCacheEntry.toDelete(entries, limit: 400), ["old", "mid"])
        XCTAssertEqual(TopoCacheEntry.toDelete(entries, limit: 2000), [])
    }
}
