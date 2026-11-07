/* xov injection probe — 注入链路验证用的最小 dylib
 * 只做两件事：进程被加载时写 os_log，并在 HOME 可写时追加一行日志。 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <os/log.h>

static void xov_log(const char *where) {
    os_log_t lg = os_log_create("wiki.xov.inject", "probe");
    os_log(lg, "XOVPROBE loaded via %{public}s pid=%d uid=%d", where,
           (int)getpid(), (int)getuid());
    const char *home = getenv("HOME");
    char path[512];
    snprintf(path, sizeof path, "%s/Documents/xov-probe.log", home ? home : "/tmp");
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return;
    char buf[256];
    int n = snprintf(buf, sizeof buf, "XOVPROBE via=%s pid=%d uid=%d home=%s\n",
                     where, (int)getpid(), (int)getuid(), home ? home : "-");
    if (n > 0) write(fd, buf, (size_t)n);
    close(fd);
}

__attribute__((constructor)) static void xov_probe_init(void) {
    xov_log("dyld-ctor");
}