# R2ClientKit

`R2ClientKit` 是一个基于 Swift Package Manager 的轻量级客户端封装，主要面向需要在 iOS 13、macOS 11、tvOS 13 及以上系统中访问 Cloudflare R2 存储桶的应用程序。它在 Soto AWS SDK 之上提供更贴近 R2 的默认配置和易用接口，将原本分散在 StoryReaderKit 项目中的逻辑抽取为独立依赖。

## 主要特性

- 提供异步 `R2Client`，支持对象的下载、上传与删除。
- 与 Soto 7.x API 深度集成，配合 Swift Concurrency 友好的流式上传/下载。
- 支持自定义 Endpoint、凭证提供者、重试策略、Request Metadata 等配置。
- 允许复用外部管理的 `AWSClient` 或自定义 `AWSHTTPClient` 以适配更复杂的运行环境。
- 针对上传提供最大体积限制与基础的重试机制。

## 系统与依赖要求

- Swift 5.9+
- iOS 13 / macOS 11 / tvOS 13 及以上
- 依赖 `soto-core` 与 `soto`（S3 模块），详见 `Package.swift`

## 安装

在目标项目的 `Package.swift` 中添加依赖：

```swift
.package(url: "https://github.com/chenlidongorg/R2ClientKit.git", branch: "main")
```

然后在需要使用的 Target 中声明产品：

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "R2ClientKit", package: "R2ClientKit")
    ]
)
```

## 快速上手

```swift
import R2ClientKit

let configuration = R2Client.Configuration(
    bucketName: "example-bucket",
    endpoint: URL(string: "https://your-endpoint.r2.cloudflarestorage.com")!,
    accessKeyId: "<#AccessKey#>",
    secretAccessKey: "<#SecretKey#>"
)

let client = R2Client(configuration: configuration)

// 下载对象
let data = try await client.downloadFile(key: "path/to/object.txt")

// 上传对象
try await client.uploadFile(
    data: data,
    key: "path/to/copied.txt",
    contentType: "text/plain",
    maxUploadSizeInMB: 30
)

// 删除对象
try await client.deleteFile(key: "path/to/copied.txt")
```

使用完成后若自行管理生命周期，可调用 `try client.syncShutdown()` 主动回收底层 `AWSClient` 资源。

## 配置项说明

`R2Client.Configuration` 支持丰富的自定义能力，常用字段包括：

- `bucketName`：目标 R2 存储桶名称。
- `endpoint`：R2 的自定义 Endpoint，例如 `https://<account>.r2.cloudflarestorage.com`。
- `accessKeyId` / `secretAccessKey` / `sessionToken`：R2 的访问密钥，支持临时凭证。
- `region` / `partition`：覆盖默认的 AWS 区域与分区设置，连接非标准 Endpoint 时可保持为空。
- `credentialProvider`：若需接入更复杂的凭证逻辑，可使用工厂方式自定义。
- `retryPolicy`：自定义 Soto 的重试策略；上传接口额外提供简单的最大重试次数封装。
- `httpClient`：传入外部构建的 `AWSHTTPClient`，在需要统一连接池或自定义代理时很有帮助。
- `timeout`、`byteBufferAllocator`、`logger` 等：用于细致调优超时、内存与日志。

## 错误处理

`R2Client` 定义了 `R2ClientError`：

- `missingResponseBody` / `emptyResponseBody`：下载对象时未获取到有效数据。
- `uploadFileExceedsMaximumSize(maximumMB:)`：超出 `maxUploadSizeInMB` 限制。

除上述错误外，其他异常会直接透传 Soto 或底层 HTTP 客户端抛出的错误，便于调用方据此做更细粒度的判断。

## 开发与测试

仓库包含基础的测试 Target，执行以下命令即可运行：

```bash
swift test
```

欢迎根据自身业务扩展更多场景的单元测试或异步集成测试。

## 相关资源

- [Soto Project 文档](https://soto.codes/)：了解 Soto 生态及各模块的更多能力。
- [Cloudflare R2 官方文档](https://developers.cloudflare.com/r2/)：获取凭证、配置自定义域名及权限策略。
