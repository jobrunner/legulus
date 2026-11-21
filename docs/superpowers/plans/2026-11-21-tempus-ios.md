# Tempus in der App (PR 8) – Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die App fragt Tempus für jede Probe mit Koordinate und Höhe selbst ab, speichert Werte und Features lokal, synchronisiert sie mit dem Backend und zeigt sie im Bereich „Wetter und Klima“.

**Architecture:** Das Ortus-Muster wird gespiegelt. Pure Logik (Antwortmodell, Abfragezeitpunkt, Abbildung auf Felder und Status) liegt im Package `LegulusGeo` und wird gegen dieselben Fixtures geprüft wie `tabularius/internal/conditions`. In der App kommen ein Client, ein Resolver, lokale Spalten, Sync-Felder und ein nach Quelle getrennter Feature-Speicher dazu. Die Ansicht liest nur lokale Daten.

**Tech Stack:** Swift, SwiftUI, GRDB, XCTest, Swift Package `LegulusGeo`, `scripts/check-ios.sh`.

**Spec:** `docs/superpowers/specs/2026-11-19-tempus-wetter-klima-design.md` (Abschnitte „Datenhaltung“, „Höhe als Voraussetzung“, „App“, „Wer gewinnt“, „Ansicht“).

**Zwei PRs:** PR 8a (`feat/tempus-ios-data`, Tasks 1–8) liefert Abfrage, Speicherung und Sync ohne neue Ansicht. PR 8b (`feat/tempus-ios-view`, Tasks 9–12, auf 8a) liefert die Ansicht. So bleibt jeder PR reviewbar; nach 8a sind die Werte der App am Server prüfbar.

## Global Constraints

- Schreibvorgänge gehen zuerst lokal in die DB, die Sync-Queue pusht nach. Die Abfrage läuft im Hintergrund und darf Anlegen und Speichern nie blockieren oder scheitern lassen.
- Abgefragt wird nur mit Koordinate **und** nutzbarer Höhe: `elevationSource != nil` und `-500 ... 9000` m. Tempus bekommt die Höhe in ganzen Metern.
- Abfragezeitpunkt: Beginn der Probe; ganztägig 14:00 Ortszeit des Sammeltags; ganztägig in einer Nachtexkursion 22:00. Ortszeit ist `timezone` der Probe, unbekannte Zone zählt als UTC. Kennt die App die Exkursion noch nicht, gilt 14:00.
- Eine Zahlenspalte gilt nur, wenn ihr Name in `conditions_fields` steht (0 °C ist ein echter Wert).
- Feldnamen, Status und die Wertetabelle sind die von `tabularius/internal/conditions/map.go` (`valueSpecs`, `StatusPending/Provisional/Final`, Windfeld nur bei Einheit `km/h`, Features ohne `kind` oder Lizenz entfallen, `FinalAfter` 120 h, `defaultRetry` 1 h). Die App bildet genauso ab; Abweichungen sind Fehler.
- Tempus-Features haben `source_id` mit Präfix `tempus:` und werden getrennt von Ortus-Features ersetzt, lokal wie am Server (`PUT /api/samples/{id}/features?scope=tempus` bzw. `?scope=ortus`).
- Die App fragt nicht von sich aus nach. Nachgezogene Werte kommen über den Pull.
- Die echte Tempus-Adresse steht nur als Default in `AppConfig` (wie bei Ortus, derselbe Wert wie in `docker-compose.yml`). In Doku, Tests, Commit- und PR-Texten steht `https://tempus.example`.
- Logging nur über `Log.network` / `Log.location` / `Log.persistence`; keine Koordinaten, Höhe höchstens gerundet. Kein `print()`.
- UI: nur Tokens (`Core/Theme/`) und Atoms (`Core/UI/`), deutsche Strings, Zahlen mit Dezimalkomma, A11y nach `.claude/rules/ACCESSIBILITY-IOS.md` (Dynamic Type bis AX5, VoiceOver-Zeilen kombiniert, Status nie nur über Farbe).
- Keine Force-Unwraps im Produktivcode. Commits nach Conventional Commits mit dem Session-Footer.
- Nach jeder neuen Datei `cd ios && xcodegen generate`. Vor jedem PR `bash scripts/check-ios.sh`.

## Review Focus

1. Probe ohne Höhe (GPS ohne Höhenangabe, Ortus liefert keine DEM-Höhe): keine Abfrage, Status `pending`, die Ansicht sagt „Wartet auf die Höhe“. Test in Task 6 und 10.
2. Koordinate, Höhe oder Zeit ändern sich, während die Abfrage läuft: Die Antwort wird verworfen, nichts wird geschrieben. Test in Task 6.
3. Wert 0 (0 °C, 0 mm, 0 % Bewölkung) wird angezeigt und gesynct, ein fehlender Wert nicht. Tests in Task 2, 4 und 10.
4. Ein Ortus-Lauf darf Tempus-Features nicht löschen und umgekehrt, lokal und beim Push. Tests in Task 5.
5. Der Pull bringt nachgezogene Werte (vorläufig → endgültig): lokale Werte und Tempus-Features werden ersetzt, auch wenn lokal schon welche liegen. Test in Task 7.

---

## PR 8a – Daten und Sync

### Task 1: Abfragezeitpunkt und Höhenregel (Package)

**Files:**
- Create: `ios/Packages/LegulusGeo/Sources/LegulusGeo/ConditionsQuery.swift`
- Test: `ios/Packages/LegulusGeo/Tests/LegulusGeoTests/ConditionsQueryTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum ConditionsQuery {
      public static let elevationRange: ClosedRange<Double>   // -500 ... 9000
      public static let finalAfter: TimeInterval               // 120 h
      public static func instant(begin: Date, timezone: String, isAllDay: Bool, night: Bool) -> Date
      public static func sameInstant(_ a: Date, _ b: Date) -> Bool   // gleiche UTC-Stunde
      /// nil, wenn hasSource false ist oder die Höhe außerhalb des Bereichs liegt
      public static func elevationMetres(_ elevation: Double?, hasSource: Bool) -> Int?
  }
  ```

- [ ] **Step 1: Tests schreiben.** Fälle wie in `tabularius/internal/conditions/instant_test.go` (dieselben Eingaben und erwarteten UTC-Zeiten): Uhrzeit-Probe = Beginn auf Sekunden gekürzt; ganztägig Berlin Sommer 14:00 → 12:00Z, Winter → 13:00Z; Nacht 22:00 → 20:00Z; unbekannte Zone → UTC; Tag der Zeitumstellung. `sameInstant`: 12:10 und 12:50 gleich, 12:59 und 13:00 verschieden. `elevationMetres`: `(519.6, true) → 520`, `(0, true) → 0`, `(520, false) → nil`, `(nil, true) → nil`, `(-501, true) → nil`, `(9001, true) → nil`.
- [ ] **Step 2:** `cd ios/Packages/LegulusGeo && swift test --scratch-path /tmp/lg-build --filter ConditionsQueryTests` → FAIL (Typ fehlt).
- [ ] **Step 3:** Implementieren. `sameInstant` vergleicht die auf die volle UTC-Stunde gekürzten Zeiten, wie `conditions.SameInstant`.
- [ ] **Step 4:** Test erneut → PASS.
- [ ] **Step 5:** Commit `feat(ios): Abfragezeitpunkt und Höhenregel für Tempus`.

### Task 2: Antwortmodell und Abbildung (Package)

**Files:**
- Create: `ios/Packages/LegulusGeo/Sources/LegulusGeo/TempusResponse.swift`, `.../ConditionsMapper.swift`
- Test: `ios/Packages/LegulusGeo/Tests/LegulusGeoTests/ConditionsMapperTests.swift` (liest `shared/testdata/tempus/*.json` über `#filePath` wie `OrtusMapperTests`)

**Interfaces:**
- Consumes: `ConditionsQuery.finalAfter`.
- Produces:
  ```swift
  public struct TempusResponse: Decodable, Sendable   // features (GeoJSON, properties als JSON-Wert), providers[id, kind, status, retryAfter]
  public enum ConditionsStatus: String, Codable, Sendable { case pending, provisional, final }
  public enum ConditionsValue: Equatable, Sendable { case number(Double), text(String), date(Date) }
  public struct ConditionsFeature: Equatable, Sendable {   // eine Zeile für local_sample_features
      public var sourceID: String        // "tempus:<kind>"
      public var sourceName: String      // "Tempus"
      public var layer: String           // kind
      public var propertiesJSON: String
      public var licenseJSON: String
  }
  public struct ConditionsResult: Equatable, Sendable {
      public var status: ConditionsStatus
      public var queriedFor: Date
      public var fetchedAt: Date
      public var retryAt: Date?
      public var values: [String: ConditionsValue]   // Schlüssel = Feldnamen des Backends
      public var fields: [String] { get }            // sortierte Schlüssel
      public var features: [ConditionsFeature]
  }
  public enum ConditionsMapper {
      public static let valueFields: [String]        // Reihenfolge wie valueSpecs im Backend
      public static func map(_ response: TempusResponse, queriedFor: Date, fetchedAt: Date) -> ConditionsResult
  }
  ```

- [ ] **Step 1: Tests schreiben**, je Test in `tabularius/internal/conditions/map_test.go` ein Gegenstück mit denselben Fixtures und denselben erwarteten Werten: `PastAllOk` (alle 19 Felder, Status `final`, kein `retryAt`), `RecentIsProvisionalWithRetryAfter`, `UnavailableWithoutHintRetriesAfterOneHour`, `OldButUnavailableStaysProvisional`, `FreshAllOkRetriesAfterFiveDays`, `FutureKeepsSunAndMoon`, `ZeroValuesCount`, `NullPropertyIsNotAField`, `WindInOtherUnitIsNotStored`, `DropsFeatureWithoutLicenseOrKind`, `ProviderErrorIsFinal`. Die erwarteten Zahlen aus dem Go-Test übernehmen, nicht neu ausrechnen.
- [ ] **Step 2:** `swift test --filter ConditionsMapperTests` → FAIL.
- [ ] **Step 3:** Implementieren. `retryAfter` ist eine Go-Dauer (`2h0m0s`); der Parser versteht `h`, `m`, `s` und Dezimalsekunden, alles andere zählt als kein Hinweis. Unbekannte Properties bleiben in `propertiesJSON` erhalten.
- [ ] **Step 4:** Tests → PASS, dann `swift test` für das ganze Package.
- [ ] **Step 5:** Commit `feat(ios): Tempus-Antwort auf Werte, Status und Features abbilden`.

### Task 3: Client und Endpoint

**Files:**
- Create: `ios/Legulus/Core/Tempus/TempusClient.swift`
- Modify: `ios/Legulus/Core/Config/AppConfig.swift`, `ios/Legulus/Features/Settings/SettingsView.swift`, `ios/Legulus/Resources/Localizable.xcstrings`
- Test: `ios/LegulusTests/TempusClientTests.swift`, `ios/LegulusTests/TempusTestSupport.swift` (`StubTempus`, getrimmte Fixture als String wie `OrtusFixtures`)

**Interfaces:**
- Produces:
  ```swift
  protocol TempusQuerying: Sendable {
      func query(lat: Double, lon: Double, elevationMetres: Int, at: Date) async throws -> TempusResponse
  }
  struct TempusClient: TempusQuerying {
      static func make(endpoint: String) -> TempusClient?   // nil bei leerem Endpoint
      func makeRequest(lat: Double, lon: Double, elevationMetres: Int, at: Date) throws -> URLRequest
  }
  // AppConfig
  @Published var tempusEndpointURL: String
  static let defaultTempusEndpointURL: String   // derselbe Wert wie in docker-compose.yml
  ```

- [ ] **Step 1: Tests schreiben** (gegen `https://tempus.example`): `makeRequest` ergibt `GET /api/v1/query` mit `lat`/`lon` auf 6 Stellen, `elevation=520`, `datetime` als RFC 3339 in UTC, Header `Accept: application/json`; ein abschließender `/` am Endpoint stört nicht; `make(endpoint: "  ")` ist nil; `AppConfig`: nie gesetzt → Default, gespeichertes `""` bleibt leer.
- [ ] **Step 2:** Gezielter Testlauf → FAIL.
- [ ] **Step 3:** Implementieren nach dem Vorbild `OrtusClient` (harter Gesamt-Timeout 5 s, Nicht-2xx wirft). UserDefaults-Key `tempusEndpointURL`. In `SettingsView` eine Section „Tempus-Endpoint“ unter der Ortus-Section, gleicher Aufbau; Fußzeile: „Dienst für Wetter, Klima, Sonne und Mond. Leer lassen, um die Abfrage auf dem Gerät abzuschalten – das Backend reichert dann an.“
- [ ] **Step 4:** Testlauf → PASS.
- [ ] **Step 5:** Commit `feat(ios): Tempus-Client und Endpoint in den Einstellungen`.

### Task 4: Lokale Spalten und Server-Modell

**Files:**
- Modify: `ios/Legulus/Core/Persistence/Database.swift` (Migration `v20_sample_conditions`), `ios/Legulus/Core/Persistence/LocalSample.swift`, `ios/Legulus/Core/Models/Sample.swift`
- Create: `ios/Legulus/Core/Persistence/SampleConditions.swift`
- Test: `ios/LegulusTests/DatabaseMigrationV20Tests.swift`, `ios/LegulusTests/SampleConditionsTests.swift`

**Interfaces:**
- Consumes: `ConditionsStatus`, `ConditionsResult`, `ConditionsMapper.valueFields`.
- Produces:
  ```swift
  /// Die Tempus-Werte einer Probe; lokal (GRDB) und vom Server (JSON) dieselbe Struktur.
  struct SampleConditions: Codable, Equatable {
      var status: ConditionsStatus?          // nil = nie verarbeitet
      var queriedFor: Date?
      var fetchedAt: Date?
      var retryAt: Date?
      var fields: [String]                   // conditions_fields
      // je Wertfeld eine optionale Property; nil, wenn der Name nicht in fields steht
      var weatherTemperatureC: Double?       // … alle 19 Felder aus der Spec-Tabelle
      init(_ result: ConditionsResult)
      static let pending: SampleConditions   // Status pending, keine Werte
      var wireBody: [String: Any]            // leer, wenn status nicht provisional/final ist
  }
  // LocalSample
  var conditions: SampleConditions           // flach in den Spalten gespeichert
  // Sample (Server)
  let conditions: SampleConditions?          // nil, wenn conditions_status leer ist
  ```

- [ ] **Step 1: Tests schreiben.** Migration: von `v19_photo_attempts` aus eine Probe einfügen, migrieren, alle neuen Spalten vorhanden, die Altprobe hat leeren Status. `SampleConditions`: Dekodieren einer Server-Probe mit `conditions_fields: ["weather_temperature_c"]`, `weather_temperature_c: 0` und `weather_humidity_pct: 0` ergibt Temperatur `0`, Luftfeuchte `nil`; `init(result)` und `wireBody` runden (`fields` sortiert, Daten als ISO 8601 mit Millisekunden, Zahlen unverändert); `wireBody` ist für `pending` leer; lokales Speichern und Laden einer Probe erhält die Werte, auch die 0.
- [ ] **Step 2:** Testlauf → FAIL.
- [ ] **Step 3:** Implementieren. Spalten: `conditions_status` (Text, Default `""`), `conditions_queried_for`, `conditions_fetched_at`, `conditions_retry_at` (Datum, optional), `conditions_fields` (Text, JSON-Liste, Default `"[]"`), dazu die 19 Wertspalten (Zahl, Text bzw. Datum, alle optional). Die Server-Dekodierung folgt dem Muster `SampleGeoValues` (flach aus demselben Decoder).
- [ ] **Step 4:** Testlauf → PASS.
- [ ] **Step 5:** Commit `feat(ios): Wetter- und Klimawerte lokal und im Server-Modell`.

### Task 5: Features nach Quelle trennen

**Files:**
- Modify: `ios/Legulus/Core/Persistence/LocalSampleFeatureStore.swift`, `ios/Legulus/Core/Persistence/LocalSampleFeature.swift`, `ios/Legulus/Core/PocketBaseClient/SampleFeaturesClient.swift`, `ios/Legulus/Core/Sync/SyncRunner.swift`, `ios/Legulus/Core/Sync/SampleLocationHydration.swift`, `ios/Legulus/Core/Persistence/LocalSampleStore.swift` (`updateCoordinate` löscht nur Ortus-Zeilen; Tempus-Zeilen räumt `resetConditionsIfStale` aus Task 6)
- Test: `ios/LegulusTests/LocalSampleFeatureStoreScopeTests.swift`, Ergänzungen in `SyncRunnerOrtusTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum FeatureScope: String { case ortus, tempus
      static let tempusPrefix = "tempus:"
      func contains(sourceID: String) -> Bool }
  // LocalSampleFeatureStore
  func replace(sampleID: String, features: [OrtusFeature]) throws            // ersetzt nur Ortus-Zeilen
  func replace(sampleID: String, tempus: [ConditionsFeature], fetchedAt: Date) throws   // ersetzt nur tempus:-Zeilen
  func all(sampleID: String, scope: FeatureScope) throws -> [LocalSampleFeature]
  func count(sampleID: String, scope: FeatureScope) throws -> Int
  // SampleFeaturesSyncClient
  func replaceFeatures(sampleBackendID: String, scope: FeatureScope, features: [LocalSampleFeature]) async throws
  ```

- [ ] **Step 1: Tests schreiben.** Store: Ortus-`replace` lässt `tempus:`-Zeilen stehen und umgekehrt; `all`/`count` je Scope. Client: URL endet auf `/features?scope=ortus` bzw. `?scope=tempus`, der Body enthält nur Zeilen des Scopes. `SyncRunner`: `pushFeatures` schickt nur Ortus-Zeilen mit `scope=ortus`; die Feature-Hydration für Ortus prüft `count(scope: .ortus) == 0` und schreibt nur Ortus-Zeilen (eine Probe mit lokalen Tempus-Zeilen bekommt ihre Ortus-Features trotzdem).
- [ ] **Step 2:** Testlauf → FAIL.
- [ ] **Step 3:** Implementieren. Alle bisherigen Aufrufer von `all(sampleID:)` und `count(sampleID:)` auf den Scope `.ortus` umstellen; die Varianten ohne Scope entfallen, damit kein Aufrufer versehentlich beide Quellen mischt.
- [ ] **Step 4:** Testlauf → PASS, dazu `SyncRunnerOrtusTests` und `SampleLocationResolverTests` vollständig.
- [ ] **Step 5:** Commit `refactor(ios): Features lokal und beim Sync nach Quelle trennen`.

### Task 6: Resolver und Auslöser

**Files:**
- Create: `ios/Legulus/Core/Tempus/SampleConditionsResolver.swift`
- Modify: `ios/Legulus/Core/Persistence/LocalSampleStore.swift`, `ios/Legulus/Features/SampleEditor/SampleCreation.swift`, `.../CoordinateCorrection.swift`, `ios/Legulus/Features/Retrospective/RetrospectiveSampleCreator.swift`, `ios/Legulus/Features/SampleForm/SampleFormViewModel.swift`, `ios/Legulus/App/AppContainer.swift`, `ios/Legulus/App/AccountGraph.swift`
- Test: `ios/LegulusTests/SampleConditionsResolverTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4, `LocalSampleFeatureStore.replace(sampleID:tempus:fetchedAt:)` aus Task 5.
- Produces:
  ```swift
  @MainActor final class SampleConditionsResolver {
      init(tempus: TempusQuerying?, samples: LocalSampleStore, fieldtrips: LocalFieldtripStore,
           features: LocalSampleFeatureStore, mutations: PendingMutationsStore?, now: @escaping () -> Date = Date.init)
      /// true, wenn Werte geschrieben wurden
      @discardableResult func resolve(sampleID: String) async -> Bool
  }
  // LocalSampleStore
  /// Setzt die Werte zurück, wenn Koordinate, Höhe (ganzer Meter) oder Abfragezeitpunkt
  /// nicht mehr zu ihnen passen: Status pending, Werte und Tempus-Features entfernt.
  /// Ohne Koordinate: Status leer.
  func resetConditionsIfStale(_ sample: inout LocalSample, db: GRDB.Database) throws
  // SampleUpdatePayload (tolerantes init(from:) und merged(with:) mitziehen)
  var pushConditions = false                 // Werte und Tempus-Features gehen mit diesem Update; ausgewertet in Task 7
  // AppContainer
  func makeConditionsResolver() -> SampleConditionsResolver
  ```

- [ ] **Step 1: Tests schreiben** (In-Memory-DB, `StubTempus`):
  - Probe mit Koordinate und GPS-Höhe: `resolve` schreibt Werte, Status und Tempus-Features; die Anfrage trug `elevationMetres` der Probe und den Abfragezeitpunkt.
  - Ohne Höhe, mit Höhe außerhalb des Bereichs, ohne Koordinate, mit `tempus == nil`: keine Anfrage, Rückgabe false, Status bleibt.
  - Status `provisional` oder `final`, deren `queriedFor` zum Abfragezeitpunkt passt: keine Anfrage (die App fragt nicht nach).
  - Koordinate, Höhe oder Beginn ändern sich während der Anfrage (Stub mit Hook): nichts wird geschrieben.
  - Fehler oder Timeout des Stubs: Status bleibt `pending`, nichts geschrieben.
  - Probe mit `backendId`: ein Update mit `pushConditions` liegt in der Outbox. Ohne `backendId`: keine Mutation.
  - Ganztägige Probe, deren Exkursion lokal `nightFieldtrip == true` hat: Anfrage für 22:00 Ortszeit; ohne bekannte Exkursion 14:00.
  - `resetConditionsIfStale`: Koordinate verschoben, Höhe um ≥ 1 m geändert, Beginn in eine andere Stunde verschoben → `pending` ohne Werte und ohne Tempus-Features (Ortus-Features bleiben); Notiz geändert oder Höhe im selben Meter → unverändert; Koordinate entfernt → Status leer.
- [ ] **Step 2:** Testlauf → FAIL.
- [ ] **Step 3:** Implementieren. `resetConditionsIfStale` wird in `updateCoordinate`, `saveEdits`, `setManualElevation` und beim Schreiben der DEM-Höhe im `SampleLocationResolver` innerhalb derselben Transaktion aufgerufen. Auslöser für `resolve`, jeweils im Hintergrund nach dem lokalen Speichern und vor `sync.kick()`: in `SampleCreation.resolvePlaceThenSync` nach dem Orts-Resolver (dann steht eine DEM-Höhe schon da), in `CoordinateCorrection` nach `applyAnswer` / `resolveAfterCorrection`, im `RetrospectiveSampleCreator` nach `resolver?.apply`, im `SampleFormViewModel` nach `saveEdits`, wenn sich der Abfragezeitpunkt geändert hat.
- [ ] **Step 4:** Testlauf → PASS, dazu die bestehenden `SampleLocationResolverTests` und `RetrospectiveEntryTests`.
- [ ] **Step 5:** Commit `feat(ios): Tempus auf dem Gerät abfragen, sobald Koordinate und Höhe da sind`.

### Task 7: Sync der Werte und Tempus-Features

**Files:**
- Modify: `ios/Legulus/Core/Sync/SyncRunner.swift`, `ios/Legulus/Core/PocketBaseClient/SampleClient.swift`, `ios/Legulus/Core/Persistence/LocalSampleStore.swift`, `ios/Legulus/Core/Sync/SampleLocationHydration.swift`
- Test: `ios/LegulusTests/SyncRunnerConditionsTests.swift`, Ergänzung in `ios/LegulusTests/LocalSampleStoreUpsertTests.swift` (anlegen, falls es die Datei nicht gibt)

**Interfaces:**
- Consumes: `SampleConditions.wireBody`, `FeatureScope`, `replaceFeatures(…scope:…)`, `SampleUpdatePayload.pushConditions` (Task 6).
- Produces:
  ```swift
  // SampleCreateInput, SampleUpdateInput
  var conditions: SampleConditions?          // nil = nichts senden
  // LocalSample
  /// Übernimmt die Werte des Servers. Sie gewinnen immer, außer die lokale Zeile hält
  /// Werte mit jüngerem fetchedAt für denselben Abfragezeitpunkt.
  /// Rückgabe: true, wenn sich fetchedAt oder Status geändert haben (Features neu holen).
  mutating func mergeServerConditions(_ remote: SampleConditions?) -> Bool
  ```

- [ ] **Step 1: Tests schreiben.**
  - Create mit lokal vorhandenen Werten: Der POST-Body enthält die `conditions_*`- und Wertfelder; nach dem Create folgt `replaceFeatures(scope: .tempus)`.
  - Create ohne Werte (`pending`): keine Wetterfelder im Body, kein Tempus-PUT.
  - Update mit `pushConditions`: PATCH-Body enthält die Werte, danach Tempus-PUT. Ohne das Flag enthält der PATCH keine Wetterfelder (ein Notiz-Update darf Server-Werte nicht mit alten überschreiben).
  - Antwort auf Create/PATCH und Pull (`upsert`): `mergeServerConditions` – Server `final` ersetzt lokal `provisional`; Server leer oder `pending` nach lokalem Reset bleibt `pending`; lokale Werte mit jüngerem `fetchedAt` bleiben, solange ihr Update in der Outbox liegt.
  - Pull mit geändertem `conditions_fetched_at`: Die Hydration holt die Tempus-Features der Probe neu und ersetzt nur `tempus:`-Zeilen, auch wenn lokal schon welche liegen.
  - 409 beim PATCH: Nach `adoptAfterConflict` stammen die Wetterfelder vom Server.
- [ ] **Step 2:** Testlauf → FAIL.
- [ ] **Step 3:** Implementieren. `mergeServerConditions` wird an denselben Stellen aufgerufen wie `mergeServerLocation` (Create-Antwort, PATCH-Antwort, `adoptServer`, `apply(remote:to:)`, `makeLocal`), aber unabhängig von `keepLocalPlace`. Die Hydration bekommt eine zweite Kandidatenliste: Proben, bei denen `mergeServerConditions` true geliefert hat.
- [ ] **Step 4:** Testlauf → PASS.
- [ ] **Step 5:** Commit `feat(ios): Wetterwerte und Tempus-Features synchronisieren`.

### Task 8: Abschluss PR 8a

- [ ] **Step 1:** `bash scripts/check-ios.sh` → Lint, Build und Tests grün auf beiden Runtimes.
- [ ] **Step 2:** Probelauf gegen die Test-Instanz (`localhost:8092`, dort ist `TEMPUS_BASE_URL` leer, das Backend fragt also nicht selbst): im Simulator eine Probe mit Koordinate und Höhe anlegen, nach dem Sync per API prüfen, dass `conditions_status` und die Wertfelder am Server stehen und `sample_features` Zeilen mit `tempus:` enthält. Ergebnis in den PR-Text. Wenn die erreichbare Tempus-Instanz die Höhe noch nicht kennt oder nicht erreichbar ist: das im PR-Text so schreiben.
- [ ] **Step 3:** `PHASES.md`: Phase T, PR 8 in 8a und 8b teilen, 8a nach dem Merge abhaken. PR öffnen, Copilot-Review abarbeiten.

---

## PR 8b – Ansicht

### Task 9: Darstellungsmodell

**Files:**
- Create: `ios/Legulus/Features/SampleEditor/Conditions/ConditionsDisplay.swift`
- Test: `ios/LegulusTests/ConditionsDisplayTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct ConditionsDisplay: Equatable {
      enum State: Equatable { case noCoordinate, waitingForElevation, pending, legacy, noData, values }
      struct Pair: Equatable, Identifiable { let id: String; let label: String; let value: String; let spoken: String }
      var state: State
      var isProvisional: Bool
      var weatherTitle: String?          // Text zum WMO-Code aus dem Feature
      var weatherSymbol: String?         // SF Symbol
      var temperature: String?           // "18,4 °C"
      var hourly: [Pair]                 // Luftfeuchte, Taupunkt, Wind, Bewölkung, Niederschlag
      var daily: [Pair]                  // Vortage, Tag (Min–Max, Mittel)
      var sky: [Pair]                    // Mond, Sonnenaufgang, Sonnenuntergang (Zeitzone der Probe)
      var climate: String?               // "Cfb · Submontane Stufe"
      var attribution: String?           // Quellen der angezeigten Features, ohne Dopplungen
      init(sample: LocalSample, features: [LocalSampleFeature], locale: Locale = Locale(identifier: "de_DE"))
  }
  ```

- [ ] **Step 1: Tests schreiben.** Zustände: ohne Koordinate → `.noCoordinate`; `pending` ohne nutzbare Höhe → `.waitingForElevation`; `pending` mit Höhe → `.pending`; leerer Status → `.legacy`; `final` ohne Wetterwerte → `.noData`, Sonne und Mond trotzdem in `sky`; `provisional` → `isProvisional`. Formate: `18,4 °C`, `62 %`, `0,0 mm`, `9 km/h`; ein Wert 0 erscheint, ein nicht gelieferter nicht. Ganztägige Probe: `hourly` leer, kein Symbol, keine Temperatur. Sonnenzeiten in der Zeitzone der Probe (`Atlantic/Canary`-Probe zeigt Kanaren-Zeit). `spoken` schreibt Einheiten aus („18,4 Grad Celsius“). `attribution` fasst gleiche Texte zusammen.
- [ ] **Step 2:** Testlauf → FAIL. **Step 3:** Implementieren (WMO-Code → SF Symbol als Tabelle in dieser Datei; der Text kommt aus dem Feature `tempus:weather`). **Step 4:** PASS. **Step 5:** Commit `feat(ios): Darstellungsmodell für Wetter und Klima`.

### Task 10: Bereich in der Sample-Ansicht

**Files:**
- Create: `ios/Legulus/Core/UI/ValuePairGrid.swift`, `ios/Legulus/Features/SampleEditor/Conditions/ConditionsSection.swift`
- Modify: `ios/Legulus/Features/SampleEditor/SampleEditorView.swift`, `.../SampleEditorViewModel.swift`, `ios/Legulus/Features/Debug/DesignCatalogView.swift`, `Localizable.xcstrings`
- Test: `ios/LegulusTests/Snapshots/ValuePairGridTests.swift`, Ergänzung in `ios/LegulusUITests/AccessibilityAuditTests.swift`

**Interfaces:**
- Consumes: `ConditionsDisplay`.
- Produces: `struct ValuePairGrid: View { init(_ pairs: [ConditionsDisplay.Pair]) }` (zwei Spalten, bei großen Schriften per `ViewThatFits` untereinander; jedes Paar ein kombiniertes VoiceOver-Element mit `spoken`), `struct ConditionsSection: View { init(display: ConditionsDisplay, onDetails: @escaping () -> Void) }`, im ViewModel `var conditionsDisplay: ConditionsDisplay`.

- [ ] **Step 1:** Snapshot-Test für `ValuePairGrid` (Default, AX5, Dark) und Erweiterung des Accessibility-Audits um die Sample-Ansicht mit Wetterbereich schreiben → FAIL bzw. neue Referenz.
- [ ] **Step 2:** Umsetzen. Der Bereich steht in `SampleEditorView.body` zwischen `locationTimeSection` und `MapSnippetView`, mit `SectionHeader(title: "Wetter und Klima")` und rechts daneben dem Text „vorläufig“ (Text, nicht nur Farbe). Texte der Zustände: „Wird ermittelt …“, „Wartet auf die Höhe des Fundorts“, „Ohne Koordinate keine Wetterdaten“, „Noch keine Wetterdaten“, „Keine Daten für diesen Zeitpunkt“. „Details“ ist ein `Button` mit mindestens 44 pt Höhe. Sonnenauf- und -untergang entfallen in `timeRow` und in `timeA11yLabel`; sie stehen jetzt im Wetterbereich. `ValuePairGrid` bekommt Doc-Comment, drei Previews und einen Katalog-Eintrag.
- [ ] **Step 3:** Anti-Pattern-Greps aus `ACCESSIBILITY-IOS.md` und `DESIGN-SYSTEM.md` über die geänderten Dateien → keine Treffer.
- [ ] **Step 4:** Testlauf → PASS, Snapshot-Referenzen (iOS 18, iOS 26) prüfen und committen.
- [ ] **Step 5:** Commit `feat(ios): Bereich „Wetter und Klima“ in der Sample-Ansicht`.

### Task 11: Detailseite

**Files:**
- Create: `ios/Legulus/Features/SampleEditor/Conditions/ConditionsDetailView.swift`, `.../ConditionsDetailModel.swift`
- Test: `ios/LegulusTests/ConditionsDetailModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct ConditionsDetailModel: Equatable {
      struct Group: Equatable, Identifiable { let id: String; let title: String; let rows: [ConditionsDisplay.Pair]
                                              let attribution: String?; let licenseName: String?; let licenseURL: URL? }
      var groups: [Group]                // Wetter, Aggregate, Klima, Sonne, Mond – in dieser Reihenfolge
      var queriedFor: String             // in der Zeitzone der Probe
      var fetchedAt: String
      var elevationNote: String          // "Werte für 520 m über dem Meer"
      init(sample: LocalSample, features: [LocalSampleFeature])
  }
  ```

- [ ] **Step 1: Tests schreiben** mit der Fixture `query_past_all_ok.json` (über den Mapper in lokale Features gewandelt): fünf Gruppen in der Reihenfolge, bekannte Properties mit deutschem Namen und Einheit, unbekannte Properties generisch als Name/Wert, verschachtelte Objekte flach mit Punkt-Pfad, Lizenzname und Link je Gruppe, Zeiten in der Zeitzone der Probe, fehlende Gruppe (z.B. Wetter in der Zukunft) entfällt.
- [ ] **Step 2:** FAIL. **Step 3:** Implementieren; die View ist eine `List` mit `Section` je Gruppe, Push aus dem Bereich. **Step 4:** PASS, Accessibility-Audit um die Detailseite ergänzen. **Step 5:** Commit `feat(ios): Detailseite für Wetter, Klima, Sonne und Mond`.

### Task 12: Abschluss PR 8b

- [ ] **Step 1:** `bash scripts/check-ios.sh` grün.
- [ ] **Step 2:** Im Simulator prüfen und im PR-Text vermerken: Bereich bei Standard-Schrift und AX5, VoiceOver-Reihenfolge über den Accessibility Inspector, alle fünf Zustände (über Proben in den passenden Zuständen).
- [ ] **Step 3:** `PHASES.md`: 8b abhaken nach dem Merge. PR öffnen, Copilot-Review abarbeiten. Gerätetest durch Jo.

## Nicht Teil dieses Plans

- PR 10 (Ablösung der eigenen Astronomie): `AstroPanel` und `fieldtrips.astro` bleiben bis dahin. In der Sample-Ansicht kommen Sonnenzeiten ab PR 8b aus Tempus; Proben ohne Tempus-Werte zeigen bis zum Backfill keine.
- Erneutes Abfragen vorläufiger Werte durch die App.
- Ein Backfill-Schritt für Altproben ohne Höhe mit Ortsstatus `manual` oder `backend_service`.
