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
   reg [4:0]  rotamt;
   wire [31:0] rotres;

   reg [4:0]   mask_s;
   reg [4:0]   mask_e;
   wire [31:0] mask;

   reg [5:0]   sh_op;
   reg [31:0]  insertee_sh;
   reg [14:0]  SH_MB_ME;
   wire [31:0] rmres;
   wire        rm_co;

   ////////////////////////////////////////////////////////////////////////////////
   // DUTs

   rotate ROT(.val(value),
              .rol(rotamt),
              .out(rotres));

   mask MASK(.start_bit(mask_s),
             .stop_bit(mask_e),
             .out(mask));

   execute_rotatemask ERM(.op(sh_op),
                          .in_val(value),
                          .insertee_sh(insertee_sh),
                          .SH_MB_ME(SH_MB_ME),
                          .out(rmres),
                          .co(rm_co));


   initial
     begin
	$dumpfile("tb_rotatemask.vcd");
	$dumpvars(0, top);

	#1;

	//////////////////////////////////////////////////////////////////////
	// Test for a purely combinatorial module:

        // First, test the rotator:

        value <= 32'h00000000;
        rotamt <= 5;
	#1;
	if (rotres != 32'h00000000) $fatal(1, "FAIL: %x<<l %d=%x", value, rotamt, rotres);

        value <= 32'h01000300;
        rotamt <= 13;
	#1;
	if (rotres != 32'h00600020) $fatal(1, "FAIL: %x<<l %d=%x", value, rotamt, rotres);

        value <= 32'hdeadbeef;
        rotamt <= 17;
	#1;
	if (rotres != 32'h7ddfbd5b) $fatal(1, "FAIL: %x<<l %d=%x", value, rotamt, rotres);

        value <= 32'hcafebabe;
        rotamt <= 1;
	#1;
	if (rotres != 32'h95fd757d) $fatal(1, "FAIL: %x<<l %d=%x", value, rotamt, rotres);

        value <= 32'hcafebabe;
        rotamt <= 4;
	#1;
	if (rotres != 32'hafebabec) $fatal(1, "FAIL: %x<<l %d=%x", value, rotamt, rotres);

        value <= 32'hcafebabe;
        rotamt <= 8;
	#1;
	if (rotres != 32'hfebabeca) $fatal(1, "FAIL: %x<<l %d=%x", value, rotamt, rotres);

        value <= 32'hcafebabe;
        rotamt <= 12;
	#1;
	if (rotres != 32'hebabecaf) $fatal(1, "FAIL: %x<<l %d=%x", value, rotamt, rotres);

        value <= 32'hcafebabe;
        rotamt <= 16;
	#1;
	if (rotres != 32'hbabecafe) $fatal(1, "FAIL: %x<<l %d=%x", value, rotamt, rotres);

        value <= 32'hcafebabe;
        rotamt <= 20;
	#1;
	if (rotres != 32'habecafeb) $fatal(1, "FAIL: %x<<l %d=%x", value, rotamt, rotres);

        value <= 32'hcafebabe;
        rotamt <= 24;
	#1;
	if (rotres != 32'hbecafeba) $fatal(1, "FAIL: %x<<l %d=%x", value, rotamt, rotres);

        value <= 32'hcafebabe;
        rotamt <= 28;
	#1;
	if (rotres != 32'hecafebab) $fatal(1, "FAIL: %x<<l %d=%x", value, rotamt, rotres);

        value <= 32'hf007face;
        rotamt <= 9;
	#1;
	if (rotres != 32'h0ff59de0) $fatal(1, "FAIL: %x<<l %d=%x", value, rotamt, rotres);

        value <= 32'hf007face;
        rotamt <= 18;
	#1;
	if (rotres != 32'heb3bc01f) $fatal(1, "FAIL: %x<<l %d=%x", value, rotamt, rotres);

        //////////////////////////////////////////////////////////////////////

        // Now test the masker:
        mask_s <= 17;
        mask_e <= 1;
        #1;
        if (mask != 32'h0003fffe) $fatal(1, "FAIL: Mask %d-%d =%x", mask_s, mask_e, mask);

        mask_s <= 31;
        mask_e <= 7;
        #1;
        if (mask != 32'hffffff80) $fatal(1, "FAIL: Mask %d-%d =%x", mask_s, mask_e, mask);

        mask_s <= 12;
        mask_e <= 3;
        #1;
        if (mask != 32'h00001ff8) $fatal(1, "FAIL: Mask %d-%d =%x", mask_s, mask_e, mask);

        mask_s <= 31;
        mask_e <= 31;
        #1;
        if (mask != 32'h80000000) $fatal(1, "FAIL: Mask %d-%d =%x", mask_s, mask_e, mask);

        mask_s <= 0;
        mask_e <= 0;
        #1;
        if (mask != 32'h00000001) $fatal(1, "FAIL: Mask %d-%d =%x", mask_s, mask_e, mask);

        mask_s <= 31;
        mask_e <= 0;
        #1;
        if (mask != 32'hffffffff) $fatal(1, "FAIL: Mask %d-%d =%x", mask_s, mask_e, mask);

        mask_s <= 0;
        mask_e <= 31;
        #1;
        if (mask != 32'h80000001) $fatal(1, "FAIL: Mask %d-%d =%x", mask_s, mask_e, mask);

        mask_s <= 0;
        mask_e <= 1;
        #1;
        if (mask != 32'hffffffff) $fatal(1, "FAIL: Mask %d-%d =%x", mask_s, mask_e, mask);

        mask_s <= 7;
        mask_e <= 24;
        #1;
        if (mask != 32'hff0000ff) $fatal(1, "FAIL: Mask %d-%d =%x", mask_s, mask_e, mask);

        mask_s <= 22;
        mask_e <= 24;
        #1;
        if (mask != 32'hff7fffff) $fatal(1, "FAIL: Mask %d-%d =%x", mask_s, mask_e, mask);

        mask_s <= 22;
        mask_e <= 30;
        #1;
        if (mask != 32'hc07fffff) $fatal(1, "FAIL: Mask %d-%d =%x", mask_s, mask_e, mask);

        mask_s <= 20;
        mask_e <= 29;
        #1;
        if (mask != 32'he01fffff) $fatal(1, "FAIL: Mask %d-%d =%x", mask_s, mask_e, mask);

        //////////////////////////////////////////////////////////////////////

        // Top-level rotatemask tests:

        // Shift right:
        sh_op       <= `EXOP_SH_SRW_AB;
        SH_MB_ME    <= 15'h1234; // Should be ignored
        value       <= 32'hdeadbeef;
        insertee_sh <= 9;
	#1;
        if (rmres != 32'h006f56df) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        insertee_sh <= 1;
	#1;
        if (rmres != 32'h6f56df77) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        insertee_sh <= 0;
	#1;
        if (rmres != 32'hdeadbeef) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        insertee_sh <= 35;
	#1;
        if (rmres != 32'h00000000) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        insertee_sh <= 31;
	#1;
        if (rmres != 32'h00000001) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);


        // Shift right algebraic:
        sh_op       <= `EXOP_SH_SRAW_AB;
        SH_MB_ME    <= 15'h4567;
        value       <= 32'hfacecace; // SXT'd
        insertee_sh <= 5;
	#1;
        if (rmres != 32'hffd67656 && rm_co != 1) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        value       <= 32'h7acecace;
        insertee_sh <= 5;
	#1;
        if (rmres != 32'h03d67656 && rm_co != 0) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        value       <= 32'h7acecace;
        insertee_sh <= 31;
	#1;
        if (rmres != 32'h00000000 && rm_co != 0) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        value       <= 32'hfacecace;
        insertee_sh <= 32; // Fills with sign
	#1;
        if (rmres != 32'hffffffff && rm_co != 0) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);
        // ? co cleared?

        value       <= 32'h7acecace;
        insertee_sh <= 39; // Fills with sign
	#1;
        if (rmres != 32'h00000000 && rm_co != 0) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        value       <= 32'hcafecace;
        insertee_sh <= 0; // No change, no carry
	#1;
        if (rmres != 32'hcafecace && rm_co != 0) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        // Shift left:
        sh_op       <= `EXOP_SH_SLW_AB;
        SH_MB_ME    <= 15'h1234; // Should be ignored
        value       <= 32'hdeadbeef;
        insertee_sh <= 3;
	#1;
        if (rmres != 32'hf56df778) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        insertee_sh <= 0;
	#1;
        if (rmres != 32'hdeadbeef) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        insertee_sh <= 31;
	#1;
        if (rmres != 32'h80000000) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        insertee_sh <= 34;
	#1;
        if (rmres != 32'h00000000) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);


        // Now the biggies, rlwimi/rlwnm:
        sh_op       <= `EXOP_SH_RLWNM_ABC;
        // RLWNM takes MB/ME from this input:
        SH_MB_ME    <= {5'h0, 5'd0, 5'd31};
        // ...and a shift from here:
        value       <= 32'hdeadbeef;
        insertee_sh <= 7;
	#1;
        if (rmres != 32'h56df77ef) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        SH_MB_ME    <= {5'h0, 5'd4, 5'd31};
        insertee_sh <= 20;
	#1;
        if (rmres != 32'h0efdeadb) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        SH_MB_ME    <= {5'h0, 5'd0, 5'd13};
        insertee_sh <= 20;
	#1;
        if (rmres != 32'heefc0000) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        SH_MB_ME    <= {5'h0, 5'd17, 5'd16}; // Inverted, weird wrappy, all 1
        insertee_sh <= 12;
	#1;
        if (rmres != 32'hdbeefdea) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        SH_MB_ME    <= {5'h0, 5'd17, 5'd15}; // Inverted, weird wrappy
        insertee_sh <= 12;
	#1;
        if (rmres != 32'hdbee7dea) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        SH_MB_ME    <= {5'h0, 5'd20, 5'd13}; // Inverted, weird wrappy
        insertee_sh <= 16;
	#1;
        if (rmres != 32'hbeec0ead) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);


        // Finally, mask insert:
        sh_op       <= `EXOP_SH_RLWIMI_ABC;
        // RLWIMI takes SH as well as MB/ME from this input:
        SH_MB_ME    <= {5'd16, 5'd0, 5'd31};
        // ...and a value from here:
        insertee_sh <= 32'hffffffff;
        value       <= 32'hb00ccafe;
	#1;
        if (rmres != 32'hcafeb00c) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        SH_MB_ME    <= {5'd16, 5'd8, 5'd19};
        insertee_sh <= 32'h55555555;
        value       <= 32'hb00ccafe;
	#1;
        if (rmres != 32'h55feb555) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        SH_MB_ME    <= {5'd24, 5'd16, 5'd27};
        insertee_sh <= 32'h11111111;
        value       <= 32'hb00bface;
	#1;
        if (rmres != 32'h11110bf1) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);

        SH_MB_ME    <= {5'd4, 5'd24, 5'd11}; // Inverted
        insertee_sh <= 32'h11111111;
        value       <= 32'hb00bface;
	#1;
        if (rmres != 32'h00b111eb) $fatal(1, "FAIL: SH %d %x-%x-%x=%x", sh_op, value, insertee_sh, SH_MB_ME, rmres);


	$display("PASS");
	$finish(0);
     end

endmodule // tb_decode_inst

