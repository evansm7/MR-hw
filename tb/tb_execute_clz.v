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


module top();

   reg [31:0] value;
   wire [5:0] count;

   ////////////////////////////////////////////////////////////////////////////////
   // DUT
   execute_clz CLZ(.in(value),
		   .count(count));

   initial
     begin
	$dumpfile("tb_execute_clz.vcd");
	$dumpvars(0, top);

	#1;

	//////////////////////////////////////////////////////////////////////
	// Test for a purely combinatorial module:

        value <= 32'h00000000;
	#1;
	if (count != 32)
	  $fatal(1, "Mismatch: %x -> %d", value, count);

        value <= 32'hffffffff;
	#1;
	if (count != 0)
	  $fatal(1, "Mismatch: %x -> %d", value, count);

        value <= 32'hdeadbeef;
	#1;
	if (count != 0)
	  $fatal(1, "Mismatch: %x -> %d", value, count);

        value <= 32'h7eefbeef;
	#1;
	if (count != 1)
	  $fatal(1, "Mismatch: %x -> %d", value, count);

        value <= 32'h000001e0;
	#1;
	if (count != 23)
	  $fatal(1, "Mismatch: %x -> %d", value, count);

        value <= 32'h00002000;
	#1;
	if (count != 18)
	  $fatal(1, "Mismatch: %x -> %d", value, count);

        value <= 32'h000400ff;
	#1;
	if (count != 13)
	  $fatal(1, "Mismatch: %x -> %d", value, count);

        value <= 32'h008cfffe;
	#1;
	if (count != 8)
	  $fatal(1, "Mismatch: %x -> %d", value, count);

        value <= 32'h030c000c;
	#1;
	if (count != 6)
	  $fatal(1, "Mismatch: %x -> %d", value, count);

        value <= 32'h130c0fff;
	#1;
	if (count != 3)
	  $fatal(1, "Mismatch: %x -> %d", value, count);

	#1;
	$display("PASS");
	$finish(0);
     end

endmodule // tb_decode_inst

