/*
 * Copyright 2020 Matt Evans
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

`timescale 1ns/1ns

`include "decode_signals.vh"
`include "decode_enums.vh"

`define CLK   10
`define CLK_P (`CLK/2)


module top();

   wire [31:0]          inst;
   reg 			clk;
   reg 			reset;

   reg [31:0] 		wb_newpc;
   reg [31:0] 		wb_newmsr;
   reg 			wb_newpcmsr_valid;
   reg 			exe_annul;
   reg 			wb_annul;
   reg [31:0] 		mem_newpc;
   reg [31:0] 		mem_newmsr;
   reg 			mem_newpc_valid;
   reg 			mem_newmsr_valid;

   wire 		decode_stall;

   wire 		ifetch_valid;
   wire [3:0] 		ifetch_fault;
   wire [31:0] 		ifetch_instr;
   wire [31:0] 		ifetch_pc;
   wire [31:0] 		ifetch_msr;

   wire 		done;


   // Memory for IF:
   reg [63:0] memory [1023:0];

   reg [63:0] read_data;
   wire       read_req;
   wire [31:0] read_address;
   wire [9:0]  ram_addr = read_address[12:3];

   always @(posedge clk) begin
      if (read_req) begin
	 read_data <= memory[ram_addr];
      end
   end


   ////////////////////////////////////////////////////////////////////////////////
   // DUT
   ifetch IF(.clk(clk),
	     .reset(reset),

	     .IRQ(1'b0),

	     .wb_newpc(wb_newpc),
	     .wb_newmsr(wb_newmsr), /* FIXME size */
	     .wb_newpcmsr_valid(wb_newpcmsr_valid),

	     .exe_annul(exe_annul),
	     .wb_annul(wb_annul),

	     .mem_newpc(mem_newpc),
	     .mem_newmsr(mem_newmsr), /* FIXME size */
	     .mem_newpc_valid(mem_newpc_valid),
	     .mem_newmsr_valid(mem_newmsr_valid),

	     .decode_stall(decode_stall),

	     .ifetch_valid(ifetch_valid),
	     .ifetch_fault(ifetch_fault),
	     .ifetch_pc(ifetch_pc),
	     .ifetch_msr(ifetch_msr), /* FIXME can be optimised */
	     .ifetch_instr(ifetch_instr),

	     .emi_if_address(read_address),
	     .emi_if_req(read_req),
	     .emi_if_rdata(read_data),
	     .emi_if_valid(1'b1)
	     );


   dummy_DE DDE(.clk(clk),
		.reset(reset),

		.instr(ifetch_instr),
		.instr_valid(ifetch_valid),
		.instr_pc(ifetch_pc),
		.instr_fault(ifetch_fault),

		.stall_out(decode_stall),

		.done(done)
	     );


   ////////////////////////////////////////////////////////////////////////////////
   always #`CLK_P clk <= ~clk;


   reg [11:0] i;

   initial
     begin
	$dumpfile("tb_ifetch2.vcd");
	$dumpvars(0, top);

	clk <= 0;
	reset <= 1;

	wb_newpc <= 0;
	wb_newmsr <= 0;
	wb_newpcmsr_valid <= 0;
	exe_annul <= 0;
	wb_annul <= 0;
	mem_newpc <= 0;
	mem_newmsr <= 0;
	mem_newpc_valid <= 0;
	mem_newmsr_valid <= 0;

	/* Initialise test memory */
	for (i = 0; i < 64; i = i + 1) begin
	   memory[i] = {magic_number((i*2)+1), magic_number(i*2)};
	end
/* -----\/----- EXCLUDED -----\/-----
	for (i = 0; i < 64; i = i + 1) begin
	   $display("mem[%d] = %x", i, memory[i]);
	end
 -----/\----- EXCLUDED -----/\----- */

	#`CLK;

	reset <= 0;

	//////////////////////////////////////////////////////////////////////

	#(`CLK*200);

	if (done)
	  $display("PASS");
	else
	  $display("FAIL");

	$finish(0);
     end

   /* Test scenarios:
    *
    * - Regular sequential fetch of instrs
    * - Stall from DE
    * - Trigger a stall in fetch
    * - New PC/MSR from WB and MEM, annul
    * - New PC/MSR whilst stalled on I$!
    * - Fault on address, IRQ -> generate fault out
    * - Fetch after fault resolved -> correct instruction
    *   (including where stall was ongoing due to pre-fault fetch!)
    */

   function [31:0] magic_number;
      input [9:0] addr;
      begin
	 magic_number = {addr[9:0], addr[9:0], addr[9:0]} ^
			{{addr[8:0], addr[8:0], addr[8:0]}, 1'b0} ^
			{{addr[3:0], addr[3:0], addr[3:0]}, 4'h1};
	 // $display("addr %x magic %x", addr, magic_number);
      end
   endfunction // magic_number

endmodule


module dummy_DE(input wire        clk,
		input wire 	  reset,

		input wire 	  instr_valid,
		input wire [31:0] instr_pc,
		input wire [31:0] instr,
		input wire [3:0]  instr_fault,

		output reg 	  done,
		output wire 	  stall_out);

   reg [9:0] 			  counter;
   reg [9:0] 			  i;
   reg [31:0] 			  pc;
`define STATE_READSOME1 0
`define STATE_BRANCH1   1
`define STATE_READSOME2 2
`define STATE_EXCEPTN1  3
`define STATE_READSOME3 4
`define STATE_EXCEPTN2  5
`define STATE_BRANCH2   6
`define STATE_READSOME4 7
   reg [3:0] 			  state;  // Unused for now

   wire [15:0] 			  random;

   rng RNG(.clk(clk),
	   .reset(reset),

	   .rng_o(random)
	   );


   assign stall_out = random[3] && random[9];

   wire [31:0] 			  addr = instr_pc[31:2];
   wire [31:0] 			  magic = magic_number(addr);

   always @(posedge clk) begin
      if (reset) begin
	 counter <= 40; // Hopefully some memory stalls in this time.
	 done <= 0;
	 pc <= 32'h100;

	 state <= `STATE_READSOME1; // FIXME, do more stuff.

      end else begin
	 if (!done) begin
	    if (stall_out) begin
	       $display("Stalling IF");

	    end else if (instr_valid) begin
	       $display("Addr %x: instr %x", instr_pc, instr);

	       pc <= pc + 4;

	       if (instr != magic) begin
		  $fatal(1, "Mismatch:  Addr %x: instr %x, should be %x, mn %x", instr_pc, instr, magic);
	       end

	       if (counter > 0) begin
		  counter <= counter - 1;
	       end else begin
		  done = 1;
	       end

	    end
	 end
      end
   end

endmodule // dummy_DE
