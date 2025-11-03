import Foundation
import SotoS3
import AsyncHTTPClient  // 添加这行


/// Errors emitted by ``R2Client``.
public enum R2ClientError: LocalizedError {
    case invalidEndpoint(String)
    case fileTooLarge(maxSizeMB: Int)
    case emptyResponseBody

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let rawValue):
            return "Invalid R2 endpoint: \(rawValue)"
        case .fileTooLarge(let maximum):
            return "The payload exceeds \(maximum) MB."
        case .emptyResponseBody:
            return "The object body was empty."
        }
    }
}

/// Small convenience wrapper around Soto's S3 client for Cloudflare R2.
public final class R2Client {
    private let client: AWSClient
    private let s3: S3
    private let ownsClient: Bool

    public let bucketName: String

    /// Creates a client using the canonical Cloudflare endpoint format (`https://<account>.r2.cloudflarestorage.com`).
    public convenience init(
        bucketName: String,
        accountId: String,
        accessKeyId: String,
        secretAccessKey: String,
        sessionToken: String? = nil,
        client: AWSClient? = nil
    ) throws {
        let endpointString = "https://\(accountId).r2.cloudflarestorage.com"
        guard let endpoint = URL(string: endpointString) else {
            throw R2ClientError.invalidEndpoint(endpointString)
        }

        self.init(
            bucketName: bucketName,
            endpoint: endpoint,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            client: client
        )
    }

    /// Designated initializer with an explicit endpoint URL.
    public init(
        bucketName: String,
        endpoint: URL,
        accessKeyId: String,
        secretAccessKey: String,
        sessionToken: String? = nil,
        client: AWSClient? = nil
    ) {
        self.bucketName = bucketName

        if let client {
            self.client = client
            self.ownsClient = false
        } else {
            let credentialProvider: CredentialProviderFactory
            if let sessionToken {
                credentialProvider = .static(
                    accessKeyId: accessKeyId,
                    secretAccessKey: secretAccessKey,
                    sessionToken: sessionToken
                )
            } else {
                credentialProvider = .static(
                    accessKeyId: accessKeyId,
                    secretAccessKey: secretAccessKey
                )
            }

            self.client = AWSClient(credentialProvider: credentialProvider)
            self.ownsClient = true
        }

        self.s3 = S3(
            client: self.client,
            endpoint: endpoint.absoluteString
        )
    }

    deinit {
        if ownsClient {
            try? client.syncShutdown()
        }
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

        
        let payload = ByteBuffer(data: data)
        let request = S3.PutObjectRequest(
            body: .init(buffer: payload),
            bucket: bucketName,
            cacheControl: cacheControl,
            contentType: contentType,
            key: key,
            metadata: metadata
        )

        _ = try await s3.putObject(request)
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
        
        let getRequest = S3.GetObjectRequest(
            bucket: bucketName,
            key: key
        )
        let response = try await s3.getObject(getRequest)
        
        // 从 response.body 中读取数据
        var data = Data()
            for try await buffer in response.body {
                data.append(contentsOf: buffer.readableBytesView)
            }
        
        
        guard !data.isEmpty else {
            throw NSError(domain: "R2Manager", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载数据为空"])
        }
        
        return data
        
    }

    /// Removes an object from the bucket.
    public func delete(key: String) async throws {
        let request = S3.DeleteObjectRequest(
            bucket: bucketName,
            key: key
        )

        _ = try await s3.deleteObject(request)
    }

    /// Shuts down the internally managed `AWSClient`. Safe to call multiple times.
    public func syncShutdown() throws {
        if ownsClient {
            try client.syncShutdown()
        }
    }
}
