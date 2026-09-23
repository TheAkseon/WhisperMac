#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned invalidated = 0;
static void keepalive_timer(CFRunLoopTimerRef timer, void *info) { (void)timer; (void)info; }
static void message_callback(CFMachPortRef port, void *message, CFIndex size, void *info) {
    (void)port; (void)message; (void)size; (void)info;
}
static void invalidation_callback(CFMachPortRef port, void *info) {
    (void)port; (void)info;
    invalidated++;
}
static unsigned live_receive_rights(mach_port_t *ports, unsigned count) {
    unsigned live = 0;
    for (unsigned i = 0; i < count; i++) {
        mach_port_type_t type = 0;
        if (mach_port_type(mach_task_self(), ports[i], &type) == KERN_SUCCESS && (type & MACH_PORT_TYPE_RECEIVE)) live++;
    }
    return live;
}
int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "legacy") && strcmp(argv[1], "invalidate"))) {
        fprintf(stderr, "Usage: %s legacy|invalidate\n", argv[0]); return 2;
    }
    const int explicit_invalidate = !strcmp(argv[1], "invalidate");
    mach_port_t native_ports[20] = {0};
    unsigned created = 0;
    for (unsigned i = 0; i < 20; i++) {
        CFMachPortContext context = {0, NULL, NULL, NULL, NULL};
        Boolean should_free_info = false;
        CFMachPortRef port = CFMachPortCreate(kCFAllocatorDefault, message_callback, &context, &should_free_info);
        if (!port) { fprintf(stderr, "CFMachPortCreate failed at%u\n", i); return 1; }
        CFMachPortSetInvalidationCallBack(port, invalidation_callback);
        native_ports[i] = CFMachPortGetPort(port);
        CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0);
        if (!source) { CFMachPortInvalidate(port); CFRelease(port); fprintf(stderr, "source create failed\n"); return 1; }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
        if (explicit_invalidate) CFMachPortInvalidate(port);
        CFRelease(source);
        CFRelease(port);
        created++;
    }
    printf("mode=%s created=%u invalidated_immediately=%u live_receive_rights_immediately=%u\n", argv[1], created, invalidated, live_receive_rights(native_ports, created));
    // Service CoreFoundation/main-queue cleanup without handling input or creating event taps.
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    CFRunLoopTimerRef keepalive = CFRunLoopTimerCreate(kCFAllocatorDefault, began + 10, 0, 0, 0, keepalive_timer, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), keepalive, kCFRunLoopDefaultMode);
    for (unsigned i = 0; i < 5; i++) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
    }
    printf("runloop_elapsed_seconds=%.3f\n", CFAbsoluteTimeGetCurrent() - began);
    CFRunLoopTimerInvalidate(keepalive);
    CFRelease(keepalive);
    printf("mode=%s invalidated_after_runloop=%u live_receive_rights_after_runloop=%u\n", argv[1], invalidated, live_receive_rights(native_ports, created));
    return 0;
}
