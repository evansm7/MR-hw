/* MIC interface for CPU top-level
 *
 * This module is the component that instantiates a CPU in a MIC-based system.
 * It bridges between the two EMI interfaces (from I-cache + D-cache) and the
 * MIC interconnect.
 *
 * ME 27/5/20
 *
 * Copyright 2020-2022 Matt Evans
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

/* Here's a picture lolz

	            |||                          |||
	 +------------------------+  +------------------------+
	 |           	       	  |  |                        |
	 |         I-cache        |  |        D-cache         |
	 |                        |  |                        |
	 +------------------------+  +------------------------+
			  \                  /
			   \                /
			+----------------------+
			| Arbitrate            |
			| Generate MIC packets |
			| Receive MIC responses|
			+----------------------+
			            |
				    V
		      MIC-based interconnect/system
*/


module mr_cpu_mic(input wire         clk,
		  input wire 	     reset,

		  input wire 	     IRQ,
		  output wire [63:0] pctrs,

		  /* MIC request channel */
		  output wire 	     O_TVALID,
		  input wire 	     O_TREADY,
		  output wire [63:0] O_TDATA,
		  output wire 	     O_TLAST,

		  /* MIC response channel */
		  input wire 	     I_TVALID,
		  output wire 	     I_TREADY,
		  input wire [63:0]  I_TDATA,
		  input wire 	     I_TLAST
		  );

   /* This parameter is percolated down to caches to determine uncacheable accesses: */
   parameter                         IO_REGION = 2'b11;
   parameter                         HIGH_VECTORS = 0;
   parameter			     MMU_STYLE = 2;

   reg [1:0] 			     state;
`define BIF_STATE_IDLE 0
`define BIF_STATE_REQD 1
`define BIF_STATE_REQI 2
   reg [1:0] 			     beat_counter;

   wire 			     req_ready;
   reg 				     req_start;
   reg 				     req_RnW; // Wire
   reg [7:0] 			     req_beats; // Wire
   reg [31:3] 			     req_address; // Wire
   reg [4:0] 			     req_byte_enables; // Wire

   wire [63:0] 			     read_data;
   wire 			     read_data_valid;
   reg 				     read_data_ready; // Wire

   reg [63:0] 			     write_data; // Wire
   reg 				     write_data_valid; // Wire
   wire 			     write_data_ready;

   /* MIC master interface: */
   mic_m_if #(.NAME("MICAPB"))
            mif (.clk(clk),
		 .reset(reset),
		 /* MIC signals */
		 .O_TVALID(O_TVALID),
		 .O_TREADY(O_TREADY),
		 .O_TDATA(O_TDATA),
		 .O_TLAST(O_TLAST),

		 .I_TVALID(I_TVALID),
		 .I_TREADY(I_TREADY),
		 .I_TDATA(I_TDATA),
		 .I_TLAST(I_TLAST),

		 /* Control/data signals */
		 .req_ready(req_ready),         // Out, I/F ready for a new request
		 .req_start(req_start),         // In, start request
		 .req_RnW(req_RnW),
		 .req_beats(req_beats),
		 .req_address(req_address),
		 .req_byte_enables(req_byte_enables),

		 .read_data(read_data),
		 .read_data_valid(read_data_valid),
		 .read_data_ready(read_data_ready),

		 .write_data(write_data),
		 .write_data_valid(write_data_valid),
		 .write_data_ready(write_data_ready)
		 );


   // Wiring
   wire [31:0] 			     i_emi_addr;
   reg [63:0] 			     i_emi_rdata; // Wire
   wire [1:0] 			     i_emi_size;
   wire 			     i_emi_req;
   reg 				     i_emi_valid; // Wire

   wire [31:0] 			     d_emi_addr;
   reg [63:0] 			     d_emi_rdata; // Wire
   wire [63:0] 			     d_emi_wdata;
   wire [1:0] 			     d_emi_size;
   wire 			     d_emi_RnW;
   wire [7:0] 			     d_emi_bws;
   wire 			     d_emi_req;
   reg 				     d_emi_valid; // Wire

   /* CPU */
   mr_cpu_top #(.IO_REGION(IO_REGION),
		.HIGH_VECTORS(HIGH_VECTORS),
                .MMU_STYLE(MMU_STYLE)
		)
              CPU(.clk(clk),
		  .reset(reset),

		  .IRQ(IRQ),
		  .pctrs(pctrs),

		  .i_emi_addr(i_emi_addr),
		  .i_emi_rdata(i_emi_rdata),
		  .i_emi_size(i_emi_size), // 1/2/4/CL
		  .i_emi_req(i_emi_req),
		  .i_emi_valid(i_emi_valid),

		  .d_emi_addr(d_emi_addr),
		  .d_emi_rdata(d_emi_rdata),
		  .d_emi_wdata(d_emi_wdata),
		  .d_emi_size(d_emi_size), // 1/2/4/CL
		  .d_emi_RnW(d_emi_RnW),
		  .d_emi_bws(d_emi_bws),
		  .d_emi_req(d_emi_req),
		  .d_emi_valid(d_emi_valid)
		  );

   /////////////////////////////////////////////////////////////////////////////
   // Do the work!

   always @(*) begin
      read_data_ready = 1;  // CPU is always ready to accept read data it asked for
      write_data_valid = 1; // CPU write data is always valid

      /* Defaults, when idle */
      req_RnW = 1'b1;
      req_beats = 8'h00;
      req_address = 29'h0;

      i_emi_rdata = 64'h0;
      i_emi_valid = 1'b0;
      d_emi_rdata = 64'h0;
      d_emi_valid = 1'b0;

      write_data = 64'h0; // Isn't really necessary but clearer for debugging...

      req_byte_enables = 5'h1f;

      if (state == `BIF_STATE_REQD) begin
	 req_RnW = d_emi_RnW;

	 if (d_emi_size == 2'b11) begin // CL
	    req_beats = 8'h03; // 4 beats
	    req_byte_enables = 5'h1f;
	 end else if (d_emi_size == 2'b10) begin // 32
	    req_beats = 8'h00; // 1 beat
	    req_byte_enables = {2'b10, d_emi_addr[2], 2'b00};
	 end else if (d_emi_size == 2'b01) begin // 16
	    req_beats = 8'h00; // 1 beat
	    req_byte_enables = {2'b01, d_emi_addr[2:1], 1'b0};
	 end else begin // 8
	    req_beats = 8'h00; // 1 beat
	    req_byte_enables = {2'b00, d_emi_addr[2:0]};
	 end

	 req_address = d_emi_addr[31:3];

	 i_emi_rdata = 64'h0;
	 i_emi_valid = 1'b0;
	 d_emi_rdata = read_data;
	 d_emi_valid = d_emi_RnW ? read_data_valid : write_data_ready;

	 write_data = d_emi_wdata;

      end else if (state == `BIF_STATE_REQI) begin
	 req_RnW = 1'b1;

	 if (i_emi_size == 2'b11) begin // CL
	    req_beats = 8'h03; // 4 beats
	    req_byte_enables = 5'h1f;
	 end else begin
	    req_beats = 8'h00; // 1 beat
	    // Show request for low vs high word:
	    req_byte_enables = {2'b10, i_emi_addr[2], 2'b00};
	 end

	 req_address = i_emi_addr[31:3];

	 i_emi_rdata = read_data;
	 i_emi_valid = read_data_valid;
	 d_emi_rdata = 64'h0;
	 d_emi_valid = 1'b0;

	 write_data = 64'h0;

      end
   end


   // State machine

   always @(posedge clk) begin
      case (state)
	`BIF_STATE_IDLE: begin
	   /* If a request is pending, move to corresponding REQ state,
	    * then pulse 'start' for 1 cycle.
	    */
	   if (req_ready) begin
	      if (d_emi_req) begin // D-fetch gets priority
		 state       <= `BIF_STATE_REQD;
		 req_start   <= 1;
		 if (d_emi_size == 2'b11) // CL
		   beat_counter <= 2'h3;
		 else
		   beat_counter <= 2'h0;

	      end else if (i_emi_req) begin
		 state       <= `BIF_STATE_REQI;
		 req_start   <= 1;
		 if (i_emi_size == 2'b11) // CL
		   beat_counter <= 2'h3;
		 else
		   beat_counter <= 2'h0;
	      end
	   end
	end

	`BIF_STATE_REQD: begin
	   req_start <= 0;
	   if (d_emi_valid) begin
	      if (beat_counter != 0)
		beat_counter <= beat_counter - 1;
	      else
		state <= `BIF_STATE_IDLE;
	   end
	end

	`BIF_STATE_REQI: begin
	   req_start <= 0;
	   if (i_emi_valid) begin
	      if (beat_counter != 0)
		beat_counter <= beat_counter - 1;
	      else
		state <= `BIF_STATE_IDLE;
	   end
	end
      endcase // case (state)

      if (reset) begin
	 state          <= `BIF_STATE_IDLE;
	 beat_counter   <= 2'h0;
	 req_start      <= 0;
      end
   end

endmodule // mr_cpu_mic
