@testable import Legulus
import LegulusGeo
import XCTest

/// Display rules for place fields (Phase O2, Task 17): level order,
/// country-specific terms with generic fallback, hidden empty fields,
/// the short list name and the MTB line.
final class PlaceDisplayTests: XCTestCase {
    private let ochsenfurt = Place(
        countryISO: "DE",
        admin: [
            .municipality: AdminValue(name: "Ochsenfurt", level: 8),
            .country: AdminValue(name: "Deutschland", level: 2),
            .county: AdminValue(name: "Landkreis Würzburg", level: 6),
            .state: AdminValue(name: "Bayern", level: 4),
            .region: AdminValue(name: "", level: 5)
        ]
    )

    func testFields_AreInLevelOrderWithCountryTermsAndSkipEmpty() {
        let items = PlaceDisplay.fields(ochsenfurt)
        XCTAssertEqual(items.map(\.value), ["Deutschland", "Bayern", "Landkreis Würzburg", "Ochsenfurt"],
                       "level order, empty region hidden")
        XCTAssertEqual(items.map(\.term), ["Staat", "Bundesland", "Landkreis", "Gemeinde"])
        XCTAssertEqual(items[1].genericLabel, "Gliedstaat (1. Ebene)")
        XCTAssertEqual(items[2].genericLabel, "Kreis")
    }

    func testFields_LandscapeFieldsFollowAdminFields() {
        var place = Place(countryISO: "ES",
                          admin: [.municipality: AdminValue(name: "Garafía", level: 8)])
        place.island = "La Palma"
        place.mountain = "Roque de los Muchachos"
        let items = PlaceDisplay.fields(place)
        XCTAssertEqual(items.map(\.value), ["Garafía", "La Palma", "Roque de los Muchachos"])
        XCTAssertEqual(items[0].term, "Municipio")
        XCTAssertNil(items[1].term, "no country term for landscape fields")
        XCTAssertEqual(items[1].genericLabel, "Insel")
        XCTAssertEqual(items[2].genericLabel, "Berg")
    }

    func testFields_UnknownCountryFallsBackToGenericLabel() {
        let place = Place(countryISO: "ZZ", admin: [.state: AdminValue(name: "Nowhere", level: 4)])
        let item = try? XCTUnwrap(PlaceDisplay.fields(place).first)
        XCTAssertNil(item?.term)
        XCTAssertEqual(item?.genericLabel, "Gliedstaat (1. Ebene)")
        XCTAssertEqual(item?.displayTerm, "Gliedstaat (1. Ebene)")
    }

    func testGenericLabels_German() {
        let expected: [String: String] = [
            "admin.country": "Staat", "admin.state": "Gliedstaat (1. Ebene)", "admin.region": "Region",
            "admin.province": "Provinz", "admin.county": "Kreis", "admin.district": "Bezirk",
            "admin.municipality": "Gemeinde", "admin.borough": "Stadtbezirk", "admin.parish": "Kirchspiel",
            "admin.submunicipality": "Ortsteil", "admin.other": "Sonstige Einheit", "place.island": "Insel",
            "place.mountain_range": "Gebirge", "place.mountain": "Berg"
        ]
        for (key, value) in expected {
            XCTAssertEqual(PlaceDisplay.genericLabel(key), value, key)
        }
    }

    func testShortName_MunicipalityElseNextHigherFilledLevel() {
        XCTAssertEqual(PlaceDisplay.shortName(ochsenfurt), "Ochsenfurt")
        var noMunicipality = ochsenfurt
        noMunicipality.admin[.municipality] = nil
        XCTAssertEqual(PlaceDisplay.shortName(noMunicipality), "Landkreis Würzburg")
        let onlyCountry = Place(countryISO: "DE", admin: [.country: AdminValue(name: "Deutschland", level: 2)])
        XCTAssertEqual(PlaceDisplay.shortName(onlyCountry), "Deutschland")
        XCTAssertNil(PlaceDisplay.shortName(nil))
        XCTAssertNil(PlaceDisplay.shortName(Place(countryISO: "DE")))
    }

    func testMTBText() {
        XCTAssertEqual(PlaceDisplay.mtbText(number: "6326", name: "Ochsenfurt", quadrant: 1, countryISO: "DE"),
                       "MTB 6326/1 Ochsenfurt")
        XCTAssertEqual(PlaceDisplay.mtbText(number: "6326", name: "Ochsenfurt", quadrant: nil, countryISO: nil),
                       "MTB 6326 Ochsenfurt")
        XCTAssertNil(PlaceDisplay.mtbText(number: "6326", name: "X", quadrant: 1, countryISO: "AT"), "only DE")
        XCTAssertNil(PlaceDisplay.mtbText(number: nil, name: "X", quadrant: 1, countryISO: "DE"))
        XCTAssertNil(PlaceDisplay.mtbText(number: "", name: "X", quadrant: 1, countryISO: "DE"))
    }

    /// The value without the „MTB“ label, for a separately styled label.
    func testMTBValue() {
        XCTAssertEqual(PlaceDisplay.mtbValue(number: "6326", name: "Ochsenfurt", quadrant: 1, countryISO: "DE"),
                       "6326/1 Ochsenfurt")
        XCTAssertNil(PlaceDisplay.mtbValue(number: "6326", name: "X", quadrant: 1, countryISO: "AT"), "only DE")
    }

    func testMatches_SearchesAllPlaceFieldsCaseAndDiacriticInsensitive() {
        XCTAssertTrue(PlaceDisplay.matches(ochsenfurt, query: "wurzburg"))
        XCTAssertTrue(PlaceDisplay.matches(ochsenfurt, query: "BAYERN"))
        XCTAssertFalse(PlaceDisplay.matches(ochsenfurt, query: "Tirol"))
        var palma = Place(countryISO: "ES")
        palma.mountainRange = "Caldera de Taburiente"
        XCTAssertTrue(PlaceDisplay.matches(palma, query: "taburiente"))
        XCTAssertTrue(PlaceDisplay.matches(ochsenfurt, query: "  "), "blank query matches")
    }

    // MARK: - sample view (Phase N)

    /// Admin data of `shared/testdata/ortus/expected_de_ochsenfurt.json`.
    private let ochsenfurtFixture = Place(
        countryISO: "DE",
        admin: [
            .country: AdminValue(name: "Deutschland", level: 2),
            .state: AdminValue(name: "Bayern", level: 4),
            .region: AdminValue(name: "Unterfranken", level: 5),
            .county: AdminValue(name: "Landkreis Würzburg", level: 6),
            .municipality: AdminValue(name: "Ochsenfurt", level: 8)
        ]
    )

    func testGazetteerLine_DEFixture_CountryThenBroadToNarrow() {
        XCTAssertEqual(PlaceDisplay.gazetteerLine(ochsenfurtFixture),
                       "Deutschland, Bayern, Unterfranken, Landkreis Würzburg, Ochsenfurt")
    }

    func testGazetteerLine_SkipsMissingAndEmptyLevels() {
        var place = ochsenfurtFixture
        place.admin[.region] = nil
        place.admin[.municipality] = AdminValue(name: "  ", level: 8)
        XCTAssertEqual(PlaceDisplay.gazetteerLine(place), "Deutschland, Bayern, Landkreis Würzburg")
        // `ochsenfurt` has an empty region.
        XCTAssertEqual(PlaceDisplay.gazetteerLine(ochsenfurt), "Deutschland, Bayern, Landkreis Würzburg, Ochsenfurt")
    }

    func testGazetteerLine_CountryFromISOWithoutAdminCountry_NoLandscape() {
        var place = Place(countryISO: "ES", admin: [.municipality: AdminValue(name: "Garafía", level: 8)])
        place.island = "La Palma"
        XCTAssertEqual(PlaceDisplay.gazetteerLine(place), "Spanien, Garafía")
    }

    func testGazetteerLine_NilWithoutData() {
        XCTAssertNil(PlaceDisplay.gazetteerLine(nil))
        XCTAssertNil(PlaceDisplay.gazetteerLine(Place(countryISO: "")))
    }

    // MARK: - „Ort“ card

    func testHeading_MunicipalityOverTwoBroaderLevelsAndISOCode() {
        XCTAssertEqual(PlaceDisplay.heading(ochsenfurtFixture),
                       PlaceDisplay.Heading(title: "Ochsenfurt", context: ["Landkreis Würzburg", "Unterfranken", "DE"]))
    }

    /// A district-free town is municipality and county at once; the
    /// duplicate is skipped.
    func testHeading_SkipsLevelsNamedLikeTheTitle() {
        let wuerzburg = Place(countryISO: "DE", admin: [
            .country: AdminValue(name: "Deutschland", level: 2),
            .state: AdminValue(name: "Bayern", level: 4),
            .region: AdminValue(name: "Unterfranken", level: 5),
            .county: AdminValue(name: "Würzburg", level: 6),
            .municipality: AdminValue(name: "Würzburg", level: 8),
            .submunicipality: AdminValue(name: "Heidingsfeld", level: 10)
        ])
        XCTAssertEqual(PlaceDisplay.heading(wuerzburg),
                       PlaceDisplay.Heading(title: "Würzburg", context: ["Unterfranken", "Bayern", "DE"]))
    }

    func testHeading_NilWithoutData() {
        XCTAssertNil(PlaceDisplay.heading(nil))
        XCTAssertNil(PlaceDisplay.heading(Place(countryISO: "DE")))
    }

    func testBearing_LeftOutWhenTheHeadingSaysIt() {
        XCTAssertEqual(PlaceDisplay.meaningfulBearing("2 km WNW Ochsenfurt", reference: "Ochsenfurt", distanceKm: 2.3,
                                                      inside: false, placeName: "Frickenhausen"),
                       "2km WNW Ochsenfurt", "unit at the number")
        XCTAssertNil(PlaceDisplay.meaningfulBearing("in Würzburg", reference: "Würzburg", distanceKm: 1.6,
                                                    inside: true, placeName: "Würzburg"))
        XCTAssertNil(PlaceDisplay.meaningfulBearing("in Würzburg", reference: nil, distanceKm: nil,
                                                    inside: false, placeName: "wurzburg"))
        XCTAssertEqual(PlaceDisplay.meaningfulBearing("in Heidingsfeld", reference: "Heidingsfeld", distanceKm: 0.4,
                                                      inside: true, placeName: "Würzburg"),
                       "in Heidingsfeld")
        XCTAssertEqual(PlaceDisplay.meaningfulBearing("in Würzburg", reference: "Würzburg", distanceKm: 0,
                                                      inside: true, placeName: nil),
                       "in Würzburg", "without a heading the bearing is all there is")
    }

    func testCompactUnits() {
        XCTAssertEqual(PlaceDisplay.compactUnits("2.3 km SW Randersacker"), "2.3km SW Randersacker")
        XCTAssertEqual(PlaceDisplay.compactUnits("800 m N Kist"), "800m N Kist")
        XCTAssertEqual(PlaceDisplay.compactUnits("in Ochsenfurt"), "in Ochsenfurt")
        XCTAssertEqual(PlaceDisplay.compactUnits("3 Mühlen"), "3 Mühlen", "only km and m")
    }

    func testLandscape_OnlyFilledFieldsInOrder() {
        var place = Place(countryISO: "ES", admin: [.municipality: AdminValue(name: "Garafía", level: 8)])
        place.island = "La Palma"
        place.mountain = "Roque de los Muchachos"
        XCTAssertEqual(PlaceDisplay.landscape(place).map(\.value), ["La Palma", "Roque de los Muchachos"])
        XCTAssertEqual(PlaceDisplay.landscape(place).map(\.displayTerm), ["Insel", "Berg"])
        XCTAssertTrue(PlaceDisplay.landscape(ochsenfurt).isEmpty)
        XCTAssertTrue(PlaceDisplay.landscape(nil).isEmpty)
    }

    func testBearing_NeverZeroKilometresOrBlank() {
        XCTAssertNil(PlaceDisplay.meaningfulBearing("0 km N Ochsenfurt", reference: "Ochsenfurt", distanceKm: 0.3,
                                                    inside: false, placeName: "Ochsenfurt"))
        XCTAssertNil(PlaceDisplay.meaningfulBearing(" ", reference: nil, distanceKm: nil, inside: false, placeName: nil))
    }

    private let german = Locale(identifier: "de_DE")

    func testExposure_WordedLikeOrtus() {
        XCTAssertEqual(PlaceDisplay.exposure(aspectCompass: "SW", aspectDeg: 233.6, slopeDeg: 6.54,
                                             terrainFlat: false, locale: german),
                       "SW (234°)-Exposition, 6,5° Neigung")
        XCTAssertEqual(PlaceDisplay.exposure(aspectCompass: "N", aspectDeg: nil, slopeDeg: nil,
                                             terrainFlat: false, locale: german),
                       "N-Exposition")
        XCTAssertEqual(PlaceDisplay.exposure(aspectCompass: " ", aspectDeg: nil, slopeDeg: 3,
                                             terrainFlat: false, locale: german),
                       "3,0° Neigung")
        XCTAssertNil(PlaceDisplay.exposure(aspectCompass: nil, aspectDeg: nil, slopeDeg: nil,
                                           terrainFlat: false, locale: german))
    }

    func testExposure_FlatTerrainShowsEbenWithSlope() {
        XCTAssertEqual(PlaceDisplay.exposure(aspectCompass: "SSW", aspectDeg: 202.5, slopeDeg: 0.44,
                                             terrainFlat: true, locale: german),
                       "eben (Neigung 0,4°)")
        XCTAssertEqual(PlaceDisplay.exposure(aspectCompass: nil, aspectDeg: nil, slopeDeg: nil,
                                             terrainFlat: true, locale: german),
                       "eben")
    }

    func testCoordinate_FollowsDisplayFormat() {
        let decimal = PlaceDisplay.coordinate(latitude: 49.681230, longitude: 10.031340, format: .decimalSign,
                                              locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(decimal.text, "+49,681230 +10,031340", "decimal comma, parts apart by a space")
        XCTAssertEqual(decimal.caption, "Geographische Koordinaten")

        let mgrs = PlaceDisplay.coordinate(latitude: 49.681230, longitude: 10.031340, format: .mgrs)
        XCTAssertTrue(mgrs.text.hasPrefix("32U NA 744"), mgrs.text)
        XCTAssertEqual(mgrs.caption, "MGRS")
    }

    func testGridSystemLabel_OnlyForGridFormats() {
        XCTAssertEqual(PlaceDisplay.gridSystemLabel(.mgrs, shownAs: "MGRS"), "MGRS")
        XCTAssertEqual(PlaceDisplay.gridSystemLabel(.utm, shownAs: "UTM"), "UTM")
        XCTAssertNil(PlaceDisplay.gridSystemLabel(.decimalSign, shownAs: "Geographische Koordinaten"))
        XCTAssertNil(PlaceDisplay.gridSystemLabel(.dmsDirection, shownAs: "Geographische Koordinaten"))
    }

    /// Near the pole UTM falls back to degrees; those get no „UTM“.
    func testGridSystemLabel_NotOnDegreeFallback() {
        let polar = PlaceDisplay.coordinate(latitude: 85, longitude: 10, format: .utm, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(polar.caption, "Geographische Koordinaten")
        XCTAssertNil(PlaceDisplay.gridSystemLabel(.utm, shownAs: polar.caption))
    }

    func testCountryName_German() {
        XCTAssertEqual(PlaceDisplay.countryName("DE"), "Deutschland")
        XCTAssertEqual(PlaceDisplay.countryName("ES"), "Spanien")
    }
}
