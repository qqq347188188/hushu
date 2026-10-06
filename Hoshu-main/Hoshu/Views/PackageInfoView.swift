import FluidGradient
import SwiftUI

struct PackageView: View {
    let controlData: Control
    @Environment(\.dismiss) private var dismiss

    // MARK: - Computed Properties

    // Background gradient view
    private var backgroundView: some View {
        FluidGradient(
            blobs: [.gray],
            highlights: [.black],
            speed: 0.25,
            blur: 0.75
        )
        .background(.black)
        .ignoresSafeArea()
    }

    // Package icon view
    private var packageIconView: some View {
        Group {
            if let icon = controlData.getValue(forField: "icon"), !icon.isEmpty
            {
                AsyncImage(url: URL(string: icon)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    case .failure(_), .empty:
                        fallbackIconView
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                fallbackIconView
            }
        }
    }

    // Fallback icon when package icon is unavailable
    private var fallbackIconView: some View {
        Image(systemName: "cube.box.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 64, height: 64)
            .foregroundStyle(.gray)
    }

    // Package header info (name and version)
    private var packageHeaderInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let name = controlData.getValue(forField: "name"), !name.isEmpty
            {
                Text(name)
                    .font(.title)
                    .bold()
                    .foregroundStyle(.white)
            }

            if let version = controlData.getValue(forField: "version"),
                !version.isEmpty
            {
                Text("Version \(version)")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }
        }
    }

    // Package description section
    private var descriptionSection: some View {
        Group {
            if !controlData.packageDescription.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description")
                        .font(.headline)
                        .foregroundStyle(.gray)
                    Text(controlData.packageDescription)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                }
                .padding(.vertical, 8)
                Divider().background(Color.gray.opacity(0.5))
            }
        }
    }

    // Package details section
    private var detailsSection: some View {
        Group {
            if let package = controlData.getValue(forField: "package"),
                !package.isEmpty
            {
                InfoRow(label: "Package ID", value: package)
            }

            if let architecture = controlData.getValue(
                forField: "architecture"
            ), !architecture.isEmpty {
                InfoRow(label: "Architecture", value: architecture)
            }

            if let section = controlData.getValue(forField: "section"),
                !section.isEmpty
            {
                InfoRow(label: "Section", value: section)
            }

            if let author = controlData.getValue(forField: "author"),
                !author.isEmpty
            {
                InfoRow(label: "Author", value: author)
            } else if let maintainer = controlData.getValue(
                forField: "maintainer"
            ), !maintainer.isEmpty {
                InfoRow(label: "Maintainer", value: maintainer)
            }

            if let installedSize = controlData.getValue(
                forField: "installed-size"
            ), !installedSize.isEmpty {
                InfoRow(label: "Size", value: "\(installedSize) KB")
            }
        }
    }

    // Dependencies section
    private var dependenciesSection: some View {
        Group {
            let depends = controlData.getValue(forField: "depends") ?? ""
            if !depends.isEmpty {
                Divider().background(Color.gray.opacity(0.5))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dependencies")
                        .font(.headline)
                        .foregroundStyle(.gray)
                    Text(depends)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                }
                .padding(.vertical, 8)
            }
        }
    }

    // Conflicts section
    private var conflictsSection: some View {
        Group {
            let conflicts = controlData.getValue(forField: "conflicts") ?? ""
            if !conflicts.isEmpty {
                Divider().background(Color.gray.opacity(0.5))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Conflicts")
                        .font(.headline)
                        .foregroundStyle(.gray)
                    Text(conflicts)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                }
                .padding(.vertical, 8)
            }
        }
    }

    // URLs section
    private var urlsSection: some View {
        Group {
            let homepage = controlData.getValue(forField: "homepage") ?? ""
            let depiction = controlData.getValue(forField: "depiction") ?? ""
            if !homepage.isEmpty || !depiction.isEmpty {
                Divider().background(Color.gray.opacity(0.5))
                VStack(alignment: .leading, spacing: 8) {
                    if !homepage.isEmpty {
                        InfoRow(label: "Homepage", value: homepage)
                    }

                    if !depiction.isEmpty {
                        InfoRow(
                            label: "Depiction",
                            value: depiction
                        )
                    }
                }
            }
        }
    }

    // Main content view
    private var contentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Package header section with icon
                HStack(alignment: .center, spacing: 12) {
                    packageIconView
                    packageHeaderInfo
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)

                // Description
                descriptionSection

                // Details
                detailsSection

                // Dependencies
                dependenciesSection

                // Conflicts
                conflictsSection

                // URLs
                urlsSection
            }
            .padding()
        }
    }

    // Initial appearance tracker
    @State private var didAppearTracker = false
    private var debugOverlay: some View {
        Color.clear.onAppear {
            didAppearTracker = true
        }
    }

    // MARK: - Main View

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                NavigationStack {
                    packageContent
                }
            } else {
                NavigationView {
                    packageContent
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
        }
    }

    private var packageContent: some View {
        ZStack {
            // Background
            backgroundView

            // Content
            contentView

            // Initial appearance tracker overlay
            if !didAppearTracker {
                debugOverlay
            }
        }
        .onAppear {
            NSLog(
                "[Hoshu] PackageView appeared with data: \(controlData.getValue(forField: "name") ?? ""), \(controlData.getValue(forField: "package") ?? "")"
            )
            // Apply transparent navigation bar appearance for iOS 15
            configureTransparentNavigationBar()
        }
        .onDisappear {
            // Reset navigation bar appearance when view disappears
            resetNavigationBarAppearance()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    NSLog("[Hoshu] Dismiss button tapped")
                    dismiss()
                }
                .foregroundStyle(.white)
            }
        }
        // For iOS 16+, use the native toolbarBackground modifier
        .modifier(ToolbarBackgroundModifier())
    }

    // iOS 15 compatible functions to manage navigation bar appearance
    private func configureTransparentNavigationBar() {
        if #available(iOS 16.0, *) {
            // Do nothing, using toolbarBackground instead
        } else {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = UIColor.clear
            appearance.shadowColor = UIColor.clear

            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        }
    }

    private func resetNavigationBarAppearance() {
        if #available(iOS 16.0, *) {
            // Do nothing, using toolbarBackground instead
        } else {
            // Optional: Reset to default appearance when view disappears
            let defaultAppearance = UINavigationBarAppearance()
            defaultAppearance.configureWithDefaultBackground()

            UINavigationBar.appearance().standardAppearance = defaultAppearance
            UINavigationBar.appearance().compactAppearance = defaultAppearance
            UINavigationBar.appearance().scrollEdgeAppearance =
                defaultAppearance
        }
    }
}

// Compatibility modifier for iOS 16+ features
struct ToolbarBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.toolbarBackground(.hidden)
        } else {
            content
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.gray)
                .frame(width: 100, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
