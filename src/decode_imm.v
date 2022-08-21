/* Immediate decoder
 *
 * ME 29/2/2020
 *
 * Copyright 2020, 2022 Matt Evans
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
`include "decode_enums.vh"
`include "arch_defs.vh"


module decode_imm(input wire [31:0]        instruction,
		  input wire [3:0] 	   select,
		  output wire [`REGSZ-1:0] out
		  );

   reg [`REGSZ-1:0] 			   outval;

   assign out = outval;

   always @(*) begin
      case (select)
	`DE_IMM_D: // And DE_IMM_SI
	  outval = {{(`REGSZ-16){instruction[15]}}, instruction[15:0]};

	`DE_IMM_SI_HI:
	  outval = {{(`REGSZ-32){instruction[15]}}, instruction[15:0], 16'h0000};

	`DE_IMM_UI:
	  outval = {{(`REGSZ-16){1'b0}}, instruction[15:0]};

	`DE_IMM_UI_HI:
	  outval = {{(`REGSZ-32){1'b0}}, instruction[15:0], 16'h0000};

	`DE_IMM_TO: // And DE_IMM_BT
	  outval = {{(`REGSZ-5){1'b0}}, instruction[25:21]};

	`DE_IMM_LI:
	  outval = {{(`REGSZ-26){instruction[25]}}, instruction[25:2], 2'h0};

	`DE_IMM_SH: // And DE_IMM_BB
	  outval = {{(`REGSZ-5){1'b0}}, instruction[15:11]};

	`DE_IMM_SH_MB_ME: // And MB_ME
	  outval = {{(`REGSZ-15){1'b0}},
		    instruction[15:11], instruction[10:6], instruction[5:1]};

	`DE_IMM_FXM:
	  outval = {{(`REGSZ-8){1'b0}}, instruction[19:12]};

	`DE_IMM_SR: /* Places SR field in [31:28]; irrelevant for 64-bit impls. */
	  outval = {instruction[19:16], {(`REGSZ-4){1'b0}}};

	`DE_IMM_BA:
	  outval = {{(`REGSZ-5){1'b0}}, instruction[20:16]};

	`DE_IMM_BF:
	  outval = {{(`REGSZ-3){1'b0}}, instruction[25:23]};

	`DE_IMM_BD:
	  outval = {{(`REGSZ-16){instruction[15]}}, instruction[15:2], 2'h0};

	`DE_IMM_BFA:
	  outval = {{(`REGSZ-3){1'b0}}, instruction[20:18]};

	default:
	  outval = `REG_ZERO;

      endcase
   end


endmodule // decode_imm


/* port C uses: TO, BF, BT (same as TO), SH_MB_ME, MB_ME (same as SH_MB_ME),
 i.e. only 3 distinct values.

 port B uses: SI, SI_HI, BFA, BB, SH, UI, UI_HI, SR, D (same as SI),
 i.e. 8 values.

 port A uses: SI, UI, BD, LI, BT, FXM
 i.e. 6 values.
 */
