/* mmu
 *
 * This component contains a TLB and BAT lookup logic, i.e. full MMU.
 * PTWs are requested to an external PTW unit, if necessary.
 *
 * If !translation_en, output paddress = input vaddress, and cacheable_access=0.
 * (A default memory map might be applied externally to determine cacheable vs
 * non-cacheable regions.)  Otherwise:
 *
 * On a cycle having lookup=1, vaddress is translated and, if a hit, valid=1 in
 * same cycle.  If a miss, valid=0 and becomes 1 later.
 *
 * When valid=1:
 * If fault_type=0 then paddress, cacheable_access are valid.
 * If fault_type!=0, gives fault code for access.
 *
 * translation_en can change per cycle (e.g. can be used to generally disable
 * TLB lookup (and PTW!) when an access is not being performed).
 *
 * Or, translation_en can stay high across cycles and vaddress can change
 * after any cycle where valid=1.  Inputs must not change when translating
 * and valid=0.
 *
 *
 * ME 170820
 *
 * Parameters:
 * 	MMU_STYLE:  0,1,2.  0=no MMU or BATs, 1=BATs only, 2=full MMU+BATs
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

/*
 * Gritty details:
 * - TLB will be fully-associative
 * - To reduce the size of the TLB entry and reduce the critical path,
 *   the segment registers are only looked up during a miss/refill.
 * - The SR data is therefore folded into the TLB entry itself (so looks
 *   like a familiar 20b VPN to 20b PPN lookup).
 * - This means any SR change needs to invalidate *all* TLB entries.
 * - This will mean context switches start a new process cold, and I should
 *   look at prefetching (e.g. from r1, lr, PC etc.) upon implicit invalidate.
 * - The SR change kicks off a 1-cycle flash invalidate of the TLB.
 * - PTW unit can have a centralised TLB too; it should receive TLBI messages.
 *
 * Though I really don't want to do hardware update of Ref/Changed bits,
 * they don't look optional:
 * - TLB stores any C=0 page as RO
 * - TLB treats hit for write on a RO page as a miss, and raises the fault
 *   only if the PTE is truly RO.  Otherwise, the PTW does a read-mod-write
 *   to update the PTE.
 * - PTW does a read-mod-write on each fetch having R=0, to set R=1.
 * - Could optimise this a little to differentiate true RO pages (fault
 *   early for COW etc., tho probably in the noise).
 * HOWEVER: MR-ISS doesn't implement them... Linux is fine. :P
 * It doesn't even cause a fault if C=0!  (Linux runs when C=0 is treated as
 * RO, but also if C is ignored.)
 *
 * TLB contents:
 *  [19:0]  VPN  (Tag)
 *  [39:20] PPN  (Data)
 *  [41:40] PP   (DTLB only)
 *  [42]    Kp   (DTLB)   /   UserExecutable (ITLB)
 *  [43]    Ks   (DTLB)   /   SvcExecutable (ITLB)
 *  [44]    Cacheable
 *
 * Permissions for ITLB:
 * - NX pages do not appear in ITLB.  When PTW, returns a FAULT_PERMS_NX.
 * - No concept of writable.
 * - Only needs 1 permission bit for "accessible by user".
 *
 * Permissions for DTLB:
 * - Kp/Ks
 * - PP
 */

`include "arch_defs.vh"
`include "decode_enums.vh"


module mmu(input wire                     clk,
	   input wire 			  reset,

	   /* Input request */
	   input wire 			  translation_en,
	   input wire 			  privileged,
	   input wire 			  RnW,
	   input wire [`REGSZ-1:0] 	  vaddress,

	   /* Output translation */
	   output wire [`REGSZ-1:0] 	  paddress,
	   output wire 			  cacheable_access,
	   output wire [2:0] 		  fault_type, // MMU_FAULT_xxx, or 0
	   output wire 			  valid,

	   /* Maintenance: */
	   input wire 			  inval_req,
	   input wire 			  inval_type, // 0=page, 1=all
	   input wire [`REGSZ-1:0] 	  inval_addr,
	   output wire 			  inval_ack,

	   /* BAT regs: */
	   input wire [(64*`NR_BATs)-1:0] bats,

	   /* Segment regs are only used by PTW. */

	   /* Pctrs */
	   output wire 			  pctr_mmu_ptws,

	   /* PTW interface: */
	   output wire [31:0] 		  ptw_addr, // 11:0 zero, for readability
	   output wire 			  ptw_req,
	   input wire [`PTW_PTE_SIZE-1:0] ptw_tlbe,
	   input wire [1:0] 		  ptw_fault, /* PTW_FAULT_* */
	   input wire 			  ptw_ack
	   );

   parameter                        INSTRUCTION = 0;
   parameter                        TLB_ENTRIES = 16;
   /* This param controls translation-off cacheability: */
   parameter                        IO_REGION = 2'b11;
   parameter			    MMU_STYLE = 2;

   /////////////////////////////////// BATs ////////////////////////////////////

   wire [`REGSZ-1:0] 		    bat_paddress;
   wire 			    bat_cacheable_access;
   wire [2:0] 			    bat_fault_type;
   wire 			    bat_valid;

   generate
      if (MMU_STYLE > 0) begin
         mmu_bat #(.INSTRUCTION(INSTRUCTION)
	           ) BATS (.bats(bats),

		           .vaddress(vaddress),
		           .privileged(privileged),
		           .RnW(RnW),

		           .paddress(bat_paddress),
		           .cacheable_access(bat_cacheable_access),
		           .fault_type(bat_fault_type),
		           .valid(bat_valid)
		           );
      end else begin
         // With no BATs, the output signals are ignored; assign them constly
         assign bat_paddress = `REG_ZERO;
         assign bat_cacheable_access = 0;
         assign bat_fault_type = 3'h0;
         assign bat_valid = 0;
      end
   endgenerate

   /////////////////////////////////// TLBs ////////////////////////////////////

   wire [`REGSZ-1:0] 		    tlb_paddress;
   wire 			    tlb_cacheable_access;
   wire 			    tlb_hit;
   wire [2:0] 			    tlb_fault_type;

   reg [`REGSZ-1:0] 		    tlb_vaddress; // Wire
   reg [1:0] 			    tlb_op; // Wire
   reg 				    tlb_en; // Wire

   reg [1:0] 			    state;
`define MMU_IDLE        2'd0
`define MMU_FETCH       2'd1
`define MMU_INSERT      2'd2
`define MMU_FAULT       2'd3

   always @(*) begin
      /* Regular lookup */
      tlb_vaddress = vaddress;
      tlb_op = 2'b00;
      tlb_en = translation_en;

      /* ...overridden if invalidate requested.
       * An invalidate occurs if requested and PTW is not in
       * progress.  (See below; an invalidation request also stops
       * the PTW from inserting an item, and stops a new PTW.)
       */
      if (inval_req && state == `MMU_IDLE) begin
	 tlb_en = 1;
	 tlb_vaddress = inval_addr;
	 if (inval_type) begin // All
	    tlb_op = 2'b01;
	 end else begin // Page
	    tlb_op = 2'b10;
	 end
      end
   end // always @ (*)

   /* With one level of TLB, the invalidation completes in one cycle.  Assert
    * ack in the same cycle as req.  But, the interface handshake allows
    * a delay (e.g. if the PTW has a central TLB which may be a clock or two
    * away.)
    *
    * Note: For no-BAT/BAT-only MMU, state is always IDLE, so ack=req.
    */
   assign inval_ack = inval_req && state == `MMU_IDLE;

   /* TLB either hits or misses; a hit might raise a PF (perms checking is done
    * in this component).
    *
    * A miss and PTW is dealt with elsewhere, poking a new entry into this.
    */

   reg 				    tlb_load; // Wire
   reg [31:0]			    tlb_new_ea; // Wire
   reg [31:0] 			    tlb_new_pa; // Wire
   reg [1:0] 			    tlb_new_pp; // Wire
   reg 				    tlb_new_Kp; // Wire
   reg 				    tlb_new_Ks; // Wire
   reg 				    tlb_new_cacheable; // Wire

   generate
      if (MMU_STYLE > 1) begin
         tlb #(.TLB_ENTRIES(TLB_ENTRIES)
	       ) TLB (.clk(clk),
		      .reset(reset),

		      .operation(tlb_op),
		      .enable(tlb_en),

		      .virtual_addr(tlb_vaddress),
		      .privileged(privileged),
		      .RnW(RnW),

		      .physical_addr(tlb_paddress),
		      .cacheable(tlb_cacheable_access),

		      .hit(tlb_hit),
		      .fault_type(tlb_fault_type),

		      .load(tlb_load),
		      .new_ea(tlb_new_ea),
		      .new_pa(tlb_new_pa),
		      .new_pp(tlb_new_pp),
		      .new_Kp(tlb_new_Kp),
		      .new_Ks(tlb_new_Ks),
		      .new_cacheable(tlb_new_cacheable)
		      );
      end else begin
         // TLB outputs are ignored, but tie them off:
         assign tlb_paddress         = `REG_ZERO;
         assign tlb_cacheable_access = 0;
         assign tlb_hit              = 0;
         assign tlb_fault_type       = `MMU_FAULT_NONE;
      end
   endgenerate

   ////////////////////////////////////////////////////////////////////////////////

   reg [`REGSZ-1:0]                 paddress_lookup; // Wire
   reg 				    cacheable_access_lookup; // Wire
   reg [2:0] 			    fault_type_lookup; // Wire
   reg 				    valid_lookup; // Wire

   always @(*) begin
      /* Note: Address bits 11:0 are always piped straight from the VA input */
      paddress_lookup = vaddress[`REGSZ-1:0];
      cacheable_access_lookup = (paddress_lookup[31:30] != IO_REGION);
      fault_type_lookup = `MMU_FAULT_NONE;
      valid_lookup = 1;

      /* For a plain MMU style 0, lookup's always valid & cannot fault.
       * For 1, BAT valid -> address.  Otherwise, output still valid, but a TF.
       * For 2, if BAT doesn't apply then check TLB, and manage miss/PTW.
       */
      if (MMU_STYLE > 0 && translation_en) begin
	 if (bat_valid) begin
	    paddress_lookup[`REGSZ-1:12] = bat_paddress[`REGSZ-1:12];
	    cacheable_access_lookup      = bat_cacheable_access;
	    fault_type_lookup            = bat_fault_type;
	    valid_lookup                 = 1;

         end else if (MMU_STYLE == 1) begin
            // BAT-only MMU, but BAT missed.  Generate a fault:
            fault_type_lookup            = `MMU_FAULT_TF;
	    valid_lookup                 = 1;

	 end else if (MMU_STYLE > 1) begin
            // BAT didn't hit, and there's a TLB to search!

            if (inval_req && state == `MMU_IDLE) begin
	       /* An invalidation request overrides any normal request,
	        * though it's possible given address could assert tlb_hit too.
	        * This must not appear as a false translation!
	        *
	        * To the regular lookup, it's an invalid cycle and we try
	        * again next cycle.
	        */
	       valid_lookup = 0;
	       /* Note: you might see output valid=1 during a DMMU invalidate because
	        * translation_en = 0.
	        */

	    end else if (tlb_hit) begin
	       /* Permissions have already been checked in the TLB component */
	       paddress_lookup[`REGSZ-1:12] = tlb_paddress[`REGSZ-1:12];
	       cacheable_access_lookup = tlb_cacheable_access;
	       fault_type_lookup = tlb_fault_type;
	       valid_lookup = 1;

	    end else begin
	       /* A TLB miss (and not an invalidation cycle).  In the FSM below,
	        * a PTW is requested.  This either inserts required TLB entry or
	        * returns a TF/PF/NX fault.
	        *
	        * This cycle is a write-off: not valid.  We'll then move into a
	        * refill state in which valid is 0, too.
	        */
	       valid_lookup = 0;

	    end // else: !if(tlb_hit)
         end // if (MMU_STYLE > 1)
      end // if (MMU_STYLE > 0 && translation_en)
   end // always @ (*)

   ////////////////////////////////////////////////////////////////////////////////

   /* TLB refill FSM:
    *
    * NORMAL: regular lookup.  On miss moves to...
    * FETCH: Issues a request (ptw_req = 1).  When ptw_ack, moves to...
    * INSERT: (if ptw_fault==PTW_FAULT_NONE) for one cycle to insert, then back to NORMAL
    * FAULT: (if ptw_fault!=0) for one cycle to output fault w/ valid=1, then NORMAL
    *
    * While this is going on, the processor might be annulling/taking other exceptions
    * etc., so translation_en *does not have to stay asserted*.
    * Should we insert a TLB entry if translation_en falls?  (speculative, kinda)
    *
    * Also watch out for BAT hits.  And, we need to sink invalidation requests,
    * though those are easy to deal with above/unrelated.
    *
    * Finally, if an invalidation comes in while fetching --- abort the fetch?
    * We don't want to risk inserting a stale entry (if the TLBI were to match fetched addr).
    * This is a little paranoid (though correct), as given the simple pipeline it'd be hard
    * for a PTE to be modified then TLBI'd whilst a PTW is going on.  Easiest way to do this
    * is to set a "poison" flag, and don't insert the TLB entry.
    */

   reg [`REGSZ-1:0] 		    captured_req_addr;
   reg [1:0] 			    captured_ptw_fault;
   reg [2:0] 			    mapped_ptw_fault; // Wire
   reg [`PTW_PTE_SIZE-1:0] 	    captured_ptw_tlbe;
   reg 				    poison_insert; // Wire
   reg 				    ptw_req_int;

   always @(*) begin
      poison_insert = inval_req;
      tlb_load = (state == `MMU_INSERT) & !poison_insert;

      /* Unpack PTE */
      tlb_new_ea = {captured_req_addr[`REGSZ-1:12], 12'h0};
      tlb_new_pa = {captured_ptw_tlbe[`PTW_PTE_PPN_ST+`PTW_PTE_PPN_SZ-1:`PTW_PTE_PPN_ST], 12'h0};
      tlb_new_pp = captured_ptw_tlbe[`PTW_PTE_PP_ST+`PTW_PTE_PP_SZ-1:`PTW_PTE_PP_ST];
      tlb_new_Kp = captured_ptw_tlbe[`PTW_PTE_KP_ST];
      tlb_new_Ks = captured_ptw_tlbe[`PTW_PTE_KS_ST];
      tlb_new_cacheable = captured_ptw_tlbe[`PTW_PTE_CACH_ST];

      /* Map any PTW faults into external TLB-style fault code: */
      mapped_ptw_fault = `MMU_FAULT_NONE;
      if (captured_ptw_fault == `PTW_FAULT_TF) begin
	 mapped_ptw_fault = `MMU_FAULT_TF;
      end else if (captured_ptw_fault == `PTW_FAULT_PF) begin
	 // FIXME: or NX when INSTRUCTION==1?
	 mapped_ptw_fault = `MMU_FAULT_PF;
      end
   end

   always @(posedge clk) begin
      case (state)
	`MMU_IDLE: begin
	   /* If translation is attempted, BAT misses, TLB misses and no
	    * invalidation's requested, then it's a true TLB miss.  Capture
	    * the requested lookup address & request PTW.
	    */
	   if (MMU_STYLE > 1 && translation_en && !bat_valid &&
               !inval_req && !tlb_hit && !inval_req) begin
	      captured_req_addr <= {vaddress[`REGSZ-1:12], 12'h0};

	      // Set up request (4-phase handshake req/ack)
	      ptw_req_int <= 1;
	      state <= `MMU_FETCH;
	   end
	end

	`MMU_FETCH: begin
	   if (ptw_ack) begin
	      ptw_req_int <= 0;

	      if (ptw_fault == `PTW_FAULT_NONE) begin
		 captured_ptw_tlbe <= ptw_tlbe; // Little bit o' pipelining
		 state <= `MMU_INSERT;
	      end else begin
		 captured_ptw_fault <= ptw_fault;
		 state <= `MMU_FAULT;
	      end
	   end // if (ptw_ack)
	end // case: `MMU_FETCH

	`MMU_INSERT: begin
	   // Asserts tlb_load here, which loads from captured_ptw_tlbe on edge.
	   state <= `MMU_IDLE;
	end

	`MMU_FAULT: begin
	   /* Comb output logic checks that the currently-requested address is
	    * the one originally walked for, and if so outputs valid + fault code.
	    * Otherwise, either the request went away or changed, so output is
	    * invalid and we just go back to IDLE.
	    */
	   state <= `MMU_IDLE;
	end

      endcase

     if (reset) begin
	state <= `MMU_IDLE;
	ptw_req_int <= 0;
     end
   end

   /* Performance counting */
   assign pctr_mmu_ptws = MMU_STYLE > 1 && translation_en && !bat_valid && !inval_req &&
			  !tlb_hit && !inval_req && state == `MMU_IDLE;  // TLB miss caused PTW
   // FIXME: TLB hit is harder to measure as there are cycles that don't represent a new fetch, but leave enable asserted.

   assign paddress = paddress_lookup;
   assign cacheable_access = cacheable_access_lookup;
   assign fault_type = (state == `MMU_FAULT) ? mapped_ptw_fault : fault_type_lookup;

   /* Output valid if:
    * 1. Translation succeeded, with a valid lookup (fault or address output)
    * 2. A PTW occurred but discovered a PF/TF and the request is both valid
    *    and for the originally-requested addr (that which faulted).
    */
   assign valid = (valid_lookup && (state == `MMU_IDLE)) ||
		  /* Shortcut for lower latency */
		  (translation_en && !inval_req && (state == `MMU_FAULT) &&
		   (vaddress[`REGSZ-1:12] == captured_req_addr[`REGSZ-1:12]));

   assign ptw_req = ptw_req_int;
   assign ptw_addr = captured_req_addr;

endmodule // mmu
