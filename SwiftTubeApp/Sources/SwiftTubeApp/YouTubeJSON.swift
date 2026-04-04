import Foundation

typealias JSONDictionary = [String: Any]

struct InnerTubeCommand: @unchecked Sendable {
    let apiPath: String
    let payload: JSONDictionary
}

enum JSONWalkResult {
    case `continue`
    case stop
}

func visitJSONObjects(in value: Any, _ body: (JSONDictionary) -> JSONWalkResult) {
    if _visitJSONObjects(in: value, body) == .stop {
        return
    }
}

@discardableResult
private func _visitJSONObjects(
    in value: Any,
    _ body: (JSONDictionary) -> JSONWalkResult
) -> JSONWalkResult {
    if let object = value as? JSONDictionary {
        if body(object) == .stop {
            return .stop
        }

        for nestedValue in object.values {
            if _visitJSONObjects(in: nestedValue, body) == .stop {
                return .stop
            }
        }
        return .continue
    }

    if let array = value as? [Any] {
        for nestedValue in array {
            if _visitJSONObjects(in: nestedValue, body) == .stop {
                return .stop
            }
        }
    }

    return .continue
}

func textValue(from value: Any?) -> String? {
    guard let object = value as? JSONDictionary else { return nil }

    if let simpleText = object["simpleText"] as? String, !simpleText.isEmpty {
        return simpleText
    }

    guard let runs = object["runs"] as? [Any] else { return nil }
    let joined = runs.compactMap { run -> String? in
        (run as? JSONDictionary)?["text"] as? String
    }.joined()
    return joined.isEmpty ? nil : joined
}

func contentTextValue(from value: Any?) -> String? {
    guard let object = value as? JSONDictionary else { return nil }
    if let content = object["content"] as? String, !content.isEmpty {
        return content
    }
    return textValue(from: object)
}

func thumbnails(from value: Any?) -> [Thumbnail] {
    guard
        let object = value as? JSONDictionary,
        let entries = object["thumbnails"] as? [Any]
    else {
        return []
    }

    return entries.compactMap { entry in
        guard let entry = entry as? JSONDictionary else { return nil }
        guard let url = normalizeURL(entry["url"]) else { return nil }
        return Thumbnail(
            url: url,
            width: entry["width"] as? Int,
            height: entry["height"] as? Int
        )
    }
}

func sourceThumbnails(from value: Any?) -> [Thumbnail] {
    guard
        let object = value as? JSONDictionary,
        let entries = object["sources"] as? [Any]
    else {
        return []
    }

    return entries.compactMap { entry in
        guard let entry = entry as? JSONDictionary else { return nil }
        guard let url = normalizeURL(entry["url"]) else { return nil }
        return Thumbnail(
            url: url,
            width: entry["width"] as? Int,
            height: entry["height"] as? Int
        )
    }
}

func firstThumbnailURL(_ thumbnails: [Thumbnail]) -> String? {
    thumbnails.first?.url
}

func normalizeURL(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else { return nil }
    if value.hasPrefix("//") {
        return "https:\(value)"
    }
    return value
}

func channelID(from value: Any?) -> String? {
    guard let object = value as? JSONDictionary else { return nil }

    if let channelID = object["channelId"] as? String, !channelID.isEmpty {
        return channelID
    }

    for sourceKey in ["ownerText", "shortBylineText", "longBylineText", "bylineText"] {
        if let source = object[sourceKey] as? JSONDictionary,
           let runs = source["runs"] as? [Any] {
            for run in runs {
                guard let run = run as? JSONDictionary else { continue }
                let browseID = (((run["navigationEndpoint"] as? JSONDictionary)?["browseEndpoint"] as? JSONDictionary)?["browseId"] as? String)
                if let browseID, browseID.hasPrefix("UC") {
                    return browseID
                }
            }
        }
    }

    if let ownerBrowseID = ((((object["owner"] as? JSONDictionary)?["videoOwnerRenderer"] as? JSONDictionary)?["navigationEndpoint"] as? JSONDictionary)?["browseEndpoint"] as? JSONDictionary)?["browseId"] as? String,
       ownerBrowseID.hasPrefix("UC") {
        return ownerBrowseID
    }

    for nestedValue in object.values {
        if let channelID = channelID(from: nestedValue) {
            return channelID
        }
    }

    return nil
}

func channelAvatarURL(from value: Any?) -> String? {
    guard let object = value as? JSONDictionary else { return nil }

    let directCandidates: [Any?] = [
        object["channelThumbnail"],
        object["avatar"],
        object["ownerThumbnail"],
        (((object["channelThumbnailSupportedRenderers"] as? JSONDictionary)?["channelThumbnailWithLinkRenderer"] as? JSONDictionary)),
        (((object["channelThumbnailSupportedRenderers"] as? JSONDictionary)?["channelThumbnailRenderer"] as? JSONDictionary)),
        (((object["owner"] as? JSONDictionary)?["videoOwnerRenderer"] as? JSONDictionary)),
    ]

    for candidate in directCandidates {
        if let url = thumbnailURLCandidate(from: candidate) {
            return url
        }
    }

    for nestedValue in object.values {
        if let url = channelAvatarURL(from: nestedValue) {
            return url
        }
    }

    return nil
}

func rowTextParts(_ value: Any?) -> [String] {
    guard
        let object = value as? JSONDictionary,
        let parts = object["metadataParts"] as? [Any]
    else {
        return []
    }

    return parts.compactMap { part in
        guard let part = part as? JSONDictionary else { return nil }
        return contentTextValue(from: part["text"]) ?? textValue(from: part["text"])
    }
}

func splitMetadataText(_ value: String?) -> [String] {
    guard let value else { return [] }
    return value
        .components(separatedBy: CharacterSet(charactersIn: "·•"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func thumbnailURLCandidate(from value: Any?) -> String? {
    guard let object = value as? JSONDictionary else { return nil }

    let candidates: [Any?] = [
        object,
        object["thumbnail"],
        object["image"],
    ]

    for candidate in candidates {
        let url = firstThumbnailURL(thumbnails(from: candidate))
        if url != nil {
            return url
        }
    }

    return nil
}
