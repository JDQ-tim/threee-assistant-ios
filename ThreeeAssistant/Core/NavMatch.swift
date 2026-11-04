import Foundation

// ============================================================
//  文字 → 楼栋 的匹配
//  ------------------------------------------------------------
//  这是整个导航功能的"大脑"。别的地方只负责画图和发链接，
//  真正难的是：给一段人写的文字（「明德楼B1 302」），判断它指的是哪栋楼。
//
//  移植自 `android/plugin-nav/.../NavStore.kt: matchKind()` 与
//  `PlaceSplitter.kt`。**判据逐条对齐**，不是"意思差不多" ——
//  这里每一次多猜、少猜，用户都会照着走，走错了才知道。
//
//  ## 为什么 iOS 不需要腾讯地图
//
//  安卓端是两段式：① 校内楼栋表（离线）→ ② 腾讯 WebService 检索。
//  iOS 有 MapKit，第 ② 段直接交给系统（用户点"打开地图"就是 Apple 地图）。
//  于是这里**只保留第 ① 段** —— 而这一段恰好是最可信的那一段：
//  公共地图库里没有校内楼名，却有**校外同名**的地方（"明德楼"全国都有），
//  先联网查的结果是把用户导到几十公里外。
// ============================================================

/// 怎么认出来的。三种对用户的意义不同。
enum NavMatchKind {
    /// 名字完全一样。「明德楼B1」
    case exact
    /// 楼名后面跟了房号。「明德楼B1 302」
    case room
    /// 去掉标点后对上，或者是相似度算出来的。**是猜的**，界面要提醒。
    case fuzzy

    var isGuess: Bool { self == .fuzzy }
}

struct NavMatch {
    let building: NavBuilding
    let kind: NavMatchKind
}

/// 一次拆分的结果。
struct NavSplit {
    /// 匹配到的楼。nil = 没匹配上（此时 `place` 是原文、`room` 为空）。
    let building: NavBuilding?
    /// 用于导航的终点名。匹配到楼时是**楼自己的 name**，否则是原文。
    let place: String
    /// 从地点文字里拆出来的房号（「302」/「13楼」）。**不参与导航**，
    /// 只是显示给用户看，让他确认"我认对了地方"。
    let room: String
    /// 是不是猜出来的。true 时界面要提醒。
    let fuzzy: Bool

    static func unmatched(_ text: String) -> NavSplit {
        NavSplit(building: nil, place: text, room: "", fuzzy: false)
    }
}

// MARK: - 文字归一化

enum NavText {

    /// 归一化：**全角转半角 + 去所有空白 + 小写**。
    ///
    /// 全角这一条很实际：中文输入法下打出来的是「主５」「Ａ栋」，
    /// 而标注包里存的是「主5」「A栋」—— 同一个楼，字面不同，匹配对不上。
    static func norm(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            // ⚠️ 全角空格 U+3000 也在这里被跳过 —— 安卓端那段
            //    `ch == '　' -> ' '` 其实是死代码（U+3000 本身就算空白）。
            if CharacterSet.whitespacesAndNewlines.contains(u) { continue }
            if u.value >= 0xFF01 && u.value <= 0xFF5E, let m = Unicode.Scalar(u.value - 0xFEE0) {
                out.unicodeScalars.append(m)
            } else {
                out.unicodeScalars.append(u)
            }
        }
        return out.lowercased()
    }

    /// **楼名部分**：井号（含全角）之后一律当房号，丢掉。
    ///
    /// 用户的原话：「至少要把那个井号后面的那些数字直接忽略掉」。
    /// 「主5#501」里 `#` 是个人为分隔符，它后面**不可能**是楼名的一部分。
    ///
    /// ⚠️ 只切 `#`/`＃`，不切 `-`：楼名里真的有连字符（「A-3栋」），
    ///    而 `#` 在中文地点写法里几乎只用来分房号。
    static func corePlace(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = t.firstIndex(where: { $0 == "#" || $0 == "＃" }), cut != t.startIndex {
            return String(t[t.startIndex..<cut])
        }
        return t
    }

    /// 剥掉标点符号，只留汉字、字母、数字。
    static func stripPunct(_ s: String) -> String {
        String(s.filter { $0.isLetter || $0.isNumber })
    }

    /// 归一化，**同时**保留"归一化后的每一位来自原文哪个位置"。
    ///
    /// 为什么需要这个映射：匹配要在归一化后的串上做（忽略空格和全半角），
    /// 但**切原文**必须用原文下标 —— 归一化会丢字符，两者长度不一样，
    /// 拿归一化下标去切原文会切歪。
    static func normWithMap(_ s: String) -> (hay: String, origin: [String.Index]) {
        var hay = ""
        var origin: [String.Index] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if !c.isWhitespace {
                var piece = ""
                for u in String(c).unicodeScalars {
                    if u.value >= 0xFF01 && u.value <= 0xFF5E, let m = Unicode.Scalar(u.value - 0xFEE0) {
                        piece.unicodeScalars.append(m)
                    } else {
                        piece.unicodeScalars.append(u)
                    }
                }
                for pc in piece.lowercased() {
                    hay.append(pc)
                    origin.append(i)
                }
            }
            i = s.index(after: i)
        }
        return (hay, origin)
    }
}

// MARK: - 匹配

enum NavMatcher {

    /// 给一段地点文字找楼。
    ///
    /// 四档，**顺序不能反**（越靠前越可信）：
    /// ① 全等 → ② 楼名 + 房号 → ③ 去标点后包含 → ④ 相似度
    static func match(_ text: String, in buildings: [NavBuilding]) -> NavMatch? {
        // 井号之后是房号，不参与楼名匹配
        let q = NavText.norm(NavText.corePlace(text))
        guard !q.isEmpty, !buildings.isEmpty else { return nil }

        // ① 全等（两边都切过井号）
        if let b = buildings.first(where: { b in
            b.keys.contains { NavText.corePlace(NavText.norm($0)) == q }
        }) {
            return NavMatch(building: b, kind: .exact)
        }

        // 所有 (楼, 名字) 对，按名字长度降序 —— **长名优先**，
        // 否则「B1」会抢在「明德楼B1」前面，把一整栋楼认成另一栋。
        let pairs = keyPairs(buildings)

        // ② 楼名后面跟房号（最常见，也最该认定为"正常"）
        for (b, k) in pairs where k.count >= 2 && q.contains(k) {
            let tail = removingFirst(k, from: q)
            if tail.isEmpty || looksLikeRoom(tail) {
                return NavMatch(building: b, kind: .room)
            }
        }

        // ③ 去掉标点之后再比（「主5#501」→「主5501」，「主-5」→「主5」）
        let qs = NavText.stripPunct(q)
        if !qs.isEmpty {
            for (b, k) in pairs where k.count >= 2 && qs.contains(NavText.stripPunct(k)) {
                let stripped = NavText.stripPunct(k)
                guard !stripped.isEmpty else { continue }
                let tail = removingFirst(stripped, from: qs)
                if tail.isEmpty || looksLikeRoom(tail) {
                    return NavMatch(building: b, kind: .fuzzy)
                }
            }
        }

        // ④ 局部相似：兜底。
        //
        // ★ 两个候选咬得很近时**不猜** —— "猜错一栋楼"比"没找到"更糟：
        //   用户会直接按它导航过去。所以除了 0.75 的绝对门槛，
        //   还要求领先第二名 0.08。
        var best: NavBuilding?
        var bestScore = 0.0
        var second = 0.0
        for (b, k) in pairs {
            let kk = NavText.stripPunct(k)
            if kk.count < 2 { continue }
            let sc = similarity(qs, kk)
            if b.id != best?.id && sc >= bestScore {
                second = bestScore
                bestScore = sc
                best = b
            } else if sc > second {
                second = sc
            }
        }
        if let best, bestScore >= 0.75, bestScore - second >= 0.08 {
            return NavMatch(building: best, kind: .fuzzy)
        }

        return nil
    }

    /// 把「明德楼B1 302」拆成「明德楼B1」+「302」。
    ///
    /// ## 设计原则：**宁可不拆，不可拆错**
    ///
    /// ```
    ///   不拆 → 导到「明德楼B1302」→ 搜不到 → 用户看到"认不出"，自己删掉房号
    ///          代价：多试一次。**用户知道发生了什么事。**
    ///
    ///   拆错 → 把「XX路302号」拆成「XX路」→ 导到别的地方
    ///          代价：走错路，而且**用户根本不知道**。
    /// ```
    ///
    /// 所以铁律是：**只在"拆完之后剩下的部分确实匹配到了用户标过的楼"时才拆。**
    /// 于是「XX路302号」拆出来是「XX路」，而用户没标过叫「XX路」的楼，
    /// 这次拆分被整体放弃，原文原样交给后面的步骤。
    ///
    /// ## 为什么先匹配楼名、再剥房号（而不是反过来）
    ///
    /// 中文学校里「明德楼A」「明德A楼」「明德楼A座」指的是**同一栋**，
    /// 而「明德楼」是**另一栋**。所以：
    /// ```
    ///   明德楼A 203  →  楼是「明德楼A」，不是「明德楼」   ← 这个 A 属于楼名
    /// ```
    /// 先按正则剥尾巴，会把「明德楼A」剥成「明德楼」—— 两个楼长得一样，
    /// 用户走进去才发现不对，是最坏的一种错。
    static func split(_ text: String, in buildings: [NavBuilding]) -> NavSplit {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .unmatched(raw) }

        let q = NavText.corePlace(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .unmatched(raw) }

        // ★ 第一步：先把楼名找出来。找不到就**一个字都不动**。
        guard let hit = match(q, in: buildings) else { return .unmatched(q) }
        let b = hit.building
        let fuzzy = hit.kind.isGuess

        // 楼名**在原文里实际出现的那一段**（可能是别名）。
        // 模糊命中时楼名可能不是原样出现在原文里（少了字/多了标点）——
        // 这时 span 找不到，但不能因此说"没匹配上"。
        guard let span = longestKeySpan(q, in: b) else {
            return NavSplit(
                building: b,
                place: b.name,
                room: fuzzy ? extractRoom(q) : "",
                fuzzy: fuzzy
            )
        }

        // ★ 第二步：只剥「楼名之后」剩下的那截，在里面找房号。
        //
        // ⚠️ 「楼名之前」的东西一律不管 —— 「东门进去第二栋 明德楼B1」
        //    这种写法里前半句是有用的语境，而房号**只可能**出现在楼名后面。
        let tail = String(q[span.upperBound...])
        var room = extractRoom(tail)
        if room.isEmpty, let cut = raw.firstIndex(where: { $0 == "#" || $0 == "＃" }) {
            // 井号后面的那段也是房号来源（「主5#501」切完之后 tail 是空的）
            room = String(raw[raw.index(after: cut)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 终点名优先用楼自己的 name（不是原文）—— 用户拿到的导航终点是
        // 「明德楼B1」而不是「明德楼B1 302」，带房号的名字会让地图去搜
        // 一个不存在的地方。
        let place = b.name.isEmpty ? String(q[span]) : b.name
        return NavSplit(building: b, place: place, room: room, fuzzy: fuzzy)
    }

    // MARK: 内部

    private static func keyPairs(_ buildings: [NavBuilding]) -> [(NavBuilding, String)] {
        var out: [(NavBuilding, String)] = []
        for b in buildings {
            var seen = Set<String>()
            for k in b.keys.map({ NavText.corePlace(NavText.norm($0)) }) where !k.isEmpty {
                if seen.insert(k).inserted { out.append((b, k)) }
            }
        }
        // 稳定排序：长度相同的保持原顺序（Swift 的 sort 不保证稳定，
        // 但这里长度相同的两个候选谁先谁后都不影响正确性 —— 只影响
        // "两栋楼名字一样长时先命中哪个"，而那种情况本身就是歧义数据）。
        out.sort { a, b in a.1.count > b.1.count }
        return out
    }

    private static func removingFirst(_ needle: String, from hay: String) -> String {
        guard let r = hay.range(of: needle) else { return hay }
        return hay.replacingCharacters(in: r, with: "")
    }

    /// 剩下那截是不是房号：以数字开头，或去掉 `# - 号 栋 楼 室 房` 之后是数字。
    static func looksLikeRoom(_ tail: String) -> Bool {
        let t0 = tail.trimmingCharacters(in: .whitespaces)
        // 「主5 教室」「主5号楼」这种：后面只剩单位词，也算"楼名 + 后缀"，
        // 归到正常用法，别当成猜。
        if !t0.isEmpty, t0.allSatisfy({ "教室号楼栋馆舍层号 ".contains($0) }) { return true }
        var t = Substring(t0)
        while let f = t.first, "#-号楼室房".contains(f) { t = t.dropFirst() }
        guard let f = t.first else { return false }
        return f.isNumber
    }

    /// 找出楼名在原文里占的那一段。
    ///
    /// 比的是**归一化长度**而不是原文长度：候选里有「明德B1」（归一化 4 字）
    /// 和别名「明 德 楼 B1」（归一化 4 字但原文更宽）。要比的是"哪一段更具体"，
    /// 那个量是归一化长度 —— 用原文长度比，带空格的名字会因为"看起来更长"而错误胜出。
    static func longestKeySpan(_ text: String, in b: NavBuilding) -> Range<String.Index>? {
        // ⚠️ 楼名可能带着房号（「主4#201」），查找 span 前先切掉 ——
        //    否则在「主4」里找「主4#201」永远找不到，接着会被判成"没匹配上"。
        var seen = Set<String>()
        let names = ([b.name] + b.alias)
            .map { NavText.corePlace($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        let (hay, origin) = NavText.normWithMap(text)

        var best: Range<String.Index>?
        var bestLen = 0
        for n in names {
            let k = NavText.norm(n)
            guard !k.isEmpty, let at = hay.range(of: k) else { continue }
            let kLen = k.count
            if kLen <= bestLen { continue }

            let startOffset = hay.distance(from: hay.startIndex, to: at.lowerBound)
            let lastOffset = startOffset + kLen - 1
            guard lastOffset < origin.count else { continue }
            best = origin[startOffset]..<text.index(after: origin[lastOffset])
            bestLen = kLen
        }
        return best
    }

    /// 相似度：LCS 同时看**两个方向**的比例。
    ///
    /// ## 为什么不能只除以"较短的那个长度"
    ///
    /// 原来写的是 `lcs / min(n, m)`，于是短楼名「主5」对长地点「主5501」
    /// 直接得 1.0 —— 任何短名字只要出现在长串里就"满分"，
    /// 而那条已经在"楼名+房号"一档处理过了。这里是**最后的兜底**，必须严格：
    ///
    /// ```
    ///   lcs / min ≥ 0.8   —— 短的那个基本被完整包含
    ///   lcs / max ≥ 0.6   —— 长的那个也不能差太多
    ///   首字相同          —— 中文楼名第一个字是"主/明/文"这种，几乎不会错
    /// ```
    ///
    /// 三条同时成立才返回分数，否则 0（= 不猜）。
    ///
    /// 用 LCS 而不是编辑距离：中文楼名错一个字（「明德」vs「明德楼」）时，
    /// LCS 能保住 2/3 的分，编辑距离会把长度差也算成错误，打分偏低。
    static func similarity(_ a: String, _ b: String) -> Double {
        let ca = Array(a)
        let cb = Array(b)
        guard !ca.isEmpty, !cb.isEmpty else { return 0 }
        guard ca[0] == cb[0] else { return 0 }

        let n = ca.count
        let m = cb.count
        var dp = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            var prev = 0
            for j in 1...m {
                let tmp = dp[j]
                dp[j] = ca[i - 1] == cb[j - 1] ? prev + 1 : max(dp[j], dp[j - 1])
                prev = tmp
            }
        }
        let lcs = Double(dp[m])
        let ratioMin = lcs / Double(min(n, m))
        let ratioMax = lcs / Double(max(n, m))
        return (ratioMin >= 0.8 && ratioMax >= 0.6) ? ratioMax : 0
    }

    // MARK: 房号

    /// 房号的正则。
    ///
    /// `([A-Za-z]?[0-9]{1,6}(?:[-#][0-9]{1,4})?)` 是主体（可带座号字母、
    /// 可带连字符），后面 `(楼|层|室|教室|机房)?` 是可选的中文单位。
    ///
    /// ⚠️ 用 `firstMatch` 不是整串匹配 —— 尾巴可能是「上去三楼 302」这种，
    ///    要能**抠出** 302。
    ///
    /// ⚠️ `\b` / `$` 之类的边界断言**不能加**：中文标点和字母之间没有词边界，
    ///    加了会让「302，」匹配不上（中文逗号不是 `\b`）。
    private static let roomRegex = try! NSRegularExpression(
        pattern: "([A-Za-z]?[0-9]{1,6}(?:[-#][0-9]{1,4})?)(楼|层|室|教室|机房)?"
    )

    /// 明确**不是**房号的词。判据是**整段相等**。
    /// 加词要谨慎：加错一个词会让一整类正常地点被剥成空。
    private static let nonRoomWords: Set<String> = [
        "门口", "大门", "正门", "侧门", "后门", "东门", "西门", "南门", "北门",
        "附近", "旁边", "对面", "斜对面", "里面", "外面", "楼上", "楼下",
    ]

    /// 从"楼名之后的那一截"里提取房号。提取不到返回空串。
    ///
    /// | 尾巴 | 房间 | 说明 |
    /// |---|---|---|
    /// | `" 302"` | `302` | 最常见 |
    /// | `"-302"` | `302` | 连字符分隔 |
    /// | `"302"` | `302` | 紧跟楼名（「明德楼B1302」） |
    /// | `" A203"` | `A203` | 带座号 |
    /// | `" 13楼"` | `13楼` | 中文单位 |
    /// | `" 2楼"` | `2楼` | ★ 单位场合**允许一位数** |
    /// | `" (302)"` | `302` | 括号包裹 |
    /// | `"3-302"` | `3-302` | 层-房 |
    ///
    /// 不认：「门口」「附近」「旁边」「对面」—— 这些是方位修饰，不是房间。
    ///
    /// ## 位数判据要分两种情况（实测踩到）
    ///
    /// 写死"房号必须 2~6 位"会让「第一食堂 2楼」里的 `2` 被拒 ——
    /// 而「2楼」「3层」是完全正常的说法。所以：
    /// · **带中文单位** → 允许 1~6 位（单位本身已经说明它是楼层/房间）
    /// · **不带单位**   → 要求 2~6 位（孤零零的 "1" 太可疑，可能是"1号门"残留）
    ///
    /// ## 单位后缀为什么要留在结果里
    ///
    /// `"13楼"` 如果只取 `"13"`，显示出来用户会以为是房号 13（在 1 楼），
    /// 而实际是"13 楼"。**少一个字的差别是整栋楼的差别。**
    static func extractRoom(_ tailRaw: String) -> String {
        let ns = tailRaw as NSString
        guard ns.length > 0,
              let m = roomRegex.firstMatch(in: tailRaw, options: [],
                                           range: NSRange(location: 0, length: ns.length))
        else { return "" }

        let bodyRange = m.range(at: 1)
        guard bodyRange.location != NSNotFound else { return "" }
        let body = ns.substring(with: bodyRange)
        let unitRange = m.range(at: 2)
        let unit = unitRange.location == NSNotFound ? "" : ns.substring(with: unitRange)

        // ★★ 右边界检查：紧跟着的**还是数字**就整段放弃。
        //
        //    实测踩到：`"明德楼B1 1234567"` 里 `\d{1,6}` 会**贪婪截取前 6 位**，
        //    把 7 位的 `1234567` 变成"看起来合法"的假房号 `123456`。
        //    这比"不认"糟得多 —— 它编了一个不存在的房号出来。
        let afterBody = bodyRange.location + bodyRange.length
        if afterBody < ns.length {
            let next = ns.substring(with: NSRange(location: afterBody, length: 1))
            if let f = next.first, f.isNumber { return "" }
        }

        let digits = body.filter { $0.isNumber }.count
        let minDigits = unit.isEmpty ? 2 : 1
        if digits < minDigits || digits > 6 { return "" }

        // ★ 修饰词排查：**抠出来的那一段**如果是"门口/附近"这类词，就不算房号。
        //    查的是整段相等（"门口"是修饰词，但"302门口"不是 —— 后者提到了 302）。
        let room = body + unit
        if nonRoomWords.contains(room) { return "" }
        if nonRoomWords.contains(body) { return "" }
        return room
    }
}
