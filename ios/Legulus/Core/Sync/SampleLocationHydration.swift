import Foundation

/// Pulls the place data that server samples reference but the device
/// doesn't have yet (Phase O2):
///
/// 1. Placemarks referenced via `placemark` / `placemark_suggestion`
///    that have no local row → fetched in batches and upserted (the
///    upsert merges onto locally created rows via `backend_id`).
/// 2. Features of samples with `location_status == backend_service`
///    that have none locally (e.g. a sample saved offline and enriched
///    by the backend) → fetched in batches and stored under the local
///    sample id.
///
/// Runs after `LocalSampleStore.upsert` (hydration) and after a
/// successful enrichment poll. Failures are logged and reported via the
/// `hydrate` result; callers that keep a cursor (SamplesHydrator) must
/// not advance past a failed batch so the next run retries.
@MainActor
struct SampleLocationHydration {
    let samples: LocalSampleStore
    let placemarks: LocalPlacemarkStore
    let features: LocalSampleFeatureStore
    let placemarkClient: PlacemarkSyncClient
    let featuresClient: SampleFeaturesSyncClient

    /// Ids per list request; keeps the filter URL short.
    static let placemarkBatch = 40
    static let featureBatch = 20

    /// Returns false when any lookup or fetch failed.
    @discardableResult
    func hydrate(_ remote: [Sample]) async -> Bool {
        let placemarksOK = await hydratePlacemarks(remote)
        let featuresOK = await hydrateFeatures(remote)
        return placemarksOK && featuresOK
    }

    private func hydratePlacemarks(_ remote: [Sample]) async -> Bool {
        var ok = true
        let referenced = remote.flatMap { [$0.placemark, $0.placemarkSuggestion] }.compactMap { $0 }
        let missing: [String]
        do {
            missing = try placemarks.missingBackendIDs(referenced)
        } catch {
            Log.persistence.error("placemark lookup failed: \(error.localizedDescription)")
            return false
        }
        for batch in missing.chunked(into: Self.placemarkBatch) {
            do {
                let fetched = try await placemarkClient.fetchMany(ids: batch)
                try placemarks.upsert(fetched)
                Log.sync.info("hydrated \(fetched.count, privacy: .public) placemarks")
            } catch {
                Log.sync.warning("placemark hydrate failed: \(error.localizedDescription)")
                ok = false
            }
        }
        return ok
    }

    /// Fetches the feature sets that are missing or outdated on the
    /// device, per source:
    ///
    /// - Ortus: samples the backend resolved (`backend_service`) that
    ///   have no Ortus rows locally.
    /// - Tempus: samples whose server values hold an answer newer than
    ///   the local weather rows (none yet, or the backend's job
    ///   replaced provisional values). Values the device fetched itself
    ///   and has not delivered keep their own rows.
    private func hydrateFeatures(_ remote: [Sample]) async -> Bool {
        var ok = true
        // backend sample id → local sample id, per source.
        var wanted: [FeatureScope: [String: String]] = [.ortus: [:], .tempus: [:]]
        for r in remote {
            guard let local = try? samples.fetchByBackendID(r.id) else { continue }
            if r.locationStatus == .backendService,
               (try? features.count(sampleID: local.id, scope: .ortus)) == 0
            {
                wanted[.ortus]?[r.id] = local.id
            }
            if needsWeatherFeatures(local, remote: r) {
                wanted[.tempus]?[r.id] = local.id
            }
        }
        let ids = Set(wanted.values.flatMap(\.keys))
        if ids.isEmpty { return true }

        for batch in ids.sorted().chunked(into: Self.featureBatch) {
            do {
                let fetched = try await featuresClient.fetchFeatures(sampleBackendIDs: batch)
                let grouped = Dictionary(grouping: fetched, by: \.sample)
                for backendID in batch {
                    let items = (grouped[backendID] ?? []).map(\.ortusFeature)
                    if let localID = wanted[.ortus]?[backendID],
                       // Re-check: the on-device resolver may have stored
                       // its own set while the request was in flight.
                       (try? features.count(sampleID: localID, scope: .ortus)) == 0
                    {
                        try features.replace(sampleID: localID, scope: .ortus, features: items)
                    }
                    if let localID = wanted[.tempus]?[backendID],
                       let local = try? samples.fetchById(localID), local.conditions?.needsPush != true
                    {
                        try features.replace(sampleID: localID, scope: .tempus, features: items)
                    }
                }
                Log.sync.info("hydrated \(fetched.count, privacy: .public) sample features")
            } catch {
                Log.sync.warning("feature hydrate failed: \(error.localizedDescription)")
                ok = false
            }
        }
        return ok
    }

    private func needsWeatherFeatures(_ local: LocalSample, remote: Sample) -> Bool {
        guard let theirs = remote.conditions, theirs.hasAnswer, let fetchedAt = theirs.fetchedAt,
              local.conditions?.needsPush != true
        else { return false }
        guard let newest = try? features.latestFetchedAt(sampleID: local.id, scope: .tempus) else { return true }
        return newest < fetchedAt
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
