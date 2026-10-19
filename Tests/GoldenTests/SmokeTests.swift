import Testing
import Foundation

/// Golden-frame tests need reference exports; they skip unless `REFS_DIR` is set.
@Test(.enabled(if: ProcessInfo.processInfo.environment["REFS_DIR"] != nil))
func refsDirExists() {
    let dir = ProcessInfo.processInfo.environment["REFS_DIR"] ?? ""
    #expect(FileManager.default.fileExists(atPath: dir))
}
