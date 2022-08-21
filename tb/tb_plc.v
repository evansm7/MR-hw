/*
 * Copyright 2022 Matt Evans
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

   localparam ITERATIONS = 100000;

   reg 			clk;
   reg 			reset;

   always #`CLK_P clk <= ~clk;

   wire [15:0] 			  random;

   rng RNG(.clk(clk),
	   .reset(reset),
	   .rng_o(random)
	   );


   ////////////////////////////////////////////////////////////////////////////////
   // DUTs

   reg [15+1:0]			  a_data;
   reg 				  a_valid;

   reg [15+1:0]			  b_data;
   wire 			  b_stall;
   wire 			  b_valid;
   wire 			  b_change;
   
   reg [15+1:0]			  c_data;
   reg [3:0]			  cssd;   
   wire 			  c_stall;
   wire 			  c_valid;
   wire 			  c_change;
   wire 			  c_self_stall = (c_data[2] && c_data[11] && c_data[15] && c_data[6]) && (cssd < 5);
   
   reg [15+1:0]			  d_data;
   wire 			  d_stall;
   wire 			  d_valid;
   wire 			  d_change;

   wire 			  end_stall = random[1] && random[3] && (random[4] ^ random[13]);

   reg [23:0] 			  i;
   reg [23:0] 			  j;
   reg [15+1:0] 		  values[ITERATIONS:0];
   reg 				  done;

   wire [15:0] 			  new_data  = random;   
   wire 			  can_launch;
   wire 			  new_value_ready;
   wire 			  last;
   
   assign can_launch = !a_valid || (a_valid && !b_stall);
   assign new_value_ready = (random[3:0] != 3) &&
			    (i < ITERATIONS);
   assign last = (i == (ITERATIONS-1));

   // First PL stage generally produces, but now and then stalls (emits valid=0)
   always @(posedge clk) begin
      if (reset) begin
	 a_valid <= 0;
	 a_data <= 0;
	 b_data <= 0;
	 c_data <= 0;
	 d_data <= 0;
	 cssd <= 0;
	 i <= 0;
	 j <= 0;
	 done <= 0;
	 
      end else if (can_launch) begin
	 if (new_value_ready) begin
	    a_valid <= 1;
	    $display("In: Write %x at %d", new_data, i);
	    values[i] <= {last, new_data};
	    a_data <= {last, new_data};
	    i <= i + 1;
	 end else begin
	    a_valid <= 0;
	 end
      end

      // The pipeline:
      if (b_change)
	b_data <= a_data;

      if (c_change)
	c_data <= b_data;
      if (c_self_stall)
	cssd <= cssd + 1;
      else
	cssd <= 0;

      if (d_change)
	d_data <= c_data;

      // The end:
      //
      if (d_valid && !end_stall) begin
	 if (d_data[15:0] != values[j][15:0]) begin
	    $fatal(1, "FAIL: Mismatch at idx %d: %x, should be %x",
		   j, d_data[15:0], values[j][15:0]);
	 end else begin
	    $display("\tOut: Read %x from %d", values[j][15:0], j);
	 end
	 j <= j + 1;

	 if (d_data[16]) begin	    
	    done <= 1;
	 end
      end
   end
 			  

   plc PLCB(.clk(clk),
	    .reset(reset),

	    /* To/from previous stage */
	    .valid_in(a_valid),
	    .stall_out(b_stall),

	    .self_stall(0),

	    /* To/from next stage */
	    .valid_out(b_valid),
	    .stall_in(c_stall),
	    .annul_in(0),

	    .enable_change(b_change)
	    );

   
   plc PLCC(.clk(clk),
	    .reset(reset),

	    /* To/from previous stage */
	    .valid_in(b_valid),
	    .stall_out(c_stall),

	    .self_stall(c_self_stall),

	    /* To/from next stage */
	    .valid_out(c_valid),
	    .stall_in(d_stall),
	    .annul_in(0),

	    .enable_change(c_change)
	    );


   plc PLCD(.clk(clk),
	    .reset(reset),

	    /* To/from previous stage */
	    .valid_in(c_valid),
	    .stall_out(d_stall),

	    .self_stall(0),

	    /* To/from next stage */
	    .valid_out(d_valid),
	    .stall_in(end_stall),
	    .annul_in(0),

	    .enable_change(d_change)
	    );


   ////////////////////////////////////////////////////////////////////////////////


   initial
     begin
	$dumpfile("tb_plc.vcd");
	$dumpvars(0, top);

	clk <= 0;
	reset <= 1;

	#`CLK;

	reset <= 0;

	//////////////////////////////////////////////////////////////////////

	//#(`CLK*2000);
	@(posedge done);

	$display("PASS");
	
	$finish(0);
     end

endmodule
