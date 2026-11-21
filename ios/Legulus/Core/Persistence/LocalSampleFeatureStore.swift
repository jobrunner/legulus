import Foundation
import GRDB
import LegulusGeo

/// The source a feature row belongs to. Ortus and Tempus rows share the
/// table (and the backend's `sample_features`) but are replaced
/// separately; the backend takes the scope as `?scope=`.
enum FeatureScope: String {
    case ortus, tempus

    /// `source_id` prefix of every Tempus row.
    static let tempusPrefix = ConditionsMapper.featureSourcePrefix

    func contains(sourceID: String) -> Bool {
        sourceID.hasPrefix(Self.tempusPrefix) == (self == .tempus)
    }

    /// SQL condition on `source_id` for this scope.
    fileprivate var filter: SQLExpression {
        let isTempus = Column("source_id").like(Self.tempusPrefix + "%")
        return self == .tempus ? isTempus : !isTempus
    }
}

/// CRUD for `local_sample_features`. A sample's feature set of one
/// source (`FeatureScope`) is always replaced as a whole (one answer =
/// one complete set), like the backend's `geoplace.ReplaceFeatures`.
/// Rows are wiped together with the samples in
/// `LocalSampleStore.reset()`.
final class LocalSampleFeatureStore {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    /// Replaces the features of `sampleID` (local sample UUID) that
    /// belong to `scope` with `features` in one transaction; rows of
    /// the other source stay. An empty list clears the scope. Features
    /// of the other source in the list are not stored.
    func replace(sampleID: String, scope: FeatureScope, features: [OrtusFeature]) throws {
        let now = Date()
        try database.writer.write { db in
            _ = try LocalSampleFeature
                .filter(Column("sample_id") == sampleID)
                .filter(scope.filter)
                .deleteAll(db)
            for feature in features where scope.contains(sourceID: feature.sourceID) {
                var row = LocalSampleFeature(sampleID: sampleID, feature: feature, fetchedAt: now)
                try row.insert(db)
            }
        }
    }

    /// Features of one sample from one Ortus source, in the order they
    /// were stored.
    func features(sampleID: String, sourceID: String) throws -> [LocalSampleFeature] {
        try database.reader.read { db in
            try LocalSampleFeature
                .filter(Column("sample_id") == sampleID)
                .filter(Column("source_id") == sourceID)
                .order(Column.rowID)
                .fetchAll(db)
        }
    }

    /// The features of one sample from one source, in the order they
    /// were stored.
    func all(sampleID: String, scope: FeatureScope) throws -> [LocalSampleFeature] {
        try database.reader.read { db in
            try LocalSampleFeature
                .filter(Column("sample_id") == sampleID)
                .filter(scope.filter)
                .order(Column.rowID)
                .fetchAll(db)
        }
    }

    func count(sampleID: String, scope: FeatureScope) throws -> Int {
        try database.reader.read { db in
            try LocalSampleFeature
                .filter(Column("sample_id") == sampleID)
                .filter(scope.filter)
                .fetchCount(db)
        }
    }

    /// When the newest row of one source was stored; nil without rows.
    func latestFetchedAt(sampleID: String, scope: FeatureScope) throws -> Date? {
        try database.reader.read { db in
            try LocalSampleFeature
                .filter(Column("sample_id") == sampleID)
                .filter(scope.filter)
                .select(max(Column("fetched_at")), as: Date.self)
                .fetchOne(db)
        }
    }
}
