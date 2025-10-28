# R2ClientKit

`R2ClientKit` is a lightweight Swift Package that wraps the Soto AWS SDK to make it easier to work with Cloudflare R2 buckets from iOS, macOS, or tvOS targets as old as iOS 13. The package extracts R2 specific logic from the StoryReaderKit project, encapsulating it in a reusable client.

## Features

- Async `SRR2Client` for downloading, uploading, and deleting objects.
- Rich configuration options, including custom endpoints, credential providers, retry behaviour, and request metadata.
- Uses Soto 7.x APIs for concurrency-friendly streaming and upload handling.

## Usage

Add the package dependency to your `Package.swift`:

```swift
.package(url: "https://github.com/chenlidongorg/R2ClientKit.git", branch: "main")
```

Then configure and use `SRR2Client`:

```swift
import R2ClientKit

let configuration = SRR2Client.Configuration(
    bucketName: "your-bucket",
    endpoint: URL(string: "https://your-endpoint.r2.cloudflarestorage.com")!,
    accessKeyId: "<#AccessKey#>",
    secretAccessKey: "<#SecretKey#>"
)

let client = SRR2Client(configuration: configuration)
let data = try await client.downloadFile(key: "path/to/object.txt")
```

See `SRR2Client.Configuration` for further customization options such as retry policies, custom `AWSHTTPClient` instances, or KMS settings.
