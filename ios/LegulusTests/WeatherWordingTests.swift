@testable import Legulus
import XCTest

final class WeatherWordingTests: XCTestCase {
    func testBeaufort_Calm() {
        XCTAssertEqual(WeatherWording.beaufort(kmh: 0), "Windstille")
    }

    func testBeaufort_LightBreeze() {
        XCTAssertEqual(WeatherWording.beaufort(kmh: 8), "leichte Brise")
    }

    /// 5,5 m/s = 19,8 km/h is the lower bound of force 4.
    func testBeaufort_BoundBelongsToHigherForce() {
        XCTAssertEqual(WeatherWording.beaufort(kmh: 19.8), "mäßige Brise")
        XCTAssertEqual(WeatherWording.beaufort(kmh: 19.7), "schwache Brise")
    }

    /// 28,5 m/s = 102,6 km/h; 102.6 / 3.6 is 28.4999… in floating point.
    func testBeaufort_BoundSurvivesFloatingPoint() {
        XCTAssertEqual(WeatherWording.beaufort(kmh: 102.6), "orkanartiger Sturm")
    }

    func testBeaufort_Hurricane() {
        XCTAssertEqual(WeatherWording.beaufort(kmh: 130), "Orkan")
    }

    func testHumidityFeeling_Steps() {
        XCTAssertEqual(WeatherWording.humidityFeeling(dewPointC: 9.9), "trocken")
        XCTAssertEqual(WeatherWording.humidityFeeling(dewPointC: 13.5), "leicht feucht")
        XCTAssertEqual(WeatherWording.humidityFeeling(dewPointC: 18), "schwül")
        XCTAssertEqual(WeatherWording.humidityFeeling(dewPointC: 30), "drückend")
    }
}
