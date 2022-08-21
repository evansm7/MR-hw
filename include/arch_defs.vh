/* Architectural constants/definitions
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

`ifndef ARCH_DEFS_VH
`define ARCH_DEFS_VH

`define REGSZ           32
`define XERCRSZ         (32+3+7)
`define XERCR_CA        32
`define XERCR_OV        33
`define XERCR_SO        34
`define XERCR_BC        41:35

`define REG_ZERO        ({`REGSZ{1'b0}})
`define REG_ONES        ({`REGSZ{1'b1}})

`define RESET_PC_HI     32'hfff00100
`define RESET_PC_LO     32'h00000100
  /* FIXME size, packing-- macro to convert to/from packed formats */
`define RESET_MSR_HI    `MSR_IP
`define RESET_MSR_LO    32'h00000000

`define MSR_EE          32'h00008000
`define MSR_PR          32'h00004000
`define MSR_IP          32'h00000040
`define MSR_IR          32'h00000020
`define MSR_DR          32'h00000010

`define MR_PVR          32'hbb0a0001

`define BATU_valid_msk	32'hfffe1fff
`define BATL_valid_msk	32'hfffe003b

`define SR_valid_msk    32'hf0ffffff

`define SDR1_valid_msk  32'hffff01ff

`endif
