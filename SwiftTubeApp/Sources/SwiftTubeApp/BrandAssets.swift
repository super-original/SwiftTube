import AppKit

enum BrandAssets {
    private static let logoResource = ("SwiftTube Logo", "svg", "Brand")
    private static let youtubeMarkResource = ("YouTube Mark", "svg", "Brand")

    static let logo: NSImage? = loadImage(
        named: logoResource.0,
        extension: logoResource.1,
        subdirectory: logoResource.2
    )

    static let youtubeMark: NSImage? = loadImage(
        named: youtubeMarkResource.0,
        extension: youtubeMarkResource.1,
        subdirectory: youtubeMarkResource.2
    )

    static func installApplicationIcon() {}

    private static func loadImage(
        named name: String,
        extension ext: String,
        subdirectory: String
    ) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
