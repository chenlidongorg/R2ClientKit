import Foundation
import SotoS3


/// Errors that can be thrown by `R2Client`.
public enum R2ClientError: LocalizedError {
    case missingResponseBody
    case emptyResponseBody
    case uploadFileExceedsMaximumSize(maximumMB: Int)

    public var errorDescription: String? {
        switch self {
        case .missingResponseBody:
            return "The S3 response did not contain a body."
        case .emptyResponseBody:
            return "The S3 response body was empty."
        case .uploadFileExceedsMaximumSize(let maximumMB):
            return "The file exceeds the maximum allowed size of \(maximumMB) MB."
        }
    }
}

public final class R2Client {
    /// Configuration options for `R2Client`.
    public struct Configuration {
        public var bucketName: String
        public var endpoint: URL
        public var region: SotoCore.Region?
        public var partition: AWSPartition
        public var credentialProvider: CredentialProviderFactory
        public var retryPolicy: RetryPolicyFactory
        public var clientOptions: AWSClient.Options
        public var serviceOptions: AWSServiceConfig.Options
        public var httpClient: (any AWSHTTPClient)?
        public var timeout: TimeAmount?
        public var byteBufferAllocator: ByteBufferAllocator
        public var logger: Logger

        /// Convenience initializer that accepts explicit credentials.
        public init(
            bucketName: String,
            endpoint: URL,
            accessKeyId: String,
            secretAccessKey: String,
            sessionToken: String? = nil,
            region: SotoCore.Region? = nil,
            partition: AWSPartition = .aws,
            timeout: TimeAmount? = nil,
            byteBufferAllocator: ByteBufferAllocator = .init(),
            logger: Logger = AWSClient.loggingDisabled,
            retryPolicy: RetryPolicyFactory = .default,
            clientOptions: AWSClient.Options = .init(),
            serviceOptions: AWSServiceConfig.Options = [],
            httpClient: (any AWSHTTPClient)? = nil
        ) {
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

            self.init(
                bucketName: bucketName,
                endpoint: endpoint,
                credentialProvider: credentialProvider,
                region: region,
                partition: partition,
                timeout: timeout,
                byteBufferAllocator: byteBufferAllocator,
                logger: logger,
                retryPolicy: retryPolicy,
                clientOptions: clientOptions,
                serviceOptions: serviceOptions,
                httpClient: httpClient
            )
        }

        /// Designated initializer giving full control over the credential provider and runtime options.
        public init(
            bucketName: String,
            endpoint: URL,
            credentialProvider: CredentialProviderFactory,
            region: SotoCore.Region? = nil,
            partition: AWSPartition = .aws,
            timeout: TimeAmount? = nil,
            byteBufferAllocator: ByteBufferAllocator = .init(),
            logger: Logger = AWSClient.loggingDisabled,
            retryPolicy: RetryPolicyFactory = .default,
            clientOptions: AWSClient.Options = .init(),
            serviceOptions: AWSServiceConfig.Options = [],
            httpClient: (any AWSHTTPClient)? = nil
        ) {
            self.bucketName = bucketName
            self.endpoint = endpoint
            self.region = region
            self.partition = partition
            self.credentialProvider = credentialProvider
            self.retryPolicy = retryPolicy
            self.clientOptions = clientOptions
            self.serviceOptions = serviceOptions
            self.httpClient = httpClient
            self.timeout = timeout
            self.byteBufferAllocator = byteBufferAllocator
            self.logger = logger
        }
    }

    /// Simple retry configuration for idempotent operations.
    public struct RetryConfiguration {
        public var maxRetries: Int

        public init(maxRetries: Int = 2) {
            self.maxRetries = max(0, maxRetries)
        }

        /// Retry disabled.
        public static var none: RetryConfiguration { RetryConfiguration(maxRetries: 0) }
    }

    private enum ClientOwnership {
        case owned
        case shared
    }

    private let client: AWSClient
    private let s3: S3
    private let ownership: ClientOwnership

    public let configuration: Configuration

    /// Creates a new `R2Client` using the provided configuration. A new `AWSClient` will be created and managed
    /// by the instance.
    public convenience init(configuration: Configuration) {
        self.init(configuration: configuration, client: nil)
    }

    /// Creates a new `R2Client` with an externally managed `AWSClient`.
    /// - Parameters:
    ///   - configuration: Runtime configuration.
    ///   - client: An existing `AWSClient`. When provided, the caller is responsible for shutting it down.
    public init(configuration: Configuration, client: AWSClient?) {
        self.configuration = configuration

        if let client {
            self.client = client
            self.ownership = .shared
        } else if let httpClient = configuration.httpClient {
            self.client = AWSClient(
                credentialProvider: configuration.credentialProvider,
                retryPolicy: configuration.retryPolicy,
                options: configuration.clientOptions,
                httpClient: httpClient,
                logger: configuration.logger
            )
            self.ownership = .owned
        } else {
            self.client = AWSClient(
                credentialProvider: configuration.credentialProvider,
                retryPolicy: configuration.retryPolicy,
                options: configuration.clientOptions,
                logger: configuration.logger
            )
            self.ownership = .owned
        }

        self.s3 = S3(
            client: self.client,
            region: configuration.region,
            partition: configuration.partition,
            endpoint: configuration.endpoint.absoluteString,
            timeout: configuration.timeout,
            byteBufferAllocator: configuration.byteBufferAllocator,
            options: configuration.serviceOptions
        )
    }

    deinit {
        if ownership == .owned {
            try? client.syncShutdown()
        }
    }

    /// Downloads an object and returns it as `Data`.
    ///
    /// - Parameters:
    ///   - key: Object key.
    ///   - versionId: Specific object version.
    ///   - range: An optional byte range (inclusive).
    ///   - expectedBucketOwner: Expected bucket owner ID.
    ///   - requestPayer: Request payer configuration.
    ///   - allowEmptyData: Whether an empty object should be considered a success.
    /// - Returns: Raw bytes of the object.
    public func downloadFile(
        key: String,
        versionId: String? = nil,
        range: ClosedRange<Int>? = nil,
        expectedBucketOwner: String? = nil,
        requestPayer: S3.RequestPayer? = nil,
        allowEmptyData: Bool = false
    ) async throws -> Data {
        let byteRange = range.map { "bytes=\($0.lowerBound)-\($0.upperBound)" }
        let request = S3.GetObjectRequest(
            bucket: configuration.bucketName,
            expectedBucketOwner: expectedBucketOwner,
            key: key,
            range: byteRange,
            requestPayer: requestPayer,
            versionId: versionId
        )

        let response = try await s3.getObject(request, logger: configuration.logger)
        let body = response.body

        var downloaded = Data()
        for try await var chunk in body {
            if let bytes = chunk.readBytes(length: chunk.readableBytes) {
                downloaded.append(contentsOf: bytes)
            } else {
                downloaded.append(contentsOf: chunk.readableBytesView)
            }
        }

        guard !downloaded.isEmpty else {
            if allowEmptyData {
                return Data()
            }
            let reportedLength = response.contentLength ?? body.length.map { Int64($0) }
            if reportedLength == 0 {
                throw R2ClientError.emptyResponseBody
            }
            throw R2ClientError.missingResponseBody
        }

        return downloaded
    }

    /// Uploads an object to the configured bucket.
    ///
    /// - Parameters:
    ///   - data: Payload to upload.
    ///   - key: Object key.
    ///   - metadata: Custom metadata.
    ///   - contentType: Optional MIME type.
    ///   - cacheControl: Cache control header.
    ///   - acl: Access control policy.
    ///   - storageClass: Storage class.
    ///   - tagging: Object tagging string.
    ///   - serverSideEncryption: Encryption mode.
    ///   - ssekmsKeyId: KMS key identifier.
    ///   - expectedBucketOwner: Expected bucket owner ID.
    ///   - requestPayer: Request payer configuration.
    ///   - retryConfiguration: Retry behaviour for transient failures.
    ///   - maxUploadSizeInMB: Optional maximum upload size in megabytes. Pass `30` to restrict uploads to 30 MB. Defaults to no limit.
    public func uploadFile(
        data: Data,
        key: String,
        metadata: [String: String]? = nil,
        contentType: String? = nil,
        cacheControl: String? = nil,
        acl: S3.ObjectCannedACL? = nil,
        storageClass: S3.StorageClass? = nil,
        tagging: String? = nil,
        serverSideEncryption: S3.ServerSideEncryption? = nil,
        ssekmsKeyId: String? = nil,
        expectedBucketOwner: String? = nil,
        requestPayer: S3.RequestPayer? = nil,
        retryConfiguration: RetryConfiguration = .init(),
        maxUploadSizeInMB: Int? = nil
    ) async throws {
        let attempts = max(1, retryConfiguration.maxRetries + 1)

        if let maxUploadSizeInMB, maxUploadSizeInMB > 0 {
            let maxAllowedBytes = Int64(maxUploadSizeInMB) * 1_048_576
            if Int64(data.count) > maxAllowedBytes {
                throw R2ClientError.uploadFileExceedsMaximumSize(maximumMB: maxUploadSizeInMB)
            }
        }

        for attempt in 0..<attempts {
            do {
                var buffer = configuration.byteBufferAllocator.buffer(capacity: data.count)
                buffer.writeBytes(data)

                let request = S3.PutObjectRequest(
                    acl: acl,
                    body: AWSHTTPBody(buffer: buffer),
                    bucket: configuration.bucketName,
                    cacheControl: cacheControl,
                    contentType: contentType,
                    expectedBucketOwner: expectedBucketOwner,
                    key: key,
                    metadata: metadata,
                    requestPayer: requestPayer,
                    serverSideEncryption: serverSideEncryption,
                    ssekmsKeyId: ssekmsKeyId,
                    storageClass: storageClass,
                    tagging: tagging
                )

                _ = try await s3.putObject(request)

                return
            } catch {
                if attempt == attempts - 1 {
                    throw error
                }
            }
        }
    }

    /// Deletes a single object.
    ///
    /// - Parameters:
    ///   - key: Object key.
    ///   - versionId: Specific version to delete.
    ///   - mfa: MFA token if bucket requires it.
    ///   - bypassGovernanceRetention: Whether to bypass governance retention.
    ///   - expectedBucketOwner: Expected bucket owner ID.
    ///   - requestPayer: Request payer configuration.
    public func deleteFile(
        key: String,
        versionId: String? = nil,
        mfa: String? = nil,
        bypassGovernanceRetention: Bool? = nil,
        expectedBucketOwner: String? = nil,
        requestPayer: S3.RequestPayer? = nil
    ) async throws {
        let request = S3.DeleteObjectRequest(
            bucket: configuration.bucketName,
            bypassGovernanceRetention: bypassGovernanceRetention,
            expectedBucketOwner: expectedBucketOwner,
            key: key,
            mfa: mfa,
            requestPayer: requestPayer,
            versionId: versionId
        )

        _ = try await s3.deleteObject(request)
    }

    /// Shutdown the underlying `AWSClient` if owned by this instance.
    public func syncShutdown() throws {
        if ownership == .owned {
            try client.syncShutdown()
        }
    }
}
