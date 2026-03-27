import SwiftUI

struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    let maxPixelSize: Int?
    let contentMode: ContentMode
    let placeholder: Placeholder

    @StateObject private var loader = ImageLoader()

    init(
        url: URL?,
        maxPixelSize: Int? = nil,
        contentMode: ContentMode = .fill,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        self.placeholder = placeholder()
    }

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .onAppear {
            loader.load(from: url, maxPixelSize: maxPixelSize)
        }
        .onChange(of: url) { _, newValue in
            loader.load(from: newValue, maxPixelSize: maxPixelSize)
        }
        .onChange(of: maxPixelSize) { _, newValue in
            loader.load(from: url, maxPixelSize: newValue)
        }
    }
}
