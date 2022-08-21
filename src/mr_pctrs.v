/* mr_pctrs
 *
 * Simple counters for performance-related events
 *
 * 24 May 2021
 *
 * Copyright 2021 Matt Evans
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

module mr_pctrs(input wire        clk,
		input wire 	  reset,

		input wire [63:0] pctrs
		);

   parameter NUM_CTRS = 64;

   /* All this module does is instantiate some counters, and give naems to the values.
    * The counters are 32b saturating up-counters.
    *
    * In future, it will have features:
    * - APB access to counter values
    * - Value capture on match/overflow
    * - Global reset
    */

   // Extra pipeline reg on pctrs:
   reg [63:0] 			  pctrsl;

   always @(posedge clk)
     pctrsl <= pctrs;

   // The counters:
   reg [31:0] 			  ctrs [NUM_CTRS-1:0];

   genvar 			  i;
   generate
      for (i = 0; i < NUM_CTRS; i = i + 1) begin
	 always @(posedge clk) begin
	    if (pctrsl[i] && ctrs[i] != 32'hffffffff)
	      ctrs[i] <= ctrs[i] + 1;

            if (reset)
	      ctrs[i] <= 32'h0;
	 end
      end
   endgenerate

   // A cycle counter:
   reg [31:0] 			  cctr;
   always @(posedge clk) begin
      if (cctr != 32'hffffffff)
	cctr <= cctr + 1;

      if (reset)
	cctr <= 32'h0;
   end

   // Trace-visible signals:
   wire [31:0] pctr_cycles = cctr;

   wire [31:0] pctr_inst_commit = ctrs[14];
   wire [31:0] pctr_fault = ctrs[13];
   wire [31:0] pctr_mem_stall = ctrs[12];
   wire [31:0] pctr_exe_stall = ctrs[11];
   wire [31:0] pctr_decode_stall = ctrs[10];
   wire [31:0] pctr_if_fetching = ctrs[9];
   wire [31:0] pctr_if_fetching_stalled = ctrs[8];
   wire [31:0] pctr_if_valid_instr = ctrs[7];
   wire [31:0] pctr_if_mmu_ptws = ctrs[6];
   wire [31:0] pctr_de_stall_operands = ctrs[5];
   wire [31:0] pctr_mem_access = ctrs[4];
   wire [31:0] pctr_mem_access_fault = ctrs[3];
   wire [31:0] pctr_mem_mmu_ptws = ctrs[2];
   wire [31:0] pctr_mem_cacheable_unaligned_8B = ctrs[1];
   wire [31:0] pctr_mem_cacheable_unaligned_CL = ctrs[0];

endmodule // mr_pctrs
