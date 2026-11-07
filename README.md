# Xov

Minis 的二次开发版：把 xosvi 的系统级能力搬进 Minis 的骨架里，走 TrollStore 分发。

> An experimental fork of [OpenMinis](https://github.com/OpenMinis/OpenMinis).

## 是什么

- **底座是 Minis**：agent 引擎、provider 抽象、iSH 沙盒、技能与记忆，原样保留。
- **加上 xosvi 的原生工具**：App 管理、注入、抓包、SQLite 取证、包解剖、内存、设备、文件。
- **工具协议重写**：用自己的协议，不保留 MCP JSON-RPC 层。
- **分发走 TrollStore**：保留特权 entitlements 与 root XPC 守护。

**状态：早期。** 界面仍是 Minis 原样，xosvi 的 UI 尚未搬入。

## 目录

| 路径 | 内容 |
|---|---|
| `src/ios/` | iOS App（Swift / SwiftUI） |
| `src/android/` | Android App（Kotlin / Compose） |
| `daemon/` | root 守护 `xovd`（XPC `wiki.xov.service`）与白名单 helper |
| `deps/` | 原生依赖构建脚本（LAME、FFmpeg、iSH、rclone） |
| `docs/specs/` | 架构与接口规格 |

## 构建

Linux 沙盒和原生依赖都要从源码编，完整说明见 [BUILDING.md](BUILDING.md)。

顺序固定，FFmpeg 要链接 LAME：

```sh
./deps/build_lame.sh   && ./deps/build_ffmpeg.sh
./deps/build_ish.sh    && ./deps/prepare_alpine_rootfs.sh
./deps/build_rclone_ios.sh
open src/ios/Minis.xcodeproj
```

- **CI**：`.github/workflows/ios-app.yml` 在 macOS runner 上跑同一套流程，产出未签名 `.ipa`。装机前按 [daemon/APP-ENTITLEMENTS.md](daemon/APP-ENTITLEMENTS.md) 用 `ldid` 签名。
- **root 守护**：`daemon/build.sh` 产出 `com.xov.daemon` 包，安装与验证见 [daemon/README.md](daemon/README.md)。

## 许可

[GPL-3.0](LICENSE)。上游是 [OpenMinis](https://github.com/OpenMinis/OpenMinis)，系统能力参考 xosvi；第三方组件与许可证见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。
