"""取消除最新一次以外的 in_progress / queued run。

为什么需要：`push_via_contents.py` 是一个文件一个 commit，
而 GitHub 为**每个 commit** 都跑一次 CI。23 个文件就有 23 个 run，
其中大多数一定编译不过（引用了还没上传的 .swift）。
必须只留最后那个，否则 macOS runner 排队会互相挤。

⚠️ 不通过 `subprocess` 调 `ci.py`，而是直接 import。
   子进程那条路在这台机器上会偶发拿到空 stdout（捕获时解码不稳），
   表现为「没拿到 run 列表」—— 看起来像 API 出错，其实是本地管道的问题。
   直接调 API 函数，异常能原样冒出来。

⚠️ `per_page` 最多用 10。试过 40，响应体 528KB，
   这台机器的链路直接抛 `IncompleteRead(481510 read, 47031 more expected)`
   —— 不是接口错，是读不满。要取消中间态只需要最近几个，
   10 个足够覆盖「一个文件一个 commit」的那一波。
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ci  # noqa: E402


def fetch_runs(n):
    """拿 run 列表，失败重试。返回 list。"""
    last = None
    for _ in range(3):
        try:
            out = ci.req("GET", f"/repos/{ci.REPO}/actions/workflows/"
                                f"{ci.WORKFLOW}/runs?per_page={n}")
            return out.get("workflow_runs", [])
        except Exception as e:                       # noqa: BLE001
            last = e
    raise last


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    runs = fetch_runs(n)
    if not runs:
        print("没有 run")
        return 1

    keep = runs[0]["id"]
    print("保留最新: %s (%s %s)" % (keep, runs[0]["status"],
                                  runs[0]["conclusion"] or "-"))

    for r in runs[1:]:
        rid, status = r["id"], r["status"]
        if status not in ("in_progress", "queued", "waiting", "pending"):
            print(rid, status, r["conclusion"] or "-", "已结束，跳过")
            continue
        try:
            ci.req("POST", f"/repos/{ci.REPO}/actions/runs/{rid}/cancel")
            print(rid, "已取消")
        except Exception as e:                       # noqa: BLE001
            print(rid, "取消失败:", str(e)[:80])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
