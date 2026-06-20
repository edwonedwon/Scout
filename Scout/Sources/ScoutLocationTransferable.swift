import SwiftUI
import UniformTypeIdentifiers
import ScoutKit

extension UTType {
    static let scoutLocation = UTType(exportedAs: "com.scout.app.location")
}

extension ScoutLocation: @retroactive Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .scoutLocation)
    }
}
