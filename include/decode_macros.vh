/* Macros used by decoder
 *
 * Copyright 2020 Matt Evans
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may
 * not use this file except in compliance with the License, or, at your option,
 * the Apache License version 2.0. You may obtain a copy of the License at
 *
 *  https://solderpad.org/licenses/SHL-2.1/
 *
 * Unless required by applicable law or agreed to in writing, any work
 * distributed under the License is distributed on an “AS IS” BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 */

`ifndef DECODE_MACROS_VH
`define DECODE_MACROS_VH

/* First, dummy macros that thunk between stuff the autogenerator outputs and basic signals: */

`define INST_BAT_IDX  ({inst_spr[5], inst_spr[2:0]})

`define CHECK_INST_RA (INST_RA == 0)

/* Register-locking guff: */

`define LOCK_GPR(x)             if(0)  // Unused
`define LOCK_SPR(x)             if(0)  // Unused
`define LOCK_GENERIC            de_locks_generic = 1
`define LOCK_XERCR_IF(x)        de_locks_xercr = ((``x``) != 0)
/* LR is an SPR, but is treated separately for writeback (there are cases writing 2 SPRs, but only where
 * LR is involved).  For locking and reading, it's Just An SPR.  This is kind of a FIXME, tidy this:
 */
`define LOCK_LR_IF(x)           if(0)  // Unused

`define UNLOCK_GPR_PORT0(x)     if(0)  // Unused
`define UNLOCK_GPR_PORT1(x)     if(0)  // Unused
`define UNLOCK_SPR(x)           if(0)  // Unused
`define UNLOCK_GENERIC          wb_unlocks_generic = 1
`define UNLOCK_XERCR_IF(x)      wb_unlocks_xercr = ((``x``) != 0)
`define UNLOCK_LR_IF(x)         if(0)  // Unused

`endif
