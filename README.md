# 3e 学习助手 · 原生 iOS 版

SwiftUI 原生实现，**iPhone 和 iPad 通用**。第一版只做日程这条主线（查看 / 新建 / 删除），
目的是先把「能不能连上你自己的服务器、界面手感对不对」验证掉，再往上铺功能。

> ⚠️ **重要前提**：这份代码是在 Windows 上写的，**没有经过 Xcode 编译**。
> 第一次编译可能有一批报错（多半是拼写、可选值解包、API 签名这类），
> 把报错整段发我，我改完你再重新跑一次。这不是「大概能用」，是「还没被验证过」——
> 说清楚比让你白折腾好。
>
> **好消息：你不需要 Mac。** 下面这套流程用 GitHub 的免费 macOS 机器编译，
> 全程在浏览器里点几下就行（有额度限制：公开仓库免费不限量，私有仓库每月 2000 分钟）。

---

## ✅ 云端编译已验证通过

2026-10-23 首次真实编译结果：

| 项目 | 结果 |
|---|---|
| 仓库 | https://github.com/JDQ-tim/threee-assistant-ios |
| 编译机器 | macOS 15 + Xcode 16.4 |
| SDK | iPhoneSimulator 18.5 |
| 结果 | **`** BUILD SUCCEEDED **`** |
| 错误 | 0 |
| 警告 | 0 |
| 产物 | `ThreeeAssistant.app`（0.9 MB，Mach-O Universal） |

也就是说 **1822 行 Swift 代码一行未改就编译通过了**，不需要"先修一堆错"。

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

| 功能 | 状态 |
|---|---|
| 登录（真实 `/api/auth/login`） | ✅ |
| Token 存钥匙串（不是 UserDefaults） | ✅ |
| 周视图、前后翻周、回到今天 | ✅ |
| 按天分组、全天置顶、按时间排序 | ✅ |
| 全天 / 待办 / 已改期 标记 | ✅ |
| 日历颜色（读服务端 `calendar.color`） | ✅ |
| 详情页 | ✅ |
| 新建日程（真实 `POST /api/events`） | ✅ |
| 删除日程（真实 `DELETE /api/events/{id}`） | ✅ |
| 下拉刷新 | ✅ |
| 深色模式 | ✅ 跟随系统 |
| iPad 两栏 | ✅ 前半周左栏、后半周右栏 |
| 修改日程 | ❌ 未做 |
| 重复日程编辑（改单次 / 改全部） | ❌ 未做 |
| 团队 / 收件箱 / 笔记 / AI / 小组件 | ❌ 未做 |

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
├── .github/workflows/ios-build.yml  GitHub 云端编译配置（不需要改）
├── tools/
│   ├── push_to_github.sh            一键推送脚本
│   ├── gen_pbxproj.py               生成 Xcode 工程文件
│   └── check_pbxproj.py             工程文件静态校验
├── ThreeeAssistant.xcodeproj/      Xcode 工程（Xcode 14+ 全兼容，显式文件引用）
├── Config/Info.plist               Bundle 信息 + ATS 例外 + 本地网络权限说明
└── ThreeeAssistant/
    ├── App/ThreeeAssistantApp.swift    @main + 登录态切换
    ├── Core/
    │   ├── Models.swift               服务端 JSON 模型
    │   ├── APIClient.swift            网络层 + 自签证书校验
    │   ├── SessionStore.swift         全局状态（@Observable）
    │   ├── TrustStore.swift           证书指纹记忆
    │   ├── Keychain.swift             令牌存取
    │   ├── DateHelp.swift             时间显示 / 拼接
    │   └── APIError.swift             错误 → 人话
    ├── Design/
    │   ├── Theme.swift                配色
    │   └── Components.swift           日程条目 / 标签 / 空状态
    └── Features/
        ├── Login/LoginView.swift
        ├── Schedule/ScheduleView.swift
        ├── Schedule/EventDetailSheet.swift
        ├── Schedule/NewEventSheet.swift
        └── Settings/SettingsView.swift
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

## 下一步建议

按「一次只验证一件事」的顺序：

1. **先让它编译通过、能登录** —— 这一步过了，架构就是对的
2. 补「修改日程」（`PUT /api/events/{id}`，服务端是局部合并，只传改的字段）
3. 补「重复日程」—— 这块最难：服务端用 `occurrence_key` 区分单次，
   改单次走 `PUT /api/events/{id}/occurrence`，别自己算
4. 最后才是团队 / 收件箱 / 笔记那些独立模块
