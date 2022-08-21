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

`include "cache_defs.vh"

`define CLK   100
`define CLK_P (`CLK/2)

`define MEMSIZEL2       20 // 1MB

module top();

   wire [31:0]          inst;
   reg 			clk;
   reg 			reset;

   wire [15:0] 		random;

   // Memory storage & simple IO for external memory interface.
   // Make this much bigger than the cache, to demonstrate it properly.
   // Also, implements random stalls!

   reg [63:0]           memory [(1 << (`MEMSIZEL2 - 3))-1:0];

   reg [63:0]           reg_A;
   reg [63:0]           reg_B;
   reg [63:0]           reg_C;
   reg [63:0]           reg_D;

   wire [63:0] 		emi_read_data;
   reg [63:0] 		emi_mem_read_data;
   reg [63:0] 		emi_reg_read_data;
   wire [63:0] 		emi_write_data;
   wire 		emi_req; // Valid request or write data
   wire 		emi_valid;
   reg 			emi_valid_r;
   wire 		memory_stall = random[7];
   wire 		emi_rnw;
   wire [7:0]		emi_bws;
   wire [1:0]		emi_size; // Only interesting if it's 2'b11, i.e. CL (and bws ignored)
   wire [31:0] 		emi_address;
   reg 			emi_first;
   reg [`MEMSIZEL2-1:3] emi_addr_r;
   wire [`MEMSIZEL2-1:3] ram_daddr = emi_first ? emi_address[`MEMSIZEL2-1:3] : emi_addr_r;

   wire 		ram_select = !emi_address[`MEMSIZEL2];
   wire 		reg_select = emi_address[`MEMSIZEL2];

   assign emi_read_data = ram_select ? emi_mem_read_data : emi_reg_read_data;

   // FIXME size=11 address incrementer:
   // The requester just gives the initial address and the beat count is
   // ignored thereafter.  This enables a pipelined read to stream data
   // in.  Otherwise the requester is waiting for the ack on data and
   // can't change address until that arrives, costing a cycle round trip.
   //
   always @(posedge clk) begin
      if (reset) begin
	 emi_first <= 1;
	 emi_addr_r <= 0;
	 emi_valid_r <= 1;
      end else begin
	 if (!memory_stall) begin
	    if (emi_req) begin
	       if (emi_first) begin
		  emi_addr_r <= emi_address[`MEMSIZEL2-1:3] + 1;
		  emi_first <= 0;

	       end else begin
		  // For multiple beats, increment addr for next access.
		  emi_addr_r <= emi_addr_r + 1;
	       end

	       if (emi_rnw) begin
		  if (ram_select) begin
		     emi_mem_read_data <= memory[ram_daddr];
		  end else if (reg_select) begin
		     // Reg read
		     case (emi_address[4:3])
		       2'b00:
			 emi_reg_read_data <= reg_A;
		       2'b01:
			 emi_reg_read_data <= reg_B;
		       2'b10:
			 emi_reg_read_data <= reg_C;
		       2'b11:
			 emi_reg_read_data <= reg_D;
		     endcase
		  end // if (reg_select)

		  // Data valid is delayed 1 cycle, just like the data
		  // itself:
		  emi_valid_r <= 1;

	       end else begin // Write
		  if (ram_select) begin
		     // Data write, with byte strobes:
		     if (emi_bws[0])
		       memory[ram_daddr][7:0] <= emi_write_data[7:0];
		     if (emi_bws[1])
		       memory[ram_daddr][15:8] <= emi_write_data[15:8];
		     if (emi_bws[2])
		       memory[ram_daddr][23:16] <= emi_write_data[23:16];
		     if (emi_bws[3])
		       memory[ram_daddr][31:24] <= emi_write_data[31:24];
		     if (emi_bws[4])
		       memory[ram_daddr][39:32] <= emi_write_data[39:32];
		     if (emi_bws[5])
		       memory[ram_daddr][47:40] <= emi_write_data[47:40];
		     if (emi_bws[6])
		       memory[ram_daddr][55:48] <= emi_write_data[55:48];
		     if (emi_bws[7])
		       memory[ram_daddr][63:56] <= emi_write_data[63:56];

		  end else if (reg_select) begin // if (ram_select)
		     // Reg write
		     case (emi_address[4:3])
		       2'b00: begin
			  if (emi_bws[0]) reg_A[7:0] <= emi_write_data[7:0];
			  if (emi_bws[1]) reg_A[15:8] <= emi_write_data[15:8];
			  if (emi_bws[2]) reg_A[23:16] <= emi_write_data[23:16];
			  if (emi_bws[3]) reg_A[31:24] <= emi_write_data[31:24];
			  if (emi_bws[4]) reg_A[39:32] <= emi_write_data[39:32];
			  if (emi_bws[5]) reg_A[47:40] <= emi_write_data[47:40];
			  if (emi_bws[6]) reg_A[55:48] <= emi_write_data[55:48];
			  if (emi_bws[7]) reg_A[63:56] <= emi_write_data[63:56];
		       end
		       2'b01: begin
			  if (emi_bws[0]) reg_B[7:0] <= emi_write_data[7:0];
			  if (emi_bws[1]) reg_B[15:8] <= emi_write_data[15:8];
			  if (emi_bws[2]) reg_B[23:16] <= emi_write_data[23:16];
			  if (emi_bws[3]) reg_B[31:24] <= emi_write_data[31:24];
			  if (emi_bws[4]) reg_B[39:32] <= emi_write_data[39:32];
			  if (emi_bws[5]) reg_B[47:40] <= emi_write_data[47:40];
			  if (emi_bws[6]) reg_B[55:48] <= emi_write_data[55:48];
			  if (emi_bws[7]) reg_B[63:56] <= emi_write_data[63:56];
		       end
		       2'b10: begin
			  if (emi_bws[0]) reg_C[7:0] <= emi_write_data[7:0];
			  if (emi_bws[1]) reg_C[15:8] <= emi_write_data[15:8];
			  if (emi_bws[2]) reg_C[23:16] <= emi_write_data[23:16];
			  if (emi_bws[3]) reg_C[31:24] <= emi_write_data[31:24];
			  if (emi_bws[4]) reg_C[39:32] <= emi_write_data[39:32];
			  if (emi_bws[5]) reg_C[47:40] <= emi_write_data[47:40];
			  if (emi_bws[6]) reg_C[55:48] <= emi_write_data[55:48];
			  if (emi_bws[7]) reg_C[63:56] <= emi_write_data[63:56];
		       end
		       2'b11: begin
			  if (emi_bws[0]) reg_D[7:0] <= emi_write_data[7:0];
			  if (emi_bws[1]) reg_D[15:8] <= emi_write_data[15:8];
			  if (emi_bws[2]) reg_D[23:16] <= emi_write_data[23:16];
			  if (emi_bws[3]) reg_D[31:24] <= emi_write_data[31:24];
			  if (emi_bws[4]) reg_D[39:32] <= emi_write_data[39:32];
			  if (emi_bws[5]) reg_D[47:40] <= emi_write_data[47:40];
			  if (emi_bws[6]) reg_D[55:48] <= emi_write_data[55:48];
			  if (emi_bws[7]) reg_D[63:56] <= emi_write_data[63:56];
		       end
		     endcase
		  end // if (reg_select)

		  // For writes, valid means previous edge captured the data
		  // This happens via req && !RnW && !stall below

	       end // else: !if(emi_rnw)
	    end // if (emi_req)
	 end else begin // if (!memory_stall)
	    emi_valid_r <= 0;
	 end

	 if (!emi_req) begin
	    // A cycle between requests is required
	    emi_first <= 1;
	    emi_valid_r <= 0;
	 end
      end // else: !if(reset)
   end
   assign emi_valid = emi_req && ((emi_rnw && emi_valid_r) ||
				  (!emi_rnw && !memory_stall)) ;

   rng #(.S(16'hcafe)) RNG(.clk(clk),
			   .reset(reset),
			   .rng_o(random)
			   );

   ////////////////////////////////////////////////////////////////////////////////
   // DUT

   reg [31:0]           address;
   reg [1:0] 		size;
   reg 			enable;
   reg [3:0] 		request_type;
   wire 		stall;
   wire 		valid;
   reg [31:0] 		wdata;
   wire [31:0] 		rdata;

// Mirroring what's going on inside CACHE:
`define CACHE_SETS 128 // 16KB/4 ways/32B lines
`define TAG_ADDR_SIZE (32-(14-2)) // 32bits - (16KB - 4) ways
`define TAG_ADDR_START 2
`define TAG_V 0
`define TAG_D 1
`define TAG_SIZE (`TAG_ADDR_SIZE + 2)

   cache CACHE(.clk(clk),
	       .reset(reset),

	       .address(address),
	       .size(size),
	       .enable(enable),
	       .request_type(request_type),
	       .stall(stall),
	       .valid(valid),
	       .wdata(wdata),
	       .rdata(rdata),

	       .emi_if_address(emi_address),
	       .emi_if_rdata(emi_read_data),
	       .emi_if_wdata(emi_write_data),
	       .emi_if_size(emi_size),
	       .emi_if_RnW(emi_rnw),
	       .emi_if_bws(emi_bws),
	       .emi_if_req(emi_req),
	       .emi_if_valid(emi_valid)
	       );


   ////////////////////////////////////////////////////////////////////////////////
   always #`CLK_P clk <= ~clk;


   reg [31:0] i;

   initial
     begin
	$dumpfile("tb_cache.vcd");
	$dumpvars(0, top);

	clk <= 0;
	reset <= 1;

	reg_A <= 64'h01234567abcd0ede;
	reg_B <= 64'h0011223344556677;
	reg_C <= 64'h8899aabbccddeeff;
	reg_D <= 64'hfeedfacebeefcace;

	emi_mem_read_data <= 64'h0;
	emi_reg_read_data <= 64'h0;

	address <= 32'h0;
	request_type <= `C_REQ_UC_READ;
	size <= 2'b10; // 32
	enable <= 0;
	wdata <= 32'h0;


	/* Initialise test memory */
	for (i = 0; i < (1 << (`MEMSIZEL2-3)); i = i + 1) begin
	   memory[i] = {magic_number((i*2)+1), magic_number(i*2)};
	end

	#`CLK_P;
	#`CLK;

	dump_mem_and_regs();

	reset <= 0;

	// All the changes/checks in the TB occur at the falling edge.
	@(negedge clk);

	//////////////////////////////////////////////////////////////////////

	#(`CLK*5);
	$display(" ****************************** Test 1:  Uncached reads");
	//  Read a couple of addresses, test against known RAM contents:
	size = 2'b10; // 32
	request_type = `C_REQ_UC_READ; // Or write, modified in tasks

	read_and_test32(32'h30, bswap32(memory[(32'h30 >> 3)][31:0]));
	read_and_test32(32'h68, bswap32(memory[(32'h68 >> 3)][31:0]));
	read_and_test32(32'h184, bswap32(memory[(32'h184 >> 3)][63:32]));
	read_and_test32(32'h110, bswap32(memory[(32'h110 >> 3)][31:0]));
	read_and_test32(32'h180, bswap32(memory[(32'h180 >> 3)][31:0]));

	#(`CLK*5);
	$display(" ****************************** Test 2:  Uncached reads of registers");
	size = 2'b10; // 32
	request_type = `C_REQ_UC_READ;

	read_and_test32(32'h100000, bswap32(reg_A[31:0]));
	size = 2'b01; // 16
	read_and_test32(32'h100000, bswap16(reg_A[15:0]));
	read_and_test32(32'h100002, bswap16(reg_A[31:16]));

	size = 2'b00; // 8
	read_and_test32(32'h100000, reg_A[7:0]);
	read_and_test32(32'h100001, reg_A[15:8]);
	read_and_test32(32'h100002, reg_A[23:16]);
	read_and_test32(32'h100003, reg_A[31:24]);
	read_and_test32(32'h100004, reg_A[39:32]);
	read_and_test32(32'h100005, reg_A[47:40]);
	read_and_test32(32'h100006, reg_A[55:48]);
	read_and_test32(32'h100007, reg_A[63:56]);

	size = 2'b01; // 16
	read_and_test32(32'h10001a, bswap16(reg_D[31:16]));
	read_and_test32(32'h10000c, bswap16(reg_B[47:32]));
	read_and_test32(32'h10001e, bswap16(reg_D[63:48]));

	#(`CLK*5);
	$display(" ****************************** Test 3:  Uncached writes of registers");
	size = 2'b10; // 32
	write(32'h100010, bswap32(32'hcafebabe));
	read_and_test32(32'h100010, bswap32(32'hcafebabe));


	#(`CLK*5);
	$display(" ****************************** Test 4:  Cached reads"); // Exciting!
	request_type = `C_REQ_C_READ;
	size = 2'b10; // 32

	read_and_test32(32'h0, bswap32(memory[(32'h0 >> 3)][31:0])); // Set 0, CL0, miss
	read_and_test32(32'h20, bswap32(memory[(32'h20 >> 3)][31:0])); // Set 1, CL0, miss
	read_and_test32(32'h44, bswap32(memory[(32'h44 >> 3)][63:32])); // Set 2, CL0, miss
	read_and_test32(32'h100, bswap32(memory[(32'h100 >> 3)][31:0])); // Set 1, CL1, different set miss

	// Now some hopefully-hitting items!
	#`CLK;
	read_and_test32(32'h0c, bswap32(memory[(32'hc >> 3)][63:32])); // Set 0, CL0, hit

	// Now, arrange some conflicts
	read_and_test32(32'h1000, bswap32(memory[(32'h1000 >> 3)][31:0])); // Set 0, CL2, different set miss
	read_and_test32(32'h2000, bswap32(memory[(32'h2000 >> 3)][31:0])); // Set 0, CL3, different set miss
	read_and_test32(32'h3000, bswap32(memory[(32'h3000 >> 3)][31:0])); // Set 0, CLx?, different set miss
	read_and_test32(32'h4000, bswap32(memory[(32'h4000 >> 3)][31:0])); // Set 0, CLx?, different set miss

	// Previous accesses push out existing lines.  These then hit on the new lines:
	read_and_test32(32'h1010, bswap32(memory[(32'h1010 >> 3)][31:0]));
	read_and_test32(32'h2008, bswap32(memory[(32'h2008 >> 3)][31:0]));

	size = 2'b00; // 8
	read_and_test32(32'h200a, memory[(32'h2009 >> 3)][23:16]);


	#`CLK;
	size = 2'b10; // 32
	$display(" ****************************** Test 5:  Cached writes");

	// Write an address that hits:
	write(32'h2008, bswap32(32'hfeedca75));
	read_and_test32(32'h2008, bswap32(32'hfeedca75));
	request_type = `C_REQ_UC_READ;
	// Do an uncached read of same address and check for old value
	// (assumes not spontaneously written back, assumes WB not WT!)
	read_and_test32(32'h2008, bswap32(memory[(32'h2008 >> 3)][31:0]));

	request_type = `C_REQ_C_READ;
	// Write an address that misses:
	write(32'h2048, bswap32(32'h70adface));
	read_and_test32(32'h2048, bswap32(32'h70adface));

	#`CLK;
	// Cause an evict on write by writing a number of other addresses in the same set:
	write(32'h3040, bswap32(32'hca75d065));
	write(32'h4044, bswap32(32'hc00ccace));
	write(32'h5040, bswap32(32'hcafebee7));
	write(32'h6044, bswap32(32'hacdc7007));

	#`CLK;
	// Do several reads to cast out the writes, above, and check (uncached) memory is
	// correct:
	read_and_test32(32'h10040, bswap32(memory[(32'h10040 >> 3)][31:0]));
	read_and_test32(32'h20040, bswap32(memory[(32'h20040 >> 3)][31:0]));
	read_and_test32(32'h30040, bswap32(memory[(32'h30040 >> 3)][31:0]));
	read_and_test32(32'h40040, bswap32(memory[(32'h40040 >> 3)][31:0]));
	read_and_test32(32'h50040, bswap32(memory[(32'h50040 >> 3)][31:0]));
	read_and_test32(32'h60040, bswap32(memory[(32'h60040 >> 3)][31:0]));
	read_and_test32(32'h70040, bswap32(memory[(32'h70040 >> 3)][31:0]));
	read_and_test32(32'h80040, bswap32(memory[(32'h80040 >> 3)][31:0]));

	// FIXME: Though writeback on read-miss is interesting to test, the above
	// does not guarantee those dirty lines were written back.  Need
	// to use a clean/clean-invalidate CMO.

	request_type = `C_REQ_UC_READ;

	read_and_test32(32'h2048, bswap32(32'h70adface));
	read_and_test32(32'h3040, bswap32(32'hca75d065));
	read_and_test32(32'h4044, bswap32(32'hc00ccace));
	read_and_test32(32'h5040, bswap32(32'hcafebee7));
	read_and_test32(32'h6044, bswap32(32'hacdc7007));

	// And get it in again.  (Will evict something else.)
	request_type = `C_REQ_C_READ;
	read_and_test32(32'h2008, bswap32(32'hfeedca75));

	#`CLK;
	size = 2'b01; // 16
	request_type = `C_REQ_C_READ;
	$display(" ****************************** Test 6:  16-bit cached writes");

	// Test back to back writes
	write(32'h2002, bswap16(16'hfee7));
	write(32'h2004, bswap16(16'hcace));
	write(32'h3006, bswap16(16'hc0ce));
	write(32'h3008, bswap16(16'hdeed));
	write(32'h400a, bswap16(16'h55aa));
	write(32'h400c, bswap16(16'habba));
	write(32'h400e, bswap16(16'hfece));
	write(32'h4010, bswap16(16'hbedd));
	write(32'h4012, bswap16(16'hbacc));
	write(32'h4014, bswap16(16'hdaff));
	write(32'h4018, bswap16(16'hfadd));
	write(32'h401a, bswap16(16'hcacc));
	write(32'h401c, bswap16(16'haaca));
	write(32'h401e, bswap16(16'hdaca));

	// Test back to back reads
	read_and_test32(32'h2002, bswap16(16'hfee7));
	read_and_test32(32'h2004, bswap16(16'hcace));
	read_and_test32(32'h3006, bswap16(16'hc0ce));
	read_and_test32(32'h3008, bswap16(16'hdeed));
	read_and_test32(32'h400a, bswap16(16'h55aa));
	read_and_test32(32'h400c, bswap16(16'habba));
	read_and_test32(32'h400e, bswap16(16'hfece));
	read_and_test32(32'h4010, bswap16(16'hbedd));
	read_and_test32(32'h4012, bswap16(16'hbacc));
	read_and_test32(32'h4014, bswap16(16'hdaff));
	read_and_test32(32'h4018, bswap16(16'hfadd));
	read_and_test32(32'h401a, bswap16(16'hcacc));
	read_and_test32(32'h401c, bswap16(16'haaca));
	read_and_test32(32'h401e, bswap16(16'hdaca));

	#`CLK;
	size = 2'b00; // 8
	$display(" ****************************** Test 7:  8-bit cached writes");

	for (i = 0; i < 64; i = i + 1) begin
	   write(32'h2000 + i, 8'haa ^ i);
	end
	for (i = 0; i < 64; i = i + 1) begin
	   read_and_test32(32'h2000 + i, 8'haa ^ i);
	end

	#`CLK;
	size = 2'b10; // 32
	request_type = `C_REQ_C_READ;
	$display(" ****************************** Test 8:  Enormous streaming write then read");

	for (i = 0; i < (17*1024/4); i = i + 1) begin
	   write(4*i, ~magic_number(i));
	end
	for (i = 0; i < (17*1024/4); i = i + 1) begin
	   read_and_test32(4*i, ~magic_number(i));
	end

	for (i = 0; i < (17*1024/4); i = i + 1) begin
	   read_and_test32(4*i, ~magic_number(i));
	end


	#`CLK;
	size = 2'b10; // 32
	request_type = `C_REQ_C_READ;
	$display(" ****************************** Test 9:  Cache clean");
	// Write cacheable, observe mem not up to date, clean, observe mem up to date:

	write(32'h1000, bswap32(32'h12345678));
	request_type = `C_REQ_UC_READ;
	// Do an uncached read of same address and check for old value (assume not written back!)
	read_and_test32(32'h1000, bswap32(memory[(32'h1000 >> 3)][31:0]));

	// Do the clean:
	do_request(32'h1003, `C_REQ_CLEAN);

	// Now check memory's the same:
	request_type = `C_REQ_UC_READ;
	// Do an uncached read of same address and check for new value
	read_and_test32(32'h1000, bswap32(32'h12345678));

	// Finally, change memory then do a cached read -- test that the line is still cached:
	request_type = `C_REQ_UC_WRITE;
	write(32'h1000, bswap32(32'h01010202));

	request_type = `C_REQ_C_READ;
	// Cached read - new value:
	read_and_test32(32'h1000, bswap32(32'h12345678));


	#`CLK;
	size = 2'b10; // 32
	request_type = `C_REQ_C_READ;
	$display(" ****************************** Test 10:  Cache clean/invalidate");
	// Write cacheable, observe mem not up to date, clean, observe mem up to date, change mem, read:

	// Extends the Clean test method
	write(32'h2008, bswap32(32'habcdef12));
	request_type = `C_REQ_UC_READ;
	read_and_test32(32'h2008, bswap32(memory[(32'h2008 >> 3)][31:0]));

	// Do the clean/inv:
	do_request(32'h200a, `C_REQ_CLEAN_INV);

	request_type = `C_REQ_UC_READ;
	read_and_test32(32'h2008, bswap32(32'habcdef12));

	// Finally, change memory then do a cached read -- test that the line is NOT cached:
	request_type = `C_REQ_UC_WRITE;
	write(32'h2008, bswap32(32'h09080706));

	request_type = `C_REQ_C_READ;
	// Cached read - this should fetch from memory (i.e. miss) & get new value:
	read_and_test32(32'h2008, bswap32(32'h09080706));


	#`CLK;
	size = 2'b10; // 32
	request_type = `C_REQ_C_READ;
	$display(" ****************************** Test 11:  Cache invalidate");
	// Write/Read cacheable, change mem, invalidate, read cacheable (see new value)

	// Cache a written value
	write(32'h300c, bswap32(32'h0a0b0c0d));

	// Change memory
	request_type = `C_REQ_UC_WRITE;
	write(32'h300c, bswap32(32'hf00dface));

	// See the originally-written value from cache:
	request_type = `C_REQ_C_READ;
	read_and_test32(32'h300c, bswap32(32'h0a0b0c0d));

	// Do the inv:
	do_request(32'h300c, `C_REQ_INV);

	// See the changed memory value:
	request_type = `C_REQ_C_READ;
	read_and_test32(32'h300c, bswap32(32'hf00dface));


	#`CLK;
	size = 2'b10; // 32
	request_type = `C_REQ_C_READ;
	$display(" ****************************** Test 12:  Cache block zero (hit)");
	// Write/Read cacheable, DCBZ, read cacheable (see zero), clean, read UC mem zero

	// Make memory non-zero!
	memory[(32'h4020 >> 3)] = 64'hffffffffffffffff;
	memory[(32'h4028 >> 3)] = 64'hffffffffffffffff;
	memory[(32'h4030 >> 3)] = 64'hffffffffffffffff;
	memory[(32'h4038 >> 3)] = 64'hffffffffffffffff;

	// Cache a line of written values
	request_type = `C_REQ_C_WRITE;
	write(32'h4020, bswap32(32'h1a2b3c4d));
	write(32'h4024, bswap32(32'h11111111));
	write(32'h4028, bswap32(32'h22222222));
	write(32'h402c, bswap32(32'h30303030));
	write(32'h4030, bswap32(32'h4a4a4a4a));
	write(32'h4034, bswap32(32'h50505050));
	write(32'h4038, bswap32(32'h66666666));
	write(32'h403c, bswap32(32'h07070707));

	// Do the zero:
	do_request(32'h4024, `C_REQ_ZERO);

	// Test for zeroes from cache:
	request_type = `C_REQ_C_READ;
	read_and_test32(32'h403c, 32'h0);
	read_and_test32(32'h4038, 32'h0);
	read_and_test32(32'h4034, 32'h0);
	read_and_test32(32'h4030, 32'h0);
	read_and_test32(32'h4020, 32'h0);
	read_and_test32(32'h4024, 32'h0);
	read_and_test32(32'h4028, 32'h0);
	read_and_test32(32'h402c, 32'h0);

	// OK, now clean then check memory's updated:
	do_request(32'h4028, `C_REQ_CLEAN);

	// See the changed memory value:
	request_type = `C_REQ_UC_READ;
	read_and_test32(32'h403c, 32'h0);
	read_and_test32(32'h4038, 32'h0);
	read_and_test32(32'h4034, 32'h0);
	read_and_test32(32'h4030, 32'h0);
	read_and_test32(32'h4020, 32'h0);
	read_and_test32(32'h4024, 32'h0);
	read_and_test32(32'h4028, 32'h0);
	read_and_test32(32'h402c, 32'h0);


	#`CLK;
	size = 2'b10; // 32
	request_type = `C_REQ_C_READ;
	$display(" ****************************** Test 13:  Cache block zero (miss)");
	// Invalidate, DCBZ, read cacheable (see zero), clean, read UC mem zero

	// Make memory non-zero!
	memory[(32'h5040 >> 3)] = 64'hffffffffffffffff;
	memory[(32'h5048 >> 3)] = 64'hffffffffffffffff;
	memory[(32'h5050 >> 3)] = 64'hffffffffffffffff;
	memory[(32'h5058 >> 3)] = 64'hffffffffffffffff;

	do_request(32'h5040, `C_REQ_INV);

	// Do the zero:
	do_request(32'h5040, `C_REQ_ZERO);

	// Test for zeroes from cache:
	request_type = `C_REQ_C_READ;
	read_and_test32(32'h505c, 32'h0);
	read_and_test32(32'h5058, 32'h0);
	read_and_test32(32'h5054, 32'h0);
	read_and_test32(32'h5050, 32'h0);
	read_and_test32(32'h5040, 32'h0);
	read_and_test32(32'h5044, 32'h0);
	read_and_test32(32'h5048, 32'h0);
	read_and_test32(32'h504c, 32'h0);

	// OK, now clean then check memory's updated:
	do_request(32'h5050, `C_REQ_CLEAN);

	// See the changed memory value:
	request_type = `C_REQ_UC_READ;
	read_and_test32(32'h5040, 32'h0);
	read_and_test32(32'h5044, 32'h0);
	read_and_test32(32'h5048, 32'h0);
	read_and_test32(32'h504c, 32'h0);
	read_and_test32(32'h5050, 32'h0);
	read_and_test32(32'h5054, 32'h0);
	read_and_test32(32'h5058, 32'h0);
	read_and_test32(32'h505c, 32'h0);


	#`CLK;
	size = 2'b10; // 32
	request_type = `C_REQ_C_READ;
	$display(" ****************************** Test 14: Invalidate all");

	// Hmmm.  Loop writing just one way's worth of stuff (guaranteeing no spill),
	// then inv-all, then clean all addresses, then check memory's unchanged?  Hmmmm...

	request_type = `C_REQ_C_WRITE;
	for (i = 0; i < 32'h1000; i = i + 4) begin
	   write(i, bswap32(32'hdeadbeef + i));
	end

	for (i = 0; i < 32'h1000; i = i + 8) begin
	   memory[i >> 3] = 64'h0;
	end

	// Read back, it's in cache
	request_type = `C_REQ_C_READ;
	for (i = 0; i < 32'h1000; i = i + 4) begin
	   read_and_test32(i, bswap32(32'hdeadbeef + i));
	end
	// Assume no writeback yet!

        // Invalidate all
        for (i = 0; i < 128; i = i + 1) begin
	   do_request(i * 32, `C_REQ_INV_SET);
        end

	// Cached read of the range -- should reflect memory!
	request_type = `C_REQ_C_READ;
	for (i = 0; i < 32'h1000; i = i + 4) begin
	   read_and_test32(i, 0);
	end
	// Done


	#`CLK;
	$display(" ****************************** Test 14: C, CI, I ops that miss");
	// Now that the cache is mostly-clean, try ops that miss.  They should be NOP.
	// The pass rate here is "don't deadlock"...
	do_request(32'h8123, `C_REQ_CLEAN);
	do_request(32'h9876, `C_REQ_CLEAN_INV);
	do_request(32'ha0a0, `C_REQ_INV);


	#(`CLK*5);

	dump_mem_and_regs();
	dump_tags();

	$display("PASS");

	$finish(0);
     end

   // For initialising memory to something crazy:
   function [31:0] magic_number;
      input [31:0] addr;
      begin
	 magic_number = {addr[10:1], addr[11:2], addr[9:0]} ^
			{{addr[9:1], addr[17:9], addr[26:18]}, 1'b0} ^
			{{addr[3:0], addr[3:0], addr[31:28]}, 4'h1};
	 // $display("addr %x magic %x", addr, magic_number);
      end
   endfunction // magic_number

   function [31:0] bswap32;
      input [31:0] value;
      begin
	 bswap32 = {value[7:0], value[15:8], value[23:16], value[31:24]};
      end
   endfunction

   function [15:0] bswap16;
      input [15:0] value;
      begin
	 bswap16 = {value[7:0], value[15:8]};
      end
   endfunction

   // Data is valid the cycle after the first cycle that doesn't stall.
   // Got that?
   //
   task read_and_test32;
      input [31:0] addressp;
      input [31:0] value;

      reg [9:0]    timeout;
      reg [31:0]   match;
      reg 	   stalled;
      begin
	 timeout = 10'h3ff;
	 match = value;

	 // At -ve edge of cycle 0, set up inputs for +ve edge
	 #1;
	 request_type[0] = 0; // Whether UC or C, bit 0 is 0 for read, 1 for write
	 address = addressp;
	 enable = 1;
	 stalled = 0;

	 // Check stall after the first +edge, because stall
	 // might be low in the same cycle in which we make a new
	 // request.
	 do begin
	    @(posedge clk);
	    if (stall || !valid) begin
	       stalled = 1;
	       timeout = timeout - 1;
	       if (timeout == 0) begin
		  $fatal(1, "FAIL: Timed out");
	       end
	    end
	 end while (stall || !valid);

	 // If there was no stall at all, we're at pos edge of cycle 1,
	 // and data is ready in the coming cycle.
	 // If we stalled, then we just had a positive edge w/o stall,
	 // and data is ready.

//	 @(negedge clk);
	 #1;
	 $display("Read addr %x, data %x", address, rdata);

	 if (rdata !== match) begin
	    $fatal(1, "FAIL: Read %x != %x, addr %x", rdata, match, address);
	 end

	 #1;
	 enable = 0;
      end
   endtask // read_and_test32

   task write;
      input [31:0] addressp;
      input [31:0] value;

      reg [9:0]    timeout;

      begin
	 timeout = 10'h3ff;

	 #1;
	 request_type[0] = 1; // Whether UC or C, bit 0 is 0 for read, 1 for write
	 wdata = value;
	 address = addressp;
	 enable = 1;

	 do begin
	    @(posedge clk);
	    if (stall || !valid) begin
	       timeout = timeout - 1;
	       if (timeout == 0) begin
		  $fatal(1, "FAIL: Timed out");
	       end
	    end
	 end while (stall || !valid);

	 $display("Write addr %x, data %x", address, value);

//	 @(negedge clk);
	 #1;
	 enable = 0;
      end
   endtask // write

   task do_request;
      input [31:0] addressp;
      input [31:0] req;

      reg [9:0]    timeout;

      begin
	 timeout = 10'h3ff;

	 #1;
	 request_type = req;
	 address = addressp;
	 enable = 1;

	 do begin
	    @(posedge clk);
	    if (stall || !valid) begin
	       timeout = timeout - 1;
	       if (timeout == 0) begin
		  $fatal(1, "FAIL: Timed out");
	       end
	    end
	 end while (stall || !valid);

	 $display("Request %x", request_type);

	 #1;
	 enable = 0;
      end
   endtask // write



   task dump_mem_and_regs;
      reg [31:0] i;
      begin
	for (i = 0; i < 64; i = i + 1) begin
	   $display("mem[%d] = %x", i, memory[i]);
	end
	 $display("reg_A = %x", reg_A);
	 $display("reg_B = %x", reg_B);
	 $display("reg_C = %x", reg_C);
	 $display("reg_D = %x", reg_D);
      end
   endtask // dump_mem_and_regs

   task dump_tags;
      reg [31:0] i;
      begin
	 // FIXME:  Assumes 4-way
	 for (i = 0; i < `CACHE_SETS; i = i + 1) begin
	    $display("%03d:   [%08x %s %s]  [%08x %s %s]  [%08x %s %s]  [%08x %s %s]",
		     i,
		     {CACHE.tag_mem[i][ 0*(`TAG_SIZE) + `TAG_ADDR_START + `TAG_ADDR_SIZE - 1 : (0*`TAG_SIZE) + `TAG_ADDR_START ],
		      i[6:0], 5'h00},
		     CACHE.tag_mem[i][ (0*`TAG_SIZE) + `TAG_D] ? "D" : " ",
		     CACHE.tag_mem[i][ (0*`TAG_SIZE) + `TAG_V] ? "V" : " ",
		     {CACHE.tag_mem[i][ 1*(`TAG_SIZE) + `TAG_ADDR_START + `TAG_ADDR_SIZE - 1 : (1*`TAG_SIZE) + `TAG_ADDR_START ],
		      i[6:0], 5'h00},
		     CACHE.tag_mem[i][ (1*`TAG_SIZE) + `TAG_D] ? "D" : " ",
		     CACHE.tag_mem[i][ (1*`TAG_SIZE) + `TAG_V] ? "V" : " ",
		     {CACHE.tag_mem[i][ 2*(`TAG_SIZE) + `TAG_ADDR_START + `TAG_ADDR_SIZE - 1 : (2*`TAG_SIZE) + `TAG_ADDR_START ],
		      i[6:0], 5'h00},
		     CACHE.tag_mem[i][ (2*`TAG_SIZE) + `TAG_D] ? "D" : " ",
		     CACHE.tag_mem[i][ (2*`TAG_SIZE) + `TAG_V] ? "V" : " ",
		     {CACHE.tag_mem[i][ 3*(`TAG_SIZE) + `TAG_ADDR_START + `TAG_ADDR_SIZE - 1 : (3*`TAG_SIZE) + `TAG_ADDR_START ],
		      i[6:0], 5'h00},
		     CACHE.tag_mem[i][ (3*`TAG_SIZE) + `TAG_D] ? "D" : " ",
		     CACHE.tag_mem[i][ (3*`TAG_SIZE) + `TAG_V] ? "V" : " ",
		     );
	 end
      end
   endtask

endmodule
