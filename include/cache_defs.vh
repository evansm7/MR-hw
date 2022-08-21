/* Cache request definitions
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

`ifndef CACHE_DEFS_VH
`define CACHE_DEFS_VH

// Request types:
`define C_REQ_UC_READ   4'b0000
`define C_REQ_UC_WRITE  4'b0001
`define C_REQ_C_READ    4'b0010
`define C_REQ_C_WRITE   4'b0011
`define C_REQ_INV       4'b0100
`define C_REQ_CLEAN_INV 4'b0101
`define C_REQ_CLEAN     4'b0110
`define C_REQ_ZERO      4'b0111
`define C_REQ_INV_SET   4'b1000
// FIXME: sync/drain operations.

`endif
