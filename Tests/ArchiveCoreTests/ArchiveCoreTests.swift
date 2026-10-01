import CArchive
import Testing
@testable import ArchiveCore

@Test func linksSystemLibarchive() {
    let version = String(cString: archive_version_string())
    #expect(version.hasPrefix("libarchive 3."))
}
