#ifndef HIDAcceleration_h
#define HIDAcceleration_h

/// Copies the live trackpad tracking speed into `outSpeed`.
/// Returns 0 on success. The value is the same 0...3 scale System Settings uses.
int SketchIntentCopyTrackpadAcceleration(double *outSpeed);

#endif
