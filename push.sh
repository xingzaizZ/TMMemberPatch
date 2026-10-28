#!/usr/bin/env bash
# 一键推到 GitHub 触发云端构建
# 用法:
#   ./push.sh                       首次：初始化仓库并推送
#   ./push.sh "提交说明"             后续：改完代码推一次
#   ./push.sh --release v1.0.0       打 tag，自动发布 Release
set -e

cd "$(dirname "$0")"

REPO_NAME="TMMemberPatch"

# ---------- 首次初始化 ----------
if [ ! -d .git ]; then
    echo "==> 首次初始化仓库"
    git init -b main

    git config user.name  "$(git config --global user.name || echo 'TMPatch')"
    git config user.email "$(git config --global user.email || echo 'tmpatch@local')"

    git add -A
    git commit -m "init: TM手游加速器 本地会员 dylib 插件"

    echo ""
    echo "=========================================="
    echo " 仓库已初始化，还差关联远程仓库。"
    echo ""
    echo " 方式 A - 用 GitHub CLI（推荐，会自动建仓）:"
    echo "   gh repo create $REPO_NAME --private --source=. --push"
    echo ""
    echo " 方式 B - 手动建仓后关联:"
    echo "   git remote add origin git@github.com:你的用户名/$REPO_NAME.git"
    echo "   git push -u origin main"
    echo "=========================================="
    exit 0
fi

# ---------- 检查远程 ----------
if ! git remote get-url origin >/dev/null 2>&1; then
    echo "错误: 还没设置远程仓库"
    echo "  gh repo create $REPO_NAME --private --source=. --push"
    echo "  或: git remote add origin <你的仓库地址>"
    exit 1
fi

# ---------- 打 Release tag ----------
if [ "$1" = "--release" ]; then
    TAG="${2:-v$(date +%Y%m%d-%H%M)}"
    echo "==> 打 tag: $TAG"
    git add -A
    git commit -m "release: $TAG" || echo "    无改动，跳过 commit"
    git tag -a "$TAG" -m "Release $TAG"
    git push origin main
    git push origin "$TAG"
    echo ""
    echo "========== 已推送 tag $TAG =========="
    echo "GitHub 会自动构建并发布 Release:"
    echo "  https://github.com/$(git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#')/releases"
    exit 0
fi

# ---------- 普通提交 ----------
MSG="${1:-update: $(date '+%Y-%m-%d %H:%M')}"
echo "==> 提交: $MSG"
git add -A
if git diff --cached --quiet; then
    echo "    没有改动，直接推送"
else
    git commit -m "$MSG"
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "==> 推送到 origin/$BRANCH"
git push origin "$BRANCH"

echo ""
echo "========== 已推送 =========="
echo "构建进度: 打开仓库 Actions 页"
echo "  https://github.com/$(git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#')/actions"
echo ""
echo "产物下载: 进入对应 run -> Artifacts -> TMMemberPatch-<sha>-both"
