#include "HIDAcceleration.h"

#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDShared.h>

int SketchIntentCopyTrackpadAcceleration(double *outSpeed) {
    if (outSpeed == NULL) {
        return 1;
    }
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching(kIOHIDSystemClass)
    );
    if (service == IO_OBJECT_NULL) {
        return 2;
    }
    io_connect_t handle = IO_OBJECT_NULL;
    kern_return_t openResult = IOServiceOpen(service, mach_task_self(), kIOHIDParamConnectType, &handle);
    IOObjectRelease(service);
    if (openResult != KERN_SUCCESS) {
        return 3;
    }
    double speed = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    kern_return_t readResult = IOHIDGetAccelerationWithKey(handle, CFSTR("HIDTrackpadAcceleration"), &speed);
#pragma clang diagnostic pop
    IOServiceClose(handle);
    if (readResult != KERN_SUCCESS) {
        return 4;
    }
    *outSpeed = speed;
    return 0;
}
