import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileDropZone: View {
    let title: String
    let subtitle: String
    let url: URL?
    let chooseAction: () -> Void
    let clearAction: () -> Void
    let onDrop: ([URL]) -> Void

    @State private var isTargeted = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("选择", action: chooseAction)
                    Button("清空", role: .destructive, action: clearAction)
                        .disabled(url == nil)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                        )

                    VStack(spacing: 10) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 28))
                            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                        Text(url?.path ?? "将文件拖拽到这里，或点击“选择”")
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                    .padding(20)
                }
                .frame(minHeight: 150)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
                    FileURLDropLoader.load(from: providers) { urls in
                        onDrop(urls)
                    }
                    return true
                }
            }
            .padding(6)
        }
    }
}

private enum FileURLDropLoader {
    static func load(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }

                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                } else if let url = item as? URL {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            completion(urls)
        }
    }
}
