import AppKit
import ArchiveCore
import SwiftUI

/// The Welcome window: a drop zone plus Open Archive… and New Archive….
struct WelcomeView: View {
    let openArchive: () -> Void
    let newArchive: () -> Void
    let drop: ([URL]) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 44, weight: .light))
                Text("Drop files to compress • Drop an archive to open")
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                  style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            )
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                loadFileURLs(providers, then: drop)
                return true
            }
            HStack(spacing: 12) {
                Button("Open Archive…", action: openArchive)
                Button("New Archive…", action: newArchive)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 460, height: 300)
    }
}

/// Loads the file URLs of dropped items, in drop order, and passes them to `done` on the main queue.
private func loadFileURLs(_ providers: [NSItemProvider], then done: @escaping ([URL]) -> Void) {
    final class Results { var urls: [URL?] = [] }
    let results = Results()
    results.urls = Array(repeating: nil, count: providers.count)
    let group = DispatchGroup()
    for (index, provider) in providers.enumerated() {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                results.urls[index] = url
                group.leave()
            }
        }
    }
    group.notify(queue: .main) { done(results.urls.compactMap { $0 }) }
}

struct NewArchiveOptions {
    let folder: URL
    let name: String
    let format: WritableFormat
    let level: CompressionLevel
    let password: String?
    let excludeJunk: Bool
}

/// The New Archive sheet: name, format, level, optional ZIP password, junk exclusion and destination folder.
struct NewArchiveView: View {
    let items: [URL]
    let cancel: () -> Void
    let create: (NewArchiveOptions) -> Void

    @State private var name: String
    @State private var folder: URL
    @State private var format = WritableFormat.zip
    @State private var level = CompressionLevel.normal
    @State private var password = ""
    @State private var confirmation = ""
    @State private var excludeJunk = true

    init(items: [URL], cancel: @escaping () -> Void, create: @escaping (NewArchiveOptions) -> Void) {
        self.items = items
        self.cancel = cancel
        self.create = create
        _name = State(initialValue: items.count == 1 ? items[0].lastPathComponent : "Archive")
        _folder = State(initialValue: items[0].deletingLastPathComponent())
    }

    /// The name without a typed format extension: "photos.zip" → "photos".
    private var baseName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = "." + format.fileExtension
        return trimmed.lowercased().hasSuffix(suffix) ? String(trimmed.dropLast(suffix.count)) : trimmed
    }

    private var isValid: Bool {
        !baseName.isEmpty && !baseName.contains("/") && (format != .zip || password == confirmation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(items.count == 1 ? "New archive from “\(items[0].lastPathComponent)”" : "New archive from \(itemCount(items.count))")
                .font(.headline)
            Form {
                TextField("Name:", text: $name)
                Picker("Format:", selection: $format) {
                    ForEach(WritableFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Compression:", selection: $level) {
                    Text("Fast").tag(CompressionLevel.fast)
                    Text("Normal").tag(CompressionLevel.normal)
                    Text("Best").tag(CompressionLevel.best)
                }
                .pickerStyle(.segmented)
                Toggle("Exclude macOS junk files", isOn: $excludeJunk)
                SecureField("Password:", text: $password)
                    .disabled(format != .zip)
                SecureField("Confirm:", text: $confirmation)
                    .disabled(format != .zip)
                Text(format == .zip ? "Optional. Encrypts the files with AES-256." : "Only ZIP archives can have a password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Save in:") {
                    HStack {
                        Text((folder.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…", action: chooseFolder)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    create(NewArchiveOptions(folder: folder, name: baseName, format: format, level: level,
                                             password: format == .zip && !password.isEmpty ? password : nil,
                                             excludeJunk: excludeJunk))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
}

/// A progress sheet with a determinate bar and Cancel.
struct ProgressSheet: View {
    let title: String
    @ObservedObject var model: ProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .lineLimit(2)
            ProgressView(value: model.fraction)
            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
