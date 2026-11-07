/* dlopen 验收：确认 ct_bypass 签名过的 dylib 能否在进程里被 dyld 接受
 * 用法：./dlopen_test <dylib path> */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <dylib>\n", argv[0]); return 2; }
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) {
        fprintf(stderr, "dlopen FAILED: %s\n", dlerror());
        return 1;
    }
    printf("dlopen OK: %p\n", h);
    dlclose(h);
    return 0;
}