import Foundation
import UIKit

// NotificationHandler class to handle notifications without capturing ContentView's self
class DebFileNotificationHandler {
    var onFileOpened: ((URL) -> Void)?
    private var notificationObserver: Any?

    init(onFileOpened: @escaping (URL) -> Void) {
        self.onFileOpened = onFileOpened
        setupNotificationObserver()
    }

    private func setupNotificationObserver() {
        notificationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("hoshuFileOpen"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            UIApplication.shared.connectedScenes
                .first(where: { $0 is UIWindowScene })
                .flatMap({ $0 as? UIWindowScene })?.windows.first?
                .rootViewController?
                .presentedViewController?.dismiss(animated: true)

            if let fileURL = notification.object as? URL,
                let onFileOpened = self?.onFileOpened
            {
                onFileOpened(fileURL)
            }
        }
    }

    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
