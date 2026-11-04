// The app's side of the protocol. If appkitd is missing, slow or denied by the sandbox, these return
// NULL and the caller draws natively.

#ifndef LIONESS_CLIENT_H
#define LIONESS_CLIENT_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <CoreGraphics/CoreGraphics.h>
#include "../Shared/Protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

/// A CGImage of the control with LIONESS_PADDING points around it, owned by the cache: do not release.
/// Thread-safe. `status`, if given, receives Lion's result or the Mach error.
CGImageRef LionessCopyCachedImage(const LionessRequest *request, int *status);

/// A picture of AppKit's CoreUI options drawn by Lion's CUIDraw at width x height points, with
/// LIONESS_PADDING points around it. +1: release it. NULL if appkitd cannot answer, or Lion drew nothing.
CGImageRef LionessCopyDrawnImage(CFDictionaryRef options, uint32_t width, uint32_t height, uint32_t scale);

/// Whether appkitd can answer right now. Looks it up if due, so a sandbox or a stopped daemon reads false.
bool LionessIsReachable(void);

#ifdef __cplusplus
}
#endif

#endif
