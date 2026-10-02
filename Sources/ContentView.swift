import SwiftUI
import UniformTypeIdentifiers

struct DebDocument: FileDocument {
    static var readableContentTypes: [UTType] = [UTType(filenameExtension: "deb") ?? .data]
    var url: URL?
    init(url: URL?) { self.url = url }
    init(configuration: ReadConfiguration) throws { url = nil }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let url = url else {
            throw NSError(domain: "DebFixer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可导出的文件"])
        }
        return try FileWrapper(url: url, options: [.withoutMounting])
    }
}

struct ContentView: View {
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var status = "选择 .deb 文件，修复 control 权限后交给 hoshu 转换。"
    @State private var busy = false
    @State private var outputURL: URL?
    @State private var outputName = "fixed.deb"

    private let debType = UTType(filenameExtension: "deb") ?? .data

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                Text("Deb Control 修复器").font(.title2.bold())
                Text(status)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                Button { showImporter = true } label: { Label("选择 .deb", systemImage: "folder") }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                Button { showExporter = true } label: { Label("保存修复后的 .deb", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
                    .disabled(outputURL == nil)
                Spacer()
            }
            .padding()
            .navigationTitle("DebFixer")
        }
        .navigationViewStyle(.stack)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [debType]) { result in
            handleImport(result)
        }
        .fileExporter(isPresented: $showExporter,
                      document: DebDocument(url: outputURL),
                      contentType: debType,
                      defaultFilename: outputName) { _ in }
        .onOpenURL { url in process(url: url) }
    }

    func handleImport(_ result: Result<URL, Error>) {
        do { process(url: try result.get()) }
        catch { status = "失败：\(error.localizedDescription)" }
    }

    func process(url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            status = "失败：无法访问传入的文件"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            busy = true
            status = "处理传入的 deb…"
            DispatchQueue.global().async {
                do {
                    let out = try repairDeb(data)
                    let name = url.deletingPathExtension().lastPathComponent + "-fixed.deb"
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                    try out.write(to: tmp, options: .atomic)
                    DispatchQueue.main.async {
                        outputURL = tmp
                        outputName = name
                        status = "完成：已生成 \(name)\n点「保存修复后的 .deb」导出。"
                        busy = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        status = "失败：\(error.localizedDescription)"
                        busy = false
                    }
                }
            }
        } catch {
            status = "失败：\(error.localizedDescription)"
        }
    }
}
