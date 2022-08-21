/* TLB
 *
 * Generic parameterisable TLB:  lookups and permission checks
 *
 * On miss, requests to walker interface.
 *
 * Decouple request (enable_lookup->hit) and the walk FSM; a fetch (leading to
 * a lookup) might be stopped before completion.  When this happens, the next
 * request might have to wait for the walk resulting from the previous to
 * complete.
 *
 * ME 16/9/20
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
`include "decode_enums.vh"

module tlb(input wire               clk,
	   input wire 		    reset,

	   /* Operation (qualified by enable):
	    * 00 = regular lookup
	    * 01 = TLBI ALL
	    * 10 = TLBI VA
	    */
	   input wire [1:0] 	    operation,
	   input wire 		    enable,

	   input wire 		    privileged,
	   input wire 		    RnW,
	   input wire [`REGSZ-1:0]  virtual_addr,

	   output wire [`REGSZ-1:0] physical_addr,
	   output wire 		    cacheable,

	   output wire 		    hit,
	   output wire [2:0] 	    fault_type, // MMU_FAULT_xxx

	   /* Insert entry: assert load for 1 cycle */
	   input wire 		    load,
	   input wire [31:0] 	    new_ea,
	   input wire [31:0] 	    new_pa,
	   input wire [1:0] 	    new_pp,
	   input wire 		    new_Kp,
	   input wire 		    new_Ks,
	   input wire 		    new_cacheable
	   );

   parameter TLB_ENTRIES = 16;

   reg [2:0] 			    fault;  // Wire

   //////////////////////////////////////////////////////////////////////////////
   // TLB entries

   reg [7:0] 			    idx;
   wire [TLB_ENTRIES-1:0] 	    tlb_n_hit;
   wire [31:0] 			    pa_n[TLB_ENTRIES-1:0]; // Wire
   wire [1:0] 			    pp_n[TLB_ENTRIES-1:0]; // Wire
   wire 			    kp_n[TLB_ENTRIES-1:0]; // Wire
   wire 			    ks_n[TLB_ENTRIES-1:0]; // Wire
   wire 			    cach_n[TLB_ENTRIES-1:0]; // Wire

   wire 			    tlb_hit;

   /* Array of TLB entries */
   genvar 			    i;
   generate
      for (i = 0; i < TLB_ENTRIES; i = i + 1) begin: tlbs
	 tlb_entry TLBE(.clk(clk),
			.reset(reset),

			.ea(virtual_addr), // Terminology mismatch

			/* Invalidate type:
			 * 00 = NONE
			 * 01 = ALL
			 * 10 = by matching EA
			 */
			.invalidate(enable ? operation : 2'b00),

			/* Update/refill */
			.load(load && (idx == i)),
			.new_ea(new_ea),
			.new_pa(new_pa),
			.new_pp(new_pp),
			.new_Kp(new_Kp),
			.new_Ks(new_Ks),
			.new_cacheable(new_cacheable),

			/* Outputs */
			.match(tlb_n_hit[i]),
			.pa(pa_n[i]),
			.pp(pp_n[i]),
			.Kp(kp_n[i]),
			.Ks(ks_n[i]),
			.cacheable(cach_n[i])
			);
      end
   endgenerate

   /* Each TLB entry flags its own match/hit, and outputs its contents on hit;
    * on miss, outputs are zero.  That enables this component to cheaply OR
    * the outputs together instead of mux/whatever.
    */
   assign tlb_hit = enable && |tlb_n_hit;

   reg [31:0] 			    pa_r[TLB_ENTRIES-1:0]; // Wire
   reg [1:0] 			    pp_r[TLB_ENTRIES-1:0]; // Wire
   reg 				    kp_r[TLB_ENTRIES-1:0]; // Wire
   reg 				    ks_r[TLB_ENTRIES-1:0]; // Wire
   reg 				    cach_r[TLB_ENTRIES-1:0]; // Wire

   reg [9:0] 			    l; // Loop counter

   /* Calculate final output: (fancy OR) */
   always @(*) begin
      for (l = 0; l < TLB_ENTRIES; l = l + 1) begin
	 if (l == 0) begin
	    pa_r[l] = pa_n[l];
	    pp_r[l] = pp_n[l];
	    kp_r[l] = kp_n[l];
	    ks_r[l] = ks_n[l];
	    cach_r[l] = cach_n[l];
	 end else begin
	    pa_r[l] = pa_r[l-1] | pa_n[l];
	    pp_r[l] = pp_r[l-1] | pp_n[l];
	    kp_r[l] = kp_r[l-1] | kp_n[l];
	    ks_r[l] = ks_r[l-1] | ks_n[l];
	    cach_r[l] = cach_r[l-1] | cach_n[l];
	 end
      end
   end

   wire [31:0] 			    pa;
   wire [1:0] 			    pp;
   wire 			    kp;
   wire 			    ks;
   wire 			    cach;

   /* The actual outputs of the TLB lookup step (zero if !tlb_hit) */
   assign pa = {pa_r[TLB_ENTRIES-1][`REGSZ-1:12], virtual_addr[11:0]};
   assign pp = pp_r[TLB_ENTRIES-1];
   assign kp = kp_r[TLB_ENTRIES-1];
   assign ks = ks_r[TLB_ENTRIES-1];
   assign cach = cach_r[TLB_ENTRIES-1];

   //////////////////////////////////////////////////////////////////////////////

   /* Check permissions */
   reg key; // Wire

   always @(*) begin
      fault = `MMU_FAULT_NONE;

      /* TF is 01, NX is 11.
       * Translation fault (PT miss) only happens when a walk comes back w/o
       * an entry.  A PF can happen when a no-access page is encountered on
       * walk (and this is not cached).
       *
       * NX isn't cached, so is also evaluated (for ITLB only) on PTW too.
       *
       * Finally, PF happens when an existing/hitting TLB entry is unsuitable
       * either because it prevents write or prevents access due to privilege.
       */

      key = privileged ? ks : kp;

      if (tlb_hit) begin
	 if ((       pp == 2'b11 && !RnW) ||
	     (key && pp == 2'b00        ) ||
	     (key && pp == 2'b01 && !RnW)) begin
	    fault = `MMU_FAULT_PF;
	 end
      end
   end

   ///////////////////////////////////////////////////////////////////////////

   /* TLB refill policy:  For now, "random".  FIXME: Improve this, e.g. LRU
    */
   always @(posedge clk) begin
      if (idx < TLB_ENTRIES-1) begin
	 idx <= idx + 1;
      end else begin
	 idx <= 0;
      end

`ifdef SIM
      /* Multi-hit checking */
      if ((tlb_n_hit & (tlb_n_hit-1)) != 0) begin
	 $fatal(1, "TLB multi-hit (%x) for VA %x",
		tlb_n_hit, virtual_addr);
      end
`endif

      if (reset) begin
	 idx <= 0;
      end
   end

   ///////////////////////////////////////////////////////////////////////////


   assign physical_addr = pa;
   assign cacheable = cach;

   assign hit = tlb_hit;
   assign fault_type = fault;

endmodule // TLB
