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

   reg 			read_strobe;
   reg [31:0] 		read_addr;
   reg 			transl;
   reg 			priv;

   wire [31:0] 		read_data;
   wire 		read_stall;
   wire [1:0] 		read_fault;

   // Memory for IF:
   reg [63:0] memory [1023:0];

   reg [63:0] emi_read_data;
   wire       emi_read_req;
   wire [31:0] emi_if_address;
   wire [9:0]  ram_addr = emi_if_address[12:3];

   always @(posedge clk) begin
      if (emi_read_req) begin
	 emi_read_data <= memory[ram_addr];
      end
   end


   ////////////////////////////////////////////////////////////////////////////////
   // DUT
   itlb_icache IF(.clk(clk),
		  .reset(reset),

		  .read_strobe(read_strobe),
		  .read_addr(read_addr),

		  .translation_enabled(transl),
		  .privileged(priv),

		  .read_data(read_data),
		  .stall(read_stall),
		  .fault(read_fault),

		  .emi_if_address(emi_if_address),
		  .emi_if_req(emi_read_req),
		  .emi_if_rdata(emi_read_data),
		  .emi_if_valid(1'b1)
		  );


   ////////////////////////////////////////////////////////////////////////////////
   always #`CLK_P clk <= ~clk;


   reg [11:0] i;

   initial
     begin
	$dumpfile("tb_itlb_icache.vcd");
	$dumpvars(0, top);

	clk <= 0;
	reset <= 1;

	read_strobe <= 0;
	read_addr <= 0;
	transl <= 0;
	priv <= 0;

	/* Initialise test memory */
	for (i = 0; i < 64; i = i + 1) begin
	   memory[i] = {magic_number((i*2)+1), magic_number(i*2)};
	end
	for (i = 0; i < 64; i = i + 1) begin
	   $display("mem[%d] = %x", i, memory[i]);
	end

	#`CLK_P;

	reset <= 0;

	#`CLK_P;

	//////////////////////////////////////////////////////////////////////

	// Test 1:  Read a couple of addresses, test against known RAM contents:
	read_and_test(32'h30);

	read_and_test(32'h68);

	#`CLK;
	read_and_test(32'h184);

	#`CLK;
	read_and_test(32'h110);

	#`CLK;
	read_and_test(32'h180);

	#`CLK;

	$display("PASS");
	$finish(0);
     end


   function [31:0] magic_number;
      input [9:0] addr;
      begin
	 magic_number = {addr[9:0], addr[9:0], addr[9:0]} ^
			{{addr[8:0], addr[8:0], addr[8:0]}, 1'b0} ^
			{{addr[3:0], addr[3:0], addr[3:0]}, 4'h1};
	 // $display("addr %x magic %x", addr, magic_number);
      end
   endfunction // magic_number

   task read_and_test;
      input [31:0] address;

      reg [9:0]    timeout;
      reg [31:0]   match;

      begin
	 timeout = 10'h3ff;
	 match <= magic_number(address/4);

	 read_addr <= address;
	 read_strobe <= 1;

	 #`CLK;

	 while (read_stall) begin
	    #`CLK;
	    timeout = timeout - 1;
	    if (timeout == 0) begin
	       $fatal(1, "FAIL: Timed out");
	    end
	 end

	 $display("Read addr %x, data %x", read_addr, read_data);

	 if (read_fault) begin
	    $fatal(1, "FAIL: Unexpected fault %x", read_fault);
	 end

	 if (read_data != match) begin
	    $fatal(1, "FAIL: Read %x != %x, addr %x", read_data, match, address);
	 end

	 read_strobe <= 0;

      end
   endtask // wait_and_test_for_instr

endmodule
