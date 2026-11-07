# daemon/ — xovd root 守护

Xov 的 root 能力入口：一个 launchd 按需拉起的 XPC 守护 `xovd`，加四个白名单 helper。
移植自 xosvi 的 `tools/xosvid.c` + `tools/xosvi-*`，只保留 XPC 一条通道（不复活
`/var/tmp` 文件轮询与 UDS 两条历史方案）。

## 命名空间

| 名字 | 值 |
| --- | --- |
| XPC MachService | `wiki.xov.service` |
| launchd label | `wiki.xov.xovd` |
| 守护二进制 | `/usr/libexec/xovd` |
| helper 目录 | `/usr/libexec/xov/`（`xov-build`、`xov-install`、`xov-symbolicate`、`xov-bin`） |
| 客户端 entitlement | `wiki.xov.client` |
| 日志 | `/var/log/xovd.log`（守护自己也写 `<bootstrap>/var/log/xovd.log`，同一 inode 只写一遍） |
| 包 | `com.xov.daemon` |
| 数据目录 | `/var/mobile/Documents/wiki.xov`（`work/` 是构建工作区） |

## 文件

| 文件 | 作用 |
| --- | --- |
| `xovd.c` | 守护：监听 `wiki.xov.service`、校验 peer、跑 helper、串行/并发队列分离、900s 空闲自退 |
| `xov-common.h` | 四个 helper 共用：bootstrap 前缀解析、`<prefix><逻辑路径>` 拼接、路径包含判定。解析顺序与 `xovd.c` 的 `find_bootstrap()` **逐字一致**（env → libroot → 可执行路径 → 扫描 → 真根），改一处必须同步另一处 |
| `xov-build.c` | 工程目录里跑构建脚本：cwd 限定在工作根内，`/bin/sh` 按实测视图选 |
| `xov-install.c` | 装 ipa/deb 类产物：路径必须先落进工作根，再交给 `ipainstaller`/dpkg |
| `xov-symbolicate.c` | 用 dSYM 符号化崩溃报告 |
| `xov-bin.c` | 以 root 跑 `Xov.app/bin` 里的注入工具（`ldid cp rm mv insert_dylib optool install_name_tool ct_bypass teamid opainject` 白名单），`sign` 子命令用自身签名里的 entitlements 重签工具 |
| `xov-cli.c` | 命令行客户端（`ping` / `status` / `helper` / `call`），装到 `/usr/bin/xov-cli` |
| `xovd.entitlements` | 守护签名：`platform-application`、无沙盒、绝对路径读写、`mach-services=wiki.xov.service` |
| `bin-entitlements.plist` | 四个 helper 签名：container-manager、`vfs.open-by-id`、`task_for_pid-allow`、`jb.pmap_cs.custom_trust` |
| `xov-cli.entitlements` | 客户端签名：无沙盒 + `wiki.xov.client` |
| `wiki.xov.xovd.plist` | launchd 描述（逻辑路径，roothide 由加载器改写成 jbroot 路径） |
| `build.sh` | 编译 + ldid 签名 + 打 `com.xov.daemon` 的 deb |
| `client/XovXPC.swift` | App 侧客户端（同一协议），**尚未接进 Xcode 工程**，见文末 |

## 构建

```sh
APELIN_PROJECT_ROOT="$(pwd)" \
APELIN_PACKAGE_DIR="$(mktemp -d -p "$TMPDIR")" \
APELIN_ARCHITECTURE=iphoneos-arm64e \
APELIN_PREFIX= \
bash daemon/build.sh
```

`build.sh` 只读环境变量：`APELIN_PROJECT_ROOT`、`APELIN_PACKAGE_DIR`、`APELIN_ARCHITECTURE`、
`APELIN_PREFIX`（**必须定义**，roothide 上是空串、rootless 上是 `/var/jb`）、`TMPDIR`，
缺一个就退出；可选 `APELIN_BOOTSTRAP`（只记进日志）、`XOV_VERSION`（默认 `0.1.0`）、
`XOV_MAINTAINER`。`apelin-project.json` 的 `external.script` 指向本脚本，
`apelin_project_build` 就是这么调它的（那时 `APELIN_ARCHITECTURE` 是 `iphoneos-arm64e`）。

包内路径 = `$APELIN_PREFIX` + 逻辑路径；rootless 打包时脚本把 `/var/jb` 前缀补到 plist 的
`ProgramArguments` 上，仓库里的 plist 永远只有逻辑路径。

四条硬规矩写在脚本头里：编译全部在 `$(mktemp -d -p "$TMPDIR")` 里用相对路径做（roothide 下
绝对路径的 `-o` 会静默不落地）、不写死 `.jbroot-XXXX`、包内不用 launchd 不认的占位符、
不安装不加载不 respring。

**本机实测（已验）**：`apelin_project_build` 跑通（build `1be7635f`，约 12s），产出
`…/Builds/…/package/com.xov.daemon_0.1.0_iphoneos-arm64e.deb`
（sha256 `0459feed8d8b…`，29 KB 量级）；包内含 `/usr/libexec/xovd`、`/usr/libexec/xov/` 四个
helper、`/usr/bin/xov-cli`、`/Library/LaunchDaemons/wiki.xov.xovd.plist`；
六个二进制都是 `arm64 + arm64e` fat，`ldid -e` 能读回各自的 entitlements；
`icli svc paths` 对该 plist 的预览把 `ProgramArguments[0]` 改写成
`<jbroot>/usr/libexec/xovd`、两个日志路径改写成 `<jbroot>/var/log/xovd.log`。

## 安装与验证

> 本会话**没有**装包、没有加载、没有 respring（项目硬约束，装包/加载需要用户明确点头）。
> 下面是给设备上执行的流程；`icli svc paths` 的预览结果已实测，其余端到端结果未验证。

1. 装包：把 `com.xov.daemon_*_iphoneos-arm64.deb` 交给设备上的包管理器（Sileo / irisin）。
   `postinst` 会建 `/var/mobile/Documents/wiki.xov/work`、建 `/var/log/xovd.log`，不改系统设置。
2. 找 plist（roothide 上装在 jbroot 里）：

   ```sh
   ls -d /private/var/containers/Bundle/Application/.jbroot-*/Library/LaunchDaemons/wiki.xov.xovd.plist
   ```

3. 先预览 launchd 实际会打开的路径（只读）：

   ```sh
   icli svc paths --human <jbroot>/Library/LaunchDaemons/wiki.xov.xovd.plist
   ```

   roothide 上 `written` 是 `/usr/libexec/xovd`，`launchd` 应显示改写到 jbroot 下的同一条路径；
   如果不一致，`hint` 会给出该写什么。
4. 加载（需要 root；`icli svc bootstrap` 会在加载前把 plist 里的路径就地改写成 jbroot 路径）：

   ```sh
   icli svc bootstrap --human <jbroot>/Library/LaunchDaemons/wiki.xov.xovd.plist
   ```
5. 验证：

   ```sh
   xov-cli status
   ```

   期望至少两行：

   ```
   status: OK
   uid: 0
   ```

   完整回复还带 `bootstrap`（前缀解析走的第几条路）、`resolved`、`pid`、`dash`、
   `helper`、`peer`、`running_helpers`。`dash` / `helper` 任一是 `missing` 说明
   前缀解析落到了错误视图，看 `/var/log/xovd.log` 第一行 `bootstrap='…' via=…`。

   `xov-cli ping` 不查 bootstrap，只证明通道通；`xov-cli status` 才有 `uid: 0`。

## XPC 协议

请求字典：

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `command` | string | `ping` / `status` / `helper`（缺省按 `status`） |
| `name` | string | `helper` 用：`xov-build` 或短名 `build`，归一后必须在白名单内 |
| `args` | [string] | `helper` 用：**第一项必须是项目目录**（限制在工作根内），其余原样传给 helper |
| `timeout` | int | helper 超时秒数，守护侧上限 |
| `dryrun` | bool | 只回解析结果，不执行 |

回复字典：`status`、`error`、`bootstrap`、`resolved`、`pid`、`uid`、`dash`、`helper`、
`peer`、`running_helpers`、`exit_code`、`stdout`（Data）、`timed_out`、`truncated`、`busy`、`elapsed_ms`。

失败三态要分清：`exit_code` 非 0（helper 跑了但失败）、`error`（守护拒绝/参数不合法）、
客户端侧 `ok:false`（通道层：服务没加载、被 entitlement 拒、超时）。

## 安全模型

- 客户端必须带 `wiki.xov.client`（`peer_allowed()` 判），否则连接被直接 `cancel`，日志里记一行
  `peer rejected … (no wiki.xov.client)`。
- 只执行 `/usr/libexec/xov/` 下的四个白名单 helper；没有「跑任意命令」的入口。
- helper 的参数由守护侧再校验一遍：项目目录必须 realpath 在工作根内，`Xov.app/bin` 下的工具
  必须 realpath 在 `Xov.app/bin` 内且文件名在白名单里。
- 守护以 root 常驻，自己**不带** `wiki.xov.client`。

## 运行期行为

- 常驻形态：plist 写了 `RunAtLoad=true` + `KeepAlive=true`，开机即起、退出立刻补。
- 因为常驻，plist 用 `EnvironmentVariables.XOVD_IDLE_SECS=0` 显式关掉空闲自退
  （`xovd` 里 0 = 常驻；不设或设正数仍是默认 900s）。否则守护每 900s 退一次、launchd
  马上再拉起，日志里刷重启记录。要回到「按需拉起」：删掉 `RunAtLoad`/`KeepAlive`/
  `EnvironmentVariables` 三块，守护恢复 900s 自退，没有请求就没有进程。
- 有 helper 在跑时即使开了自退也不退（续一个周期再查）。排障时把 `XOVD_IDLE_SECS` 调成几秒。
- 每个连接一条请求：客户端回完即 `cancel`，守护侧不 retain 也不 cancel 连接。

## 排错

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| `xov-cli` 报 `xovd 不可达` / `Connection invalid` | 服务没在 launchd 注册 | `icli svc bootstrap` 加载；`icli svc status wiki.xov.xovd` 看状态 |
| `peer rejected` | 客户端没带 `wiki.xov.client` | 用签名过的 `xov-cli`，或给 App 重打 entitlements（见 `APP-ENTITLEMENTS.md`） |
| `status: OK` 但 `dash: missing` | 前缀解析落到错误视图 | 看日志首行 `bootstrap='…' via=…`；必要时设 `XOV_JBROOT` |
| `work root missing` | 数据目录没建 | `mkdir -p /var/mobile/Documents/wiki.xov/work && chown -R mobile:mobile /var/mobile/Documents/wiki.xov` |
| helper `timed_out: true` | 命令真的跑太久 | 看 `running_helpers`，加大 `timeout` |

## 尚未验证 / 属推断

- **已验（本机）**：`apelin_project_build` 出包、包内容、entitlements 读回、`icli svc paths`
  的路径改写预览（`ProgramArguments[0]` → `<jbroot>/usr/libexec/xovd`）。
- **已验（本机，2026-11-07 20:24）**：`apelin_package_install` 装上 `com.xov.daemon 0.1.0`
  （installation `4f413aa3…`）→ `icli svc bootstrap` 返回 `loaded: true / running: true`、
  pid 2432 → `xov-cli status` 输出 `status: OK` / `uid: 0` / `dash: ok` / `helper: ok`
  → `xov-cli helper xov-build --exec /tmp 'id -u'` 经守护得 `uid=0`（同一 helper 直接以
  mobile 跑是 `uid=501`）。日志里 `idle exit disabled (XOVD_IDLE_SECS=0)` 说明常驻形态生效。
- **未验证**：helper 真正以 root 执行注入类工具的完整链路（需要设备上的一次真实注入）。
- **已修并已验（2026-11-07 20:34）**：早期版本在 `xpc_connection_has_bool_entitlement` 拿不到时
  **放行**（roothide 的 libxpc 确实没有这个符号），等于 root 守护对任何进程开放。现在
  `peer_allowed` 走三级降级且 **fail-closed**：`xpc_connection_has_bool_entitlement` →
  `xpc_connection_copy_entitlement_value` → 拒绝（只有显式 `XOVD_ALLOW_ANY_PEER=1` 才放行，
  排障用，会写日志）。启动日志记 `peer check via …`，本机实测走的是
  `xpc_connection_copy_entitlement_value`。
  负向/正向都验过：不带 entitlement 的 ad-hoc 客户端得到 `Connection interrupted`（rc=3），
  守护记 `peer rejected … (no wiki.xov.client)`；同一个程序带 `xov-cli.entitlements` 签名后
  得到 `reply: status=OK`（rc=0）；`xov-cli status` 仍 `status: OK / uid: 0`。
- **未验证**：`XOVD_ALLOW_ANY_PEER=1` 这条排障开关本身（没有为它改 plist 重载）。
- **已验**：roothide 下 launchd 通过路径改写找到 `<jbroot>/usr/libexec/xovd` ——
  `icli svc paths` 预览出 `<jbroot>/usr/libexec/xovd`，`icli svc bootstrap` 后
  `program` 正是该真实路径且 `running: true`。
- **推断**：`/var/mobile`、`/var/log` 在两种 bootstrap 视图下都指向真根，所以守护与 postinst
  直接写这两个绝对路径。
- `client/XovXPC.swift` 是照 `Sources/XosviMCP/XosviXPC.swift` 改名的移植，**没有**加进
  `src/ios` 的 Xcode 工程，本机也构建不了 iOS App，所以它既没编译过也没跑过。接进去时要做的：
  在 target 里加文件、确认 `import XPC` 可用（`xpc_connection_create_mach_service` 只能 dlsym）、
  把 `XovXPC.serviceName` 当常量用。
