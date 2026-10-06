import SwiftUI

struct ContributorView: View {
    let imageURL: URL
    let name: String
    let profileURL: URL
    let contribution: String
    let projectURL: URL

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: {
                openURLInApp(
                    "com.apple.mobilesafari",
                    profileURL.absoluteString
                )
            }) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        Image(systemName: "person.circle.fill")
                    @unknown default: EmptyView()
                    }
                }
                .frame(width: 50, height: 50)
                .clipShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())

            VStack(alignment: .leading, spacing: 2) {
                Button(action: {
                    openURLInApp(
                        "com.apple.mobilesafari",
                        profileURL.absoluteString
                    )
                }) {
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: {
                    openURLInApp(
                        "com.apple.mobilesafari",
                        projectURL.absoluteString
                    )
                }) {
                    Text(contribution)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(PlainButtonStyle())
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }
}
