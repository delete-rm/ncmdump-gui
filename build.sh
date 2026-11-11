#!/bin/bash
#
# 构建 ncmdump GUI（原生 AppKit，单文件 Objective-C）
#
# 用法：
#   ./build.sh                  # 构建并安装到 ~/Applications/ncmdump.app
#   ./build.sh /path/xxx.app    # 构建到指定位置
#   ./build.sh --no-launch      # 构建完不自动启动
#   ./build.sh --zip            # 额外产出一个可上传 Release 的 zip
#
# 首次构建会从 GitHub 下载 ncmdump 1.5.0（arm64 + x86_64）并合并成 universal，
# 缓存在 vendor/ncmdump（已在 .gitignore 中，不入库）。之后构建直接复用。
# 离线环境可手动把 ncmdump 可执行文件放到 vendor/ncmdump 再构建。
#
# 可用环境变量：
#   NCM_VER=1.5.0              指定内核版本
#   NCM_URL_PREFIX=<前缀>       替换下载地址前缀（镜像用），默认走 GitHub
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Applications/ncmdump.app"
LAUNCH=1
MAKE_ZIP=0
NCM_VER="${NCM_VER:-1.5.0}"
APP_VERSION="${APP_VERSION:-1.4}"

# 内置内核的 SHA256（用于校验下载完整性；换版本时同步更新）
case "$NCM_VER" in
  1.5.0)
    SHA_arm64="3d059dcf53f4dbacd9442b443d23152e69b28ddba318e3435e2ddb282c040e2c"
    SHA_x86_64="b5efa23644645746965dd2b4eed66c581c0904212d46e7fce676f3a2d2b3e16e"
    ;;
  *)
    SHA_arm64=""; SHA_x86_64="" ;;
esac
NCM_URL_PREFIX="${NCM_URL_PREFIX:-https://github.com/taurusxin/ncmdump/releases/download}"

for arg in "$@"; do
    case "$arg" in
        --no-launch) LAUNCH=0 ;;
        --zip)       MAKE_ZIP=1 ;;
        *)           DEST="$arg" ;;
    esac
done

BIN_NAME="NCMDump"
BUNDLE_ID="local.ncmdump.gui"
HELPER="$HERE/vendor/ncmdump"

echo "==> 检查依赖"
xcode-select -p >/dev/null 2>&1 || { echo "需要 Xcode Command Line Tools：xcode-select --install"; exit 1; }
mkdir -p "$HERE/build" "$HERE/vendor"

##############################################################################
# 内核：优先复用缓存，否则下载并合并成 universal
##############################################################################
if [ -x "$HELPER" ] && "$HELPER" -v >/dev/null 2>&1; then
    echo "==> 内核已就绪（复用 vendor/ncmdump: $("$HELPER" -v 2>/dev/null)）"
else
    echo "==> 下载 ncmdump $NCM_VER（arm64 + x86_64）并合并为 universal"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    for arch in arm64 x86_64; do
        url="$NCM_URL_PREFIX/$NCM_VER/ncmdump-$NCM_VER-darwin-$arch.tar.gz"
        echo "    ↓ $arch"
        mkdir -p "$TMP/$arch"
        if ! curl -L --http1.1 -sS --retry 3 --retry-all-errors --connect-timeout 30 -m 240 \
                  -o "$TMP/$arch.tar.gz" "$url"; then
            echo
            echo "下载失败：$url"
            echo "可尝试："
            echo "  · 重试本脚本（网络不稳定时 GitHub 偶发超时）"
            echo "  · NCM_URL_PREFIX=https://ghproxy.net/https://github.com/taurusxin/ncmdump/releases/download ./build.sh"
            echo "  · 或手动下载 ncmdump-$NCM_VER-darwin-{arm64,x86_64}.tar.gz，解压后："
            echo "      lipo -create -output vendor/ncmdump <arm64/ncmdump> <x86_64/ncmdump> && chmod +x vendor/ncmdump"
            exit 1
        fi
        want=""
        eval "want=\$SHA_$arch"
        if [ -n "$want" ]; then
            got=$(shasum -a 256 "$TMP/$arch.tar.gz" | cut -d' ' -f1)
            if [ "$got" != "$want" ]; then
                echo "校验失败（$arch）：期望 $want，实际 $got"
                echo "下载文件可能被篡改或上游重新打包，已中止。"
                exit 1
            fi
            echo "    ✓ $arch 校验通过"
        fi
        tar xzf "$TMP/$arch.tar.gz" -C "$TMP/$arch"
    done

    lipo -create -output "$HELPER" "$TMP/arm64/ncmdump" "$TMP/x86_64/ncmdump"
    chmod +x "$HELPER"
    echo "    完成：$(lipo -info "$HELPER" | sed 's/.*are: //')"
fi

##############################################################################
# 编译
##############################################################################
echo "==> 编译主程序（universal2: arm64 + x86_64）"
CLANG_FLAGS=(-fobjc-arc -O2 -framework Cocoa -framework UniformTypeIdentifiers)
clang "${CLANG_FLAGS[@]}" -target arm64-apple-macos12.0  -o "$HERE/build/$BIN_NAME-arm64"  "$HERE/main.m"
clang "${CLANG_FLAGS[@]}" -target x86_64-apple-macos12.0 -o "$HERE/build/$BIN_NAME-x86_64" "$HERE/main.m"
lipo -create -output "$HERE/build/$BIN_NAME" \
     "$HERE/build/$BIN_NAME-arm64" "$HERE/build/$BIN_NAME-x86_64"

echo "==> 生成图标"
clang -fobjc-arc -O2 -framework Cocoa -o "$HERE/build/icongen" "$HERE/icon.m"
( cd "$HERE/build" && ./icongen >/dev/null 2>&1 )
rm -rf "$HERE/build/ncmdump.iconset"
mkdir -p "$HERE/build/ncmdump.iconset"
for s in 16 32 128 256 512; do
    sips -z $s $s "$HERE/build/icon_1024.png" --out "$HERE/build/ncmdump.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$HERE/build/icon_1024.png" --out "$HERE/build/ncmdump.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$HERE/build/ncmdump.iconset" -o "$HERE/build/icon.icns"

##############################################################################
# 打包
##############################################################################
echo "==> 组装 App Bundle"
pkill -f "$BIN_NAME" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$HERE/build/$BIN_NAME" "$DEST/Contents/MacOS/$BIN_NAME"
cp "$HELPER" "$DEST/Contents/Resources/ncmdump"
cp "$HERE/build/icon.icns" "$DEST/Contents/Resources/icon.icns"
cp "$HERE/vendor/ncmdump.LICENSE.txt" "$DEST/Contents/Resources/ncmdump.LICENSE.txt"
chmod +x "$DEST/Contents/MacOS/$BIN_NAME" "$DEST/Contents/Resources/ncmdump"
printf 'APPL????' > "$DEST/Contents/PkgInfo"

cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ncmdump</string>
    <key>CFBundleDisplayName</key><string>ncmdump</string>
    <key>CFBundleExecutable</key><string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>icon</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>NetEase Cloud Music NCM</string>
            <key>CFBundleTypeExtensions</key><array><string>ncm</string></array>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> 签名"
codesign --force --sign - "$DEST" 2>/dev/null
codesign -v "$DEST" && echo "    签名校验通过"

echo "==> 注册到 LaunchServices"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true

if [ "$MAKE_ZIP" = "1" ]; then
    ZIP="$HERE/build/ncmdump.app.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --keepParent "$DEST" "$ZIP"
    echo "==> Release 包：$ZIP"
fi

echo "==> 完成：$DEST（版本 $APP_VERSION）"

if [ "$LAUNCH" = "1" ]; then
    open "$DEST"
fi
