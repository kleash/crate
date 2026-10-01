import Foundation
import Testing
@testable import ArchiveCore

/// Archives split into volumes, 7-Zip style: name.zip.001, name.zip.002, …
struct SplitTests {
    let scratch: Scratch
    init() throws { scratch = try Scratch() }

    func length(_ url: URL) throws -> Int64 {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
    }

    /// The volumes joined back together, as `cat name.zip.0* > name.zip` would.
    func join(_ volumes: [URL], as name: String) throws -> URL {
        let joined = scratch[name]
        try Data(volumes.flatMap { try Data(contentsOf: $0) }).write(to: joined)
        return joined
    }

    /// tree/ plus a file of random data, grown a byte at a time until the archive's size has a divisor in 2…6,
    /// so that one volume size splits it into equal volumes. Returns the tree and the archive's size.
    func source(for format: WritableFormat) throws -> (tree: URL, size: Int64, divisor: Int64) {
        let tree = try makeTree(in: scratch["src"])
        for extra in 0..<100 {
            try writeRandom(bytes: 20_000 + extra, to: tree.appendingPathComponent("sub/data.bin"))
            let whole = scratch["whole.\(format.fileExtension)"]
            // Twice: the first read moves the files' access times, which 7-Zip stores, so its size can change once.
            try Archive.create([tree], at: whole, format: format)
            try Archive.create([tree], at: whole, format: format)
            let size = try length(whole)
            try FileManager.default.removeItem(at: whole)
            if let divisor = (2...6).first(where: { size % Int64($0) == 0 }) { return (tree, size, Int64(divisor)) }
        }
        throw ArchiveError.failed("no archive size with a small divisor")
    }

    @Test(arguments: [WritableFormat.zip, .sevenZip, .tarGz])
    func volumeSizes(_ format: WritableFormat) throws {
        let (tree, size, divisor) = try source(for: format)
        let ext = format.fileExtension

        // Fits in one volume (also exactly): a normal archive, no .001.
        for volume in [size + 1, size] {
            let out = scratch["one-\(volume).\(ext)"]
            #expect(try Archive.create([tree], at: out, format: format, volumeSize: volume) == [out])
            #expect(try length(out) == size && !exists(Archive.volume(1, of: out)))
            #expect(try Archive.list(out).formatName == format.displayName)
        }

        // An exact multiple: equal volumes, no empty one at the end.
        let exact = try Archive.create([tree], at: scratch["exact.\(ext)"], format: format, volumeSize: size / divisor)
        #expect(exact.map(\.lastPathComponent) == (1...divisor).map { "exact.\(ext)." + String(format: "%03d", $0) })
        #expect(try exact.map(length) == Array(repeating: size / divisor, count: Int(divisor)))

        // Several volumes and a smaller last one.
        let volume = size / 3 + 1
        let parts = try Archive.create([tree], at: scratch["parts.\(ext)"], format: format, volumeSize: volume)
        #expect(parts.map(\.lastPathComponent) == ["parts.\(ext).001", "parts.\(ext).002", "parts.\(ext).003"])
        #expect(try parts.map(length) == [volume, volume, size - 2 * volume])

        for volumes in [exact, parts] {
            // Joined back together they are an ordinary archive.
            let joined = try Archive.list(try join(volumes, as: "joined-\(volumes.count).\(ext)"))
            #expect(joined.formatName == format.displayName && joined.archiveSize == size)
            try Archive.extract(joined, to: scratch["out-joined-\(volumes.count)"])
            #expect(snapshot(scratch["out-joined-\(volumes.count)/tree"]) == snapshot(tree))

            // Any volume opens the whole archive, read-only.
            for opened in [volumes[0], volumes[1]] {
                let listing = try Archive.list(opened)
                #expect(listing.url == volumes[0] && listing.volumes == volumes)
                #expect(listing.formatName == "\(format.displayName) (\(volumes.count) volumes)")
                #expect(listing.archiveSize == size && listing.writableFormat == format && !listing.isEditable)
                #expect(Set(listing.entries.map(\.path)) == Set(joined.entries.map(\.path)))
                let out = scratch["out-\(opened.lastPathComponent)"]
                try Archive.extract(listing, to: out)
                #expect(snapshot(out.appendingPathComponent("tree")) == snapshot(tree))
                try Archive.extract(listing, paths: ["tree/sub/data.bin"], to: scratch["one-\(opened.lastPathComponent)"])
                #expect(try Data(contentsOf: scratch["one-\(opened.lastPathComponent)/data.bin"])
                        == Data(contentsOf: tree.appendingPathComponent("sub/data.bin")))
            }
        }
        #expect(throws: ArchiveError.notEditable) { try Archive.rewrite(try Archive.list(parts[0]), removing: ["tree/a.txt"]) }
    }

    @Test(arguments: [WritableFormat.zip, .sevenZip, .tarGz])
    func incompleteSplitArchives(_ format: WritableFormat) throws {
        let tree = try makeTree(in: scratch["src"])
        try writeRandom(bytes: 20_000, to: tree.appendingPathComponent("sub/data.bin"))
        let ext = format.fileExtension
        let volumes = try Archive.create([tree], at: scratch["t.\(ext)"], format: format, volumeSize: 5_000)
        #expect(volumes.count >= 4)
        let fm = FileManager.default
        func copy(_ name: String, without missing: Int? = nil) throws -> [URL] {
            try volumes.indices.filter { $0 != missing }.map { index in
                let copy = Archive.volume(index + 1, of: scratch["\(name).\(ext)"])
                try fm.copyItem(at: volumes[index], to: copy)
                return copy
            }
        }
        // A volume missing in the middle, whether opening the first volume or one after the gap.
        let middle = try copy("middle", without: 1)
        #expect(throws: Archive.incompleteSplitArchive) { try Archive.list(middle[0]) }
        #expect(throws: Archive.incompleteSplitArchive) { try Archive.list(middle[1]) }
        // The last volume missing: the archive breaks off.
        let last = try copy("last", without: volumes.count - 1)
        #expect(throws: Archive.incompleteSplitArchive) { try Archive.list(last[0]) }
        // The first volume missing.
        let first = try copy("first", without: 0)
        #expect(throws: Archive.incompleteSplitArchive) { try Archive.list(first[0]) }
        // A volume cut short.
        let short = try copy("short")
        try fm.removeItem(at: short[1])
        try Data(try Data(contentsOf: volumes[1]).dropLast()).write(to: short[1])
        #expect(throws: Archive.incompleteSplitArchive) { try Archive.list(short[0]) }
        // Caught by the sizes alone, before reading: a TAR could otherwise lose bytes without an error.
        #expect(throws: Archive.incompleteSplitArchive) { try Archive.volumes(of: short[0]) }
        // All there, but one can't be read: that one, not "incomplete" (nor "Unrecognized archive format" for ZIP).
        let locked = try copy("locked")
        chmod(locked[1].path, 0)
        for opened in [locked[0], locked[2]] {
            #expect(throws: ArchiveError.failed("Can't read “locked.\(ext).002”: Permission denied")) { try Archive.list(opened) }
        }
        // Complete again: fine.
        #expect(try Archive.list(volumes[2]).volumes == volumes)
    }

    @Test func splitNonArchiveKeepsItsError() throws {
        // Volumes of something that isn't an archive (HJSplit splits any file the same way): not "incomplete".
        try Data(repeating: 7, count: 1_500).write(to: scratch["movie.mkv.001"])
        try Data(repeating: 7, count: 300).write(to: scratch["movie.mkv.002"])
        #expect(throws: ArchiveError.failed("Unrecognized archive format")) { try Archive.list(self.scratch["movie.mkv.001"]) }
    }

    @Test func oneVolume() throws {
        // 7-Zip names an archive .001 even when it fits in one volume.
        let tree = try makeTree(in: scratch["src"])
        try Archive.create([tree], at: scratch["t.zip"], format: .zip)
        try FileManager.default.moveItem(at: scratch["t.zip"], to: scratch["t.zip.001"])
        let listing = try Archive.list(scratch["t.zip.001"])
        #expect(listing.formatName == "ZIP (1 volume)" && listing.volumes == [scratch["t.zip.001"]] && !listing.isEditable)
        // Extract Here names its folder after the archive, without the volume number.
        try write("x", to: scratch["here/tree"])
        let (destination, item) = Archive.smartExtractDestination(listing, in: scratch["here"])
        #expect(destination.lastPathComponent == "t" && item == destination)
        try Archive.extract(listing, to: destination)
        #expect(snapshot(destination.appendingPathComponent("tree")) == snapshot(tree))
    }

    @Test func encryptedSplitZip() throws {
        let tree = try makeTree(in: scratch["src"])
        try writeRandom(bytes: 20_000, to: tree.appendingPathComponent("sub/data.bin"))
        let volumes = try Archive.create([tree], at: scratch["secret.zip"], format: .zip, passphrase: "s3cret", volumeSize: 8_000)
        #expect(volumes.count == 3)
        let listing = try Archive.list(volumes[1])
        #expect(listing.hasEncryptedEntries && listing.writableFormat == .zip)
        #expect(throws: ArchiveError.passphraseRequired) { try Archive.extract(listing, to: self.scratch["none"]) }
        #expect(throws: ArchiveError.wrongPassphrase) { try Archive.extract(listing, to: self.scratch["wrong"], passphrase: "nope") }
        try Archive.extract(listing, to: scratch["out"], passphrase: "s3cret")
        #expect(snapshot(scratch["out/tree"]) == snapshot(tree))
    }

    @Test func cancellingRemovesEveryVolume() throws {
        try writeRandom(bytes: 3_000_000, to: scratch["src/big.bin"])
        for format in [WritableFormat.zip, .sevenZip, .tarGz] {
            var calls = 0
            var written = 0
            #expect(throws: ArchiveError.cancelled) {
                try Archive.create([self.scratch["src"]], at: self.scratch["c.\(format.fileExtension)"], format: format,
                                   volumeSize: 100_000) { _ in
                    calls += 1
                    written = names(in: self.scratch.url).filter { $0.hasSuffix(".cratetmp") }.count
                    return calls < 3  // cancel two thirds through big.bin
                }
            }
            // ZIP and TAR.GZ had written a few volumes; 7-Zip writes everything at the end.
            #expect(format == .sevenZip || written > 10, "\(written) volumes")
            #expect(names(in: scratch.url) == ["src"])
        }
    }

    @Test func volumeNames() throws {
        #expect(Archive.volume(1, of: URL(fileURLWithPath: "/a/b.tar.gz")).lastPathComponent == "b.tar.gz.001")
        #expect(Archive.volume(1000, of: URL(fileURLWithPath: "/a/b.zip")).lastPathComponent == "b.zip.1000")
        #expect(Archive.volumeNumber(URL(fileURLWithPath: "/a/b.zip.012")) == 12)
        #expect(Archive.volumeNumber(URL(fileURLWithPath: "/a/b.zip.1000")) == 1000)
        for name in ["b.zip", "b.12", "b.000", "b.0x1", "b.mp3"] {
            #expect(Archive.volumeNumber(URL(fileURLWithPath: "/a/" + name)) == nil, "\(name)")
        }

        // A new archive's name is taken when a split archive uses it: "Archive.zip.001" means "Archive 2.zip".
        try write("old", to: scratch["Archive.zip.001"])
        let out = Archive.uniqueURL(in: scratch.url, name: "Archive", extension: "zip")
        #expect(out.lastPathComponent == "Archive 2.zip")
        try writeRandom(bytes: 10_000, to: scratch["src/data.bin"])
        let volumes = try Archive.create([scratch["src"]], at: out, format: .zip, level: .fast, volumeSize: 4_000)
        #expect(volumes.map(\.lastPathComponent) == ["Archive 2.zip.001", "Archive 2.zip.002", "Archive 2.zip.003"])
        #expect(read(scratch["Archive.zip.001"]) == "old")

        // So is a name with only a later volume left from an earlier set ("Old.zip.003"): a new set would take it in
        // as its own and read as incomplete. Names compare without regard to case, as the file system reads them.
        let old = try Archive.create([scratch["src"]], at: scratch["Old.zip"], format: .zip, level: .fast, volumeSize: 4_000)
        try FileManager.default.removeItem(at: old[0])
        try FileManager.default.removeItem(at: old[1])
        let next = Archive.uniqueURL(in: scratch.url, name: "old", extension: "zip")
        #expect(next.lastPathComponent == "old 2.zip")
        try writeRandom(bytes: 5_000, to: scratch["small/data.bin"])
        let new = try Archive.create([scratch["small"]], at: next, format: .zip, level: .fast, volumeSize: 4_000)
        #expect(new.count == 2)
        #expect(try Archive.list(new[0]).volumes == new)
        try write("old", to: scratch["photos.tar.gz.1000"])
        #expect(Archive.uniqueURL(in: scratch.url, name: "photos", extension: "tar.gz").lastPathComponent == "photos 2.tar.gz")
    }
}
