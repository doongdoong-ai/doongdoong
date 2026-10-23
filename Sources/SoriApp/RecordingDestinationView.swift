import SwiftUI
import SoriCore

struct RecordingDestinationView: View {
    @Bindable var store: AppStore
    @State private var selectedID: UUID?
    @State private var newFolderName = ""
    @FocusState private var folderNameFocused: Bool

    init(store: AppStore) {
        self.store = store
        _selectedID = State(initialValue: store.selectedProjectID ?? store.projects.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                Text("녹음할 폴더를 선택하세요").font(.system(size: 23, weight: .semibold)).tracking(-0.4)
                Text("녹음과 핵심 요약을 이 폴더에 저장합니다.")
                    .font(.system(size: 14)).foregroundStyle(SoriTheme.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.projects) { project in
                        Button { selectedID = project.id } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder").font(.system(size: 17))
                                Text(project.name).font(.system(size: 15)).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if selectedID == project.id { Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)) }
                            }.padding(13).contentShape(Rectangle())
                                .background(selectedID == project.id ? SoriTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityAddTraits(selectedID == project.id ? [.isSelected] : [])
                    }
                }
            }.frame(height: min(260, max(100, CGFloat(store.projects.count) * 54)))
            HStack(spacing: 10) {
                TextField("새 폴더 이름", text: $newFolderName).textFieldStyle(.roundedBorder)
                    .focused($folderNameFocused).onSubmit { createFolder() }
                    .accessibilityLabel("새 폴더 이름")
                Button("폴더 추가") { createFolder() }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(.system(size: 14))
            Divider()
            HStack {
                Button("취소") { store.showRecordingDestination = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("녹음 시작") {
                    guard let selectedID else { return }
                    store.showRecordingDestination = false
                    Task { await store.startRecording(in: selectedID) }
                }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(selectedID == nil || !store.projects.contains(where: { $0.id == selectedID }) || store.isStartingRecording || store.audio.isRecording)
            }
        }.padding(30).frame(width: 460).background(SoriTheme.paper).foregroundStyle(SoriTheme.ink)
            .focusEffectDisabled()
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let previous = Set(store.projects.map(\.id))
        store.createProject(name)
        if let added = store.projects.first(where: { !previous.contains($0.id) }) {
            selectedID = added.id; newFolderName = ""; folderNameFocused = false
        }
    }
}
