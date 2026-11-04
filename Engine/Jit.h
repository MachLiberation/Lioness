// x86-64 to arm64, on top of the interpreter: what it does not translate it hands to the interpreter one instruction at a time.

#ifndef LIONESS_JIT_H
#define LIONESS_JIT_H

#include "Lioness/Cpu.h"

namespace Lioness {

void StepInstruction(Cpu &c);                      // one instruction in the interpreter (Interpreter.cpp)

bool JitAvailable();                               // sets it up on first use; false if switched off (LIONESS_NO_JIT) or without executable memory
void JitRun(Cpu &c);                               // runs guest code until it needs the dispatcher, with c.rip where to go on
void *JitLookup(uint64_t rip);                     // the code for this address, translating it if it can be; NULL if not

// Executable guest code from a file. Only this is translated: anything else may be rewritten without telling us (LLVM's output, say), and stays interpreted.
void JitAddText(uint64_t start, uint64_t length);
void JitNoteUnmap(uint64_t start, uint64_t length);

// From a host fault handler. A load from the commpage, which cannot be mapped here, is pointed at our copy and true is returned: retry.
// Otherwise the guest's registers are copied out of the context, so that a report shows them, and false.
bool JitFixFault(void *ucontext, Cpu *guest);

void JitDumpStats();                               // LIONESS_JIT_STATS: what still falls back to the interpreter

} // namespace Lioness

#endif
