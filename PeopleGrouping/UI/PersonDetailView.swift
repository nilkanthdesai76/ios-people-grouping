import SwiftUI

struct PersonDetailView: View {
    let person: PersonSummary
    @Environment(AppModel.self) private var appModel
    @State private var assetIDs: [String] = []
    @State private var showingRename = false
    @State private var newName = ""
    @State private var mergeTarget: UUID?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let cover = person.coverFaceID {
                    FaceAvatar(faceID: cover, size: 120)
                }
                Button(person.name ?? "Add a name") {
                    newName = person.name ?? ""
                    showingRename = true
                }
                .font(.title2.bold())
                Text("\(person.faceCount) photos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(assetIDs, id: \.self) { assetID in
                        NavigationLink {
                            PhotoViewerView(assetID: assetID)
                        } label: {
                            AssetThumbnail(assetID: assetID)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Not this person", systemImage: "person.crop.circle.badge.xmark") {
                                Task { await removeFaces(from: assetID) }
                            }
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(person.name ?? "Person")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename") {
                        newName = person.name ?? ""
                        showingRename = true
                    }
                    if let firstTarget = otherPeople.first {
                        Button("Merge into…") { mergeTarget = firstTarget.id }
                    }
                    Button("Hide person", role: .destructive) {
                        Task {
                            await appModel.store.hide(person: person.id)
                            await appModel.refreshPeople()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Person options")
            }
        }
        .alert("Rename person", isPresented: $showingRename) {
            TextField("Name", text: $newName)
            Button("Save") {
                Task {
                    await appModel.store.rename(person: person.id, name: newName)
                    await appModel.refreshPeople()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Merge into which person?", isPresented: isMergeTargetPresented, titleVisibility: .visible) {
            ForEach(otherPeople) { target in
                Button(target.name ?? "Unnamed") {
                    Task {
                        await appModel.store.merge(from: person.id, into: target.id)
                        await appModel.refreshPeople()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            await loadAssets()
        }
    }

    private var otherPeople: [PersonSummary] {
        appModel.people.filter { $0.id != person.id }
    }

    private var isMergeTargetPresented: Binding<Bool> {
        Binding(
            get: { mergeTarget != nil },
            set: { if !$0 { mergeTarget = nil } }
        )
    }

    private func loadAssets() async {
        assetIDs = await appModel.store.assetIDs(forPerson: person.id)
    }

    private func removeFaces(from assetID: String) async {
        let faces = await appModel.store.faces(inAsset: assetID)
        for face in faces where face.personID == person.id {
            await appModel.store.removeFace(face.id, fromPerson: person.id)
        }
        await appModel.refreshPeople()
        await loadAssets()
    }
}

private struct AssetThumbnail: View {
    let assetID: String
    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                if loadFailed {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Photo could not be loaded from iCloud")
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .clipped()
            .task(id: assetID) {
                image = nil
                loadFailed = false
                let loaded = await PhotoLibraryService().loadDisplayImage(
                    id: assetID,
                    targetSize: CGSize(width: 300, height: 300)
                )
                if let loaded {
                    image = loaded
                } else {
                    loadFailed = true
                }
            }
            .accessibilityLabel("Photo")
    }
}
