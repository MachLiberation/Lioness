// Client-side Mach bridge from any app (including sandboxed apps, XPC helpers, Dock,
// DockHelper, MenuBarAgent, Spotlight/Siri AI) to lionessmenud.

#ifndef LIONESS_MENU_CLIENT_H
#define LIONESS_MENU_CLIENT_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns YES if com.lioness.menud is currently reachable.
BOOL LionessMenuServerIsReachable(void);

/// Presents a serialized menu dictionary in lionessmenud and returns the reply dictionary
/// (blocking cleanly until the user picks an item, switches menu bar title, or dismisses).
/// Returns nil if lionessmenud is unreachable or an IPC error occurs.
NSDictionary *LionessMenuPresent(NSDictionary *request);

/// Asynchronously dismisses any active menu shown by lionessmenud.
void LionessMenuDismiss(void);

/// Asks lionessmenud to toggle (action=0), show (action=1), or dismiss (action=2) LionessSpotlight.
BOOL LionessMenuTriggerSpotlight(uint32_t action);

#ifdef __cplusplus
}
#endif

#endif // LIONESS_MENU_CLIENT_H
