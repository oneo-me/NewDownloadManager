import SwiftUI

struct AddDownloadSheet: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var customFileName = ""
    @State private var useCustomPath = false
    @State private var customPath = ""
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Download")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Text("URL")
                    .font(.headline)
                TextField("https://example.com/file.zip", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDownload)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("File Name (optional)")
                    .font(.headline)
                TextField("Auto-detect from URL", text: $customFileName)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Custom save location", isOn: $useCustomPath)

            if useCustomPath {
                HStack {
                    TextField("Save path", text: $customPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        chooseDirectory()
                    }
                }
            }

            if let error = validationError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Download") {
                    addDownload()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 460)
    }

    private func addDownload() {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        guard URL(string: trimmedURL) != nil else {
            validationError = "Invalid URL"
            return
        }

        let fileName = customFileName.isEmpty ? nil : customFileName
        var destPath: String? = nil

        if useCustomPath, !customPath.isEmpty {
            let name = fileName ?? URL(string: trimmedURL)?.lastPathComponent ?? "download"
            destPath = (customPath as NSString).appendingPathComponent(name)
        }

        manager.addDownload(url: trimmedURL, fileName: fileName, destinationPath: destPath, revealInUI: true)
        dismiss()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
        }
    }
}
