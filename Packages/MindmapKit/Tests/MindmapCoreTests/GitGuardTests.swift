import Foundation
import MindmapCore
import Testing

@Test func gitGuardFindsRepoAboveAndBelow() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let fm = FileManager.default
  let plain = root.appendingPathComponent("plain/maps")
  let repo = root.appendingPathComponent("repo")
  try fm.createDirectory(at: plain, withIntermediateDirectories: true)
  try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
  try fm.createDirectory(at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)

  #expect(GitGuard.workTree(around: plain) == nil)
  #expect(
    GitGuard.workTree(around: repo.appendingPathComponent("sub"))?.lastPathComponent == "repo")
  #expect(GitGuard.workTree(around: root)?.lastPathComponent == "repo")
  #expect(GitGuard.workTree(around: root, scanDescendants: false) == nil)
  #expect(
    GitGuard.workTree(around: repo.appendingPathComponent("sub"), scanDescendants: false)?
      .lastPathComponent == "repo")
  #expect(GitGuard.workTree(around: repo, scanDescendants: false) == nil)
  #expect(GitGuard.workTree(around: repo)?.lastPathComponent == "repo")
}
