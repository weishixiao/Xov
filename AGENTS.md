# Xov — 工作上下文（每轮从这里恢复）

> 本文件由用户指定写入，内容是会话的权威上下文。任何新会话先读本文件，再动手。

## 1. 项目背景

把 OpenMinis 二次开发成 xosvi 的形态。仓库已克隆在项目根（182 MB，`src/ios/` 是 iOS 端，Swift/SwiftUI；`src/android/` 是 Kotlin/Compose；`deps/`、`scripts/`、`docs/specs/`）。GPL-3.0，`LICENSE` 原样保留。

用户已拍板五项：

1. 底座保留 Minis（工程骨架、agent 引擎、provider 抽象、iSH 沙盒、技能与记忆）不动。
2. 搬 xosvi 的能力（约 50 个原生工具：App 管理、注入、抓包、SQLite 取证、包解剖、内存、设备、文件）。
3. **UI 逐页改造**（2026-11-07 用户改口，取代原「UI 先不做」）：抽屉的会话列表**保留 Minis 的行为**
   （数据源、排序分组、文件夹、拖拽、右键菜单、搜索高亮、Face ID 锁定、运行/暂停标记），**只换视觉**；
   其余页面逐个按 xosvi 的 DeepSeek 白/近黑中性底改造，公共 token 落 `src/ios/Views/ContentView/XTheme.swift`。
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
- `src/ios/Views` 只改视觉、不动行为：抽屉会话列表的数据流、手势、菜单、锁定、搜索逻辑一律保留。
- 不构建 iOS App（本机没有 Xcode/Go/macOS），不要声明构建成功。
- 结论区分「已查证 / 推断」；给真实路径，不要占位符。
- 同一命令同类错误失败 2 次就停并报告。

## 5. 本轮进度（每轮追加，不删旧记录）

- 2026-11-07：建 `AGENTS.md`；设 `upstream`（默认读）/`origin`（推送目标）远端。
- 2026-11-07：`daemon/` 首批移植提交 `d27bd44`，已推到 `origin/main`
  （`1a71df0 → d27bd44`，`git ls-remote` 核对远端一致）。
- 2026-11-07：`daemon/` 落地（`xovd.c`、`xov-common.h`、四个 helper、`xov-cli`、三份 entitlements、
  launchd plist、`build.sh`、`README.md`、`APP-ENTITLEMENTS.md`、`client/XovXPC.swift`）。
  `daemon/build.sh` 本机真跑过：六个二进制 arm64+arm64e fat、ldid 签名可读回、
  `dpkg-deb` 产出 `com.xov.daemon_0.1.0_iphoneos-arm64.deb`（29 388 字节）。
  未装包、未加载、未 respring；`icli svc paths`/`bootstrap` 与 `xov-cli status` 的端到端未验证。
- 2026-11-07：外部构建接通。`apelin-project.json` 补 `external.script=daemon/build.sh`
  （interpreter bash）；`build.sh` 改为强制读 `APELIN_PROJECT_ROOT`/`APELIN_PACKAGE_DIR`/
  `APELIN_ARCHITECTURE`/`APELIN_PREFIX`/`TMPDIR`，包内路径 = prefix + 逻辑路径，rootless 时
  把 `/var/jb` 补到 plist 的 `ProgramArguments`；plist 改成常驻（`RunAtLoad`+`KeepAlive`+
  `XOVD_IDLE_SECS=0`，`xovd` 认 0 = 关自退），仍有 `Library/LaunchDaemons/wiki.xov.xovd.plist`。
  `apelin_project_build` 成功：build `1be7635f`，产物
  `…/Apelin/Builds/<pid>/1be7635f…/package/com.xov.daemon_0.1.0_iphoneos-arm64e.deb`
  （sha256 `0459feed8d8b8ee5ce6fef98301cda57feb5de63466b2c574da0fd0c07d51f92`，29 KB 量级）。
  `icli svc paths` 预览已验：`ProgramArguments[0]` → `<jbroot>/usr/libexec/xovd`、
  日志 → `<jbroot>/var/log/xovd.log`。
  仍**未**装包/加载（第 4 节硬约束；协作会话要求验收，需用户明确点头才做）。
- 2026-11-07 20:24：用户同意后端到端验收通过。`apelin_package_install` 装 `com.xov.daemon 0.1.0`
  （installation `4f413aa3-8c25-42b1-a640-143ff7307914`）→ `icli svc bootstrap <jbroot>/Library/LaunchDaemons/wiki.xov.xovd.plist`
  返回 `loaded: true / running: true`（pid 2432）→ `<jbroot>/usr/bin/xov-cli status`：
  `status: OK`、`uid: 0`、`dash: ok`、`helper: ok`；`xov-cli helper xov-build --exec /tmp 'id -u'`
  经守护得 `uid=0`（直接以 mobile 跑同一条是 `uid=501`）。日志 `/var/log/xovd.log` 有
  `idle exit disabled (XOVD_IDLE_SECS=0)`。
  **发现的缺口**：roothide 的 libxpc 无 `xpc_connection_has_bool_entitlement`，守护每次连接都
  记 WARN 并放行 —— `wiki.xov.client` 实际未被校验，任何进程都能驱动 root 守护跑白名单 helper。
  待修（SecTask 兜底 + 不带 entitlement 的负向测试），未动代码。
- 2026-11-07 20:34：该缺口已修。`xovd.c` 的 `peer_allowed` 改三级降级 + fail-closed：
  `xpc_connection_has_bool_entitlement` → `xpc_connection_copy_entitlement_value`（本机走这条，
  启动日志 `peer check via …`）→ 都没有则拒绝，只有 `XOVD_ALLOW_ANY_PEER=1` 才放行（排障用）。
  重出包（build `0a7e848b`，sha256 `c30e8eab…`）→ 装（installation `474aa0e1…`）→
  `icli svc bootout`/`bootstrap` 重载（新 pid 4176）。
  验证：`$TMPDIR` 里编的同一 XPC 客户端 `ldid -S`（无 entitlement）→ `Connection interrupted`
  rc=3，守护记 `peer rejected … (no wiki.xov.client)`；`ldid -S daemon/xov-cli.entitlements`
  副本 → `reply: status=OK` rc=0；`xov-cli status` 仍 OK/uid 0。
  未验证：`XOVD_ALLOW_ANY_PEER=1` 开关本身；注入类 helper 的完整链路。
- 2026-11-07 22:30：**白描真实 dylib 注入打通（已查证）**。放弃 `opainject` 的 ROP 路线
  （root 下卡在 `[createRemotePthread] Created bootstrap thread... now waiting on finish`，
  mobile 下 `[spawnPacChild] Failed to obtain task port: 5`；两者均不可用），改走 roothide 自带的
  **TweakInject**：`/usr/lib/TweakInject/wiki.xov.inject.dylib`（thin arm64 探针，root:wheel 755）
  + `wiki.xov.inject.plist`（`Filter → Bundles = (com.uzero.ocrrec)`）。
  重启白描后 App 容器 `Documents/xov-probe.log` 落盘
  `XOVPROBE via=dyld-ctor pid=27446 uid=501 home=/private/var/mobile/Containers/Data/Application/740FDEBA-…`，
  即进程内真实执行到我们 dylib 的 constructor。os_log 子系统 `wiki.xov.inject`。
  探针源码留在 `daemon/test/`（`inject_probe.c`、`dlopen_test.c`），构建产物不进仓库。
  遗留：白描包内 `Frameworks/libxovinject.dylib`（早前覆盖的 arm64 副本）与
  `/var/mobile/xovinj/` 暂存目录仍在，未删（删包外文件需单独点头）。
  另：`jbctl trustcache add` 静默 rc=0，`trustcache info` 条目数未见增长（78 条），
  即 TweakInject 的加载并不依赖它 —— 该命令是否真的写入未查证。
- 2026-11-07 23:05：新增 `.github/workflows/ios-app.yml`（iOS App → 未签名 .ipa）。
  `macos-26` 上按 BUILDING.md 固定顺序跑五个 deps 脚本（原生产物走 `actions/cache` 精确 key，
  hit 则整段跳过，并有一步 `Verify the native dependencies` 兜住残缺缓存），随后
  `xcodebuild archive`（`CODE_SIGNING_ALLOWED=NO` / `CODE_SIGNING_REQUIRED=NO`，正好让
  strip 阶段跳过 codesign），`ditto` + `zip -y` 打成 `Minis-<version>-<build>-unsigned.ipa`，
  连同 `Minis-dSYMs.zip` 上传（30 天）。Xcode 钉 26.6 并带 SDK ≥26.2 的守卫；
  Metal 工具链 `continue-on-error` 下载（缺了 FFmpeg 会静默丢 `yadif_videotoolbox`）。
  同时把 `src/ios/Configs/ProviderCustomization.xcconfig` 加进 `.gitignore`（只跟踪 `.example`）。
  **未验证**：本机无 Xcode/Go/macOS，工作流从未跑过；YAML 只做了缩进/制表符/行尾的结构检查
  （设备上没有 actionlint/python/ruby/node）。单元测试不进工作流 —— `MinisTests` 要模拟器，
  而 deps 只产出 device arm64 切片。artifact 里的 .ipa 仍需 `ldid -S` 按
  `daemon/APP-ENTITLEMENTS.md` 签名才能装。
- 2026-11-07 23:40：UI 开工（用户改口，见第 1 节第 3 条）。
  新增 `src/ios/Views/ContentView/XTheme.swift`（照搬 xosvi 的 DeepSeek token：白/近黑底、
  `rowSelected`、`hairline`、DeepSeek 蓝、行字号 15/13/12、34pt 头像、圆角 10）。
  `Views/ContentView/Sidebar/SessionRow.swift` 换成 xosvi 的细描边环形头像 + 15 medium 标题 +
  13 摘要 + 12 时间，间距 8→12；`RemoteSessionRow` 同步。行为层未动（Equatable、徽章、
  锁定模糊、搜索高亮、`scaledApp` 动态字号、按压样式全部保留）。
  **未验证**：本机无 Swift 编译器/Xcode，只做了括号平衡与制表符检查；要等 CI 出包才算编译通过。
- 2026-11-07 23:40：模型 API 模块的依赖测绘（照搬可行性）。xosvi 侧只有
  `Sources/XosviMCP` 一个扁平目录（185 个 Swift 文件）；`OpenAIClient`(1909) + `Models`(2899) +
  `ProviderDirectory`(966) + `GatewayClient`(204) 共 5 978 行，不是独立模块：它们引用另外 37 个
  外部类型（`StreamingProjection`/`ProjectedBlock`/`ToolRegistry`/`Workspace`/`ReasoningWriter`/
  `MCPCore` 里的 `ToolDefinition`/`KeychainStore`/`AuditLog`/`ChatView`…），即 xosvi 自己的
  agent 引擎、工具层、流式投影与 MCP 核心。与 Minis 冲突的类型只有 `ChatMessage` 一个。
  Minis 侧已有 `src/ios/Providers/`：`LLMProvider`/`LLMProviderFactory`/`LLMError`、
  OpenAI/Anthropic/Gemini/Kimi/xAI/OpenRouter/Copilot/Antigravity 八家、`ModelEntry`、
  `ModelsDevAPI`（模型目录）、`ModelGroupRouter`、`OAuthRefreshCoordinator`。
  结论（推断）：整模块照搬 = 把 xosvi 的引擎一起搬进来，与「保留 Minis agent 引擎/provider 抽象」
  冲突；待用户确认走「传输层照搬」还是「连引擎一起换」。
  **未查证**：哪几个具体 API 行为是用户真正要的（多 provider 网关？自建中转？）。
