/* tlb_entry
 *
 * For an incoming address, match a TLB entry.
 * Supports:
 * - Match EA (async)
 * - Load value (on _|)
 * - Invalidate
 *
 * This TLB is intended to index/match on EA and fold in SR information.
 *
 * ME 210920
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

`define DTLB_PERMS_SIZE (2 /* PP */ + \
			 1 /* Ks */ + \
			 1 /* Kp */)

`define ITLB_PERMS_SIZE (1 /* UserEx */)


module tlb_entry(input wire         clk,
		 input wire 	    reset,

		 input wire [31:0]  ea, /* 11:0 unused, for debug */

		 /* 01: Inval always, 10: Inval if match, 00/11: no inval */
		 input wire [1:0]   invalidate,

		 input wire 	    load,
		 input wire [31:0]  new_ea,
		 input wire [31:0]  new_pa,
		 input wire [1:0]   new_pp,
		 input wire 	    new_Kp,
		 input wire 	    new_Ks,
		 input wire 	    new_cacheable,

		 output wire 	    match,
		 output wire [31:0] pa,
		 output wire [1:0]  pp,
		 output wire 	    Kp, /* Or UserEx */
		 output wire 	    Ks,
		 output wire 	    cacheable
		 );

   parameter INSTRUCTION = 0;

   reg 						  match_r; // Wire
   reg 						  match_inval_r; // Wire

   reg 						  valid;
   /* Storage */
   reg [19:0] 					  vpn;
   reg [19:0] 					  ppn;
   reg 						  wb;
   /* PP etc. */
   reg [((INSTRUCTION == 0) ? `DTLB_PERMS_SIZE : `ITLB_PERMS_SIZE)-1:0] perms;

   always @(posedge clk) begin
      if ((invalidate == 2'b01) ||
	  ((invalidate == 2'b10) && match_inval_r)) begin
	 valid       <= 1'b0;

      end else if (load) begin
	 /* Inval takes priority if both asserted */
	 valid       <= 1'b1;
	 vpn         <= new_ea[31:12];
	 ppn         <= new_pa[31:12];
	 wb          <= new_cacheable;
	 if (INSTRUCTION == 0) begin
	    perms[3:2] <= new_pp;
	    perms[1]   <= new_Ks;
	 end
	 perms[0]    <= new_Kp;
      end
   end

   always @(*) begin
      /* One page size, for now;  FIXME: blocks */
      match_r = valid && (ea[31:12] == vpn[19:0]);
      /* For invalidation-by-EA, bits EA[17:12] are tested for match (like PPC750): */
      match_inval_r = valid && (ea[17:12] == vpn[5:0]);
   end

   assign match = match_r;

   assign cacheable = match_r ? wb : 1'b0;
   assign pa = match_r ? {ppn, 12'h0} : 32'h0;
   assign pp = (INSTRUCTION == 0 && match_r) ? perms[3:2] : 2'h0;
   assign Ks = (INSTRUCTION == 0 && match_r) ? perms[1] : 1'b0;
   assign Kp = match_r ? perms[0] : 1'b0;

endmodule // mmu_bat_match
