/*
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

`ifndef DECODE_SIGNALS_VH
`define DECODE_SIGNALS_VH

`include "auto_decoder_signals.vh"

`define DEC_NAME_LEN            20
`define DEC_SIGS_DECLARE        reg [(8*`DEC_NAME_LEN)-1:0] name; \
                                reg de_locks_generic; \
                                reg de_locks_xercr; \
                                reg wb_unlocks_generic; \
                                reg wb_unlocks_xercr; \
                                `DEC_AUTO_SIGS_DECLARE

`define DEC_SIGS_SIZE (`DEC_AUTO_SIGS_SIZE + 4 + (20*8))

`define DEC_SIGS_BUNDLE         de_locks_generic, \
                                de_locks_xercr, \
                                wb_unlocks_generic, \
                                wb_unlocks_xercr, \
                                name, \
                                `DEC_AUTO_SIGS_BUNDLE
`define DEC_RANGE_NAME (`DEC_AUTO_SIGS_SIZE+(8*`DEC_NAME_LEN)-1):(`DEC_AUTO_SIGS_SIZE)

`endif
