import Foundation

/// Archives no tool on a stock Mac can make (RAR, encrypted 7-Zip/RAR), taken from libarchive 3.7.4's own test
/// suite (libarchive/test/*.uu, BSD-2-Clause) and stored here base64-encoded.
enum Fixture: String {
    /// helloworld.txt, stored ("hello libarchive test suite!\n").
    case rar5 = "UmFyIRoHAQAzkrXlCgEFBgAFAQGAgAA4MAZjLAIDC50ABJ0ApIMCtEOglYAAAQ5oZWxsb3dvcmxkLnR4dAoDE34Oq1tW6Q4aaGVsbG8gbGliYXJjaGl2ZSB0ZXN0IHN1aXRlIQodd1ZRAwUEAA=="
    /// RAR 2.9: test.txt, testlink -> test.txt, testdir/test.txt, testdir/, testemptydir/.
    case rar = "UmFyIRoHAM+QcwAADQAAAAAAAACEUnQgkDIAFAAAABQAAAADQqLIvrd22j4UMAgApIEAAHRlc3QudHh0gAi3dto+t3baPnRlc3QgdGV4dCBkb2N1bWVudA0KnS90IJAyAAgAAAAIAAAAA3tEybbRTNg+FDAIAP+hAAB0ZXN0bGlua8AI0UzYPlBf2j50ZXN0LnR4dM3gdCCQOgAUAAAAFAAAAANCosi+Y3faPhQwEACkgQAAdGVzdGRpclx0ZXN0LnR4dMDMY3faPmN32j50ZXN0IHRleHQgZG9jdW1lbnQNCqHIdOCQMQAAAAAAAAAAAAMAAAAAY3faPhQwBwDtQQAAdGVzdGRpcsDMY3faPmR32j7m53TgkDYAAAAAAAAAAAADAAAAAJ2r1T4UMAwA7UEAAHRlc3RlbXB0eWRpcoDMnavVPsVd2j7EPXsAQAcA"
    /// 7-Zip with an AES-encrypted bar.txt; names readable.
    case sevenZipEncryptedData = "N3q8ryccAAOCr+qIEAAAAAAAAABhAAAAAAAAAFj/bGq5DYjQrC1ro1q75TXf0UHZAQQGAAEJEAAHCwEAAiQG8QcBClMH2WRtZJq/DtUjAwEBBV0AAAEAAQAMCAQACAoBqGUyfgAABQEREQBiAGEAcgAuAHQAeAB0AAAAFAoBAACGNqh5sM4BFQYBACCAtIEAAA=="
    /// 7-Zip with encrypted names (7z -mhe=on).
    case sevenZipEncryptedHeader = "N3q8ryccAANRIXJ9gAAAAAAAAAAmAAAAAAAAABpax2mOWrqfd7a1ZaNBMYhQiWvQGsnBfkkay/HQXBOBu2bPs5JKmpm341p7Jd0wnGCbVjFcomL/ZlXY03qBVxd6mIOYY9Q5Tc1UwpeKFzLslyn3LOkF4rKHeVOmxeXUqu9CFAVF00x7gs+D622Asq0Cc25+Dpc1cvDJXakl4KDJRM9kxhcGEAEJcAAHCwEAASQG8QcBClMHTxry5UUdLtIMYQoB+2PQJgAA"
    /// RAR with encrypted foo.txt and bar.txt; names readable.
    case rarEncryptedData = "UmFyIRoHAM+QcwAADQAAAAAAAABd/HQkhC8AIAAAABAAAAADXIatpqVMMUMdMwcAtIEAAGZvby50eHRPA7zZ1hZM30VAGpKSiN8VK46ez3C5QOjJR+bO1r9E4rg1qJzoZTcBB0V0JIQvACAAAAAQAAAAA77ikM2mTDFDHTMHALSBAABiYXIudHh0TwO82dYWTN9wdHpIiYgPZlt95Qa5ch6oJVX4yjcBo+308RTzI2TRocQ9ewBABwA="
    /// RAR with encrypted names (rar -hp).
    case rarEncryptedHeader = "UmFyIRoHAM6Zc4AADQAAAAAAAADjLqtkp1x2jIRHQgDLysyfF2eRlxtxdgRzM7EaQ58bHnY/jQkFSsCaKbOiKstQBMBOSByi1fLAk0uZr4k8cUynzjcrVOE1V6w+SLWCMjUAx+uKt3QJcE1M4y6rZKdcdoyqlt/wYnpuaKU6kwceLDrjja8yEJwG/PkSpHIUMXE+DS78M5CkOS0EgiRDqN6E9yW/KIE3XLBqo8MI4oMHjXmjgiM8EReLj4NdANFmTjWFp+Muq2SnXHaMqmfUrzaWd0hrFE2d9SLu+g=="

    /// Writes the fixture to `folder/name` and returns its URL.
    func write(to folder: URL, as name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(base64Encoded: rawValue)!.write(to: url)
        return url
    }
}
