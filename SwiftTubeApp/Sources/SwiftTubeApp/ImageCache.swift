import Foundation
import ImageIO

struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage
}

private final class DecodedImageBox: NSObject {
    let image: DecodedImage

    init(image: DecodedImage) {
        self.image = image
    }
}

actor ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, DecodedImageBox>()
    private var inFlightTasks: [URL: Task<DecodedImage, Error>] = [:]

    private init() {
        cache.countLimit = 512
    }

    func loadDecodedImage(from url: URL) async throws -> DecodedImage {
        if let cached = cache.object(forKey: url as NSURL)?.image {
            return cached
        }

        if let inFlightTask = inFlightTasks[url] {
            return try await inFlightTask.value
        }

        let task = Task(priority: .utility) {
            try await Self.fetchDecodedImage(from: url)
        }
        inFlightTasks[url] = task

        defer {
            inFlightTasks[url] = nil
        }

        let image = try await task.value
        cache.setObject(DecodedImageBox(image: image), forKey: url as NSURL)
        return image
    }

    nonisolated private static func fetchDecodedImage(from url: URL) async throws -> DecodedImage {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceShouldCache: true,
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary
              ) else {
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

    private var activeURL: URL? = nil
    private var loadTask: Task<Void, Never>? = nil

    deinit {
        loadTask?.cancel()
    }

    func load(from url: URL?) {
        activeURL = url
        loadTask?.cancel()
        image = nil

        guard let url else { return }

        loadTask = Task { [weak self] in
            do {
                let decodedImage = try await ImageCache.shared.loadDecodedImage(from: url)
                guard !Task.isCancelled else { return }
                guard self?.activeURL == url else { return }
                self?.image = decodedImage
            } catch {
                // Ignore image loading errors to keep UI responsive.
            }
        }
    }
}
