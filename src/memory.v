/* MEM stage
 *
 * ME 8/3/20
 *
 * Deals with memory ops, passthrough instructions, and trap conditions.
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

`include "decode_signals.vh"
`include "decode_enums.vh"
`include "arch_defs.vh"


module memory(input wire                       clk,
	      input wire                       reset,

	      input wire                       execute_valid,
	      input wire [3:0]                 execute_fault,
	      input wire [31:0]                execute_instr,
	      input wire [`REGSZ-1:0]          execute_pc,
	      input wire [31:0]                execute_msr,
	      input wire [`DEC_SIGS_SIZE-1:0]  execute_ibundle_in,
	      input wire                       execute_brtaken,

	      input wire [`REGSZ-1:0]          execute_R0,
	      input wire [`REGSZ-1:0]          execute_R1,
	      input wire [`REGSZ-1:0]          execute_R2,
	      input wire [`XERCRSZ-1:0]        execute_RC,
              input wire [5:0]                 execute_miscflags,

	      input wire                       writeback_annul,

	      output wire [`REGSZ-1:0]         memory_R0,
	      output wire [`REGSZ-1:0]         memory_R1,
	      output wire [`XERCRSZ-1:0]       memory_RC,
	      output wire [`REGSZ-1:0]         memory_res,
	      output wire [`REGSZ-1:0]         memory_addr,

	      output wire [`REGSZ-1:0]         memory_out_bypass,
	      output wire [4:0]                memory_out_bypass_reg,
	      output wire                      memory_out_bypass_valid,
              output wire [`XERCRSZ-1:0]       memory_out_bypass_xercr,
              output wire                      memory_out_bypass_xercr_valid,
              output wire                      memory_out_writes_gpr0,
              output wire [4:0]                memory_out_writes_gpr0_reg,
              output wire                      memory_out_writes_gpr1,
              output wire [4:0]                memory_out_writes_gpr1_reg,
              output wire                      memory_out_writes_xercr,

	      output wire                      memory_valid,
	      output wire [3:0]                memory_fault,
	      output wire [31:0]               memory_instr,
	      output wire [`REGSZ-1:0]         memory_pc,
	      output wire [31:0]               memory_msr,
	      output wire [`DEC_SIGS_SIZE-1:0] memory_ibundle_out,

              output wire [31:0]               emi_if_address,
              input wire [63:0]                emi_if_rdata,
              output wire [63:0]               emi_if_wdata,
              output wire [1:0]                emi_if_size, // FIXME: encoding 1/2/4/CL
              output wire                      emi_if_RnW,
              output wire [7:0]                emi_if_bws,
              output wire                      emi_if_req,
              input wire                       emi_if_valid,

	      /* Perf counters */
	      output wire                      pctr_mem_access,
	      output wire                      pctr_mem_access_fault,
	      output wire                      pctr_mem_mmu_ptws,
	      output wire                      pctr_mem_cacheable_unaligned_8B,
	      output wire                      pctr_mem_cacheable_unaligned_CL,

	      /* Invalidation channel to IF.ITC cache & MMU: */
	      output reg [31:0]                inval_addr,
	      output reg [1:0]                 inval_type,
	      output reg                       inval_req,
	      input wire                       inval_ack,

	      /* PTW req channel in from IF.ITC.MMU to MEM.PTW */
	      input wire [31:0]                i_ptw_addr,
	      input wire                       i_ptw_req,
	      output wire [`PTW_PTE_SIZE-1:0]  i_ptw_tlbe,
	      output wire [1:0]                i_ptw_fault,
	      output wire                      i_ptw_ack,

	      input wire [(64*`NR_BATs)-1:0]   d_bats,
	      input wire [`REGSZ-1:0]          sdr1,

	      output wire                      memory_stall
	      );

   parameter                                   IO_REGION = 2'b11;
   parameter			     	       MMU_STYLE = 2;

   reg [`DEC_SIGS_SIZE-1:0]                    memory_ibundle_out_r;
   `DEC_SIGS_DECLARE;

   always @(*) begin
      {`DEC_SIGS_BUNDLE} = execute_ibundle_in;
   end

   reg [`REGSZ-1:0]                            memory_R0_r /*verilator public*/;
   reg [`REGSZ-1:0]                            memory_R1_r;
   reg [`XERCRSZ-1:0]                          memory_RC_r;
   reg [`REGSZ-1:0]                            memory_addr_r;

   wire                                        memory_valid_i /*verilator public*/;
   reg [3:0]                                   memory_fault_r /*verilator public*/;
   reg [31:0]                          	       memory_instr_r /*verilator public*/;
   reg [`REGSZ-1:0]                            memory_pc_r /*verilator public*/;
   reg [31:0]                          	       memory_msr_r /*verilator public*/;

   reg                                         mem_want_stall; // Wire

   reg                                         do_dtc_access; // Wire
   reg 					       failed_stwcx; // Wire

   wire [`REGSZ-1:0]                           virt_addr = execute_R0;
   reg [`REGSZ-1:0]                            store_data; // Wire

   wire                                        privileged_state = (execute_msr & `MSR_PR) == 0;
   wire                                        DR = (execute_msr & `MSR_DR) != 0;
   wire                                        dtc_hit;
   wire [2:0]                                  mmu_fault;

   reg 					       hax_reservation_valid;

   wire [`REGSZ-1:0] 			       phys_addr;

   /////////////////////////////////////////////////////////////////////////////
   // Storage for Segment Registers (16 of), which live in MEM.  This is for
   // the current 32-bit implementation; 64b impls use SLBs instead.
   // Note: This is unused when MMU_STYLE is 0 or 1.
   reg [31:0]                                  segment[15:0] /*verilator public*/;

   /////////////////////////////////////////////////////////////////////////////

   /* An incoming instruction is present if input valid, not a fault, and WB
    * isn't annulling.  (Previously a possible bug-- didn't check for annul.)
    */
   wire 				       valid_op = execute_valid &&
					       execute_fault == 0 &&
					       !writeback_annul;


   /////////////////////////////////////////////////////////////////////////////
   // TLB and D-cache wrapper:
   //
   // This block is presented with an address and responds *in the same cycle*
   // with one of:
   // - Data written
   // - Data read (at next _| clk)
   // - A miss flag (stalled)
   // - A fault type (a miss and a fault)

   wire [31:0] 				       d_ptw_addr;
   wire 				       d_ptw_req;
   wire [`PTW_PTE_SIZE-1:0] 		       d_ptw_tlbe;
   wire [1:0] 				       d_ptw_fault;
   wire 				       d_ptw_ack;

   wire 				       ptw_walk_req;
   wire [`REGSZ-1:0] 			       ptw_walk_addr;
   wire 				       ptw_walk_ack;
   wire [63:0] 				       ptw_walk_data;


   // May move the D$, because it is used by this module but also by the
   // walker module (used by ITLB, DTLB).  Currently, walker is in here, but
   // may be cleaner to have all caches external and assemble at top level.

   dtlb_dcache #(.IO_REGION(IO_REGION),
                 .MMU_STYLE(MMU_STYLE))
               DTC(.clk(clk),
                   .reset(reset),

                   // Requests:
                   .read_write_strobe(do_dtc_access),
                   .addr(virt_addr),

                   .translation_enabled(DR),
                   .privileged(privileged_state),
		   .translate_only(failed_stwcx),
		   // mem_op might be LOAD/STORE, or DC op, IC op, or TLB op
                   .op(mem_op),
                   .size(mem_op_size),

                   // Responses:
                   .write_data(store_data),
                   .read_data(memory_res), // FIXME, transforms (sxt/bswap)
                   .hit(dtc_hit),
                   .fault(mmu_fault),
		   .paddr(phys_addr),

		   .d_bats(d_bats),

		   .pctr_mmu_ptws(pctr_mem_mmu_ptws),
		   .pctr_cacheable_unaligned_8B(pctr_mem_cacheable_unaligned_8B),
		   .pctr_cacheable_unaligned_CL(pctr_mem_cacheable_unaligned_CL),

		   // PTW data request interface in:
		   .walk_request(ptw_walk_req),
		   .walk_addr(ptw_walk_addr),
		   .walk_ack(ptw_walk_ack),
		   .walk_data(ptw_walk_data),

		   // PTW request out:
		   .ptw_addr(d_ptw_addr),
		   .ptw_req(d_ptw_req),
		   .ptw_tlbe(d_ptw_tlbe),
		   .ptw_fault(d_ptw_fault),
		   .ptw_ack(d_ptw_ack),

                   .emi_if_address(emi_if_address),
                   .emi_if_rdata(emi_if_rdata),
                   .emi_if_wdata(emi_if_wdata),
                   .emi_if_size(emi_if_size), // FIXME: encoding 1/2/4/CL
                   .emi_if_RnW(emi_if_RnW),
		   .emi_if_bws(emi_if_bws),
                   .emi_if_req(emi_if_req),
                   .emi_if_valid(emi_if_valid)
                   );


   /////////////////////////////////////////////////////////////////////////////
   // PTW

   wire [(32*16)-1:0]                          segment_regs_data;

   genvar                                      i;
   generate
      for (i = 0; i < 16; i = i + 1) begin: sr_read
         assign segment_regs_data[(i*32)+31:(i*32)] = (MMU_STYLE > 1) ? segment[i] : 32'h0;
      end
   endgenerate

   generate
      if (MMU_STYLE > 1) begin
         mmu_ptw PTW
                    (.clk(clk),
	             .reset(reset),

	             /* Segment registers */
	             .SRs(segment_regs_data),

	             .SDR1(sdr1),

	             /* Walk interface (out to cache) */
	             .walk_req(ptw_walk_req),
	             .walk_addr(ptw_walk_addr),
	             .walk_ack(ptw_walk_ack),
	             .walk_data(ptw_walk_data),

	             /* PTW request channels from IMMU/DMMU */
	             .i_ptw_addr(i_ptw_addr),
	             .i_ptw_req(i_ptw_req),
	             .i_ptw_tlbe(i_ptw_tlbe),
	             .i_ptw_fault(i_ptw_fault),
	             .i_ptw_ack(i_ptw_ack),

	             .d_ptw_addr(d_ptw_addr),
	             .d_ptw_req(d_ptw_req),
	             .d_ptw_tlbe(d_ptw_tlbe),
	             .d_ptw_fault(d_ptw_fault),
	             .d_ptw_ack(d_ptw_ack)

	             // FIXME: In future, add central TLB & invalidation channel
	             );
      end else begin // if (MMU_STYLE > 1)
         assign ptw_walk_req = 0;
         assign ptw_walk_addr = `REG_ZERO;
         assign i_ptw_ack = i_ptw_req;
         assign d_ptw_ack = d_ptw_req;
      end // else: !if(MMU_STYLE > 1)
   endgenerate

   /////////////////////////////////////////////////////////////////////////////
   // Invalidation control signals
   wire 				       invalidation_wait;
   reg [2:0] 				       inval_state;

   /* Invalidation control:
    *
    * D$ inval goes to DTC for translate && cache op:
    * - mem_op will be the correct type; issue do_dtc_access
    * - Translation occurs internally, handled purely in DTC.
    *
    * D$ inval-set goes to DTC for cache op:
    * - Handled purely in DTC.
    *
    * I$ inval goes to DTC then ITC:
    * - mem_op causes DTC to do a translate-only. Wait for dtc_hit, or mmu_fault.  Abort if fault.
    * - If hit and no fault, physical_address gives the invalidation address.
    * - Start request to ITC; inval_type from mem_op.
    * - Assert stall backwards until dtc_hit, and then when hit and a request pending.  When request
    *   completes, drop stall for one "Consume" cycle. (go valid)
    *
    * I$ inval-set goes to ITC:
    * - No translate, no DTC access required; however, it's piped in there
    *   anyway, and dtc_hit occurs immediately.
    *
    * TLBI needs to go to ITC and DTC:
    * - mem_op will be the correct type; issue do_dtc_access for one cycle
    *   (e.g. mem_op=tlbi & state = IDLE & not stalled)
    * - Begin ITC request, setting inval_type based on mem_op and
    *   assert inval_req
    * - stall until itc_req_idle again (go valid)
    *
    * A simple FSM controls the invalidation request channel to ITC.
    */

`define MEM_INV_STATE_IDLE      0
`define MEM_INV_STATE_REQWAIT   1
`define MEM_INV_STATE_CONSUME   2

   always @(posedge clk) begin
      case (inval_state)

	`MEM_INV_STATE_IDLE: begin
	   if (valid_op && mem_op == `MEM_IC_INV) begin
	      /* DTC is translating for us. If that succeeds,
	       * start an external request:
	       */
	      if (dtc_hit && mmu_fault == 0) begin
		 inval_req    <= 1;
		 inval_type   <= 2'b00; // CLInv
		 inval_addr   <= phys_addr;
		 inval_state  <= `MEM_INV_STATE_REQWAIT;
	      end
	      /* If there *is* a fault, the main FSM generates a fault
	       * code as per any other type of access.  See below.
	       */

	   end else if (valid_op && mem_op == `MEM_IC_INV_SET) begin
	      // No translation to wait for.
	      inval_req       <= 1;
	      inval_type      <= 2'b01; // CSetInv
	      inval_addr      <= virt_addr;
	      inval_state     <= `MEM_INV_STATE_REQWAIT;

	   end else if (valid_op && ((mem_op == `MEM_TLBIA) ||
				     (mem_op == `MEM_TLBI_R0))) begin
	      /* No translation to wait for.  However, we need to coordinate
	       * an inval_req to IF as well as an inval_req to DTC (both of
	       * which might complete this cycle, or stall arbitrarily!).
	       */
	      inval_req       <= 1;
	      inval_type      <= (mem_op == `MEM_TLBIA) ? 2'b11 : 2'b10;
	      inval_addr      <= virt_addr;
	      inval_state     <= `MEM_INV_STATE_REQWAIT;

	      /* This asserts do_dtc_access (which pipes TLBI into DTC).
	       * That doesn't necessarily complete immediately... though
	       * in the current implementation it's a 1-cycle op.
	       *
	       * Messily, do_dtc_access is asserted throughout so we get a
	       * few cycles of the same invalidation over and over.  Safe
	       * but manky.
	       */
	   end
	end // case: `MEM_INV_STATE_IDLE

	`MEM_INV_STATE_REQWAIT: begin
	   if (inval_ack) begin
	      inval_req       <= 0;
	      inval_state     <= `MEM_INV_STATE_CONSUME;

`ifdef SIM
	      if (((mem_op == `MEM_TLBIA) || (mem_op == `MEM_TLBI_R0)) &&
		  !dtc_hit)
		$fatal(1, "MEM: ITLB invalidation completed but no DTLB inval_ack?");
`endif
	      /* FIXME, if DTLB ever needs a multi-cycle invalidate */

	   end
	end

	`MEM_INV_STATE_CONSUME:
	  /* The purpose of this state is to give one cycle
	   * that does *not* assert invalidation_wait, meaning
	   * the stage is not stalled and the instruction is
	   * consumed from EX.
	   */
	  inval_state <= `MEM_INV_STATE_IDLE;

      endcase

      if (reset) begin
	 inval_state     <= `MEM_INV_STATE_IDLE;
	 inval_req       <= 0;
      end
   end

   /* Stall if IDLE and about to do an invalidation, or if waiting for an inval
    * to complete:
    */
   assign invalidation_wait = valid_op && (((inval_state == `MEM_INV_STATE_IDLE) &&
					    ((mem_op == `MEM_IC_INV) ||
					     (mem_op == `MEM_IC_INV_SET) ||
					     (mem_op == `MEM_TLBIA) ||
					     (mem_op == `MEM_TLBI_R0))) ||
					   (inval_state == `MEM_INV_STATE_REQWAIT));


   /////////////////////////////////////////////////////////////////////////////
   // DTC control signals and stall

   always @(*) begin
      do_dtc_access = valid_op && (mem_op != 0); // FIXME TLBI

      /* A stwcx makes a request into the cache as per normal, but it is
       * made unable to modify memory using this flag.  We can't just
       * set do_dtc_access=0 because we *do* want to test for translation-
       * related faults.
       */
      failed_stwcx = mem_op != 0 && mem_op_addr_test_reservation /* stwcx */
		     && !hax_reservation_valid;

      /* The stalling is relatively simple.  If the DTC flags to wait, we wait.
       *
       * The flag is that the DTC didn't hit, but that could be because
       * of a miss or because of a fault output.  We don't stall on a fault
       * output (because this stage converts that into a faultcode in
       * memory_fault_r same-cycle).  The only thing we need to do is hold
       * inputs still!  (I.e. don't consume EXE output)
       *
       * Can only stall when we do_dtc_access
       *
       * The other thing that causes a stall is an invalidation request
       * (which may be in one of a couple of states).  Depending on the request,
       * it may or may not involve ITC, DTC or both.
       */
      mem_want_stall = (do_dtc_access && !dtc_hit && mmu_fault == 0) || invalidation_wait;
      /* gross - in terms of timing that can't easily be decoupled
       * from the entire DTC lookup, e.g. though we can't stall if we're
       * not doing a DTC access, we have to evaluate that expression as though
       * we're waiting for the DTC access.
       * Stall comes very late in the cycle, very limiting fmax!
       */
   end


   // More FIXME: going to have to do some amount of combinatorial
   // rotation/masking after the synchronous BRAM read from the cache.  So, do
   // the bswap/sxt stuff (currently in WB) in there too!

   // Store data transformation:
   always @(*) begin
      store_data = execute_R2;
      if (mem_op != 0 && mem_op_store_bswap) begin
         if (mem_op_size == `MEM_OP_SIZE_16) begin
            store_data = {16'h0000, execute_R2[7:0], execute_R2[15:8]};
         end else begin // Assumes 32
            store_data = {execute_R2[7:0], execute_R2[15:8], execute_R2[23:16], execute_R2[31:24]};
         end
      end
   end


   /////////////////////////////////////////////////////////////////////////////
   // Pipeline control
   wire enable_change;

   plc PLC(.clk(clk),
	   .reset(reset),
	   /* To/from previous stage */
	   .valid_in(execute_valid),
	   .stall_out(memory_stall),

	   /* Note: mem_want_stall affects both output/forward progress and
	    * EX to stall/hold inputs.
	    */
	   .self_stall(mem_want_stall),

	   .valid_out(memory_valid_i),
	   .stall_in(1'b0), // WB doesn't stall
	   .annul_in(writeback_annul),

           /* enable_change is for the outputs.  FSM can
            * still change/work on intermediate results if 0.
            */
	   .enable_change(enable_change)
	   );

   assign memory_valid = memory_valid_i;

   /////////////////////////////////////////////////////////////////////////////
   // State

   always @(posedge clk) begin
      if (writeback_annul) begin
`ifdef DEBUG
         $display("MEM: Annulled (EXE valid %d)", execute_valid);
`endif
         /* NOTE HACK:
          *
          * WB expects MEM to hold PC/MSR unchanged when annulling back,
          * which is gross (uses value when valid=0) but allows WB
          * to take multiple cycles raising an exception.
          */

	 /* lwarx/stwcx reservation:
	  * The correct implementation would store the address of a lwarx, setting
	  * a reservation, and then test future stores against this (CL) range.
	  * Any modifications of the range clear the reservation.
	  *
	  * However, a shitty cheap version that'll work with various
	  * locking primitives is:  Set reservation as a flag, and clear it
	  * if there's been an exception.  I.e. one thread is guaranteed
	  * an atomic update if it isn't pre-empted.  This obviously won't
	  * work for SMP, but is OK in UP unless a thread intentionally tries
	  * to blow its own reservation by storing to a range marked by lwarx.
	  */
	 hax_reservation_valid <= 0;
      end

      if (enable_change) begin
         /* Inputs are valid, and we're allowed to change state. */
`ifdef DEBUG $display("MEM: '%s', PC %08x", name, execute_pc);  `endif

         memory_instr_r <= execute_instr;
         memory_pc_r <= execute_pc;
         memory_msr_r <= execute_msr;
         memory_ibundle_out_r <= execute_ibundle_in;

         /* Values passed through: */
         if (mem_sr_op == `MEM_SR_READ) begin
	    /* execute_R1 either comes from a reg read from the RB field
	     * in the case of mfsrin, or for mfsr the SR field (which
	     * is positioned into [31:28] by the immediate decoder
	     * for convenience, since it's shifting bits anyway).
	     *
	     * SR's [27:24] aren't stored, masked out.
	     */
	    memory_R0_r <= (MMU_STYLE > 1) ?
                           segment[execute_R1[31:28]] & `SR_valid_msk : 32'h0;
	 end else if (mem_pass_R0) begin
            memory_R0_r <= execute_R0;
         end
         if (mem_pass_R1) begin
            memory_R1_r <= execute_R1;
         end

         if (execute_fault != 0) begin
`ifdef DEBUG   $display("MEM: Passing fault %d through", execute_fault);  `endif
            memory_fault_r <= execute_fault;

         end else begin
            /* Requests into MEM:
             */
            if (mem_op != 0) begin
	       // See reservation hax note above.
	       if (mem_op_addr_set_reservation) begin
		  // A fault (a kind of miss) doesn't set reservation
		  hax_reservation_valid <= dtc_hit;

	       end else if (mem_op_addr_test_reservation) begin
`ifdef SIM	     if (mem_op != `MEM_STORE || mem_op_size != `MEM_OP_SIZE_32)
		  $fatal(1, "MEM: Mem op %d/size %d, but should be stwcx?",
			 mem_op, mem_op_size);
`endif

		  if (!hax_reservation_valid) begin
		     /* If !hax_reservation_valid, then stwcx is going to fail.
		      * DTC has translate_only=1 to prevent store.
		      * Note that might cause a miss/exception to occur.
		      *
		      * Here, we modify CR0:
		      */
`ifdef DEBUG               $display("MEM: stwcx failed");  `endif
		  end else begin
		     // Store occurs, consumes reservation.
		     hax_reservation_valid <= 0;
		  end

		  /* stwcx is unique in that it writes XERCR.
		   * It's OK to do this even if an exception is generated:
		   */
		  memory_RC_r <= {execute_RC[`XERCR_BC],
				  execute_RC[`XERCR_SO],
				  execute_RC[`XERCR_OV],
				  execute_RC[`XERCR_CA],
				  {2'b00, hax_reservation_valid, execute_RC[`XERCR_SO]},
				  execute_RC[27:0]
				  };
	       end

	       /* Debug */
`ifdef DEBUG
	       if (mem_op == `MEM_TLBI_R0 || mem_op == `MEM_TLBIA) begin
		  $display("MEM: TLBI(%d) [%08x]", mem_op, virt_addr);
	       end else if (mem_op == `MEM_DC_CLEAN ||
			    mem_op == `MEM_DC_CINV ||
			    mem_op == `MEM_DC_INV ||
			    mem_op == `MEM_DC_INV_SET ||
			    mem_op == `MEM_DC_BZ) begin
		  $display("MEM: DCache op(%d) [%08x]", mem_op, virt_addr);
	       end else if (mem_op == `MEM_IC_INV ||
			    mem_op == `MEM_IC_INV_SET) begin
		  $display("MEM: ICache op(%d) [%08x]", mem_op, virt_addr);
	       end else if (mem_op == `MEM_LOAD) begin
		  if (mem_op_size == `MEM_OP_SIZE_8)
		    $display("MEM: '%s' LOAD8[%08x]", name, virt_addr);
		  if (mem_op_size == `MEM_OP_SIZE_16)
		    $display("MEM: '%s' LOAD16[%08x]", name, virt_addr);
		  if (mem_op_size == `MEM_OP_SIZE_32)
		    $display("MEM: '%s' LOAD32[%08x]", name, virt_addr);
	       end else begin
		  if (mem_op_size == `MEM_OP_SIZE_8)
		    $display("MEM: '%s' STORE8[%08x] = %02x", name, virt_addr, store_data[7:0]);
		  if (mem_op_size == `MEM_OP_SIZE_16)
		    $display("MEM: '%s' STORE16[%08x] = %04x", name, virt_addr, store_data[15:0]);
		  if (mem_op_size == `MEM_OP_SIZE_32)
		    $display("MEM: '%s' STORE32[%08x] = %08x", name, virt_addr, store_data);
	       end // else: !if(mem_op == `MEM_LOAD)
`endif
            end else begin // if (mem_op)
	       /* Not a MEM op, this stage just passes stuff through. */
	       memory_RC_r <= execute_RC;
	    end

	    /* Independent of mem_op (and in parallel to), update a SR
	     * if we're writing SRs.  Note a mtsr(in) currently also spits a
	     * TLBI mem_op into DTC.
	     */
/* -----\/----- EXCLUDED -----\/-----
	    if (MMU_STYLE > 1 && mem_sr_op == `MEM_SR_WRITE) begin
	       segment[execute_R1[31:28]] <= execute_R0 & `SR_valid_msk;
	    end
 // see below
 -----/\----- EXCLUDED -----/\----- */

            /* Generate a fault, if necessary.  Note mmu_fault is zero if
	     * mem_op is 0, or if translation is off, or most importantly if
	     * do_dtc_access = 0.
	     */
            if (!dtc_hit && mmu_fault != 0 /* && !mem_op_fault_inhibit */) begin
               /* MMU didn't translate, so synthesise a fault: */
               case (mmu_fault)
                 `MMU_FAULT_TF:
		   if (mem_op == `MEM_STORE || mem_op == `MEM_DC_INV || mem_op == `MEM_DC_BZ) begin
                      memory_fault_r <= `FC_DSI_TF_W;
		   end else begin
                      memory_fault_r <= `FC_DSI_TF_R;
		   end
                 `MMU_FAULT_PF:
		   if (mem_op == `MEM_STORE || mem_op == `MEM_DC_INV || mem_op == `MEM_DC_BZ) begin
                      memory_fault_r <= `FC_DSI_PF_W;
		   end else begin
		      memory_fault_r <= `FC_DSI_PF_R;
		   end
                 `MMU_FAULT_ALIGN:
		   memory_fault_r <= `FC_MEM_ALIGN;
`ifdef SIM
                 default:
                   $fatal(1, "MEM: Unknown MMU fault %d", mmu_fault);
`endif
               endcase

            end else if (mem_test_trap_enable) begin
               /* And here's where execute_miscflags is used:
                */
               if ((execute_R1[0] & execute_miscflags[3]) || // s<
                   (execute_R1[1] & execute_miscflags[2]) || // s>
                   (execute_R1[2] & execute_miscflags[1]) || // ==
                   (execute_R1[3] & execute_miscflags[5]) || // u<
                   (execute_R1[4] & execute_miscflags[4])) begin // u>
                  memory_fault_r <= `FC_PROG_TRAP;
               end else begin
                  memory_fault_r <= `FC_NONE;
               end

            end else begin
               memory_fault_r <= `FC_NONE;
            end

            memory_addr_r <= virt_addr;
         end // else: !if(execute_fault != 0)

      end else begin // if (enable_change)
`ifdef DEBUG
         if (!valid_op) begin
            $display("MEM: Nothing (EXE valid %d, wb annul %d)",
                     execute_valid, writeback_annul);
         end else begin
            $display("MEM: Stalled (DTC hit %d)", dtc_hit);
         end
`endif
      end

      /* Independent of mem_op (and in parallel to), update a SR
	  * if we're writing SRs.  Note a mtsr(in) currently also spits a
	  * TLBI mem_op into DTC.
          *
          * Note: To shorten paths, this does NOT depend on enable_change.
          * These internal regs can be updated whenever a valid instruction
          * is available.
          * (In fact, all outputs, really, can change when instr is valid
          * because WB never stalls MEM....)
	  */
	 if (MMU_STYLE > 1 && execute_valid && execute_fault == 0 &&
             mem_sr_op == `MEM_SR_WRITE) begin
	    segment[execute_R1[31:28]] <= execute_R0 & `SR_valid_msk;
	 end

      if (reset) begin
	 hax_reservation_valid  <= 0;
      end
   end


   /////////////////////////////////////////////////////////////////////////////
   // Bypass paths

   /* Unfortunately, the synchronous D$ read means load data isn't ready this cycle
    * so all there is to forward is an integer op that's in this pipeline stage.
    * That is, mem_pass_R0.  (We don't forward from R1 yet, as that's uncommon/
    * probably not worth it.)  Note this isn't exclusive with doing a load/store,
    * and the -u updated base can be forwarded.  NB: Loads w/ base update write back
    * via port1.
    *
    * The conditions are:
    * - Not stalled/a valid op from EX, not a fault
    *  - DO NOT use !mem_want_stall, because
    * 	 that signal depends on DTC lookup and these signals aren't, by definition
    * 	 active where the DTC is used.  (Makes critical path unnecessarily long!)
    * - Doesn't necessarily imply mem_op == 0, because such an op might have
    * 	a value like a load-update.
    * - passing R0
    * - Will be writing R0 back to a GPR once in WB (via port0 or port1)
    */
   wire instr_generates_result_now = valid_op; // not annulled
   /* Note, !mem_want_stall is similar to enable_change, as long as WB can't stall us,
    * which as yet it cannot.
    */

   assign memory_out_bypass_valid = (instr_generates_result_now &&
				     mem_pass_R0 &&
				     ((wb_write_gpr_port0 &&
				       wb_write_gpr_port0_from == `WB_PORT_R0) ||
				      (wb_write_gpr_port1 &&
				       wb_write_gpr_port1_from == `WB_PORT_R0))
				     );

   assign memory_out_bypass_reg = (wb_write_gpr_port0 &&
				   wb_write_gpr_port0_from == `WB_PORT_R0) ?
				  wb_write_gpr_port0_reg : wb_write_gpr_port1_reg;

   assign memory_out_bypass = execute_R0;

   /* XERCR forwards passed-through condition from execute, except in the case
    * of STWCX's condition, which is generated in this stage.
    * STWCX is then the single exception to the rule that all XERCRs are forwarded.
    * Bypass logic will need to know that this instruction will generate XERCR,
    * but not from here.  (Note, this is different to EX which will always forward
    * XERCR if the instruction writes it.)
    */
   assign memory_out_bypass_xercr_valid = instr_generates_result_now &&
                                          !mem_op_addr_test_reservation && // Isn't STWCX
                                          wb_write_xercr; // and instr will later write condition
   assign memory_out_bypass_xercr = execute_RC;

   // If we *can't* forward a value, dep tracking still needs to know which reg we'll eventually write:
   assign memory_out_writes_gpr0 	= valid_op && wb_write_gpr_port0;
   assign memory_out_writes_gpr0_reg 	= wb_write_gpr_port0_reg;
   assign memory_out_writes_gpr1 	= valid_op && wb_write_gpr_port1;
   assign memory_out_writes_gpr1_reg 	= wb_write_gpr_port1_reg;
   assign memory_out_writes_xercr 	= valid_op && wb_write_xercr;


   /////////////////////////////////////////////////////////////////////////////
   // Perf counting
   assign pctr_mem_access = do_dtc_access && !mem_want_stall; // % Memory access performed (incl faults) %
   assign pctr_mem_access_fault = pctr_mem_access && mmu_fault != 0; // % Memory access leads to fault %


   /////////////////////////////////////////////////////////////////////////////
   // Assign outputs:

   assign memory_fault = memory_fault_r;
   assign memory_instr = memory_instr_r;
   assign memory_pc = memory_pc_r;
   assign memory_msr = memory_msr_r;
   assign memory_ibundle_out = memory_ibundle_out_r;

   assign memory_R0 = memory_R0_r;
   assign memory_R1 = memory_R1_r;
   assign memory_RC = memory_RC_r;
   assign memory_addr = memory_addr_r;

endmodule
