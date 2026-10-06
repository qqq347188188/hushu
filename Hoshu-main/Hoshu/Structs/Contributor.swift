import Foundation

struct Contributor: Identifiable, Codable, Hashable {
    let id: UUID
    let imageURL: URL
    let profileURL: URL
    let name: String
    let contribution: String
    let projectURL: URL

    init(
        id: UUID = .init(),
        imageURL: URL,
        profileURL: URL,
        name: String,
        contribution: String,
        projectURL: URL
    ) {
        self.id = id
        self.imageURL = imageURL
        self.profileURL = profileURL
        self.name = name
        self.contribution = contribution
        self.projectURL = projectURL
    }
}

extension Contributor {
    static let samples: [Contributor] = [
        .init(
            imageURL: URL(
                string: "https://avatars.githubusercontent.com/u/156133757"
            )!,
            profileURL: URL(string: "https://github.com/waruhachi")!,
            name: "waruhachi",
            contribution: "Made Hoshu",
            projectURL: URL(string: "https://github.com/waruhachi/Hoshu")!
        ),
        .init(
            imageURL: URL(
                string: "https://avatars.githubusercontent.com/u/81449663"
            )!,
            profileURL: URL(string: "https://github.com/NightwindDev")!,
            name: "NightwindDev",
            contribution: "Made rootless-patcher",
            projectURL: URL(
                string: "https://github.com/NightwindDev/rootless-patcher"
            )!
        ),
        .init(
            imageURL: URL(
                string: "https://avatars.githubusercontent.com/u/134120506"
            )!,
            profileURL: URL(string: "https://github.com/roothide")!,
            name: "roothide",
            contribution: "Made RoothidePatcher",
            projectURL: URL(
                string: "https://github.com/roothide/RootHidePatcher"
            )!
        ),
        .init(
            imageURL: URL(
                string: "https://avatars.githubusercontent.com/u/85764897"
            )!,
            profileURL: URL(string: "https://github.com/haxi0")!,
            name: "haxi0",
            contribution: "Made Derootifier",
            projectURL: URL(string: "https://github.com/haxi0/Derootifier")!
        ),
    ]
}
