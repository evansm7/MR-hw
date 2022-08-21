/* decode_inst
 * Wrap/contain the auto-generated instruction decode combinatorial logic.
 *
 * Copyright 2020-2021 Matt Evans
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

`include "decode_signals.vh"
`include "decode_macros.vh"
`include "decode_enums.vh"


module decode_inst(input wire  [31:0] 		    instruction,
                   output wire [`DEC_SIGS_SIZE-1:0] decode_bundle
                   );

   wire [4:0]                                           INST_RA = instruction[20:16];
   wire [4:0] 						INST_RB = instruction[15:11];
   wire [4:0] 						INST_RT = instruction[25:21];
   wire [4:0] 						INST_RS = instruction[25:21];
   wire 						INST_LK = instruction[0];
   wire 						INST_Rc = instruction[0];
   wire 						INST_SO = instruction[10];
   wire [3:0] 						INST_SR  = instruction[19:16];
   wire [9:0] 						INST_SPR = {instruction[15:11], instruction[20:16]};
   wire [2:0] 						bat_idx  = {INST_SPR[2:0]};

   reg [`DEC_SIGS_SIZE-1:0] 				decode_bundle_sigs;

   `DEC_SIGS_DECLARE;


   always @(*)
     begin
	de_locks_generic = 0;
	de_locks_xercr = 0;
	wb_unlocks_generic = 0;
	wb_unlocks_xercr = 0;
	name = {(`DEC_NAME_LEN*8){1'b0}};
	/* Decode inst into bundle: */
`include "auto_decoder.vh"
     end

   always @(*)
     begin
        decode_bundle_sigs = {`DEC_SIGS_BUNDLE};
     end
   assign decode_bundle = decode_bundle_sigs;

endmodule
