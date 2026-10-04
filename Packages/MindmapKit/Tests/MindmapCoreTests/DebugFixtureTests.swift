import Foundation
import Testing

/// Bundled debug fixtures must match the stable test inputs used for motion benchmarks.
@Test(arguments: ["sample", "large"])
func debugFixtureMatchesTestFixture(_ name: String) throws {
  let appCopy = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("../../../App/Debug/" + name + ".mindmap").standardized
  let source = fixtureURL.deletingLastPathComponent().appendingPathComponent(name + ".mindmap")
  #expect(try Data(contentsOf: appCopy) == Data(contentsOf: source))
}
