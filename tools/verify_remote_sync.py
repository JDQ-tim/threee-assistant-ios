"""核验远端 main 与本地 git HEAD 的内容是否完全一致（逐文件 blob sha）。

为什么需要单独一个工具：`push_via_contents.py` 走的是 Contents API，
一个文件一个 commit。它**有可能**因为超时/重试只推了一半，
或者推上去的内容和本地 HEAD 不一致 —— 而 CI 是拿远端内容编的，
如果两者不同，那 CI 绿证明的不是本地这份代码。

⚠️ 必须比 `git show HEAD:<path>`，**不能**比工作区文件。
   这台机器 `core.autocrlf=true`：git 提交时把 CRLF 转成 LF，
   检出时再转回 CRLF。所以工作区是 CRLF、git blob 和远端都是 LF。
   直接拿工作区字节去比，每个改过的文件都会"不一致"，
   而实际内容一模一样 —— 2026-11-02 我就这么误判过一次。
"""
import base64
import hashlib
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402


def blob_sha(raw: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(raw) + raw).hexdigest()


def tracked_files() -> list:
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True,
                         encoding="utf-8", errors="replace").stdout
    return [f for f in out.replace("\r", "").splitlines() if f.strip()]


def head_bytes(path: str) -> bytes:
    return subprocess.run(["git", "show", "HEAD:%s" % path],
                          capture_output=True).stdout


def main() -> int:
    files = tracked_files()
    bad, checked = [], 0
    for p in files:
        local = head_bytes(p)
        if not local:
            continue
        try:
            r = ci.req("GET", "/repos/%s/contents/%s?ref=main" % (ci.REPO, p))
        except Exception as e:                       # noqa: BLE001
            bad.append((p, "取远端失败: %s" % str(e)[:60]))
            continue
        checked += 1
        if r.get("sha") != blob_sha(local):
            bad.append((p, "sha 不同 远端=%s 本地=%s"
                        % (r.get("sha", "?")[:10], blob_sha(local)[:10])))

    print("比对 %d 个文件（共 %d 个已跟踪）" % (checked, len(files)))
    if bad:
        print("\n不一致 %d 个：" % len(bad))
        for p, why in bad:
            print("  ❌", p, "—", why)
        return 1
    print("✅ 远端 main 与本地 HEAD 完全一致")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
