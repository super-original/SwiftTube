import Foundation
import ImageIO

struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage
}

private struct DecodedImageRequest: Hashable {
    let url: URL
    let maxPixelSize: Int?

    var cacheKey: NSString {
        "\(url.absoluteString)#\(maxPixelSize ?? 0)" as NSString
    }
}

private final class DecodedImageMemoryCache: @unchecked Sendable {
    static let shared = DecodedImageMemoryCache()

    private let cache = NSCache<NSString, DecodedImageBox>()

    private init() {
        cache.countLimit = 512
    }

    func image(for key: NSString) -> DecodedImage? {
        cache.object(forKey: key)?.image
    }

    func insert(_ image: DecodedImage, for key: NSString) {
        cache.setObject(DecodedImageBox(image: image), forKey: key)
    }
}

private final class DecodedImageBox: NSObject {
    let image: DecodedImage

    init(image: DecodedImage) {
        self.image = image
    }
}

actor ImageCache {
    static let shared = ImageCache()

    private let cache = DecodedImageMemoryCache.shared
    private var inFlightTasks: [DecodedImageRequest: Task<DecodedImage, Error>] = [:]

    private init() {}

    func loadDecodedImage(from url: URL, maxPixelSize: Int? = nil) async throws -> DecodedImage {
        let request = DecodedImageRequest(url: url, maxPixelSize: maxPixelSize)

        if let cached = cache.image(for: request.cacheKey) {
            return cached
        }

        if let inFlightTask = inFlightTasks[request] {
            return try await inFlightTask.value
        }

        let task = Task(priority: .utility) {
            try await Self.fetchDecodedImage(from: url, maxPixelSize: maxPixelSize)
        }
        inFlightTasks[request] = task

        defer {
            inFlightTasks[request] = nil
        }

        let image = try await task.value
        cache.insert(image, for: request.cacheKey)
        return image
    }

    nonisolated private static func fetchDecodedImage(
        from url: URL,
        maxPixelSize: Int?
    ) async throws -> DecodedImage {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw URLError(.cannotDecodeContentData)
        }

        let cgImage: CGImage?
        if let maxPixelSize, maxPixelSize > 0 {
            cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceShouldCacheImmediately: false,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                ] as CFDictionary
            )
        } else {
            cgImage = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [
                    kCGImageSourceShouldCache: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
            )
        }

        guard let cgImage else {
            throw URLError(.cannotDecodeContentData)
        }

        return forceDecode(cgImage)
    }

    nonisolated private static func forceDecode(_ image: CGImage) -> DecodedImage {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)

        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return DecodedImage(cgImage: image)
        }

        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)

        if let decoded = context.makeImage() {
            return DecodedImage(cgImage: decoded)
        }

        return DecodedImage(cgImage: image)
    }
}

@MainActor
final class ImageLoader: ObservableObject {
    @Published private(set) var image: DecodedImage? = nil
    @Published private(set) var shouldAnimatePresentation = false

    private var activeRequest: DecodedImageRequest? = nil
    private var loadTask: Task<Void, Never>? = nil

    deinit {
        loadTask?.cancel()
    }

    func load(from url: URL?, maxPixelSize: Int? = nil) {
        guard let url else {
            loadTask?.cancel()
            activeRequest = nil
            image = nil
            shouldAnimatePresentation = false
            return
        }

        let request = DecodedImageRequest(url: url, maxPixelSize: maxPixelSize)
        if activeRequest == request {
            return
        }

        loadTask?.cancel()
        activeRequest = request

        if let cachedImage = DecodedImageMemoryCache.shared.image(for: request.cacheKey) {
            shouldAnimatePresentation = false
            image = cachedImage
            return
        }

        image = nil
        shouldAnimatePresentation = true

        loadTask = Task { [weak self] in
            do {
                let decodedImage = try await ImageCache.shared.loadDecodedImage(
                    from: url,
                    maxPixelSize: maxPixelSize
                )
                guard !Task.isCancelled else { return }
                guard self?.activeRequest == request else { return }
                self?.image = decodedImage
            } catch {
                self?.shouldAnimatePresentation = false
                // Ignore image loading errors to keep UI responsive.
            }
        }
    }
}
