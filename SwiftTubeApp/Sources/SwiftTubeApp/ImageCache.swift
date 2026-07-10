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
        cache.totalCostLimit = 192 * 1_024 * 1_024
    }

    func image(for key: NSString) -> DecodedImage? {
        cache.object(forKey: key)?.image
    }

    func insert(_ image: DecodedImage, for key: NSString) {
        let cost = image.cgImage.bytesPerRow * image.cgImage.height
        cache.setObject(DecodedImageBox(image: image), forKey: key, cost: cost)
    }
}

private final class DecodedImageBox: NSObject {
    let image: DecodedImage

    init(image: DecodedImage) {
        self.image = image
    }
}

/// Owns raw thumbnail transport separately from decoded variants. A single URL may be
/// requested at several display sizes; coalescing here prevents downloading it once per size.
private actor ImageDataPipeline {
    static let shared = ImageDataPipeline()

    private let session: URLSession
    private var inFlightTasks: [URL: Task<Data, Error>] = [:]

    private init() {
        let cache = URLCache(
            memoryCapacity: 96 * 1_024 * 1_024,
            diskCapacity: 768 * 1_024 * 1_024,
            diskPath: "SwiftTubeThumbnails"
        )
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func data(for url: URL) async throws -> Data {
        if let task = inFlightTasks[url] {
            return try await task.value
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 20

        let session = session
        let task = Task(priority: .userInitiated) {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        }
        inFlightTasks[url] = task
        defer { inFlightTasks[url] = nil }
        return try await task.value
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

        let task = Task(priority: .userInitiated) {
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
        let data = try await ImageDataPipeline.shared.data(for: url)

        return try await Task.detached(priority: .utility) {
            try decode(data, maxPixelSize: maxPixelSize)
        }.value
    }

    nonisolated private static func decode(_ data: Data, maxPixelSize: Int?) throws -> DecodedImage {
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
