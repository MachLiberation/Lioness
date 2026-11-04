// What the kernel's execve does for an x86-64 Mach-O, done in the host process: map the main executable
// and dyld, build the initial stack, point the CPU at dyld. Lion's own dyld, executed by the engine,
// loads everything else through the syscall layer.

#include "Runtime.h"
#include "Jit.h"
#include <fcntl.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>
#include <map>
#include <set>
#include <mutex>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

namespace Lioness {

const GuestConfig *gConfig;

constexpr uint64_t kHostPage = 0x4000;
static std::mutex gMemoryLock;
static std::map<uint64_t, uint64_t> gOwned;   // start -> end, host-page aligned, merged
static uint64_t gNextAnywhere = 0x7f0000000000ull;

static bool OwnedLocked(uint64_t page) {
    auto it = gOwned.upper_bound(page);
    if (it == gOwned.begin()) return false;
    --it;
    return page < it->second;
}

static std::set<uint64_t> gKeptFree;

static void AddOwnedLocked(uint64_t start, uint64_t end) {
    auto it = gOwned.upper_bound(start);
    if (it != gOwned.begin()) {
        auto prev = std::prev(it);
        if (prev->second >= start) { start = prev->first; end = std::max(end, prev->second); gOwned.erase(prev); }
    }
    while (it != gOwned.end() && it->first <= end) { end = std::max(end, it->second); it = gOwned.erase(it); }
    gOwned[start] = end;
}

bool GuestMap(uint64_t address, size_t length) {
    if (address >> 47 || length > (1ull << 36)) {
        fprintf(stderr, "lioness: refused mapping of %#zx bytes at %#llx\n", length, address);
        return false;
    }
    std::lock_guard<std::mutex> lock(gMemoryLock);
    uint64_t start = address & ~(kHostPage - 1), end = (address + length + kHostPage - 1) & ~(kHostPage - 1);
    // Freed pages that were kept mapped can simply be used again.
    for (uint64_t page = start; page < end; page += kHostPage) {
        auto kept = gKeptFree.find(page);
        if (kept == gKeptFree.end()) continue;
        gKeptFree.erase(kept);
        memset((void *)page, 0, kHostPage);
        AddOwnedLocked(page, page + kHostPage);
    }
    // In one piece where it can be: a memory entry made on this range (how a guest shares memory with another process) only covers one VM object.
    bool free = true;
    for (uint64_t page = start; page < end && free; page += kHostPage) free = !OwnedLocked(page);
    if (free) {
        mach_vm_address_t whole = start;
        if (mach_vm_allocate(mach_task_self(), &whole, end - start, VM_FLAGS_FIXED) == KERN_SUCCESS) {
            AddOwnedLocked(start, end);
            return true;
        }
    }
    for (uint64_t page = start; page < end; page += kHostPage) {
        if (OwnedLocked(page)) continue;
        // Never MAP_FIXED: vm_allocate without ANYWHERE fails rather than clobbering the host's memory.
        mach_vm_address_t at = page;
        kern_return_t kr = mach_vm_allocate(mach_task_self(), &at, kHostPage, VM_FLAGS_FIXED);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "lioness: cannot map guest page %#llx: %s\n", page, mach_error_string(kr));
            return false;
        }
        AddOwnedLocked(page, page + kHostPage);
    }
    return true;
}

uint64_t GuestMapAnywhere(size_t length) {
    // A wild size must not move the next free address: every later allocation would fail with it.
    if (!length || length > (1ull << 36)) {
        fprintf(stderr, "lioness: refused anywhere-mapping of %#zx bytes\n", length);
        return 0;
    }
    length = (length + kHostPage - 1) & ~(kHostPage - 1);
    uint64_t at;
    {
        std::lock_guard<std::mutex> lock(gMemoryLock);
        at = gNextAnywhere;
        gNextAnywhere += length + kHostPage;
    }
    return GuestMap(at, length) ? at : 0;
}

bool GuestOverlaps(uint64_t address, size_t length) {
    std::lock_guard<std::mutex> lock(gMemoryLock);
    uint64_t start = address & ~(kHostPage - 1), end = (address + length + kHostPage - 1) & ~(kHostPage - 1);
    for (uint64_t page = start; page < end; page += kHostPage) if (OwnedLocked(page)) return true;
    return false;
}

void GuestZero(uint64_t address, size_t length) { memset((void *)address, 0, length); }

bool GuestOwns(uint64_t address, size_t length) {
    std::lock_guard<std::mutex> lock(gMemoryLock);
    uint64_t start = address & ~(kHostPage - 1), end = (address + length + kHostPage - 1) & ~(kHostPage - 1);
    for (uint64_t page = start; page < end; page += kHostPage)
        if (!OwnedLocked(page)) return false;
    return true;
}

// Whole host pages are released; a partial 4 KB unmap can only be zeroed, and stays mapped.
void GuestUnmap(uint64_t address, size_t length) {
    JitNoteUnmap(address, length);
    if (GuestOwns(address, length)) GuestZero(address, length);
    uint64_t start = (address + kHostPage - 1) & ~(kHostPage - 1), end = (address + length) & ~(kHostPage - 1);
    if (start >= end) return;
    std::lock_guard<std::mutex> lock(gMemoryLock);
    for (uint64_t page = start; page < end; page += kHostPage) {
        if (!OwnedLocked(page)) continue;
        mach_vm_deallocate(mach_task_self(), page, kHostPage);
        auto it = std::prev(gOwned.upper_bound(page));
        uint64_t s = it->first, e = it->second;
        gOwned.erase(it);
        if (s < page) gOwned[s] = page;
        if (page + kHostPage < e) gOwned[page + kHostPage] = e;
    }
}

std::string HostPath(const char *path) {
    if (path[0] != '/' || !gConfig) return path;
    // In the guest's world /var, /tmp and /etc are links into /private, as on a real Mac, and its code uses either spelling.
    if (!strncmp(path, "/private/var/", 13) || !strncmp(path, "/private/tmp/", 13) || !strncmp(path, "/private/etc/", 13)) path += 8;
    std::string rooted = gConfig->root + path;
    struct stat st;
    if (stat(rooted.c_str(), &st) == 0) return rooted;
    // Lion's own trees resolve only inside the root: a host library must never answer for a Lion one.
    // /var and /Library too: the guest's state files live there.
    static const char *const lion[] = { "/System/", "/usr/lib/", "/usr/share/", "/bin/", "/sbin/", "/Library/",
                                        "/var/", "/private/var/", "/etc/", "/private/etc/" };
    for (const char *prefix : lion)
        if (strncmp(path, prefix, strlen(prefix)) == 0) return rooted;
    return path;
}

struct Image {
    uint64_t base = 0, slide = 0, entry = 0;
    bool hasEntry = false;
    std::string dylinker;
};

static bool LoadImage(const std::string &path, uint64_t wantedSlide, Image &out) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) { fprintf(stderr, "lioness: cannot open %s\n", path.c_str()); return false; }
    mach_header_64 header;
    if (pread(fd, &header, sizeof header, 0) != sizeof header || header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_X86_64) {
        fprintf(stderr, "lioness: %s is not a thin x86-64 Mach-O\n", path.c_str());
        close(fd);
        return false;
    }
    std::vector<uint8_t> commands(header.sizeofcmds);
    pread(fd, commands.data(), commands.size(), sizeof header);
    out.slide = wantedSlide;

    const uint8_t *p = commands.data();
    for (uint32_t i = 0; i < header.ncmds; i++) {
        const load_command *lc = (const load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const segment_command_64 *seg = (const segment_command_64 *)p;
            if (seg->vmsize && strcmp(seg->segname, "__PAGEZERO") != 0) {
                uint64_t at = seg->vmaddr + wantedSlide;
                if (!GuestMap(at, seg->vmsize)) { close(fd); return false; }
                if (seg->filesize && pread(fd, (void *)at, seg->filesize, seg->fileoff) != (ssize_t)seg->filesize) {
                    fprintf(stderr, "lioness: short read of %s %s\n", path.c_str(), seg->segname);
                    close(fd);
                    return false;
                }
                if (!strcmp(seg->segname, "__TEXT") && header.filetype == MH_DYLINKER) PatchHostCalls(fd, 0, (uint8_t *)at, seg->filesize, seg->vmaddr);
                if (seg->fileoff == 0) out.base = at;
                if (!strcmp(seg->segname, "__TEXT")) JitAddText(at, seg->filesize);
            }
        } else if (lc->cmd == LC_UNIXTHREAD) {
            // flavor, count, then x86_thread_state64_t: rip is the 17th register.
            const uint64_t *state = (const uint64_t *)(p + sizeof(thread_command) + 8);
            out.entry = state[16] + wantedSlide;
            out.hasEntry = true;
        } else if (lc->cmd == LC_LOAD_DYLINKER) {
            const dylinker_command *dl = (const dylinker_command *)p;
            out.dylinker = (const char *)p + dl->name.offset;
        }
        p += lc->cmdsize;
    }
    close(fd);
    return true;
}

int RunGuest(const GuestConfig &config) {
    gConfig = &config;
    SetupCommpage();
    RegisterHostCalls();

    // The main image cannot use its linked address: 0x100000000 is where the host's own image sits. It
    // is PIE, so it goes high and dyld rebases it, exactly as for a kernel-chosen slide.
    Image main;
    if (!LoadImage(HostPath(config.executable.c_str()), 0x7e0000000000ull - 0x100000000ull, main)) return 127;
    if (main.dylinker.empty()) { fprintf(stderr, "lioness: no dyld named in %s\n", config.executable.c_str()); return 127; }

    Image dyld;
    if (!LoadImage(HostPath(main.dylinker.c_str()), 0, dyld) || !dyld.hasEntry) return 127;

    // The stack, below dyld at Lion's own address, 8 MB as the default limit.
    constexpr uint64_t kStackTop = 0x7fff5fc00000ull, kStackSize = 8 * 1024 * 1024;
    if (!GuestMap(kStackTop - kStackSize, kStackSize)) return 127;

    // The strings first, then from the bottom up: mh, argc, argv..., 0, envp..., 0, apple..., 0.
    uint64_t sp = kStackTop;
    auto pushString = [&](const std::string &s) {
        sp -= s.size() + 1;
        memcpy((void *)sp, s.c_str(), s.size() + 1);
        return sp;
    };
    uint64_t execPath = pushString(config.executable);
    std::vector<uint64_t> argv, envp;
    for (const auto &a : config.arguments) argv.push_back(pushString(a));
    for (const auto &e : config.environment) envp.push_back(pushString(e));
    sp &= ~15ull;
    size_t words = 2 + argv.size() + 1 + envp.size() + 1 + 2;   // mh argc ... apple[0] null
    sp -= words * 8;
    sp &= ~15ull;
    uint64_t *w = (uint64_t *)sp;
    *w++ = main.base;
    *w++ = argv.size();
    for (uint64_t a : argv) *w++ = a;
    *w++ = 0;
    for (uint64_t e : envp) *w++ = e;
    *w++ = 0;
    *w++ = execPath;
    *w++ = 0;

    Cpu cpu{};
    cpu.r[RSP] = sp;
    cpu.rip = dyld.entry;
    cpu.mxcsr = 0x1f80;
    cpu.fpuControl = 0x37f;
    cpu.pfByte = 1;
    int status = Run(cpu);
    if (config.trace) fprintf(stderr, "lioness: main thread done, %llu instructions\n", cpu.instructions);
    return status;
}

} // namespace Lioness
