// The SYSCALL instruction. x86-64 Darwin puts the class in the top byte of rax: 1 Mach trap, 2 BSD,
// 3 machine-dependent. Numbers carry over to the arm64 kernel, so most calls go straight through with
// `svc #0x80` (arm64 takes the BSD number positive and the Mach trap negative in x16). The rest are
// handled here because a Lion binary would otherwise reach something the host owns: its paths, its
// page size, its signal handlers, its threads, the shared region. Call semantics are from XNU's
// bsd/kern and the stubs in Lion's libsystem_kernel.

#include "IOKit.h"
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <unordered_map>
#include "Runtime.h"
#include "Jit.h"
#include <dirent.h>
#include <fcntl.h>
#include <string>
#include <vector>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

namespace Lioness {

static const uint64_t kCarry = 1ull << 29;

struct RawResult { uint64_t x0, x1; bool carry; };

static RawResult RawSyscall(int64_t number, const uint64_t a[8]) {
    register uint64_t x0 __asm__("x0") = a[0], x1 __asm__("x1") = a[1], x2 __asm__("x2") = a[2], x3 __asm__("x3") = a[3];
    register uint64_t x4 __asm__("x4") = a[4], x5 __asm__("x5") = a[5], x6 __asm__("x6") = a[6], x7 __asm__("x7") = a[7];
    register int64_t x16 __asm__("x16") = number;
    uint64_t flags;
    __asm__ volatile("svc #0x80\n mrs %[flags], nzcv"
                     : "+r"(x0), "+r"(x1), [flags] "=r"(flags)
                     : "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x6), "r"(x7), "r"(x16)
                     : "memory", "cc", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x17");
    return { x0, x1, (flags & kCarry) != 0 };
}

static pthread_mutex_t gPfzLock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t gTimeOrigin;

uint64_t GuestTicks() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - gTimeOrigin; }

// Offsets are the ones Lion's libsystem and dyld read.
void SetupCommpage() {
    gTimeOrigin = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - 1000000000ull;
    uint8_t *page = gCommpage;
    memset(page, 0, sizeof gCommpage);
    memcpy(page, "commpage 64-bit", 16);
    *(uint16_t *)(page + 0x1e) = 11;   // version
    int cpus = 0; size_t size = sizeof cpus;
    sysctlbyname("hw.logicalcpu", &cpus, &size, NULL, 0);
    if (cpus <= 0) cpus = 1;
    if (cpus > 32) cpus = 32;
    // MMX SSE SSE2 SSE3 cache64 fastTLS SSSE3 64bit, and the CPU count: what cpuid says too.
    uint32_t capabilities = 0x1 | 0x2 | 0x4 | 0x8 | 0x20 | 0x80 | 0x100 | 0x200 | ((uint32_t)cpus << 16);
    *(uint32_t *)(page + 0x20) = capabilities;
    page[0x22] = (uint8_t)cpus;
    page[0x34] = page[0x35] = page[0x36] = (uint8_t)cpus;
    uint64_t memory = 0; size = sizeof memory;
    sysctlbyname("hw.memsize", &memory, &size, NULL, 0);
    *(uint64_t *)(page + 0x38) = memory;
    // Nanotime: RDTSC returns nanoseconds, so (tsc << 1) * 0x80000000 >> 32 is the identity. A nonzero
    // generation marks it valid. The gettimeofday data stays at generation 0, which sends Lion's libc to
    // the real system call.
    *(uint64_t *)(page + 0x50) = 0;            // tsc base
    *(uint32_t *)(page + 0x58) = 0x80000000u;  // scale
    *(uint32_t *)(page + 0x5c) = 1;            // shift
    *(uint64_t *)(page + 0x60) = 0;            // ns base
    *(uint32_t *)(page + 0x68) = 1;            // generation
}

// The preemption-free-zone routines. The real ones are code in the commpage that the kernel will not
// preempt; a lock around plain reads and writes gives the same atomicity against each other.
bool CommpageCall(Cpu &c) {
    uint64_t offset = c.rip - kCommpageBase;
    auto ret = [&] { c.rip = *(uint64_t *)c.r[RSP]; c.r[RSP] += 8; };
    switch (offset) {
        case 0x1c00: {   // OSAtomicFifoEnqueue: rdi list {head, tail}, rsi new, rdx link offset
            pthread_mutex_lock(&gPfzLock);
            uint64_t *list = (uint64_t *)c.r[RDI];
            *(uint64_t *)(c.r[RSI] + c.r[RDX]) = 0;
            if (list[1]) *(uint64_t *)(list[1] + c.r[RDX]) = c.r[RSI];
            else list[0] = c.r[RSI];
            list[1] = c.r[RSI];
            pthread_mutex_unlock(&gPfzLock);
            ret();
            return true;
        }
        case 0x1c80: {   // OSAtomicFifoDequeue: rdi list, rdx link offset, rax result
            pthread_mutex_lock(&gPfzLock);
            uint64_t *list = (uint64_t *)c.r[RDI];
            uint64_t head = list[0];
            if (head) {
                uint64_t next = *(uint64_t *)(head + c.r[RDX]);
                list[0] = next;
                if (!next) list[1] = 0;
            }
            c.r[RAX] = head;
            pthread_mutex_unlock(&gPfzLock);
            ret();
            return true;
        }
        default:
            return false;
    }
}

static uint64_t gThreadStart, gWqThreadStart;

struct NewThread { Cpu cpu; pthread_t host; volatile mach_port_t port; volatile int ready; };

static void *ThreadMain(void *arg) {
    NewThread *t = (NewThread *)arg;
    t->port = pthread_mach_thread_np(pthread_self());
    __atomic_store_n(&t->ready, 1, __ATOMIC_RELEASE);
    while (__atomic_load_n(&t->ready, __ATOMIC_ACQUIRE) != 2) sched_yield();
    t->cpu.r[RSI] = t->port;
    Run(t->cpu);
    delete t;
    return NULL;
}

// From bsdthread_create in XNU's pthread_synch.c.
static uint64_t BsdThreadCreate(Cpu &c, uint64_t func, uint64_t arg, uint64_t stack, uint64_t pthread, uint32_t flags) {
    constexpr uint32_t kCustom = 0x01000000;
    uint64_t threadStack, threadSelf, stackField = stack;
    if (flags & kCustom) {
        threadStack = stack;
        threadSelf = pthread;
    } else {
        constexpr uint64_t kGuard = 0x4000, kSelfSize = 0x4000;
        uint64_t size = (stack + 0x3fff) & ~0x3fffull;
        uint64_t map = GuestMapAnywhere(kGuard + size + kSelfSize);
        if (!map) return 0;
        threadStack = map + kGuard + size;
        threadSelf = threadStack;
    }
    NewThread *t = new NewThread{};
    t->cpu.mxcsr = 0x1f80; t->cpu.fpuControl = 0x37f; t->cpu.pfByte = 1;
    t->cpu.rip = gThreadStart;
    t->cpu.r[RDI] = threadSelf;
    t->cpu.r[RDX] = func;
    t->cpu.r[RCX] = arg;
    t->cpu.r[R8] = stackField;
    t->cpu.r[R9] = flags;
    t->cpu.r[RSP] = threadStack - 128;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, 1024 * 1024);
    if (pthread_create(&t->host, &attr, ThreadMain, t) != 0) { pthread_attr_destroy(&attr); delete t; return 0; }
    pthread_attr_destroy(&attr);
    while (__atomic_load_n(&t->ready, __ATOMIC_ACQUIRE) != 1) sched_yield();
    __atomic_store_n(&t->ready, 2, __ATOMIC_RELEASE);
    return threadSelf;
}

// The kernel workqueue, which Mountain Lion's libdispatch cannot run without. Each requested thread starts in the guest's
// _pthread_wqthread with the registers of setup_wqthread in XNU's pthread_synch.c. WQOPS_THREAD_RETURN parks it rather than ending
// it, as the guest's thread list has links inside its stack mapping, and the next request restarts it with `reuse`.
// Flags are what _pthread_wqthread tests: 0x40000 new SPI, 0x20000 reuse, 0x10000 overcommit, low 16 priority.
struct ParkedWorker { pthread_cond_t wake; bool assigned; uint32_t flags; };
static pthread_mutex_t gWorkerLock = PTHREAD_MUTEX_INITIALIZER;
static std::vector<ParkedWorker *> gParkedWorkers;
static thread_local uint64_t tWorkerMap;
static constexpr uint64_t kWorkerGuard = 0x4000, kWorkerStack = 0x80000, kWorkerSelf = 0x4000;

static void *WorkerMain(void *arg) {
    NewThread *t = (NewThread *)arg;
    tWorkerMap = t->cpu.r[RDX] - kWorkerGuard;
    t->cpu.r[RSI] = pthread_mach_thread_np(pthread_self());
    Run(t->cpu);
    delete t;
    return NULL;
}

static void ParkWorker(Cpu &c) {
    ParkedWorker me{};
    pthread_cond_init(&me.wake, NULL);
    pthread_mutex_lock(&gWorkerLock);
    gParkedWorkers.push_back(&me);
    while (!me.assigned) pthread_cond_wait(&me.wake, &gWorkerLock);
    pthread_mutex_unlock(&gWorkerLock);
    pthread_cond_destroy(&me.wake);
    uint64_t self = tWorkerMap + kWorkerGuard + kWorkerStack;
    c.rip = gWqThreadStart;
    c.r[RDI] = self;
    c.r[RSI] = pthread_mach_thread_np(pthread_self());
    c.r[RDX] = tWorkerMap + kWorkerGuard;
    c.r[RCX] = 0;
    c.r[R8] = 0x40000 | 0x20000 | (me.flags & 0x1ffff);
    c.r[R9] = 0;
    c.r[RSP] = self - 128;
}

static bool StartWorker(uint32_t priorityAndOvercommit) {
    pthread_mutex_lock(&gWorkerLock);
    if (!gParkedWorkers.empty()) {
        ParkedWorker *worker = gParkedWorkers.back();
        gParkedWorkers.pop_back();
        worker->flags = priorityAndOvercommit;
        worker->assigned = true;
        pthread_cond_signal(&worker->wake);
        pthread_mutex_unlock(&gWorkerLock);
        return true;
    }
    pthread_mutex_unlock(&gWorkerLock);
    uint64_t map = GuestMapAnywhere(kWorkerGuard + kWorkerStack + kWorkerSelf);
    if (!map) return false;
    NewThread *t = new NewThread{};
    t->cpu.mxcsr = 0x1f80; t->cpu.fpuControl = 0x37f; t->cpu.pfByte = 1;
    t->cpu.rip = gWqThreadStart;
    uint64_t self = map + kWorkerGuard + kWorkerStack;
    t->cpu.r[RDI] = self;
    t->cpu.r[RDX] = map + kWorkerGuard;
    t->cpu.r[RCX] = 0;
    t->cpu.r[R8] = 0x40000 | (priorityAndOvercommit & 0x1ffff);
    t->cpu.r[R9] = 0;
    t->cpu.r[RSP] = self - 128;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, 1024 * 1024);
    int failed = pthread_create(&t->host, &attr, WorkerMain, t);
    pthread_attr_destroy(&attr);
    if (failed) { GuestUnmap(map, kWorkerGuard + kWorkerStack + kWorkerSelf); delete t; return false; }
    return true;
}

void GuestExit(Cpu &c, int code) { c.exitCode = code; c.running = false; }

static char *GuestPath(uint64_t address, std::string &storage) {
    storage = HostPath((const char *)address);
    return (char *)storage.c_str();
}

// Where guest code came from, for naming addresses in a crash dump.
struct CodeImage { uint64_t start, end; std::string path; };
static pthread_mutex_t gCodeImagesLock = PTHREAD_MUTEX_INITIALIZER;
static std::vector<CodeImage> gCodeImages;

std::string GuestAddressName(uint64_t address) {
    pthread_mutex_lock(&gCodeImagesLock);
    std::string name;
    for (const CodeImage &image : gCodeImages) {
        if (address < image.start || address >= image.end) continue;
        char offset[32];
        snprintf(offset, sizeof offset, "+%#llx", address - image.start);
        size_t slash = image.path.rfind('/');
        name = (slash == std::string::npos ? image.path : image.path.substr(slash + 1)) + offset;
        break;
    }
    pthread_mutex_unlock(&gCodeImagesLock);
    return name;
}

static bool Mmap(Cpu &c, uint64_t &result, int &error) {
    uint64_t address = c.r[RDI], length = c.r[RSI];
    int prot = (int)c.r[RDX], flags = (int)c.r[R10], fd = (int)c.r[R8];
    int64_t offset = (int64_t)c.r[R9];
    if (!length) { error = EINVAL; return false; }
    // Host pages are 16 KB and Lion maps at 4 KB boundaries, so a file is copied in rather than mapped,
    // and everything is readable and writable (nothing executes natively, and mprotect is a no-op).
    uint64_t at;
    if (flags & MAP_FIXED) {
        if (!GuestMap(address, length)) { error = ENOMEM; return false; }
        at = address;
        if (fd < 0 || (flags & MAP_ANON)) GuestZero(at, length);
    } else {
        at = GuestMapAnywhere(length);
        if (!at) { error = ENOMEM; return false; }
    }
    if (!(flags & MAP_ANON) && fd >= 0) {
        if (prot & PROT_EXEC) {
            char path[1024];
            if (fcntl(fd, F_GETPATH, path) == 0) {
                pthread_mutex_lock(&gCodeImagesLock);
                gCodeImages.push_back({ at, at + length, path });
                pthread_mutex_unlock(&gCodeImagesLock);
            }
        }
        uint64_t done = 0;
        while (done < length) {
            ssize_t n = pread(fd, (void *)(at + done), length - done, offset + (int64_t)done);
            if (n <= 0) break;
            done += (uint64_t)n;
        }
        if (done < length) memset((void *)(at + done), 0, length - done);
        if (prot & PROT_EXEC) {
            char path[1024];
            if (fcntl(fd, F_GETPATH, path) == 0) {
                const char *slash = strrchr(path, '/');
                if (slash && !strcmp(slash + 1, "libsystem_c.dylib")) PatchHostCalls(fd, offset, (uint8_t *)at, done, 0);
                JitAddText(at, done);
            }
        }
    }
    result = at;
    return true;
}

// sysctl values Lion must see as Lion's machine, not the host's arm64 kernel.
static bool Sysctl(Cpu &c, uint64_t &result, int &error) {
    int *name = (int *)c.r[RDI];
    uint32_t count = (uint32_t)c.r[RSI];
    void *old = (void *)c.r[RDX];
    size_t *oldSize = (size_t *)c.r[R10];
    auto giveString = [&](const char *s) {
        size_t n = strlen(s) + 1;
        if (old && oldSize) { memcpy(old, s, std::min(n, *oldSize)); }
        if (oldSize) *oldSize = n;
        result = 0;
        return true;
    };
    auto giveInt = [&](int v) {
        if (old && oldSize && *oldSize >= sizeof v) memcpy(old, &v, sizeof v);
        if (oldSize) *oldSize = sizeof v;
        result = 0;
        return true;
    };
    if (count >= 2 && name[0] == CTL_KERN) {
        switch (name[1]) {
            case KERN_OSRELEASE: return giveString("12.5.0");
            case KERN_OSTYPE: return giveString("Darwin");
            case KERN_VERSION: return giveString("Darwin Kernel Version 12.5.0: Sun Sep 29 13:33:47 PDT 2013; root:xnu-2050.48.12~1/RELEASE_X86_64");
            case KERN_OSREV: return giveInt(199506);
            default: break;
        }
    }
    if (count >= 2 && name[0] == CTL_HW) {
        switch (name[1]) {
            case HW_MACHINE: return giveString("x86_64");
            case HW_PAGESIZE: return giveInt(4096);
            case HW_BYTEORDER: return giveInt(1234);
            default: break;
        }
    }
    (void)error;
    return false;
}

// VM calls on the guest's own task. They have to meet the same bookkeeping as mmap (dyld reserves a range
// with vm_allocate and maps files over it), and the kernel's protections work in 16 KB pages where
// Lion means 4 KB. Layouts are the MIG requests in Lion's mach_vm and vm_map stubs: both families carry
// 64-bit addresses and sizes here.
static bool GuestVmCall(uint8_t *guest, mach_msg_option_t option, mach_msg_return_t &kr) {
#pragma pack(push, 4)
    struct Allocate { mach_msg_header_t h; NDR_record_t ndr; uint64_t address, size; int32_t flags; };
    struct Range { mach_msg_header_t h; NDR_record_t ndr; uint64_t address, size; };
    struct Reply { mach_msg_header_t h; NDR_record_t ndr; kern_return_t ret; };
    struct AllocateReply { mach_msg_header_t h; NDR_record_t ndr; kern_return_t ret; uint64_t address; };
#pragma pack(pop)
    mach_msg_header_t *h = (mach_msg_header_t *)guest;
    if (!(option & MACH_SEND_MSG) || !(option & MACH_RCV_MSG) || h->msgh_remote_port != mach_task_self()) return false;
    int id = h->msgh_id;
    mach_port_t reply = h->msgh_local_port;
    auto finish = [&](mach_msg_size_t size, kern_return_t ret) {
        Reply *r = (Reply *)guest;
        r->h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
        r->h.msgh_size = size;
        r->h.msgh_remote_port = MACH_PORT_NULL;
        r->h.msgh_local_port = reply;
        r->h.msgh_id = id + 100;
        r->ndr = NDR_record;
        r->ret = ret;
        kr = MACH_MSG_SUCCESS;
    };
    switch (id) {
        case 4800: case 3801: {   // mach_vm_allocate vm_allocate
            Allocate *a = (Allocate *)guest;
            uint64_t address = a->address, size = a->size;
            kern_return_t ret = KERN_SUCCESS;
            if (size > (1ull << 36)) fprintf(stderr, "lioness: vm_allocate id %d flags %#x address %#llx size %#llx\n", id, a->flags, address, size);
            if (a->flags & VM_FLAGS_ANYWHERE) { address = GuestMapAnywhere(size); if (!address) ret = KERN_NO_SPACE; }
            else if (GuestOverlaps(address, size)) ret = KERN_NO_SPACE;   // as the kernel: a fixed allocation never lands on memory in use
            else if (GuestMap(address, size)) GuestZero(address, size);
            else ret = KERN_NO_SPACE;
            finish(sizeof(AllocateReply), ret);
            ((AllocateReply *)guest)->address = address;
            return true;
        }
        case 4801: case 3802: {   // mach_vm_deallocate vm_deallocate
            Range *a = (Range *)guest;
            uint64_t address = a->address, size = a->size;
            GuestUnmap(address, size);
            finish(sizeof(Reply), KERN_SUCCESS);
            return true;
        }
        case 4802: case 3803:     // mach_vm_protect vm_protect: all guest memory stays read-write
            finish(sizeof(Reply), KERN_SUCCESS);
            return true;
        case 3404: {              // mach_ports_lookup, which libxpc aborts over if it fails: three empty slots
#pragma pack(push, 4)
            struct PortsReply { mach_msg_header_t h; mach_msg_body_t body; mach_msg_ool_ports_descriptor_t ports; NDR_record_t ndr; mach_msg_type_number_t count; };
#pragma pack(pop)
            uint64_t slots = GuestMapAnywhere(3 * sizeof(mach_port_t));
            if (slots) GuestZero(slots, 3 * sizeof(mach_port_t));
            PortsReply *r = (PortsReply *)guest;
            memset(r, 0, sizeof *r);
            r->h.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
            r->h.msgh_size = sizeof *r;
            r->h.msgh_local_port = reply;
            r->h.msgh_id = id + 100;
            r->body.msgh_descriptor_count = 1;
            r->ports.address = (void *)slots;
            r->ports.count = 3;
            r->ports.disposition = MACH_MSG_TYPE_MOVE_SEND;   // what a receiver sees
            r->ports.copy = MACH_MSG_VIRTUAL_COPY;
            r->ports.type = MACH_MSG_OOL_PORTS_DESCRIPTOR;
            r->ndr = NDR_record;
            r->count = 3;
            kr = MACH_MSG_SUCCESS;
            return true;
        }
        default:
            return false;
    }
}

// Lion's MIG builds messages in 4-byte-aligned stack buffers and leaves msgh_size for the trap to fill in
// from send_size. The current mach_msg wants neither, so the message crosses in a buffer of our own.
static mach_msg_return_t GuestMachMsg(const uint64_t arg[8], bool overwrite = false) {
    uint8_t *guest = (uint8_t *)arg[0];
    uint8_t *received = overwrite && arg[7] ? (uint8_t *)arg[7] : guest;
    mach_msg_option_t option = (mach_msg_option_t)arg[1];
    {
        mach_msg_return_t kr;
        if (GuestVmCall(guest, option, kr)) return kr;
        if (VirtualIOKitMessage(guest, option, kr, (option & MACH_SEND_MSG) ? (mach_msg_size_t)arg[2] : 0, (option & MACH_RCV_MSG) ? (mach_msg_size_t)arg[3] : 0)) return kr;
    }
    mach_msg_size_t sendSize = (option & MACH_SEND_MSG) ? (mach_msg_size_t)arg[2] : 0;
    mach_msg_size_t receiveSize = (option & MACH_RCV_MSG) ? (mach_msg_size_t)arg[3] : 0;
    mach_msg_size_t room = (std::max(sendSize, receiveSize) + 7 + 64) & ~7u;

    uint64_t small[512];
    uint8_t *buffer = room <= sizeof small ? (uint8_t *)small : (uint8_t *)malloc(room);
    if (!buffer) return MACH_SEND_NO_BUFFER;
    if (sendSize) {
        memcpy(buffer, guest, sendSize);
        ((mach_msg_header_t *)buffer)->msgh_size = sendSize;
    }
    if (gConfig && gConfig->trace && sendSize) {
        mach_msg_header_t *h = (mach_msg_header_t *)buffer;
        fprintf(stderr, "  send id=%d bits=%#x remote=%#x local=%#x size=%u option=%#x rcv=%u from=%#llx\n", h->msgh_id, h->msgh_bits,
                h->msgh_remote_port, h->msgh_local_port, sendSize, option, receiveSize, arg[4]);
    }
    // mach_msg2_trap, because the kernel kills a sender that calls a kernel object without saying so and
    // mach_msg() has no way to say it. MACH64_SEND_ANY accepts both kinds of destination.
    // Register layout from the libsystem_kernel wrapper; the message stays in `data`.
    constexpr uint64_t kMachMsg2 = 0x0000010000000000ull, kSendAny = 0x0000000800000000ull;
    mach_msg_header_t *h = (mach_msg_header_t *)buffer;
    uint32_t descriptors = 0;
    if (sendSize && (h->msgh_bits & MACH_MSGH_BITS_COMPLEX)) descriptors = *(uint32_t *)(buffer + sizeof(mach_msg_header_t));
    const uint64_t words[8] = {
        (uint64_t)buffer,
        (uint64_t)(uint32_t)option | kMachMsg2 | ((option & MACH_SEND_MSG) ? kSendAny : 0),
        sendSize ? (uint64_t)h->msgh_bits | ((uint64_t)sendSize << 32) : 0,
        sendSize ? (uint64_t)h->msgh_remote_port | ((uint64_t)h->msgh_local_port << 32) : 0,
        sendSize ? (uint64_t)h->msgh_voucher_port | ((uint64_t)(uint32_t)h->msgh_id << 32) : 0,
        (uint64_t)descriptors | (arg[4] << 32),
        (uint64_t)receiveSize,
        (uint64_t)(uint32_t)arg[5],
    };
    mach_msg_return_t kr = (mach_msg_return_t)RawSyscall(-47, words).x0;
    if ((option & MACH_RCV_MSG) && (kr == MACH_MSG_SUCCESS || kr == MACH_RCV_TOO_LARGE)) {
        mach_msg_size_t got = ((mach_msg_header_t *)buffer)->msgh_size;
        // The whole trailer, as long as the receiver asked for: audit tokens are how servers know who is calling.
        mach_msg_size_t total = got + (mach_msg_size_t)sizeof(mach_msg_trailer_t);
        if (kr == MACH_MSG_SUCCESS && got + sizeof(mach_msg_trailer_t) <= room) total = got + ((mach_msg_trailer_t *)(buffer + got))->msgh_trailer_size;
        memcpy(received, buffer, kr == MACH_RCV_TOO_LARGE ? sizeof(mach_msg_header_t) : std::min(total, receiveSize));
    }
    // host_info: the guest is on an Intel Mac. Launch Services compares this with an app's architectures, and badges every app it thinks cannot run.
    if ((option & MACH_RCV_MSG) && kr == MACH_MSG_SUCCESS && ((mach_msg_header_t *)buffer)->msgh_id == 300 && ((mach_msg_header_t *)buffer)->msgh_size >= 56) {
        integer_t *info = (integer_t *)(buffer + sizeof(mach_msg_header_t) + sizeof(NDR_record_t) + 8);
        if (info[3] == CPU_TYPE_ARM64) { info[3] = CPU_TYPE_X86_64; info[4] = CPU_SUBTYPE_X86_64_H; }
    }
    if (gConfig && gConfig->trace) {
        mach_msg_header_t *got = (mach_msg_header_t *)buffer;
        if ((option & MACH_RCV_MSG) && kr == MACH_MSG_SUCCESS)
            { fprintf(stderr, "  -> kr=0 got id=%d size=%u bits=%#x ret=%#x\n", got->msgh_id, got->msgh_size, got->msgh_bits, got->msgh_size >= 36 ? *(uint32_t *)(buffer + 32) : 0);
            }
        else fprintf(stderr, "  -> kr=%#x\n", kr);
    }
    if (buffer != (uint8_t *)small) free(buffer);
    return kr;
}

void Syscall(Cpu &c) {
    uint64_t rax = c.r[RAX];
    int cls = (int)(rax >> 24);
    int number = (int)(rax & 0xffffff);
    uint64_t arg[8] = { c.r[RDI], c.r[RSI], c.r[RDX], c.r[R10], c.r[R8], c.r[R9],
                        *(uint64_t *)(c.r[RSP] + 8), *(uint64_t *)(c.r[RSP] + 16) };
    if (cls == 2 && number == 0) {   // syscall(2): the real number is the first argument
        number = (int)arg[0];
        memmove(arg, arg + 1, 7 * sizeof arg[0]);
        arg[7] = 0;
    }
    if (gConfig && gConfig->trace)
        fprintf(stderr, "sys[%d.%d](%#llx, %#llx, %#llx, %#llx)\n", cls, number, arg[0], arg[1], arg[2], arg[3]);

    if (cls == 3) {   // machdep
        if (number == 3) { c.gsBase = arg[0]; c.r[RAX] = 0; c.cf = false; return; }   // thread_fast_set_cthread_self
        c.r[RAX] = 0; c.cf = false;
        return;
    }
    if (cls == 1) {   // Mach traps return kern_return_t and never set carry
        if (number == 31 || number == 32) {
            // 32 is mach_msg_overwrite_trap, the same with the received message going to its own buffer (arg[7], if any).
            // This kernel kills a process for the old trap, so messages go through the host's mach_msg, which knows the current trap.
            c.r[RAX] = (uint64_t)(int64_t)GuestMachMsg(arg, number == 32);
            return;
        }
        // Reference counting on a virtual name (the bootstrap port, the IOKit master) is accepted: the kernel has never heard of either.
        if ((number == 17 || number == 18 || number == 19) && (uint32_t)arg[1] >= 0xf0000002 && (uint32_t)arg[1] < 0xf0001000) {
            c.r[RAX] = KERN_SUCCESS;
            return;
        }
        // Mountain Lion makes VM calls on its own task through these traps, where Lion sent messages (GuestVmCall). Passed through,
        // they would reserve memory in the host's address space and outside the guest's bookkeeping.
        if ((number == 10 || number == 12 || number == 14) && (mach_port_t)arg[0] == mach_task_self()) {
            kern_return_t ret = KERN_SUCCESS;
            if (number == 10) {   // _kernelrpc_mach_vm_allocate_trap(task, *address, size, flags)
                uint64_t *address = (uint64_t *)arg[1];
                if ((int)arg[3] & VM_FLAGS_ANYWHERE) { *address = GuestMapAnywhere(arg[2]); if (!*address) ret = KERN_NO_SPACE; }
                else if (GuestOverlaps(*address, arg[2])) ret = KERN_NO_SPACE;   // as the kernel: a fixed allocation never lands on memory in use
                else if (GuestMap(*address, arg[2])) GuestZero(*address, arg[2]);
                else ret = KERN_NO_SPACE;
            } else if (number == 12) {   // _kernelrpc_mach_vm_deallocate_trap(task, address, size)
                GuestUnmap(arg[1], arg[2]);
            }   // 14 is _kernelrpc_mach_vm_protect_trap: all guest memory stays read-write
            c.r[RAX] = (uint64_t)(int64_t)ret;
            return;
        }
        if (number == 17) {   // mach_port_destroy_trap, gone from this kernel (it answers with SIGSYS): the MIG routine still exists
            c.r[RAX] = (uint64_t)(int64_t)mach_port_destroy((mach_port_t)arg[0], (mach_port_name_t)arg[1]);
            return;
        }
        // The guest's clock counts nanoseconds (RDTSC and the commpage), not this machine's ticks, so timebase and deadlines are converted.
        if (number == 89) {   // mach_timebase_info_trap
            if (!GuestOwns(arg[0], 8)) { c.r[RAX] = (uint64_t)KERN_INVALID_ADDRESS; return; }
            ((uint32_t *)arg[0])[0] = ((uint32_t *)arg[0])[1] = 1;
            c.r[RAX] = KERN_SUCCESS;
            return;
        }
        uint64_t translated[8];
        if (number == 90 || number == 93) {   // mach_wait_until_trap(deadline), mk_timer_arm_trap(port, deadline)
            memcpy(translated, arg, sizeof translated);
            int which = number == 90 ? 0 : 1;
            uint64_t now = GuestTicks(), wanted = arg[which], delta = wanted > now ? wanted - now : 0;
            static mach_timebase_info_data_t base = [] { mach_timebase_info_data_t b; mach_timebase_info(&b); return b; }();
            translated[which] = mach_absolute_time() + (uint64_t)((__uint128_t)delta * base.denom / base.numer);
        }
        RawResult r = RawSyscall(-(int64_t)number, number == 90 || number == 93 ? translated : arg);
        c.r[RAX] = r.x0;
        return;
    }
    if (cls != 2) GuestPanic(c, "unknown syscall class");

    uint64_t result = 0;
    int error = 0;
    bool handled = true, ok = true;
    std::string p0, p1;
    uint64_t passed[8];
    memcpy(passed, arg, sizeof passed);

    switch (number) {
        case 1:   // exit
            if (gConfig && gConfig->trace) DumpGuest(c, "exit called");
            if (gConfig) { fflush(stdout); fflush(stderr); _exit((int)arg[0]); }
            GuestExit(c, (int)arg[0]);
            return;
        case 361:   // bsdthread_terminate(stack, size, port, semaphore): this guest thread only
            if (arg[1]) GuestUnmap(arg[0], arg[1]);
            if (arg[3]) semaphore_signal((semaphore_t)arg[3]);
            GuestExit(c, 0);
            return;
        case 116: {                                                          // gettimeofday: Lion's stub takes the answer from rax and rdx
            struct timeval now;
            gettimeofday(&now, NULL);
            c.r[RAX] = (uint64_t)now.tv_sec;
            c.r[RDX] = (uint64_t)now.tv_usec;
            c.cf = false;
            return;
        }
        case 73:  GuestUnmap(arg[0], arg[1]); break;                         // munmap
        case 74: case 75: break;                                             // mprotect madvise: all memory is RW, and nothing runs natively
        case 197: ok = Mmap(c, result, error); break;                        // mmap
        case 294: case 295: case 438:                                        // the shared region: no cache, dyld loads from files
            ok = false; error = ENOSYS;
            break;
        case 46:                                                             // sigaction: never the host's handlers
            if (arg[2]) memset((void *)arg[2], 0, 24);
            break;
        case 48: case 329:                                                   // sigprocmask __pthread_sigmask
            if (arg[2]) *(uint32_t *)arg[2] = 0;
            break;
        case 53: case 328: case 331: case 332: case 333: break;              // sigaltstack __pthread_kill __disable_threadsignal cancel state
        case 2: case 59: case 66: ok = false; error = ENOSYS; break;         // fork execve vfork: one image only
        case 37:                                                             // kill: a guest aiming at itself must not hit its host
            if ((pid_t)arg[0] == getpid() || (pid_t)arg[0] == 0) { GuestExit(c, 128 + (int)arg[1]); return; }
            handled = false;
            break;
        case 327: result = 0; break;                                         // issetugid: the guest is not, whatever its host is
        case 202: handled = Sysctl(c, result, error); break;                 // __sysctl
        case 360:                                                            // bsdthread_create
            result = BsdThreadCreate(c, arg[0], arg[1], arg[2], arg[3], (uint32_t)arg[4]);
            if (!result) { ok = false; error = EAGAIN; }
            break;
        case 366: gThreadStart = arg[0]; gWqThreadStart = arg[1]; break;     // bsdthread_register
        case 367: break;                                                     // workq_open
        case 368:                                                            // workq_kernreturn(op, item, count, priority)
            switch ((int)arg[0]) {
                case 0x10: break;                                            // WQOPS_QUEUE_NEWSPISUPP
                case 0x20:                                                   // WQOPS_QUEUE_REQTHREADS
                    for (uint64_t i = 0; i < arg[2]; i++) if (!StartWorker((uint32_t)arg[3])) { ok = false; error = EAGAIN; break; }
                    break;
                case 4:                                                      // WQOPS_THREAD_RETURN
                    if (!tWorkerMap) { ok = false; error = EINVAL; break; }
                    ParkWorker(c);
                    return;
                default: ok = false; error = ENOTSUP; break;
            }
            break;
        // The first argument is a path.
        case 5: case 398:                                                    // open open_nocancel
        case 10: case 12: case 15: case 16: case 33: case 58:                // unlink chdir chmod chown access readlink
        case 128: case 136: case 137: case 157:                              // rename mkdir rmdir statfs
        case 188: case 190: case 191:                                        // stat lstat pathconf
        case 220: case 221: case 234:                                        // getattrlist setattrlist getxattr
        case 338: case 340: case 341: case 342: case 345:                    // stat64 lstat64 stat64_extended lstat64_extended statfs64
            passed[0] = (uint64_t)GuestPath(arg[0], p0);
            if (gConfig && gConfig->trace) fprintf(stderr, "  path %s -> %s\n", (const char *)arg[0], p0.c_str());
            handled = false;
            break;
        default:
            handled = false;
            break;
    }

    if (!handled) {
        RawResult r = RawSyscall(number, passed);
        if (gConfig && gConfig->trace) fprintf(stderr, "  -> %#llx carry=%d\n", r.x0, r.carry);
        c.r[RAX] = r.x0;
        c.r[RDX] = r.x1;
        c.cf = r.carry;
        return;
    }
    if (ok) { c.r[RAX] = result; c.r[RDX] = 0; c.cf = false; }
    else { c.r[RAX] = (uint64_t)error; c.cf = true; }
    if (gConfig && gConfig->trace) fprintf(stderr, "  => %#llx carry=%d (handled)\n", c.r[RAX], c.cf);
}

void DumpGuest(const Cpu &c, const char *why) {
    fprintf(stderr, "\nlioness: guest stopped: %s at rip=%#llx after %llu instructions\n", why, c.rip, c.instructions);
    if (GuestOwns(c.rip, 16)) {
        const uint8_t *code = (const uint8_t *)c.rip;
        fprintf(stderr, "  bytes:");
        for (int i = 0; i < 16; i++) fprintf(stderr, " %02x", code[i]);
        fprintf(stderr, "\n");
    }
    fprintf(stderr, "  rax=%#llx rcx=%#llx rdx=%#llx rbx=%#llx rsp=%#llx rbp=%#llx rsi=%#llx rdi=%#llx\n",
            c.r[RAX], c.r[RCX], c.r[RDX], c.r[RBX], c.r[RSP], c.r[RBP], c.r[RSI], c.r[RDI]);
    fprintf(stderr, "  r8=%#llx r9=%#llx r10=%#llx r11=%#llx r12=%#llx r13=%#llx r14=%#llx r15=%#llx\n",
            c.r[R8], c.r[R9], c.r[R10], c.r[R11], c.r[R12], c.r[R13], c.r[R14], c.r[R15]);
    // The frame-pointer chain, for symbolising against the image that holds each address.
    uint64_t fp = c.r[RBP];
    fprintf(stderr, "  frames:");
    for (int i = 0; i < 12 && fp && GuestOwns(fp, 16); i++) {
        fprintf(stderr, " %s", GuestAddressName(((uint64_t *)fp)[1]).c_str());
        fp = ((uint64_t *)fp)[0];
    }
    fprintf(stderr, "\n  at: %s\n", GuestAddressName(c.rip).c_str());
}

void GuestPanic(Cpu &c, const char *why) {
    DumpGuest(c, why);
    abort();
}

void RegisterHostCalls() {}

// The busiest routines of the guest's libc and dyld, run natively (PatchHostCalls). Bulk copies dominate drawing.
enum { kHostMemmove = 1, kHostBcopy, kHostBzero, kHostMemset, kHostStrlen, kHostStrcmp, kHostStrncmp, kHostMemcmp, kHostReturnZero, kHostSyslog };

void PatchHostCalls(int fd, off_t sliceOffset, uint8_t *text, size_t length, uint64_t textVmaddr) {
    static const struct { const char *name; uint32_t id; } kTable[] = {
        // Only the variants: libc's plain _memcpy, _memmove, _bcopy and _bzero are resolvers that return a variant's address at bind time.
        { "_memmove$VARIANT$sse3x", kHostMemmove }, { "_memcpy$VARIANT$sse3x", kHostMemmove },
        { "_memmove$VARIANT$sse42", kHostMemmove }, { "_memcpy$VARIANT$sse42", kHostMemmove },
        { "_bcopy$VARIANT$sse3x", kHostBcopy }, { "_bcopy$VARIANT$sse42", kHostBcopy },
        { "_bzero$VARIANT$sse2", kHostBzero }, { "_bzero$VARIANT$sse42", kHostBzero },
        { "_memset", kHostMemset }, { "_strlen", kHostStrlen }, { "_strcmp", kHostStrcmp }, { "_strncmp", kHostStrncmp }, { "_memcmp", kHostMemcmp },
        // Nothing receives the guest's logs, so formatting them is wasted time.
        { "_asl_log", kHostReturnZero }, { "_asl_vlog", kHostReturnZero }, { "_asl_send", kHostReturnZero }, { "_syslog", kHostSyslog },
    };
    const mach_header_64 *header = (const mach_header_64 *)text;
    if (length < sizeof *header || header->magic != MH_MAGIC_64) return;
    const uint8_t *command = (const uint8_t *)(header + 1);
    const symtab_command *table = NULL;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const load_command *lc = (const load_command *)command;
        if (lc->cmd == LC_SYMTAB) table = (const symtab_command *)lc;
        command += lc->cmdsize;
    }
    if (!table) return;
    std::vector<nlist_64> symbols(table->nsyms);
    std::vector<char> strings(table->strsize);
    if (pread(fd, symbols.data(), symbols.size() * sizeof(nlist_64), sliceOffset + table->symoff) != (ssize_t)(symbols.size() * sizeof(nlist_64))) return;
    if (pread(fd, strings.data(), strings.size(), sliceOffset + table->stroff) != (ssize_t)strings.size()) return;
    for (const nlist_64 &symbol : symbols) {
        if (symbol.n_un.n_strx >= strings.size() || (symbol.n_type & N_STAB) || !symbol.n_value) continue;
        const char *name = strings.data() + symbol.n_un.n_strx;
        if (name[0] != '_' || name[1] < 'b' || name[1] > 's') continue;
        for (const auto &entry : kTable) {
            if (strcmp(name, entry.name)) continue;
            uint64_t offset = symbol.n_value - textVmaddr;
            if (offset + 6 > length) break;
            text[offset] = 0x0f;
            text[offset + 1] = 0x0b;
            memcpy(text + offset + 2, &entry.id, 4);
            break;
        }
    }
}

void HostCall(Cpu &c, uint32_t id) {
    uint64_t a = c.r[RDI], b = c.r[RSI], n = c.r[RDX];
    switch (id) {
        case kHostMemmove: memmove((void *)a, (void *)b, n); c.r[RAX] = a; break;
        case kHostBcopy: memmove((void *)b, (void *)a, n); break;
        case kHostBzero: memset((void *)a, 0, b); break;
        case kHostMemset: memset((void *)a, (int)b, n); c.r[RAX] = a; break;
        case kHostStrlen: c.r[RAX] = strlen((const char *)a); break;
        case kHostStrcmp: c.r[RAX] = (uint64_t)(int64_t)strcmp((const char *)a, (const char *)b); break;
        case kHostStrncmp: c.r[RAX] = (uint64_t)(int64_t)strncmp((const char *)a, (const char *)b, n); break;
        case kHostMemcmp: c.r[RAX] = (uint64_t)(int64_t)memcmp((const void *)a, (const void *)b, n); break;
        case kHostReturnZero: c.r[RAX] = 0; break;
        case kHostSyslog:   // no log daemon, so stderr
            fprintf(stderr, "[syslog] %s (%#llx %#llx %#llx %#llx)\n", GuestOwns(b, 1) ? (const char *)b : "?", n, c.r[RCX], c.r[R8], c.r[R9]);
            break;
        default: GuestPanic(c, "ud2 / host call with no handler");
    }
    c.rip = *(uint64_t *)c.r[RSP];   // what the routine's ret would have done
    c.r[RSP] += 8;
}

} // namespace Lioness
