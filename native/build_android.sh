#!/usr/bin/env bash
# 编译红果引擎的 Android arm64 原生库。
# 引擎源码不在本仓库内，通过 go.mod 的 replace 指向本地「短聚」工程（只读引用，不修改其文件）。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GO_BIN="${GO_BIN:-C:/Users/hui/DevTools/go/bin}"
NDK="${ANDROID_NDK_HOME:-C:/Users/hui/DevTools/android-sdk/ndk/28.2.13676358}"
NDK_BIN="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin"
OUT="$HERE/../app/android/app/src/main/jniLibs/arm64-v8a"

export PATH="$GO_BIN:$PATH"
export GOOS=android
export GOARCH=arm64
export CGO_ENABLED=1
export CC="$NDK_BIN/aarch64-linux-android24-clang.cmd"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
export GOSUMDB=off

mkdir -p "$OUT"
cd "$HERE"
echo ">>> 编译 arm64 原生库"
go build -buildmode=c-shared -trimpath -ldflags="-s -w" -o "$OUT/libhgnative.so" .
echo ">>> 产物: $(ls -la "$OUT/libhgnative.so" | awk '{print $5" 字节"}')"

echo ">>> 导出符号"
nm -D "$OUT/libhgnative.so" | grep -E " T (HgRequest|HgFree)$"
