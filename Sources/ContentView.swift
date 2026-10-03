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
        return try FileWrapper(url: url)
    }
}

struct ContentView: View {
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var status = "选择 .deb（或从「文件」App 分享到本 App），再点「修复 control 权限」。"
    @State private var busy = false
    @State private var outputURL: URL?
    @State private var outputName = "fixed.deb"
    @State private var selectedURL: URL?
    @State private var selectedName: String?

    private let debType = UTType(filenameExtension: "deb") ?? .data

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                Text("Deb Control 修复器").font(.title2.bold())

                if let name = selectedName {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.zipper")
                        Text(name).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor.opacity(0.12))
                    .cornerRadius(8)
                }

                Text(status)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                Button { showImporter = true } label: { Label("选择 .deb", systemImage: "folder") }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)

                Button { runRepair() } label: { Label("修复 control 权限", systemImage: "wand.and.stars") }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || selectedURL == nil)

                Button { showExporter = true } label: { Label("保存修复后的 .deb", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
                    .disabled(outputURL == nil)

                if busy {
                    ProgressView().padding(.top, 4)
                }
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
        .onOpenURL { url in
            if url.scheme == "debfixer" {
                // 由共享扩展「用 DebFixer 打开」跳回：读取 App Group 收件箱里的 deb
                handleSharedInbox()
            } else {
                // 从「文件」App 分享 / 打开方式 进来：URL 位于本 App 沙盒 Inbox，
                // 不是 security-scoped 的，无需 startAccessing，直接处理即可。
                selectedURL = url
                selectedName = url.lastPathComponent
                runRepair()
            }
        }
    }

    func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            selectedURL = url
            selectedName = url.lastPathComponent
            status = "已选择 \(url.lastPathComponent)，点「修复 control 权限」开始处理。"
        } catch {
            status = "选择失败：\(error.localizedDescription)"
        }
    }

    /// 由共享扩展「用 DebFixer 打开」跳回时调用：读取 App Group 收件箱里的 deb。
    /// App Group 不可用时（TrollStore / 自签）containerURL 返回 nil，此时提示改用「打开方式」。
    func handleSharedInbox() {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.example.debfixer") else {
            status = "未收到文件：当前安装方式未启用 App Group，请改用「打开方式」把 .deb 传入 DebFixer（系统会直接放进 App 沙盒，可正常修复）。"
            return
        }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        let manifestURL = inbox.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [[String: String]],
              let first = manifest.first,
              let rel = first["relativePath"] else {
            status = "未找到共享的 .deb，请确认已从分享扩展选择了文件。"
            return
        }
        let fileURL = inbox.appendingPathComponent(rel)
        selectedURL = fileURL
        selectedName = first["name"] ?? fileURL.lastPathComponent
        runRepair()
    }

    func runRepair() {
        guard let url = selectedURL else {
            status = "请先选择 .deb 文件，再点「修复 control 权限」"
            return
        }
        busy = true
        status = "处理 \(url.lastPathComponent) …"
        let inName = url.lastPathComponent
        DispatchQueue.global().async {
            // 文档选择器给的是 security-scoped URL，需 startAccessing；
            // 分享/打开方式进来的是沙盒内 Inbox 文件，startAccessing 返回 false，跳过即可。
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let out = try repairDeb(data)
                let base = (inName as NSString).deletingPathExtension
                let name = base + "-fixed.deb"
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
                    status = "修复失败：\(error.localizedDescription)"
                    busy = false
                }
            }
        }
    }
}
