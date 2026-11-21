@testable import Legulus
import LegulusGeo
import XCTest

/// Phase O2 sync: placemark → sample → features on push, merging
/// server enrichment without losing local data, and hydrating
/// placemarks + features of samples the backend enriched.
@MainActor
final class SyncRunnerOrtusTests: XCTestCase {
    private var database: Database!
    private var store: LocalSampleStore!
    private var mutations: PendingMutationsStore!
    private var placemarks: LocalPlacemarkStore!
    private var features: LocalSampleFeatureStore!
    private var log: CallLog!
    // swiftlint:disable:next force_unwrapping
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    private let place = Place(
        countryISO: "DE",
        admin: [
            .country: AdminValue(name: "Deutschland", level: 2),
            .state: AdminValue(name: "Bayern", level: 4),
            .municipality: AdminValue(name: "Ochsenfurt", level: 8)
        ]
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: ())
        store = LocalSampleStore(database: database, userId: "u1", timeZone: berlin, settings: { SampleIDSettings(cutoffHour: 5) })
        mutations = PendingMutationsStore(database: database)
        placemarks = LocalPlacemarkStore(database: database)
        features = LocalSampleFeatureStore(database: database)
        log = CallLog()
    }

    override func tearDownWithError() throws {
        store = nil
        mutations = nil
        placemarks = nil
        features = nil
        database = nil
        log = nil
        try super.tearDownWithError()
    }

    // MARK: - create

    func testCreate_ResolvesPlacemarkThenCreatesThenPutsFeatures() async throws {
        let sample = try seedResolvedSample()
        let localPlacemarkID = try XCTUnwrap(sample.placemark)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     placemark: "pmbackend00001", elevation: 250, elevationSource: "location_service")
        let pm = MockPlacemarks(log: log)
        pm.resolveResponse = remotePlacemark(id: "pmbackend00001")
        let fx = MockFeatures(log: log)

        await runUntilQuiescent(makeRunner(push: push, placemarks: pm, features: fx))

        XCTAssertEqual(log.calls, ["resolve", "create", "features"])
        XCTAssertEqual(pm.resolved.first?.source, .backendService)
        XCTAssertEqual(pm.resolved.first?.place, place)

        let sent = try XCTUnwrap(push.lastCreate)
        XCTAssertEqual(sent.location.placemark, "pmbackend00001", "backend id, never the local UUID")
        XCTAssertEqual(sent.location.locationStatus, .backendService)
        XCTAssertEqual(sent.location.elevation, 250)
        XCTAssertEqual(sent.location.elevationSource, .locationService)
        XCTAssertEqual(sent.location.locationSource, .locationService)
        XCTAssertEqual(sent.location.mtbSheetNumber, "6326")
        XCTAssertEqual(sent.location.mtbQuadrant, 1)
        XCTAssertEqual(sent.location.wireBody["placemark"] as? String, "pmbackend00001")

        XCTAssertEqual(fx.replaced.first?.sampleBackendID, "backend-1")
        XCTAssertEqual(fx.replaced.first?.features.count, 2)

        let row = try XCTUnwrap(placemarks.fetchById(localPlacemarkID))
        XCTAssertEqual(row.backendId, "pmbackend00001", "backend id remembered on the local row")
        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.placemark, localPlacemarkID, "local reference stays the local row")
        XCTAssertEqual(stored.syncStatus, .synced)
        XCTAssertEqual(stored.backendId, "backend-1")
    }

    func testCreate_AlreadyResolvedPlacemarkIsNotResolvedAgain() async throws {
        let sample = try seedResolvedSample()
        try placemarks.setBackend(localID: XCTUnwrap(sample.placemark), backendID: "pmbackend00001", owner: nil)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service")
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertEqual(log.calls, ["create", "features"])
        XCTAssertEqual(push.lastCreate?.location.placemark, "pmbackend00001")
    }

    func testCreate_ManualPlacemarkResolvedAsOwnManualRow() async throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let manual = try placemarks.lookupOrCreate(place: place, source: .manual)
        sample.placemark = manual.id
        sample.locationStatus = .manual
        try store.update(sample)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual")
        let pm = MockPlacemarks(log: log)
        pm.resolveResponse = remotePlacemark(id: "pmmanual000001", source: "manual", owner: "u1")
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm))

        XCTAssertEqual(pm.resolved.first?.source, .manual)
        XCTAssertEqual(push.lastCreate?.location.placemark, "pmmanual000001")
        XCTAssertEqual(push.lastCreate?.location.locationStatus, .manual)
        XCTAssertEqual(try placemarks.fetchById(manual.id)?.owner, "u1")
    }

    func testCreate_UnknownLocalPlacemarkUUID_IsNotSentAndStatusFallsBackToPending() async throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        sample.placemark = UUID().uuidString
        sample.locationStatus = .inherited
        try store.update(sample)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertNil(push.lastCreate?.location.placemark)
        XCTAssertEqual(push.lastCreate?.location.locationStatus, .pending,
                       "without its placemark the backend must enrich the sample itself")
    }

    func testCreate_KeepsLocalLocalityWhenServerReturnsNone() async throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        sample.locality = "locbackend0001"
        try store.update(sample)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertEqual(push.lastCreate?.location.locality, "locbackend0001")
        XCTAssertEqual(try store.fetchById(sample.id)?.locality, "locbackend0001")
    }

    func testCreate_ClientLocalityUUIDIsNotSent() async throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        sample.locality = UUID().uuidString
        try store.update(sample)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertNil(push.lastCreate?.location.locality)
    }

    func testCreate_ManualHeightStaysManual() async throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14),
                                           locationSource: .user)
        sample.elevation = 512
        sample.elevationSource = .manual
        try store.update(sample)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID,
                                     elevation: 512, elevationSource: "manual")
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertEqual(push.lastCreate?.location.elevationSource, .manual)
        XCTAssertEqual(push.lastCreate?.location.wireBody["elevation_source"] as? String, "manual")
        XCTAssertEqual(push.lastCreate?.location.locationSource, .user)
        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.elevationSource, .manual)
        XCTAssertEqual(stored.elevation, 512)
    }

    func testCreate_ServerWithoutEnrichment_KeepsLocalMTBAndGeo() async throws {
        let sample = try seedResolvedSample()
        try placemarks.setBackend(localID: XCTUnwrap(sample.placemark), backendID: "pmbackend00001", owner: nil)

        let push = MockPush(log: log)
        // Server echo without geo columns (e.g. older server build).
        push.createResponse = remote(id: "backend-1", code: sample.sampleID)
        await runUntilQuiescent(makeRunner(push: push))

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.mtbSheetNumber, "6326")
        XCTAssertEqual(stored.mtbSheetName, "Ochsenfurt")
        XCTAssertEqual(stored.mtbQuadrant, 1)
        XCTAssertEqual(stored.bearingLabel, "Ochsenfurt")
        XCTAssertEqual(stored.locationStatus, .backendService)
        XCTAssertEqual(stored.placemark, sample.placemark)
    }

    func testCreate_EditDuringPost_IsKeptAndQueuedAsUpdate() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID)
        // The on-device resolver lands while the POST is in flight.
        push.duringCreate = { [store] in
            guard var row = try? store?.fetchById(sample.id) else { return }
            row.mtbSheetNumber = "6326"
            row.locationStatus = .inherited
            row.placemark = "pminherited001"
            try? store?.update(row)
        }
        await runUntilQuiescent(makeRunner(push: push))

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.mtbSheetNumber, "6326", "stale pre-POST copy must not overwrite")
        XCTAssertEqual(stored.locationStatus, .inherited)
        XCTAssertEqual(stored.placemark, "pminherited001")
        XCTAssertEqual(stored.backendId, "backend-1")
        let updates = try mutations.fetch(entityType: .sample).filter { $0.op == .update }
        XCTAssertEqual(updates.map(\.entityId), [sample.id], "missed edit goes out as update")
    }

    /// The server answered a repeated create with the sample it stored
    /// on the first attempt and did not apply this request's body. What
    /// changed locally between the attempts is not on the server, so
    /// the row goes out once more as an update.
    func testCreate_Replay_QueuesUpdateWithTheLocalState() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let push = MockPush(log: log)
        var replayed = remote(id: "backend-1", code: sample.sampleID)
        replayed.isReplay = true
        push.createResponse = replayed
        await runUntilQuiescent(makeRunner(push: push))

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.backendId, "backend-1")
        let updates = try mutations.fetch(entityType: .sample).filter { $0.op == .update }
        XCTAssertEqual(updates.map(\.entityId), [sample.id], "the local state goes out as an update")
    }

    /// The replay carries the state of the first attempt. A code the
    /// user changed since then is not a reassignment by the server: it
    /// stays, and the follow-up PATCH sends it.
    func testCreate_Replay_KeepsCodeEditedBetweenTheAttempts() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let firstCode = sample.sampleID
        var row = try XCTUnwrap(store.fetchById(sample.id))
        row.sampleID = "260519/77"
        try store.update(row)
        let push = MockPush(log: log)
        var replayed = remote(id: "backend-1", code: firstCode)
        replayed.isReplay = true
        push.createResponse = replayed
        push.updateResponse = remote(id: "backend-1", code: "260519/77", version: 2)
        let runner = makeRunner(push: push)
        await runUntilQuiescent(runner)

        XCTAssertEqual(try store.fetchById(sample.id)?.sampleID, "260519/77")
        await runUntilQuiescent(runner)
        XCTAssertEqual(push.lastUpdate?.code, "260519/77")
    }

    /// The first attempt ran into a code collision and the server
    /// suffixed the code. The local row still holds what was sent
    /// then, so the reassignment is taken over as after a normal create.
    func testCreate_Replay_AdoptsServerReassignmentOfTheFirstAttempt() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let push = MockPush(log: log)
        var replayed = remote(id: "backend-1", code: sample.sampleID + " (2)", originalCode: sample.sampleID)
        replayed.isReplay = true
        push.createResponse = replayed
        await runUntilQuiescent(makeRunner(push: push))

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.sampleID, sample.sampleID + " (2)")
        XCTAssertEqual(stored.originalCode, sample.sampleID)
    }

    /// Edits made while the sample had no backend id queued nothing of
    /// their own. The follow-up PATCH of a replay has to carry them:
    /// the star, and values the user removed.
    func testCreate_Replay_FollowUpCarriesStarAndClears() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        var row = try XCTUnwrap(store.fetchById(sample.id))
        row.marked = true
        row.horizontalAccuracy = nil
        try store.update(row)
        let push = MockPush(log: log)
        var replayed = remote(id: "backend-1", code: sample.sampleID, horizontalAccuracy: 5)
        replayed.isReplay = true
        push.createResponse = replayed
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, version: 2)
        let runner = makeRunner(push: push)
        await runUntilQuiescent(runner)
        await runUntilQuiescent(runner)

        let update = try XCTUnwrap(push.lastUpdate)
        XCTAssertEqual(update.marked, true)
        XCTAssertTrue(update.location.clearsHorizontalAccuracy)
    }

    func testAfterReplayPayload_OnlyFlagsWhatDiffers() throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let same = SampleUpdatePayload.afterReplay(
            local: sample, server: remote(id: "backend-1", code: sample.sampleID), hasLocalFeatures: false
        )
        XCTAssertEqual(same, SampleUpdatePayload())

        let moved = SampleUpdatePayload.afterReplay(
            local: sample, server: remote(id: "backend-1", code: sample.sampleID, lat: 48.0), hasLocalFeatures: false
        )
        XCTAssertTrue(moved.coordinateChanged)
    }

    /// The server model reads a coordinate component of 0 as missing.
    /// A point on the equator or the prime meridian has not moved for
    /// that reason.
    func testAfterReplayPayload_ZeroCoordinateIsNotAMove() throws {
        let sample = try store.createLocal(lat: 0, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let server = remote(id: "backend-1", code: sample.sampleID, lat: 0)
        XCTAssertNil(server.latitude, "Vorbedingung: 0 wird als fehlend gelesen")
        XCTAssertFalse(
            SampleUpdatePayload.afterReplay(local: sample, server: server, hasLocalFeatures: false).coordinateChanged
        )
    }

    /// Without a local feature set the follow-up must not replace the
    /// server's: that would delete features the backend added after the
    /// first attempt.
    func testAfterReplayPayload_PushesFeaturesOnlyWhenTheDeviceHasSome() throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let server = remote(id: "backend-1", code: sample.sampleID)
        XCTAssertFalse(SampleUpdatePayload.afterReplay(local: sample, server: server, hasLocalFeatures: false).pushFeatures)
        XCTAssertTrue(SampleUpdatePayload.afterReplay(local: sample, server: server, hasLocalFeatures: true).pushFeatures)
    }

    /// The backend wrote a DEM height with its accuracy after the first
    /// attempt. A height the user entered by hand since then has no
    /// accuracy: the DEM's must not stay attached to it. While the
    /// device has no height of its own, the DEM accuracy is not the
    /// user's to clear.
    func testAfterReplayPayload_ManualHeightClearsTheDEMAccuracy() throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        sample.elevation = nil
        sample.elevationSource = nil
        sample.verticalAccuracy = nil
        let server = remote(
            id: "backend-1", code: sample.sampleID,
            elevation: 236, elevationSource: "backend_service", verticalAccuracy: 5
        )
        XCTAssertFalse(
            SampleUpdatePayload.afterReplay(local: sample, server: server, hasLocalFeatures: false).elevationEdited
        )

        sample.elevation = 120
        sample.elevationSource = .manual
        XCTAssertTrue(
            SampleUpdatePayload.afterReplay(local: sample, server: server, hasLocalFeatures: false).elevationEdited
        )
    }

    func testCreate_NoReplay_QueuesNoUpdate() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID)
        await runUntilQuiescent(makeRunner(push: push))

        let updates = try mutations.fetch(entityType: .sample).filter { $0.op == .update }
        XCTAssertTrue(updates.isEmpty)
    }

    func testCreate_RowDeletedDuringPost_QueuesServerDelete() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID)
        push.duringCreate = { [store, mutations] in
            guard let store, let mutations else { return }
            try? store.deleteSample(id: sample.id, mutationsStore: mutations)
        }
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertNil(try store.fetchById(sample.id), "no resurrection")
        let deletes = try mutations.fetch(entityType: .sample).filter { $0.op == .delete }
        XCTAssertEqual(deletes.map(\.entityId), ["backend-1"])
        XCTAssertTrue(try mutations.fetch(entityType: .sample).filter { $0.op == .create }.isEmpty)
    }

    func testCreate_FeaturesPutFails_QueuesFeatureUpdate() async throws {
        let sample = try seedResolvedSample()
        try placemarks.setBackend(localID: XCTUnwrap(sample.placemark), backendID: "pmbackend00001", owner: nil)
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service")
        let fx = MockFeatures(log: log)
        fx.replaceError = SampleClientError.http(status: 500, body: "")
        await runUntilQuiescent(makeRunner(push: push, features: fx))

        let update = try XCTUnwrap(mutations.fetch(entityType: .sample).first { $0.op == .update })
        XCTAssertTrue(SampleUpdatePayload.decode(update.payloadJson).pushFeatures)
        XCTAssertEqual(try store.fetchById(sample.id)?.syncStatus, .synced)
    }

    // MARK: - update

    func testUpdate_NewCoordinate_SendsCoordinateAndPendingStatus() async throws {
        let sample = try seedSyncedSample(status: .backendService)
        try store.updateCoordinate(id: sample.id, latitude: 49.70, longitude: 10.10,
                                   mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "pending", version: 3,
                                     lat: 49.70, lon: 10.10)
        // The backend re-enriches the moved sample and bumps the version.
        push.fetchResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                    placemark: "pmbackend00002", version: 4, mtb: "6327",
                                    lat: 49.70, lon: 10.10)
        await runUntilQuiescent(makeRunner(push: push))

        let sent = try XCTUnwrap(push.lastUpdate)
        XCTAssertEqual(sent.location.latitude, 49.70)
        XCTAssertEqual(sent.location.longitude, 10.10)
        XCTAssertEqual(sent.location.locationStatus, .pending)
        XCTAssertEqual(sent.location.locationSource, .user)
        let body = sent.location.wireBody
        XCTAssertEqual(body["location_status"] as? String, "pending")
        XCTAssertEqual(body["mtb_sheet_number"] as? String, "", "old point's MTB is cleared, not re-sent")
        XCTAssertEqual(body["placemark"] as? String, "")
        XCTAssertEqual(body["bearing_inside"] as? Bool, false)

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.version, 4, "follows the enrichment bump, next edit won't 409")
        XCTAssertEqual(stored.placemark, "pmbackend00002")
        XCTAssertEqual(stored.mtbSheetNumber, "6327")
        XCTAssertEqual(stored.locationStatus, .backendService)
    }

    func testUpdateCoordinate_ClearsDerivedValuesButKeepsGPSHeight() throws {
        let sample = try seedResolvedSample()
        try store.updateCoordinate(id: sample.id, latitude: 47.0, longitude: 11.0, mutationsStore: mutations)

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertNil(stored.mtbSheetNumber)
        XCTAssertNil(stored.mtbSheetName)
        XCTAssertNil(stored.mtbQuadrant)
        XCTAssertNil(stored.bearingLabel)
        XCTAssertFalse(stored.bearingInside)
        XCTAssertNil(stored.placemark)
        XCTAssertEqual(stored.locationStatus, .pending)
        XCTAssertEqual(stored.elevation, 250, "GPS height is the device's own, not derived")
        XCTAssertEqual(try features.count(sampleID: sample.id, scope: .ortus), 0)
        XCTAssertEqual(try mutations.count(), 0, "unpushed row: the pending create carries it")
    }

    func testUpdateCoordinate_ManualKeepsPlacemarkAndClearsDEMHeight() throws {
        var sample = try seedResolvedSample()
        sample.locationStatus = .manual
        sample.placemarkSuggestion = "pmsuggestion01"
        sample.elevationSource = .backendService
        try store.update(sample)

        try store.updateCoordinate(id: sample.id, latitude: 47.0, longitude: 11.0, mutationsStore: mutations)

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.locationStatus, .manual)
        XCTAssertEqual(stored.placemark, sample.placemark)
        XCTAssertNil(stored.placemarkSuggestion)
        XCTAssertNil(stored.elevation)
        XCTAssertNil(stored.elevationSource)
    }

    func testUpdate_WeakLocalStatus_TakesServerEnrichmentInsteadOfReverting() async throws {
        var sample = try seedSyncedSample(status: .pending)
        sample.notes = "edit"
        try store.saveEdits(sample, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.fetchResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                    placemark: "pmbackend00001", version: 3, mtb: "6326")
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     placemark: "pmbackend00001", version: 4, mtb: "6326")
        let pm = MockPlacemarks(log: log)
        pm.fetchResponse = [remotePlacemark(id: "pmbackend00001")]
        let fx = MockFeatures(log: log)
        fx.fetchResponse = [
            RemoteSampleFeature(id: "f1", sample: "backend-1", sourceID: "wdpa", sourceName: "WDPA",
                                layer: "areas", featureID: "1", propertiesJSON: "{}", licenseJSON: nil)
        ]
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm, features: fx))

        let sent = try XCTUnwrap(push.lastUpdate)
        XCTAssertEqual(sent.location.locationStatus, .backendService, "never push pending over the enrichment")
        XCTAssertEqual(sent.location.placemark, "pmbackend00001")
        XCTAssertEqual(sent.version, 4, "server version 3 + 1")
        XCTAssertEqual(sent.notes, "edit")
        XCTAssertEqual(try features.count(sampleID: sample.id, scope: .ortus), 1, "features hydrated after enrichment")
        XCTAssertNotNil(try placemarks.fetchById("pmbackend00001"))
    }

    func testPoll_WithQueuedEdit_MergesPlaceDataSoTheEditDoesNotRevertIt() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "pending")
        push.fetchResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                    placemark: "pmbackend00001", version: 2, mtb: "6326")
        // The user edits the notes while the poll waits.
        push.duringFetch = { [store, mutations] in
            guard var row = try? store?.fetchById(sample.id), let mutations else { return }
            row.notes = "edit"
            try? store?.saveEdits(row, mutationsStore: mutations)
        }
        let runner = makeRunner(push: push)
        await runUntilQuiescent(runner)

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.locationStatus, .backendService)
        XCTAssertEqual(stored.placemark, "pmbackend00001")
        XCTAssertEqual(stored.version, 2)
        XCTAssertEqual(stored.notes, "edit")

        push.duringFetch = nil
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     placemark: "pmbackend00001", version: 3)
        try? await Task.sleep(for: .milliseconds(20))
        await runUntilQuiescent(runner)
        XCTAssertEqual(push.lastUpdate?.location.locationStatus, .backendService)
        XCTAssertEqual(push.lastUpdate?.location.placemark, "pmbackend00001")
        XCTAssertEqual(push.lastUpdate?.version, 3)
    }

    func testSaveEdits_StaleEditorSnapshotKeepsVersionAndPlaceData() throws {
        let stale = try seedSyncedSample(status: .pending)
        var merged = stale
        merged.version = 5
        merged.placemark = "pmbackend00001"
        merged.locationStatus = .backendService
        try store.update(merged)

        var edited = stale
        edited.notes = "from the editor"
        try store.saveEdits(edited, mutationsStore: mutations)
        try store.update(stale) // a whole-row write with the old counter

        let row = try XCTUnwrap(store.fetchById(stale.id))
        XCTAssertEqual(row.version, 5, "versions only move forward")
        XCTAssertEqual(try XCTUnwrap(store.fetchById(stale.id)).version, 5)
        var afterEdit = row
        afterEdit.notes = "again"
        try store.saveEdits(afterEdit, mutationsStore: mutations)
        let final = try XCTUnwrap(store.fetchById(stale.id))
        XCTAssertEqual(final.notes, "again")
        XCTAssertEqual(final.version, 5)
    }

    func testSaveEdits_WritesOnlyUserFields() throws {
        let stale = try seedSyncedSample(status: .pending)
        var merged = stale
        merged.placemark = "pmbackend00001"
        merged.locationStatus = .backendService
        merged.mtbSheetNumber = "6326"
        try store.update(merged)

        var edited = stale
        edited.notes = "from the editor"
        try store.saveEdits(edited, mutationsStore: mutations)

        let row = try XCTUnwrap(store.fetchById(stale.id))
        XCTAssertEqual(row.notes, "from the editor")
        XCTAssertEqual(row.placemark, "pmbackend00001")
        XCTAssertEqual(row.locationStatus, .backendService)
        XCTAssertEqual(row.mtbSheetNumber, "6326")
    }

    func testReconcile_FailedPushedRowIsNotReadoptedAsCreate() async throws {
        var sample = try seedSyncedSample(status: .backendService)
        sample.syncStatus = .failed
        try store.update(sample)

        let push = MockPush(log: log)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertTrue(log.calls.isEmpty)
        XCTAssertEqual(try mutations.count(), 0)
    }

    func testUpdate_NewCoordinateOnManualSample_KeepsManual() async throws {
        let sample = try seedSyncedSample(status: .manual)
        try store.updateCoordinate(id: sample.id, latitude: 49.70, longitude: 10.10,
                                   mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual", version: 3)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertEqual(push.lastUpdate?.location.locationStatus, .manual)
    }

    func testUpdate_FeaturePayload_OrderPlacemarkPatchFeatures() async throws {
        var sample = try seedSyncedSample(status: .pending)
        let local = try placemarks.lookupOrCreate(place: place, source: .backendService)
        sample.placemark = local.id
        sample.locationStatus = .backendService
        try store.update(sample)
        try features.replace(sampleID: sample.id, scope: .ortus, features: [feature("a")])
        _ = try mutations.enqueue(entityType: .sample, entityId: sample.id, op: .update,
                                  payload: SampleUpdatePayload(pushFeatures: true).encoded)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     placemark: "pmbackend00001", version: 3)
        let pm = MockPlacemarks(log: log)
        pm.resolveResponse = remotePlacemark(id: "pmbackend00001")
        let fx = MockFeatures(log: log)
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm, features: fx))

        XCTAssertEqual(log.calls, ["resolve", "update", "features"])
        XCTAssertEqual(push.lastUpdate?.location.placemark, "pmbackend00001")
        XCTAssertEqual(push.lastUpdate?.location.locationStatus, .backendService)
        XCTAssertEqual(fx.replaced.first?.features.count, 1)
        XCTAssertEqual(try mutations.count(), 0)
    }

    /// The Ortus push replaces the Ortus rows of the server only: it
    /// goes out under its scope and without the weather features.
    func testUpdate_FeaturePushIsScopedToOrtus() async throws {
        var sample = try seedSyncedSample(status: .backendService)
        sample.placemark = "pmbackend00001"
        try store.update(sample)
        try features.replace(sampleID: sample.id, scope: .ortus, features: [feature("a")])
        try features.replace(sampleID: sample.id, scope: .tempus, features: [tempusFeature("sun")])
        _ = try mutations.enqueue(entityType: .sample, entityId: sample.id, op: .update,
                                  payload: SampleUpdatePayload(pushFeatures: true).encoded)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     placemark: "pmbackend00001", version: 3)
        let fx = MockFeatures(log: log)
        await runUntilQuiescent(makeRunner(push: push, features: fx))

        XCTAssertEqual(fx.scopes, [.ortus])
        XCTAssertEqual(fx.replaced.first?.features.map(\.sourceID), ["wdpa"])
        XCTAssertEqual(try features.count(sampleID: sample.id, scope: .tempus), 1, "the local weather rows stay")
    }

    /// Weather features on the device must not make the hydration think
    /// the Ortus features are there already, and what it stores are the
    /// Ortus rows only.
    func testHydration_OrtusFeaturesArriveDespiteLocalWeatherFeatures() async throws {
        let sample = try seedSyncedSample(status: .pending)
        try features.replace(sampleID: sample.id, scope: .tempus, features: [tempusFeature("sun")])

        let list = MockList()
        list.items = [remote(id: "backend-1", code: sample.sampleID, clientUuid: sample.id,
                             status: "backend_service", placemark: "pmbackend00001", version: 2)]
        let pm = MockPlacemarks(log: log)
        pm.fetchResponse = [remotePlacemark(id: "pmbackend00001")]
        let fx = MockFeatures(log: log)
        fx.fetchResponse = [
            RemoteSampleFeature(id: "f1", sample: "backend-1", sourceID: "wdpa", sourceName: "WDPA",
                                layer: "areas", featureID: "1", propertiesJSON: "{}", licenseJSON: nil),
            RemoteSampleFeature(id: "f2", sample: "backend-1", sourceID: "tempus:moon", sourceName: "Tempus",
                                layer: "moon", featureID: "", propertiesJSON: "{}", licenseJSON: "{\"name\":\"x\"}")
        ]
        let hydrator = SamplesHydrator(
            store: store, placemarks: placemarks, features: features,
            endpointProvider: { "http://test.invalid" },
            clientFactory: { _, _ in list },
            placemarkClientFactory: { _, _ in pm },
            featuresClientFactory: { _, _ in fx }
        )
        await hydrator.pull()

        XCTAssertEqual(try features.all(sampleID: sample.id, scope: .ortus).map(\.featureID), ["1"])
        XCTAssertEqual(try features.all(sampleID: sample.id, scope: .tempus).map(\.layer), ["sun"],
                       "the Ortus hydration leaves the weather rows alone")
    }

    func testUpdate_PlainEdit_DoesNotPutFeatures() async throws {
        var sample = try seedSyncedSample(status: .backendService)
        try features.replace(sampleID: sample.id, scope: .ortus, features: [feature("a")])
        sample.notes = "edit"
        try store.saveEdits(sample, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, version: 3)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertEqual(log.calls, ["update"])
    }

    // MARK: - Task 17 place edits on the wire

    func testUpdate_DismissedSuggestion_SendsExplicitEmptyRelation() async throws {
        var sample = try seedSyncedSample(status: .manual)
        sample.placemark = "pmmanual000001"
        sample.placemarkSuggestion = "pmsuggestion01"
        try store.update(sample)
        try store.dismissPlacemarkSuggestion(id: sample.id, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual",
                                     placemark: "pmmanual000001", version: 3)
        await runUntilQuiescent(makeRunner(push: push))

        let body = try XCTUnwrap(push.lastUpdate?.location.wireBody)
        XCTAssertEqual(body["placemark_suggestion"] as? String, "", "server must drop its suggestion too")
        XCTAssertEqual(body["placemark"] as? String, "pmmanual000001")
        XCTAssertEqual(body["location_status"] as? String, "manual")
        XCTAssertNil(body["mtb_sheet_number"], "no coordinate clears on a suggestion clear")
        XCTAssertNil(try store.fetchById(sample.id)?.placemarkSuggestion)
    }

    func testUpdate_PlainEdit_DoesNotClearSuggestion() async throws {
        var sample = try seedSyncedSample(status: .manual)
        sample.placemark = "pmmanual000001"
        try store.update(sample)
        sample.notes = "edit"
        try store.saveEdits(sample, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual", version: 3)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertNil(push.lastUpdate?.location.wireBody["placemark_suggestion"])
    }

    func testUpdate_AcceptedLocalSuggestion_IsResolvedAndSentAsPlacemark() async throws {
        let pmRow = try placemarks.lookupOrCreate(place: place, source: .backendService)
        var sample = try seedSyncedSample(status: .manual)
        sample.placemark = "pmmanual000001"
        sample.placemarkSuggestion = pmRow.id
        try store.update(sample)
        try store.acceptPlacemarkSuggestion(id: sample.id, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     placemark: "pmbackend00001", version: 3)
        let pm = MockPlacemarks(log: log)
        pm.resolveResponse = remotePlacemark(id: "pmbackend00001")
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm))

        let body = try XCTUnwrap(push.lastUpdate?.location.wireBody)
        XCTAssertEqual(body["placemark"] as? String, "pmbackend00001")
        XCTAssertEqual(body["placemark_suggestion"] as? String, "")
        XCTAssertEqual(body["location_status"] as? String, "backend_service")
    }

    func testUpdate_ManualPlaceFromEditor_IsResolvedAsManual() async throws {
        let sample = try seedSyncedSample(status: .backendService)
        _ = try store.setManualPlace(id: sample.id, place: place, placemarks: placemarks,
                                     mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual",
                                     placemark: "pmmanual000009", version: 3)
        let pm = MockPlacemarks(log: log)
        pm.resolveResponse = remotePlacemark(id: "pmmanual000009", source: "manual", owner: "u1")
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm))

        XCTAssertEqual(pm.resolved.first?.source, .manual)
        XCTAssertEqual(push.lastUpdate?.location.wireBody["placemark"] as? String, "pmmanual000009")
        XCTAssertEqual(push.lastUpdate?.location.locationStatus, .manual)
    }

    func testResendFailed_AfterGivingUp_PushesTheKeptEdit() async throws {
        var sample = try seedSyncedSample(status: .backendService)
        sample.notes = "kept edit"
        try store.update(sample)
        try store.setSyncState(id: sample.id, status: .failed, error: "Konflikt")
        try store.resendFailed(id: sample.id, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service", version: 3)
        await runUntilQuiescent(makeRunner(push: push))

        XCTAssertEqual(push.lastUpdate?.notes, "kept edit")
        XCTAssertEqual(try store.fetchById(sample.id)?.syncStatus, .synced)
        XCTAssertEqual(try mutations.count(), 0)
    }

    // MARK: - Task 17 fix round 1: edits during the round trip (I1)

    func testUpdate_DismissDuringPatch_ResponseDoesNotRestoreSuggestion() async throws {
        var sample = try seedSyncedSample(status: .manual)
        sample.placemark = "pmmanual000001"
        sample.placemarkSuggestion = "pmsuggestion01"
        try store.update(sample)
        sample.notes = "edit"
        try store.saveEdits(sample, mutationsStore: mutations)

        let push = MockPush(log: log)
        // The first PATCH (notes) echoes the server's suggestion.
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual",
                                     placemark: "pmmanual000001", suggestion: "pmsuggestion01", version: 3)
        push.duringUpdate = { [store, mutations] in
            guard let store, let mutations else { return }
            // The user taps „Verwerfen“ while the PATCH is in flight.
            try? store.dismissPlacemarkSuggestion(id: sample.id, mutationsStore: mutations)
            push.duringUpdate = nil
            push.updateResponse = self.remote(id: "backend-1", code: sample.sampleID, status: "manual",
                                              placemark: "pmmanual000001", version: 4)
        }
        await runUntilOutboxEmpty(makeRunner(push: push))

        XCTAssertEqual(push.updateCount, 2, "notes PATCH, then the queued dismiss")
        XCTAssertEqual(push.lastUpdate?.location.wireBody["placemark_suggestion"] as? String, "",
                       "the dismiss still sends the clear")
        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertNil(stored.placemarkSuggestion, "the in-flight response must not bring it back")
        XCTAssertEqual(try mutations.count(), 0)
    }

    func testUpdate_ManualPlaceDuringPatch_IsNotReverted() async throws {
        var sample = try seedSyncedSample(status: .backendService)
        sample.placemark = "pmbackend00001"
        try store.update(sample)
        sample.notes = "edit"
        try store.saveEdits(sample, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     placemark: "pmbackend00001", version: 3)
        let pm = MockPlacemarks(log: log)
        pm.resolveResponse = remotePlacemark(id: "pmmanual000009", source: "manual", owner: "u1")
        var manualID = ""
        push.duringUpdate = { [store, placemarks, mutations, place] in
            guard let store, let placemarks, let mutations else { return }
            manualID = (try? store.setManualPlace(id: sample.id, place: place, placemarks: placemarks,
                                                  mutationsStore: mutations))?.id ?? ""
            push.duringUpdate = nil
            push.updateResponse = self.remote(id: "backend-1", code: sample.sampleID, status: "manual",
                                              placemark: "pmmanual000009", version: 4)
        }
        await runUntilOutboxEmpty(makeRunner(push: push, placemarks: pm))

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.locationStatus, .manual, "the response of the older PATCH must not revert it")
        XCTAssertEqual(stored.placemark, manualID)
        XCTAssertEqual(push.lastUpdate?.location.locationStatus, .manual)
        XCTAssertEqual(push.lastUpdate?.location.wireBody["placemark"] as? String, "pmmanual000009")
    }

    func testCreate_ManualPlaceDuringPost_IsNotReverted() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     placemark: "pmbackend00001")
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual",
                                     placemark: "pmmanual000009", version: 2)
        let pm = MockPlacemarks(log: log)
        pm.resolveResponse = remotePlacemark(id: "pmmanual000009", source: "manual", owner: "u1")
        var manualID = ""
        push.duringCreate = { [store, placemarks, mutations, place] in
            guard let store, let placemarks, let mutations else { return }
            manualID = (try? store.setManualPlace(id: sample.id, place: place, placemarks: placemarks,
                                                  mutationsStore: mutations))?.id ?? ""
        }
        await runUntilOutboxEmpty(makeRunner(push: push, placemarks: pm))

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.backendId, "backend-1")
        XCTAssertEqual(stored.locationStatus, .manual)
        XCTAssertEqual(stored.placemark, manualID)
        XCTAssertEqual(push.lastUpdate?.location.locationStatus, .manual, "missed edit pushed as update")
    }

    // MARK: - Task 17 fix round 1: parked mutations after the 409 give-up (I2)

    func testGiveUp_ParksMutationWithFlags_AndResendSendsTheClear() async throws {
        var sample = try seedSyncedSample(status: .manual)
        sample.placemark = "pmmanual000001"
        sample.placemarkSuggestion = "pmsuggestion01"
        try store.update(sample)
        try store.dismissPlacemarkSuggestion(id: sample.id, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateError = SampleClientError.conflict(currentVersion: 9, body: "")
        push.fetchResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual",
                                    placemark: "pmmanual000001", suggestion: "pmsuggestion01", version: 9)
        let runner = makeRunner(push: push)
        await runUntilOutboxEmpty(runner)
        await runUntilQuiescent(runner)

        XCTAssertEqual(push.updateCount, SyncRunner.maxConflictAttempts * 2, "no automatic retry once parked")
        let parked = try XCTUnwrap(mutations.fetch(entityType: .sample).first)
        XCTAssertTrue(parked.isParked)
        XCTAssertTrue(SampleUpdatePayload.decode(parked.payloadJson).clearsSuggestion, "flags survive")
        XCTAssertEqual(try store.fetchById(sample.id)?.syncStatus, .failed)

        // „Erneut senden“ revives exactly that mutation.
        push.updateError = nil
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual",
                                     placemark: "pmmanual000001", version: 10)
        try store.resendFailed(id: sample.id, mutationsStore: mutations)
        await runUntilOutboxEmpty(runner)

        XCTAssertEqual(push.lastUpdate?.location.wireBody["placemark_suggestion"] as? String, "")
        XCTAssertEqual(try mutations.count(), 0)
        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.syncStatus, .synced)
        XCTAssertNil(stored.placemarkSuggestion)
    }

    func testLaterUpdate_AbsorbsParkedFlags() async throws {
        var sample = try seedSyncedSample(status: .manual)
        sample.placemark = "pmmanual000001"
        try store.update(sample)
        let parked = try mutations.enqueue(entityType: .sample, entityId: sample.id, op: .update,
                                           payload: SampleUpdatePayload(clearsSuggestion: true).encoded)
        try mutations.park(parked.id, error: "409 conflict")
        sample.notes = "next edit"
        try store.saveEdits(sample, mutationsStore: mutations)

        let push = MockPush(log: log)
        push.updateResponse = remote(id: "backend-1", code: sample.sampleID, status: "manual",
                                     placemark: "pmmanual000001", version: 3)
        await runUntilOutboxEmpty(makeRunner(push: push))

        XCTAssertEqual(push.updateCount, 1)
        XCTAssertEqual(push.lastUpdate?.location.wireBody["placemark_suggestion"] as? String, "",
                       "the parked dismiss rides along with the next successful PATCH")
        XCTAssertEqual(try mutations.count(), 0, "parked row is done too")
    }

    func testParkedMutation_DoesNotBlockOtherSamples() async throws {
        let blocked = try seedSyncedSample(status: .backendService)
        let parked = try mutations.enqueue(entityType: .sample, entityId: blocked.id, op: .update, payload: Data())
        try mutations.park(parked.id, error: "409 conflict")
        let other = try store.createLocal(lat: 49.7, lon: 10.1, collectedFrom: date(2026, 5, 19, 15))

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-2", code: other.sampleID, status: "backend_service")
        await runUntilOutboxEmpty(makeRunner(push: push))

        XCTAssertEqual(push.updateCount, 0, "parked update is not retried")
        XCTAssertEqual(try store.fetchById(other.id)?.backendId, "backend-2")
        XCTAssertEqual(try mutations.count(), 1)
        XCTAssertEqual(try mutations.activeCount(), 0)
    }

    // MARK: - hydration / enrichment

    func testHydration_OfflineSampleEnrichedByBackend_GetsPlacemarkAndFeatures() async throws {
        // Saved offline, pushed as pending, enriched by the backend.
        let sample = try seedSyncedSample(status: .pending)

        let list = MockList()
        list.items = [remote(id: "backend-1", code: sample.sampleID, clientUuid: sample.id,
                             status: "backend_service", placemark: "pmbackend00001", version: 2,
                             mtb: "6326")]
        let pm = MockPlacemarks(log: log)
        pm.fetchResponse = [remotePlacemark(id: "pmbackend00001")]
        let fx = MockFeatures(log: log)
        fx.fetchResponse = [
            RemoteSampleFeature(id: "f1", sample: "backend-1", sourceID: "wdpa", sourceName: "WDPA",
                                layer: "areas", featureID: "1", propertiesJSON: "{\"name\":\"A\"}", licenseJSON: nil),
            RemoteSampleFeature(id: "f2", sample: "backend-1", sourceID: "wdpa", sourceName: "WDPA",
                                layer: "areas", featureID: "2", propertiesJSON: "{}", licenseJSON: "{\"id\":\"CC-BY\"}")
        ]
        let hydrator = SamplesHydrator(
            store: store, placemarks: placemarks, features: features,
            endpointProvider: { "http://test.invalid" },
            clientFactory: { _, _ in list },
            placemarkClientFactory: { _, _ in pm },
            featuresClientFactory: { _, _ in fx }
        )
        await hydrator.pull()

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.placemark, "pmbackend00001")
        XCTAssertEqual(stored.locationStatus, .backendService)
        XCTAssertEqual(stored.mtbSheetNumber, "6326")
        XCTAssertEqual(stored.version, 2)
        let row = try XCTUnwrap(placemarks.fetchById("pmbackend00001"))
        XCTAssertEqual(row.place, place, "Ortus columns hydrated, not blank")
        XCTAssertEqual(try features.all(sampleID: sample.id, scope: .ortus).map(\.featureID), ["1", "2"])
        XCTAssertEqual(pm.fetchedIDs, [["pmbackend00001"]])
        XCTAssertEqual(fx.fetchedIDs, [["backend-1"]])
    }

    func testHydration_PlacemarkKnownViaBackendID_MapsToLocalRowAndKeepsOrtusColumns() async throws {
        var sample = try seedSyncedSample(status: .backendService)
        let local = try placemarks.lookupOrCreate(place: place, source: .backendService)
        try placemarks.setBackend(localID: local.id, backendID: "pmbackend00001", owner: nil)
        sample.placemark = local.id
        try store.update(sample)
        try features.replace(sampleID: sample.id, scope: .ortus, features: [feature("a")])

        let list = MockList()
        list.items = [remote(id: "backend-1", code: sample.sampleID, clientUuid: sample.id,
                             status: "backend_service", placemark: "pmbackend00001", version: 2)]
        let pm = MockPlacemarks(log: log)
        let fx = MockFeatures(log: log)
        let hydrator = SamplesHydrator(
            store: store, placemarks: placemarks, features: features,
            endpointProvider: { "http://test.invalid" },
            clientFactory: { _, _ in list },
            placemarkClientFactory: { _, _ in pm },
            featuresClientFactory: { _, _ in fx }
        )
        await hydrator.pull()

        XCTAssertEqual(try store.fetchById(sample.id)?.placemark, local.id)
        XCTAssertTrue(pm.fetchedIDs.isEmpty, "known placemark is not fetched again")
        XCTAssertTrue(fx.fetchedIDs.isEmpty, "local features present → no fetch")
        XCTAssertEqual(try placemarks.count(), 1)
    }

    func testHydration_DirtyRowIsNotOverwritten() async throws {
        var sample = try seedSyncedSample(status: .pending)
        sample.notes = "local edit"
        try store.saveEdits(sample, mutationsStore: mutations)

        let list = MockList()
        list.items = [remote(id: "backend-1", code: sample.sampleID, clientUuid: sample.id,
                             status: "backend_service", placemark: "pmbackend00001", version: 5)]
        let hydrator = SamplesHydrator(
            store: store, endpointProvider: { "http://test.invalid" },
            clientFactory: { _, _ in list }
        )
        await hydrator.pull()

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.notes, "local edit")
        XCTAssertEqual(stored.locationStatus, .pending)
    }

    func testHydration_KeepsClientLocalityWhoseLocalityPushIsPending() async throws {
        var sample = try seedSyncedSample(status: .backendService)
        let clientLocality = UUID().uuidString
        sample.locality = clientLocality
        try store.update(sample)

        let list = MockList()
        list.items = [remote(id: "backend-1", code: sample.sampleID, clientUuid: sample.id,
                             status: "backend_service", version: 2)]
        let hydrator = SamplesHydrator(store: store, endpointProvider: { "http://test.invalid" },
                                       clientFactory: { _, _ in list })
        await hydrator.pull()

        XCTAssertEqual(try store.fetchById(sample.id)?.locality, clientLocality)
    }

    func testHydration_OlderSnapshotThanLocalIsIgnored() async throws {
        var sample = try seedSyncedSample(status: .backendService)
        sample.version = 5
        sample.notes = "pushed edit"
        try store.update(sample)

        let list = MockList()
        list.items = [remote(id: "backend-1", code: sample.sampleID, clientUuid: sample.id,
                             status: "backend_service", version: 3)]
        let hydrator = SamplesHydrator(store: store, endpointProvider: { "http://test.invalid" },
                                       clientFactory: { _, _ in list })
        await hydrator.pull()

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.version, 5)
        XCTAssertEqual(stored.notes, "pushed edit")
    }

    func testUpsertPlacemark_ServerRowWithoutOrtusColumns_DoesNotBlankLocal() throws {
        let local = try placemarks.lookupOrCreate(place: place, source: .backendService)
        try placemarks.setBackend(localID: local.id, backendID: "pmbackend00001", owner: nil)
        try placemarks.upsert(remotePlacemark(id: "pmbackend00001", withPlace: false))

        let row = try XCTUnwrap(placemarks.fetchById(local.id))
        XCTAssertEqual(row.place, place)
        XCTAssertEqual(try placemarks.count(), 1, "merged onto the local row, no duplicate")
    }

    func testPollEnrichment_OfflineSample_GetsPlacemarkAndFeatures() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "pending")
        push.fetchResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                    placemark: "pmbackend00001", version: 2, mtb: "6326")
        let pm = MockPlacemarks(log: log)
        pm.fetchResponse = [remotePlacemark(id: "pmbackend00001")]
        let fx = MockFeatures(log: log)
        fx.fetchResponse = [
            RemoteSampleFeature(id: "f1", sample: "backend-1", sourceID: "wdpa", sourceName: "WDPA",
                                layer: "areas", featureID: "1", propertiesJSON: "{}", licenseJSON: nil)
        ]
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm, features: fx))

        let stored = try XCTUnwrap(store.fetchById(sample.id))
        XCTAssertEqual(stored.placemark, "pmbackend00001")
        XCTAssertEqual(stored.locationStatus, .backendService)
        XCTAssertEqual(stored.version, 2)
        XCTAssertNotNil(try placemarks.fetchById("pmbackend00001"))
        XCTAssertEqual(try features.count(sampleID: sample.id, scope: .ortus), 1)
    }

    // MARK: - batched enrichment poll (I-2)

    /// Offline samples (status ≠ backend_service) used to wait for the
    /// server enrichment one by one inside the create path. Now every
    /// POST goes out first; one bounded poll follows the push loop.
    func testOfflineCreates_AllPostedBeforeTheFirstEnrichmentPoll() async throws {
        let samples = try (0 ..< 3).map { i in
            try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14 + i))
        }
        let push = MockPush(log: log)
        let created = createResponses(for: samples)
        push.createResponder = { created[$0.clientUuid ?? ""] }
        // Server never enriches (Ortus down): status stays pending.
        let stillPending = Dictionary(uniqueKeysWithValues: created.values.map {
            ($0.id, remote(id: $0.id, code: $0.sampleID, status: "pending"))
        })
        push.fetchResponder = { stillPending[$0] }
        let runner = makeRunner(push: push)
        await runUntilQuiescent(runner)

        XCTAssertEqual(push.createCount, 3)
        XCTAssertFalse(push.fetches.isEmpty, "enrichment is still polled")
        XCTAssertTrue(push.fetches.allSatisfy { $0.createsSoFar == 3 }, "no poll between the POSTs")
        let perID = Dictionary(grouping: push.fetches, by: \.id).mapValues(\.count)
        XCTAssertEqual(Set(perID.keys), ["backend-0", "backend-1", "backend-2"])
        XCTAssertTrue(perID.values.allSatisfy { $0 <= SyncRunner.enrichmentPollRounds }, "bounded: \(perID)")
        for sample in samples {
            XCTAssertEqual(try store.fetchById(sample.id)?.syncStatus, .synced)
        }
    }

    func testBatchedPoll_StopsPollingEnrichedSamples() async throws {
        let samples = try (0 ..< 2).map { i in
            try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14 + i))
        }
        let push = MockPush(log: log)
        let created = createResponses(for: samples)
        push.createResponder = { created[$0.clientUuid ?? ""] }
        let fetched = [
            "backend-0": remote(id: "backend-0", code: samples[0].sampleID, status: "backend_service",
                                placemark: "pmbackend00001", version: 2, mtb: "6326"),
            "backend-1": remote(id: "backend-1", code: samples[1].sampleID, status: "pending")
        ]
        push.fetchResponder = { fetched[$0] }
        let pm = MockPlacemarks(log: log)
        pm.fetchResponse = [remotePlacemark(id: "pmbackend00001")]
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm))

        XCTAssertEqual(push.fetches.filter { $0.id == "backend-0" }.count, 1, "done after the enrichment landed")
        XCTAssertEqual(push.fetches.filter { $0.id == "backend-1" }.count, SyncRunner.enrichmentPollRounds)
        let enriched = try XCTUnwrap(store.fetchById(samples[0].id))
        XCTAssertEqual(enriched.locationStatus, .backendService)
        XCTAssertEqual(enriched.placemark, "pmbackend00001")
        XCTAssertEqual(enriched.version, 2)
        XCTAssertEqual(try store.fetchById(samples[1].id)?.locationStatus, .pending)
    }

    func testBatchedPoll_RespectsTotalTimeBudget() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "pending")
        push.fetchResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service", version: 2)
        let runner = makeRunner(push: push, pollBudget: .zero)
        await runUntilQuiescent(runner)

        XCTAssertTrue(push.fetches.isEmpty, "no budget: left to the next hydration")
        XCTAssertEqual(try store.fetchById(sample.id)?.syncStatus, .synced)
    }

    // MARK: - wire format

    func testFeaturesBody_SendsPropertiesAndLicenseAsJSON() throws {
        try features.replace(sampleID: "s", scope: .ortus, features: [feature("a", license: "{\"id\":\"CC-BY\"}")])
        let body = try SampleFeaturesClient.replaceBody(features.all(sampleID: "s", scope: .ortus))
        let items = try XCTUnwrap(body["features"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["source_id"] as? String, "wdpa")
        XCTAssertEqual((items[0]["properties"] as? [String: Any])?["name"] as? String, "a")
        XCTAssertEqual((items[0]["license"] as? [String: Any])?["id"] as? String, "CC-BY")
        XCTAssertNotNil(SampleFeaturesClient.replaceBody([])["features"], "key required even when empty")
    }

    func testResolveBody_HasFlatPlaceFieldsAndSource() {
        let body = PlacemarkClient.placeBody(place, source: .backendService)
        XCTAssertEqual(body["geocoding_source"] as? String, "backend_service")
        XCTAssertEqual(body["country_iso"] as? String, "DE")
        XCTAssertEqual(body["admin_municipality"] as? String, "Ochsenfurt")
        XCTAssertEqual(body["admin_municipality_level"] as? Int, 8)
        XCTAssertEqual(body["admin_county"] as? String, "")
    }

    // MARK: - weather values (Tempus)

    private func sampleWithHeight() throws -> LocalSample {
        try store.createLocal(lat: 49.68, lon: 10.04, elevation: 250, collectedFrom: date(2026, 5, 19, 14))
    }

    /// The sync asks Tempus before it pushes a new sample: the values
    /// travel with the POST, their features follow under their scope.
    func testCreate_AsksTempusAndDeliversValuesAndFeatures() async throws {
        let sample = try sampleWithHeight()
        let push = MockPush(log: log)
        // The backend takes delivered values over and echoes them.
        push.createResponder = { [self] input in
            remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                   extra: input.conditions?.wireBody ?? [:])
        }
        let fx = MockFeatures(log: log)
        let tempus = StubTempus()
        await runUntilQuiescent(makeRunner(push: push, features: fx, tempus: tempus))

        XCTAssertEqual(tempus.queries.map(\.elevationMetres), [250])
        let sent = try XCTUnwrap(push.lastCreate?.conditions)
        XCTAssertEqual(sent.status, .final)
        XCTAssertEqual(sent.number("weather_temperature_c"), 0)
        let body = try SampleClient.createBody(XCTUnwrap(push.lastCreate))
        XCTAssertEqual(body["conditions_status"] as? String, "final")
        XCTAssertEqual(body["weather_temperature_c"] as? Double, 0)
        XCTAssertEqual(fx.scopes, [.tempus])
        XCTAssertEqual(fx.replaced.first?.features.map(\.sourceID), ["tempus:weather", "tempus:sun", "tempus:moon"])

        let stored = try XCTUnwrap(store.fetchById(sample.id)?.conditions)
        XCTAssertFalse(stored.needsPush, "delivered")
        XCTAssertEqual(stored.number("weather_temperature_c"), 0)
        XCTAssertTrue(try mutations.fetch(entityType: .sample).isEmpty)
    }

    /// The backend does not take the values over (it asks for another
    /// instant, e.g. 22:00 in a night fieldtrip) and answers with its
    /// own state. Their features must not be uploaded then, and the
    /// device follows the server.
    func testCreate_RejectedValuesUploadNoFeatures() async throws {
        let sample = try sampleWithHeight()
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     extra: ["conditions_status": "pending"])
        let fx = MockFeatures(log: log)
        await runUntilQuiescent(makeRunner(push: push, features: fx, tempus: StubTempus()))

        XCTAssertNotNil(push.lastCreate?.conditions, "delivered")
        XCTAssertTrue(fx.scopes.isEmpty, "no weather PUT for values the server did not take")
        XCTAssertEqual(try store.fetchById(sample.id)?.conditions?.status, .pending)
    }

    /// An edit lands while the placemark is resolved, after Tempus was
    /// asked: the request is built from the row as it is then, and the
    /// weather of the old height must not go out with the new one.
    func testCreate_EditBetweenTempusAndPostSendsNoStaleWeather() async throws {
        // A sample with a local placemark: the push resolves it on the
        // server first, and the edit lands during that request.
        let sample = try seedResolvedSample()
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     placemark: "pmbackend00001")
        let pm = MockPlacemarks(log: log)
        pm.resolveResponse = remotePlacemark(id: "pmbackend00001")
        pm.duringResolve = { [store] in
            guard var row = try? store?.fetchById(sample.id) else { return }
            row.elevation = 800
            try? store?.update(row)
        }
        let tempus = StubTempus()
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm, tempus: tempus))

        XCTAssertEqual(tempus.queries.map(\.elevationMetres), [250], "asked before the edit")
        XCTAssertEqual(push.lastCreate?.location.elevation, 800)
        XCTAssertNil(push.lastCreate?.conditions, "weather for 250 m must not travel with 800 m")
    }

    /// The account is left while Tempus answers: the runner stops
    /// there. No POST without a token, nothing acknowledged.
    func testCreate_SignedOutDuringTempusSendsNothing() async throws {
        let sample = try sampleWithHeight()
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service")
        let tempus = StubTempus()
        var account: String? = "user-a"
        tempus.duringQuery = { account = nil }
        let resolver = conditionsResolver(tempus)
        let runner = SyncRunner(
            store: store, mutationsStore: mutations, placemarkStore: placemarks, featureStore: features,
            endpointProvider: { "http://test.invalid" }, retryInterval: .seconds(3600),
            clientFactory: { _, _ in push },
            placemarkClientFactory: { [log] _, _ in MockPlacemarks(log: log) },
            featuresClientFactory: { [log] _, _ in MockFeatures(log: log) },
            accountProvider: { account },
            conditionsResolver: { resolver }
        )
        await runUntilQuiescent(runner)

        XCTAssertEqual(tempus.queries.count, 1)
        XCTAssertEqual(push.createCount, 0, "no request after the account was left")
        XCTAssertNil(try store.fetchById(sample.id)?.conditions, "the answer is not written either")
        XCTAssertEqual(try mutations.fetch(entityType: .sample).filter { $0.op == .create }.count, 1,
                       "the create stays queued for the next sign-in")
    }

    /// The upload of the weather features is recorded in the outbox
    /// before the request goes out: an app stopped mid-request repeats
    /// it on the next start. After a successful PUT nothing is left.
    func testCreate_WeatherFeatureUploadIsQueuedUntilItSucceeded() async throws {
        let sample = try sampleWithHeight()
        let push = MockPush(log: log)
        push.createResponder = { [self] input in
            remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                   extra: input.conditions?.wireBody ?? [:])
        }
        let fx = MockFeatures(log: log)
        var queuedDuringPut: [SampleUpdatePayload] = []
        fx.duringReplace = { [mutations] scope in
            guard scope == .tempus, let rows = try? mutations?.fetch(entityType: .sample) else { return }
            queuedDuringPut = rows.filter { $0.op == .update }.map { SampleUpdatePayload.decode($0.payloadJson) }
        }
        await runUntilQuiescent(makeRunner(push: push, features: fx, tempus: StubTempus()))

        XCTAssertEqual(queuedDuringPut, [SampleUpdatePayload(pushConditionFeatures: true)])
        XCTAssertTrue(try mutations.fetch(entityType: .sample).isEmpty, "done: nothing left to repeat")
    }

    /// The record is written together with the acknowledgement of the
    /// values, not just before the weather PUT: other requests run in
    /// between (here the Ortus features), and an app stopped during
    /// those must not lose the upload either.
    func testCreate_WeatherFeatureUploadIsQueuedBeforeAnyFurtherRequest() async throws {
        let sample = try seedResolvedSample()
        let push = MockPush(log: log)
        push.createResponder = { [self] input in
            remote(id: "backend-1", code: sample.sampleID, status: "backend_service", placemark: "pmbackend00001",
                   elevation: 250, elevationSource: "location_service", extra: input.conditions?.wireBody ?? [:])
        }
        let pm = MockPlacemarks(log: log)
        pm.resolveResponse = remotePlacemark(id: "pmbackend00001")
        let fx = MockFeatures(log: log)
        var queuedDuringOrtusPut: [SampleUpdatePayload]?
        fx.duringReplace = { [mutations] scope in
            guard scope == .ortus, let rows = try? mutations?.fetch(entityType: .sample) else { return }
            queuedDuringOrtusPut = rows.filter { $0.op == .update }.map { SampleUpdatePayload.decode($0.payloadJson) }
        }
        await runUntilQuiescent(makeRunner(push: push, placemarks: pm, features: fx, tempus: StubTempus()))

        XCTAssertEqual(fx.scopes, [.ortus, .tempus])
        XCTAssertEqual(queuedDuringOrtusPut, [SampleUpdatePayload(pushConditionFeatures: true)])
        XCTAssertTrue(try mutations.fetch(entityType: .sample).isEmpty)
    }

    /// A failed PUT leaves that record behind; the next pass repeats it.
    func testCreate_FailedWeatherFeatureUploadStaysQueued() async throws {
        let sample = try sampleWithHeight()
        let push = MockPush(log: log)
        push.createResponder = { [self] input in
            remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                   extra: input.conditions?.wireBody ?? [:])
        }
        let fx = MockFeatures(log: log)
        fx.replaceError = SampleClientError.http(status: 500, body: "")
        await runUntilQuiescent(makeRunner(push: push, features: fx, tempus: StubTempus()))

        let left = try mutations.fetch(entityType: .sample).filter { $0.op == .update }
        XCTAssertEqual(left.map { SampleUpdatePayload.decode($0.payloadJson) },
                       [SampleUpdatePayload(pushConditionFeatures: true)])
    }

    /// The device fetched values itself, then the height changed before
    /// they went out. Those values can never be delivered any more. If
    /// they kept blocking, the device would never take the server's
    /// values (nor fetch their features) while it cannot reach Tempus
    /// itself, and the area would stay at „Wird ermittelt …“.
    func testCreate_UndeliverableOwnValuesGiveWayToTheServer() async throws {
        let sample = try sampleWithHeight()
        let fetched = await conditionsResolver(StubTempus()).resolve(sampleID: sample.id)
        XCTAssertTrue(fetched)
        var moved = try XCTUnwrap(store.fetchById(sample.id))
        moved.elevation = 800
        try store.update(moved)

        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                                     extra: ["conditions_status": "pending"])
        await runUntilQuiescent(makeRunner(push: push, tempus: StubTempus(.failure(URLError(.timedOut)))))

        XCTAssertNil(push.lastCreate?.conditions, "values for 250 m do not travel with 800 m")
        let stored = try XCTUnwrap(store.fetchById(sample.id)?.conditions)
        XCTAssertEqual(stored.status, .pending, "the server's state is taken over")
        XCTAssertFalse(stored.needsPush)
        XCTAssertTrue(stored.fields.isEmpty)
    }

    /// Without a height (or with Tempus switched off) nothing is asked
    /// and nothing is sent: the backend enriches.
    func testCreate_WithoutHeightSendsNoWeather() async throws {
        let sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let push = MockPush(log: log)
        push.createResponse = remote(id: "backend-1", code: sample.sampleID, status: "backend_service")
        let fx = MockFeatures(log: log)
        let tempus = StubTempus()
        await runUntilQuiescent(makeRunner(push: push, features: fx, tempus: tempus))

        XCTAssertTrue(tempus.queries.isEmpty)
        XCTAssertNil(push.lastCreate?.conditions)
        XCTAssertNil(try SampleClient.createBody(XCTUnwrap(push.lastCreate))["conditions_status"])
        XCTAssertTrue(fx.scopes.isEmpty)
    }

    /// A Tempus failure never fails the push, and the next samples of
    /// the queue do not wait for its timeout again.
    func testCreate_TempusDownPushesWithoutWeatherAndPauses() async throws {
        let first = try sampleWithHeight()
        let second = try sampleWithHeight()
        let push = MockPush(log: log)
        push.createResponder = { [self] input in
            remote(id: "backend-" + (input.clientUuid ?? ""), code: input.code ?? "", status: "backend_service")
        }
        let tempus = StubTempus(.failure(URLError(.timedOut)))
        await runUntilQuiescent(makeRunner(push: push, tempus: tempus))

        XCTAssertEqual(push.createCount, 2)
        XCTAssertEqual(tempus.queries.count, 1, "the second sample does not ask a Tempus that just failed")
        XCTAssertEqual(try store.fetchById(first.id)?.syncStatus, .synced)
        XCTAssertEqual(try store.fetchById(second.id)?.syncStatus, .synced)
    }

    /// The height changed on a synced sample: the update asks again and
    /// carries the new values. An edit that changes nothing Tempus
    /// depends on sends no weather at all — it must not write older
    /// values over the server's.
    func testUpdate_CarriesWeatherOnlyWhenTheDeviceHasNewValues() async throws {
        var sample = try sampleWithHeight()
        sample.backendId = "backend-1"
        sample.syncStatus = .synced
        sample.locationStatus = .backendService
        try store.update(sample)
        let push = MockPush(log: log)
        push.updateResponder = { [self] input in
            remote(id: "backend-1", code: sample.sampleID, status: "backend_service",
                   elevation: 250, elevationSource: "location_service", version: input.version,
                   extra: input.conditions?.wireBody ?? [:])
        }
        let fx = MockFeatures(log: log)
        let tempus = StubTempus()
        let runner = makeRunner(push: push, features: fx, tempus: tempus)

        _ = try mutations.enqueue(entityType: .sample, entityId: sample.id, op: .update,
                                  payload: SampleUpdatePayload().encoded)
        await runUntilQuiescent(runner)
        XCTAssertEqual(push.lastUpdate?.conditions?.status, .final)
        XCTAssertEqual(try SampleClient.updateBody(XCTUnwrap(push.lastUpdate))["conditions_status"] as? String, "final")
        XCTAssertEqual(fx.scopes, [.tempus])

        var edited = try XCTUnwrap(store.fetchById(sample.id))
        edited.notes = "Eichenstubben"
        try store.update(edited)
        _ = try mutations.enqueue(entityType: .sample, entityId: sample.id, op: .update,
                                  payload: SampleUpdatePayload().encoded)
        await runUntilQuiescent(runner)
        XCTAssertNil(push.lastUpdate?.conditions)
        XCTAssertNil(try SampleClient.updateBody(XCTUnwrap(push.lastUpdate))["conditions_status"])
        XCTAssertEqual(tempus.queries.count, 1, "values that fit are not asked again")
        XCTAssertEqual(fx.scopes, [.tempus], "no second weather PUT")
    }

    private func serverConditions(status: String, temperature: Double, fetched: String) -> [String: Any] {
        [
            "conditions_status": status,
            "conditions_fields": ["weather_temperature_c"],
            "conditions_queried_for": "2026-05-19 12:00:00.000Z",
            "conditions_fetched_at": fetched,
            "weather_temperature_c": temperature,
            "elevation": 250, "elevation_source": "location_service"
        ]
    }

    /// The backend's job replaced provisional values by final ones: the
    /// pull brings them, and the weather features are fetched again
    /// although the device already has some.
    func testPull_ServerValuesReplaceLocalOnesAndRefreshTheFeatures() async throws {
        var sample = try sampleWithHeight()
        sample.backendId = "backend-1"
        sample.syncStatus = .synced
        var old = SampleConditions(status: .provisional)
        old.numbers["weather_temperature_c"] = 11
        old.queriedFor = date(2026, 5, 19, 14)
        old.fetchedAt = date(2026, 5, 19, 15)
        // The device holds the features of that answer. They were
        // written just now — later than the server's refresh below,
        // which must not hide the newer set.
        old.featuresFetchedAt = old.fetchedAt
        sample.conditions = old
        try store.update(sample)
        try features.replace(sampleID: sample.id, scope: .tempus, features: [tempusFeature("sun")])
        try features.replace(sampleID: sample.id, scope: .ortus, features: [feature("a")])

        let list = MockList()
        list.items = [remote(id: "backend-1", code: sample.sampleID, clientUuid: sample.id, version: 2,
                             extra: serverConditions(status: "final", temperature: 12.5, fetched: "2026-05-25 12:00:00.000Z"))]
        let fx = MockFeatures(log: log)
        fx.fetchResponse = [
            RemoteSampleFeature(id: "f1", sample: "backend-1", sourceID: "tempus:weather", sourceName: "Tempus",
                                layer: "weather", featureID: "", propertiesJSON: "{}", licenseJSON: "{\"name\":\"x\"}"),
            RemoteSampleFeature(id: "f2", sample: "backend-1", sourceID: "wdpa", sourceName: "WDPA",
                                layer: "areas", featureID: "9", propertiesJSON: "{}", licenseJSON: nil)
        ]
        let hydrator = SamplesHydrator(
            store: store, placemarks: placemarks, features: features,
            endpointProvider: { "http://test.invalid" },
            clientFactory: { _, _ in list },
            placemarkClientFactory: { [log] _, _ in MockPlacemarks(log: log) },
            featuresClientFactory: { _, _ in fx }
        )
        await hydrator.pull()

        let stored = try XCTUnwrap(store.fetchById(sample.id)?.conditions)
        XCTAssertEqual(stored.status, .final)
        XCTAssertEqual(stored.number("weather_temperature_c"), 12.5)
        XCTAssertEqual(stored.inputs?.elevationMetres, 250, "server values carry the server sample's height")
        XCTAssertEqual(try features.all(sampleID: sample.id, scope: .tempus).map(\.layer), ["weather"])
        XCTAssertEqual(try features.all(sampleID: sample.id, scope: .ortus).map(\.featureID), ["a"],
                       "the Ortus rows of the device stay")
        XCTAssertEqual(stored.fetchedAt, try XCTUnwrap(store.fetchById(sample.id)?.conditions?.featuresFetchedAt),
                       "the device now holds the features of the server's answer")

        // The same answer again: nothing to fetch.
        let fetchesBefore = fx.fetchedIDs.count
        await hydrator.pull()
        XCTAssertEqual(fx.fetchedIDs.count, fetchesBefore)
    }

    /// Values the device fetched itself and has not delivered yet are
    /// not replaced by an older server state.
    func testMerge_UndeliveredLocalValuesStay() throws {
        var sample = try sampleWithHeight()
        var mine = SampleConditions(status: .final)
        mine.numbers["weather_temperature_c"] = 3
        mine.queriedFor = date(2026, 5, 19, 14)
        mine.fetchedAt = date(2026, 6, 30, 12)
        mine.needsPush = true
        sample.conditions = mine
        sample.mergeServerConditions(
            remote(id: "backend-1", code: sample.sampleID, extra: ["conditions_status": "pending"]), delivered: nil
        )
        XCTAssertEqual(sample.conditions, mine)

        // Delivered: the server's state counts from now on.
        sample.mergeServerConditions(
            remote(id: "backend-1", code: sample.sampleID, extra: ["conditions_status": "pending"]), delivered: mine
        )
        XCTAssertEqual(sample.conditions, .pending, "the backend did not take the values over")

        // A server that never processed the sample changes nothing.
        sample.conditions = nil
        sample.mergeServerConditions(remote(id: "backend-1", code: sample.sampleID), delivered: nil)
        XCTAssertNil(sample.conditions)
    }

    // MARK: - helpers

    /// A local sample as the on-device resolver leaves it: local
    /// placemark (UUID, no backend id), status backend_service, MTB,
    /// bearing, GPS height and two features.
    private func seedResolvedSample() throws -> LocalSample {
        var sample = try store.createLocal(lat: 49.681616, lon: 10.039652, elevation: 250,
                                           collectedFrom: date(2026, 5, 19, 14))
        let pm = try placemarks.lookupOrCreate(place: place, source: .backendService)
        sample.placemark = pm.id
        sample.locationStatus = .backendService
        sample.mtbSheetNumber = "6326"
        sample.mtbSheetName = "Ochsenfurt"
        sample.mtbQuadrant = 1
        sample.bearingLabel = "Ochsenfurt"
        sample.bearingInside = true
        try store.update(sample)
        try features.replace(sampleID: sample.id, scope: .ortus, features: [feature("a"), feature("b")])
        // swiftlint:disable:next force_unwrapping
        return try store.fetchById(sample.id)!
    }

    private func seedSyncedSample(status: LocationStatus) throws -> LocalSample {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        sample.backendId = "backend-1"
        sample.syncStatus = .synced
        sample.version = 2
        sample.locationStatus = status
        try store.update(sample)
        // swiftlint:disable:next force_unwrapping
        return try store.fetchById(sample.id)!
    }

    /// Create responses `backend-<index>` (status pending) keyed by
    /// the local sample id (= `client_uuid`).
    private func createResponses(for samples: [LocalSample]) -> [String: Sample] {
        Dictionary(uniqueKeysWithValues: samples.enumerated().map { index, sample in
            (sample.id, remote(id: "backend-\(index)", code: sample.sampleID, clientUuid: sample.id, status: "pending"))
        })
    }

    private func feature(_ id: String, license: String? = nil) -> OrtusFeature {
        OrtusFeature(sourceID: "wdpa", sourceName: "WDPA", layer: "areas", featureID: id,
                     propertiesJSON: "{\"name\":\"\(id)\"}", licenseJSON: license)
    }

    private func tempusFeature(_ kind: String) -> OrtusFeature {
        OrtusFeature(sourceID: "tempus:" + kind, sourceName: "Tempus", layer: kind, featureID: "",
                     propertiesJSON: "{}", licenseJSON: "{\"name\":\"CC-BY 4.0\"}")
    }

    private func makeRunner(
        push: MockPush,
        placemarks pm: MockPlacemarks? = nil,
        features fx: MockFeatures? = nil,
        pollBudget: Duration = .seconds(5),
        tempus: StubTempus? = nil
    ) -> SyncRunner {
        let pm = pm ?? MockPlacemarks(log: log)
        let fx = fx ?? MockFeatures(log: log)
        return SyncRunner(
            store: store,
            mutationsStore: mutations,
            placemarkStore: placemarks,
            featureStore: features,
            endpointProvider: { "http://test.invalid" },
            retryInterval: .seconds(3600),
            enrichmentPollInterval: .milliseconds(1),
            enrichmentPollBudget: pollBudget,
            clientFactory: { _, _ in push },
            placemarkClientFactory: { _, _ in pm },
            featuresClientFactory: { _, _ in fx },
            conditionsResolver: tempus.map { stub in { [self] in self.conditionsResolver(stub) } }
        )
    }

    /// 2026-06-30 12:00 UTC: six weeks after the samples, answers are final.
    private let conditionsNow = Date(timeIntervalSince1970: 1_782_820_800)

    private func conditionsResolver(_ stub: TempusQuerying?) -> SampleConditionsResolver {
        SampleConditionsResolver(
            tempus: stub, samples: store, features: features,
            isNightFieldtrip: { _ in false }, now: { [conditionsNow] in conditionsNow }
        )
    }

    /// Passes until no active mutation is left (a mutation queued
    /// during a pass only runs in the next one).
    private func runUntilOutboxEmpty(_ runner: SyncRunner) async {
        for _ in 0 ..< 10 {
            await runUntilQuiescent(runner)
            try? await Task.sleep(for: .milliseconds(20))
            if (try? mutations.activeCount()) == 0 { return }
        }
    }

    private func runUntilQuiescent(_ runner: SyncRunner) async {
        runner.kick()
        for _ in 0 ..< 300 {
            try? await Task.sleep(for: .milliseconds(10))
            if runner.isIdleForTest { return }
        }
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        c.timeZone = berlin
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = berlin
        // swiftlint:disable:next force_unwrapping
        return cal.date(from: c)!
    }

    // MARK: - Phase Z final fixes

    func testAdoptServerZone_LocationServiceBeatsDevice() throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        XCTAssertEqual(sample.timezoneSource, .device)
        sample.adoptServerZone(remote(id: "b", code: "x", timezone: "Atlantic/Canary", timezoneSource: "location_service"))
        XCTAssertEqual(sample.timezone, "Atlantic/Canary")
        XCTAssertEqual(sample.timezoneSource, .locationService)
    }

    func testAdoptServerZone_ManualLocalWinsAndDeviceServerIsIgnored() throws {
        var manual = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        manual.timezone = "Asia/Tokyo"
        manual.timezoneSource = .manual
        manual.adoptServerZone(remote(id: "b", code: "x", timezone: "Atlantic/Canary", timezoneSource: "location_service"))
        XCTAssertEqual(manual.timezone, "Asia/Tokyo")

        var device = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        device.adoptServerZone(remote(id: "b", code: "x", timezone: "Atlantic/Canary", timezoneSource: "device"))
        XCTAssertEqual(device.timezone, "Europe/Berlin")
        XCTAssertEqual(device.timezoneSource, .device)
    }

    func testAdoptServerZone_AllDayKeepsCalendarDayAtMidnight() throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 0))
        sample.isAllDay = true
        sample.endDate = nil
        sample.adoptServerZone(remote(id: "b", code: "x", timezone: "Atlantic/Canary", timezoneSource: "location_service"))
        let canary = try XCTUnwrap(TimeZone(identifier: "Atlantic/Canary"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = canary
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: sample.beginDate)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 5, 19, 0, 0])
        XCTAssertNil(sample.endDate)
        XCTAssertEqual(sample.timezone, "Atlantic/Canary")
    }

    func testAdoptServerZone_TimedSampleKeepsInstant() throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, collectedFrom: date(2026, 5, 19, 14))
        let begin = sample.beginDate
        sample.adoptServerZone(remote(id: "b", code: "x", timezone: "Atlantic/Canary", timezoneSource: "location_service"))
        XCTAssertEqual(sample.beginDate, begin)
    }

    func testMergeServerLocation_ServerElevationClearsStaleVerticalAccuracy() throws {
        var sample = try store.createLocal(lat: 49.68, lon: 10.04, verticalAccuracy: 7, elevation: 100,
                                           collectedFrom: date(2026, 5, 19, 14))
        sample.mergeServerLocation(
            remote(id: "b", code: "x", elevation: 120, elevationSource: "location_service"),
            localPlacemarkID: { $0 }
        )
        XCTAssertEqual(sample.elevation, 120)
        XCTAssertNil(sample.verticalAccuracy, "server sent no accuracy for its elevation")
    }

    private func remote(
        id: String,
        code: String,
        clientUuid: String? = nil,
        status: String = "",
        placemark: String = "",
        suggestion: String = "",
        elevation: Double = 0,
        elevationSource: String = "",
        version: Int = 1,
        mtb: String? = nil,
        lat: Double = 49.68,
        lon: Double = 10.04,
        timezone: String = "Europe/Berlin",
        timezoneSource: String? = nil,
        verticalAccuracy: Double? = nil,
        horizontalAccuracy: Double? = nil,
        originalCode: String? = nil,
        extra: [String: Any] = [:]
    ) -> Sample {
        var dict: [String: Any] = [
            "id": id,
            "sample_id": code,
            "fieldtrip": "ft-1",
            "locality": "",
            "latitude": lat,
            "longitude": lon,
            "begin_date": "2026-05-19T12:00:00.000Z",
            "client_updated_at": "2026-05-19T12:00:00.000Z",
            "location_source": "location_service",
            "timezone": timezone,
            "version": version,
            "elevation": elevation,
            "elevation_source": elevationSource,
            "location_status": status,
            "placemark": placemark,
            "placemark_suggestion": suggestion,
            "mtb_sheet_number": mtb ?? "",
            "mtb_sheet_name": mtb == nil ? "" : "Ochsenfurt",
            "mtb_quadrant": mtb == nil ? 0 : 1,
            "slope_deg": 0,
            "aspect_deg": 0,
            "aspect_compass": "",
            "terrain_flat": false,
            "bearing_label": "",
            "bearing_distance_km": 0,
            "bearing_inside": false
        ]
        if let clientUuid { dict["client_uuid"] = clientUuid }
        if let timezoneSource { dict["timezone_source"] = timezoneSource }
        if let verticalAccuracy { dict["vertical_accuracy"] = verticalAccuracy }
        if let horizontalAccuracy { dict["horizontal_accuracy"] = horizontalAccuracy }
        if let originalCode { dict["original_code"] = originalCode }
        dict.merge(extra) { _, new in new }
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: dict)
        // swiftlint:disable:next force_try
        return try! JSONDecoder.legulus.decode(Sample.self, from: data)
    }

    private func remotePlacemark(
        id: String,
        source: String = "backend_service",
        owner: String = "",
        withPlace: Bool = true
    ) -> Placemark {
        var dict: [String: Any] = [
            "id": id,
            "country": "DE",
            "geocoding_source": source,
            "dedup_hash": place.dedupHash,
            "owner": owner
        ]
        if withPlace {
            dict["country_iso"] = "DE"
            for tier in AdminTier.allCases {
                let value = place.admin[tier]
                dict[tier.rawValue] = value?.name ?? ""
                dict["\(tier.rawValue)_native"] = value?.native ?? ""
                dict["\(tier.rawValue)_level"] = value?.level ?? 0
            }
            dict["island"] = ""
            dict["mountain_range"] = ""
            dict["mountain"] = ""
        }
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: dict)
        // swiftlint:disable:next force_try
        return try! JSONDecoder.legulus.decode(Placemark.self, from: data)
    }
}

// MARK: - Mocks

private final class CallLog: @unchecked Sendable {
    var calls: [String] = []
}

private final class MockPush: SamplePushClient, @unchecked Sendable {
    let log: CallLog
    var createResponse: Sample?
    var updateResponse: Sample?
    var fetchResponse: Sample?
    var lastCreate: SampleCreateInput?
    var lastUpdate: SampleUpdateInput?
    var duringCreate: (@MainActor () -> Void)?
    var duringFetch: (@MainActor () -> Void)?
    /// Runs while the PATCH is "in flight" (once per call).
    var duringUpdate: (@MainActor () -> Void)?
    /// Thrown by `updateSample` while set (e.g. a 409).
    var updateError: Error?
    var updateCount = 0

    init(log: CallLog) {
        self.log = log
    }

    /// Per-input create response (several samples in one pass); wins
    /// over `createResponse`.
    var createResponder: ((SampleCreateInput) -> Sample?)?
    /// Per-input update response; wins over `updateResponse`.
    var updateResponder: ((SampleUpdateInput) -> Sample?)?
    /// Per-id fetch response; wins over `fetchResponse`.
    var fetchResponder: ((String) -> Sample?)?
    var createCount = 0
    /// Every GET, with the number of POSTs that had happened by then.
    var fetches: [(id: String, createsSoFar: Int)] = []

    func createSample(_ input: SampleCreateInput) async throws -> Sample {
        log.calls.append("create")
        lastCreate = input
        createCount += 1
        if let duringCreate { await duringCreate() }
        guard let createResponse = createResponder?(input) ?? createResponse else { throw SampleClientError.http(
            status: 500,
            body: "no mock"
        ) }
        return createResponse
    }

    func updateSample(id _: String, input: SampleUpdateInput) async throws -> Sample {
        log.calls.append("update")
        lastUpdate = input
        updateCount += 1
        if let duringUpdate { await duringUpdate() }
        if let updateError { throw updateError }
        guard let response = updateResponder?(input) ?? updateResponse else {
            throw SampleClientError.http(status: 500, body: "no mock")
        }
        return response
    }

    func fetchSample(id: String) async throws -> Sample {
        fetches.append((id, createCount))
        if let duringFetch { await duringFetch() }
        if let fetchResponder {
            guard let response = fetchResponder(id) else { throw SampleClientError.http(status: 404, body: "") }
            return response
        }
        guard let response = fetchResponse ?? createResponse else {
            throw SampleClientError.http(status: 404, body: "")
        }
        return response
    }

    func deleteSample(id _: String) async throws {}
}

private final class MockPlacemarks: PlacemarkSyncClient, @unchecked Sendable {
    let log: CallLog
    var resolveResponse: Placemark?
    var fetchResponse: [Placemark] = []
    var resolved: [(place: Place, source: Placemark.GeocodingSource)] = []
    var fetchedIDs: [[String]] = []
    /// Runs while the resolve request is "in flight".
    var duringResolve: (@MainActor () -> Void)?

    init(log: CallLog) {
        self.log = log
    }

    func resolve(place: Place, source: Placemark.GeocodingSource) async throws -> Placemark {
        log.calls.append("resolve")
        resolved.append((place, source))
        if let duringResolve { await duringResolve() }
        guard let resolveResponse else { throw SampleClientError.http(status: 500, body: "no mock") }
        return resolveResponse
    }

    func fetchMany(ids: [String]) async throws -> [Placemark] {
        fetchedIDs.append(ids)
        return fetchResponse.filter { ids.contains($0.id) }
    }
}

private final class MockFeatures: SampleFeaturesSyncClient, @unchecked Sendable {
    let log: CallLog
    var replaceError: Error?
    var fetchResponse: [RemoteSampleFeature] = []
    var replaced: [(sampleBackendID: String, features: [LocalSampleFeature])] = []
    var scopes: [FeatureScope] = []
    /// Runs while a replace request is "in flight".
    var duringReplace: (@MainActor (FeatureScope) -> Void)?
    var fetchedIDs: [[String]] = []

    init(log: CallLog) {
        self.log = log
    }

    func replaceFeatures(sampleBackendID: String, scope: FeatureScope, features: [LocalSampleFeature]) async throws {
        log.calls.append("features")
        if let duringReplace { await duringReplace(scope) }
        if let replaceError { throw replaceError }
        scopes.append(scope)
        replaced.append((sampleBackendID, features))
    }

    func fetchFeatures(sampleBackendIDs: [String]) async throws -> [RemoteSampleFeature] {
        fetchedIDs.append(sampleBackendIDs)
        return fetchResponse.filter { sampleBackendIDs.contains($0.sample) }
    }
}

final class MockList: SampleListClient, @unchecked Sendable {
    var items: [Sample] = []
    /// 1-based request index that throws instead of answering.
    var failOnCall: Int?
    /// Runs before each request is answered (1-based index); lets a
    /// test rewrite rows mid-scan.
    var beforeCall: ((Int) -> Void)?
    private(set) var calls: [(updatedSince: Date?, after: (updated: Date, id: String)?, perPage: Int)] = []

    func listPage(updatedSince: Date?, after: (updated: Date, id: String)?, perPage: Int) async throws -> [Sample] {
        calls.append((updatedSince, after, perPage))
        beforeCall?(calls.count)
        if calls.count == failOnCall { throw SampleClientError.http(status: 500, body: "") }
        let sorted = items.sorted {
            let l = $0.updated ?? .distantPast, r = $1.updated ?? .distantPast
            return l == r ? $0.id < $1.id : l < r
        }
        let matching = sorted.filter { sample in
            let u = sample.updated ?? .distantPast
            if let after { return u > after.updated || (u == after.updated && sample.id > after.id) }
            if let updatedSince { return u >= updatedSince }
            return true
        }
        return Array(matching.prefix(perPage))
    }
}
