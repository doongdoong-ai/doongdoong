import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    static let recordingReference = UTType(exportedAs: "app.bungbungi.recording-reference", conformingTo: .data)
}

/// Internal moves carry identity only; dragging never exports or copies the audio.
struct RecordingTransfer: Codable, Transferable {
    let recordingID: UUID
    let projectID: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .recordingReference)
    }
}

struct RecordingDragModifier: ViewModifier {
    let reference: RecordingTransfer
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.draggable(reference) }
        else { content }
    }
}
