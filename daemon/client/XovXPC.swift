import Foundation
import XPC
import Darwin

/// App 侧通往 root 守护 `xovd` 的 XPC 客户端（MachService `wiki.xov.service`）。
///
/// 移植自 xosvi 的 `Sources/XosviMCP/XosviXPC.swift`，只改了命名空间与文案：
/// `wiki.qaq.xosvi.*` → `wiki.xov.*`、`xosvid` → `xovd`、helper 名 → `xov-*`。
///
/// **这个文件尚未接进 `src/ios` 的 Xcode 工程**：本机没有 Xcode，编译不了 iOS App，
/// 所以它既没编译过也没跑过。接进去时要确认两件事：
///   1. target 里包含本文件，且 `import XPC` 可用（SDK 的 `usr/include/xpc` 在，
///      `libxpc` 由 `libSystem` 重导出）；
///   2. `xpc_connection_create_mach_service` 只能 dlsym 取（SDK 里标了 API_UNAVAILABLE(ios)）。
///
/// 协议（与 `daemon/xovd.c`、`daemon/xov-cli.c` 一致）：
///   请求 `{command: ping|status|helper, name, args:[String], timeout:Int, dryrun:Bool}`
///   回复 `{status, error, bootstrap, resolved, pid, uid, dash, helper, peer,
///          running_helpers, exit_code, stdout:Data, timed_out, truncated, busy, elapsed_ms}`
///
/// 编译约定（踩过的坑，改动时别退回去）：
///   * `xpc_connection_create_mach_service` 第二参数是 `dispatch_queue_t`，Swift 没有对应的
///     C 兼容名字，按指针（`UnsafeMutableRawPointer?`）传 NULL —— 走默认队列，语义不变。
///   * `XPC_TYPE_*` 是 `&_xpc_type_xxx` 这类宏，Swift 侧不一定能取；判断「是不是错误」
///     一律用错误字典里的 `XPCErrorDescription` 键，不碰类型常量。
///   * `XPC_ARRAY_APPEND` 是 `((size_t)(-1))` 宏，用 `Int(bitPattern: UInt.max)` 代替。
enum XovXPC {
    static let serviceName = "wiki.xov.service"
    /// 守护只接受带这个 entitlement 的客户端（见 daemon/xovd.c 的 peer_allowed）
    static let clientEntitlement = "wiki.xov.client"
    /// 守护允许的 helper 白名单，与 daemon/xovd.c 的 normalize_helper 一致
    static let allowedHelpers = ["xov-build", "xov-install", "xov-symbolicate", "xov-bin"]

    /// XPC_ERROR_KEY_DESCRIPTION 的字面值（xpc/xpc.h）：错误事件就是带这个键的字典。
    private static let errorKey = "XPCErrorDescription"
    /// XPC_ARRAY_APPEND == (size_t)-1
    private static let arrayAppend = Int(bitPattern: UInt.max)

    /// 通道层失败后的冷却闸门。
    ///
    /// 每次 `create_mach_service` 都要走一遍 libxpc 与 launchd 的回复路径，而 roothide 的
    /// basebin 替换了 `xpc_pipe_routine_reply` / `xpc_dictionary_create_reply`。一次注入/安装
    /// 会连着发好几条请求，第一条失败后剩下的直接返回 `skipped:true`，不再各打一次，
    /// 免得把触发面乘以步骤数。显式诊断（`root command:probe` 一类）用 `force` 穿透。
    private final class Gate {
        static let shared = Gate()
        let lock = NSLock()
        var until: Date?
        var reason: String?
    }

    /// 冷却时长：够覆盖一次注入/安装的全部步骤，又不至于让刚修好守护的用户等太久。
    static let cooldownSeconds: TimeInterval = 60

    /// 冷却剩余秒数；返回 nil 表示闸门开着（可打）。
    private static func cooldownLeft() -> (seconds: Int, reason: String)? {
        let g = Gate.shared
        g.lock.lock()
        defer { g.lock.unlock() }
        guard let until = g.until else { return nil }
        let left = Int(ceil(until.timeIntervalSinceNow))
        if left <= 0 {
            g.until = nil
            g.reason = nil
            return nil
        }
        return (left, g.reason ?? "未知")
    }

    private static func markChannelFailure(_ reason: String) {
        let g = Gate.shared
        g.lock.lock()
        g.until = Date().addingTimeInterval(cooldownSeconds)
        g.reason = reason
        g.lock.unlock()
    }

    private static func clearChannelFailure() {
        let g = Gate.shared
        g.lock.lock()
        g.until = nil
        g.reason = nil
        g.lock.unlock()
    }

    /// 闸门现状，`root command:status` 的 `xpc` 段里展示；只读，不改闸门。
    static func channelState() -> [String: Any] {
        if let (left, reason) = cooldownLeft() {
            return ["state": "cooldown", "cooldown_remaining": left, "last_error": reason]
        }
        return ["state": "ready"]
    }

    // 公共头把这两个符号标为 iOS 不可用，但运行时一直都在；按 dlsym 取。
    private typealias CreateMachFn = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?, UInt64) -> xpc_connection_t?

    private static let rtlDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static func createMach() -> CreateMachFn? {
        guard let fn = dlsym(rtlDefault, "xpc_connection_create_mach_service") else { return nil }
        return unsafeBitCast(fn, to: CreateMachFn.self)
    }

    /// 一次性把回复取回来的盒子：回调在 XPC 的连接队列上跑，主线程等信号量。
    ///
    /// 盒子里存的是**已经解析好的 Swift 字典**，不存 xpc 对象：reply 块拿到的对象只在这次
    /// 块调用期间有效，块一返回 libxpc 就回收；之后再 `xpc_dictionary_get_*` 是
    /// use-after-free（实测同一写法必崩，纯 C 复现是 SIGBUS，App 里是 EXC_GUARD /
    /// namespace LIBXPC / XPC_EXIT_REASON_FAULT）。所以解析一律在块里做完。
    private final class Box {
        var result: [String: Any]?
        var error: String?
        var done = false
    }

    private static func str(_ obj: xpc_object_t, _ key: String) -> String? {
        guard let p = xpc_dictionary_get_string(obj, key) else { return nil }
        return String(cString: p)
    }

    private static func replyDict(_ obj: xpc_object_t) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in ["status", "error", "bootstrap", "resolved", "dash", "helper", "peer"] {
            if let v = str(obj, key) { out[key] = v }
        }
        for key in ["pid", "uid", "exit_code", "running_helpers"] {
            if xpc_dictionary_get_value(obj, key) != nil {
                out[key] = Int(xpc_dictionary_get_int64(obj, key))
            }
        }
        if xpc_dictionary_get_value(obj, "elapsed_ms") != nil {
            out["elapsed_ms"] = xpc_dictionary_get_double(obj, "elapsed_ms")
        }
        if xpc_dictionary_get_bool(obj, "timed_out") { out["timed_out"] = true }
        if xpc_dictionary_get_bool(obj, "truncated") { out["truncated"] = true }
        if xpc_dictionary_get_bool(obj, "busy") { out["busy"] = true }
        var len = 0
        if let data = xpc_dictionary_get_data(obj, "stdout", &len), len > 0 {
            out["stdout"] = String(decoding: Data(bytes: data, count: len), as: UTF8.self)
        } else {
            out["stdout"] = ""
        }
        return out
    }

    /// 错误事件（含 Connection invalid / Interrupted）都是带 XPCErrorDescription 的字典；
    /// 正常回复没有这个键。返回 nil 表示「这不是错误」。
    private static func errorText(_ obj: xpc_object_t) -> String? {
        return str(obj, errorKey)
    }

    /// 发一条请求并等回复。
    /// - Parameter force: 穿透冷却闸门（只给显式诊断用）。
    /// - Returns: `ok:false` 时 `error` 是连接层的原因（创建失败 / 错误事件 / 超时 / 闸门冷却），
    ///            `ok:true` 时其余键来自守护返回的字典（可能仍带守护侧的 `error` 字段）。
    ///
    /// 连接是「一条请求一条连接，回完即 cancel」。超时后回调仍可能稍后到达，所以
    /// 取消与读取都在锁里做，`done` 只让第一个到者生效。
    static func request(_ message: [String: Any], timeout: Double, force: Bool = false) -> [String: Any] {
        if !force, let (left, reason) = cooldownLeft() {
            return ["ok": false,
                    "error": "xovd 通道冷却中（\(left)s 后可重试）：\(reason)",
                    "skipped": true,
                    "cooldown_remaining": left,
                    "hint": "上次 create_mach_service 已失败，冷却期内不再碰 libxpc；显式诊断可立即重试。"]
        }
        guard let create = createMach() else {
            markChannelFailure("libxpc 缺 xpc_connection_create_mach_service")
            return ["ok": false, "error": "libxpc 缺 xpc_connection_create_mach_service"]
        }
        let made: xpc_connection_t? = serviceName.withCString { name in
            create(name, nil, 0)
        }
        guard let conn = made else {
            markChannelFailure("xpc_connection_create_mach_service 返回 NULL")
            return ["ok": false, "error": "xpc_connection_create_mach_service(\(serviceName)) 返回 NULL"]
        }

        let box = Box()
        let lock = NSLock()
        let sem = DispatchSemaphore(value: 0)

        /// 回调里交付结果：只有第一个到者生效；超时后到的直接丢掉。
        /// 参数必须已经是从 xpc 对象里读出来的 Swift 值 —— 对象不能跨块保存（见 Box 注释）。
        func deliver(_ result: [String: Any]?, _ err: String?) {
            lock.lock()
            if box.done { lock.unlock(); return }
            box.result = result
            box.error = err
            box.done = true
            lock.unlock()
            sem.signal()
        }

        // 非监听连接的事件回调只会收到错误事件；没有错误描述也不能当成回复。
        xpc_connection_set_event_handler(conn) { event in
            deliver(nil, errorText(event) ?? "xpc 事件未带描述")
        }
        xpc_connection_resume(conn)

        let msg = xpc_dictionary_create(nil, nil, 0)
        for (k, v) in message {
            switch v {
            case let s as String: xpc_dictionary_set_string(msg, k, s)
            case let i as Int: xpc_dictionary_set_int64(msg, k, Int64(i))
            case let b as Bool: xpc_dictionary_set_bool(msg, k, b)
            case let a as [String]:
                let arr = xpc_array_create(nil, 0)
                for s in a { xpc_array_set_string(arr, arrayAppend, s) }
                xpc_dictionary_set_value(msg, k, arr)
            default: break
            }
        }

        // 发送也走同一个连接；连接不可用时这里常常是**同步**回调错误事件。
        // 解析必须在这个块里做完（块外对象已回收，见 Box 注释）。
        xpc_connection_send_message_with_reply(conn, msg, nil) { reply in
            if let e = errorText(reply) { deliver(nil, e) } else { deliver(replyDict(reply), nil) }
        }

        let waited = sem.wait(timeout: .now() + timeout)

        lock.lock()
        let finished = box.done
        if !box.done { box.done = true }           // 超时：先占位，之后到的回调一律丢弃
        let result = box.result
        let err = box.error
        lock.unlock()

        // 无论成功、失败还是超时都取消连接：取消后 libxpc 会立刻停掉回调，不留悬挂引用。
        xpc_connection_cancel(conn)

        if waited == .timedOut && !finished {
            return ["ok": false, "error": "等待 xovd 回复超时（\(Int(timeout))s）",
                    "hint": "守护已把 helper 移出监听队列；长时间无回复通常是命令本身还在跑（例如安装/构建）。先看 status 的 running_helpers，再等或缩短命令。"]
        }
        if result == nil, let e = err {
            markChannelFailure(e)
            return ["ok": false, "error": "xovd 不可达：\(e)",
                    "hint": "服务 \(serviceName) 未在 launchd 注册或被拒。先 icli svc status wiki.xov.xovd 看 daemon 状态；守护需在 system 域加载（icli svc bootstrap），客户端要带 \(clientEntitlement)。"]
        }
        guard var out = result else {
            return ["ok": false, "error": "xovd 没有返回字典"]
        }
        // 真的收到守护的字典 = 通道通着，把可能残留的冷却清掉。
        clearChannelFailure()
        out["ok"] = true
        return out
    }

    // MARK: - 便捷封装

    static func ping(timeout: Double = 5) -> [String: Any] {
        request(["command": "ping"], timeout: timeout)
    }

    /// `status` 回复里的 `uid` 应为 0、`status` 为 `OK`，`helper`/`dash` 为 `ok`。
    static func serviceStatus(timeout: Double = 5, force: Bool = false) -> [String: Any] {
        request(["command": "status"], timeout: timeout, force: force)
    }

    /// 调一个 helper。`args` 的第一项必须是项目目录（守护侧的要求，且必须落在工作根内）。
    /// - Parameter force: 穿透冷却闸门（只给显式诊断用）。
    static func helper(_ name: String, args: [String], timeout: Int,
                       dryrun: Bool = false, force: Bool = false) -> [String: Any] {
        var msg: [String: Any] = ["command": "helper", "name": name, "args": args]
        if timeout > 0 { msg["timeout"] = timeout }
        if dryrun { msg["dryrun"] = true }
        // 客户端等待要比守护侧的超时更长，否则先超时的永远是客户端
        return request(msg, timeout: Double(max(timeout, 30)) + 10, force: force)
    }

    /// 编译/打包：`xov-build <项目目录> [脚本]`。
    static func build(projectDir: String, script: String? = nil, timeout: Int = 300,
                      dryrun: Bool = false) -> [String: Any] {
        var args = [projectDir]
        if let s = script { args.append(s) }
        return helper("xov-build", args: args, timeout: timeout, dryrun: dryrun)
    }

    /// 安装产物：`xov-install <项目目录> <产物路径>`。
    static func install(projectDir: String, artifact: String, timeout: Int = 300,
                        dryrun: Bool = false) -> [String: Any] {
        helper("xov-install", args: [projectDir, artifact], timeout: timeout, dryrun: dryrun)
    }

    /// 符号化：`xov-symbolicate <项目目录> <dSYM 或项目> <崩溃报告>`（参数细节见 helper 的 usage）。
    static func symbolicate(projectDir: String, args: [String], timeout: Int = 120,
                            dryrun: Bool = false) -> [String: Any] {
        helper("xov-symbolicate", args: [projectDir] + args, timeout: timeout, dryrun: dryrun)
    }

    // SecTask 是私有 API（公开 SDK 不导出）。这里不用 @_silgen_name：那两个符号在别处可能
    // 已被声明成实例方法，Swift 会当成多带一个 self 的 C 函数，一调用就报 convention mismatch。
    // 按 dlsym + @convention(c) 取，参数全用裸指针，ABI 与 C 侧一致。
    private typealias SecTaskCreateFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias SecTaskCopyFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer,
                                                      UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

    private static let secTaskCreateFn: SecTaskCreateFn? = {
        guard let p = dlsym(rtlDefault, "SecTaskCreateFromSelf") else { return nil }
        return unsafeBitCast(p, to: SecTaskCreateFn.self)
    }()

    private static let secTaskCopyFn: SecTaskCopyFn? = {
        guard let p = dlsym(rtlDefault, "SecTaskCopyValueForEntitlement") else { return nil }
        return unsafeBitCast(p, to: SecTaskCopyFn.self)
    }()

    /// 本进程是否带客户端 entitlement（带不上时守护会直接 cancel 连接，表现为错误事件）。
    static func hasClientEntitlement() -> Bool {
        guard let createTask = secTaskCreateFn, let copyValue = secTaskCopyFn else { return false }
        guard let task = createTask(nil) else { return false }
        defer { Unmanaged<AnyObject>.fromOpaque(task).release() }

        // 先把 CFString 桥接出来**绑在局部变量上**：`clientEntitlement as CFString` 是临时对象，
        // 直接 passUnretained 会拿到已释放的指针（栈上野指针），SecTaskCopyValueForEntitlement
        // 内部 objc_msgSend 取 objectForKey 时就炸了 —— 这是实测过的崩溃点。
        // 这里用 passRetained，并在 defer 里配对释放，指针在整个调用期间有效。
        let cfKey = clientEntitlement as CFString
        let key = UnsafeMutableRawPointer(Unmanaged.passRetained(cfKey).toOpaque())
        defer { Unmanaged<CFString>.fromOpaque(key).release() }
        guard let raw = copyValue(task, key, nil) else { return false }
        // +1 由 takeRetainedValue 收下，交给 ARC 释放；CFBoolean 与 Bool 免费桥接
        let value = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
        return (value as? Bool) ?? false
    }
}
