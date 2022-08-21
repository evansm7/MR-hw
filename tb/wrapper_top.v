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

`include "decode_signals.vh"
`include "decode_enums.vh"


//`define DEBUG 1
`define SIM 1

/* verilator lint_off DECLFILENAME */
module tb_top(input wire clk,
              input wire reset);
/* lint_on */

   ////////////////////////////////////////////////////////////////////////////////

   tb_mr_cpu_top TMCT(.clk(clk),
		      .reset(reset)
		      );

   ////////////////////////////////////////////////////////////////////////////////

   reg [256*8:1] filename;
   reg 		 junk;

   initial begin
      if (!$value$plusargs("INPUT_FILE=%s", filename)) begin
         filename="testprog.hex";
      end

      // Load test program:
      $readmemh(filename, TMCT.memory);
   end

endmodule
