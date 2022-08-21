/* General-purpose register file:
 *
 * 32x 32-bit registers
 *
 * 3x read ports (async)
 *
 * 2x write ports (sync)
 *
 *
 * ME 23/2/20
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

`include "arch_defs.vh"


module gpregs(input wire         clk,
	      input wire 	 reset,

	      input wire [31:0]  write_a_val,
	      input wire [4:0] 	 write_a_select,
	      input wire 	 write_a_en,

	      input wire [31:0]  write_b_val,
	      input wire [4:0] 	 write_b_select,
	      input wire 	 write_b_en,

	      input wire [4:0] 	 read_a_select,
	      output wire [31:0] read_a_val,

	      input wire [4:0] 	 read_b_select,
	      output wire [31:0] read_b_val,

	      input wire [4:0] 	 read_c_select,
	      output wire [31:0] read_c_val
	      );


   reg [31:0] 			 registers [31:0] /*verilator public*/;

   reg [31:0] 			 a;
   reg [31:0] 			 b;
   reg [31:0] 			 c;

   // (Synchronous) writes:
   always @(posedge clk) begin
      if (write_a_en && write_b_en && (write_a_select == write_b_select)) begin
`ifdef SIM
         $fatal(1, "gpregs: Both ports writing reg %d", write_a_select);
`endif
      end

      // Using blah[idx] <= foo syntax seemed to generate a lot of stuff...
      if (write_a_en && write_a_select == 5'h00)
        registers[5'h00] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h00)
        registers[5'h00] <= write_b_val;

      if (write_a_en && write_a_select == 5'h01)
        registers[5'h01] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h01)
        registers[5'h01] <= write_b_val;

      if (write_a_en && write_a_select == 5'h02)
        registers[5'h02] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h02)
        registers[5'h02] <= write_b_val;

      if (write_a_en && write_a_select == 5'h03)
        registers[5'h03] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h03)
        registers[5'h03] <= write_b_val;

      if (write_a_en && write_a_select == 5'h04)
        registers[5'h04] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h04)
        registers[5'h04] <= write_b_val;

      if (write_a_en && write_a_select == 5'h05)
        registers[5'h05] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h05)
        registers[5'h05] <= write_b_val;

      if (write_a_en && write_a_select == 5'h06)
        registers[5'h06] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h06)
        registers[5'h06] <= write_b_val;

      if (write_a_en && write_a_select == 5'h07)
        registers[5'h07] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h07)
        registers[5'h07] <= write_b_val;

      if (write_a_en && write_a_select == 5'h08)
        registers[5'h08] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h08)
        registers[5'h08] <= write_b_val;

      if (write_a_en && write_a_select == 5'h09)
        registers[5'h09] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h09)
        registers[5'h09] <= write_b_val;

      if (write_a_en && write_a_select == 5'h0a)
        registers[5'h0a] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h0a)
        registers[5'h0a] <= write_b_val;

      if (write_a_en && write_a_select == 5'h0b)
        registers[5'h0b] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h0b)
        registers[5'h0b] <= write_b_val;

      if (write_a_en && write_a_select == 5'h0c)
        registers[5'h0c] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h0c)
        registers[5'h0c] <= write_b_val;

      if (write_a_en && write_a_select == 5'h0d)
        registers[5'h0d] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h0d)
        registers[5'h0d] <= write_b_val;

      if (write_a_en && write_a_select == 5'h0e)
        registers[5'h0e] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h0e)
        registers[5'h0e] <= write_b_val;

      if (write_a_en && write_a_select == 5'h0f)
        registers[5'h0f] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h0f)
        registers[5'h0f] <= write_b_val;

      if (write_a_en && write_a_select == 5'h10)
        registers[5'h10] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h10)
        registers[5'h10] <= write_b_val;

      if (write_a_en && write_a_select == 5'h11)
        registers[5'h11] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h11)
        registers[5'h11] <= write_b_val;

      if (write_a_en && write_a_select == 5'h12)
        registers[5'h12] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h12)
        registers[5'h12] <= write_b_val;

      if (write_a_en && write_a_select == 5'h13)
        registers[5'h13] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h13)
        registers[5'h13] <= write_b_val;

      if (write_a_en && write_a_select == 5'h14)
        registers[5'h14] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h14)
        registers[5'h14] <= write_b_val;

      if (write_a_en && write_a_select == 5'h15)
        registers[5'h15] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h15)
        registers[5'h15] <= write_b_val;

      if (write_a_en && write_a_select == 5'h16)
        registers[5'h16] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h16)
        registers[5'h16] <= write_b_val;

      if (write_a_en && write_a_select == 5'h17)
        registers[5'h17] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h17)
        registers[5'h17] <= write_b_val;

      if (write_a_en && write_a_select == 5'h18)
        registers[5'h18] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h18)
        registers[5'h18] <= write_b_val;

      if (write_a_en && write_a_select == 5'h19)
        registers[5'h19] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h19)
        registers[5'h19] <= write_b_val;

      if (write_a_en && write_a_select == 5'h1a)
        registers[5'h1a] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h1a)
        registers[5'h1a] <= write_b_val;

      if (write_a_en && write_a_select == 5'h1b)
        registers[5'h1b] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h1b)
        registers[5'h1b] <= write_b_val;

      if (write_a_en && write_a_select == 5'h1c)
        registers[5'h1c] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h1c)
        registers[5'h1c] <= write_b_val;

      if (write_a_en && write_a_select == 5'h1d)
        registers[5'h1d] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h1d)
        registers[5'h1d] <= write_b_val;

      if (write_a_en && write_a_select == 5'h1e)
        registers[5'h1e] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h1e)
        registers[5'h1e] <= write_b_val;

      if (write_a_en && write_a_select == 5'h1f)
        registers[5'h1f] <= write_a_val;
      else if (write_b_en && write_b_select == 5'h1f)
        registers[5'h1f] <= write_b_val;

   end

   // Reads:
   always @(*) begin
      a = (read_a_select >= 5'd0 && read_a_select <= 5'd31) ? registers[read_a_select] : 32'h0;
      b = (read_b_select >= 5'd0 && read_b_select <= 5'd31) ? registers[read_b_select] : 32'h0;
      c = (read_c_select >= 5'd0 && read_c_select <= 5'd31) ? registers[read_c_select] : 32'h0;
   end

   assign read_a_val = a;
   assign read_b_val = b;
   assign read_c_val = c;

endmodule // gpregs
