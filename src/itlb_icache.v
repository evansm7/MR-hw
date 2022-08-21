/* Wrapper for ITLB & I-cache
 *
 * Deals with faults and presents stalls (from TLB/$) in a unified way up to the
 * IFETCH stage.
 *
 * ME 22/2/2020
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


module itlb_icache(input wire                     clk,
		   input wire 			  reset,

		   input wire 			  read_strobe,
		   /* Word-aligned addr: */
		   input wire [31:0] 		  read_addr,

		   input wire 			  translation_enabled,
		   input wire 			  privileged,
		   output wire [31:0] 		  read_data,
		   output wire 			  stall,
		   output wire 			  valid,
		   output wire [2:0] 		  fault,

		   /* Input channel for CMOs, from MEM: */
		   input wire [31:0] 		  inval_addr,
		   /* Type: 00=CLInv, 01=CSetInv, 10=TLBI, 11=TLBIA */
		   input wire [1:0] 		  inval_type,
		   input wire 			  inval_req,
		   output wire 			  inval_ack,

		   input wire [(64*`NR_BATs)-1:0] i_bats,

		   output wire 			  pctr_mmu_ptws,

		   /* PTW interface from MMU: */
		   output wire [31:0] 		  ptw_addr,
		   output wire 			  ptw_req,
		   input wire [`PTW_PTE_SIZE-1:0] ptw_tlbe,
		   input wire [1:0] 		  ptw_fault,
		   input wire 			  ptw_ack,

		   output wire [31:0] 		  emi_if_address,
		   input wire [63:0] 		  emi_if_rdata,
                   output wire [1:0] 		  emi_if_size, // 1/2/4/CL
		   output wire 			  emi_if_req,
		   input wire 			  emi_if_valid
		   );

   /* This parameter indicates where uncacheable accesses must be made
    * (before the MMU is implemented to do this):
    */
   parameter                          IO_REGION = 2'b11;
   parameter			      MMU_STYLE = 2;

   /////////////////////////////////////////////////////////////////////////////
   // Translation

   wire [31:0] 			      physical_address; // Wire
   wire [2:0] 			      mmu_fault_type;
   wire 			      mmu_valid;
   reg [2:0] 			      fault_type; // Wire
   // Cache read requests:
   wire                               cache_read_valid;
   reg 				      cache_read_strobe; // Wire

   wire 			      is_cacheable;
   reg 				      do_translate; // Wire

   // Secondary cache requests (from CMOs, from inval_* port)
   reg 				      cache_other_strobe; // Wire
   wire                               cache_other_valid;
   reg [31:0] 			      cache_other_address; // Wire

   reg 				      tlb_inval_req; // Wire
   wire 			      tlb_inval_ack;
   reg 				      tlb_inval_type;
   reg [31:0] 			      tlb_inval_addr; // Wire

   /* FIXME: Investigate whether it's worth adding a stage of pipelining
    * for d_bats, to lengthen the path from DE.
    */
   mmu #(.INSTRUCTION(1),
	 .IO_REGION(IO_REGION),
         .MMU_STYLE(MMU_STYLE)
	 )
       IMMU(.clk(clk),
	    .reset(reset),

	    .translation_en(do_translate),
	    .privileged(privileged),
	    .RnW(1'b1),
	    .vaddress(read_addr),

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
	    .bats(i_bats),

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
      fault_type        = mmu_valid ? mmu_fault_type : 3'b000;
      cache_read_strobe = mmu_valid && read_strobe && (mmu_fault_type == 3'b000);
      do_translate      = translation_enabled && read_strobe;
   end


   /////////////////////////////////////////////////////////////////////////////
   // TLB and cache invalidation mapping

   /* "Protocol" on ITC invalidation channel:
    * - Does NOT have to complete in the same cycle, and indeed
    *   it'll be better for pipelining if it doesn't.
    *
    * Simple 4-phase handshake:  R=1 invokes an invalidate; then A=1, then
    * R=0 (and A=0 follows in same cycle).  Req must return to zero between
    * successive requests.
    */

   reg [1:0] 			      inval_state;
   reg 				      inval_ack_r; // Wire
   reg 				      inval_req_type;
   reg [31:0] 			      inval_addr_capture;

`define INV_ST_IDLE     0
`define INV_ST_IC_REQ   1
`define INV_ST_TLB_REQ  2
`define INV_ST_DONE     3

   // FSM
   always @(posedge clk) begin
      case (inval_state)
	`INV_ST_IDLE: begin
	   if (inval_req) begin
	      if (inval_type[1] == 0) begin // IC inval
		 inval_state <= `INV_ST_IC_REQ;
	      end else begin
		 inval_state <= `INV_ST_TLB_REQ;
	      end
	      inval_req_type <= inval_type[0];
	      inval_addr_capture     <= inval_addr;
	   end
	end

	`INV_ST_IC_REQ: begin
	   if (cache_other_valid)
	     inval_state     <= `INV_ST_DONE;
	   // Also, the ack is asserted
	end

	`INV_ST_TLB_REQ: begin
	   /* This sends inval_req into IMMU, which holds off any
	    * concurrent regular lookup.
	    */
	   if (tlb_inval_ack)
	     inval_state     <= `INV_ST_DONE;
	   // Also, the ack is asserted
	end

	`INV_ST_DONE: begin
	   // Asserts ack, and waits for the req to RTZ
	   if (!inval_req)
	     inval_state     <= `INV_ST_IDLE;
	end
      endcase

      if (reset) begin
	 inval_state             <= `INV_ST_IDLE;
      end
   end

   // Combinatorial
   always @(*) begin
      cache_other_request = 0;
      cache_other_strobe = 0;
      inval_ack_r = 0;
      tlb_inval_req = 0;
      tlb_inval_type = inval_req_type; // 0 = TLBI VA, 1 = TLBI ALL

      if (inval_state == `INV_ST_IC_REQ) begin
	 cache_other_request = inval_req_type ? `C_REQ_INV_SET : `C_REQ_INV;
	 cache_other_strobe = 1;

	 // Can signal ACK to requester in cycle req+1
	 // FIXME: Worth sending this through a FF to reduce path?
	 inval_ack_r = cache_other_valid;

      end else if (inval_state == `INV_ST_TLB_REQ) begin
	 tlb_inval_req = 1;
	 inval_ack_r = tlb_inval_ack;

      end else if (inval_state == `INV_ST_DONE) begin
	 // This state waits for REQ to return to 0.
	 // ACK is 1 for as long as it isn't zero...
	 inval_ack_r = inval_req;
      end

      cache_other_address = {inval_addr_capture[31:5], 5'h0};
      tlb_inval_addr = {inval_addr_capture[31:12], 12'h0};
   end


   /////////////////////////////////////////////////////////////////////////////
   // Cache lookup/access

   reg [3:0]    cache_read_request; // Wire
   reg [3:0] 	cache_other_request; // Wire

   always @(*) begin
      // Type for read requests:
      if (is_cacheable) begin
	 cache_read_request = `C_REQ_C_READ;
      end else begin
	 cache_read_request = `C_REQ_UC_READ;
      end
   end


   /////////////////////////////////////////////////////////////////////////////
   // Cache access
   // Arbitrate between regular (IF) and other (cache maintenance) requests:

   wire [31:0] 	cache_address;
   wire 	cache_strobe;
   wire [3:0]	cache_request;
   wire 	cache_valid;

   cache_arb2 ICA(.clk(clk),
		  .reset(reset),
		  /* Requests from external invalidation port: */
		  .cache_a_address(cache_other_address),
		  .cache_a_strobe(cache_other_strobe),
		  .cache_a_request(cache_other_request),
		  .cache_a_size(2'b00), // Unused
		  .cache_a_wdata(32'h0), // Unused
		  .cache_a_valid(cache_other_valid),

		  /* IFetch requests: */
		  .cache_b_address(physical_address),
		  .cache_b_strobe(cache_read_strobe),
		  .cache_b_request(cache_read_request),
		  .cache_b_size(2'b00), // Unused
		  .cache_b_wdata(32'h0), // Unused
		  .cache_b_valid(cache_read_valid),

		  /* Arbitrated cache access: */
		  .cache_address(cache_address),
		  .cache_strobe(cache_strobe),
		  .cache_request(cache_request),
		  .cache_valid(cache_valid)
		  );

   cache ICACHE(.clk(clk),
		.reset(reset),

		.address(cache_address),
		.request_type(cache_request),
		.size(2'b10), // 32-bit only
		.enable(cache_strobe),
		.stall(stall),
		.valid(cache_valid),
		.wdata(32'b0),
		.rdata(read_data),

		.emi_if_address(emi_if_address),
		.emi_if_rdata(emi_if_rdata),
		.emi_if_wdata(),
		.emi_if_size(emi_if_size),
		.emi_if_RnW(),
		.emi_if_bws(),
		.emi_if_req(emi_if_req),
		.emi_if_valid(emi_if_valid)
		);

   /////////////////////////////////////////////////////////////////////////////
   // Assign outputs:

   assign fault = fault_type;
   assign valid = (cache_read_valid && cache_read_strobe) || (fault_type != 0);
   assign inval_ack = inval_ack_r;

endmodule // itlb_icache
