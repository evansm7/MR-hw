/* Top-level CPU
 *
 * Typically, this would be wrapped in a bus interface unit, e.g. mr_cpu_mic.
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

`include "decode_enums.vh"
`include "decode_signals.vh"
`include "arch_defs.vh"

module mr_cpu_top(input wire         clk,
                  input wire         reset,

                  input wire         IRQ,

                  /* I-side memory interface (RO, 4 beats) */
                  output wire [31:0] i_emi_addr,
                  input wire [63:0]  i_emi_rdata,
                  output wire [1:0]  i_emi_size, // 1/2/4/CL
                  output wire        i_emi_req,
                  input wire         i_emi_valid,

                  /* I-side memory interface (RW, 1,2,4,32B) */
                  output wire [31:0] d_emi_addr,
                  input wire [63:0]  d_emi_rdata,
                  output wire [63:0] d_emi_wdata,
                  output wire [1:0]  d_emi_size, // 1/2/4/CL
                  output wire        d_emi_RnW,
                  output wire [7:0]  d_emi_bws,
                  output wire        d_emi_req,
                  input wire         d_emi_valid,

		  output wire [63:0] pctrs
                  );

   parameter                         IO_REGION = 2'b11;
   /* Reset with vectors at 0xfff00000, or 0: */
   parameter                         HIGH_VECTORS = 0;
   /* MMU styles: 	0 = nothing (IO_REGION is used to determine cacheability)
    *			1 = BATs
    * 			2 = BATs and TLB/HTAB
    */
   parameter			     MMU_STYLE = 2;

   wire                              decode_stall;
   wire                              execute_stall;
   wire                              memory_stall;

   wire                              execute_annul;
   wire                              writeback_annul;

   // Software-controllable bits for testing:
   wire [7:0]			     debug_bits;

   wire 			     pctr_if_fetching;
   wire 			     pctr_if_fetching_stalled;
   wire 			     pctr_if_valid_instr;
   wire 			     pctr_if_mmu_ptws;
   wire 			     pctr_de_stall_operands;
   wire 			     pctr_mem_access;
   wire 			     pctr_mem_access_fault;
   wire 			     pctr_mem_mmu_ptws;
   wire 			     pctr_mem_cacheable_unaligned_8B;
   wire 			     pctr_mem_cacheable_unaligned_CL;

   ////////////////////////////// IFETCH   //////////////////////////////

   wire                              ifetch_valid;
   wire [3:0]                        ifetch_fault;
   wire [`REGSZ-1:0] 		     ifetch_pc;
   wire [31:0]                       ifetch_instr;
   wire [31:0]                       ifetch_msr;

   wire [`REGSZ-1:0] 		     wb_newpc;
   wire [31:0]                       wb_newmsr;
   wire                              wb_newpcmsr_valid;
   wire [`REGSZ-1:0] 		     branch_newpc;
   wire [31:0] 			     branch_newmsr;
   wire                              branch_newpc_valid;
   wire                              branch_newmsr_valid;

   wire [31:0] 			     inval_addr;
   wire [1:0] 			     inval_type;
   wire 			     inval_req;
   wire 			     inval_ack;

   wire [`REGSZ-1:0] 		     i_ptw_addr;
   wire 			     i_ptw_req;
   wire [`PTW_PTE_SIZE-1:0] 	     i_ptw_tlbe;
   wire [1:0] 			     i_ptw_fault;
   wire 			     i_ptw_ack;

   // IRQs and similar, including test
   wire 			     IRQ_internal = IRQ || debug_bits[0];
   wire 			     DEC_msb;

   wire [(64*`NR_BATs)-1:0] 	     i_bats;

   ifetch #(.IO_REGION(IO_REGION),
	    .HIGH_VECTORS(HIGH_VECTORS),
            .MMU_STYLE(MMU_STYLE))
          IF(.clk(clk),
             .reset(reset),

             .IRQ(IRQ_internal),
	     .DEC_msb(DEC_msb),

             .wb_newpc(wb_newpc),
             .wb_newmsr(wb_newmsr),
             .wb_newpcmsr_valid(wb_newpcmsr_valid),

             .mem_newpc(branch_newpc),
             .mem_newmsr(branch_newmsr),
             .mem_newpc_valid(branch_newpc_valid),
             .mem_newmsr_valid(branch_newmsr_valid),

             .exe_annul(execute_annul),
             .wb_annul(writeback_annul),

             .decode_stall(decode_stall),

             .ifetch_valid(ifetch_valid),
             .ifetch_fault(ifetch_fault),
             .ifetch_pc(ifetch_pc),
             .ifetch_msr(ifetch_msr),

             .ifetch_instr(ifetch_instr),

	     .inval_addr(inval_addr),
	     .inval_type(inval_type),
	     .inval_req(inval_req),
	     .inval_ack(inval_ack),

	     .i_bats(i_bats),

	     .pctr_if_fetching(pctr_if_fetching),
	     .pctr_if_fetching_stalled(pctr_if_fetching_stalled),
	     .pctr_if_valid_instr(pctr_if_valid_instr),
	     .pctr_if_mmu_ptws(pctr_if_mmu_ptws),

	     .ptw_addr(i_ptw_addr),
	     .ptw_req(i_ptw_req),
	     .ptw_tlbe(i_ptw_tlbe),
	     .ptw_fault(i_ptw_fault),
	     .ptw_ack(i_ptw_ack),

             .emi_if_address(i_emi_addr),
             .emi_if_rdata(i_emi_rdata),
	     .emi_if_size(i_emi_size),
	     /* No wdata, no RnW, no bws */
             .emi_if_req(i_emi_req),
             .emi_if_valid(i_emi_valid) // FIXME; also burst size too!
             );


   ////////////////////////////// DECODE   //////////////////////////////

   wire                              decode_valid /* verilator public */;
   wire [3:0]                        decode_fault;
   wire [`REGSZ-1:0] 		     decode_pc;
   wire [31:0]                       decode_msr;
   wire [31:0]                       decode_instr;

   wire [`REGSZ-1:0] 		     execute_bypass;
   wire [4:0] 			     execute_bypass_reg;
   wire 			     execute_bypass_valid;
   wire [`XERCRSZ-1:0]               execute_bypass_xercr;
   wire 			     execute_bypass_xercr_valid;
   wire                              execute_writes_gpr0;
   wire [4:0]                        execute_writes_gpr0_reg;
   wire                              execute_writes_gpr1;
   wire [4:0]                        execute_writes_gpr1_reg;
   wire                              execute_writes_xercr;
   wire                              execute2_writes_gpr0;
   wire [4:0]                        execute2_writes_gpr0_reg;
   wire                              execute2_writes_gpr1;
   wire [4:0]                        execute2_writes_gpr1_reg;
   wire [`REGSZ-1:0] 		     memory_bypass;
   wire [4:0] 			     memory_bypass_reg;
   wire 			     memory_bypass_valid;
   wire [`XERCRSZ-1:0]               memory_bypass_xercr;
   wire 			     memory_bypass_xercr_valid;
   wire                              memory_writes_gpr0;
   wire [4:0]                        memory_writes_gpr0_reg;
   wire                              memory_writes_gpr1;
   wire [4:0]                        memory_writes_gpr1_reg;
   wire                              memory_writes_xercr;

   wire                              writeback_gpr_port0_en;
   wire [4:0]                        writeback_gpr_port0_reg;
   wire [`REGSZ-1:0] 		     writeback_gpr_port0_value;
   wire                              writeback_gpr_port1_en;
   wire [4:0]                        writeback_gpr_port1_reg;
   wire [`REGSZ-1:0] 		     writeback_gpr_port1_value;
   wire                              writeback_xercr_en;
   wire [`XERCRSZ-1:0] 		     writeback_xercr_value;
   wire 			     writeback_spr_en;
   wire [`DE_NR_SPRS_LOG2-1:0] 	     writeback_spr_reg;
   wire [`REGSZ-1:0] 		     writeback_spr_value;
   wire                              writeback_sspr_en;
   wire [`DE_NR_SPRS_LOG2-1:0] 	     writeback_sspr_reg;
   wire [`REGSZ-1:0] 		     writeback_sspr_value;

   wire                              writeback_unlock_generic;

   wire [`DEC_SIGS_SIZE-1:0] 	     decode_ibundle;
   wire [`REGSZ-1:0] 		     op_a;
   wire [`REGSZ-1:0] 		     op_b;
   wire [`REGSZ-1:0] 		     op_c;
   wire [`XERCRSZ-1:0] 		     op_d;

   wire [(64*`NR_BATs)-1:0] 	     d_bats;

   wire [`REGSZ-1:0] 		     sdr1;

   decode #(.WITH_BATS(MMU_STYLE > 0),
            .WITH_MMU(MMU_STYLE > 1))
          DE(.clk(clk),
             .reset(reset),

             .ifetch_valid(ifetch_valid),
             .ifetch_fault(ifetch_fault),
             .ifetch_pc(ifetch_pc),
             .ifetch_instr(ifetch_instr),
             .ifetch_msr(ifetch_msr),

             .writeback_gpr_port0_en(writeback_gpr_port0_en),
             .writeback_gpr_port0_reg(writeback_gpr_port0_reg),
             .writeback_gpr_port0_value(writeback_gpr_port0_value),
             .writeback_gpr_port1_en(writeback_gpr_port1_en),
             .writeback_gpr_port1_reg(writeback_gpr_port1_reg),
             .writeback_gpr_port1_value(writeback_gpr_port1_value),
             .writeback_xercr_en(writeback_xercr_en),
             .writeback_xercr_value(writeback_xercr_value),
             .writeback_spr_en(writeback_spr_en),
             .writeback_spr_reg(writeback_spr_reg),
             .writeback_spr_value(writeback_spr_value),
             .writeback_sspr_en(writeback_sspr_en),
             .writeback_sspr_reg(writeback_sspr_reg),
             .writeback_sspr_value(writeback_sspr_value),
             .writeback_unlock_generic(writeback_unlock_generic),

             .execute_stall(execute_stall),
             .execute_annul(execute_annul),
             .writeback_annul(writeback_annul),

	     .execute_bypass(execute_bypass),
	     .execute_bypass_reg(execute_bypass_reg),
	     .execute_bypass_valid(execute_bypass_valid),
             .execute_bypass_xercr(execute_bypass_xercr),
             .execute_bypass_xercr_valid(execute_bypass_xercr_valid),
             .execute_writes_gpr0(execute_writes_gpr0),
             .execute_writes_gpr0_reg(execute_writes_gpr0_reg),
             .execute_writes_gpr1(execute_writes_gpr1),
             .execute_writes_gpr1_reg(execute_writes_gpr1_reg),
             .execute2_writes_gpr0(execute2_writes_gpr0),
             .execute2_writes_gpr0_reg(execute2_writes_gpr0_reg),
             .execute2_writes_gpr1(execute2_writes_gpr1),
             .execute2_writes_gpr1_reg(execute2_writes_gpr1_reg),
             .execute_writes_xercr(execute_writes_xercr),
	     .memory_bypass(memory_bypass),
	     .memory_bypass_reg(memory_bypass_reg),
	     .memory_bypass_valid(memory_bypass_valid),
             .memory_bypass_xercr(memory_bypass_xercr),
             .memory_bypass_xercr_valid(memory_bypass_xercr_valid),
             .memory_writes_gpr0(memory_writes_gpr0),
             .memory_writes_gpr0_reg(memory_writes_gpr0_reg),
             .memory_writes_gpr1(memory_writes_gpr1),
             .memory_writes_gpr1_reg(memory_writes_gpr1_reg),
             .memory_writes_xercr(memory_writes_xercr),

             .decode_out_a(op_a),
             .decode_out_b(op_b),
             .decode_out_c(op_c),
             .decode_out_d(op_d),

             .decode_valid(decode_valid),
             .decode_fault(decode_fault),
             .decode_pc(decode_pc),
             .decode_msr(decode_msr),
             .decode_instr(decode_instr),
             .decode_ibundle_out(decode_ibundle),

             .decode_stall(decode_stall),

	     .i_bats(i_bats),
	     .d_bats(d_bats),
	     .sdr1(sdr1),

	     .pctr_de_stall_operands(pctr_de_stall_operands),

	     .DEC_msb(DEC_msb),
	     .debug_bits(debug_bits)
             );

   ////////////////////////////// EXECUTE  //////////////////////////////

   wire                              execute_valid;
   wire [3:0]                        execute_fault;
   wire [31:0]                       execute_instr;
   wire [`REGSZ-1:0] 		     execute_pc;
   wire [31:0]                       execute_msr;
   wire 			     execute_brtaken;

   wire [`DEC_SIGS_SIZE-1:0] 	     execute_ibundle;
   wire [`REGSZ-1:0] 		     ex_R0;
   wire [`REGSZ-1:0] 		     ex_R1;
   wire [`REGSZ-1:0] 		     ex_R2;
   wire [`XERCRSZ-1:0] 		     ex_RC;
   wire [5:0]                        ex_miscflags;

   execute EX(.clk(clk),
              .reset(reset),

              .decode_valid(decode_valid),
              .decode_fault(decode_fault),
              .decode_pc(decode_pc),
              .decode_msr(decode_msr),
              .decode_instr(decode_instr),
              .decode_ibundle_in(decode_ibundle),

              .decode_op_a(op_a),
              .decode_op_b(op_b),
              .decode_op_c(op_c),
              .decode_op_d(op_d),

              .memory_stall(memory_stall),
              .writeback_annul(writeback_annul),

              .execute_out_R0(ex_R0),
              .execute_out_R1(ex_R1),
              .execute_out_R2(ex_R2),
              .execute_out_RC(ex_RC),
              .execute_out_miscflags(ex_miscflags),

	      .execute_out_bypass(execute_bypass),
	      .execute_out_bypass_reg(execute_bypass_reg),
	      .execute_out_bypass_valid(execute_bypass_valid),
              .execute_out_bypass_xercr(execute_bypass_xercr),
              .execute_out_bypass_xercr_valid(execute_bypass_xercr_valid),
              .execute_out_writes_gpr0(execute_writes_gpr0),
              .execute_out_writes_gpr0_reg(execute_writes_gpr0_reg),
              .execute_out_writes_gpr1(execute_writes_gpr1),
              .execute_out_writes_gpr1_reg(execute_writes_gpr1_reg),
              .execute_out_writes_xercr(execute_writes_xercr),
              .execute2_out_writes_gpr0(execute2_writes_gpr0),
              .execute2_out_writes_gpr0_reg(execute2_writes_gpr0_reg),
              .execute2_out_writes_gpr1(execute2_writes_gpr1),
              .execute2_out_writes_gpr1_reg(execute2_writes_gpr1_reg),

              .execute_valid(execute_valid),
              .execute_fault(execute_fault),
              .execute_instr(execute_instr),
              .execute_pc(execute_pc),
              .execute_msr(execute_msr),
              .execute_ibundle_out(execute_ibundle),
	      .execute_brtaken(execute_brtaken),

              .execute_annul(execute_annul),
              .execute2_newpc(branch_newpc),
              .execute2_newmsr(branch_newmsr),
              .execute2_newpc_valid(branch_newpc_valid),
              .execute2_newmsr_valid(branch_newmsr_valid),

              .execute_stall(execute_stall)
              );


   ////////////////////////////// MEMORY   //////////////////////////////

   wire                              memory_valid;
   wire [3:0]                        memory_fault;
   wire [31:0]                       memory_instr;
   wire [`REGSZ-1:0] 		     memory_pc;
   wire [31:0]                       memory_msr;

   wire [`DEC_SIGS_SIZE-1:0] 	     memory_ibundle;
   wire [`REGSZ-1:0] 		     mem_R0;
   wire [`REGSZ-1:0] 		     mem_R1;
   wire [`XERCRSZ-1:0] 		     mem_RC;
   wire [`REGSZ-1:0] 		     mem_res;
   wire [`REGSZ-1:0] 		     mem_addr;

   memory #(.IO_REGION(IO_REGION),
            .MMU_STYLE(MMU_STYLE))
          MEM(.clk(clk),
              .reset(reset),

              .execute_valid(execute_valid),
              .execute_fault(execute_fault),
              .execute_instr(execute_instr),
              .execute_pc(execute_pc),
              .execute_msr(execute_msr),
              .execute_ibundle_in(execute_ibundle),
	      .execute_brtaken(execute_brtaken),

              .execute_R0(ex_R0),
              .execute_R1(ex_R1),
              .execute_R2(ex_R2),
              .execute_RC(ex_RC),
              .execute_miscflags(ex_miscflags),

              .writeback_annul(writeback_annul),

              .memory_R0(mem_R0),
              .memory_R1(mem_R1),
              .memory_RC(mem_RC),
              .memory_res(mem_res),
              .memory_addr(mem_addr),

	      .memory_out_bypass(memory_bypass),
	      .memory_out_bypass_reg(memory_bypass_reg),
	      .memory_out_bypass_valid(memory_bypass_valid),
              .memory_out_bypass_xercr(memory_bypass_xercr),
              .memory_out_bypass_xercr_valid(memory_bypass_xercr_valid),
              .memory_out_writes_gpr0(memory_writes_gpr0),
              .memory_out_writes_gpr0_reg(memory_writes_gpr0_reg),
              .memory_out_writes_gpr1(memory_writes_gpr1),
              .memory_out_writes_gpr1_reg(memory_writes_gpr1_reg),
              .memory_out_writes_xercr(memory_writes_xercr),

              .memory_valid(memory_valid),
              .memory_fault(memory_fault),
              .memory_instr(memory_instr),
              .memory_pc(memory_pc),
              .memory_msr(memory_msr),
              .memory_ibundle_out(memory_ibundle),

	      .pctr_mem_access(pctr_mem_access),
	      .pctr_mem_access_fault(pctr_mem_access_fault),
	      .pctr_mem_mmu_ptws(pctr_mem_mmu_ptws),
	      .pctr_mem_cacheable_unaligned_8B(pctr_mem_cacheable_unaligned_8B),
	      .pctr_mem_cacheable_unaligned_CL(pctr_mem_cacheable_unaligned_CL),

	      .inval_addr(inval_addr),
	      .inval_type(inval_type),
	      .inval_req(inval_req),
	      .inval_ack(inval_ack),

	      .i_ptw_addr(i_ptw_addr),
	      .i_ptw_req(i_ptw_req),
	      .i_ptw_tlbe(i_ptw_tlbe),
	      .i_ptw_fault(i_ptw_fault),
	      .i_ptw_ack(i_ptw_ack),

              .emi_if_address(d_emi_addr),
              .emi_if_rdata(d_emi_rdata),
              .emi_if_wdata(d_emi_wdata),
              .emi_if_size(d_emi_size),
              .emi_if_RnW(d_emi_RnW),
              .emi_if_bws(d_emi_bws),
              .emi_if_req(d_emi_req),
              .emi_if_valid(d_emi_valid),

	      .d_bats(d_bats),
	      .sdr1(sdr1),

              .memory_stall(memory_stall)
              );

   ////////////////////////////// WRITEBACK /////////////////////////////

   writeback WB(.clk(clk),
                .reset(reset),

                .memory_valid(memory_valid),
                .memory_fault(memory_fault),
		.memory_instr(memory_instr),
                .memory_pc(memory_pc),
                .memory_msr(memory_msr),
                .memory_ibundle_in(memory_ibundle),

                .memory_R0(mem_R0),
                .memory_R1(mem_R1),
                .memory_RC(mem_RC),
                .memory_res(mem_res),
                .memory_addr(mem_addr),

                .writeback_newpc(wb_newpc),
                .writeback_newmsr(wb_newmsr),
                .writeback_newpcmsr_valid(wb_newpcmsr_valid),

                .writeback_gpr_port0_en(writeback_gpr_port0_en),
                .writeback_gpr_port0_reg(writeback_gpr_port0_reg),
                .writeback_gpr_port0_value(writeback_gpr_port0_value),
                .writeback_gpr_port1_en(writeback_gpr_port1_en),
                .writeback_gpr_port1_reg(writeback_gpr_port1_reg),
                .writeback_gpr_port1_value(writeback_gpr_port1_value),
                .writeback_xercr_en(writeback_xercr_en),
                .writeback_xercr_value(writeback_xercr_value),
                .writeback_spr_en(writeback_spr_en),
                .writeback_spr_reg(writeback_spr_reg),
                .writeback_spr_value(writeback_spr_value),
                .writeback_sspr_en(writeback_sspr_en),
                .writeback_sspr_reg(writeback_sspr_reg),
                .writeback_sspr_value(writeback_sspr_value),
                .writeback_unlock_generic(writeback_unlock_generic),

                .writeback_annul(writeback_annul)
                );


   ////////////////////////////// MISC     //////////////////////////////

   reg [63:0] 			     pctrs_r;
   assign pctrs = pctrs_r;

   // Perfcounters:
   wire 			     pctr_mem_stall = memory_stall;
   wire 			     pctr_exe_stall = execute_stall && !memory_stall;
   wire 			     pctr_decode_stall = decode_stall && !execute_stall;
   wire 			     pctr_inst_commit = memory_valid && memory_fault == 0;
   wire 			     pctr_faults = memory_valid && memory_fault != 0;

   always @(posedge clk)
     pctrs_r <= { /* FIXME: Automate this, to then automate unbundling/prettyprint elsewhere! */
		  pctr_inst_commit,
		  pctr_faults,
		  pctr_mem_stall,
		  pctr_exe_stall,
		  pctr_decode_stall,

		  pctr_if_fetching,
		  pctr_if_fetching_stalled,
		  pctr_if_valid_instr,
		  pctr_if_mmu_ptws,
		  pctr_de_stall_operands,
		  pctr_mem_access,
		  pctr_mem_access_fault,
		  pctr_mem_mmu_ptws,
		  pctr_mem_cacheable_unaligned_8B,
		  pctr_mem_cacheable_unaligned_CL
		  };

endmodule // mr_cpu_top
