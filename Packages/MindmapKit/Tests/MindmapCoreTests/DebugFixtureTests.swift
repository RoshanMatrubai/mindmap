import Foundation
import Testing

/// App/Debug/sample.mindmap (bundled into Debug builds for `-fixture sample`) must match the test fixture.
@Test func debugFixtureMatchesTestFixture() throws {
  let appCopy = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("../../../App/Debug/sample.mindmap").standardized
  #expect(try Data(contentsOf: appCopy) == Data(contentsOf: fixtureURL))
}
