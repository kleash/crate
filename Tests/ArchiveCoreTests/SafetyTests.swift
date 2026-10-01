import Foundation
import Testing
@testable import ArchiveCore

/// Hostile archives must not write outside the destination folder.
struct SafetyTests {
    let scratch: Scratch
    /// A sibling of every destination, holding one file the attacks aim at.
    let outside: URL
    init() throws {
        scratch = try Scratch()
        outside = scratch["outside"]
        try write("secret\n", to: outside.appendingPathComponent("secret.txt"))
    }

    func extract(_ entries: [Crafted], to dest: URL) throws {
        let archive = scratch["evil-\(UUID().uuidString).tar"]
        try craftTar(archive, entries)
        try Archive.extract(try Archive.list(archive), to: dest)
    }

    @Test func dotDotIsRejected() throws {
        let dest = scratch["dest"]
        #expect(throws: ArchiveError.unsafePath("../outside/escape.txt")) {
            try self.extract([.file("ok.txt", "ok\n"), .file("../outside/escape.txt", "pwned\n")], to: dest)
        }
        #expect(throws: ArchiveError.unsafePath("a/../../outside/escape.txt")) {
            try self.extract([.file("a/../../outside/escape.txt", "pwned\n")], to: dest)
        }
        #expect(snapshot(outside) == ["secret.txt": "file:secret\n"])
        #expect(snapshot(dest) == ["ok.txt": "file:ok\n"])
    }

    @Test func absolutePathsLandInside() throws {
        let dest = scratch["dest"]
        let absolute = outside.appendingPathComponent("abs.txt").path
        try extract([.file(absolute, "pwned\n")], to: dest)
        #expect(!exists(outside.appendingPathComponent("abs.txt")))
        #expect(read(dest.appendingPathComponent(String(absolute.dropFirst()))) == "pwned\n")
    }

    @Test func symlinksCannotBeWrittenThrough() throws {
        // A link in the archive pointing outside, then a file "through" it.
        let dest = scratch["dest"]
        try extract([.symlink("link", outside.path), .file("link/through.txt", "pwned\n")], to: dest)
        #expect(snapshot(outside) == ["secret.txt": "file:secret\n"])
        #expect(snapshot(dest) == ["link": "dir", "link/through.txt": "file:pwned\n"])

        // A link that already exists in the destination.
        try FileManager.default.createSymbolicLink(at: dest.appendingPathComponent("pre"), withDestinationURL: outside)
        try extract([.file("pre/through.txt", "pwned\n"), .file("pre/secret.txt", "pwned\n")], to: dest)
        #expect(snapshot(outside) == ["secret.txt": "file:secret\n"])

        // Replacing a link to an outside file replaces the link, not the file.
        try FileManager.default.createSymbolicLink(at: dest.appendingPathComponent("s.txt"),
                                                   withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try extract([.file("s.txt", "pwned\n")], to: dest)
        #expect(snapshot(outside) == ["secret.txt": "file:secret\n"])
        #expect(read(dest.appendingPathComponent("s.txt")) == "pwned\n")
    }

    @Test func replacingNeverRemovesThroughASymlink() throws {
        // A file entry below a link to an outside folder, where that folder has a subfolder of the same name:
        // replacing a folder with a file must not remove outside/victim.
        try write("keep\n", to: outside.appendingPathComponent("victim/keep.txt"))
        let dest = scratch["dest"]
        try extract([.symlink("link", outside.path), .file("link/victim", "pwned\n")], to: dest)
        try FileManager.default.createSymbolicLink(at: dest.appendingPathComponent("pre"), withDestinationURL: outside)
        try extract([.file("pre/victim", "pwned\n")], to: dest)
        #expect(snapshot(outside) == ["secret.txt": "file:secret\n", "victim": "dir", "victim/keep.txt": "file:keep\n"])
        #expect(snapshot(dest) == ["link": "dir", "link/victim": "file:pwned\n", "pre": "dir", "pre/victim": "file:pwned\n"])
    }

    @Test func hardLinksStayInside() throws {
        let dest = scratch["dest"]
        #expect(throws: ArchiveError.unsafePath("../outside/secret.txt")) {
            try self.extract([.hardlink("h.txt", "../outside/secret.txt", "pwned\n")], to: dest)
        }
        // An absolute target is looked up inside the destination, where it doesn't exist.
        #expect(throws: ArchiveError.self) {
            try self.extract([.hardlink("h.txt", self.outside.appendingPathComponent("secret.txt").path, "pwned\n")], to: dest)
        }
        #expect(snapshot(outside) == ["secret.txt": "file:secret\n"])
        // A hard link to an entry extracted earlier works.
        try extract([.file("one.txt", "same\n"), .hardlink("two.txt", "one.txt", "")], to: dest)
        let one = try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent("one.txt").path)
        let two = try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent("two.txt").path)
        #expect(one[.systemFileNumber] as? Int == two[.systemFileNumber] as? Int)
        #expect(read(dest.appendingPathComponent("two.txt")) == "same\n")
    }

    @Test func destinationUnderTmp() throws {
        // /tmp is itself a symlink (to /private/tmp).
        let tmp = try Scratch(under: URL(fileURLWithPath: "/tmp"))
        let tree = try makeTree(in: scratch["src"])
        try Archive.create([tree], at: scratch["t.tar.bz2"], format: .tarBz2)
        try Archive.extract(try Archive.list(scratch["t.tar.bz2"]), to: tmp["out"])
        #expect(snapshot(tmp["out/tree"]) == snapshot(tree))
    }
}
