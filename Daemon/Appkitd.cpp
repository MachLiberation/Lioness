// The daemon: checks in the Mach service, then runs Lion's HIToolbox and AppKit under the engine, on this
// thread, inside Guest/Renderer.m. launchd owns the service name (Package/com.lioness.appkitd.plist).
//
//   appkitd <ml-root>

#include "Runtime.h"
#include "Jit.h"
#include "../Shared/Protocol.h"
#include <bootstrap.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <stdio.h>
#include <unistd.h>

// Not in any public header. Without the extension, a sandboxed app's lookup of the service is denied.
extern "C" char *sandbox_extension_issue_mach(const char *extension_class, const char *name, uint32_t flags);

// Written where a sandboxed app can read it: the token grants lookup of this one service and nothing else.
static void PublishSandboxToken(void) {
    char *token = sandbox_extension_issue_mach(LIONESS_TOKEN_CLASS, LIONESS_SERVICE, 0);
    if (!token) { fprintf(stderr, "appkitd: no sandbox extension: sandboxed apps will draw natively\n"); return; }
    char temporary[256];
    snprintf(temporary, sizeof temporary, "%s.new", LIONESS_TOKEN_PATH);
    FILE *f = fopen(temporary, "w");
    if (!f) { fprintf(stderr, "appkitd: cannot write %s\n", temporary); free(token); return; }
    fputs(token, f);
    fclose(f);
    chmod(temporary, 0644);
    rename(temporary, LIONESS_TOKEN_PATH);
    free(token);
    fprintf(stderr, "appkitd: sandbox token published\n");
}

static void OnFault(int signal, siginfo_t *info, void *context) {
    if (Lioness::JitFixFault(context, Lioness::CurrentGuest())) return;   // a read of the commpage from translated code
    fprintf(stderr, "appkitd: host signal %d at address %p\n", signal, info->si_addr);
    if (Lioness::Cpu *guest = Lioness::CurrentGuest()) Lioness::DumpGuest(*guest, "host fault");
    _exit(128 + signal);   // launchd starts a new one; the apps draw natively until it is back
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: appkitd <ml-root>\n"); return 2; }

    mach_port_t port = MACH_PORT_NULL;
    // APPKITD_TEST_SERVICE: register under this name instead, leaving the installed service's token alone.
    const char *testService = getenv("APPKITD_TEST_SERVICE");
    kern_return_t kr;
    if (testService) {
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
        mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
        kr = bootstrap_register(bootstrap_port, (char *)testService, port);
    } else kr = bootstrap_check_in(bootstrap_port, LIONESS_SERVICE, &port);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "appkitd: cannot check in %s: %s (start it with Scripts/Appkitd.sh)\n", LIONESS_SERVICE, bootstrap_strerror(kr));
        return 1;
    }

    if (!testService) PublishSandboxToken();

    struct sigaction sa = {};
    sa.sa_sigaction = OnFault;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);

    char portText[32];
    snprintf(portText, sizeof portText, "LIONESS_PORT=%#x", port);

    Lioness::GuestConfig config;
    config.root = argv[1];
    config.trace = getenv("APPKITD_TRACE") != NULL;
    config.executable = "/usr/libexec/lioness/renderer";
    config.arguments = { config.executable };
    config.environment = { "PATH=/usr/bin:/bin", "HOME=/var/root", "TMPDIR=/tmp/", portText };
    return Lioness::RunGuest(config);
}
