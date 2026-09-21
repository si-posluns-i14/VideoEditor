import Foundation

enum ProjectFile {

    static func write(_ data: ProjectData, to workspace: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(data)
        try json.write(to: WorkspaceManager.projectFile(workspace), options: .atomic)
    }

    static func read(from workspace: URL) throws -> ProjectData {
        let url = WorkspaceManager.projectFile(workspace)
        guard FileManager.default.fileExists(atPath: url.path) else { return ProjectData() }
        let json = try Data(contentsOf: url)
        return try JSONDecoder().decode(ProjectData.self, from: json)
    }
}
