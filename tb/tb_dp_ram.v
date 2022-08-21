/*
 * Copyright 2020, 2022 Matt Evans
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

`define CLK   10
`define CLK_P (`CLK/2)


module top();

   reg 			clk;
   reg 			reset;

   reg 			aen;
   reg 			ben;

   reg [63:0] 		a_wr_data;
   reg [63:0] 		b_wr_data;

   reg [10:0] 		a_addr;
   reg [10:0] 		b_addr;

   reg 			a_we;
   reg 			b_we;

   reg [7:0] 		a_bwe;
   reg [7:0] 		b_bwe;

   wire [63:0] 		a_rd_data;
   wire [63:0] 		b_rd_data;



   ////////////////////////////////////////////////////////////////////////////////
   // DUT
   dp_ram #(.L2WIDTH(3), // 64bit
	    .L2SIZE(14)  // 16KB
	    )
          RAM(.clk(clk),
	      .reset(reset),

	      .a_enable(aen),
	      .a_addr(a_addr),
	      .a_wr_data(a_wr_data),
	      .a_rd_data(a_rd_data),
	      .a_WE(a_we),
	      .a_BWE(a_bwe),

	      .b_enable(ben),
	      .b_addr(b_addr),
	      .b_wr_data(b_wr_data),
	      .b_rd_data(b_rd_data),
	      .b_WE(b_we),
	      .b_BWE(b_bwe)
	      );


   ////////////////////////////////////////////////////////////////////////////////
   always #`CLK_P clk <= ~clk;

   initial
     begin
	$dumpfile("tb_dp_ram.vcd");
	$dumpvars(0, top);

	clk <= 0;
	reset <= 1;

	aen <= 0;
	a_addr <= 0;
	a_wr_data <= 0;
	a_we <= 0;
	a_bwe <= 0;

	ben <= 0;
	b_addr <= 0;
	b_wr_data <= 0;
	b_we <= 0;
	b_bwe <= 0;

	#`CLK_P;

	reset <= 0;

	#`CLK_P;

	//////////////////////////////////////////////////////////////////////

	// Write some stuff:
	a_wr_data <= 64'h12345678abcdef90;
	a_addr <= 1;
	a_bwe <= 8'hff;
	a_we <= 1;
	aen <= 1;
	#`CLK;

	a_wr_data <= 64'h0102030405060708;
	a_addr <= 0;
	a_bwe <= 8'hff;
	a_we <= 1;
	aen <= 1;
	#`CLK;

	aen <= 0;
	b_wr_data <= 64'h0102030405060708;
	b_addr <= 2;
	b_bwe <= 8'hff;
	b_we <= 1;
	ben <= 1;
	#`CLK;

	// Read back
	a_we <= 0;
	b_we <= 0;
	aen <= 1;
	ben <= 0;
	a_addr <= 1;
	#`CLK;

	if (a_rd_data != 64'h12345678abcdef90)
	  $fatal(1, "Mismatch: read %x", a_rd_data);

	aen <= 0;
	ben <= 1;
	b_addr <= 0;
	#`CLK;

	if (b_rd_data != 64'h0102030405060708)
	  $fatal(1, "Mismatch: read %x", b_rd_data);

	// Test byte write strobes
	aen <= 0;
	b_wr_data <= 64'h1122334455667788;
	b_addr <= 1;
	b_bwe <= 8'haa;
	b_we <= 1;
	ben <= 1;
	#`CLK;

	// Read back
	a_we <= 0;
	b_we <= 0;
	aen <= 1;
	ben <= 0;
	a_addr <= 1;
	#`CLK;

	if (a_rd_data != 64'h1134337855cd7790)
	  $fatal(1, "Mismatch: read %x", a_rd_data);


	$display("PASS");
	$finish(0);
     end

endmodule
