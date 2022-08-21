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

   reg 			clk;
   reg 			reset;

   reg			enable;
   reg                  op;
   reg [31:0]           A;
   reg [31:0]           B;

   wire			done;
   wire [31:0]          result;
   wire                 ov;

   ////////////////////////////////////////////////////////////////////////////////
   // DUT
   execute_divide DUT(.clk(clk),
	              .reset(reset),

                      .enable(enable),
                      .unsigned_div(op),
                      .done(done),

                      .in_a(A),
                      .in_b(B),
                      .out(result),
                      .ov(ov)
	              );


   ////////////////////////////////////////////////////////////////////////////////
   always #`CLK_P clk <= ~clk;


   reg [11:0] i;

   initial
     begin
	$dumpfile("tb_execute_divide.vcd");
	$dumpvars(0, top);

	clk    <= 0;
	reset  <= 1;
        enable <= 0;
        op     <= 0;
        A      <= 0;
        B      <= 0;

	#`CLK;

	reset  <= 0;

	//////////////////////////////////////////////////////////////////////

        /* Test scenarios:
         *
         * Signed:
         * +ve / -ve
         * -ve / +ve
         * +ve / +ve
         * -ve / -ve
         *
         * Both:
         * N / 0
         *
         * small / large
         * large / small
         */

        @(posedge clk);
        // Test /0:

        A      <= 32'hfeedface;
        B      <= 32'h0;
        op     <= 0; // Signed
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 1, 32'h80000000);
        enable <= 0;
        @(posedge clk);

        A      <= 32'h00baface;
        B      <= 32'h0;
        op     <= 0; // Signed
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 1, 32'h7fffffff);
        enable <= 0;
        @(posedge clk);

        A      <= 32'hcacebeef;
        B      <= 32'h0;
        op     <= 1; // Unsigned
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 1, 32'hffffffff);
        enable <= 0;
        @(posedge clk);

        // Test some real divides;  first, +ve/+ve large/small:

        A      <= 32'hc234feed;
        B      <= 32'h11;
        op     <= 1; // Unsigned
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 0, 32'h0b6c8777);
        enable <= 0;
        @(posedge clk);

        A      <= 32'h1234feed;
        B      <= 32'h11;
        op     <= 0; // Signed
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 0, 32'h01122d1d);
        enable <= 0;
        @(posedge clk);

        A      <= 32'hdeadbeef;
        B      <= 32'h1234;
        op     <= 1; // Unsigned
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 0, 32'h000c3ba5);
        enable <= 0;
        @(posedge clk);

        A      <= 32'hfffabcde;
        B      <= 32'h69;
        op     <= 1; // Unsigned
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 0, 32'h02701a2e);
        enable <= 0;
        @(posedge clk);

        // Now small/large:
        A      <= 32'h00023456;
        B      <= 32'h00123456;
        op     <= 0; // Signed
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 0, 32'h00000000);
        enable <= 0;
        @(posedge clk);

        // Signed division:  +ve / -ve
        A      <= 32'h00123424;
        B      <= 32'hfffffcad;
        op     <= 0; // Signed
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 0, 32'hfffffa87);
        enable <= 0;
        @(posedge clk);

        // Signed division:  -ve / -ve
        A      <= 32'hffedcbdb;
        B      <= 32'hfffffc97;
        op     <= 0; // Signed
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 0, 32'h00000556);
        enable <= 0;
        @(posedge clk);

        // Signed division:  -ve / +ve
        A      <= 32'hffa98770;
        B      <= 32'h00000123;
        op     <= 0; // Signed
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 0, 32'hffffb3ee);
        enable <= 0;
        @(posedge clk);

        // Test the corner case with /-1
        A      <= 32'h80000000;
        B      <= 32'hffffffff;
        op     <= 0; // Signed
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 1, 32'h7fffffff);
        enable <= 0;
        @(posedge clk);

        // Any old thing/-1
        A      <= 32'h81234567;
        B      <= 32'hffffffff;
        op     <= 0; // Signed
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 0, 32'h7edcba99);
        enable <= 0;
        @(posedge clk);

        // Other things from random testing:
        A      <= 32'h80000000;
        B      <= 32'h0001c020;
        op     <= 0; // Signed
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 0, 32'hFFFFB6E1);
        enable <= 0;
        @(posedge clk);

        A      <= 32'h80000000;
        B      <= 32'hfcfdfeff;
        op     <= 0; // Signed
        enable <= 1;
        @(posedge clk);
        wait_for_done();
        check(ov, result, 0, 32'h0000002a);
        enable <= 0;
        @(posedge clk);

	$display("PASS");
	$finish(0);
     end


   task wait_for_done;
      reg [9:0]    timeout;

      begin
	 timeout = 10'h3ff;

	 while (!done) begin
            @(posedge clk);

	    timeout = timeout - 1;
	    if (timeout == 0) begin
	       $fatal(1, "FAIL: wait_for_done: timed out (v=%d)", done);
	    end
	 end
      end
   endtask

   task check;
      input        ov;
      input [31:0] result;
      input        want_ov;
      input [31:0] want_result;
      begin
         if (ov != want_ov || result != want_result)
           $fatal(1, "FAIL: ov %d (want %d), result %08x (want %08x)",
                  ov, want_ov, result, want_result);
      end
   endtask

endmodule // top


