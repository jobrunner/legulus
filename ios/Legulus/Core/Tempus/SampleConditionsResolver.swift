import Foundation
import LegulusGeo

/// What Tempus is asked with for one sample. Two requests are the same
/// when Tempus would answer the same: coordinate to six decimals,
/// height in whole metres, instant to the second.
struct ConditionsRequest: Equatable {
    let latitude: Double
    let longitude: Double
    let elevationMetres: Int
    let instant: Date

    /// nil when the sample cannot be asked: no coordinate, or no usable
    /// height (Tempus requires it; see `ConditionsQuery.elevationMetres`).
    init?(_ sample: LocalSample, night: Bool) {
        guard let lat = sample.latitude, let lon = sample.longitude,
              let metres = ConditionsQuery.elevationMetres(sample.elevation, hasSource: sample.elevationSource != nil)
        else { return nil }
        latitude = lat
        longitude = lon
        elevationMetres = metres
        instant = ConditionsQuery.instant(
            begin: sample.beginDate, timezone: sample.timezone, isAllDay: sample.isAllDay, night: night
        )
    }

    var inputs: SampleConditions.Inputs {
        .init(latitude: latitude, longitude: longitude, elevationMetres: elevationMetres)
    }

    /// The backend's tolerance (`hooks.coordEpsilon`): a larger change
    /// is a move there and resets the values, so it must be one here
    /// too — otherwise the push would send no new values for a sample
    /// the backend is about to clear.
    static let coordEpsilon = 1e-7

    /// Whether `conditions` were queried with this request.
    func fits(_ conditions: SampleConditions) -> Bool {
        guard let inputs = conditions.inputs else { return false }
        return abs(inputs.latitude - latitude) < Self.coordEpsilon
            && abs(inputs.longitude - longitude) < Self.coordEpsilon
            && inputs.elevationMetres == elevationMetres
            && ConditionsQuery.sameInstant(conditions.queriedFor, instant)
    }
}

/// Fills a sample's weather, climate and astronomy values from Tempus
/// on the device — the counterpart of the backend's conditions
/// enrichment, with the same request and the same mapping.
///
/// Values are never reset when a sample changes. They carry what they
/// were queried with (`SampleConditions.inputs`, `queriedFor`), and
/// `validConditions(for:)` says whether they still fit: after a moved
/// coordinate, another height or another instant they simply no longer
/// count, on every code path that changes a sample.
///
/// The sync asks before it pushes a sample (`SyncRunner`), so the values
/// travel with that push. The app never refreshes values that fit;
/// provisional ones are replaced by the backend's job and arrive with
/// the pull.
@MainActor
final class SampleConditionsResolver {
    private let tempus: TempusQuerying?
    private let samples: LocalSampleStore
    private let features: LocalSampleFeatureStore
    private let isNightFieldtrip: (LocalSample) -> Bool
    private let now: () -> Date

    /// - Parameters:
    ///   - tempus: nil (empty endpoint) switches the on-device query off.
    ///   - isNightFieldtrip: whether the sample's fieldtrip is a night
    ///     fieldtrip (an all-day sample is then asked for 22:00).
    init(
        tempus: TempusQuerying?,
        samples: LocalSampleStore,
        features: LocalSampleFeatureStore,
        isNightFieldtrip: @escaping (LocalSample) -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.tempus = tempus
        self.samples = samples
        self.features = features
        self.isNightFieldtrip = isNightFieldtrip
        self.now = now
    }

    /// The request for the sample as it is now; nil when it cannot be
    /// asked.
    func request(for sample: LocalSample) -> ConditionsRequest? {
        ConditionsRequest(sample, night: isNightFieldtrip(sample))
    }

    /// The sample's values when they hold an answer that fits the
    /// sample as it is now; nil otherwise.
    func validConditions(for sample: LocalSample) -> SampleConditions? {
        guard let conditions = sample.conditions, conditions.hasAnswer,
              let request = request(for: sample), request.fits(conditions)
        else { return nil }
        return conditions
    }

    /// Values the device fetched itself wait for the next push
    /// (`needsPush`) and meanwhile keep the server's values out
    /// (`LocalSample.mergeServerConditions`). Once the sample changed so
    /// that they no longer fit, they can never be delivered: without
    /// this, the device would neither take the server's values nor
    /// fetch their features for as long as it cannot reach Tempus
    /// itself. The values stay as they are, they just stop blocking.
    func releaseUndeliverable(sampleID: String) {
        guard var row = try? samples.fetchById(sampleID), row.conditions?.needsPush == true,
              validConditions(for: row) == nil
        else { return }
        row.conditions?.needsPush = false
        do {
            try samples.update(row)
        } catch {
            Log.persistence.error("releasing undeliverable tempus values failed: \(error.localizedDescription)")
        }
    }

    /// Asks Tempus when the sample can be asked and holds no values
    /// that fit. Returns true when values were written. Never throws:
    /// a failure leaves the sample as it is and the backend enriches it
    /// after sync.
    ///
    /// `isLive` is asked after the network call, before anything is
    /// written: the sync passes whether it still acts for the account
    /// it started for. A runner left behind by a sign-out must not
    /// write over what the next session stored.
    @discardableResult
    func resolve(sampleID: String, isLive: @MainActor () -> Bool = { true }) async -> Bool {
        guard let tempus,
              let sample = try? samples.fetchById(sampleID),
              let request = request(for: sample),
              validConditions(for: sample) == nil
        else { return false }

        let response: TempusResponse
        do {
            response = try await tempus.query(
                lat: request.latitude, lon: request.longitude,
                elevationMetres: request.elevationMetres, at: request.instant
            )
        } catch {
            Log.network.warning(
                "tempus unavailable for sample \(sampleID, privacy: .public): \(error.localizedDescription)"
            )
            return false
        }
        guard isLive() else { return false }
        let result = ConditionsMapper.map(response, queriedFor: request.instant, fetchedAt: now())

        do {
            var conditions = SampleConditions(result)
            conditions.inputs = request.inputs
            conditions.needsPush = true
            conditions.featuresFetchedAt = result.fetchedAt
            // Values and their features in one transaction, on the row
            // as it is now: the sample may have changed while Tempus
            // answered.
            let wrote = try samples.writeConditions(id: sampleID, features: result.features) { row in
                guard self.request(for: row) == request else { return false }
                row.conditions = conditions
                return true
            }
            guard wrote else {
                Log.location.info("sample \(sampleID, privacy: .public) changed during the tempus query, answer dropped")
                return false
            }
        } catch {
            Log.persistence.error("storing tempus values failed: \(error.localizedDescription)")
            return false
        }
        Log.location.info(
            "sample \(sampleID, privacy: .public) conditions via tempus: \(result.status.rawValue, privacy: .public), \(result.features.count, privacy: .public) features"
        )
        return true
    }
}
