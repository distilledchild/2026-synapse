import SwiftUI

struct OutgoingPhotoPreview: View {
    let photo: PhotoAttachment
    let disabled: Bool
    let onRemove: () -> Void
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                } else { Image(systemName: "photo").font(.title) }
            }.frame(width: 76, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(photo.name).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(photo.byteCount), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).help("Remove photo").accessibilityLabel("Remove photo").disabled(disabled)
        }.padding(8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .task(id: photo.id) {
            let photo = photo
            thumbnail = await Task.detached(priority: .utility) {
                (try? PhotoFile.verifiedData(photo)).flatMap(PhotoFile.thumbnail)
            }.value
        }
    }
}
