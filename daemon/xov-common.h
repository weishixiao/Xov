// xov-common.h —— 四个 helper 共用的定义（bootstrap 前缀解析、安全路径判定）
//
// 移植自 xosvi 的 Support/xosvi/xosvi-common.h；解析顺序与 daemon/xovd.c 的
// find_bootstrap() 逐字一致，两处必须同步改，否则 helper 会在另一种视图里找错根。
//
// 为什么需要它：roothide 下不同进程看到的「根」不同。helper 是 xovd（root 守护）
// fork 出来的，继承守护的视图：可能看见真根（/usr/... 直接可用），也可能看见
// AppGroup 里的 .jbroot-XXXX 共享视图。写死 /var/jb 在两边都会错—— xosvi 0.1.0
// 就是这么挂的（日志里 bootstrap=/var/jb，opendir 全部 ENOENT）。

#ifndef XOV_COMMON_H
#define XOV_COMMON_H

#define _DARWIN_C_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

/* 数据目录（真根视图下写死 /private/var 是对的：两者都指向同一个卷）。
 * App 侧必须先把这个目录建出来（owner mobile），否则 xov-build / xov-install
 * 会以「work root missing」失败。可用 -DXOV_DATA_DIR=\"...\" 覆盖。 */
#ifndef XOV_DATA_DIR
#define XOV_DATA_DIR "/private/var/mobile/Documents/wiki.xov"
#endif
#define XOV_WORK_ROOT XOV_DATA_DIR "/work"

typedef int (*xov_rootfs_fn)(char *, size_t);

static int xov_probe_prefix(const char *prefix) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/usr/bin/dash", prefix);
    return access(p, X_OK) == 0;
}

static int xov_exe_jbroot(char *out, size_t cap) {
    char buf[PATH_MAX];
    uint32_t sz = (uint32_t)sizeof(buf);
    if (_NSGetExecutablePath(buf, &sz) != 0) return 0;
    char *p = strstr(buf, "/.jbroot-");
    if (!p) return 0;
    char *end = strchr(p + 1, '/');
    if (!end) return 0;
    *end = '\0';
    snprintf(out, cap, "%s", buf);
    return 1;
}

static int xov_scan_base(const char *base, char *out, size_t cap) {
    DIR *d = opendir(base);
    if (!d) return 0;
    struct dirent *de;
    int found = 0;
    while ((de = readdir(d))) {
        if (strncmp(de->d_name, ".jbroot-", 8) != 0) continue;
        char cand[PATH_MAX];
        snprintf(cand, sizeof cand, "%s/%s", base, de->d_name);
        if (xov_probe_prefix(cand)) { snprintf(out, cap, "%s", cand); found = 1; break; }
    }
    closedir(d);
    return found;
}

/* 返回 bootstrap 前缀（真根为空串）；0 表示找不到。顺序：env → libroot → 可执行路径
 * → 扫描 → 真根，与 xovd.c 的 find_bootstrap() 完全一致。 */
static int xov_bootstrap(char *out, size_t cap) {
    const char *env = getenv("XOV_JBROOT");
    if (env && env[0] == '/' && xov_probe_prefix(env)) {
        snprintf(out, cap, "%s", env);
        return 1;
    }
    xov_rootfs_fn rootfs = (xov_rootfs_fn)dlsym(RTLD_DEFAULT, "rootfs_get_path");
    if (rootfs) {
        char root[PATH_MAX];
        if (rootfs(root, sizeof root) == 0 && root[0]) {
            const char *pre = strcmp(root, "/") ? root : "";
            if (xov_probe_prefix(pre)) { snprintf(out, cap, "%s", pre); return 1; }
        }
    }
    char exe[PATH_MAX];
    if (xov_exe_jbroot(exe, sizeof exe) && xov_probe_prefix(exe)) {
        snprintf(out, cap, "%s", exe);
        return 1;
    }
    const char *bases[] = { "/private/var/containers/Bundle/Application",
                            "/var/containers/Bundle/Application", NULL };
    for (int i = 0; bases[i]; i++) {
        char cand[PATH_MAX];
        if (xov_scan_base(bases[i], cand, sizeof cand)) {
            snprintf(out, cap, "%s", cand);
            return 1;
        }
    }
    if (xov_probe_prefix("")) { out[0] = '\0'; return 1; }
    out[0] = '\0';
    return 0;
}

/* <prefix><逻辑路径> */
static void xov_path(char *out, size_t cap, const char *prefix, const char *logical) {
    snprintf(out, cap, "%s%s", prefix, logical);
}

/* path 是否等于 root 或位于其下（两者都应是 realpath 结果）。 */
static int xov_inside(const char *path, const char *root) {
    size_t rl = strlen(root);
    if (rl == 0) return 0;
    if (strncmp(path, root, rl) != 0) return 0;
    return path[rl] == '/' || path[rl] == 0;
}

#endif
