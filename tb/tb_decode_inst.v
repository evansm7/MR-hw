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

   reg [31:0] inst;
   wire [`DEC_SIGS_SIZE-1:0] dec_out;
   `DEC_SIGS_DECLARE;

   always @(*)
     begin
	{`DEC_SIGS_BUNDLE} = dec_out;
     end

   ////////////////////////////////////////////////////////////////////////////////
   // DUT
   decode_inst DEC(.instruction(inst),
		   .decode_bundle(dec_out));

   initial
     begin
	$dumpfile("tb_decode_inst.vcd");
	$dumpvars(0, top);

	inst <= 0;
	#1;

	//////////////////////////////////////////////////////////////////////
	// Test for a purely combinatorial module:

	inst <= 32'h918b0040; //     stw     r12,64(r11)
	#1;
	if (exe_R0 != `EXUNIT_INT ||
	    mem_op != `MEM_STORE ||
	    de_portb_imm_name != `DE_IMM_D)
	  $fatal(1, "Mismatch");

	inst <= 32'h7d4802a6; //     mflr    r10
	#1;
	if (wb_write_gpr_port0_reg != 10 ||
	    mem_pass_R0 != 1 ||
	    exe_R0 != `EXUNIT_PORT_C)
	  $fatal(2, "Mismatch");

	#1;
	$display("PASS");
	$finish(0);
     end

endmodule // tb_decode_inst

