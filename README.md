# 3e 学习助手 · 原生 iOS 版

SwiftUI 原生实现，**iPhone 和 iPad 通用**。日程主线（查看 / 新建 / 修改 / 删除 / 重复规则 /
课程表 / 分享 / 冲突检测）已经完整，团队、收件箱、背词、天气这些独立模块也接上了。

> ⚠️ **最重要的一句话：这个 App 到今天为止，从没在任何设备或模拟器上启动过一次。**
> 代码是在 Windows 上写的，只在 GitHub 的 macOS 机器上编过。
> 编译通过、契约对过，都只能说明「它应该能跑」，不等于「它真的能跑」。
> 想验一次，看 [`docs/运行验证.md`](docs/运行验证.md)。
>
> **好消息：你不需要 Mac 也能编。** 下面这套流程用 GitHub 的免费 macOS 机器编译，
> 全程在浏览器里点几下就行（公开仓库免费不限量，私有仓库每月 2000 分钟）。

---

## ✅ 云端编译已验证通过

最近一次成功编译（run `40809920133`，head `8c5c0fb`，2026-10-29）：

| 项目 | 结果 |
|---|---|
| 仓库 | https://github.com/JDQ-tim/threee-assistant-ios |
| 编译机器 | macOS 14 + Xcode 15.4 |
| SDK | iPhoneSimulator 17.5 |
| 结果 | **`** BUILD SUCCEEDED **`** |
| 代码量 | 47 个 Swift 文件 / 约 16200 行 |
| 编译记录 | 116 条（确实是全量编译，不是复用产物） |
| 错误 / 警告 | 0 / 0 |
| 产物 | `ThreeeAssistant.app`（6.03 MB，x86_64 13.5 MB + arm64 13.2 MB） |
| 响应契约 | 19 个接口 / 199 个字段，逐字段对过真实响应，**0 处不兼容** |
| 请求契约 | 15 组「客户端发的键 vs 服务端读的键」，**全部对齐** |
| 提醒排程 | 真实快照 + 合成数据 **19 条断言**（截断、去重、已完成待办、稳定性） |
| 写操作实测 | 37 个 POST/PUT/DELETE 打真服务端，**37/37 通过** |

> ⚠️ **「编译通过」不等于「能用」。** 这一点踩过两次：
>
> 1. `ScheduleInstance.allDay` 的 CodingKeys 漏了 `= "all_day"`，
>    服务端发 `all_day`、客户端找 `allDay` → `keyNotFound` →
>    **整个 `SyncSnapshotResponse` 解析失败**，登录后一片空白。
> 2. `HealthDTO.modules` 把服务端的对象声明成 `String?` →
>    `typeMismatch` → 登录页「测试连接」明明服务器活着却报错。
>
> 两处都是**编译 100% 通过**、静态检查也过，只有真连服务端才炸。
> 现在 CI 里加了「契约回归」步骤：拿真实响应喂给 DTO 逐个解码，
> 并且带**自检**（故意改坏一份 fixture，要求检查器必须报错）——
> 避免出现「一直绿但什么都没检查」的假通过。
>
> 剩下的唯一盲区：**App 从没在任何设备上启动过**。
> 怎么在 Mac 上跑起来、卡在哪一步算什么问题，见
> [`docs/运行验证.md`](docs/运行验证.md)。

> 第一次失败的原因值得记下来：`project.pbxproj` 里「ThreeeAssistant」父组
> 和「App」子组共用了同一个对象 ID。Xcode 遇到重复 ID **不会报错**，
> 只会让路径解析错乱，表现为 `Assets.xcassets: No such file or directory`。
> 这类问题极难排查，`tools/check_pbxproj.py` 现在会主动检测重复 ID。

---

## 路线 A：用 GitHub 云端编译（推荐，不需要 Mac）

### 一次性准备（约 5 分钟）

1. **注册 GitHub 账号** → https://github.com/signup
2. **新建一个空仓库** → https://github.com/new
   - 名字随意，例如 `threee-assistant-ios`
   - ⚠️ **不要**勾选 Add a README / .gitignore / license（要空仓库）
   - 想省额度就选 **Public**（公开仓库的 Actions 分钟数完全免费）
3. **生成访问令牌（Token）** → https://github.com/settings/tokens
   - 点 `Generate new token` → `Generate new token (classic)`
   - Note 随便填，Expiration 选 30 days
   - 勾选 **`repo`** 这一项权限就行
   - 生成后**立刻复制**（页面关掉就看不到了）

### 推送代码（一条命令）

在 `ios-native` 目录下打开 Git Bash：

```bash
bash tools/push_to_github.sh 你的GitHub用户名 threee-assistant-ios
```

中途会问：
- `Username` → 填你的 GitHub 用户名
- `Password` → 粘贴刚才那个 Token（**不是** GitHub 登录密码）

看到 `✅ 推送完成` 就成功了。

### 跑编译

1. 打开 `https://github.com/你的用户名/threee-assistant-ios/actions`
2. 首次会有一条提示，点绿色按钮 **`I understand my workflows, go ahead and enable them`**
3. 左侧点 **`iOS Build`** → 右侧 **`Run workflow`** → 绿色按钮
4. 等 **3~6 分钟**，点进这次运行

### 看结果

页面最下方有 **`Summary`**，会用中文告诉你：
- ✅ 编译通过 → 同时可以下载编译好的 `.app`（模拟器版）
- ❌ 编译失败 → 直接列出 `文件:行:列: 错误信息`

**把 Summary 那一整段复制发给我**，我照着改。

---

## 路线 B：本机 Mac 编译（有 Mac 时）

需要：**Mac** + **Xcode 15 或更新**（工程已降到 Xcode 14+ 兼容格式）。

1. 双击 `ThreeeAssistant.xcodeproj`
2. 左侧选中工程 → `TARGETS: ThreeeAssistant` → **Signing & Capabilities**
   - 勾上 `Automatically manage signing`
   - `Team` 选你自己的账号
   - 没有开发者账号也能选 **Personal Team**，能装到自己设备上（7 天过期，重装即可）
   - 如果 Bundle ID 冲突，把 `cn.threees.assistant.ios` 改成 `cn.你的名字.assistant`
3. 顶部选模拟器（比如 iPad Pro 13-inch）或插上的真机 → 点 ▶️
4. 打开 App → 填服务器地址（例：`https://192.168.1.10:8443`）、用户名、密码

### 连不上服务器

自签证书是这里最容易卡住的地方，App 里也会显示排查步骤：

1. 先在 **Safari** 打开 `服务器地址/api/health`
   - 看到 JSON → 网络和证书都通
   - 提示「此连接非私人连接」→ 「显示详细信息 → 访问此网站」，再回 App
2. 端口默认 **8443**，不是 80/443
3. `Info.plist` 里已开 `NSAllowsArbitraryLoads`（为了局域网 http 也能连），
   首次连局域网设备时系统会弹「本地网络」权限，必须允许

---

## 做了什么

### 日程主线

| 功能 | 状态 |
|---|---|
| 登录 / 注册（真实 `/api/auth/login`、`/api/auth/register`） | ✅ |
| Token 存钥匙串（不是 UserDefaults） | ✅ |
| 周视图、前后翻周、回到今天 / 月视图 | ✅ |
| 按天分组、全天置顶、按时间排序 | ✅ |
| 全天 / 待办 / 已改期 标记 | ✅ |
| 日历颜色（读服务端 `calendar.color`） | ✅ |
| 详情页 / 新建 / 修改 / 删除 | ✅ |
| 重复规则（新建与编辑共用一个规则编辑器） | ✅ |
| 改单次 vs 改全部（`occurrence_key`） | ✅ |
| 课程表网格 + 课程节次编辑 | ✅ |
| 日程分享 / 举报 | ✅ |
| 冲突检测 | ✅ |
| **到点提醒（本地通知，不是只存不响）** | ✅ |
| 下拉刷新 / 深色模式 / iPad 两栏 | ✅ |

> **关于提醒**：2026-10-29 之前这块是**假的** —— 界面能设「提前 15 分钟」，
> 数据也发到了服务端，但 App 从来没有注册过 `UserNotifications`，
> 设备上永远不会响。现在补上了：
>
> - 登录后按「未来 30 天 / 最多 60 条」排进系统（iOS 硬上限是 64 条）
> - 新建、改时间、改提醒、删日程、勾完待办都会立刻重排（幂等对账，不是追加）
> - 换账号、登出、清空数据会把已排的通知全部撤掉
> - **前台也会弹**（iOS 默认会吞掉前台通知，靠 `NotificationPresenter` 兜住）
> - 设置页显示「通知权限 / 已排 N 条」；没权限时新建页会当场警告
> - 提醒配置缓存在本地（`/api/instances` 不带 `reminders`，只能从快照/详情取）

### 独立模块

| 模块 | 状态 |
|---|---|
| 收件箱（邀请处理） | ✅ |
| 团队 / 成员 / 共享 | ✅ |
| 日历管理 / 邀请 / 站点邀请 | ✅ |
| 背词同步（独立端口 8446） | ✅ |
| 天气位置 | ✅ |
| 改密码 / 分级信息 / 同步状态 | ✅ |
| 数据完整性检查 / 清空数据 | ✅ |
| 笔记 / AI / 小组件 | ❌ 未做 |

---

## 和安卓端的对应关系

| 安卓 | 这里 | 说明 |
|---|---|---|
| `ui/Theme.kt` | `Design/Theme.swift` | 同一套色值，深色也是 |
| `net/ApiClient.kt` | `Core/APIClient.swift` | `HttpURLConnection` → `URLSession` |
| `net/Models.kt` | `Core/Models.swift` | 字段名逐字对齐 |
| `ui/AppVm.kt` | `Core/SessionStore.swift` | `@Observable` 统一状态 |
| 运行时加载的插件 APK | 编译期模块 | **iOS 不允许动态加载代码**，这条路不存在 |

### 三个必须知道的差异

**1. 插件化没了。** 安卓那 20 个插件是独立 APK，运行时 `DexClassLoader` 加载。
iOS 禁止动态加载可执行代码，所有功能只能**编译进主包**。这不是偷懒，
是平台规则，也意味着 iOS 版天生比安卓版体积大、且「按需装功能」这个卖点不存在。

**2. 自签证书换了思路。** 安卓往包里塞 `app_ca.crt` 当信任锚；iOS 走
**TOFU（首次信任）**——第一次连某台服务器记下证书指纹，以后比对，对不上就断开。
实现见 `Core/TrustStore.swift` 和 `APIClient` 的 `urlSession(_:didReceive:)`。
换过服务器证书后连不上，去「设置 → 安全 → 忘记已信任的服务器证书」。

**3. 时间是 epoch 秒。** 服务端 `saneStartUTC` 会对明显离谱的时间直接 400。
Swift 的 `Date.timeIntervalSince1970` 本身就是秒，但**别再乘 1000**——
这是最容易犯、又最难从报错里看出来的一个错。

---

## 目录

```
ios-native/
├── .github/workflows/ios-build.yml  GitHub 云端编译 + 契约回归 + 负向自检
├── Tests/
│   ├── DecodeCheck/main.swift      swiftc 编的命令行程序，逐份 fixture 解码
│   ├── ReminderCheck/main.swift    提醒排程的纯逻辑校验（19 条断言）
│   ├── fixtures/*.json             19 份从真服务端抓下来的响应
│   └── server-request-keys.json    服务端 115 个结构体字段快照
├── tools/
│   ├── push_via_api.py             走 api.github.com 推送（git 协议在本机不通）
│   ├── probe_api.py                打真服务端抓响应 → fixtures
│   ├── probe_writes.py             37 个写操作实测
│   ├── seed_data.py                灌复杂数据（重复 / 全天 / 待办 / 邀请）
│   ├── check_dto_contract.py       声明类型 vs 真实 JSON（响应方向）
│   ├── check_request_contract.py   发的键 vs 服务端读的键（请求方向）
│   ├── check_route_coverage.py     服务端路由 vs 已接线接口
│   ├── gen_pbxproj.py              生成 Xcode 工程文件
│   ├── check_pbxproj.py            工程文件静态校验
│   └── check_swift.py              本地机械性错误粗检
├── ThreeeAssistant.xcodeproj/      Xcode 工程（Xcode 14+ 全兼容，显式文件引用）
├── Config/Info.plist               Bundle 信息 + ATS 例外 + 本地网络权限说明
└── ThreeeAssistant/
    ├── App/ThreeeAssistantApp.swift    @main + 登录态切换
    ├── Core/
    │   ├── Models.swift               服务端 JSON 模型（日程 / 团队 / 收件箱…）
    │   ├── SyncModels.swift           同步快照模型
    │   ├── APIClient.swift            网络层 + 自签证书校验
    │   ├── SessionStore.swift         全局状态（@Observable）
    │   ├── RepeatRule.swift           重复规则 ↔ RRULE
    │   ├── ReminderPlan.swift         提醒排程的纯函数（可离线验证）
    │   ├── ReminderRules.swift        提醒配置本地缓存（落盘）
    │   ├── ReminderScheduler.swift    排进系统通知 + 幂等对账
    │   ├── TrustStore.swift           证书指纹记忆（TOFU）
    │   ├── Keychain.swift             令牌存取
    │   ├── DateHelp.swift             时间显示 / 拼接
    │   └── APIError.swift             错误 → 人话
    ├── Design/                        Theme / Components
    └── Features/
        ├── Login/                     登录、注册
        ├── Schedule/                  周视图、月视图、课程表、详情、新建/编辑、
        │                              重复规则编辑器、分享、举报
        └── Settings/                  日历、邀请、成员、共享、团队、收件箱、
                                       背词、天气、冲突、改密码、分级、同步状态、
                                       数据完整性、清空数据、站点邀请
```

工程用的是最保守的**显式文件引用**写法的 `project.pbxproj`（`objectVersion = 56`），
Xcode 14 / 15 / 16 都能打开，云端的 macOS runner 也一定能识别。

> 代价：新增 `.swift` 文件后要重新跑 `python tools/gen_pbxproj.py` 再提交，
> 不能像 Xcode 16 的「文件系统同步组」那样自动收进来。稳定性优先。

修改工程结构后可以跑一遍校验：

```bash
python tools/check_pbxproj.py
```

它会检查括号配平、ID 引用是否一一对应、每个 Swift 文件有没有真的进编译阶段。

### 如果工程打不开（兜底办法）

万一 `.xcodeproj` 因为版本差异打不开：

1. Xcode 里 `File → New → Project → iOS → App`
2. Product Name 填 `ThreeeAssistant`，Interface 选 **SwiftUI**，语言 Swift
3. 删掉它自动生成的 `ContentView.swift` 和 `ThreeeAssistantApp.swift`
4. 把本仓库 `ThreeeAssistant/` 里的所有文件夹拖进工程（勾 Copy items if needed）
5. `Info.plist` 用 `Config/Info.plist` 覆盖掉默认的
6. Bundle ID 改成自己的

---

## 还没做的事

按「不做会不会出事」排的，不是按工作量排的。

### 1. 从没真机跑过（最高优先级）

编译通过、契约对过、37 个写操作实测过，**但一次都没启动过**。
上面这些结论只覆盖「数据对不对」，完全没覆盖：

- 布局在真实机型上是不是错位（尤其是课程表网格、iPad 两栏）
- 手势、键盘弹出、Sheet 高度这些只有真跑才知道的事
- 首次启动的证书信任流程能不能走通

步骤见 [`docs/运行验证.md`](docs/运行验证.md)。

### 2. 没有测试目标

工程里只有 App 一个 target，**没有任何 XCTest / Swift Testing 目标**。
现有保障全在 CI 脚本和 `Tests/` 下的命令行检查程序里：

| 检查 | 覆盖 | 位置 |
|---|---|---|
| 契约回归 | 19 个真实响应逐份解码 + 负向自检 | `Tests/DecodeCheck` |
| 请求契约 | 15 组「发的键 vs 读的键」 | `tools/check_request_contract.py` |
| 提醒排程 | 19 条断言（截断/去重/已完成待办/顺序稳定） | `Tests/ReminderCheck` |

但还有业务逻辑没有覆盖：**重复规则展开、冲突检测、日期分组**。
这几块目前只能靠手验。

### 3. 无障碍基本没做

| 项 | 现状 |
|---|---|
| `accessibilityLabel` 等 | 全工程 **2 处** |
| 动态字体适配 | 0 处 `dynamicTypeSize` |
| 硬编码字号 `.system(size:)` | **132 处**（WeatherView 一个文件就 24 处） |

后果：系统字号调到最大时，部分文字不会跟着放大；VoiceOver 读出来基本是控件类型而不是内容。
自用够、给人用不够。真要改，最省力的是把那 132 处硬编码字号换成 `Theme` 里定义的语义化 font。

### 4. 没有离线能力

全工程 **0 处** `URLCache` / `cachePolicy` / 本地文件缓存。
断网打开 App = 空白 + 一条错误提示，看不到任何已经同步过的日程。
20 处 `UserDefaults` 存的都是设置项（服务器地址、当前视图之类），不是数据。

对一个「自建服务器、可能只在局域网」的 App 来说，这个缺口比界面缺功能更影响体验。

### 5. 接口覆盖 31%

服务端 182 个路由，客户端已接线 56 个。剩下的 126 个里一多半**本来就不该在手机上做**
（管理后台 63、第三方扩展 12、实时协作 10、内部 6、调试 6、部署 4）。
真正想做还能做的约 15~22 个：插件市场 6、主题皮肤 2、导航 2、API Key 2，
以及自更新 5（iOS 走 App Store，可跳过）。

### 6. 三块功能整块没做

笔记、AI、小组件。

---

## 已知的小幌子

`tools/check_swift.py` 末尾那两条「[提示]」是误报，不用管：

- `Components.swift:15` 用了 `if let x {` 简写 —— 这是**编译器**特性（Swift 5.7+），
  跟 `SWIFT_VERSION` 填几无关。工程已改 `SWIFT_VERSION = 5.9`。
- `CoursePeriodsEditorView` 的 `.label` / `.start` —— 那两个字段本来就是 `var`，
  检查器只是按名字硬猜「可能是 let」。
