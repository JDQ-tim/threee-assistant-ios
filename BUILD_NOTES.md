# 本次做的事

## 目标
用户想在 Windows 上搞「隔离沙箱里跑 macOS」→ 结论不可行（Apple 授权 + 缺少虚拟化支持 + Hackintosh 硬件门槛），
转向真实目的：**不需要 Mac 也能编译 ios-native 那个 Xcode 工程**。

## 方案
用 GitHub Actions 的 `macos-15` runner 云端编译。

## 关键改动
1. **重写 `project.pbxproj`**
   - 原来用 `objectVersion = 77` + `PBXFileSystemSynchronizedRootGroup`（Xcode 16 新特性），
     GitHub runner 上容易打不开 → 降级为 `objectVersion = 56` + 显式 `PBXFileReference`，
     Xcode 14/15/16 全兼容。
   - 由 `tools/gen_pbxproj.py` 生成（15 个 Swift 文件 + Assets + Info.plist，56 个对象）。
   - **顺便把 scheme 里写死的旧 target ID `3E0000...0006` 换成新生成的 ID**，
     否则 `xcodebuild -scheme` 找不到 target —— 这个坑很隐蔽。
2. **新增 `.gitattributes` 强制 `eol=lf`**
   - Windows git 默认 CRLF，`.sh` 脚本到 macOS 会报 `bad interpreter: /bin/bash^M`，
     Swift/pbxproj 也可能被 CRLF 搞坏。这条必须有。
3. **新增 `.github/workflows/ios-build.yml`**
   - 9 个 step：显示工具链 → 编译（`-sdk iphonesimulator` + `CODE_SIGNING_ALLOWED=NO`，
     没开发者账号也能验证编译）→ 提炼 `文件:行:列: error:` → 写入 `$GITHUB_STEP_SUMMARY` → 上传日志与 .app
   - 本地实测过日志解析逻辑（错误计数、路径精简、空日志、BUILD SUCCEEDED 判定）。
4. **新增 `tools/push_to_github.sh`**（不需要 gh CLI，纯 git + Token）

## 顺手修的并发问题（云端编译会报的那类）
- `TrustStore`：会被 URLSessionDelegate 后台线程和主线程同时调用 → 加 `NSLock`
- `APIClient`：`baseURL`/`token` 主线程写、后台读 → 加 `stateLock`（`@unchecked Sendable` 得名副其实）
- `SessionStore.init()` 补 `@MainActor`
- `if let body {` → `if let bodyData = body {`（工程是 `SWIFT_VERSION = 5.0`）

## 校验方式（无 Swift 编译器）
- `tools/check_pbxproj.py`：括号配平、56 个 ID 定义与引用一一对应、每个 Swift 文件都在 Sources 阶段、path 指向真实文件
- YAML 用 pyyaml 解析通过
- 本地 `git add` + `git commit` 跑通（30 个文件），`git ls-files --eol` 确认全 LF

## 未解决
真正能不能编译通过，只有云端跑一次才知道。预计有一批小报错（可选值解包、SF Symbols 名、SwiftUI API 签名），
让用户把 Actions 的 Summary 贴回来。
