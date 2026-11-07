# App 侧要点：TrollStore 签名要叠加哪些 entitlements

`xovd` 是 root 守护，只能由 deb 装进系统域。App（`Xov.app`）永远只是**客户端**：
它带 `wiki.xov.client` 去连 `wiki.xov.service`，自己不持有 root，也不装任何守护。

## 必须叠加的 key

App 用 TrollStore 签名时，可执行文件里要带下面这些（缺哪条，症状都不一样）：

| key | 值 | 缺了会怎样 |
| --- | --- | --- |
| `platform-application` | `true` | TrollStore 安装时本来就会加；手动签名时漏了会拿不到 platform 域待遇，部分 mach 服务查不到 |
| `com.apple.private.security.no-sandbox` | `true` | 沙箱内 `xpc_connection_create_mach_service("wiki.xov.service")` 直接 `Connection invalid` |
| `com.apple.private.security.container-required` | `false` | 强制要求容器，App 读不到 `/var/mobile/Documents/wiki.xov` |
| `com.apple.private.security.no-container` | `true` | 同上，两者配套 |
| `com.apple.security.exception.files.absolute-path.read-write` | `["/"]` | 写不进工作根、读不到 `/var/log/xovd.log`，排障全靠猜 |
| `com.apple.private.launchservices.mach-services` | `["wiki.xov.service"]` | 向 launchd 查/连这个服务可能被拒；写上是低成本保险 |
| `wiki.xov.client` | `true` | **守护会直接 cancel 连接**，日志一行 `peer rejected … (no wiki.xov.client)` |

参考文件（App 侧的最小集，不含 helper 用的 container-manager / `task_for_pid`）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>platform-application</key>
	<true/>
	<key>com.apple.private.security.no-sandbox</key>
	<true/>
	<key>com.apple.private.security.no-container</key>
	<true/>
	<key>com.apple.private.security.container-required</key>
	<false/>
	<key>com.apple.security.exception.files.absolute-path.read-write</key>
	<array>
		<string>/</string>
	</array>
	<key>com.apple.private.launchservices.mach-services</key>
	<array>
		<string>wiki.xov.service</string>
	</array>
	<key>wiki.xov.client</key>
	<true/>
</dict>
</plist>
```

签名（在打包/交给 TrollStore 之前把 entitlements 打进可执行文件）：

```sh
ldid -SApp.entitlements Xov.app/Xov
ldid -e Xov.app/Xov | grep -c wiki.xov.client   # 期望 >=1
```

TrollStore 安装时会用 ldid 重签，并强制加 `platform-application` / `no-sandbox`；
**二进制里已有的** entitlements 会被保留 —— 所以 `wiki.xov.client` 必须像上面那样先打进去，
不能指望安装器替你加。App 每次覆盖安装都会被重签，同一份 `App.entitlements` 要跟着发。

> 这一节是 TrollStore 的通用做法（推断），本机没有 TrollStore，也没装过这个 App。

## 为什么 App 自己装不了 LaunchDaemon

1. **目录写不进去**：launchd 只从 system 域的 `/Library/LaunchDaemons` 读 plist（roothide 上
   是 `<jbroot>/Library/LaunchDaemons`），该目录属 `root:wheel`、权限 0755；App 以 `mobile`
   身份运行，连创建文件都不行。
2. **登记要 root**：把 plist 装进 system 域是 `launchctl bootstrap system <plist>` 这类操作，
   `icli svc bootstrap` 也一样 —— 帮助文本第一句就是 "Service changes require root and the
   launchd privileges granted by your jailbreak"。App 进程没有 root，TrollStore 只负责
   「让 amfi 放行签名」，它不发 root。
3. **特权守护必须由系统装**：`xovd` 要 `MachServices`、无沙盒、绝对路径读写，这些只有在
   system 域常驻的进程才成立；App 内嵌的副本即使能 exec，也在 App 的沙箱与生命周期里，
   随 App 退出而消失，注入类工具需要的那种「App 被杀后仍能收尾」的 root 上下文就没有了。
4. 因此分工是固定的：**deb 装守护 + plist，App 只当客户端**。App 若真需要 root 动作，
   一律通过 `XovXPC`（`daemon/client/XovXPC.swift`）发请求，不在 App 内自己提权。

备选方案（不采用）：App 内嵌特权辅助、每次注入时借用户已装的其它 root 工具拉起 —— 引入
不可控的外部依赖，且失败时诊断链路会跨三四个进程。

## 不要顺手加的东西

`task_for_pid-allow`、`com.apple.private.security.storage.AppBundles`、
`MobileContainerManager.*`、`vfs.open-by-id` 这些是给 helper（`xov-bin` 跑注入工具）用的，
App 自己不需要。App 带这些只会扩大签名面，且出问题时更难判断是哪一层的权限在拦。
