import Foundation
import CryptoKit

/// Errors emitted by ``R2Client``.
public enum R2ClientError: LocalizedError {
    case invalidEndpoint(String)
    case fileTooLarge(maxSizeMB: Int)
    case emptyResponseBody
    case httpError(statusCode: Int, message: String?)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let rawValue):
            return "Invalid R2 endpoint: \(rawValue)"
        case .fileTooLarge(let maximum):
            return "The payload exceeds \(maximum) MB."
        case .emptyResponseBody:
            return "The object body was empty."
        case .httpError(let status, let message):
            if let message, !message.isEmpty {
                return "Request failed with status \(status): \(message)"
            } else {
                return "Request failed with status \(status)."
            }
        case .unexpectedResponse:
            return "The server response was missing or malformed."
        }
    }
}

/// Options when listing objects from the bucket.
public struct R2ListOptions {
    public var prefix: String?
    public var continuationToken: String?
    public var maxKeys: Int?

    public init(prefix: String? = nil, continuationToken: String? = nil, maxKeys: Int? = nil) {
        self.prefix = prefix
        self.continuationToken = continuationToken
        self.maxKeys = maxKeys
    }
}

/// Basic metadata describing an object within R2.
public struct R2Object: Sendable {
    public let key: String
    public let size: Int
    public let lastModified: Date?
    public let etag: String?
}

/// The result returned from ``R2Client/list(options:)``.
public struct R2ListResult: Sendable {
    public let objects: [R2Object]
    public let nextContinuationToken: String?
    public let isTruncated: Bool
}

/// Small convenience client that talks to Cloudflare R2's S3-compatible API using URLSession.
public final class R2Client {
    public let bucketName: String

    private let session: URLSession
    private let signer: R2RequestSigner
    private let baseEndpoint: URL

    /// Creates a client using the canonical Cloudflare endpoint format (`https://<account>.r2.cloudflarestorage.com`).
    public convenience init(
        bucketName: String,
        accountId: String,
        accessKeyId: String,
        secretAccessKey: String,
        region: String = "auto",
        sessionToken: String? = nil,
        session: URLSession = .shared
    ) throws {
        let endpointString = "https://\(accountId).r2.cloudflarestorage.com"
        guard let endpoint = URL(string: endpointString) else {
            throw R2ClientError.invalidEndpoint(endpointString)
        }

        try self.init(
            bucketName: bucketName,
            endpoint: endpoint,
            region: region,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            session: session
        )
    }

    /// Designated initializer allowing a fully custom endpoint URL.
    public init(
        bucketName: String,
        endpoint: URL,
        region: String = "auto",
        accessKeyId: String,
        secretAccessKey: String,
        sessionToken: String? = nil,
        session: URLSession = .shared
    ) throws {
        self.bucketName = bucketName
        self.session = session
        self.signer = R2RequestSigner(
            credentials: .init(
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey,
                sessionToken: sessionToken
            ),
            region: region
        )

        guard let sanitizedEndpoint = R2Client.cleanEndpointURL(from: endpoint) else {
            throw R2ClientError.invalidEndpoint(endpoint.absoluteString)
        }

        self.baseEndpoint = sanitizedEndpoint
    }

    /// Uploads an in-memory payload.
    public func upload(
        data: Data,
        to key: String,
        contentType: String? = nil,
        metadata: [String: String]? = nil,
        cacheControl: String? = nil,
        maxSizeInMB: Int? = nil
    ) async throws {
        if let maxSizeInMB, maxSizeInMB > 0 {
            let limitBytes = Int64(maxSizeInMB) * 1_048_576
            guard Int64(data.count) <= limitBytes else {
                throw R2ClientError.fileTooLarge(maxSizeMB: maxSizeInMB)
            }
        }

        let objectURL = try objectURL(forKey: key)
        var request = URLRequest(url: objectURL)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(cacheControl, forHTTPHeaderField: "Cache-Control")

        if let metadata {
            for (metaKey, value) in metadata {
                let lowercasedKey = metaKey.lowercased()
                request.setValue(value, forHTTPHeaderField: "x-amz-meta-\(lowercasedKey)")
            }
        }

        let signedRequest = try signer.sign(request: request, body: data, date: Date())

        let (_, response) = try await send(signedRequest)
        guard (200...299).contains(response.statusCode) else {
            throw R2ClientError.httpError(statusCode: response.statusCode, message: nil)
        }
    }

    /// Loads a file from disk and uploads it.
    public func uploadFile(
        at fileURL: URL,
        to key: String,
        contentType: String? = nil,
        metadata: [String: String]? = nil,
        cacheControl: String? = nil,
        maxSizeInMB: Int? = nil
    ) async throws {
        let data = try Data(contentsOf: fileURL)
        try await upload(
            data: data,
            to: key,
            contentType: contentType,
            metadata: metadata,
            cacheControl: cacheControl,
            maxSizeInMB: maxSizeInMB
        )
    }

    /// Downloads an object and returns it as `Data`.
    public func download(
        key: String,
        allowEmpty: Bool = true
    ) async throws -> Data {
        let objectURL = try objectURL(forKey: key)
        var request = URLRequest(url: objectURL)
        request.httpMethod = "GET"

        let signedRequest = try signer.sign(request: request, body: Data(), date: Date())
        let (data, response) = try await send(signedRequest)

        guard (200...299).contains(response.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)
            throw R2ClientError.httpError(statusCode: response.statusCode, message: snippet)
        }

        if data.isEmpty, !allowEmpty {
            throw R2ClientError.emptyResponseBody
        }

        return data
    }

    /// Removes an object from the bucket.
    public func delete(key: String) async throws {
        let objectURL = try objectURL(forKey: key)
        var request = URLRequest(url: objectURL)
        request.httpMethod = "DELETE"

        let signedRequest = try signer.sign(request: request, body: Data(), date: Date())
        let (data, response) = try await send(signedRequest)

        guard (200...299).contains(response.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)
            throw R2ClientError.httpError(statusCode: response.statusCode, message: snippet)
        }
    }

    /// Lists objects inside the bucket.
    public func list(options: R2ListOptions = .init()) async throws -> R2ListResult {
        var components = URLComponents(url: baseEndpoint.appendingPathComponent(bucketName), resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "list-type", value: "2")
        ]

        if let prefix = options.prefix, !prefix.isEmpty {
            queryItems.append(URLQueryItem(name: "prefix", value: prefix))
        }
        if let continuation = options.continuationToken, !continuation.isEmpty {
            queryItems.append(URLQueryItem(name: "continuation-token", value: continuation))
        }
        if let maxKeys = options.maxKeys {
            queryItems.append(URLQueryItem(name: "max-keys", value: "\(maxKeys)"))
        }

        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw R2ClientError.invalidEndpoint("Failed to construct list URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let signedRequest = try signer.sign(request: request, body: Data(), date: Date())
        let (data, response) = try await send(signedRequest)

        guard (200...299).contains(response.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)
            throw R2ClientError.httpError(statusCode: response.statusCode, message: snippet)
        }

        guard !data.isEmpty else {
            return R2ListResult(objects: [], nextContinuationToken: nil, isTruncated: false)
        }

        return try ListBucketResultParser.decode(data: data)
    }

    /// No-op retained for API compatibility with the Soto-based version.
    public func syncShutdown() throws {}

    private func objectURL(forKey key: String) throws -> URL {
        let sanitizedKey = key.hasPrefix("/") ? String(key.dropFirst()) : key
        var url = baseEndpoint.appendingPathComponent(bucketName)

        let segments = sanitizedKey.split(separator: "/", omittingEmptySubsequences: false)
        for segment in segments {
            url.appendPathComponent(String(segment))
        }

        return url
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw R2ClientError.unexpectedResponse
            }
            return (data, httpResponse)
        } catch let error as R2ClientError {
            throw error
        } catch {
            throw error
        }
    }

    private static func cleanEndpointURL(from endpoint: URL) -> URL? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.path = ""
        components.query = nil
        components.fragment = nil

        return components.url
    }
}

private struct R2RequestSigner {
    struct Credentials {
        let accessKeyId: String
        let secretAccessKey: String
        let sessionToken: String?
    }

    enum SigningError: Error {
        case missingURL
    }

    private let credentials: Credentials
    private let region: String
    private let service = "s3"

    init(credentials: Credentials, region: String) {
        self.credentials = credentials
        self.region = region
    }

    func sign(request original: URLRequest, body: Data, date: Date) throws -> URLRequest {
        guard let url = original.url else {
            throw SigningError.missingURL
        }

        var request = original
        let payloadHash = Self.hexDigest(SHA256.hash(data: body))
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        let (amzDate, dateStamp) = Self.timestampComponents(for: date)
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")

        if let token = credentials.sessionToken {
            request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }

        if let host = url.host {
            request.setValue(host, forHTTPHeaderField: "Host")
        }

        let canonicalRequest = try canonicalRequestString(url: url, request: request, payloadHash: payloadHash)
        let hashedCanonicalRequest = Self.hexDigest(SHA256.hash(data: Data(canonicalRequest.utf8)))
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"

        let stringToSign = """
        AWS4-HMAC-SHA256
        \(amzDate)
        \(credentialScope)
        \(hashedCanonicalRequest)
        """

        let signingKey = signingKey(for: dateStamp)
        let signature = Self.hexDigest(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey))

        let signedHeaders = canonicalSignedHeaders(from: request)
        let authorizationValue = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorizationValue, forHTTPHeaderField: "Authorization")

        return request
    }

    private func canonicalRequestString(url: URL, request: URLRequest, payloadHash: String) throws -> String {
        guard let method = request.httpMethod else {
            throw SigningError.missingURL
        }

        let canonicalURI = Self.canonicalURI(from: url)
        let canonicalQuery = Self.canonicalQuery(from: url)
        let canonicalHeaders = Self.canonicalHeaders(from: request)
        let signedHeaders = canonicalSignedHeaders(from: request)

        return """
        \(method)
        \(canonicalURI)
        \(canonicalQuery)
        \(canonicalHeaders)

        \(signedHeaders)
        \(payloadHash)
        """
    }

    private func canonicalSignedHeaders(from request: URLRequest) -> String {
        let headers = request.allHTTPHeaderFields ?? [:]
        let names = Set(headers.keys.map { $0.lowercased() })
            .sorted()
        return names.joined(separator: ";")
    }

    private static func canonicalHeaders(from request: URLRequest) -> String {
        let headers = request.allHTTPHeaderFields ?? [:]
        let processed = headers
            .map { (key: $0.key.lowercased(), value: normalizeWhitespace(in: $0.value)) }
            .sorted { lhs, rhs in lhs.key < rhs.key }

        return processed.map { "\($0.key):\($0.value)" }.joined(separator: "\n")
    }

    private static func canonicalURI(from url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        let encodedSegments = segments.map { percentEncode(String($0)) }
        return encodedSegments.joined(separator: "/")
    }

    private static func canonicalQuery(from url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              !items.isEmpty else {
            return ""
        }

        let sorted = items.sorted { lhs, rhs in
            if lhs.name == rhs.name {
                return (lhs.value ?? "") < (rhs.value ?? "")
            }
            return lhs.name < rhs.name
        }

        return sorted.map { item in
            let value = item.value ?? ""
            return "\(percentEncode(item.name))=\(percentEncode(value))"
        }.joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func normalizeWhitespace(in value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    private func signingKey(for dateStamp: String) -> SymmetricKey {
        let secret = Data(("AWS4" + credentials.secretAccessKey).utf8)
        let kDate = hmac(key: secret, message: dateStamp)
        let kRegion = hmac(key: kDate, message: region)
        let kService = hmac(key: kRegion, message: service)
        let kSigning = hmac(key: kService, message: "aws4_request")
        return SymmetricKey(data: kSigning)
    }

    private func hmac(key: Data, message: String) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
        return Data(signature)
    }

    private static func timestampComponents(for date: Date) -> (amzDate: String, dateStamp: String) {
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0) ?? .gmt, from: date)
        guard
            let year = components.year,
            let month = components.month,
            let day = components.day,
            let hour = components.hour,
            let minute = components.minute,
            let second = components.second
        else {
            return ("", "")
        }

        let amzDate = String(format: "%04d%02d%02dT%02d%02d%02dZ", year, month, day, hour, minute, second)
        let dateStamp = String(format: "%04d%02d%02d", year, month, day)
        return (amzDate, dateStamp)
    }

    private static func hexDigest(_ digest: SHA256.Digest) -> String {
        Data(digest).hexEncodedString()
    }

    private static func hexDigest(_ authenticationCode: HMAC<SHA256>.MAC) -> String {
        Data(authenticationCode).hexEncodedString()
    }
}

private final class ListBucketResultParser: NSObject, XMLParserDelegate {
    private var objects: [R2Object] = []
    private var nextContinuationToken: String?
    private var isTruncated = false

    private var currentElement: String?
    private var currentText = ""
    private var currentObject: PartialObject?

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    struct PartialObject {
        var key: String?
        var size: Int?
        var lastModified: Date?
        var etag: String?
    }

    static func decode(data: Data) throws -> R2ListResult {
        let parser = XMLParser(data: data)
        let delegate = ListBucketResultParser()
        parser.delegate = delegate

        guard parser.parse() else {
            throw R2ClientError.unexpectedResponse
        }

        return R2ListResult(
            objects: delegate.objects,
            nextContinuationToken: delegate.nextContinuationToken,
            isTruncated: delegate.isTruncated
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""

        if elementName == "Contents" {
            currentObject = PartialObject()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "Key":
            currentObject?.key = trimmed
        case "Size":
            currentObject?.size = Int(trimmed)
        case "LastModified":
            currentObject?.lastModified = ListBucketResultParser.isoFormatter.date(from: trimmed) ??
                ISO8601DateFormatter().date(from: trimmed)
        case "ETag":
            currentObject?.etag = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        case "Contents":
            if let partial = currentObject,
               let key = partial.key,
               let size = partial.size {
                let object = R2Object(
                    key: key,
                    size: size,
                    lastModified: partial.lastModified,
                    etag: partial.etag
                )
                objects.append(object)
            }
            currentObject = nil
        case "NextContinuationToken":
            nextContinuationToken = trimmed.isEmpty ? nil : trimmed
        case "IsTruncated":
            isTruncated = (trimmed.lowercased() == "true")
        default:
            break
        }

        currentElement = nil
        currentText = ""
    }
}

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension TimeZone {
    static var gmt: TimeZone {
        TimeZone(secondsFromGMT: 0)!
    }
}
