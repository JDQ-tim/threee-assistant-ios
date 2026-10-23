#!/usr/bin/env bash
# ============================================================
# 一键推送到 GitHub（无需安装 gh，用 git 即可）
#
# 用法：
#   1. 在 GitHub 网页上新建一个空仓库（不要勾选 README / .gitignore）
#   2. 执行：  bash tools/push_to_github.sh 你的GitHub用户名 仓库名
#   3. 按提示输入用户名和 Personal Access Token（不是登录密码）
#
# 关于 Token：
#   访问 https://github.com/settings/tokens
#   → Generate new token (classic)
#   → 勾选 repo 权限
#   → 生成后复制，粘贴到密码位置
# ============================================================
set -euo pipefail

GH_USER="${1:-}"
GH_REPO="${2:-}"

if [ -z "$GH_USER" ] || [ -z "$GH_REPO" ]; then
  echo "用法: bash tools/push_to_github.sh <用户名> <仓库名>"
  echo "例如: bash tools/push_to_github.sh jdq threee-assistant-ios"
  exit 1
fi

cd "$(dirname "$0")/.."
echo "当前目录: $(pwd)"

if [ ! -f "ThreeeAssistant.xcodeproj/project.pbxproj" ]; then
  echo "❌ 没找到 Xcode 工程，请在 ios-native 目录下运行"
  exit 1
fi

# 初始化仓库
if [ ! -d ".git" ]; then
  echo "→ 初始化 git 仓库"
  git init -b main
fi

git add -A

if git diff --cached --quiet; then
  echo "→ 没有新的改动需要提交"
else
  git -c user.name="${GH_USER}" -c user.email="${GH_USER}@users.noreply.github.com" \
      commit -m "feat: 3e 学习助手 iOS 原生版（SwiftUI）"
fi

REMOTE="https://github.com/${GH_USER}/${GH_REPO}.git"

if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE"
else
  git remote add origin "$REMOTE"
fi

echo ""
echo "→ 推送到 $REMOTE"
echo "  用户名填: ${GH_USER}"
echo "  密码填  : Personal Access Token"
echo ""
git push -u origin main

echo ""
echo "✅ 推送完成"
echo ""
echo "下一步："
echo "  打开 https://github.com/${GH_USER}/${GH_REPO}/actions"
echo "  点左侧「iOS Build」→ 右侧「Run workflow」→ 绿色按钮"
echo "  等 3~6 分钟，点进这次运行，看页面最下方的 Summary"
