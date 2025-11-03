# R2ClientKit

`R2ClientKit` 是一个基于 Swift Package Manager 的轻量级客户端封装，针对 iOS 与 Mac Catalyst 共用的 Cloudflare R2 访问需求而设计。它在 Soto AWS SDK 基础上提供最小化的上传、下载、删除接口，便于将同一套代码运行在 iPhone、iPad 以及 Mac App Store 的 Catalyst 应用中。

## 主要特性

- 异步 `R2Client`，覆盖上传、下载、删除三大常用操作。
- 默认内置 `<account>.r2.cloudflarestorage.com` Endpoint 构建，亦可传入自定义 URL。
- 可选的单次上传体积限制与文件 URL 上传辅助方法。
- 支持复用现有 `AWSClient`，也支持内部自管理生命周期。
- 针对 Cloudflare R2 做了简化配置，适合 iOS / Mac Catalyst 共用代码。

## 系统与依赖要求

- Swift 5.9+
- iOS 13 / Mac Catalyst 13 及以上
- 依赖 `SotoS3`（Swift Package Manager 自动处理）

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

let client = try R2Client(
    bucketName: "example-bucket",
    accountId: "<#CloudflareAccountID#>",
    accessKeyId: "<#AccessKey#>",
    secretAccessKey: "<#SecretKey#>"
)

// 上传
try await client.upload(
    data: Data("Hello Catalyst!".utf8),
    to: "demo/hello.txt",
    contentType: "text/plain",
    maxSizeInMB: 30
)

// 下载
let payload = try await client.download(key: "demo/hello.txt")

// 删除
try await client.delete(key: "demo/hello.txt")

// 若由自身托管生命周期，可在退出前回收底层连接资源
try client.syncShutdown()
```

## 配置项说明

构造参数说明：

- `bucketName`：目标 R2 存储桶名称。
- `accountId` / `endpoint`：二选一。可直接传入 Cloudflare 账号 ID 或自定义完整 Endpoint。
- `accessKeyId` / `secretAccessKey` / `sessionToken`：R2 访问凭证。
- `client`：可注入已有的 `AWSClient`，用于重用事件循环或统一代理设置。

如果不提供 `client`，`R2Client` 会在内部创建并在 `deinit` 时自动释放。

## 错误处理

`R2ClientError` 包含以下错误类型：

- `invalidEndpoint`：配置阶段构造 Endpoint 失败。
- `fileTooLarge`：上传数据超出指定上限。
- `emptyResponseBody`：调用 `download(key:allowEmpty: false)` 时返回了空数据。

除此之外，其他错误会原样透传 Soto 或底层 HTTP 客户端的异常，方便调用方断言和重试。

## 相关资源

- [Soto Project 文档](https://soto.codes/)：了解 Soto 生态及各模块的更多能力。
- [Cloudflare R2 官方文档](https://developers.cloudflare.com/r2/)：获取凭证、配置自定义域名及权限策略。
