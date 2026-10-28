#!/usr/bin/env bash
# TMMemberPatch 构建脚本
# 用法: ./build.sh          默认 theos 构建
#       ./build.sh clang    只用 clang 出裸 dylib (无需 theos)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> 工作目录: $SCRIPT_DIR"

if [ "$1" = "clang" ]; then
    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    echo "==> SDK: $SDK"

    echo "==> 编译 arm64"
    clang -arch arm64 -miphoneos-version-min=14.0 \
        -isysroot "$SDK" -dynamiclib -fobjc-arc -O2 \
        -framework Foundation -framework UIKit \
        -install_name @executable_path/TMMemberPatch.dylib \
        -o TMMemberPatch_arm64.dylib TMMemberPatch.m

    echo "==> 编译 arm64e"
    clang -arch arm64e -miphoneos-version-min=14.0 \
        -isysroot "$SDK" -dynamiclib -fobjc-arc -O2 \
        -framework Foundation -framework UIKit \
        -install_name @executable_path/TMMemberPatch.dylib \
        -o TMMemberPatch_arm64e.dylib TMMemberPatch.m

    echo "==> 合并 fat binary"
    lipo -create TMMemberPatch_arm64.dylib TMMemberPatch_arm64e.dylib \
        -output TMMemberPatch.dylib

    echo "==> 签名 (ldid)"
    if command -v ldid >/dev/null 2>&1; then
        ldid -S TMMemberPatch.dylib
    else
        echo "    未装 ldid，跳过。请在 Mac 上安装: brew install ldid"
    fi

    echo "==> 完成: $SCRIPT_DIR/TMMemberPatch.dylib"
    lipo -info TMMemberPatch.dylib
    exit 0
fi

# theos 路径
if [ -z "$THEOS" ]; then
    if [ -d "$HOME/theos" ]; then
        export THEOS="$HOME/theos"
    else
        echo "错误: 没找到 theos。设置 export THEOS=~/theos 或先装 theos" >&2
        exit 1
    fi
fi
echo "==> THEOS: $THEOS"

make clean 2>/dev/null || true
make package

echo "==> 产物:"
ls -la "$SCRIPT_DIR/.theos/obj/"*.dylib 2>/dev/null || true
ls -la "$SCRIPT_DIR/packages/"*.deb 2>/dev/null || true
