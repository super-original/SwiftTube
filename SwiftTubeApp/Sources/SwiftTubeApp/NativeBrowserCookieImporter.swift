import CommonCrypto
import Foundation
import Security
import SQLite3

enum NativeBrowserCookieImporter {
    static func exportCookies(for browser: BrowserLoginOption, profilePath: String? = nil, to destinationURL: URL) throws {
        let cookies: [NativeBrowserCookie]
        switch browser {
        case .safari:
            cookies = try SafariCookieReader().cookies()
        case .firefox, .zen, .librewolf, .floorp:
            cookies = try FirefoxCookieReader(browser: browser, explicitProfilePath: profilePath).cookies()
        default:
            cookies = try ChromiumCookieReader(browser: browser, explicitProfilePath: profilePath).cookies()
        }

        let relevantCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            return domain.contains("youtube") || domain.contains("google")
        }
        guard relevantCookies.isEmpty == false else {
            throw BackendClientError(message: "No usable YouTube cookies were found in \(browser.displayName).")
        }

        try writeNetscapeCookieFile(relevantCookies, to: destinationURL)
    }
}

private struct NativeBrowserCookie {
    let domain: String
    let path: String
    let isSecure: Bool
    let expires: Int64?
    let name: String
    let value: String
}

private func writeNetscapeCookieFile(_ cookies: [NativeBrowserCookie], to destinationURL: URL) throws {
    try? FileManager.default.removeItem(at: destinationURL)
    let lines = cookies.map { cookie in
        [
            cookie.domain,
            cookie.domain.hasPrefix(".") ? "TRUE" : "FALSE",
            cookie.path.isEmpty ? "/" : cookie.path,
            cookie.isSecure ? "TRUE" : "FALSE",
            String(cookie.expires ?? 0),
            cookie.name,
            cookie.value
        ].joined(separator: "\t")
    }

    let contents = "# Netscape HTTP Cookie File\n" + lines.joined(separator: "\n") + "\n"
    try contents.write(to: destinationURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
}

private struct FirefoxCookieReader {
    let browser: BrowserLoginOption
    let explicitProfilePath: String?

    func cookies() throws -> [NativeBrowserCookie] {
        let profileURL = try profileDirectory()
        let cookieDB = profileURL.appendingPathComponent("cookies.sqlite")
        let db = try SQLiteDatabase(copying: cookieDB)
        defer { db.close() }

        let version = db.intValue("PRAGMA user_version;") ?? 0
        let rows = try db.query(
            """
            SELECT host, name, value, path, expiry, isSecure
            FROM moz_cookies
            WHERE host LIKE '%youtube%' OR host LIKE '%google%'
            """
        )

        return rows.compactMap { row in
            guard let domain = row.string(at: 0),
                  let name = row.string(at: 1),
                  let value = row.string(at: 2) else {
                return nil
            }
            let rawExpiry = row.int64(at: 4)
            let expiry = version >= 16 ? rawExpiry / 1000 : rawExpiry
            return NativeBrowserCookie(
                domain: domain,
                path: row.string(at: 3) ?? "/",
                isSecure: row.bool(at: 5),
                expires: expiry > 0 ? expiry : nil,
                name: name,
                value: value
            )
        }
    }

    private func profileDirectory() throws -> URL {
        if let explicitProfilePath {
            return URL(fileURLWithPath: explicitProfilePath)
        }
        if let path = profilePath(from: browser.cookieSource) {
            return URL(fileURLWithPath: path)
        }

        guard let baseURL = applicationSupportURL else {
            throw BackendClientError(message: "Could not find Application Support.")
        }

        let relativePath: String
        switch browser {
        case .firefox:
            relativePath = "Firefox/Profiles"
        case .zen:
            relativePath = "zen/Profiles"
        case .librewolf:
            relativePath = "LibreWolf/Profiles"
        case .floorp:
            relativePath = "Floorp/Profiles"
        default:
            relativePath = "Firefox/Profiles"
        }

        return try newestProfile(
            in: baseURL.appendingPathComponent(relativePath, isDirectory: true),
            cookieRelativePaths: ["cookies.sqlite"]
        )
    }
}

private struct ChromiumCookieReader {
    let browser: BrowserLoginOption
    let explicitProfilePath: String?

    func cookies() throws -> [NativeBrowserCookie] {
        let profileURL = try profileDirectory()
        let cookieDB = try chromiumCookieDatabase(in: profileURL)
        let db = try SQLiteDatabase(copying: cookieDB)
        defer { db.close() }

        let metaVersion = db.intValue("SELECT value FROM meta WHERE key = 'version'") ?? 0
        let secureColumn = db.columnNames(table: "cookies").contains("is_secure") ? "is_secure" : "secure"
        let key = try keychainKey()
        let rows = try db.query(
            """
            SELECT host_key, name, value, encrypted_value, path, expires_utc, \(secureColumn)
            FROM cookies
            WHERE host_key LIKE '%youtube%' OR host_key LIKE '%google%'
            """
        )

        return rows.compactMap { row in
            guard let domain = row.string(at: 0),
                  let name = row.string(at: 1) else {
                return nil
            }

            let plainValue = row.string(at: 2) ?? ""
            let value: String
            if plainValue.isEmpty, let encryptedValue = row.blob(at: 3), encryptedValue.isEmpty == false {
                guard let decrypted = decryptChromiumCookie(encryptedValue, key: key, stripsHashPrefix: metaVersion >= 24) else {
                    return nil
                }
                value = decrypted
            } else {
                value = plainValue
            }

            return NativeBrowserCookie(
                domain: domain,
                path: row.string(at: 4) ?? "/",
                isSecure: row.bool(at: 6),
                expires: chromeExpiryToUnix(row.int64(at: 5)),
                name: name,
                value: value
            )
        }
    }

    private func profileDirectory() throws -> URL {
        if let explicitProfilePath {
            return URL(fileURLWithPath: explicitProfilePath)
        }
        if let path = profilePath(from: browser.cookieSource) {
            return URL(fileURLWithPath: path)
        }

        guard let baseURL = applicationSupportURL else {
            throw BackendClientError(message: "Could not find Application Support.")
        }

        let root: URL
        switch browser {
        case .chrome:
            root = baseURL.appendingPathComponent("Google/Chrome", isDirectory: true)
        case .edge:
            root = baseURL.appendingPathComponent("Microsoft Edge", isDirectory: true)
        case .brave:
            root = baseURL.appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true)
        case .arc:
            root = baseURL.appendingPathComponent("Arc/User Data", isDirectory: true)
        case .helium:
            root = baseURL.appendingPathComponent("Helium/User Data", isDirectory: true)
        case .chromium:
            root = baseURL.appendingPathComponent("Chromium", isDirectory: true)
        case .vivaldi:
            root = baseURL.appendingPathComponent("Vivaldi", isDirectory: true)
        case .opera:
            root = baseURL.appendingPathComponent("com.operasoftware.Opera", isDirectory: true)
        case .whale:
            root = baseURL.appendingPathComponent("Naver/Whale", isDirectory: true)
        default:
            root = baseURL.appendingPathComponent("Google/Chrome", isDirectory: true)
        }

        if browser == .opera {
            return root
        }

        return try newestProfile(
            in: root,
            preferredNames: ["Default", "Profile 1", "Profile 2", "Profile 3"],
            cookieRelativePaths: ["Network/Cookies", "Cookies"]
        )
    }

    private func keychainKey() throws -> Data {
        for name in browser.keychainNames {
            if let password = keychainPassword(account: name, service: "\(name) Safe Storage"),
               let key = pbkdf2SHA1(password: password, salt: Data("saltysalt".utf8), iterations: 1003, keyLength: 16) {
                return key
            }
        }

        throw BackendClientError(message: "Could not read \(browser.displayName) Safe Storage key from Keychain.")
    }
}

private struct SafariCookieReader {
    func cookies() throws -> [NativeBrowserCookie] {
        let url = try cookieFileURL()
        return try SafariBinaryCookieParser(data: Data(contentsOf: url)).cookies()
    }

    private func cookieFileURL() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        ]

        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return url
        }
        throw BackendClientError(message: "Could not find Safari cookies.")
    }
}

private struct SafariBinaryCookieParser {
    let data: Data
    private static let macAbsoluteTimeOffset: Double = 978_307_200

    func cookies() throws -> [NativeBrowserCookie] {
        var reader = BinaryReader(data: data)
        try reader.expect(Data("cook".utf8))
        let pageCount = try reader.readUInt32BE()
        let pageSizes = try (0..<pageCount).map { _ in try reader.readUInt32BE() }
        let bodyStart = reader.offset

        var cookies: [NativeBrowserCookie] = []
        var bodyReader = BinaryReader(data: data.subdata(in: bodyStart..<data.count))
        for pageSize in pageSizes {
            let pageData = try bodyReader.readData(Int(pageSize))
            cookies.append(contentsOf: try parsePage(pageData))
        }
        return cookies
    }

    private func parsePage(_ pageData: Data) throws -> [NativeBrowserCookie] {
        var reader = BinaryReader(data: pageData)
        try reader.expect(Data([0x00, 0x00, 0x01, 0x00]))
        let cookieCount = try reader.readUInt32LE()
        let offsets = try (0..<cookieCount).map { _ in try reader.readUInt32LE() }
        return try offsets.compactMap { offset in
            try parseRecord(pageData.subdata(in: Int(offset)..<pageData.count))
        }
    }

    private func parseRecord(_ recordData: Data) throws -> NativeBrowserCookie? {
        var reader = BinaryReader(data: recordData)
        let recordSize = try Int(reader.readUInt32LE())
        guard recordSize <= recordData.count else { return nil }
        try reader.skip(4)
        let flags = try reader.readUInt32LE()
        let isSecure = (flags & 0x0001) != 0
        try reader.skip(4)
        let domainOffset = try Int(reader.readUInt32LE())
        let nameOffset = try Int(reader.readUInt32LE())
        let pathOffset = try Int(reader.readUInt32LE())
        let valueOffset = try Int(reader.readUInt32LE())
        try reader.skip(8)
        let expirationDate = try reader.readDoubleLE()
        _ = try reader.readDoubleLE()

        let record = recordData.subdata(in: 0..<recordSize)
        guard let domain = cString(in: record, at: domainOffset),
              let name = cString(in: record, at: nameOffset),
              let path = cString(in: record, at: pathOffset),
              let value = cString(in: record, at: valueOffset) else {
            return nil
        }

        return NativeBrowserCookie(
            domain: domain,
            path: path,
            isSecure: isSecure,
            expires: Int64(expirationDate + Self.macAbsoluteTimeOffset),
            name: name,
            value: value
        )
    }
}

private final class SQLiteDatabase {
    private var db: OpaquePointer?
    private let copiedURL: URL

    init(copying sourceURL: URL) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw BackendClientError(message: "Could not find cookie database at \(sourceURL.path).")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftTube-Cookies-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: sourceURL, to: tempURL)
        copiedURL = tempURL

        guard sqlite3_open_v2(tempURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.flatMap { sqlite3_errmsg($0).map(String.init(cString:)) } ?? "Could not open cookie database."
            close()
            throw BackendClientError(message: message)
        }
    }

    func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
        try? FileManager.default.removeItem(at: copiedURL)
    }

    func query(_ sql: String) throws -> [SQLiteRow] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BackendClientError(message: sqlite3_errmsg(db).map(String.init(cString:)) ?? "Failed to prepare cookie query.")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [SQLiteRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = sqlite3_column_count(statement)
            var values: [SQLiteValue] = []
            for index in 0..<count {
                values.append(SQLiteValue(statement: statement, index: index))
            }
            rows.append(SQLiteRow(values: values))
        }
        return rows
    }

    func intValue(_ sql: String) -> Int? {
        try? query(sql).first?.int(at: 0)
    }

    func columnNames(table: String) -> Set<String> {
        let rows = (try? query("PRAGMA table_info(\(table));")) ?? []
        return Set(rows.compactMap { $0.string(at: 1) })
    }
}

private enum SQLiteValue {
    case null
    case int64(Int64)
    case text(String)
    case blob(Data)

    init(statement: OpaquePointer?, index: Int32) {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            self = .int64(sqlite3_column_int64(statement, index))
        case SQLITE_TEXT:
            let text = sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
            self = .text(text)
        case SQLITE_BLOB:
            let bytes = sqlite3_column_blob(statement, index)
            let count = Int(sqlite3_column_bytes(statement, index))
            if let bytes, count > 0 {
                self = .blob(Data(bytes: bytes, count: count))
            } else {
                self = .blob(Data())
            }
        default:
            self = .null
        }
    }
}

private struct SQLiteRow {
    let values: [SQLiteValue]

    func string(at index: Int) -> String? {
        guard values.indices.contains(index) else { return nil }
        if case .text(let value) = values[index] { return value }
        return nil
    }

    func blob(at index: Int) -> Data? {
        guard values.indices.contains(index) else { return nil }
        if case .blob(let value) = values[index] { return value }
        return nil
    }

    func int64(at index: Int) -> Int64 {
        guard values.indices.contains(index) else { return 0 }
        if case .int64(let value) = values[index] { return value }
        if case .text(let value) = values[index] { return Int64(value) ?? 0 }
        return 0
    }

    func int(at index: Int) -> Int {
        Int(int64(at: index))
    }

    func bool(at index: Int) -> Bool {
        int64(at: index) != 0
    }
}

private struct BinaryReader {
    let data: Data
    var offset: Int = 0

    mutating func expect(_ expected: Data) throws {
        let actual = try readData(expected.count)
        guard actual == expected else {
            throw BackendClientError(message: "Unexpected cookie file signature.")
        }
    }

    mutating func readData(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw BackendClientError(message: "Cookie file ended unexpectedly.")
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func skip(_ count: Int) throws {
        _ = try readData(count)
    }

    mutating func readUInt32LE() throws -> UInt32 {
        let bytes = [UInt8](try readData(4))
        return UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
    }

    mutating func readUInt32BE() throws -> UInt32 {
        let bytes = [UInt8](try readData(4))
        return UInt32(bytes[3])
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[0]) << 24
    }

    mutating func readDoubleLE() throws -> Double {
        let bytes = [UInt8](try readData(8))
        let bits = UInt64(bytes[0])
            | UInt64(bytes[1]) << 8
            | UInt64(bytes[2]) << 16
            | UInt64(bytes[3]) << 24
            | UInt64(bytes[4]) << 32
            | UInt64(bytes[5]) << 40
            | UInt64(bytes[6]) << 48
            | UInt64(bytes[7]) << 56
        return Double(bitPattern: bits)
    }
}

private var applicationSupportURL: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
}

private func profilePath(from cookieSource: String?) -> String? {
    guard let cookieSource, let separator = cookieSource.firstIndex(of: ":") else { return nil }
    let pathStart = cookieSource.index(after: separator)
    let path = String(cookieSource[pathStart...])
    return path.hasPrefix("/") ? path : nil
}

private func newestProfile(
    in baseURL: URL,
    preferredNames: [String] = [],
    cookieRelativePaths: [String]
) throws -> URL {
    let fileManager = FileManager.default
    let preferredURLs = preferredNames.map { baseURL.appendingPathComponent($0, isDirectory: true) }
    let discoveredURLs = (try? fileManager.contentsOfDirectory(
        at: baseURL,
        includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []

    let sortedDiscovered = discoveredURLs
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }

    for profileURL in preferredURLs + sortedDiscovered {
        guard fileManager.fileExists(atPath: profileURL.path) else { continue }
        if cookieRelativePaths.contains(where: { fileManager.fileExists(atPath: profileURL.appendingPathComponent($0).path) }) {
            return profileURL
        }
    }

    throw BackendClientError(message: "Could not find a readable browser cookie profile.")
}

private func chromiumCookieDatabase(in profileURL: URL) throws -> URL {
    let candidates = [
        profileURL.appendingPathComponent("Network/Cookies"),
        profileURL.appendingPathComponent("Cookies")
    ]
    if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
        return url
    }
    throw BackendClientError(message: "Could not find Chromium cookies database.")
}

private func keychainPassword(account: String, service: String) -> Data? {
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrAccount: account,
        kSecAttrService: service,
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
        return nil
    }
    return result as? Data
}

private func pbkdf2SHA1(password: Data, salt: Data, iterations: UInt32, keyLength: Int) -> Data? {
    var key = Data(count: keyLength)
    let status = key.withUnsafeMutableBytes { keyBytes in
        password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress,
                    password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    iterations,
                    keyBytes.bindMemory(to: UInt8.self).baseAddress,
                    keyLength
                )
            }
        }
    }
    return status == kCCSuccess ? key : nil
}

private func decryptChromiumCookie(_ encryptedValue: Data, key: Data, stripsHashPrefix: Bool) -> String? {
    let prefix = Data("v10".utf8)
    guard encryptedValue.starts(with: prefix) else {
        return String(data: encryptedValue, encoding: .utf8)
    }

    let ciphertext = encryptedValue.dropFirst(prefix.count)
    let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
    let outputCapacity = output.count
    var outputLength = 0

    let status = output.withUnsafeMutableBytes { outputBytes in
        ciphertext.withUnsafeBytes { ciphertextBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        key.count,
                        ivBytes.bindMemory(to: UInt8.self).baseAddress,
                        ciphertextBytes.bindMemory(to: UInt8.self).baseAddress,
                        ciphertext.count,
                        outputBytes.bindMemory(to: UInt8.self).baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
    }
    guard status == kCCSuccess else { return nil }
    output.removeSubrange(outputLength..<output.count)
    if stripsHashPrefix, output.count > 32 {
        output.removeFirst(32)
    }
    return String(data: output, encoding: .utf8)
}

private func chromeExpiryToUnix(_ expiresUTC: Int64) -> Int64? {
    guard expiresUTC > 0 else { return nil }
    let unix = expiresUTC / 1_000_000 - 11_644_473_600
    return unix > 0 ? unix : nil
}

private func cString(in data: Data, at offset: Int) -> String? {
    guard offset >= 0, offset < data.count else { return nil }
    guard let end = data[offset...].firstIndex(of: 0) else { return nil }
    return String(data: data.subdata(in: offset..<end), encoding: .utf8)
}

private extension BrowserLoginOption {
    var keychainNames: [String] {
        switch self {
        case .chrome:
            return ["Chrome"]
        case .edge:
            return ["Microsoft Edge", "Chromium"]
        case .brave:
            return ["Brave"]
        case .arc:
            return ["Arc", "Chrome"]
        case .helium:
            return ["Helium", "Chrome"]
        case .chromium:
            return ["Chromium"]
        case .vivaldi:
            return ["Vivaldi", "Chrome"]
        case .opera:
            return ["Opera"]
        case .whale:
            return ["Whale"]
        default:
            return [displayName]
        }
    }
}
