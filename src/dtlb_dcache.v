/* Wrapper for DTLB & D-cache
 *
 * Deals with faults and presents stalls (from TLB/$) in a unified way up to the
 * MEM stage.
 *
 * ME 16/3/2020
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
`include "cache_defs.vh"


module dtlb_dcache(input wire                     clk,
                   input wire 			  reset,

                   input wire 			  read_write_strobe,
                   /* Word-aligned addr: */
                   input wire [`REGSZ-1:0] 	  addr,

                   input wire 			  translation_enabled,
                   input wire 			  privileged,
		   input wire 			  translate_only,

		   // Operations encoded as mem_op, e.g. LOAD/STORE, DC, IC, TLBI.
                   input wire [3:0] 		  op,
                   input wire [1:0] 		  size,

                   output wire [`REGSZ-1:0] 	  read_data,
                   input wire [`REGSZ-1:0] 	  write_data,
                   output wire 			  hit,
                   output wire [2:0] 		  fault,
		   output wire [31:0] 		  paddr,

		   input wire [(64*`NR_BATs)-1:0] d_bats,
                   // FIXME:  Implicit invalidation from SR changes

                   /* Inputs from MMU/PTW unit which needs read access to DC: */
                   input wire 			  walk_request,
                   input wire [`REGSZ-1:0] 	  walk_addr,
		   /* NOTE: ack means walk_data will be valid next cycle, not
		    * *is currently valid*.
		    */
                   output wire 			  walk_ack,
                   output wire [63:0] 		  walk_data,
		   /* FIXME: Writes/RmW updates on PTW? */

		   output wire 			  pctr_mmu_ptws,
		   output wire 			  pctr_cacheable_unaligned_8B,
		   output wire 			  pctr_cacheable_unaligned_CL,

		   /* PTW interface from MMU: */
		   output wire [31:0] 		  ptw_addr,
		   output wire 			  ptw_req,
		   input wire [`PTW_PTE_SIZE-1:0] ptw_tlbe,
		   input wire [1:0] 		  ptw_fault,
		   input wire 			  ptw_ack,

                   output wire [31:0] 		  emi_if_address,
                   input wire [63:0] 		  emi_if_rdata,
                   output wire [63:0] 		  emi_if_wdata,
                   output wire [1:0] 		  emi_if_size,
                   output wire 			  emi_if_RnW,
                   output wire [7:0] 		  emi_if_bws,
                   output wire 			  emi_if_req,
                   input wire 			  emi_if_valid
                   );

   /* This parameter indicates where uncacheable accesses must be made
    * (before the MMU is implemented to do this).  PA space is split into
    * 4 regions, so this gives top two bits of the IO region:
    */
   parameter                          IO_REGION = 2'b11;
   parameter			      MMU_STYLE = 2;

   /////////////////////////////////////////////////////////////////////////////
   // Translation

   wire [31:0] 			      physical_address;
   wire [2:0] 			      mmu_fault_type;
   wire 			      mmu_valid;
   reg [2:0] 			      fault_type; // Wire

   reg				      tlb_hit; // Wire
   wire 			      cache_stall;

   wire 			      is_cacheable;
   reg 				      do_translate; // Wire
   reg 				      do_cache_access; // Wire
   reg                                inhibit_hit_report; // Wire

   reg 				      hit_r; // Wire

   reg 				      tlb_inval_req; // Wire
   wire 			      tlb_inval_ack;
   reg 				      tlb_inval_type;
   reg [31:0] 			      tlb_inval_addr; // Wire


   /* FIXME: Investigate whether it's worth adding a stage of pipelining
    * for d_bats, to lengthen the path from DE.
    */
   mmu #(.INSTRUCTION(0),
	 .IO_REGION(IO_REGION),
         .MMU_STYLE(MMU_STYLE)
	 )
       DMMU(.clk(clk),
	    .reset(reset),

	    .translation_en(do_translate),
	    .privileged(privileged),
	    .RnW(!(op == `MEM_STORE || op == `MEM_DC_INV || op == `MEM_DC_BZ)),
	    .vaddress(addr),

	    .paddress(physical_address),
	    .cacheable_access(is_cacheable),
	    .fault_type(mmu_fault_type),
	    .valid(mmu_valid),

	    /* TLB maintenance channel in: */
	    .inval_req(tlb_inval_req),
	    .inval_ack(tlb_inval_ack),
	    .inval_type(tlb_inval_type),
	    .inval_addr(tlb_inval_addr),

	    /* BATs */
	    .bats(d_bats),

	    .pctr_mmu_ptws(pctr_mmu_ptws),

	    /* PTW interface out: */
	    .ptw_addr(ptw_addr),
	    .ptw_req(ptw_req),
	    .ptw_tlbe(ptw_tlbe),
	    .ptw_fault(ptw_fault),
	    .ptw_ack(ptw_ack)
	    );

   // Translation lookup is always combinatorial:
   always @(*) begin
      /* Default value "overridden" by statements below: */
      fault_type         = mmu_valid ? mmu_fault_type : 3'b000;
      tlb_hit            = mmu_valid && read_write_strobe && (mmu_fault_type == 3'b000);
      do_translate       = translation_enabled && read_write_strobe;
      do_cache_access    = !translate_only;
      inhibit_hit_report = 0;

      // Untranslated operations:
      if (op == `MEM_IC_INV_SET || op == `MEM_DC_INV_SET ||
	  op == `MEM_TLBI_R0 || op == `MEM_TLBIA) begin
	 // Translation does occur for MEM_IC_INV, though!
	 do_translate = 0;
	 fault_type = 0;
      end

      // TLB maintenance
      // For DTLB currently appears on 'op' rather than inval channel
      tlb_inval_req = 0;
      tlb_inval_type = 0;
      tlb_inval_addr = 0;
      if (op == `MEM_TLBI_R0 || op == `MEM_TLBIA) begin
	 tlb_inval_req = read_write_strobe;
	 tlb_inval_type = (op == `MEM_TLBIA); // 0 for VA
	 tlb_inval_addr = {addr[31:12], 12'h0};
	 tlb_hit = 0;
	 // See "hit"/completion below
      end

      // Alignment checking
      if (tlb_hit && (op == `MEM_LOAD || op == `MEM_STORE)) begin
	 /* Strict alignment requirements for non-cacheable,
	  * but for cacheable, access is permitted at any byte within
	  * a 64b span.
	  */
	 if ((!is_cacheable && ((size == 2'b01 && addr[0] != 0) ||
				(size == 2'b10 && addr[1:0] != 2'b00))) ||
	     ( is_cacheable && ((size == 2'b01 && addr[2:0] == 3'b111) ||
				(size == 2'b10 && addr[2:0] >  3'b100)))) begin
	    /* The effect is to force the output of a MMU lookup into a fault;
	     * the MMU might have gone and translated, but that's OK.
	     *
	     * The MMU lookup needs to happen so we can make a decision based on
             * is_cacheable; we just override the output such that the cache/mem
	     * isn't happening.
	     */
	    fault_type                = `MMU_FAULT_ALIGN;
	    do_cache_access           = 0;
            /* We want to wait for the 'tlb_hit' stuff for completion and priority reasons,
             * but this component reports a fault with hit=0, so we must inhibit the
             * actual output below.
             */
            inhibit_hit_report        = 1;
	 end
      end
   end

   assign pctr_cacheable_unaligned_8B = tlb_hit && (op == `MEM_LOAD || op == `MEM_STORE) &&
					( is_cacheable && ((size == 2'b01 && addr[2:0] == 3'b111) ||
							   (size == 2'b10 && addr[2:0] >  3'b100)));
   assign pctr_cacheable_unaligned_CL = tlb_hit && (op == `MEM_LOAD || op == `MEM_STORE) &&
					( is_cacheable && ((size == 2'b01 && addr[4:0] == 5'b11111) ||
							   (size == 2'b10 && addr[4:0] >  5'b11100)));


   /////////////////////////////////////////////////////////////////////////////
   // Cache lookup/access
   //
   // Two ports:  Primary is a load/store/CMO from MEM.  Secondary is a PTW access.
   //

   reg [3:0]                          cache_primary_request; // Wire
   reg 				      cache_primary_strobe; // Wire
   wire                               cache_primary_valid;

   // Map incoming MEM request into a cache op (or nothing if it's an other-op)
   always @(*) begin
      cache_primary_request = 4'h0;
      cache_primary_strobe = 0;

      case (op)
	`MEM_LOAD: begin
	   if (is_cacheable) begin
	      cache_primary_request = `C_REQ_C_READ;
	   end else begin
	      cache_primary_request = `C_REQ_UC_READ;
	   end
	   // Access the cache if a PA's been acquired:
	   cache_primary_strobe  = tlb_hit && do_cache_access;
	end

	`MEM_STORE: begin
	   if (is_cacheable) begin
	      cache_primary_request = `C_REQ_C_WRITE;
	   end else begin
	      cache_primary_request = `C_REQ_UC_WRITE;
	   end
	   cache_primary_strobe  = tlb_hit && do_cache_access;
	end

	`MEM_DC_CLEAN: begin
	   cache_primary_request = `C_REQ_CLEAN;
	   cache_primary_strobe  = tlb_hit && do_cache_access;
	end

	`MEM_DC_CINV: begin
	   cache_primary_request = `C_REQ_CLEAN_INV;
	   cache_primary_strobe  = tlb_hit && do_cache_access;
	end

	`MEM_DC_INV: begin
	   cache_primary_request = `C_REQ_INV;
	   cache_primary_strobe  = tlb_hit && do_cache_access;
	end

	`MEM_DC_BZ: begin
	   cache_primary_request = `C_REQ_ZERO;
	   cache_primary_strobe  = tlb_hit && do_cache_access;
	end

	`MEM_DC_INV_SET: begin
	   cache_primary_request = `C_REQ_INV_SET;
	   // DC invalidate by set doesn't need a translation hit.
	   cache_primary_strobe  = read_write_strobe;
	end

	/* Other possible mem_op values do not take any action
	 * on the Dcache:
	 *
	 * MEM_IC_INV (just translates), and MEM_IC_INV_SET,
	 * MEM_TLBI_R0 and MEM_TLBIA (which don't need any translation).
	 */

      endcase // case (op)
   end // always @ (*)

   ////////////////////////////////////////////////////////////////////////////////
   // Arbitrate between primary and secondary requests:

   wire [31:0] 	cache_address;
   wire 	cache_strobe;
   wire [3:0]	cache_request;
   wire [1:0] 	cache_size;
   wire 	cache_valid;

   /* Want physical_address[11:0] to zip thru to cache ASAP to permit tag
    * lookup immediately.  It has to go through some logic here, but default
    * to "pass A[11:0] unless passing B":
    */
   cache_arb2 #(.PASS_A(0))
              DCA(.clk(clk),
		  .reset(reset),
		  /* Memory requests: */
		  .cache_b_address(physical_address),
		  .cache_b_strobe(cache_primary_strobe),
		  .cache_b_request(cache_primary_request),
		  .cache_b_size(size),
		  // Unused, wdata wired directly (only 1 port writes)
		  .cache_b_wdata(32'h0),
		  .cache_b_valid(cache_primary_valid),

		  /* PTW requests: */
		  .cache_a_address(walk_addr),
		  .cache_a_strobe(walk_request),
		  .cache_a_request(`C_REQ_C_READ),
		  .cache_a_size(2'b10),
		  .cache_a_wdata(32'h0), // Unused
		  .cache_a_valid(walk_ack),

		  /* Arbitrated cache access: */
		  .cache_address(cache_address),
		  .cache_strobe(cache_strobe),
		  .cache_request(cache_request),
		  .cache_size(cache_size),
		  .cache_valid(cache_valid)
		  );

   // Note for TLBI, it both acts locally and externally, and we flag stall
   // until both are done (stall=0 valid=1 on final cycle)

   cache DCACHE(.clk(clk),
		.reset(reset),

		.address(cache_address),
		.request_type(cache_request),
		.size(cache_size),
		.enable(cache_strobe),
		.stall(cache_stall),
		.valid(cache_valid),
		.wdata(write_data), // From mem request
		.rdata(read_data),
		.raw_rdata(walk_data), /* 64b read data */

		.emi_if_address(emi_if_address),
		.emi_if_rdata(emi_if_rdata),
		.emi_if_wdata(emi_if_wdata),
		.emi_if_size(emi_if_size),
		.emi_if_RnW(emi_if_RnW),
		.emi_if_bws(emi_if_bws),
		.emi_if_req(emi_if_req),
		.emi_if_valid(emi_if_valid)
		);

   // Map "doneness" given the request:
   always @(*) begin
      hit_r = 0;

      /* hit means:
       *
       * - For a load, store, or non-set D$ op the op translated and operated on D$.
       * - For a DC_INV_SET op, the op operated on D$ (no translate required).
       * - For an I$ invalidate, the op translated.
       * - An IC_INV_SET doesn't operate on this block & "always hits"
       * - TLB invalidates "hit" once they're complete/ack'd from the TLB.
       */
      if (op == `MEM_LOAD || op == `MEM_STORE || op == `MEM_DC_CLEAN || op == `MEM_DC_CINV ||
	  op == `MEM_DC_INV || op == `MEM_DC_BZ) begin
	 hit_r = !inhibit_hit_report && tlb_hit && (!do_cache_access || (cache_primary_valid && !cache_stall));
      end else if (op == `MEM_DC_INV_SET) begin
	 hit_r = cache_primary_valid && !cache_stall;
      end else if (op == `MEM_IC_INV) begin
	 hit_r = tlb_hit; // Translates only
      end else if (op == `MEM_IC_INV_SET) begin
	 hit_r = 1; // This op has no effect on DTC
      end else if (op == `MEM_TLBIA || op == `MEM_TLBI_R0) begin
	 hit_r = tlb_inval_ack;
      end
   end


   /////////////////////////////////////////////////////////////////////////////
   // Assign outputs:

   assign fault = fault_type;
   assign hit = hit_r && read_write_strobe; // Short-circuit path for no-lookup=no-hit
   assign paddr = physical_address;

endmodule // dtlb_dcache
