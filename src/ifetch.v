/* IFETCH pipeline stage:
 *
 * As you might expect, the job of this stage is to fetch 32-bit instructions
 * one by one from ever-increasing memory addresses.  In more detail, this stage
 * holds PC and MSR (using privilege to test for instruction fetch memory
 * permissions), and controls control flow.
 *
 * Fetch faults cause IF to emit a fault record instead of an instruction; IF
 * moves into a fault state and stops fetching instructions.  The fault record
 * pushes earlier instructions through the pipeline, and (unless one of those is
 * a branch/earlier fault), WB gives IF a new PC for the exception vector.
 *
 * External interrupts cause IFETCH to behave similarly.
 *
 * Finally, this stage accepts new PC/MSR values from MEM (branch destinations
 * & RFI) and from WB (faults) which write the PC/MSR.  When this happens, an
 * 'annul' signal is also sent down from later stages, stopping what we're
 * currently doing -- effectively resetting earlier stages.  This is
 * particularly important to unstick us from being in FAULT state, when an
 * earlier branch/exception masks that fault.
 *
 * ME 22/2/20
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


module ifetch(input wire                     clk,
	      input wire 		     reset,

	      /* External interrupt: */
	      input wire 		     IRQ,
	      /* The MSB of the Decrementer (0->1 = event): */
	      input wire 		     DEC_msb,

	      /* WB can instruct us to fetch from elsewhere: */
	      input wire [`REGSZ-1:0] 	     wb_newpc,
	      input wire [31:0] 	     wb_newmsr, /* FIXME size */
	      input wire 		     wb_newpcmsr_valid,

	      /* MEM can also instruct us to fetch from elsewhere: */
	      input wire [`REGSZ-1:0] 	     mem_newpc,
	      input wire [31:0] 	     mem_newmsr, /* FIXME size */
	      input wire 		     mem_newpc_valid,
	      /* If mem_newpc_valid, can optionally also load MSR: */
	      input wire 		     mem_newmsr_valid,

	      /* EXE and WB can instruct us to drop what we're currently doing &
	       * reset: */
	      input wire 		     exe_annul,
	      input wire 		     wb_annul,

	      input wire 		     decode_stall,

	      /* Invalidation request input channel */
	      input wire [31:0] 	     inval_addr,
	      input wire [1:0] 		     inval_type,
	      input wire 		     inval_req,
	      output wire 		     inval_ack,

	      /* BAT registers */
	      input wire [(64*`NR_BATs)-1:0] i_bats,

	      /* Qualifies other outputs: */
	      output wire 		     ifetch_valid,
	      /* Fetch is emitting a fault, not an instruction: */
	      output wire [3:0] 	     ifetch_fault,
	      /* Fetched instruction, PC and MSR of instruction: */
	      output wire [`REGSZ-1:0] 	     ifetch_pc,
	      output wire [31:0] 	     ifetch_msr, /* FIXME can be optimised */
	      output wire [31:0] 	     ifetch_instr,

	      output wire [31:0] 	     ptw_addr,
	      output wire 		     ptw_req,
	      input wire [`PTW_PTE_SIZE-1:0] ptw_tlbe,
	      input wire [1:0] 		     ptw_fault,
	      input wire 		     ptw_ack,

	      /* Perf counters */
	      output wire 		     pctr_if_fetching,
	      output wire 		     pctr_if_fetching_stalled,
	      output wire 		     pctr_if_valid_instr,
	      output wire 		     pctr_if_mmu_ptws,

	      /* External memory interface: */
	      output wire [31:0] 	     emi_if_address,
	      output wire [1:0] 	     emi_if_size,
	      output wire 		     emi_if_req,
	      input wire 		     emi_if_valid,
	      input wire [63:0] 	     emi_if_rdata
	      );

   parameter                     IO_REGION = 2'b11;
   /* Reset with MSR_IP=1 or 0, PC fff00100 or 100. */
   parameter                     HIGH_VECTORS = 0;
   parameter			 MMU_STYLE = 2;

   /////////////////////////////////////////////////////////////////////////////
   // State held in IF:

   reg [31:0] 			 current_pc /*verilator public*/;
   reg [31:0] 			 current_msr /*verilator public*/; /* FIXME size */
   reg [31:0] 			 fetch_pc /*verilator public*/; // Wire
   reg [31:0] 			 fetch_pc_hold;
   reg [31:0] 			 fetch_msr /*verilator public*/; // Wire
   reg [31:0] 			 fetch_msr_hold;
   reg                           DEC_msb_delayed;

   /* state==0 is NORMAL: Fetch normally.
    * state==1 is FAULT:  Stop fetching until a new PC/MSR are written by
    *                     the other end of the pipeline.
    */
`define IF_NORMAL 0
`define IF_FAULT  1
   reg [1:0]			 state;
   reg [3:0] 			 out_is_fault;
   reg 				 out_is_valid;
   reg [31:0] 			 out_pc; /* FIXME: need ff for MSR? */

   // Outputs from TLB/cache block:
   wire [31:0] 			 read_instr;
   wire 			 read_stalled;
   wire 			 read_valid;
   wire [2:0]			 read_addr_fault;


   /////////////////////////////////////////////////////////////////////////////
   // Combinatorial stuff:

   wire				 downstream_stall;
   reg 				 fetch; // Wire
   reg [31:0] 			 new_pc; // Wire
   reg 				 new_pc_valid; // Wire
   reg [31:0] 			 new_msr; // Wire
   reg 				 new_msr_also_valid; // Wire
   reg 				 cache_read_strobe; // Wire
   reg 				 IRQ_exception; // Wire
   reg 				 DEC_exception; // Wire

   wire				 annul = exe_annul || wb_annul;

   always @(*) begin
      /* Default values that are "overwritten" by statements below: */
      new_pc = {current_pc[31:2], 2'b00};
      new_pc_valid = 0;
      new_msr = current_msr;
      new_msr_also_valid = 0;
      IRQ_exception = 0;
      DEC_exception = 0;

      /* First priority is to load PC if MEM/WB instruct this.  The previous
       * cycle will have annulled, and this cycle also annuls.
       */
      if (wb_newpcmsr_valid) begin
	 new_pc = {wb_newpc[31:2], 2'b00};
	 new_pc_valid = 1;
	 new_msr = wb_newmsr;
	 new_msr_also_valid = 1;

      end else if (mem_newpc_valid) begin
	 new_pc = {mem_newpc[31:2], 2'b00};
	 new_pc_valid = 1;
	 if (mem_newmsr_valid) begin
	    new_msr = mem_newmsr;
	    new_msr_also_valid = 1;
	 end

      end

      /* Do we initiate a fetch this cycle? */
      fetch     = (state == `IF_NORMAL && !downstream_stall) || new_pc_valid;

      /* Note: We used to stop a fetch if exe_annul or wb_annul were asserted,
       * but those signals are evaluated very late in the cycle which drastically increases
       * the critical path.
       *
       * To decouple this, we do the fetch anyway and just control the validity of the
       * output:
       *  - If it's a fetch cycle, force the output to 0 if annul occurs
       *  - If the fetch is stalling, then there isn't anything for the annul to do
       *    because (next cycle) newPC is captured and later used for the next legit
       *    fetch.
       *
       * In both cases, the next instruction to be output corresponds to newPC.
       */

      /* Select which PC is used for fetch/itlb_icache input: */
      fetch_pc = {current_pc[31:2], 2'b00};
      fetch_msr = current_msr;

      if (read_stalled) begin
	 /* Hold ITC inputs stable when stalled: */
	 fetch_pc = {fetch_pc_hold[31:2], 2'b00};
	 fetch_msr = fetch_msr_hold;
      end else if (new_pc_valid) begin
	 fetch_pc = {new_pc[31:2], 2'b00};
	 if (new_msr_also_valid) begin
	    fetch_msr = new_msr;
	 end
      end

      /* Note: We force the cache read strobe "on" when the cache is stalled:
       * there must have been a fetch cycle previously for it to have stalled,
       * and the strobe must be maintained during a stall.
       *
       * Separated from fetch just to make debugging a little clearer; a new fetch
       * is not happening when stalled, but the strobe is held high.
       */
      if (fetch || read_stalled)
	cache_read_strobe = 1;
      else
	cache_read_strobe = 0;

      if ((fetch_msr & `MSR_EE) != 0 && IRQ)
	IRQ_exception = 1;

      /* The DEC exception is WRONG AND BROKEN AND TERRIBLE and works
       * well with Linux:
       *
       * My reading of the PPC architecture is that a DEC exception
       * *becomes pending* when the MSB transitions from 0 to 1.  It's
       * an edge, in other words, *not* a level (which is what's implemented
       * here).  Initially I used a pulse and a one-shot event generated
       * here, but that's easy to lose.  The key requirement is DEC irq
       * stays pending until the 0x900 interrupt is invoked.  That's slightly
       * messy as it involves *not* just generating the fault downstream,
       * but matching it up with a wb_newpc indicating it's actually been
       * taken.  Otherwise, they're easy to lose.
       *
       * Before that filth is implemented, just go with a cheeky level.
       * This should only be noticable if, after taking the 0x900, IRQs are
       * unmasked while DEC < 0, which Linux doesn't do.
       */
      if ((fetch_msr & `MSR_EE) != 0 && DEC_msb_delayed)
        DEC_exception = 1;

   end


   /////////////////////////////////////////////////////////////////////////////
   // State
   always @(posedge clk) begin
      /* The plan:
       * A little debug, then deal with PC/next PC.  Then, deal with output
       * values & fault/state changes.
       */

      /* Debug: */
      if (wb_newpcmsr_valid) begin
`ifdef DEBUG   $display("IF: New PC %x/%x from WB", wb_newpc, wb_newmsr);  `endif
	 /* It's actually OK for DE to be stalling when wb_newpcmsr_valid,
	  * because that's asserted in the same cycle as the annul from WB.
	  * (After the next edge, DE will have sorted itself out and will
	  * be empty.)
	  */
      end else if (mem_newpc_valid) begin
`ifdef DEBUG   $display("IF: New PC %x/%x from MEM (msrv %d)", mem_newpc, mem_newmsr, mem_newmsr_valid);  `endif
         //            $display("IF: branch PC %x (%x msrv %d)", mem_newpc, mem_newmsr, mem_newmsr_valid);
	 /* If DE's still stalling, the annul in last cycle didn't do its job! */
         //	    if (downstream_stall) $fatal(1, "IF: Unexpected decode stall 2");

      end


      /* PC handling */
      if (fetch && !read_valid && !read_stalled) begin
	 /* If we attempted a fetch, but output was not valid (meaning we
	  * will stall next cycle) and we're not yet stalled, then capture
	  * the PC/MSR to hold during the stall/miss:
	  */
	 fetch_pc_hold  <= fetch_pc;
	 fetch_msr_hold <= fetch_msr;
      end

      if (fetch && read_valid && !annul && read_addr_fault == 0 && !IRQ_exception && !DEC_exception) begin
	 /* current_pc is updated is a successful fetch cycle
	  * (valid data, not a fault or IRQ), which increments for next time.
	  * Note that new_pc_valid might be asserted in this cycle,
	  * in which case fetch_pc equals new_pc.
	  */
	 current_pc     <= fetch_pc + 4;  /* NOTE 1 */
      end else if (new_pc_valid) begin
	 /* When new_pc is written (in a cycle that isn't a successful fetch
	  * cycle), unconditionally capture it in current_pc.
	  * This is especially important during stall cycles, when otherwise
	  * the new_pc might be missed.
	  */
	 current_pc     <= new_pc;
      end

      if (new_pc_valid && new_msr_also_valid) begin
	 current_msr    <= new_msr;
      end


      if (fetch) begin
	 /* The ITLB/I$ does a new fetch if fetch=1. It responds with
	  * valid/stall/fault outputs.
	  */

	 if (read_valid && read_addr_fault == 0) begin
	    /* We fetched an instruction! */

	    if (IRQ_exception) begin
	       /* IRQ is the simplest thing ever.  It transforms a correctly-fetched
		* instruction into a fault.  (This is somewhat wasteful, as we
		* might've experienced a miss for that instruction, but meh.)
		* It is prioritised below ISI/IF faults.
		*/
`ifdef DEBUG      $display("IF: IRQ taken at PC %08x", new_pc);  `endif
	       /* We move into IF_FAULT state, meaning we stop fetching until
		* WB raises an exception (writes new_pc to IF):
		*/
	       out_is_fault <= `FC_IRQ;
	       state <= `IF_FAULT;

	    end else if (DEC_exception) begin
	       /* Decrementer interrupt works the same as an IRQ.
		* It is prioritised below IRQ. */
`ifdef DEBUG      $display("IF: DEC taken at PC %08x", new_pc);  `endif
	       out_is_fault <= `FC_DEC;
	       state <= `IF_FAULT;

	    end else begin
	       /* SUCCESSFUL FETCH with real instruction output!
		* The instruction data is registered in the ITC block.
		*/
`ifdef DEBUG      $display("IF: Fetch from PC %08x", new_pc);  `endif

	       /* Ultimately, the IF_FAULT state just makes IF stay
		* with fetch=0 until a new_pc forces fetch=1.  However, see the
		* other clauses for read_addr_fault and even simply !valid: any
		* attempt to fetch is what returns back to IF_NORMAL, not just
		* a successful fetch.
		*/
	       out_is_fault <= `FC_NONE;
	       state <= `IF_NORMAL;

	       /* *NOTE 1*:  On a successful fetch we update PC: this
		* happens in the "PC handling" section above.
		*/
	    end

            /* Output is dropped if we're asked to annul: */
	    out_is_valid <= !annul;
	    out_pc <= {fetch_pc[31:2], 2'b00};

	 end else if (read_valid && read_addr_fault != 0) begin
	    /* ITLB combinatorially checked new_pc and hated it,
	     * flagging read_addr_fault (comb).  Instead of an
	     * instruction, emit a fault code:
	     */
	    if (read_addr_fault == `MMU_FAULT_TF) begin
	       out_is_fault <= `FC_ISI_TF;
	    end else if (read_addr_fault == `MMU_FAULT_PF) begin
	       out_is_fault <= `FC_ISI_PF;
	    end else if (read_addr_fault == `MMU_FAULT_NX) begin
	       out_is_fault <= `FC_ISI_NX;
	    end

`ifdef DEBUG   $display("IF: Fetch causing fault %d", out_is_fault);  `endif
	    out_is_valid <= !annul;
	    out_pc <= {fetch_pc[31:2], 2'b00};
	    state <= `IF_FAULT;

	 end else if (!read_valid) begin
`ifdef DEBUG   $display("IF: Fetch I$ invalid, stalling");  `endif
	    /* Attempting a fetch, but the ITLB/I$ aren't giving answers in
	     * this cycle; we will stall.  So, nothing to output.
	     */
	    out_is_valid <= 0;
	    state <= `IF_NORMAL;

	 end

      end else begin
	 /* Not fetching.  There are three reasons for this:
	  * 1. Decode stall
	  * 2. We've been annulled by WB or MEM (note, annul takes
	  *    precedence over decode stall!)
	  * 3. We're not in IF_NORMAL (i.e. we're stuck in IF_FAULT
	  *    state until someone annuls us or writes a new PC!)
	  *
	  * downstream_stall means hold outputs until DE is ready; all other
	  * reasons (annul or IF_FAULT) provide no valid output.
	  */
	 if (!downstream_stall || annul) begin
	    out_is_valid <= 0;
	 end

      end // else: !if(fetch)

      /* External MSB can be pipelined for even more timing karma. */
      DEC_msb_delayed <= DEC_msb;

      if (reset) begin
	 if (HIGH_VECTORS) begin
	    current_pc     <= `RESET_PC_HI;
	    current_msr    <= `RESET_MSR_HI;
	 end else begin
	    current_pc     <= `RESET_PC_LO;
	    current_msr    <= `RESET_MSR_LO;
	 end
	 state          <= `IF_NORMAL;
	 out_is_valid   <= 1'b0;
      end
   end // always @ (posedge clk)

   /////////////////////////////////////////////////////////////////////////////
   /* Instruction memory/cache:
    *
    * When enabled (fetch), presents read data at output synchronously; holds this
    * data until next read, so that's effectively holding this stage's output.
    *
    * It flags (asynchronously, i.e. THIS clock cycle) whether the address causes
    * a fault, or a miss of some kind.
    *
    * That is, a read is triggered when strobe=1 and output is valid at the next
    * edge that has valid=1.  The valid output could be a fault type, or read_data.
    * Stall cycle(s) follows a cycle having strobe=1 but valid=0.
    */

   wire pctr_mmu_ptws;

   itlb_icache #(.IO_REGION(IO_REGION),
                 .MMU_STYLE(MMU_STYLE))
               ITC(.clk(clk),
		   .reset(reset),

		   .read_strobe(cache_read_strobe),
		   .read_addr(fetch_pc),

		   .translation_enabled((fetch_msr & `MSR_IR) != 0),
		   .privileged((fetch_msr & `MSR_PR) == 0),

		   .read_data(read_instr),
		   .stall(read_stalled),
		   .valid(read_valid),
		   .fault(read_addr_fault),

		   .inval_addr(inval_addr),
		   .inval_type(inval_type),
		   .inval_req(inval_req),
		   .inval_ack(inval_ack),

		   .i_bats(i_bats),

		   .pctr_mmu_ptws(pctr_mmu_ptws),

		   .ptw_addr(ptw_addr),
		   .ptw_req(ptw_req),
		   .ptw_tlbe(ptw_tlbe),
		   .ptw_fault(ptw_fault),
		   .ptw_ack(ptw_ack),

		   .emi_if_address(emi_if_address),
		   .emi_if_size(emi_if_size),
		   .emi_if_req(emi_if_req),
		   .emi_if_valid(emi_if_valid),
		   .emi_if_rdata(emi_if_rdata)
		   );

   /////////////////////////////////////////////////////////////////////////////
   // Performance counters

   // Note these are a particular format, to grep for 'assign pctr_([^= ]*).*;\s*//\s*%(.*)%$'
   assign pctr_if_fetching = cache_read_strobe;  // % IF cycles requesting fetch %
   assign pctr_if_fetching_stalled = cache_read_strobe && !read_valid;  // % IF cycles stalled for cache %
   assign pctr_if_valid_instr = ifetch_valid;  // % IF instruction fetched %

   assign pctr_if_mmu_ptws = pctr_mmu_ptws;  // % TLB miss caused PTW %


   /////////////////////////////////////////////////////////////////////////////
   // Skid buffer for IF stage outputs:
   // The key purpose of this is to decouple the downstream stall (decode_stall)
   // from the stall this stage experiences.  With this scheme, IF's stall
   // comes direct from a register, not a lengthy comb path.  Clock speed should
   // improve!

`define IF_USE_SBUFF 1
`ifdef IF_USE_SBUFF
   wire		ds_ready;
   assign 	downstream_stall = !ds_ready;

   sbuff #(.WIDTH(100))
         IFSB(.clk(clk),
              .reset(reset),
	      // Input port:
	      .i_valid(out_is_valid),
	      .i_ready(ds_ready),
	      .i_data({out_is_fault, out_pc, current_msr, read_instr}),
	      // Output port:
	      .o_valid(ifetch_valid),
	      .o_ready(!decode_stall),
	      .o_data({ifetch_fault, ifetch_pc, ifetch_msr, ifetch_instr}),
              // Annul this too!
              .empty_all(annul)
              );

`else
   assign 	downstream_stall = decode_stall;
   // Assign outputs:

   assign ifetch_valid = out_is_valid;
   assign ifetch_fault = out_is_fault;
   assign ifetch_pc = out_pc;
   assign ifetch_msr = current_msr;
   assign ifetch_instr = read_instr;
`endif

endmodule // ifetch
