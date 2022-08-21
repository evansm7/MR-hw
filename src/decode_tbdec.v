/* decode_tbdec
 * TB and DEC counter/timer logic, including update from mttb.
 *
 * Copyright 2020-2022 Matt Evans
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

`define CYCLE_UPDATE_L2_M1 0 // 0 = /2, 1 = /4

module decode_tbdec(input wire         clk,
		    input wire 	       reset,

		    input wire 	       write_tbl,
		    input wire 	       write_tbu,
		    input wire 	       write_dec,
		    input wire [31:0]  write_val,

		    output wire [63:0] tb,
		    output wire [31:0] dec,
		    output wire        dec_trigger
		    );

   reg [63:0]                                as_TB /*verilator public*/;
   reg [31:0]                                as_DEC /*verilator public*/;

   assign tb = as_TB;
   assign dec = as_DEC;

   /* TB and DEC both change at F_CPU/2 or /4.  This is particularly important
    * for TB, as we don't want to do a 64-bit add per cycle (slow).  This logic
    * attempts to split the TB update, to reduce the critical path.
    */

   reg [31:0] wr_TBL_val; // Wire
   reg [31:0] wr_TBU_val; // Wire
   reg [31:0] wr_DEC_val; // Wire
   reg 	      update_TBL; // Wire
   reg 	      update_TBU; // Wire
   reg 	      update_DEC; // Wire
   reg [31:0] TBL_next; // Wire
   reg [31:0] TBU_next; // Wire
   reg [1:0]  cycle_count;
   reg [63:0] inter_TB /*verilator public*/;
   reg 	      DEC_out_r;

   assign dec_trigger = DEC_out_r;

   // New values for TB and DEC
   always @(*) begin
      // Flag an update based on delay counter:
      update_TBL = cycle_count[`CYCLE_UPDATE_L2_M1];
      update_TBU = cycle_count[`CYCLE_UPDATE_L2_M1];
      update_DEC = cycle_count[`CYCLE_UPDATE_L2_M1];

      if (as_TB[31:0] == 32'hffffffff) begin
	 TBL_next = 0;
	 TBU_next = as_TB[63:32] + 1;
      end else begin
	 TBL_next = as_TB[31:0] + 1;
	 TBU_next = as_TB[63:32];
      end

      if (write_tbl) begin
	 // Update the reg with the written value
	 wr_TBL_val = write_val;
	 // Force an update, even if cycle_count doesn't say it's ready
	 update_TBL = 1;
      end else begin
	 wr_TBL_val = TBL_next;
      end

      if (write_tbu) begin
	 wr_TBU_val = write_val;
	 update_TBU = 1;
      end else begin
	 wr_TBU_val = TBU_next;
      end

      if (write_dec) begin
	 wr_DEC_val = write_val;
	 update_DEC = 1;
      end else begin
	 wr_DEC_val = as_DEC - 1;
      end
   end

   always @(posedge clk) begin
      cycle_count    <= cycle_count + 1;

      /* These regs are written when their value is loaded via
       * write_val, or when a tick occurs.  The value written is
       * prepared by combinatorial logic above.
       */
      if (update_TBL)
	as_TB[31:0]  <= wr_TBL_val;
      if (update_TBU)
	as_TB[63:32] <= wr_TBU_val;
      if (update_DEC)
	as_DEC       <= wr_DEC_val;

      /* Finally, give the MSB of decrementer to IF, so it can decide when
       * to trigger an exception.  Delay it a cycle here for timing karma.
       */
      DEC_out_r      <= (as_DEC[31] == 1);

      if (reset) begin
	 as_TB          <= 64'h0;
	 inter_TB       <= 64'h0;
	 cycle_count    <= 2'h0;
	 DEC_out_r      <= 1'b0;
      end
   end


endmodule // decode_tbdec
