# "MattRISC" PowerPC 32-bit CPU

1.0, 21 August 2022


This is Verilog source for a "quite simple" pipelined RISC CPU,
mostly compatible with the PowerPC 32-bit UISA/OEA architecture, intended
for FPGA implementation.  It was designed for fun, for a home-built
FPGA 'computer from scratch', with the aim of running PowerPC 604-era
code.  It needs a better name -- for now you'll see references to a
shorthand "MR" everywhere.

I will write more elsewhere on the whys and hows; consider this poor
README a placeholder for now.

This CPU is a component of the umbrella **MR-sys** project.


# Features, architecture & microarchitecture

Aside from floating point instructions, which this CPU doesn't
currently implement, any PowerPC 604-era userspace programs should run
without trouble.  All integer instructions/registers are present (and
even believed to be correct!).  All architected privileged/OEA-level
instructions are also supported a la PPC604, but MR doesn't implement
HIDn registers (and a couple of corners) that would make it fully
compatible with the 604.

Modern PowerPC ISAs are numbered, e.g. ISA 2.07, 3.0, etc., but I'm
not aware of a straightforward numbering scheme for the early
1990s-era CPU ISAs.  So, I'm saying things like "PPC604-like",
compatible with the Freescale PEM 32-bit manual.

CPU features:

   * Pipelined "simple" 5-stage classic RISC pipeline
   * Support for all integer instructions and registers (no FP yet)
   * Support for both execution states/privilege levels, exceptions and high/low vector base
   * Standard TB/DEC, supports external interrupts
   * Separate 16KB (4-way set-associative) I- and writeback D-caches, supports all cache maintenance instructions
   * BATs (4x I, 4x D) and MMU, including hardware refill from HTAB, `tlbie`/`tlbia`
   * Big-endian memory accesses
   * Strictly in-order
   * Runs ppc32 Linux!

I keep saying "simple", because there are several disadvantages to
this 5-stage classic RISC pipeline and some of them require fugly
workarounds or performance hacks.  This CPU is also not especially
small.

My design goals and priorities were:

   * Fun: to enjoy building a CPU
   * To run existing off-the-shelf binaries
   * To have _reasonably_ high performance
   * To learn: Verilog, microarchitecture
   * To get empirical experience of FPGA implementation tradeoffs/foibles/costs/tricks

It _wasn't_ designed to be small or pushed for absolute performance.
(That's V2 😉)

Critically-speaking, MR 1.0 is not a _great_ CPU, or an especially
frugal one.  But, I fairly confidently understand all of the failures
and pitfalls in its design (ticks my goal to learn).  And, it works!
It's been great fun to work on. 😁

Some more detailed features:

   * Configurable fully-associative L1 TLBs in I and D
     * A combined larger L2 TLB is scribble-planned
   * "Squashable" pipeline bubbles: later instructions can catch up to stalled earlier instructions
   * No branch prediction yet (this is a WIP):  static predicts not-taken and carries on, or annuls the shadow if taken
   * MMU PTEG access does _not_ yet update PTE R/C bits!  (Planned; Linux doesn't rely on them, NetBSD does.)
   * Supports unaligned cacheable loads/stores within a 64-bit chunk
     * Raises an alignment exception for others.
     * The cache/MEM needs refactoring/rewriting; this will make it easier to split loads/stores to split an unaligned access across cache lines.
   * Iterative integer divide
   * 2-cycle 32x32->64 multiply (FPGA DSP slices)
   * Fairly costly 3R2W GPR file: single-cycle stwx issue
   * GPR scoreboarding: permits multiple outstanding GPR writes
   * GPR (and CR/XER) bypass paths from EX/MEM results
   * Performance monitor triggers from various microarchitectural sources (e.g. stalls, faults, unaligned accesses, PTWs)
     * Actual perf counters are not yet implemented; they will be memory-mapped, and sit external to the CPU core

The CPU hasn't been thoroughly verified, nor has it undergone PowerPC
conformance testing.  I don't claim this is a certified PowerPC CPU!
It has had "agile directed testing" during development (test program
elsewhere/TBD), a lot of SimpleRandom testing, and has been running
PPC Linux for a year or so with some quite large programs (e.g. X11).
(That's nice, but doesn't prove correctness.)  For a single-person pet
project, it seems fairly robust but I make NO GUARANTEES.  I will
publish the `testprog.S` in due course...

There are also _some_ unit-level tests in this repo, but some of them
are more about "get the human to eyeball a corner case" rather than
being stringent self-evaluating tests useful for regression testing.

⚠️ *This project is not endorsed by or associated with IBM,
Motorola/Freescale/NXP, or the OpenPOWER foundation.  PowerPC is their
trademark.* This project is a retrocomputing labour of adoration for
the historical products of these companies.


## See also

The overall MR-sys project log is (awkwardly) held in this repository,
in `docs/log.txt`.  It's very raw -- originally written for me, not
you -- but gives an overview of the timeline and order in which work
was done, and some debugging details if you like that sort of thing.

There are also some notes-to-self (slightly rambling, not intended for
other eyes) outlining the historical plan in `docs/plan.txt`.

(*FIXME*) This is the CPU; the MR system top level, MIC interconnect
and devices, firmware, and Linux platform support are in other
repositories.


# Structure of the design

## Top-level

The CPU top itself is `mr_cpu_top.v`, which exposes an External Memory
Interface (see `docs/emi.txt`).  That component is not usually
instantiated directly, but wrapped to expose a particular interconnect
technology appropriate to the system.  MR-sys uses the MIC
interconnect (see the `mic-hw` repository), so the `mr_cpu_mic.v`
top-level is what's instantiated.  This wrapper could implement a
unified L2 cache; for MIC, it just combines the I- and D-side EMI port
requests into one outgoing MIC requester port.

The pipeline stages are named IF, DE, EXE, MEM and WB.  Disgustingly,
the Verilog module hierarchy follows the pipeline stages.

I wouldn't do it this way again, because we're grouping behaviours by
time rather than by actual association.  Lesson learned, I'd prefer to
rotate 90° and have a module represent a pipeline/association, but
this isn't without disadvantages either.

Pipeline stages use a `src/plc.v` pipeline control module to pass
valid forward, stall/consume back, and wrap up whether the stage can
change or whether it needs to hold outputs.  Corresponding to IF/MEM
doing a registered read of the cache RAM, each stage _ends_ with a
register.  Each stage's outputs are said to be valid if those
registers hold real data/a live instruction.  The inputs to a stage
come from the previous stage's FFs; so, EXE "contains" a valid
instruction if DE's output FFs are valid.  EXE "emits" a valid
instruction when EXE's output FFs go valid.


## Decoding

Like the MR-ISS project, the decoder (and constant definitions) are
auto-generated using the `tools/mk_decode.py` script.  The input
oracle is the `tools/PPC.csv` table (from a spreadsheet), with one
line for each instruction and properties/decode flags of each.
"Output" columns indicate the behaviour of each instruction in DE,
EXE, MEM and WB.

Load/store-multiple instructions are cracked in decode with a
multi-cycle FSM, generating multiple instructions downstream.  Each
cycle synthesises control signals for a sequence of discrete
`lwz`/`stw` instructions.


### Registers and bypass

Decode owns the GP and SPRs.  When a decoded instruction wants a GPR
value, the scoreboard indicates whether that register is "old" because
an in-flight instruction is going to update it.  In this case, the
decoded instruction must either use a bypassed value or wait for that
previous instruction to complete (and use the register file version).

Bypass is implemented for GPRs and XER/CR; SPRs don't currently
bypass.  (LR and CTR, I'm looking at you.)  Whether bypass isn't
available or isn't implemented, the RAW resolution is the same: stall
the issue until the required register is written back.

Bypass occurs from EXE results, EXE results that are being passed
through the MEM stage (ew), and a short-cut for a register being
written back in the same cycle as a read.  Note, load data is valid
only when the load instruction moves to WB, so the value is only
forwarded from WB to DE -- a 2 cycle load-to-use.

Bypass works by having eligible stages "offer" a result back to DE.
Each stage indicates whether its current instruction writes a
particular register (up to 2 GPR results per instruction), and
separately whether it is currently outputting a valid value for those
registers.  If DE has an instruction needing one of those values, it
takes the bypass version in preference to the GPRF version.  Sometimes
a value might be in-flight (so the GPRF version is stale) but the
corresponding stage cannot provide a value right now; DE must be aware
that the value is out doing the rounds, but must stall to wait for it
to become valid (or get written back to the GPRF).

Of course, I had several exciting bugs caused by DE using a stale
value!  It's not just use-GPRF-or-not, too: you might have sequential
instructions that both write the same register, so now there's an
ancient value in the GPRF, an old one in MEM, and the most up-to-date
one in EXE!  The newest version must always be chosen -- falling back
to a stall if it can't be guaranteed.


## Execute

This is very MUX-heavy.  There are multiple sub-modules for, e.g. ALU,
multiplier, CLZ, rotate/mask, divide, condition calculation and branch
calcs.  An early version of the CPU didn't implement divide (KISS),
but it became so irritating to ensure any test code from C had my
"Mini OS" shim attached to provide SW instruction emulation.  It was
easier just to implement divide (though the condition flags on
div*[o.] were a good source of pain).

Multiply and divide instructions take 2 cycles and a value-specific
time, respectively.  EXE contains a FSM to stall until they're
complete/outputs are valid.

Units like the rotate-mask and CLZ calculation are in my sights for
future profiling and possible pipelining.  Currently, they're purely
combinatorial, single-cycle, and large.  Profiling will confirm
whether they're common enough to justify that cost.


## Control flow changes

EXE has a dedicated branch address adder and condition code
evaluation.  A taken branch emits an annul in EXE (to invalidate any
instruction that might be in DE), then emits a new PC the cycle after
that.  (This used to be done in the MEM module, but is now done from
an awkward second pipeline stage in EXE, called EXE2/execute2.)

An `rfi` looks like a branch that also happens to write MSR.

Every instruction flows down the pipeline with decoded control,
PC/MSR, and a status that indicates whether it's a pure instruction or
a fault.  An instruction that throws an exception is transformed into
a fault.  Without exception, exceptions are only raised when the
instruction gets to WB; WB emits a new PC/MSR having calculated the
exception vector from the fault type.

Note some exceptions don't get to WB, so are squashed: picture a
syscall instruction following a taken branch.  The `sc` is transformed
by DE into a fault, but that instruction is annulled by the earlier
branch instruction now in EXE.


## Memory system

IF and MEM both instantiate an MMU (providing BAT translation and TLB)
and cache.  Each cache has one EMI (to the outside world/top-level
wrapper) and initiate transactions to memory.  The cache components
also (grrrrr) initiate uncached operations.  Each MMU contains a TLB,
which has a port out to a shared `mmu_ptw` component which services
requests to walk the HTAB.

The PTW component makes memory requests into the D-side cache, sharing
with MEM; awkward as this is wire-wise, data coherency must be
maintained.  The MEM stage also manages cache and TLB invalidation
instructions; it has an invalidation port over to the ITLB/I$, plus
acts on the local DTLB/D$.

MEM owns the Segment Register bank.

At the moment, TLB invalidations stall until complete (they only take
a couple of cycles), so `tlbsync` is a NOP.  Similarly, there's no
store buffer or possibility to reorder (though I'd like to add at
least a store buffer (and write-combining) soon) so `sync` is also a
NOP.

Ah, and I've fundamentally cheated with `lwarx`/`stwcx`'s reservation.
It does not monitor the corresponding cache line for access; it simply
blows the reservation on an exception.  This isn't architecturally
correct, for instance can't spot ABA and should permit an exception
handler to intervene ("but works fine for my simple Linux system").
It would be straightforward to track address-based reservation.

The interface to the cache itself is overly complex; effectively it
has a "not ready yet" signal, but the user has to hold signals stable.
As mentioned elsewhere, the cache will be refactored and this will be
simplified.  The EMI/fill/spill engine is implicitly coupled to the
MEM-side request interface, and this should be decoupled.  Once that's
done, uncached write combining (good for framebuffer), prefetch (both
explicit and implicit) and external snoops become much easier to
implement.


### MMU style

The MMU grew from a BAT-only first go, adding full translation later.
Somewhat because of this evolution, the MMU critical path searches
both BATs and TLBs (which is a little heavy, even though in parallel).

Each TLB contains combined HTAB and Segment Register translation
information, so the TLB result translates from EA to PA (much like the
POWER-era ERAT).  These TLBs must therefore be invalidated when any
Segment Register is written.  In a future refactoring, the PTW
component will contain a L2 TLB (holding VA-PA entries from the HTAB)
to both speed up an L1 miss and reduce the impact of this
invalidate-all.  This centralised component could also contain the BAT
translation logic, meaning the MMU *only* consists of a TLB lookup.
(This terminology might be counter-intuitive: in this arrangement the
TLB would always be active, including when the page table is disabled,
so as to provide BAT translation too.)

A set of IMPDEF SPRs allow CPU-specific reset code to perform an
invalidate-all on the caches.  (Note, this is not done via a HIDn
register a la PPC60x.)


# The ugly

For my project, this CPU is kinda-complete and I've decided to avoid
any more major turd-polishing on it going forward.  There are lots of
features/bits of work I'd like to do, e.g. gentle OoO in load-miss
cases, LSU/store queue, prefetch, snoops/SMP coherency etc., but I
think this is better done in a different overall CPU microarch
(sharing much of the logic and some components).

For example, the MEM stage is the current critical path and prevents
reaching higher frequencies.  It's doing a lot in a single cycle: BAT
lookup, TLB lookup, then using the result of that (PA) to lookup
physical cache tags, then creating a cache data address.  This needs
to be pipelined, but that'll be a pain without having a dedicated
"LSU" pipeline (in parallel with others) -- which all begs for a
top-down refactor/rearch.

You will also see various small sins, bad (learning) style,
inconsistent naming and minds changed in various places (all of which
need eventual fixing).

Viva el CPU 2.0.


# Example test program execution

This repository contains a simple memory-and-debug-putchar top-level
so that the CPU can be simulated outside of the full SoC (for better
performance and debugability).  Trivial simulations using Icarus
Verilog are supported, but I now use the Verilator builds more often.

Having copied a PPC test program (TBD) having low vectors (reset is
phys address 0x100) to `testprog.bin`:

~~~
$ make verilate_tb_top
    [...Much build output...]
EXE is:  ./verilator/obj_dir/Vwrapper_top
$
$ make run_tb_top
verilator -Mdir verilator/obj_dir -Wall -Wno-fatal --trace --timescale 1ns/1ns -j 4 -cc tb/wrapper_top.v -Iinclude/ -Isrc/ -Itb/ -CFLAGS "-O3 -flto" -CFLAGS " -DEXIT_B_SELF=1" --exe ../main.cpp
(cd verilator/obj_dir ; make -f Vwrapper_top.mk -j 4)
make[1]: Entering directory '/foo/MR-hw/verilator/obj_dir'
make[1]: Nothing to be done for 'default'.
make[1]: Leaving directory '/foo/MR-hw/verilator/obj_dir'

EXE is:  ./verilator/obj_dir/Vwrapper_top

Running verilated build:

time ./verilator/obj_dir/Vwrapper_top
*** Booting ***
Going to userspace:
Stage 1: Sum f30e2b14
e8e9db48b71cb365efcb882dd6d6ab70

                              ....                                                                                              
                              ....                                                                                              
                                                                                                                                
                                           .....                                                           ...                  
                                         ........                                                        .....                  
                                        ..........                                                    .....                     
                                    ..............                                                     ....                     
                                   ..............                                                                               
                                    .... ......                                                                                 
                                     .    .....                                                                                 
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                                                                
                                                                                  .....                                         
                                                                                  ......  ....                                  
                                                                                ...............                                 
                       ...                                                     ...............                                  
                      .....                                                     .........                                       
                   ......                                                       ........                                        
                   ...                                                            .....                                         
                                                                                                                                
                                                                                                ...                             
Stage 2: Sum 1146c31e3a1
348b0b9926b85653d7c01a4f9f2dd6eb

####   ....  ####ooo.  .o#oo..     ..o##o.  ..ooooo########oooooooooooo############ooo.. .#o. ##########.o#. ..oo####      #####
####  .....  ####ooo.  .o#oo.      ..o#o..  ..oooooo#####ooooooooooo###############ooo.  o#o ####ooo####.o#. ..oo#####   #######
####  .....  ####oo..  .o#oo..    ..oo#o.   ..ooooooooooooooooooooo#######     ####ooo.  o#. ###oooo####.o#. ..oo###############
o###   ...  ####ooo..  .o#oo... ...oo#oo.  ...oooooooooooooooooooo######   ...  ####oo. .oo.####oooo####.oo. ..ooo##############
o####       ####ooo..  .o#oo......oo##o..  ...ooooooooooooooooooo######  ......  ###oo. .#o ###ooooo### .oo. ..ooo##############
o#####     ####ooo..  ..o#ooo....ooo#oo.   ....oooooooooooooooooo##### ..ooooo.. ###oo. .#. ###ooooo### .oo. ..oooo############ 
oo#############ooo..  ..o##ooooooo##oo.    ....ooooooooooooooooo##### ..oo###oo. ###o.. o#. ###ooooo### .#o. ..ooooo########### 
ooo###########oooo..  .oo##oooooo##oo..   .....ooooooooooooooooo#### ..oo#####oo.###o.. o#. ###oooo#### o#o. ...oooooo########  
ooo##########oooo..   .oo###o#####oo..   .................oooooo#### .o###ooo##o.###o.  oo.####oooo####.o#o.  ..ooooooooo##### .
ooooo######ooooo...  ..oo#######oo..    ...................ooooo### .oo##oooo##o.##oo.  oo.####ooo#### .o#o.  ...oooooooo##### .
.oooooooooooooo...   ..oo#####ooo..    .....................oooo### .o##oooooo#o.##oo. .oo. ########## .o#o.  ....oooooooo#### .
..ooooooooooo....   ..ooooooooo...    ......................oooo### .o#oo...oo#o.##oo. .oo. ######### .o#oo.   .....oooooo### .o
....oooooo.....    ..ooooooooo..    ........................oooo## .o##oo...oo#o.##oo. .oo. ######### .o#oo.    ......oooo### .o
  ...........    ..ooooooooo...    .....oooo........    ....ooo### .o#oo....oo#o ##oo. .#o. ######## .oo#o..      .....ooo### .#
    .....     ...oooo###ooo...   .....ooooooo......      ...ooo### .o#oo....o#o. ##oo. .oo.  #####  ..o##o...       ...ooo### o#
           ...ooo########oo..   ....ooooooooo.....       ...ooo### .o#oo...oo#o. ##oo. .o#o.  ##   ..oo#oo....       ...oo###.o#
...   ....ooo####ooooo###oo.   ....ooooooooooo....       ...ooo### .o#oo...oo#o.##oo.. .o#o..    ..ooo##oo.......     ..oo## .oo
o....oooo###ooooo...ooo##oo.   ...oooooooooooo....       ...ooo### .o#oooooo#o. ##oo.. .o#oo......oo###ooo.........   ..oo## .#o
ooooo###ooo....    ...oo#oo.  ...ooooooooooooo....       ...ooo###..o#ooooo##o. ##oo.  .o##ooooooo###oooooooooooo...  ..oo## .#o
#####ooo..    #####  ..o##o.  ..oooooooooooooo....       ...ooo## .oo##ooo##o. ###oo.  ..o#########oooooooooooooooo.   .oo## o#o
###oo..   ########### ..o#o.  ..oooooooooooooo....      ...ooo### ..o######o.. ##ooo.  ..ooo###ooooo......ooooo##oo..  .oo## o#o
#ooo.. ############### .o#o.  ..ooooo###oooooo....      ...ooo### ..o#####oo. ###oo..   ..oooooo..........ooo#####oo.  .oo## o#.
#oo.  ######oooooo#### .o#o.  ..oooo#####oooooo....    ....ooo### ..oooooo.. ###ooo..   ........       ...oo#######o.  .oo##.o#.
#o.  ####oooooooooo#### .#o.  .ooooo#####oooooo...........oooo### ..ooooo.. ###ooo...                   ..oo##ooo##o.  .oo##.o#o
#o. ####oooooooooooo### .oo.  ..oooo#####oooooo..........oooo####  ....... ####ooo...                   ..o##ooooo#o.  .oo##.o#o
#o. ###ooooo.....oooo###.o#.  ..oooo#####oooooo.........ooooo####  .....  ####ooo....       .........   ..o##ooooo#o.  .oo##.o#o
#o. ##oooo........ooo### o#o  ..ooooo###oooooooo.......ooooo#####  ...   ####ooo....     .............  ..o##ooooo#o.  .oo##.o#o
#o.###ooo..........ooo## .#o. ..oooooooooooooooo.....oooooo######      #####ooo.....   ......oooooo...   .o#oooooo#o.  .oo##.o##
#o.###ooo...    ...ooo## .oo.  .oooooooooooooooooooooooooo######      ####oooo.....   .....ooooooooo...  .o#oooooo#o. ..oo##.oo#
#o.###oo...      ...oo###.o#.  ..oooooooooooooooooooooooo#######    #####oooo....    .....oooooooooo...  .o#oooooo#o. ..oo## .o#
oo.###oo...       ..ooo## o#o. ...oooooooooooooooooooooo#######    #####oooo....     ....oooooooooooo..  .o##oooo##o. .ooo## ..o
oo. ##oo...       ..ooo## .#o.  ...oooooooooooooooooooo######     #####oooo...       ...ooooo####oooo..  .o##oooo#o.  .ooo##  ..
o#. ##oo...       ..ooo## .o#.   ...ooooooooooooooooo#######     #####oooo..         ...oooo######ooo..  .o##ooo##o.  .oo####   
o#o ##ooo..       ..ooo###.o#o.   .....ooooooooooooo######       ####oooo..         ...oooo#######oooo.  .oo#####oo. ..ooo####  
.#o ##ooo...     ...ooo### o#oo.   .......ooooooooo#####   ...   ####ooo..   ....   ...ooo#########ooo..  .o#####o.  ..ooo######
.#o.##ooo...     ...ooo### .o#o..    .......oooooo#####  ......  ###ooo..   ......  ..ooo##########ooo..  .oo##ooo.  ..ooo######
.oo.###ooo.........oooo### .oo#o..      .....ooooo####  .......  ###ooo.   ..ooo..  ..ooo##########ooo..  ..ooooo.  ..oooo######
.o#. ##oooo........oooo###  .o##oo..     ....oooo####  ..oooo..  ##ooo..  .ooooo..  ..ooo####  #####oo..   ..oo..   ..oooooooooo
.o#. ###oooo.....ooooo##### ..o###oo...    ..oooo###  .ooooooo. ###oo..  .ooo#ooo.  ..oo####    ####ooo..   ....   ...oooooooooo
 o#o ###oooooooooooooo#####  ..oo###oo..   ...ooo### ..oo###oo. ###oo.. ..o####oo.  .ooo####    ####ooo..          ...oooooooooo
 o#o. ###oooooooooooo######  ...ooo###oo.   ..ooo### .oo####oo. ##ooo.  .o#####oo.  .ooo###     ####ooo...       ....ooooooooo..
.o#o. #####oooooooo########    ....ooo#oo.  ..ooo## ..o######o. ##oo..  oo######o.  .ooo###     ####ooo....    .....oooooooo... 
.o#o.  ####################       ...oo##o.  .ooo## .oo######o. ##oo.. .o##ooo#oo. ..oo####     ####oooo...........ooooooo....  
.o#oo.  ##################           ..o#o.  .ooo## .o###o##oo.###oo.  .o##ooo#oo  ..oo####     ####ooooo........oooooooo...   .
.o#oo..  ##########         ########  ..o#o. ..oo## .o##oo##o. ##ooo. .oo#ooo##o.  ..oo####    #####ooooooo..ooooooooooo...   .o
oo#oo...          ....      #########  .o#o. ..oo## .o###o##o. ##oo.. .o##ooo##o.  .ooo#####  #######oooooooooooooooooo...  ..o#
o##ooo...........oooo.....  ########### .o#.  .oo## .o######o. ##oo.  .o##ooo##o.  .ooo##############oooooooooooooooooo..  .oo#o
###ooooooooooooo#####ooo...  ########## .o#o  .oo## .oo####o..###oo.  .o###o##o.. ..ooo##############oooooooooooooooooo.. .o##o.
##ooooooooo####ooooo###oo..  ########### .#o. .oo## .oo###oo. ##ooo.  .o######o.  ..ooo#################o#########oooo..  .ooo..
oooooooo###oooo.....ooo##o.. ########### .oo. .oo### .ooooo.. ##oo..  .o#####o..  ..ooo############################ooo.. .o#o.  
ooooooo###oo...    ...oo#oo. ########### .o#. ..oo## ..ooo.. ###oo..  .oo###oo.  ..oooo############################ooo.  o#o. ##
....ooo##oo..         ..o#o.. ########## .o#. ..oo### ..... ###ooo.  ..oooooo.   ..ooooo####################  #####ooo. .oo. ###
.....o##oo.      .     ..o#o. ########## .o#o  .oo###      ####oo..  ..ooooo..  ...ooooo#################       ###oo.. .#o ####
   ..oo#o..   .......   .o#o.  ######### .o#o  .ooo####  #####ooo..  ...oo...   ..oooooooo##############  .....  ##oo.  oo. ####
#  ..oo#o.   .........   .o#o. ######### .o#o  .ooo##########ooo..    .....    ...oooooooooooooo####### ...ooo.. ##oo. .#o #####
##  .oo#o.  ....ooo....  .o#o.  ######## .o#o  ..ooo########oooo..    ...     ...oooooooooooooooo#####  .oooooo. ##oo. .#. #####
### .oo#o.  ...oooooo...  .o#o. #######  .o#o  ..oooo####oooooo..            ....oooooooooooooooo##### .oo####oo.##oo. oo.###oo#
### ..o#o.  ..oooooooo..  .o#o..  ##### ..o#o  ...ooooooooooo...           ....oooooooooooooooooo#### .oo##oo##o.##oo. oo ###ooo
#### .o#o.  ..oooooooo...  .o#o..      ..o#o..  ..ooooooooo....           ....ooooooooooooooooooo#### .o#ooooo#o.##o. .#. ##oooo
#### .o#o. ...ooooooooo..  .o##o...  ...oo#o.   ....oooo.....            ....oooooooooooooooooooo### .o##oo.oo#o.##o. .#.###oooo
#### .o#o. ...ooooooooo...  .o##oo.....oo#oo.    .........              ...oooooooooooooooooooooo### .o#o....o#o.##o. oo.###ooo#
#### .o#o. ...ooooooooo...   .o##oooooo##oo..     ....       .....     ...ooooooooooooooo....oooo### .#oo....o#o.##o. oo ###ooo#
#### .o#o.  ..oooooooooo..   ..oo#######oo...            ....ooo...   ...ooooooooooooooo.....oooo###.o#o.. ..o#o #oo. oo ###ooo#
#### .o#o.  ..oooooooooo...   ...ooooooo...          ...oooo##oooo.   ...oooooo#ooooooo.......ooo## .o#o.   .o#o #oo..#. ###oo##
GPR0 00000001
GPR1 00007ef0
GPR2 0000ff50
GPR3 00000000
GPR4 00000000
GPR5 00000081
GPR6 00800000
GPR7 0000001e
GPR8 0000fe67
GPR9 00000023
GPR10 00030910
GPR11 0000fe90
GPR12 88000022
GPR13 0000ffff
GPR14 00030000
GPR15 0000ffff
GPR16 0000ffff
GPR17 0000ffff
GPR18 0000ffff
GPR19 0000ffff
GPR20 0000ffff
GPR21 0000ffff
GPR22 0000ffff
GPR23 0000ffff
GPR24 00000000
GPR25 00030000
GPR26 00000001
GPR27 0000ffbc
GPR28 0000ffb4
GPR29 0000ff50
GPR30 00011fac
GPR31 0000ff70
CR 28000022
LR 00011fac
CTR 00000000
XER 00000000000000
SPRG0 00007f80
SPRG1 0000ff40
SPRG2 00000000
SPRG3 00000000
SRR0 00011ccc
SRR1 00004000
SDR1 00000000
DAR 00000000
DSISR 00000000
DABR 00000000
Decode PC 000011e4
EXIT =   0
- src//decode.v:892: Verilog $finish
Complete:  Committed 1720586 instructions, 679486 stall cycles, 2400248 cycles total
4.39user 0.00system 0:04.39elapsed 99%CPU (0avgtext+0avgdata 4988maxresident)k
0inputs+0outputs (0major+412minor)pagefaults 0swaps
$
~~~

Note that the IPC isn't too bad, at 0.71 instructions per clock.
However, this is a simple/small program, and real-world programs with
cache misses will bring this down.


# Copyright and Licence

Copyright (c) 2018-2022 Matt Evans

This work is licenced under the Solderpad Hardware License v2.1.  You
may obtain a copy of the License at
<https://solderpad.org/licenses/SHL-2.1/>.
