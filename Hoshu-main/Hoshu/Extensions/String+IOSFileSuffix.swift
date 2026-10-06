import Foundation

// Helper to clean iOS 15 duplicate file number suffixes
extension String {
    func cleanIOSFileSuffix() -> String {
        // Match patterns like "-1.deb", "-2.deb", etc.
        let pattern = "-\\d+(\\.\\w+)$"

        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(self.startIndex..<self.endIndex, in: self)

            if let match = regex.firstMatch(in: self, options: [], range: range)
            {
                let fullRange = match.range
                let extensionRange = match.range(at: 1)

                if let extensionRange = Range(extensionRange, in: self),
                    let fullRange = Range(fullRange, in: self)
                {
                    let fileExtension = String(self[extensionRange])
                    let cleanedName = self.replacingCharacters(
                        in: fullRange,
                        with: fileExtension
                    )
                    return cleanedName
                }
            }
        }

        return self
    }
}
