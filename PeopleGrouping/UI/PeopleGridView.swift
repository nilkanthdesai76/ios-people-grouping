import SwiftUI

struct PeopleGridView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isSelecting = false
    @State private var selection: [UUID] = []
    @State private var confirmMerge = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)

    var body: some View {
        NavigationStack {
            Group {
                if appModel.people.isEmpty {
                    EmptyState(
                        systemImage: "person.2.crop.square.stack",
                        title: "No people yet",
                        message: "Scan your library to find people."
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(appModel.people) { person in
                                cell(for: person)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        Button("Cancel") {
                            isSelecting = false
                            selection = []
                        }
                    } else {
                        Button("Select") {
                            isSelecting = true
                            selection = []
                        }
                        .disabled(appModel.people.count < 2)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if isSelecting && selection.count == 2 {
                        Button("Merge") { confirmMerge = true }
                    }
                }
            }
            .confirmationDialog("Merge these two people?", isPresented: $confirmMerge, titleVisibility: .visible) {
                Button("Merge") {
                    Task {
                        await appModel.store.merge(from: selection[0], into: selection[1])
                        await appModel.refreshPeople()
                    }
                    isSelecting = false
                    selection = []
                }
                Button("Cancel", role: .cancel) {}
            }
            .task {
                await appModel.refreshPeople()
            }
        }
    }

    @ViewBuilder
    private func cell(for person: PersonSummary) -> some View {
        if isSelecting {
            Button {
                toggleSelection(of: person.id)
            } label: {
                cellContent(for: person)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: selection.contains(person.id) ? "checkmark.circle.fill" : "circle")
                            .imageScale(.large)
                            .foregroundStyle(.tint)
                            .padding(4)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(person.name ?? "Unnamed person"), \(person.faceCount) photos")
        } else {
            NavigationLink {
                PersonDetailView(person: person)
            } label: {
                cellContent(for: person)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(person.name ?? "Unnamed person"), \(person.faceCount) photos")
        }
    }

    private func cellContent(for person: PersonSummary) -> some View {
        VStack(spacing: 6) {
            if let cover = person.coverFaceID {
                FaceAvatar(faceID: cover, size: 96)
            } else {
                Circle().fill(.secondary.opacity(0.15)).frame(width: 96, height: 96)
            }
            Text(person.name ?? "Unnamed")
                .font(.subheadline)
                .lineLimit(1)
            Text("\(person.faceCount) photos")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func toggleSelection(of id: UUID) {
        if let index = selection.firstIndex(of: id) {
            selection.remove(at: index)
        } else if selection.count < 2 {
            selection.append(id)
        }
    }
}
