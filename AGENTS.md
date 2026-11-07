# Xov — 工作上下文（每轮从这里恢复）

> 本文件由用户指定写入，内容是会话的权威上下文。任何新会话先读本文件，再动手。

## 1. 项目背景

把 OpenMinis 二次开发成 xosvi 的形态。仓库已克隆在项目根（182 MB，`src/ios/` 是 iOS 端，Swift/SwiftUI；`src/android/` 是 Kotlin/Compose；`deps/`、`scripts/`、`docs/specs/`）。GPL-3.0，`LICENSE` 原样保留。

用户已拍板五项：

1. 底座保留 Minis（工程骨架、agent 引擎、provider 抽象、iSH 沙盒、技能与记忆）不动。
2. 搬 xosvi 的能力（约 50 个原生工具：App 管理、注入、抓包、SQLite 取证、包解剖、内存、设备、文件）。
3. **UI 先不做**（`src/ios/Views` 一行不改，xosvi 的 `ChatView`/`XTheme`/`ConversationListView` 推迟，非取消）。
4. 工具协议全部重写成 Minis 自己的协议，不保留 MCP JSON-RPC 层。
5. 分发继续 TrollStore，保留特权 entitlements 与 root XPC 守护。

当前优先级：先做 root 能力（见第 3 节）。工具协议测绘可以只留草稿，不要扩大。

## 2. 远端

- `upstream` = https://github.com/OpenMinis/OpenMinis.git（保留，以后拉 Minis 更新）
- `origin` = https://github.com/weishixiao/Xov.git（推送目标，public）

## 3. root 守护移植规格（照做，别自己改命名）

源材料在 xosvi 项目的 `tools/`、`Support/`、`Sources/XosviMCP/`、`apelin/build.sh`（**只读**，不改它的文件与 git 历史）。

新目录 `daemon/`（仓库根，与 `src/`、`deps/` 平级）：C 源码 + 头文件 + entitlements + launchd plist + 构建脚本。

- 命名空间统一 **`wiki.xov`**：
  - XPC MachService `wiki.xov.service`
  - launchd label `wiki.xov.xovd`，二进制 `/usr/libexec/xovd`
  - helper 目录 `/usr/libexec/xov/`（`xov-build`、`xov-install`、`xov-symbolicate`、`xov-bin`）
  - 客户端 entitlement `wiki.xov.client`
  - 日志 `/var/log/xovd.log`
- `find_bootstrap()` 的路径解析（env → libroot → 可执行路径 → 扫描 → 真根）原样照搬，别自创。
- 不复活 `/var/tmp` 轮询和 UDS 两条历史方案，只留 XPC。
- 守护只认白名单 helper，不提供任意脚本执行入口。
- 签名 `ldid -S<entitlements>`；构建 `clang -arch arm64e -arch arm64 -O2 -o xovd daemon/xovd.c -framework Foundation`。
- `daemon/APP-ENTITLEMENTS.md`：TrollStore 签名时 App 侧要叠加哪些 key（`platform-application`、`com.apple.private.security.no-sandbox`、`com.apple.private.security.container-required=false`、`com.apple.security.exception.files.absolute-path.read-write`、`com.apple.private.launchservices.mach-services`=`wiki.xov.service`、客户端标记 `wiki.xov.client`），并说明为什么 App 自己装不了 LaunchDaemon、必须配 deb。
- `daemon/README.md`：安装与验证流程（`icli svc paths` 预览 → `icli svc bootstrap` 加载 → `xov-cli status` 期望 `status: OK / uid: 0`）。
- `daemon/build.sh`：只读环境变量（`APELIN_PROJECT_ROOT`/`APELIN_PACKAGE_DIR`/`TMPDIR` 等），缺一个就失败；在 `$(mktemp -d -p "$TMPDIR")` 里用**相对路径**编译（绝对路径的 `-o` 在 roothide 视图下会静默不落地）；产出 `com.xov.daemon` 的 `.deb`。

## 4. 硬约束

- 不装包、不 respring、不动系统；xosvi 项目只读，不改它的文件与 git 历史。
- `src/ios/Views` 一行不改。
- 不构建 iOS App（本机没有 Xcode/Go/macOS），不要声明构建成功。
- 结论区分「已查证 / 推断」；给真实路径，不要占位符。
- 同一命令同类错误失败 2 次就停并报告。

## 5. 本轮进度（每轮追加，不删旧记录）

- 2026-11-07：建 `AGENTS.md`；设 `upstream`（默认读）/`origin`（推送目标）远端。
- 2026-11-07：`daemon/` 落地（`xovd.c`、`xov-common.h`、四个 helper、`xov-cli`、三份 entitlements、
  launchd plist、`build.sh`、`README.md`、`APP-ENTITLEMENTS.md`、`client/XovXPC.swift`）。
  `daemon/build.sh` 本机真跑过：六个二进制 arm64+arm64e fat、ldid 签名可读回、
  `dpkg-deb` 产出 `com.xov.daemon_0.1.0_iphoneos-arm64.deb`（29 388 字节）。
  未装包、未加载、未 respring；`icli svc paths`/`bootstrap` 与 `xov-cli status` 的端到端未验证。
