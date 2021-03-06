/*
 * This file is part of the MIPS unpacker for the Supercard DSTwo.
 *
 * Copyright 2017 Nebuleon Fumika <nebuleon.fumika@gmail.com>
 *
 * It is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * It is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with it.  If not, see <http://www.gnu.org/licenses/>.
*/

#include "mips.h"

    .text
    .set     noreorder
    .set     at

    .extern  __stack
    .extern  __text_start
    .extern  __text_end
    .extern  __data_start
    .extern  filtered_data
    .extern  __bss_start
    .extern  __bss_end
    .extern  memcpy
    .extern  memset
    .extern  filtered_size
    .extern  instruction_count
    .extern  __heap_start
    .extern  __heap_end
    .extern  _heap_init
    .extern  entry

# A macro after which execution is sent to the next instruction in the file,
# but in KSEG0 (cached).
.macro CACHED
    .set     push
    .set     noreorder
    .set     noat

    bal     1f                         # grab the address of the next label 1:
    lui     AT, 0xDFFF                 # (delay slot) load the mask that sends
1:  ori     AT, AT, 0xFFFF             #   ra into KSEG0
    addiu   ra, ra, 20                 # skip 5 further instructions after 1:
    and     ra, ra, AT
    jr      ra
    nop                                # cannot delay usefully here

    .set     pop
.endm

# A macro after which execution is sent to the next instruction in the file,
# but in KSEG1 (uncached).
.macro UNCACHED
    .set     push
    .set     noreorder
    .set     noat

    bal     1f                         # grab the address of the next label 1:
    lui     AT, 0x2000                 # (delay slot) mask that sends to KSEG1
1:  addiu   ra, ra, 16                 # skip 4 further instructions after 1:
    or      ra, ra, AT
    jr      ra
    nop                                # cannot delay usefully here

    .set     pop
.endm

    .ent     _start
    .global  _start
    .type    _start,@function

_start:
    /* BEGIN MAGIC SECTION - SET BY THE PACKER */
    lui     s4, 0                      # s4 = filtered size
    ori     s4, s4, 0
    lui     s5, 0                      # s5 = instruction count
    ori     s5, s5, 0
    /* END MAGIC SECTION - SET BY THE PACKER */

    /* We're still technically handling the Reset exception, so we don't need
     * to disable interrupts and exceptions. The plugin code will handle that
     * when it installs its exception handler. However, we do need to... */
    UNCACHED

    /* ... initialise the cache. */
    # Enable the use of the cache for accesses through KSEG0.
    li      v0, 3
    mtc0    v0, C0_Config

    # For each index at 0x8000_0000 + 16 KiB (cache size), write an empty
    # cache tag to the data cache and the instruction cache.
    # Important: 0x8000_0000 is not mapped through the MMU. Virtual addresses
    # can raise exceptions if they're not mapped.
    li      v0, 0x80000000
    ori     v1, v0, 0x4000
    mtc0    zero, C0_TagLo
    mtc0    zero, C0_TagLo, 2
    mtc0    zero, C0_TagHi
    mtc0    zero, C0_TagHi, 2

1:  cache   DCIndexStTag, 0(v0)
    addiu   v0, v0, 0x20               # cache lines are 32 bytes
    bne     v0, v1, 1b
    cache   ICIndexStTag, -0x20(v0)

    sync

    CACHED

    /* Invalidate the BTB */
    mfc0    v0, C0_Config, 7
    nop
    ori     v0, v0, 0x2
    mtc0    v0, C0_Config, 7
    nop

    /* Set up the stack, preparing for the jump to C */
    la      sp, __stack

    la      t3, __text_start
    la      a0, __text_end

    /* Copy code from the load address to the execution address */
    la      a1, 0x80002000             # from 0x8000_2000
    move    v1, t3                     # to __text_start
    /* [No check for there being no code - we're running some right now!] */
1:  lw      v0, 0(a1)
    # Let the load complete in parallel with these.
    addiu   a1, a1, 4
    addiu   v1, v1, 4
    bne     v1, a0, 1b                 # until t1 is __text_end
    sw      v0, -4(v1)                 # (delay slot) store to 0(old v1)
    # a1 is now 0x8000_2000 + .text size.

    /* Write back and invalidate both caches for the code at __text_start */
    li      s0, ~0x1F                  # mask to round down to a cache line
    and     v1, t3, s0                 # from __text_start, rounded down
    addiu   t0, a0, 0x1F               # until __text_end, rounded up
    and     t0, t0, s0
    /* [No check for there being no code - we're running some right now!] */
2:  cache   DCHitWB, 0(v1)
    addiu   v1, v1, 0x20               # cache lines are 32 bytes
    bne     v1, t0, 2b
    cache   ICHitInv, -0x20(v1)        # (delay slot) CACHE on 0(old t0)

    sync

    /* Invalidate the BTB */
    mfc0    v0, C0_Config, 7
    nop
    ori     v0, v0, 0x2
    mtc0    v0, C0_Config, 7
    nop

    /* Jump to ourselves at 3:. Since the linker thinks we're at __text_start,
     * this J instruction will actually transfer us to the new copy. */
    j       3f                         # v delay slot v
    /* Now that the code is copied, copy data too, with memcpy */
    # a1 is already 0x80002000 + .text size, the source of the copy.
    # a0 is already __text_end, the destination of the copy.
    # a2 needs to become (filtered_data - a0) + s4 == s4 - a0 + filtered_data.
    subu    v0, s4, a0
3:  la      a2, filtered_data
    jal     memcpy
    addu    a2, a2, v0                 # (delay slot)

    /* Clear the uninitialised data section */
    la      a0, __bss_start            # start = __bss_start
    la      a2, __bss_end
    subu    a2, a2, a0                 # count = __bss_end - __bss_start
    jal     memset
    move    a1, zero                   # (delay slot) byte = 0

    /* Now that the uninitialised data section is cleared, store the filtered
     * size and instruction count to memory */
    sw      s4, filtered_size
    sw      s5, instruction_count

    /* Initialise the heap for malloc, realloc and free. */
    la      a0, __heap_start
    lui     a1, %hi(__heap_end)
    jal     _heap_init
    addiu   a1, a1, %lo(__heap_end)    # (delay slot)

    /* Call void* entry(void). */
    jal     entry
    nop                                # cannot delay usefully here

    beq     v0, zero, exit_fail
    # This BEQ has a harmless delay slot from below.

    /* Write back and invalidate the data cache. */
    # Important: 0x8000_0000 is not mapped through the MMU and is cacheable.
    # Virtual addresses can raise exceptions if they're not mapped; using an
    # uncacheable address in a CACHE operation is UNDEFINED.
    lui     v1, 0x8000
    ori     t1, v1, 0x2000             # preload 0x8000_2000 for the next loop
    ori     t0, v1, 0x4000
4:  addiu   v1, v1, 0x20               # cache lines are 32 bytes
    bne     v1, t0, 4b
    cache   DCIndexWBInv, -0x20(v1)    # (delay slot) CACHE on 0(old v1)

    /* Write back and invalidate the instruction cache for code at 0x8000_2000
     * until the extraction end address returned by entry. */
    beq     v0, t1, exit_fail          # check for nothing extracted
    addiu   v1, v0, 0x1F               # (delay slot) until v0, rounded up
    and     v1, v1, s0
5:  addiu   t1, t1, 0x20               # cache lines are 32 bytes
    bne     t1, v1, 5b
    cache   ICHitInv, -0x20(t1)        # (delay slot) CACHE on 0(old t1)

    sync

    /* Invalidate the BTB */
    mfc0    v0, C0_Config, 7
    nop
    ori     v0, v0, 0x2
    mtc0    v0, C0_Config, 7
    nop

    j       0x80002000                 # transfer control to the unfiltered executable
    nop                                # cannot delay usefully here

exit_fail:
    wait
    b       exit_fail
    nop                                # cannot delay usefully here

    .end     _start
