import Foundation
import SwiftUI

// Alternative File Picker View that looks like a TableView
struct AlternativeDebFilePicker: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var appState: AppState
    @State private var currentPath: String = "/"
    @State private var directoryContents: [FileItem] = []
    @State private var searchText: String = ""
    @State private var detectedDirectoryPath: String? = nil
    @State private var showingSortOptions = false
    @State private var sortOption: SortOption = .nameAscending
    var onFileSelected: (URL) -> Void

    // Sort options enum
    enum SortOption: String, CaseIterable, Identifiable {
        case nameAscending = "Name (A-Z)"
        case nameDescending = "Name (Z-A)"
        case dateNewest = "Date (Newest First)"
        case dateOldest = "Date (Oldest First)"
        case sizeSmallest = "Size (Smallest First)"
        case sizeLargest = "Size (Largest First)"

        var id: String { self.rawValue }

        // Always use a consistent icon regardless of sort option
        static let sortIcon = "arrow.up.arrow.down"

        // Convert from integer index for storage
        static func fromIndex(_ index: Int) -> SortOption {
            let allOptions = SortOption.allCases
            guard index >= 0 && index < allOptions.count else {
                return .nameAscending  // Default if out of range
            }
            return allOptions[index]
        }

        // Convert to integer index for storage
        var toIndex: Int {
            return SortOption.allCases.firstIndex(of: self) ?? 0
        }
    }

    struct FileItem: Identifiable {
        var name: String
        var path: String
        var isDirectory: Bool
        var modificationDate: Date?
        var size: Int64 = 0

        var id: String { path }

        var iconName: String {
            return isDirectory ? "folder.fill" : "doc.fill"
        }

        var color: Color {
            return isDirectory ? .cyan : .white
        }

        var formattedSize: String {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: size)
        }

        var formattedDate: String {
            guard let date = modificationDate else { return "Unknown" }
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
    }

    // Computed property for filtered and sorted directory contents
    private var filteredContents: [FileItem] {
        let base: [FileItem] =
            searchText.isEmpty
            ? directoryContents
            : directoryContents.filter {
                $0.name.localizedStandardContains(searchText)
            }
        return base.sorted { (a: FileItem, b: FileItem) -> Bool in
            switch sortOption {
            case .nameAscending:
                return a.name.localizedStandardCompare(b.name)
                    == .orderedAscending
            case .nameDescending:
                return a.name.localizedStandardCompare(b.name)
                    == .orderedDescending
            case .dateNewest:
                guard let d1 = a.modificationDate, let d2 = b.modificationDate
                else {
                    return a.isDirectory && !b.isDirectory
                }
                return d1 > d2
            case .dateOldest:
                guard let d1 = a.modificationDate, let d2 = b.modificationDate
                else {
                    return a.isDirectory && !b.isDirectory
                }
                return d1 < d2
            case .sizeSmallest:
                if a.isDirectory && !b.isDirectory { return false }
                if !a.isDirectory && b.isDirectory { return true }
                return a.size < b.size
            case .sizeLargest:
                if a.isDirectory && !b.isDirectory { return false }
                if !a.isDirectory && b.isDirectory { return true }
                return a.size > b.size
            }
        }
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                NavigationStack {
                    pickerContent
                }
            } else {
                NavigationView {
                    pickerContent
                }
            }
        }
        .onAppear {
            // Initialize from saved preferences
            currentPath = appState.lastFilePickerPath
            sortOption = SortOption.fromIndex(appState.lastFilePickerSortOption)
            loadDirectoryContents()
        }
        // Add confirmation dialog for sort options
        .confirmationDialog(
            "Sort By",
            isPresented: $showingSortOptions,
            titleVisibility: .visible
        ) {
            Button("Cancel", role: .cancel) {}

            ForEach(SortOption.allCases) { option in
                Button(option.rawValue) {
                    sortOption = option
                    // Save the sort option
                    appState.lastFilePickerSortOption = option.toIndex
                    // Reload the directory contents with new sort option
                    loadDirectoryContents()
                }
            }
        }
    }

    private var pickerContent: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            VStack {
                // Search field (now positioned first)
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.gray)

                    TextField(
                        "Search files or enter a path",
                        text: $searchText
                    )
                    .foregroundStyle(.white)
                    .tint(.white)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .onChange(of: searchText) { _ in
                        checkForDirectoryPath()
                    }
                    // Make placeholder text brighter
                    .placeholder(when: searchText.isEmpty) {
                        Text("Search files or enter a path")
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                            detectedDirectoryPath = nil
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.gray)
                                .padding(2)
                        }
                    }
                }
                .padding(8)
                .background(SwiftUI.Color.gray.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.top, 10)

                // Path jump button when a valid path is typed
                if let directoryPath = detectedDirectoryPath {
                    Button(action: {
                        navigateToDirectory(directoryPath)
                    }) {
                        HStack {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(.cyan)
                            Text("Go to \(directoryPath)")
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .padding(8)
                        .background(SwiftUI.Color.gray.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)
                    }
                    .padding(.top, 5)
                }

                // Breadcrumbs now below search bar with matching horizontal padding
                HStack {
                    // Display path components as separate tappable items
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            let pathComponents = currentPath.split(
                                separator: "/"
                            )

                            // Root directory
                            Button {
                                navigateToDirectory("/")
                            } label: {
                                Text("/")
                                    .foregroundStyle(.white)
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.plain)

                            // Other path components
                            ForEach(0..<pathComponents.count, id: \.self) {
                                index in
                                let component = pathComponents[index]
                                if !component.isEmpty {
                                    Button {
                                        // Calculate the path up to this component
                                        let pathToHere =
                                            "/"
                                            + pathComponents[
                                                0...index
                                            ].joined(
                                                separator: "/"
                                            )
                                        navigateToDirectory(pathToHere)
                                    } label: {
                                        ZStack(alignment: .bottom) {
                                            Text("\(component)")
                                                .foregroundStyle(.white)
                                                .font(.system(size: 16))
                                                .lineLimit(1)

                                            // Custom underline compatible with iOS 15 and 16
                                            Rectangle()
                                                .frame(height: 2.0)
                                                .foregroundStyle(.white)
                                                .offset(y: 1)
                                        }
                                    }
                                    .buttonStyle(.plain)

                                    if index < pathComponents.count - 1 {
                                        Text("/")
                                            .foregroundStyle(.white)
                                            .font(.system(size: 12))
                                    }
                                }
                            }
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 5)
                .padding(.bottom, 5)

                ZStack {
                    // This provides a solid black background behind the List
                    Color.black.ignoresSafeArea()

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredContents) { item in
                                Button {
                                    if item.isDirectory {
                                        navigateToDirectory(item.path)
                                    } else if item.name.hasSuffix(".deb") {
                                        // Auto-select file and dismiss picker
                                        onFileSelected(
                                            URL(fileURLWithPath: item.path)
                                        )
                                        isPresented = false
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: item.iconName)
                                            .foregroundStyle(item.color)
                                            .frame(width: 25)

                                        VStack(alignment: .leading) {
                                            Text(item.name)
                                                .foregroundStyle(
                                                    item.name.hasSuffix(".deb")
                                                        || item.isDirectory
                                                        ? .white : .gray
                                                )

                                            HStack {
                                                Text(item.formattedDate)
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.gray)

                                                if !item.isDirectory {
                                                    Text(item.formattedSize)
                                                        .font(.system(size: 12))
                                                        .foregroundStyle(.gray)
                                                }
                                            }
                                        }

                                        Spacer()
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 16)
                                    .background(Color.black)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(Color.black)
                    }
                    .background(Color.black)
                }
                .background(Color.black)
            }
            .background(Color.black)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    isPresented = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white)
                        .padding()
                }
            }

            // Home button
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    navigateToDirectory("/")
                }) {
                    Image(systemName: "house.fill")
                        .foregroundStyle(.white)
                }
            }

            // Sort button
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    showingSortOptions.toggle()
                }) {
                    Image(systemName: SortOption.sortIcon)
                        .foregroundStyle(.white)
                }
            }

            // Back button, only shown when not at root
            ToolbarItem(placement: .navigationBarLeading) {
                if currentPath != "/" {
                    Button(action: {
                        navigateUp()
                    }) {
                        Image(systemName: "arrowshape.turn.up.backward")
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    private func loadDirectoryContents() {
        let fileManager = FileManager.default
        directoryContents.removeAll()

        do {
            let contents = try fileManager.contentsOfDirectory(
                atPath: currentPath
            )

            // Add all directory contents, including hidden files (those starting with ".")
            for item in contents.sorted() {
                // Skip "." (current directory) but show other hidden files/folders
                if item == "." {
                    continue
                }

                let fullPath = (currentPath as NSString).appendingPathComponent(
                    item
                )
                var isDir: ObjCBool = false

                if fileManager.fileExists(atPath: fullPath, isDirectory: &isDir)
                {
                    // Get file attributes to retrieve date and size information
                    let attributes = try? fileManager.attributesOfItem(
                        atPath: fullPath
                    )
                    let modificationDate =
                        attributes?[.modificationDate] as? Date
                    let fileSize = attributes?[.size] as? Int64 ?? 0

                    directoryContents.append(
                        FileItem(
                            name: item,
                            path: fullPath,
                            isDirectory: isDir.boolValue,
                            modificationDate: modificationDate,
                            size: fileSize
                        )
                    )
                }
            }
        } catch {
            print("Error reading directory: \(error)")
        }
    }

    private func navigateToDirectory(_ path: String) {
        currentPath = path
        // Save the current path
        appState.lastFilePickerPath = path
        // Clear search text when navigating to a new directory
        searchText = ""
        loadDirectoryContents()
    }

    private func navigateUp() {
        currentPath = (currentPath as NSString).deletingLastPathComponent
        if currentPath.isEmpty {
            currentPath = "/"
        }
        // Save the current path
        appState.lastFilePickerPath = currentPath
        // Clear search text when navigating up
        searchText = ""
        loadDirectoryContents()
    }

    private func isValidDirectoryPath(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: path,
            isDirectory: &isDir
        )
        return exists && isDir.boolValue
    }

    private func checkForDirectoryPath() {
        // First check if the search text is a valid path (starts with /)
        if searchText.hasPrefix("/") {
            // Check if it's a valid directory
            if isValidDirectoryPath(searchText) {
                detectedDirectoryPath = searchText
            } else {
                detectedDirectoryPath = nil
            }
        } else {
            detectedDirectoryPath = nil
        }
    }
}
