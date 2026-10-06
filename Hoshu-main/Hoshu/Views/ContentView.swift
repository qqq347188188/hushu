import FluidGradient
import Foundation
import MobileCoreServices
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var isFilePickerPresented = false
    @State private var isAlternativeFilePickerPresented = false
    @State private var selectedFilePath: String?
    @State private var isTerminalViewPresented = false
    @EnvironmentObject private var appState: AppState
    @State private var conversionCompleted = false
    @State private var controlData: Control? = nil
    @State private var showPackageInfoSheet = false
    @State private var notificationHandler: DebFileNotificationHandler?
    @State private var showRootlessAlert = false
    @State private var isSettingsPresented = false
    @StateObject private var urlImportCoordinator = URLImportCoordinator()
    @State private var extractionTask: Task<Void, Never>? = nil
    @State private var extractionOperationID: UUID? = nil

    // Temporary directory paths
    private let tempDirectory = "/tmp/moe.waru.hoshu/"
    private let stagingDirectory = "/tmp/moe.waru.hoshu/.staging/"
    private let importingDirectory = "/tmp/moe.waru.hoshu/.importing/"
    private let convertedDirectory = "/tmp/moe.waru.hoshu/.converted/"

    // Define a constant for the .deb UTType
    private let debUTType = UTType(filenameExtension: "deb")

    // Create the temporary directories if they don't exist
    private func ensureTempDirectoryExists() {
        let fileManager = FileManager.default
        // Check and create main temp directory
        if !fileManager.fileExists(atPath: tempDirectory) {
            do {
                try fileManager.createDirectory(
                    atPath: tempDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                NSLog(
                    "[Hoshu] Error creating directory: \(error.localizedDescription)"
                )
            }
        }

        // Check and create staging directory
        if !fileManager.fileExists(atPath: stagingDirectory) {
            do {
                try fileManager.createDirectory(
                    atPath: stagingDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                NSLog(
                    "[Hoshu] Error creating staging directory: \(error.localizedDescription)"
                )
            }
        }

        // Check and create importing directory
        if !fileManager.fileExists(atPath: importingDirectory) {
            do {
                try fileManager.createDirectory(
                    atPath: importingDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                NSLog(
                    "[Hoshu] Error creating importing directory: \(error.localizedDescription)"
                )
            }
        }

        // Check and create converted directory
        if !fileManager.fileExists(atPath: convertedDirectory) {
            do {
                try fileManager.createDirectory(
                    atPath: convertedDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                NSLog(
                    "[Hoshu] Error creating converted directory: \(error.localizedDescription)"
                )
            }
        }
    }

    // Clear the cache directory
    private func clearCache() {
        let fileManager = FileManager.default

        do {
            // Clear main temp directory
            let fileURLs = try fileManager.contentsOfDirectory(
                atPath: tempDirectory
            )

            // Delete each item (except the special directories)
            for file in fileURLs {
                if file != ".staging" && file != ".importing"
                    && file != ".converted"
                {
                    let filePath = tempDirectory + file
                    try fileManager.removeItem(atPath: filePath)
                    NSLog("[Hoshu] Deleted: \(file)")
                }
            }

            // Clear staging directory
            let stagingURLs = try fileManager.contentsOfDirectory(
                atPath: stagingDirectory
            )

            // Delete each item in staging
            for file in stagingURLs {
                let filePath = stagingDirectory + file
                try fileManager.removeItem(atPath: filePath)
                NSLog("[Hoshu] Deleted staging: \(file)")
            }

            // Clear importing directory
            let importingURLs = try fileManager.contentsOfDirectory(
                atPath: importingDirectory
            )

            // Delete each item in importing
            for file in importingURLs {
                let filePath = importingDirectory + file
                try fileManager.removeItem(atPath: filePath)
                NSLog("[Hoshu] Deleted importing: \(file)")
            }

            // Clear converted directory
            let convertedURLs = try fileManager.contentsOfDirectory(
                atPath: convertedDirectory
            )

            // Delete each item in converted
            for file in convertedURLs {
                let filePath = convertedDirectory + file
                try fileManager.removeItem(atPath: filePath)
                NSLog("[Hoshu] Deleted converted: \(file)")
            }

            // Clear rootless-patcher temp directory
            let rootlessPatcherPath = "/tmp/rootless-patcher"
            if fileManager.fileExists(atPath: rootlessPatcherPath) {
                let rootlessPatcherURLs = try fileManager.contentsOfDirectory(
                    atPath: rootlessPatcherPath
                )

                // Delete each item in rootless-patcher directory
                for file in rootlessPatcherURLs {
                    let filePath = rootlessPatcherPath + "/" + file
                    try fileManager.removeItem(atPath: filePath)
                    NSLog("[Hoshu] Deleted rootless-patcher: \(file)")
                }

                NSLog("[Hoshu] Cleaned rootless-patcher directory")
            }

            // Reset all states
            resetAllState()

        } catch {
            NSLog("[Hoshu] Error clearing cache: \(error.localizedDescription)")
        }
    }

    // This function resets both app state and local view state
    private func resetAllState() {
        if extractionTask != nil {
            logLifecycle(
                "Extract",
                "Cancelling active extraction task during reset",
                operationID: extractionOperationID
            )
        }
        extractionTask?.cancel()
        extractionTask = nil
        extractionOperationID = nil
        urlImportCoordinator.reset()

        // Reset AppState
        appState.resetState()

        // Reset local ContentView state
        resetLocalSelectionState()
    }

    private func resetLocalSelectionState() {
        selectedFilePath = nil
        conversionCompleted = false
        controlData = nil
    }

    private func dismissShareAlert(reset: Bool) {
        appState.showShareSheet = false
        if reset {
            resetAllState()
        }
    }

    private struct ShareDestination: Identifiable {
        let title: String
        let bundleIdentifier: String

        var id: String { bundleIdentifier }
    }

    private let thirdPartyShareDestinations: [ShareDestination] = [
        ShareDestination(
            title: "Sileo",
            bundleIdentifier: "org.coolstar.SileoStore"
        ),
        ShareDestination(
            title: "Zebra",
            bundleIdentifier: "xyz.willy.Zebra"
        ),
        ShareDestination(
            title: "Filza",
            bundleIdentifier: "com.tigisoftware.Filza"
        ),
    ]

    private func availableThirdPartyShareDestinations() -> [ShareDestination] {
        thirdPartyShareDestinations.filter {
            isAppAvailable($0.bundleIdentifier)
        }
    }

    private func shareToThirdPartyApp(_ destination: ShareDestination) {
        if let filePath = appState.convertedFilePath {
            shareFileToApp(destination.bundleIdentifier, filePath)
        }
        dismissShareAlert(reset: true)
    }

    private func shareViaSystemSheet() {
        guard let filePath = appState.convertedFilePath else {
            logLifecycle(
                "Share",
                "Unable to open system share sheet: converted file path was nil"
            )
            return
        }

        dismissShareAlert(reset: false)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            presentNativeShareSheet(filePath: filePath)
        }
    }

    private func proceedWithRootlessPackage() {
        showRootlessAlert = false
    }

    private func cancelRootlessPackageFlow() {
        resetAllState()
        showRootlessAlert = false
    }

    // Initialize and make sure temp directory exists
    init() {
        ensureTempDirectoryExists()
    }

    // Helper method to handle opened files
    private func handleOpenedFile(fileURL: URL) {
        selectedFilePath = fileURL.path
        extractDebFile(filePath: fileURL.path)
    }

    private func importSelectedDebFile(from sourceFileURL: URL) {
        ensureTempDirectoryExists()

        let originalFileName = sourceFileURL.lastPathComponent
        appState.isParsingDeb = true

        do {
            let fileManager = FileManager.default
            let cleanedFileName = originalFileName.cleanIOSFileSuffix()
            let destinationPath = importingDirectory + cleanedFileName

            if fileManager.fileExists(atPath: destinationPath) {
                try fileManager.removeItem(atPath: destinationPath)
            }

            try fileManager.copyItem(
                at: sourceFileURL,
                to: URL(fileURLWithPath: destinationPath)
            )

            selectedFilePath = destinationPath
            extractDebFile(filePath: destinationPath)
        } catch {
            appState.isParsingDeb = false
            NSLog("Error copying file: \(error.localizedDescription)")
        }
    }

    private func runOnMain(_ operation: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            operation()
        }
    }

    @MainActor
    private func presentNativeShareSheet(filePath: String) {
        logShareTransition(from: .idle, to: .presenting)
        guard
            let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
            let presenter = windowScene.windows
                .first(where: { $0.isKeyWindow })?.rootViewController
        else {
            logLifecycle(
                "Share",
                "Unable to open native share sheet: no active presenter"
            )
            return
        }

        let fileURL = URL(fileURLWithPath: filePath)
        let activityViewController = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )

        activityViewController.completionWithItemsHandler = {
            _,
            _,
            _,
            _ in
            Task { @MainActor in
                self.resetAllState()
            }
        }

        if let popover = activityViewController.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }

        presenter.present(activityViewController, animated: true)
    }

    private func shortOperationID(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return String(id.uuidString.prefix(8))
    }

    @MainActor
    private func clearExtractionOperationIDIfMatches(_ id: UUID) {
        if extractionOperationID == id {
            extractionOperationID = nil
        }
    }

    private func logLifecycle(
        _ area: String,
        _ message: String,
        operationID: UUID? = nil
    ) {
        if let shortID = shortOperationID(operationID) {
            NSLog("[Hoshu][\(area)][\(shortID)] \(message)")
        } else {
            NSLog("[Hoshu][\(area)] \(message)")
        }
    }

    private enum ExtractTransitionState: String {
        case idle
        case extracting
        case parsingControl
        case cancelled
        case failed
        case completed
    }

    private enum ShareTransitionState: String {
        case idle
        case presenting
    }

    private func logExtractTransition(
        from: ExtractTransitionState,
        to: ExtractTransitionState,
        operationID: UUID? = nil,
        note: String? = nil
    ) {
        let transitionText = "state \(from.rawValue) -> \(to.rawValue)"
        if let note, !note.isEmpty {
            logLifecycle(
                "Extract",
                "\(transitionText) (\(note))",
                operationID: operationID
            )
        } else {
            logLifecycle("Extract", transitionText, operationID: operationID)
        }
    }

    private func logShareTransition(
        from: ShareTransitionState,
        to: ShareTransitionState,
        operationID: UUID? = nil,
        note: String? = nil
    ) {
        let transitionText = "state \(from.rawValue) -> \(to.rawValue)"
        if let note, !note.isEmpty {
            logLifecycle(
                "Share",
                "\(transitionText) (\(note))",
                operationID: operationID
            )
        } else {
            logLifecycle("Share", transitionText, operationID: operationID)
        }
    }

    // Extract .deb file to staging directory
    private func extractDebFile(filePath: String) {
        let operationID = UUID()

        guard FileManager.default.fileExists(atPath: filePath) else {
            NSLog("[Hoshu] File does not exist at path: \(filePath)")
            runOnMain {
                self.appState.isParsingDeb = false
            }
            return
        }

        extractionOperationID = operationID
        logLifecycle(
            "Extract",
            "Starting extraction for \(filePath)",
            operationID: operationID
        )
        logExtractTransition(
            from: .idle,
            to: .extracting,
            operationID: operationID
        )

        // Set parsing state to true
        runOnMain {
            self.appState.isParsingDeb = true
        }

        if extractionTask != nil {
            logLifecycle(
                "Extract",
                "Cancelling previous extraction task before new extraction",
                operationID: extractionOperationID
            )
        }
        extractionTask?.cancel()
        extractionTask = nil

        // Perform extraction in background to prevent UI freezing
        extractionTask = Task.detached(priority: .userInitiated) { [self] in
            guard !Task.isCancelled else {
                await self.logLifecycle(
                    "Extract",
                    "Extraction task cancelled before work started",
                    operationID: operationID
                )
                await self.logExtractTransition(
                    from: .extracting,
                    to: .cancelled,
                    operationID: operationID,
                    note: "before extraction started"
                )
                await self.clearExtractionOperationIDIfMatches(operationID)
                return
            }

            do {
                guard !Task.isCancelled else {
                    await self.logLifecycle(
                        "Extract",
                        "Extraction cancelled before extraction service invocation",
                        operationID: operationID
                    )
                    await self.logExtractTransition(
                        from: .extracting,
                        to: .cancelled,
                        operationID: operationID,
                        note: "before extraction service invocation"
                    )
                    await self.clearExtractionOperationIDIfMatches(operationID)
                    return
                }

                await self.logExtractTransition(
                    from: .extracting,
                    to: .parsingControl,
                    operationID: operationID
                )

                let control =
                    try DebPackageExtractionService
                    .extractAndParse(
                        filePath: filePath,
                        stagingDirectory: self.stagingDirectory
                    )

                guard !Task.isCancelled else {
                    await self.logLifecycle(
                        "Extract",
                        "Extraction cancelled after control parsing",
                        operationID: operationID
                    )
                    await self.logExtractTransition(
                        from: .parsingControl,
                        to: .cancelled,
                        operationID: operationID,
                        note: "after control parsing"
                    )
                    await self.clearExtractionOperationIDIfMatches(operationID)
                    return
                }

                await MainActor.run {
                    if control.isDetectedAsRootless {
                        self.showRootlessAlert = true
                    }
                    self.controlData = control
                }

            } catch {
                NSLog(
                    "[Hoshu] Error extracting .deb: \(error.localizedDescription)"
                )
                if Task.isCancelled {
                    await self.logLifecycle(
                        "Extract",
                        "Extraction cancelled while handling extraction error",
                        operationID: operationID
                    )
                    await self.logExtractTransition(
                        from: .extracting,
                        to: .cancelled,
                        operationID: operationID,
                        note: "while handling extraction error"
                    )
                    await self.clearExtractionOperationIDIfMatches(operationID)
                    return
                }
                await self.logLifecycle(
                    "Extract",
                    "Extraction failed for \(filePath): \(error.localizedDescription)",
                    operationID: operationID
                )
                await self.logExtractTransition(
                    from: .extracting,
                    to: .failed,
                    operationID: operationID,
                    note: error.localizedDescription
                )
                await self.clearExtractionOperationIDIfMatches(operationID)
                await MainActor.run {
                    self.appState.isParsingDeb = false
                }
                return
            }

            guard !Task.isCancelled else {
                await self.logLifecycle(
                    "Extract",
                    "Extraction cancelled before completion state update",
                    operationID: operationID
                )
                await self.logExtractTransition(
                    from: .parsingControl,
                    to: .cancelled,
                    operationID: operationID,
                    note: "before completion state update"
                )
                await self.clearExtractionOperationIDIfMatches(operationID)
                return
            }

            // Set parsing state back to false when complete
            await MainActor.run {
                self.appState.isParsingDeb = false
            }
            await self.logLifecycle(
                "Extract",
                "Extraction completed for \(filePath)",
                operationID: operationID
            )
            await self.logExtractTransition(
                from: .parsingControl,
                to: .completed,
                operationID: operationID
            )
            await self.clearExtractionOperationIDIfMatches(operationID)
        }
    }

    // Start the conversion process
    private func startConversion() {
        guard selectedFilePath != nil else { return }

        appState.isProcessing = true
        isTerminalViewPresented = true
    }

    var body: some View {
        let gradientStyle = FluidGradient(
            blobs: [.gray],
            highlights: [.black],
            speed: 0.25,
            blur: 0.75
        ).background(.black)

        gradientStyle
            .ignoresSafeArea()
            .overlay(
                ZStack {
                    // Top buttons
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: {
                                isSettingsPresented = true
                            }) {
                                Image(systemName: "gear")
                                    .foregroundStyle(.white)
                                    .font(.system(size: 24))
                                    .padding()
                            }
                        }
                        Spacer()
                    }

                    // Center button in a fixed position
                    VStack {
                        Spacer()

                        // File name area with fixed height that opens package info when tapped
                        ZStack {
                            if let selectedPath = selectedFilePath {
                                Button {
                                    NSLog(
                                        "[Hoshu] File name tapped, controlData: \(controlData != nil), isParsingDeb: \(appState.isParsingDeb)"
                                    )
                                    showPackageInfoSheet = true
                                } label: {
                                    HStack {
                                        // Left spacer to center the text
                                        Spacer()

                                        // Center: Filename + info icon
                                        Text(
                                            URL(fileURLWithPath: selectedPath)
                                                .lastPathComponent
                                                .cleanIOSFileSuffix()
                                        )
                                        .foregroundStyle(.white)

                                        Image(systemName: "info.circle")
                                            .foregroundStyle(.gray)
                                            .font(.system(size: 14))

                                        // Right spacer with equal weight
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(height: 30)  // Fixed height reserved for filename
                        .padding(.bottom, 10)

                        // Convert button
                        Button(action: {
                            if selectedFilePath == nil {
                                // Use the appropriate file picker based on the toggle setting
                                if appState.showAlternativeFilePicker {
                                    isAlternativeFilePickerPresented = true
                                } else {
                                    isFilePickerPresented = true
                                }
                            } else {
                                startConversion()
                            }
                        }) {
                            convertButtonContent()
                        }
                        .fileImporter(
                            isPresented: $isFilePickerPresented,
                            allowedContentTypes: debUTType != nil
                                ? [debUTType!] : [],
                            allowsMultipleSelection: false
                        ) { result in
                            switch result {
                            case .success(let files):
                                guard let selectedFile = files.first else {
                                    return
                                }
                                importSelectedDebFile(from: selectedFile)
                            case .failure(let error):
                                NSLog(
                                    "Error selecting file: \(error.localizedDescription)"
                                )
                            }
                        }
                        .disabled(
                            (appState.isProcessing && selectedFilePath != nil)
                                || appState.isParsingDeb
                        )  // Disable during processing or parsing if a file is selected
                        .padding(.horizontal, 20)
                        // Import from URL section (only show when no file selected and not busy with conversion)
                        if selectedFilePath == nil && !appState.isProcessing {
                            VStack(spacing: 8) {
                                Button(action: {
                                    urlImportCoordinator.beginPromptIfIdle()
                                }) {
                                    Text(urlImportButtonLabel())
                                        .foregroundStyle(.white)
                                        .padding()
                                        .frame(maxWidth: .infinity)
                                        .background(.ultraThinMaterial)
                                        .clipShape(
                                            RoundedRectangle(cornerRadius: 8)
                                        )
                                }
                                .disabled(urlImportCoordinator.isPreflighting)

                                if urlImportCoordinator.isDownloading
                                    || urlImportCoordinator.isPreflighting
                                {
                                    Button(role: .cancel) {
                                        cancelDownload()
                                    } label: {
                                        Text("Cancel Download")
                                            .foregroundStyle(.red)
                                            .padding(8)
                                            .frame(maxWidth: .infinity)
                                            .background(Color.red.opacity(0.15))
                                            .clipShape(
                                                RoundedRectangle(
                                                    cornerRadius: 8
                                                )
                                            )
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                        }

                        Spacer()
                    }
                }
                .padding()
            )
            .fullScreenCover(isPresented: $isTerminalViewPresented) {
                if let filePath = selectedFilePath {
                    TerminalView(
                        filePath: filePath,
                        isPresented: $isTerminalViewPresented
                    )
                }
            }
            .sheet(isPresented: $showPackageInfoSheet) {
                if let data = controlData {
                    PackageView(controlData: data)
                }
            }
            // Use alert with package manager options
            .alert("Success", isPresented: $appState.showShareSheet) {
                ForEach(availableThirdPartyShareDestinations()) {
                    destination in
                    Button(destination.title) {
                        shareToThirdPartyApp(destination)
                    }
                }

                Button("Share") {
                    shareViaSystemSheet()
                }

                Button("Cancel", role: .cancel) {
                    dismissShareAlert(reset: true)
                }
            } message: {
                Text("Choose where to share the converted package")
            }
            .fullScreenCover(isPresented: $isAlternativeFilePickerPresented) {
                // Show our custom alternative file picker when requested
                AlternativeDebFilePicker(
                    isPresented: $isAlternativeFilePickerPresented
                ) { fileURL in
                    importSelectedDebFile(from: fileURL)
                }
            }
            .fullScreenCover(isPresented: $isSettingsPresented) {
                SettingsView(onClearCache: clearCache)
            }
            .onAppear {
                // Initialize the notification handler here
                if notificationHandler == nil {
                    notificationHandler = DebFileNotificationHandler {
                        fileURL in
                        self.handleOpenedFile(fileURL: fileURL)
                    }
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: Notification.Name("hoshuclearSelectedFile")
                )
            ) { notification in
                guard (notification.object as? String) == "conversion-failed"
                else {
                    return
                }
                resetLocalSelectionState()
            }
            .alert("Rootless Package Detected", isPresented: $showRootlessAlert)
        {
            Button("Proceed Anyway") {
                proceedWithRootlessPackage()
            }
            Button("Cancel", role: .cancel) {
                cancelRootlessPackageFlow()
            }
        } message: {
            Text(
                "This package was detected to be already rootless (arm64). You can still proceed if you'd like to convert it again."
            )
        }
            // URL entry prompt
            .alert(
                "Import .deb from URL",
                isPresented: $urlImportCoordinator.showURLImportPrompt
            ) {
                TextField(
                    "URL",
                    text: $urlImportCoordinator.urlToImport
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit {
                    submitURLImportFromAlert()
                }
                Button("Cancel", role: .cancel) {}
                Button("Submit") { submitURLImportFromAlert() }
                    .keyboardShortcut(.defaultAction)
            }
            // Download error alert
            .alert(item: $urlImportCoordinator.downloadErrorAlert) { alert in
                Alert(
                    title: Text("Download Failed"),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
    }
}

// ScrollContentBackgroundModifier to handle iOS version compatibility
// Removed unused ScrollContentBackgroundModifier

// MARK: - URL Import Helpers
extension ContentView {
    @ViewBuilder
    private func convertButtonContent() -> some View {
        if appState.isProcessing {
            convertProgressLabel("Converting...")
        } else if appState.isParsingDeb {
            convertProgressLabel("Parsing...")
        } else if conversionCompleted {
            primaryActionButtonBody {
                Text("Conversion Complete!")
            }
        } else {
            primaryActionButtonBody {
                Text(convertIdleActionTitle())
            }
        }
    }

    private func convertIdleActionTitle() -> String {
        selectedFilePath == nil ? "Select .deb File" : "Convert .deb File"
    }

    @ViewBuilder
    private func convertProgressLabel(_ title: String) -> some View {
        primaryActionButtonBody {
            HStack {
                ProgressView()
                    .progressViewStyle(
                        CircularProgressViewStyle(
                            tint: .white
                        )
                    )
                    .scaleEffect(0.8)
                Text(title)
            }
        }
    }

    private func primaryActionButtonBody<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .foregroundStyle(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func retrySuffixPart() -> String? {
        guard urlImportCoordinator.retryAttempt > 0 else {
            return nil
        }
        return "(retry \(urlImportCoordinator.retryAttempt)/3)"
    }

    private func urlImportButtonLabel() -> String {
        if urlImportCoordinator.isPreflighting {
            return "Checking URL..."
        }

        guard urlImportCoordinator.isDownloading else {
            return "Import from URL"
        }

        if urlImportCoordinator.isUnknownSize {
            var parts: [String] = ["Downloading"]

            if urlImportCoordinator.downloadedBytes > 0 {
                parts.append(
                    URLImportSupport.formatBytes(
                        Double(urlImportCoordinator.downloadedBytes)
                    )
                )
            }

            if urlImportCoordinator.downloadSpeedBytesPerSec > 0 {
                parts.append(
                    URLImportSupport.formatBytes(
                        urlImportCoordinator.downloadSpeedBytesPerSec
                    ) + "/s"
                )
            }

            if let retrySuffix = retrySuffixPart() {
                parts.append(retrySuffix)
            }

            return parts.joined(separator: " • ")
        }

        if urlImportCoordinator.downloadSpeedBytesPerSec > 0
            && urlImportCoordinator.downloadETASeconds > 0
        {
            var parts = [
                "Downloading",
                URLImportSupport.formatPercent(
                    urlImportCoordinator.downloadProgress
                ),
                URLImportSupport.formatBytes(
                    urlImportCoordinator.downloadSpeedBytesPerSec
                ) + "/s",
                URLImportSupport.formatETA(
                    urlImportCoordinator.downloadETASeconds
                ),
            ]

            if let retrySuffix = retrySuffixPart() {
                parts.append(retrySuffix)
            }

            return parts.joined(separator: " • ")
        }

        var parts = [
            "Downloading",
            URLImportSupport.formatPercent(
                urlImportCoordinator.downloadProgress
            ),
        ]

        if let retrySuffix = retrySuffixPart() {
            parts.append(retrySuffix)
        }

        return parts.joined(separator: " • ")
    }

    @MainActor
    private func submitURLImportFromAlert() {
        urlImportCoordinator.submitFromAlert(
            ensureTempDirectoryExists: ensureTempDirectoryExists,
            setParsingDeb: { self.appState.isParsingDeb = $0 },
            log: { area, message, operationID in
                self.logLifecycle(area, message, operationID: operationID)
            },
            onDownloadFinalized: { destinationPath in
                self.selectedFilePath = destinationPath
                self.extractDebFile(filePath: destinationPath)
            },
            importingDirectory: importingDirectory
        )
    }

    @MainActor
    private func cancelDownload() {
        urlImportCoordinator.cancel(
            setParsingDeb: { self.appState.isParsingDeb = $0 },
            log: { area, message, operationID in
                self.logLifecycle(area, message, operationID: operationID)
            }
        )
    }
}
