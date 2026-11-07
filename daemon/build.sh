#!/bin/bash
# daemon/build.sh —— 产出 com.xov.daemon 的 .deb（xovd + 四个 helper + xov-cli + launchd plist）。
#
# 由 Apelin 的外部构建（apelin_project_build）调用，也可以在本机终端手跑：
#
#   APELIN_PROJECT_ROOT=... APELIN_PACKAGE_DIR=$(mktemp -d) \
#   APELIN_ARCHITECTURE=iphoneos-arm64 daemon/build.sh
#
# 三条硬规矩（都是 roothide 上实测踩出来的，改动时别退回去）：
#   1) 环境变量只读：APELIN_PROJECT_ROOT / APELIN_PACKAGE_DIR / TMPDIR 缺一个就失败，
#      不在脚本里自己猜路径。
#   2) 所有编译都在 $(mktemp -d -p "$TMPDIR") 里用**相对路径**做。roothide 下给 clang
#      绝对路径的 -o，产物常常静默不落地（进程按另一套视图解析那个绝对路径）。
#   3) 不写死 .jbroot-XXXX：包内路径全是逻辑路径，前缀由安装器和 launchd 决定。
#
# 本脚本不安装、不加载、不 respring：只编译 + 打包，产物写进 APELIN_PACKAGE_DIR。

set -euo pipefail

: "${APELIN_PROJECT_ROOT:?需要 APELIN_PROJECT_ROOT}"
: "${APELIN_PACKAGE_DIR:?需要 APELIN_PACKAGE_DIR}"
: "${TMPDIR:?需要 TMPDIR}"

PKGID="com.xov.daemon"
VERSION="${XOV_VERSION:-0.1.0}"
ARCH="${APELIN_ARCHITECTURE:-iphoneos-arm64}"
MAINTAINER="${XOV_MAINTAINER:-weishixiao <weishixiao@users.noreply.github.com>}"

[ -d "$APELIN_PROJECT_ROOT/daemon" ] || {
    echo "build.sh: 找不到 $APELIN_PROJECT_ROOT/daemon" >&2
    exit 1
}
mkdir -p "$APELIN_PACKAGE_DIR"

WORK="$(mktemp -d -p "$TMPDIR" xov-build.XXXXXX)" || exit 1
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# 相对路径的锚点：在 WORK 里把项目根挂成 src，之后一切路径都是 src/daemon/xxx。
cd "$WORK"
ln -s "$APELIN_PROJECT_ROOT" src

echo "build.sh: pkg=$PKGID version=$VERSION arch=$ARCH"
echo "build.sh: project=$(cd src && pwd -P)"
echo "build.sh: work=$WORK"

# -fblocks：xovd.c / xov-cli.c 用 dispatch 的 block 语法写事件处理，C 里必须显式打开。
# -lxpc 不需要：SDK 的 libSystem.tbd 重导出 /usr/lib/system/libxpc.dylib。
CFLAGS=(-arch arm64e -arch arm64 -O2 -fblocks -Wall -Wno-unused-parameter)

compile() {
    local out="$1" src="$2"
    shift 2
    echo "build.sh: clang -> $out"
    clang "${CFLAGS[@]}" "$@" -o "$out" "$src"
    lipo -info "$out" 2>/dev/null | sed 's/^/build.sh:   /' || true
}

compile xovd        src/daemon/xovd.c        -framework Foundation
compile xov-build   src/daemon/xov-build.c
compile xov-install src/daemon/xov-install.c
compile xov-symbolicate src/daemon/xov-symbolicate.c
compile xov-bin     src/daemon/xov-bin.c
compile xov-cli     src/daemon/xov-cli.c     -framework Foundation

# ldid -S<复数文件>：校验要求二进制自带 entitlements，否则 launchd 不认 MachService、
# helper 也写不进别的 App Bundle。xov-cli 带客户端标记 wiki.xov.client。
echo "build.sh: ldid 签名"
ldid -Ssrc/daemon/xovd.entitlements xovd
ldid -Ssrc/daemon/bin-entitlements.plist xov-build
ldid -Ssrc/daemon/bin-entitlements.plist xov-install
ldid -Ssrc/daemon/bin-entitlements.plist xov-symbolicate
ldid -Ssrc/daemon/bin-entitlements.plist xov-bin
ldid -Ssrc/daemon/xov-cli.entitlements xov-cli

# ---- 打包树 ----
ROOT="$WORK/root"
mkdir -p "$ROOT/usr/libexec/xov" "$ROOT/usr/bin" \
         "$ROOT/Library/LaunchDaemons" "$ROOT/DEBIAN"

cp xovd            "$ROOT/usr/libexec/xovd"
cp xov-build       "$ROOT/usr/libexec/xov/xov-build"
cp xov-install     "$ROOT/usr/libexec/xov/xov-install"
cp xov-symbolicate "$ROOT/usr/libexec/xov/xov-symbolicate"
cp xov-bin         "$ROOT/usr/libexec/xov/xov-bin"
cp xov-cli         "$ROOT/usr/bin/xov-cli"
for f in "$ROOT/usr/libexec/xovd" "$ROOT"/usr/libexec/xov/* "$ROOT/usr/bin/xov-cli"; do
    chmod 0755 "$f"
done

cp src/daemon/wiki.xov.xovd.plist "$ROOT/Library/LaunchDaemons/wiki.xov.xovd.plist"
chmod 0644 "$ROOT/Library/LaunchDaemons/wiki.xov.xovd.plist"

SIZE="$(du -sk "$ROOT" | awk '{print $1}')"

cat > "$ROOT/DEBIAN/control" <<EOF
Package: $PKGID
Name: Xov Root Daemon
Version: $VERSION
Architecture: $ARCH
Description: Xov 的 root XPC 守护（xovd）与白名单 helper 工具
 xovd 经 MachService wiki.xov.service 提供服务，只执行 /usr/libexec/xov/ 下的四个
 helper（xov-build / xov-install / xov-symbolicate / xov-bin），不提供任意脚本入口。
 客户端必须带 wiki.xov.client entitlement。
Maintainer: $MAINTAINER
Author: $MAINTAINER
Section: Development
Priority: optional
Installed-Size: $SIZE
Depends: firmware (>= 15.0)
EOF

# postinst 只准备运行环境，不加载服务：加载这一步交给
#   icli svc bootstrap <plist>（它负责 roothide 的路径改写）
# 数据目录与日志都在真根上（/var/mobile、/var/log），两种 bootstrap 下都是同一处，
# 所以脚本里不需要 @PREFIX@/@ROOTFS@ 之类的占位符。
cat > "$ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

# xov-build / xov-install 要求 work root 已存在且属 mobile：App 写不进去时由这里兜底。
DATA=/var/mobile/Documents/wiki.xov
mkdir -p "$DATA/work"
chown -R mobile:mobile "$DATA" 2>/dev/null || true

# 日志：xovd 自己也会 open(O_CREAT)，这里先建好，装完立刻可 tail。
touch /var/log/xovd.log
chmod 0644 /var/log/xovd.log

echo "xovd 已安装。按顺序执行："
echo "  1) icli svc paths <jbroot>/Library/LaunchDaemons/wiki.xov.xovd.plist    # 预览路径改写"
echo "  2) icli svc bootstrap <jbroot>/Library/LaunchDaemons/wiki.xov.xovd.plist  # 加载（需 root）"
echo "  3) xov-cli status    # 期望 status: OK / uid: 0"
exit 0
EOF
chmod 0755 "$ROOT/DEBIAN/postinst"

# postrm 只清运行期残渣（pidfile、日志），不动用户数据目录 /var/mobile/Documents/wiki.xov ——
# 里面是构建工作区，重装后还要用。
cat > "$ROOT/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    rm -f /var/run/xovd.pid 2>/dev/null || true
fi
exit 0
EOF
chmod 0755 "$ROOT/DEBIAN/postrm"

DEB="$APELIN_PACKAGE_DIR/${PKGID}_${VERSION}_${ARCH}.deb"
echo "build.sh: dpkg-deb -> $DEB"
dpkg-deb -b --root-owner-group "$ROOT" "$DEB"

# 自检：包里的四个 helper 与 xovd 必须在，且带签名。
echo "build.sh: 包内容"
dpkg-deb -c "$DEB" | sed 's/^/build.sh:   /'

echo "build.sh: OK"
echo "$DEB"
