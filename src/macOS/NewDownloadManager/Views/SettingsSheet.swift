import SwiftUI

struct SettingsSheet: View {
    private enum Category: String, CaseIterable, Identifiable {
        case general
        case browserSupport

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "通用"
            case .browserSupport: return "浏览器支持"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .browserSupport: return "network"
            }
        }
    }

    @Environment(DownloadManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Category = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: 760, height: 500)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("设置")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 14)
                .padding(.top, 14)

            ForEach(Category.allCases) { category in
                Button {
                    selection = category
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: category.symbol)
                            .frame(width: 16)
                        Text(category.title)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(selection == category ? Color.accentColor.opacity(0.16) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer()
        }
        .padding(10)
        .frame(width: 190)
        .background(.quaternary.opacity(0.35))
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch selection {
                case .general:
                    generalContent
                case .browserSupport:
                    browserSupportContent
                }
            }
            .padding(20)
        }
    }

    private var generalContent: some View {
        Group {
            Text("通用")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("主题") {
                Picker("外观", selection: Bindable(manager).appTheme) {
                    ForEach(AppTheme.allCases, id: \.rawValue) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            GroupBox("User-Agent") {
                TextField(
                    "User-Agent",
                    text: Bindable(manager).customUserAgent,
                    prompt: Text(DownloadEngine.fallbackUserAgent)
                )
                .textFieldStyle(.roundedBorder)
            }

            GroupBox("线程") {
                TextField("1-32", value: Bindable(manager).maxDownloadConnections, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
            }

            GroupBox("下载路径") {
                HStack {
                    TextField(
                        "下载路径",
                        text: Bindable(manager).customDownloadDirectory,
                        prompt: Text(manager.defaultDownloadDirectoryPlaceholder)
                    )
                    .textFieldStyle(.roundedBorder)
                    Button("浏览...") {
                        chooseDirectory()
                    }
                }
            }

            HStack {
                Button("恢复默认") {
                    manager.resetDownloadSettingsToDefault()
                }
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }

    private var browserSupportContent: some View {
        Group {
            Text("浏览器支持")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("Chrome") {
                Toggle("启用 Chrome 拦截", isOn: Bindable(manager).chromeInterceptionEnabled)
                Text("关闭后，Chrome 下载将恢复浏览器默认行为。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            manager.customDownloadDirectory = url.path
        }
    }
}
