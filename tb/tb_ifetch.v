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
   reg 			decode_stall;

   wire 		ifetch_valid;
   wire [3:0] 		ifetch_fault;
   wire [31:0] 		ifetch_instr;
   wire [31:0] 		ifetch_pc;
   wire [31:0] 		ifetch_msr;



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


   ////////////////////////////////////////////////////////////////////////////////
   always #`CLK_P clk <= ~clk;


   reg [11:0] i;

   initial
     begin
	$dumpfile("tb_ifetch.vcd");
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
	decode_stall <= 0;


	/* Initialise test memory */
	for (i = 0; i < 256; i = i + 1) begin
	   memory[i] = {magic_number((i*2)+1), magic_number(i*2)} ;
	   // $display("mem[%d] = %x", i, memory[i]);
	end

	#`CLK;

	reset <= 0;

	//////////////////////////////////////////////////////////////////////
	// Test 1:  Fetch 3 instrs from addr 0:

	wait_and_test_for_instr(32'h100, 1);
	wait_and_test_for_instr(32'h104, 1);
	wait_and_test_for_instr(32'h108, 1);

	// Test 2:  Stall in, ensure clocks don't "do" anything:
	decode_stall <= 1;
	#(`CLK*5);
	decode_stall <= 0;
	// An instruction (addr 2) was fetched at the end of the last test and will have been held.
	// Check that's the case:
	if (!ifetch_valid || ifetch_instr != magic_number(10'h108/4)) begin
	   #`CLK;
	   $fatal(1, "FAIL: Problem after stall, v %d, %x / %x",
		  ifetch_valid, ifetch_instr, magic_number(10'h108/4));
	end

	wait_and_test_for_instr(32'h10c, 1);
	wait_and_test_for_instr(32'h110, 1);

	// Test 3:  Annul, then load a new PC:
	exe_annul <= 1;
	#`CLK;
	exe_annul <= 0;
	wb_newpc <= 32'h00000060;
	wb_newpcmsr_valid <= 1;
	#`CLK;
	wb_newpcmsr_valid <= 0;
	// In this cycle, output won't yet be valid?
	wait_and_test_for_instr(32'h060, 0);

	wait_and_test_for_instr(32'h064, 1);
	wait_and_test_for_instr(32'h068, 1);

	$display("PASS");
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
	 magic_number = {addr, addr, addr} ^ {{addr[8:0], addr[8:0], addr[8:0]}, 1'b0} ^
			{{addr[3:0], addr[3:0], addr[3:0]}, 4'h1};
      end
   endfunction // magic_number

   task wait_and_test_for_instr;
      input [31:0] address;
      input 	   clock_it;

      reg [9:0]    timeout;
      reg [31:0]   match;

      begin
	 timeout = 10'h3ff;
	 match = magic_number(address/4);

	 if (clock_it) begin
	    #`CLK;
	 end

	 while (!ifetch_valid) begin
	    #`CLK;
	    timeout = timeout - 1;
	    if (timeout == 0) begin
	       $fatal(1, "FAIL: wait_and_test_for_instr: timed out (v=%d)", ifetch_valid);
	    end
	 end

	 if (ifetch_pc != address) begin
	    $fatal(1, "FAIL: wait_and_test_for_instr: Wanted addr %x, got %x", address, ifetch_pc);
	 end

	 if (ifetch_fault) begin
	    $fatal(1, "FAIL: wait_and_test_for_instr: Unexpected fault %x", ifetch_fault);
	 end

	 if (ifetch_instr != match) begin
	    $fatal(1, "FAIL: wait_and_test_for_instr: %x != %x, addr %x", ifetch_instr, match, address);
	 end
      end
   endtask // wait_and_test_for_instr

endmodule // top


