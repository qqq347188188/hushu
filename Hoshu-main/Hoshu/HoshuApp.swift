import SwiftUI
import UIKit

struct StatusBarModifier: ViewModifier {
    var style: UIStatusBarStyle
    @State private var statusBarViewController: StatusBarViewController? = nil

    func body(content: Content) -> some View {
        content
            .onAppear {
                let keyWindow = UIApplication.shared.connectedScenes
                    .filter { $0.activationState == .foregroundActive }
                    .compactMap { $0 as? UIWindowScene }
                    .first?.windows
                    .filter { $0.isKeyWindow }
                    .first

                if let rootViewController = keyWindow?.rootViewController {
                    let statusBarVC = StatusBarViewController(style: style)
                    rootViewController.addChild(statusBarVC)
                    rootViewController.view.addSubview(statusBarVC.view)
                    statusBarVC.view.frame = .zero
                    statusBarVC.didMove(toParent: rootViewController)
                    statusBarViewController = statusBarVC
                }
            }
            .onDisappear {
                if let statusBarVC = statusBarViewController,
                    statusBarVC.parent != nil
                {
                    statusBarVC.willMove(toParent: nil)
                    statusBarVC.view.removeFromSuperview()
                    statusBarVC.removeFromParent()
                }
                statusBarViewController = nil
            }
    }
}

class StatusBarViewController: UIViewController {
    private var statusBarStyle: UIStatusBarStyle

    init(style: UIStatusBarStyle) {
        self.statusBarStyle = style
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return statusBarStyle
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }
}

extension View {
    func statusBarStyle(_ style: UIStatusBarStyle) -> some View {
        modifier(StatusBarModifier(style: style))
    }
}

class AppState: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var showAlternativeFilePicker: Bool {
        didSet {
            UserDefaults.standard.set(
                showAlternativeFilePicker,
                forKey: "showAlternativeFilePicker"
            )
        }
    }

    // Last used directory path in the alternative file picker
    @Published var lastFilePickerPath: String {
        didSet {
            UserDefaults.standard.set(
                lastFilePickerPath,
                forKey: "lastFilePickerPath"
            )
        }
    }

    // Last used sort option in the alternative file picker (stored as Int)
    @Published var lastFilePickerSortOption: Int {
        didSet {
            UserDefaults.standard.set(
                lastFilePickerSortOption,
                forKey: "lastFilePickerSortOption"
            )
        }
    }

    @Published var convertedFilePath: String?
    @Published var showShareSheet: Bool = false
    @Published var isParsingDeb: Bool = false
    @Published var errorMessage: String? = nil  // Add this for user-facing errors

    // Initialize from UserDefaults
    init() {
        // Load saved settings from UserDefaults or use defaults
        self.showAlternativeFilePicker = UserDefaults.standard.bool(
            forKey: "showAlternativeFilePicker"
        )
        self.lastFilePickerPath =
            UserDefaults.standard.string(forKey: "lastFilePickerPath") ?? "/"
        self.lastFilePickerSortOption = UserDefaults.standard.integer(
            forKey: "lastFilePickerSortOption"
        )
    }

    // Function to reset all state values to default
    func resetState() {
        isProcessing = false
        showShareSheet = false
        isParsingDeb = false
        convertedFilePath = nil  // Clear the converted file path
        // Note: We don't reset persistent settings here
    }
}

// Helper struct for Identifiable error message
struct ErrorAlert: Identifiable {
    let id = UUID()
    let message: String
}

@main
struct HoshuApp: App {
    @StateObject private var appState = AppState()
    @State private var errorAlert: ErrorAlert? = nil

    var body: some Scene {
        WindowGroup {
            rootContentView
        }
    }

    @ViewBuilder
    private var rootContentView: some View {
        let content = ContentView()
            .environmentObject(appState)
            .statusBarStyle(.lightContent)  // Apply white status bar
            .onOpenURL { (url) in
                let fileManager = FileManager.default

                guard fileManager.fileExists(atPath: url.path) else {
                    return
                }

                // Use importing directory instead of main directory
                let importingFolderURL = URL(
                    fileURLWithPath: "/tmp/moe.waru.hoshu/.importing"
                )

                // Create all necessary directories
                let mainDirURL = URL(fileURLWithPath: "/tmp/moe.waru.hoshu")
                let stagingDirURL = URL(
                    fileURLWithPath: "/tmp/moe.waru.hoshu/.staging"
                )
                let convertedDirURL = URL(
                    fileURLWithPath: "/tmp/moe.waru.hoshu/.converted"
                )

                do {
                    // Create all necessary directories
                    try fileManager.createDirectory(
                        at: mainDirURL,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    try fileManager.createDirectory(
                        at: stagingDirURL,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    try fileManager.createDirectory(
                        at: importingFolderURL,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    try fileManager.createDirectory(
                        at: convertedDirURL,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                } catch {
                    appState.errorMessage =
                        "Failed to create necessary directories. Please check permissions.\n\(error.localizedDescription)"
                    return
                }

                let destFileURL = importingFolderURL.appendingPathComponent(
                    url.lastPathComponent
                )

                do {
                    if fileManager.fileExists(atPath: destFileURL.path) {
                        try fileManager.removeItem(at: destFileURL)
                    }

                    try fileManager.copyItem(at: url, to: destFileURL)

                    // Post notification with file path for processing
                    NotificationCenter.default.post(
                        name: Notification.Name("hoshuFileOpen"),
                        object: destFileURL
                    )

                } catch {
                    appState.errorMessage =
                        "Failed to import file. Please try again.\n\(error.localizedDescription)"
                }
            }
            .preferredColorScheme(.dark)

        if #available(iOS 17.0, *) {
            content
                .onChange(of: appState.errorMessage) { _, msg in
                    if let msg = msg {
                        errorAlert = ErrorAlert(message: msg)
                    }
                }
                .alert(item: $errorAlert) { alert in
                    Alert(
                        title: Text("Error"),
                        message: Text(alert.message),
                        dismissButton: .default(Text("OK")) {
                            appState.errorMessage = nil
                        }
                    )
                }
        } else {
            content
                .onChange(of: appState.errorMessage) { msg in
                    if let msg = msg {
                        errorAlert = ErrorAlert(message: msg)
                    }
                }
                .alert(item: $errorAlert) { alert in
                    Alert(
                        title: Text("Error"),
                        message: Text(alert.message),
                        dismissButton: .default(Text("OK")) {
                            appState.errorMessage = nil
                        }
                    )
                }
        }
    }
}
