@testable import ReadiumNavigator
import ReadiumShared
import XCTest

final class ExplicitColumnTests: XCTestCase {
    func testExplicitColumnsBypassLegacyResponsiveFloor() throws {
        var css = ReadiumCSS(baseURL: try XCTUnwrap(HTTPURL(string: "https://example.com/css/")))
        for (count, expected) in [(ColumnCount.two, "2"), (.one, "1")] {
            css.update(with: EPUBSettings(preferences: EPUBPreferences(columnCount: count), defaults: EPUBDefaults(), metadata: Metadata(title: "Test")))
            let props = css.userProperties.cssProperties()
            XCTAssertEqual(props["column-count"]!, expected)
            XCTAssertEqual(props["column-width"]!, "auto")
        }
        for preferences in [EPUBPreferences(columnCount: .auto), EPUBPreferences(columnCount: .two, scroll: true), EPUBPreferences(columnCount: .two, verticalText: true)] {
            css.update(with: EPUBSettings(preferences: preferences, defaults: EPUBDefaults(), metadata: Metadata(title: "Test")))
            let props = css.userProperties.cssProperties()
            XCTAssertEqual(props["column-count"]!, "")
            XCTAssertEqual(props["column-width"]!, "")
        }
    }
}
