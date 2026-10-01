import Foundation
import Testing
@testable import ArchiveCore

struct CreateExtractTests {
    let scratch: Scratch
    init() throws { scratch = try Scratch() }

    @Test(arguments: WritableFormat.allCases)
    func roundTrip(_ format: WritableFormat) throws {
        let tree = try makeTree(in: scratch["src"])
        let archive = scratch["out.\(format.fileExtension)"]
        try Archive.create([tree], at: archive, format: format)

        let listing = try Archive.list(archive)
        #expect(listing.writableFormat == format)
        #expect(listing.formatName == format.displayName)
        #expect(!listing.hasEncryptedEntries)
        #expect(listing.archiveSize == Int64(try Data(contentsOf: archive).count))
        #expect(Set(listing.entries.map(\.path)) == ["tree", "tree/a.txt", "tree/sub", "tree/sub/b.txt", "tree/sub/zero.txt",
                                                       "tree/sub/deeper", "tree/sub/deeper/c.txt", "tree/café 日本 😀.txt",
                                                       "tree/empty", "tree/link"])
        #expect(Set(listing.children(of: "tree").map(\.name)) == ["a.txt", "sub", "café 日本 😀.txt", "empty", "link"])
        #expect(listing.children(of: "").map(\.path) == ["tree"])
        let a = try #require(listing.entries.first { $0.path == "tree/a.txt" })
        #expect(a.size == 6 && !a.isDirectory && !a.isSymlink && a.modified != nil && a.parent == "tree")
        #expect(listing.entries.first { $0.path == "tree/link" }?.isSymlink == true)
        #expect(listing.entries.first { $0.path == "tree/empty" }?.isDirectory == true)

        let out = scratch["extracted"]
        try Archive.extract(listing, to: out)
        #expect(names(in: out) == ["tree"])
        #expect(snapshot(out.appendingPathComponent("tree")) == snapshot(tree))
    }

    @Test(arguments: [WritableFormat.zip, .sevenZip, .tarGz, .tarBz2, .tarXz])
    func compressionLevels(_ format: WritableFormat) throws {
        let file = scratch["data.txt"]
        try write((0..<60_000).map { "line \($0): \($0 * 7919 % 10007)\n" }.joined(), to: file)
        var sizes: [CompressionLevel: Int64] = [:]
        for level in CompressionLevel.allCases {
            let archive = scratch["\(level).\(format.fileExtension)"]
            try Archive.create([file], at: archive, format: format, level: level)
            let listing = try Archive.list(archive)
            sizes[level] = listing.archiveSize
            try Archive.extract(listing, to: scratch["out-\(level)"])
            #expect(read(scratch["out-\(level)/data.txt"]) == read(file))
        }
        // bzip2's levels are block sizes, which don't always shrink the output; they must still change it.
        if format == .tarBz2 {
            #expect(sizes[.best]! != sizes[.fast]!, "\(sizes)")
        } else {
            #expect(sizes[.best]! < sizes[.fast]!, "\(sizes)")
        }
    }

    @Test func aesZip() throws {
        let tree = try makeTree(in: scratch["src"])
        let archive = scratch["secret.zip"]
        try Archive.create([tree], at: archive, format: .zip, passphrase: "s3cret")
        let strengths = try zipAESStrengths(archive)
        #expect(!strengths.isEmpty && strengths.allSatisfy { $0 == 3 }, "AES-256: \(strengths)")

        let listing = try Archive.list(archive)
        #expect(listing.hasEncryptedEntries)
        // libarchive encrypts every file with data; an empty file has nothing to encrypt.
        #expect(listing.entries.filter { $0.size > 0 }.allSatisfy { $0.isEncrypted })
        #expect(throws: ArchiveError.passphraseRequired) { try Archive.extract(listing, to: self.scratch["none"]) }
        #expect(throws: ArchiveError.wrongPassphrase) { try Archive.extract(listing, to: self.scratch["wrong"], passphrase: "nope") }
        // A failed attempt leaves no files, only folders created before it.
        #expect(snapshot(scratch["none"]).values.allSatisfy { $0 == "dir" })
        #expect(snapshot(scratch["wrong"]).values.allSatisfy { $0 == "dir" })

        let out = scratch["right"]
        try Archive.extract(listing, to: out, passphrase: "s3cret")
        #expect(snapshot(out.appendingPathComponent("tree")) == snapshot(tree))

        // A wrong passphrase fails before an existing file would be replaced.
        try write("mine\n", to: out.appendingPathComponent("tree/a.txt"))
        let before = snapshot(out)
        #expect(throws: ArchiveError.wrongPassphrase) { try Archive.extract(listing, to: out, passphrase: "nope") }
        #expect(snapshot(out) == before)

        #expect(throws: ArchiveError.unsupportedEncryption("7-Zip")) {
            try Archive.create([tree], at: self.scratch["secret.7z"], format: .sevenZip, passphrase: "s3cret")
        }
        #expect(!exists(scratch["secret.7z"]))
    }

    @Test func encrypted7zAndRarAreReportedAsUnsupported() throws {
        let sevenZip = try Archive.list(try Fixture.sevenZipEncryptedData.write(to: scratch.url, as: "data.7z"))
        #expect(sevenZip.hasEncryptedEntries && sevenZip.entries.map(\.path) == ["bar.txt"])
        #expect(throws: ArchiveError.unsupportedEncryption("7-Zip")) { try Archive.extract(sevenZip, to: self.scratch["out"]) }
        #expect(throws: ArchiveError.unsupportedEncryption("7-Zip")) { try Archive.extract(sevenZip, to: self.scratch["out"], passphrase: "x") }
        #expect(throws: ArchiveError.unsupportedEncryption("7-Zip")) { try Archive.rewrite(sevenZip, removing: ["bar.txt"], passphrase: "x") }
        #expect(throws: ArchiveError.unsupportedEncryption("7-Zip")) {
            try Archive.list(try Fixture.sevenZipEncryptedHeader.write(to: self.scratch.url, as: "header.7z"))
        }

        let rar = try Archive.list(try Fixture.rarEncryptedData.write(to: scratch.url, as: "data.rar"))
        #expect(rar.hasEncryptedEntries && rar.entries.map(\.path) == ["foo.txt", "bar.txt"])
        #expect(throws: ArchiveError.unsupportedEncryption("RAR")) { try Archive.extract(rar, to: self.scratch["out"]) }
        #expect(throws: ArchiveError.unsupportedEncryption("RAR")) {
            try Archive.list(try Fixture.rarEncryptedHeader.write(to: self.scratch.url, as: "header.rar"))
        }
        #expect(names(in: scratch["out"]).isEmpty)
    }

    @Test func excludeJunk() throws {
        let tree = try makeTree(in: scratch["src"])
        try write("junk", to: tree.appendingPathComponent(".DS_Store"))
        try write("junk", to: tree.appendingPathComponent("sub/._b.txt"))
        try write("junk", to: tree.appendingPathComponent("__MACOSX/._a.txt"))
        try write("keep", to: tree.appendingPathComponent(".hidden"))

        try Archive.create([tree], at: scratch["clean.zip"], format: .zip)
        let clean = Set(try Archive.list(scratch["clean.zip"]).entries.map(\.path))
        #expect(clean.contains("tree/.hidden") && clean.contains("tree/sub/b.txt"))
        #expect(clean.isDisjoint(with: ["tree/.DS_Store", "tree/sub/._b.txt", "tree/__MACOSX", "tree/__MACOSX/._a.txt"]))

        try Archive.create([tree], at: scratch["all.zip"], format: .zip, excludeJunk: false)
        let all = Set(try Archive.list(scratch["all.zip"]).entries.map(\.path))
        #expect(all.isSuperset(of: ["tree/.DS_Store", "tree/sub/._b.txt", "tree/__MACOSX", "tree/__MACOSX/._a.txt", "tree/.hidden"]))
    }

    @Test(arguments: WritableFormat.allCases)
    func noAbsolutePathsOrMetadata(_ format: WritableFormat) throws {
        let tree = try makeTree(in: scratch["src"])
        let tagged = tree.appendingPathComponent("xattr.txt")
        try write("has an extended attribute\n", to: tagged)
        let value = "crate-test-value"
        #expect(setxattr(tagged.path, "com.crate.test", value, value.utf8.count, 0, 0) == 0)

        let archive = scratch["meta.\(format.fileExtension)"]
        try Archive.create([tree], at: archive, format: format)
        let members = try run("/usr/bin/bsdtar", ["-tf", archive.path]).split(separator: "\n")
        #expect(!members.isEmpty && members.allSatisfy { !$0.hasPrefix("/") && $0.hasPrefix("tree") })
        #expect(try Archive.list(archive).entries.allSatisfy { !$0.name.hasPrefix("._") })
        let bytes = try decompressedBytes(archive)
        #expect(bytes.range(of: Data("com.crate.test".utf8)) == nil)
        #expect(bytes.range(of: Data("._xattr".utf8)) == nil)
    }

    @Test(arguments: [WritableFormat.zip, .sevenZip, .tarGz])
    func partialExtract(_ format: WritableFormat) throws {
        let tree = try makeTree(in: scratch["src"])
        let archive = scratch["t.\(format.fileExtension)"]
        try Archive.create([tree], at: archive, format: format)
        let listing = try Archive.list(archive)

        // A file lands directly in the destination.
        try Archive.extract(listing, paths: ["tree/sub/b.txt"], to: scratch["file"])
        #expect(snapshot(scratch["file"]) == ["b.txt": "file:bravo\n"])

        // A folder comes with everything below it.
        try Archive.extract(listing, paths: ["tree/sub"], to: scratch["folder"])
        #expect(snapshot(scratch["folder"]) == ["sub": "dir", "sub/b.txt": "file:bravo\n", "sub/zero.txt": "file:",
                                                "sub/deeper": "dir", "sub/deeper/c.txt": "file:charlie\n"])

        // Paths from different folders keep what's below their deepest common folder.
        try Archive.extract(listing, paths: ["tree/link", "tree/sub/deeper/c.txt"], to: scratch["mixed"])
        #expect(snapshot(scratch["mixed"]) == ["link": "link:a.txt", "sub": "dir", "sub/deeper": "dir",
                                               "sub/deeper/c.txt": "file:charlie\n"])
    }

    @Test func smartExtractDestination() throws {
        let tree = try makeTree(in: scratch["src"])
        let here = scratch["here"]
        try FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)

        // One top-level folder: extract right here.
        try Archive.create([tree], at: scratch["single.tar.gz"], format: .tarGz)
        let single = try Archive.list(scratch["single.tar.gz"])
        var (destination, item) = Archive.smartExtractDestination(single, in: here)
        #expect(destination.path == here.path && item.path == here.appendingPathComponent("tree").path)
        try Archive.extract(single, to: destination)
        #expect(snapshot(item) == snapshot(tree))

        // Once "tree" exists, use a folder named after the archive instead of merging.
        (destination, item) = Archive.smartExtractDestination(single, in: here)
        #expect(destination.path == here.appendingPathComponent("single").path && item == destination)

        // Several top-level items: a folder named after the archive ("multi.tar.gz" → "multi"), then "multi 2".
        try Archive.create([tree.appendingPathComponent("a.txt"), tree.appendingPathComponent("sub")],
                           at: scratch["multi.tar.gz"], format: .tarGz)
        let multi = try Archive.list(scratch["multi.tar.gz"])
        #expect(Archive.smartExtractDestination(multi, in: here).destination.lastPathComponent == "multi")
        try FileManager.default.createDirectory(at: here.appendingPathComponent("multi"), withIntermediateDirectories: true)
        (destination, item) = Archive.smartExtractDestination(multi, in: here)
        #expect(destination.lastPathComponent == "multi 2" && item == destination)
        try Archive.extract(multi, to: destination)
        #expect(Set(snapshot(destination).keys) == ["a.txt", "sub", "sub/b.txt", "sub/zero.txt", "sub/deeper", "sub/deeper/c.txt"])

        // uniqueURL keeps compound extensions.
        try write("x", to: here.appendingPathComponent("Archive.tar.gz"))
        #expect(Archive.uniqueURL(in: here, name: "Archive", extension: "tar.gz").lastPathComponent == "Archive 2.tar.gz")
        #expect(Archive.uniqueURL(in: here, name: "Archive", extension: "zip").lastPathComponent == "Archive.zip")
    }

    @Test func conflictsAndSkip() throws {
        let tree = try makeTree(in: scratch["src"])
        try Archive.create([tree], at: scratch["t.zip"], format: .zip)
        let listing = try Archive.list(scratch["t.zip"])
        let dest = scratch["dest"]
        #expect(Archive.conflicts(listing, in: dest).isEmpty)

        try Archive.extract(listing, to: dest)
        #expect(Set(Archive.conflicts(listing, in: dest)) == Set(listing.entries.filter { !$0.isDirectory }.map(\.path)))

        let a = dest.appendingPathComponent("tree/a.txt")
        let b = dest.appendingPathComponent("tree/sub/b.txt")
        try write("edited\n", to: a)
        try FileManager.default.removeItem(at: b)
        #expect(!Archive.conflicts(listing, in: dest).contains("tree/sub/b.txt"))
        try Archive.extract(listing, to: dest, overwrite: .skip)
        #expect(read(a) == "edited\n")
        #expect(read(b) == "bravo\n")
        try Archive.extract(listing, to: dest, overwrite: .replace)
        #expect(read(a) == "alpha\n")

        // Partial selections are checked where `extract` would put them.
        #expect(Archive.conflicts(listing, paths: ["tree/sub/b.txt"], in: dest).isEmpty)
        try write("other\n", to: dest.appendingPathComponent("b.txt"))
        #expect(Archive.conflicts(listing, paths: ["tree/sub/b.txt"], in: dest) == ["tree/sub/b.txt"])
        // A file where a folder goes conflicts too, and replacing turns it into the folder.
        try write("not a folder\n", to: dest.appendingPathComponent("deeper"))
        #expect(Archive.conflicts(listing, paths: ["tree/sub/deeper"], in: dest) == ["tree/sub/deeper"])
        try Archive.extract(listing, paths: ["tree/sub/deeper"], to: dest)
        #expect(read(dest.appendingPathComponent("deeper/c.txt")) == "charlie\n")
        // An empty folder where a file goes is replaced by the file.
        try FileManager.default.removeItem(at: a)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        #expect(Archive.conflicts(listing, paths: ["tree/a.txt"], in: dest.appendingPathComponent("tree")) == ["tree/a.txt"])
        try Archive.extract(listing, paths: ["tree/a.txt"], to: dest.appendingPathComponent("tree"))
        #expect(read(a) == "alpha\n")
    }

    @Test func singleCompressedFiles() throws {
        try write("just one file\n", to: scratch["notes.txt"])
        // gzip stores "notes.txt" in its header; the entry is named after the archive file instead.
        try run("/usr/bin/gzip", ["-k", scratch["notes.txt"].path])
        try FileManager.default.moveItem(at: scratch["notes.txt.gz"], to: scratch["renamed.txt.gz"])
        try run("/usr/bin/bzip2", ["-k", scratch["notes.txt"].path])
        for (file, format) in [("renamed.txt.gz", "GZIP"), ("notes.txt.bz2", "BZIP2")] {
            let listing = try Archive.list(scratch[file])
            let name = (file as NSString).deletingPathExtension
            #expect(listing.entries.map(\.path) == [name])
            #expect(listing.formatName == format && !listing.isEditable)
            let here = scratch["out-\(format)"]
            let (destination, item) = Archive.smartExtractDestination(listing, in: here)
            #expect(destination.path == here.path && item.lastPathComponent == name)
            try Archive.extract(listing, to: destination)
            #expect(read(item) == "just one file\n")
        }
        // Neither an archive nor compressed: an error, not a one-entry listing.
        #expect(throws: ArchiveError.self) { try Archive.list(self.scratch["notes.txt"]) }
        #expect(throws: ArchiveError.self) { try Archive.list(self.scratch["missing.zip"]) }
    }

    @Test func readOnlyFormats() throws {
        let tree = try makeTree(in: scratch["src"])
        let rar5 = try Archive.list(try Fixture.rar5.write(to: scratch.url, as: "hello.rar"))
        #expect(rar5.formatName == "RAR5" && !rar5.isEditable)
        try Archive.extract(rar5, to: scratch["rar5"])
        #expect(snapshot(scratch["rar5"]) == ["helloworld.txt": "file:hello libarchive test suite!\n"])

        let rar = try Archive.list(try Fixture.rar.write(to: scratch.url, as: "old.rar"))
        #expect(rar.formatName == "RAR" && rar.entries.first { $0.path == "testlink" }?.isSymlink == true)
        try Archive.extract(rar, paths: ["testdir"], to: scratch["rar"])
        #expect(snapshot(scratch["rar"]) == ["testdir": "dir", "testdir/test.txt": "file:test text document\r\n"])

        try run("/usr/bin/bsdtar", ["--format", "iso9660", "-cf", scratch["t.iso"].path, "-C", tree.deletingLastPathComponent().path, "tree"])
        try run("/usr/bin/bsdtar", ["--format", "newc", "-cf", scratch["t.cpio"].path, "-C", tree.deletingLastPathComponent().path, "tree"])
        for file in ["t.iso", "t.cpio"] {
            let listing = try Archive.list(scratch[file])
            #expect(!listing.isEditable && listing.entries.contains { $0.path == "tree/sub/deeper/c.txt" })
            try Archive.extract(listing, paths: ["tree/sub/deeper/c.txt"], to: scratch["out-\(file)"])
            #expect(read(scratch["out-\(file)/c.txt"]) == "charlie\n")
            #expect(throws: ArchiveError.notEditable) { try Archive.rewrite(listing, removing: ["tree/a.txt"]) }
        }
        #expect(throws: ArchiveError.notEditable) { try Archive.rewrite(rar5, removing: ["helloworld.txt"]) }
        #expect(throws: ArchiveError.notEditable) { try Archive.rewrite(rar, removing: ["test.txt"]) }
    }

    @Test func listingNormalizesPaths() throws {
        let archive = scratch["odd.tar"]
        try craftTar(archive, [.directory("./"), .file("./dup.txt", "one"), .file("a/b/c.txt", "c"),
                               .file("//dup.txt", "second"), .directory("a/")])
        let listing = try Archive.list(archive)
        // "./" is dropped, implied folders are added, a repeated path keeps its last copy.
        #expect(listing.entries.map(\.path) == ["dup.txt", "a", "a/b", "a/b/c.txt"])
        #expect(listing.entries[0].size == 6)
        #expect(listing.entries[1].modified != nil && listing.entries[2].modified == nil)
        #expect(listing.children(of: "").map(\.path) == ["dup.txt", "a"])
        #expect(listing.children(of: "a/b").map(\.name) == ["c.txt"])
        #expect(listing.children(of: "./a/b/").map(\.name) == ["c.txt"])
        #expect(listing.children(of: "missing").isEmpty)
    }

    @Test func cancellingLeavesNothingBehind() throws {
        try writeRandom(bytes: 3_000_000, to: scratch["src/big.bin"])
        for format in [WritableFormat.zip, .sevenZip, .tarXz] {
            let archive = scratch["c.\(format.fileExtension)"]
            var calls = 0
            #expect(throws: ArchiveError.cancelled) {
                try Archive.create([self.scratch["src"]], at: archive, format: format) { _ in
                    calls += 1
                    return calls < 3  // cancel partway through big.bin
                }
            }
            #expect(!exists(archive))
        }
        #expect(names(in: scratch.url) == ["src"])

        // Extraction: the file being written is removed.
        try Archive.create([scratch["src"]], at: scratch["big.zip"], format: .zip)
        let listing = try Archive.list(scratch["big.zip"])
        var calls = 0
        #expect(throws: ArchiveError.cancelled) {
            try Archive.extract(listing, to: self.scratch["out"]) { _ in
                calls += 1
                return calls < 3
            }
        }
        #expect(snapshot(scratch["out"]) == ["src": "dir"])
    }
}
