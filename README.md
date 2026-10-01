# Crate

A native macOS archive utility: browse, preview, extract, create and edit archives. It uses the libarchive
that ships with macOS, so it has no third-party dependencies.

## Features

- **Open** ZIP, 7-Zip, RAR/RAR5, TAR, TAR.GZ/.BZ2/.XZ, single-file .gz/.bz2/.xz, ISO, CPIO and XAR/PKG.
- **Browse** one window per archive: folders, path bar, sortable columns, search across the whole archive,
  Quick Look preview with Space.
- **Extract** the selection or everything, or use **Extract Here**, which adds no extra folder when the archive
  has a single top-level item. You can also drag items out to Finder.
- **Create** ZIP, 7-Zip, TAR, TAR.GZ, TAR.XZ or TAR.BZ2 archives by dropping files on Crate.
  macOS junk files (.DS_Store, `._*`, `__MACOSX`) are left out, and ZIPs can have an AES-256 password.
- **Edit** ZIP, 7-Zip and TAR archives: drop files on an open archive to add them, press Delete to remove items.
- **Finder integration**
  - Open With ▸ Crate.
  - Right-click ▸ Services ▸ **Compress with Crate** and **Extract Here with Crate**.
  - Quick Look: press Space on an archive to see the files inside.

## Requirements

- macOS 13.1 or later, on Apple silicon or Intel.
- Building needs the Command Line Tools with Swift 5.9 or later. Xcode is not needed. Installing the Command Line
  Tools (`xcode-select --install`) needs an administrator password; on a Mac without them, use a prebuilt Crate.app.
- Running the tests needs Swift 6 or later.

## Quick start (prebuilt app)

Unzip, then open Terminal in the unzipped folder and run `./install.sh`.

Don't double-click Crate.app first. The app is ad-hoc signed, so macOS calls a downloaded copy "damaged" until
`install.sh` clears its quarantine flag.

## Build from source

```sh
./build.sh      # universal app in build/Crate.app (./build.sh --native builds only this Mac's architecture, faster)
./install.sh    # copies it to ~/Applications and registers Open With, the Services and Quick Look
```

`./install.sh --dry-run` prints what it would do. `./install.sh path/to/Crate.app` installs a prebuilt app.
No administrator rights are needed.

## Tests

```sh
./test.sh
```

## Uninstall

```sh
./uninstall.sh
```

## Known limitations

- Encrypted 7-Zip and RAR archives can be browsed (unless their file names are encrypted too) but not extracted,
  because the libarchive in macOS can't decrypt them. Encrypted ZIPs work.
- `.tar.zst`, `.lz4` and similar archives need command-line tools that macOS doesn't include, so Crate can't open them.
- Adding or deleting items rewrites the whole archive at Normal compression. An encrypted ZIP is re-encrypted
  with AES-256.
- There is no per-file packed size (libarchive doesn't report one). The status bar shows the archive's size.
- RAR, ISO, CPIO, XAR/PKG and single-file .gz/.bz2/.xz archives are read-only.
- A single .bz2 or .xz file doesn't record its uncompressed size, so Crate shows it as Zero KB.
