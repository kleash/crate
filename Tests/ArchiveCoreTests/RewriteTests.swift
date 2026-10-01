import Foundation
import Testing
@testable import ArchiveCore

struct RewriteTests {
    let scratch: Scratch
    init() throws { scratch = try Scratch() }

    @Test(arguments: [WritableFormat.zip, .tarGz, .sevenZip])
    func addRemoveReplace(_ format: WritableFormat) throws {
        let tree = try makeTree(in: scratch["src"])
        let archive = scratch["t.\(format.fileExtension)"]
        try Archive.create([tree], at: archive, format: format)
        try write("new\n", to: scratch["add/new.txt"])
        try write("bravo v2\n", to: scratch["add/b.txt"])
        try write("only\n", to: scratch["add/sub/only.txt"])

        // Remove a file and a folder, add a file.
        try Archive.rewrite(try Archive.list(archive), removing: ["tree/a.txt", "tree/sub/deeper"],
                            adding: [scratch["add/new.txt"]], into: "tree")
        var listing = try Archive.list(archive)
        #expect(listing.writableFormat == format)
        #expect(Set(listing.entries.map(\.path)) == ["tree", "tree/sub", "tree/sub/b.txt", "tree/sub/zero.txt",
                                                       "tree/café 日本 😀.txt", "tree/empty", "tree/link", "tree/new.txt"])

        // Adding a file whose path exists replaces it.
        try Archive.rewrite(listing, adding: [scratch["add/b.txt"]], into: "tree/sub")
        listing = try Archive.list(archive)
        #expect(listing.entries.filter { $0.path == "tree/sub/b.txt" }.count == 1)
        try Archive.extract(listing, to: scratch["out1"])
        #expect(read(scratch["out1/tree/sub/b.txt"]) == "bravo v2\n")
        #expect(read(scratch["out1/tree/new.txt"]) == "new\n")
        #expect(snapshot(scratch["out1/tree"])["link"] == "link:a.txt")

        // Adding a folder whose path exists replaces the whole folder.
        try Archive.rewrite(listing, adding: [scratch["add/sub"]], into: "tree")
        listing = try Archive.list(archive)
        #expect(listing.children(of: "tree/sub").map(\.path) == ["tree/sub/only.txt"])

        // Adding at the top level.
        try Archive.rewrite(listing, adding: [scratch["add/new.txt"]])
        #expect(try Archive.list(archive).children(of: "").map(\.path).sorted() == ["new.txt", "tree"])
        #expect(names(in: scratch.url) == ["add", "out1", "src", archive.lastPathComponent].sorted())
    }

    @Test func encryptedZip() throws {
        let tree = try makeTree(in: scratch["src"])
        let archive = scratch["secret.zip"]
        try Archive.create([tree], at: archive, format: .zip, passphrase: "pw")
        try write("added\n", to: scratch["new.txt"])
        let listing = try Archive.list(archive)
        let original = try Data(contentsOf: archive)

        #expect(throws: ArchiveError.passphraseRequired) { try Archive.rewrite(listing, removing: ["tree/a.txt"]) }
        #expect(throws: ArchiveError.wrongPassphrase) { try Archive.rewrite(listing, removing: ["tree/a.txt"], passphrase: "bad") }
        #expect(try Data(contentsOf: archive) == original)

        try Archive.rewrite(listing, removing: ["tree/a.txt"], adding: [scratch["new.txt"]], into: "tree", passphrase: "pw")
        let after = try Archive.list(archive)
        #expect(after.entries.filter { $0.size > 0 }.allSatisfy { $0.isEncrypted })
        #expect(after.entries.contains { $0.path == "tree/new.txt" } && !after.entries.contains { $0.path == "tree/a.txt" })
        let strengths = try zipAESStrengths(archive)
        #expect(!strengths.isEmpty && strengths.allSatisfy { $0 == 3 })
        #expect(throws: ArchiveError.passphraseRequired) { try Archive.extract(after, to: self.scratch["none"]) }
        try Archive.extract(after, to: scratch["out"], passphrase: "pw")
        #expect(read(scratch["out/tree/new.txt"]) == "added\n")
        #expect(read(scratch["out/tree/sub/b.txt"]) == "bravo\n")
    }

    @Test func cancellingKeepsTheOriginal() throws {
        let tree = try makeTree(in: scratch["src"])
        try writeRandom(bytes: 3_000_000, to: scratch["big.bin"])
        let archive = scratch["t.tar.xz"]
        try Archive.create([tree], at: archive, format: .tarXz)
        let original = try Data(contentsOf: archive)
        var calls = 0
        #expect(throws: ArchiveError.cancelled) {
            try Archive.rewrite(try Archive.list(archive), adding: [self.scratch["big.bin"]]) { _ in
                calls += 1
                return calls < 3
            }
        }
        #expect(try Data(contentsOf: archive) == original)
        #expect(names(in: scratch.url) == ["big.bin", "src", "t.tar.xz"])
    }
}
