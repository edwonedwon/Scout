import Foundation
import SwiftUI

public struct LocationGroup: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var colorHex: String
    public var icon: String
    public var projectID: UUID
    public var sortOrder: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#FF6B35",
        icon: String = "mappin.circle",
        projectID: UUID,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.icon = icon
        self.projectID = projectID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

public struct ScoutProject: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var description: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, description: String = "", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
    }
}
