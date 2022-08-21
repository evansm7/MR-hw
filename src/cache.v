/* cache
 *
 * Interface usage:
 * 'enable' asserted in a cycle causes an operation to begin.  If stall=0 by
 * the next clock edge, then that edge has performed the requested read/write
 * (data present after clock edge).
 *
 * Size is parameterisable.  Ways is sorta-parameterisable (needs work to make
 * this actually flexible).  (FIXME: Only supports 4-way, currently.)
 *
 * Interface:
 * Provide address, properties, data.
 * Outputs include valid/stall, which operate as follows:
 * In a given request cycle:
 * - valid=1/stall=0: A hit (or uncached access), write data will be accepted or read data valid at next _| clk
 * - valid=0/stall=0: A miss, the next cycle will have stall=1.
 * - valid=0/stall=1: A stall cycle.  Must keep enable/address/data stable w.r.t. previous cycle until stall=0 after this!
 *
 * If you cannot change enable/address/data when stall=1, that implies you're
 * free to do this when stall=0.  For uncached accesses, stall will go
 * immediately high for as many cycles as it takes to consume a write or perform
 * a read, then gives one cycle with stall=0 and valid=1.  If you change the
 * inputs (e.g. address) in this cycle, then note the write or read you
 * previously requested may have been performed.  This is typically not a useful
 * thing to do for data caches, but an instruction cache may need to change its
 * mind on any non-stall cycle.
 *
 * ME 5/4/2020
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

`include "cache_defs.vh"

`define CL_L2SIZE 5
`define CL_SIZE   (1 << `CL_L2SIZE)

// Start bits of field in the tag; assumes flags are at the bottom!
`define TAG_V     0
`define TAG_D     1
`define TAG_ADDR  2
`define TAG_BITS_INV	2'b00
`define TAG_BITS_VALID	2'b01
`define TAG_BITS_DIRTY	2'b11


module cache(input wire         clk,
	     input wire 	reset,

	     output wire [31:0] emi_if_address,
             input wire [63:0] 	emi_if_rdata,
             output wire [63:0] emi_if_wdata,
             output wire [1:0] 	emi_if_size,
             output wire 	emi_if_RnW,
             output wire [7:0] 	emi_if_bws,
             output wire 	emi_if_req,
             input wire 	emi_if_valid,

	     input wire [31:0] 	address,
	     input wire [1:0] 	size, // 00=8b, 01=16b, 10=32b

	     input wire 	enable,
	     input wire [3:0] 	request_type,
	     // 0000  UC Read
	     // 0001  UC Write
	     // 0010  C Read
	     // 0011  C Write
	     // 0100  Invalidate
	     // 0101  Clean Invalidate
	     // 0110  Clean
	     // 0111  Block zero
	     // 1000  Invalidate set

	     // If stall=1, hold all inputs stable!
	     // Don't really have a good story for aborting a transfer yet,
	     // if you drop enable during stall then you may get partial updates
	     // or conflict/corruption of next transfer.
	     output wire 	stall,
	     output wire 	valid,
	     input wire [31:0] 	wdata, // FIXME size
	     output wire [31:0] rdata,

	     // A 64-bit read port for special purposes (PTW)
	     output wire [63:0] raw_rdata
	     );

   parameter L2SIZE = 14; // 16KB
   parameter L2WAYS = 2; // 4-way

   //////////////////////////////////////////////////////////////////////////
   // Tags

   /* Tags contain:
    *
    * address[31:(L2SIZE-L2WAYS)] (below this, addr bits used to index tags or index resulting CL)
    * valid
    * dirty
    *
    */
   parameter TAG_ADDR_SIZE = 32-(L2SIZE-L2WAYS);
   parameter TAG_SIZE = TAG_ADDR_SIZE + 1 + 1;


   wire [63:0] 			      formatted_wrdata;
   wire [7:0] 			      wr_bwe;
   wire [63:0] 			      raw_rdata_cache;
   reg [1:0] 			      read_size;
   reg [2:0] 			      read_address;
   reg [63:0] 			      uc_reg; // For uncached accesses
   reg [31:0] 			      requested_address;
   reg [3:0]			      requested_request; // Ha!
   reg [1:0] 			      requested_size;
   reg [7:0] 			      emi_bwe;
   reg 				      rdata_from_uncached;
   reg 				      wdata_from_uncached;
   reg 				      use_uc_address;
   reg [31:0] 			      emi_address; // Wire

   wire [63:0] 			      data_ram_out;
   reg 				      data_ram_read_enable; // Enable read at next clock
   reg 				      data_ram_read_cond;   // Enable read at next clock if emi_if_valid
   reg 				      data_ram_write_cond;  // Enable write at next clock if emi_if_valid

   reg 				      emi_req;
   reg [1:0] 			      emi_size;
   reg 				      emi_RnW;
   reg [31:0] 			      spill_address;
   reg 				      valid_out; // Wire
   reg 				      stall_out; // Wire

   /* See below for a description of the FSM: */
   reg [3:0] 			      state;
   reg [3:0] 			      state_next; // Chain to next state
   reg [3:0] 			      burst_counter;
   /* There are two counters b/c for spill, the internal one moves on a cycle
    * ahead of the external one, to prepare read data.
    */
   reg [2:0] internal_burst_counter;

`define STATE_LOOKUP                  0
`define STATE_SPILL                   1
`define STATE_SPILL_TRANSFER          2
`define STATE_FILL                    3
`define STATE_FILL_TRANSFER           4
`define STATE_UNCACHED_R              5
`define STATE_UNCACHED_W              6
`define STATE_CONSUME                 7
`define STATE_INVALIDATE              8
`define STATE_CMO_CONSUME             9
`define STATE_FILL_ZERO               10
`define STATE_INV_SET                 11


   ///////////////////////////////////////////////////////////////////////////
   /* Tag memory/ways/hits */
   wire [L2SIZE-L2WAYS-`CL_L2SIZE-1:0] tag_index = address[L2SIZE-L2WAYS-1:`CL_L2SIZE];
   wire [TAG_SIZE-1:0] 		      tag [(1 << L2WAYS)-1:0];
   reg [(TAG_SIZE << L2WAYS)-1:0]     tags_new_value; // Wire
   wire [(TAG_SIZE << L2WAYS)-1:0]    tags_read_value;
   wire [(1 << L2WAYS)-1:0] 	      way_hit;
   reg 				      hit; // Wire
   reg [L2WAYS-1:0] 		      way_addr; // Wire, offset of way in data RAM
   reg [L2WAYS-1:0] 		      destination_way;
   reg [L2WAYS-1:0] 		      zero_way;
   reg [L2WAYS-1:0] 		      cycle_count;


   /* Address indexes tag read, down to the lowest bit not used to index a line itself (e.g. 5) */
   /* Tags live in distributed/CLB RAM, i.e. async read, sync write: */
   reg [(TAG_SIZE << L2WAYS)-1:0] tag_mem [(1 << (L2SIZE-`CL_L2SIZE-L2WAYS))-1:0];

   /* For sim, init of tags is important! */
   reg [L2SIZE-`CL_L2SIZE-L2WAYS:0] i;
   initial begin
      for (i = 0; i < (1 << (L2SIZE-`CL_L2SIZE-L2WAYS)); i = i + 1) begin
	 tag_mem[i[L2SIZE-`CL_L2SIZE-L2WAYS-1:0]] = {(TAG_SIZE << L2WAYS){1'b0}};
      end
   end

   /* Async read of tag memory (all tags in set): */
   assign tags_read_value = tag_mem[tag_index];

   genvar 			      t;
   generate
      /* Split tag set read into tag[n] (where n = way) */
      for (t = 0; t < (1 << L2WAYS); t = t + 1) begin : tagr

	 assign tag[t] = tags_read_value[ ((t+1)*TAG_SIZE)-1 : t*TAG_SIZE ];

	 assign way_hit[t] = tag[t][`TAG_V] == 1'b1 &&
			     (tag[t][`TAG_ADDR + TAG_ADDR_SIZE - 1:`TAG_ADDR] ==
			      address[31:32-TAG_ADDR_SIZE]);

      end
   endgenerate

   // Way hit to address encoder:  FIXME, parameterise this!
   always @(*) begin

      hit = enable && |way_hit[(1 << L2WAYS)-1:0];

      case (way_hit[3:0])
	4'b1000:
	  way_addr = 3;
	4'b0100:
	  way_addr = 2;
	4'b0010:
	  way_addr = 1;
	4'b0001:
	  way_addr = 0;
	default: // Assert at CLK?
	  way_addr = 0;
      endcase
   end


   /* Tag new value */
   /* FIXME: parameterise this! */
   always @(*) begin
      tags_new_value = {tag[3], tag[2], tag[1], tag[0]};

      if (state == `STATE_LOOKUP) begin
	 // On a cacheable write hit, this value is written to tag @ tag_index.
	 if (way_addr == 0) begin
	    tags_new_value[ (1*TAG_SIZE)-1 : 0*TAG_SIZE ] = tag[0] | `TAG_BITS_DIRTY;
	 end else if (way_addr == 1) begin
	    tags_new_value[ (2*TAG_SIZE)-1 : 1*TAG_SIZE ] = tag[1] | `TAG_BITS_DIRTY;
	 end else if (way_addr == 2) begin
	    tags_new_value[ (3*TAG_SIZE)-1 : 2*TAG_SIZE ] = tag[2] | `TAG_BITS_DIRTY;
	 end else if (way_addr == 3) begin
	    tags_new_value[ (4*TAG_SIZE)-1 : 3*TAG_SIZE ] = tag[3] | `TAG_BITS_DIRTY;
	 end

      end else if (state == `STATE_INVALIDATE) begin
	 // Invalidate clears V on target/hit line.  Zeroes whole tag.
	 if (way_addr == 0) begin
	    tags_new_value[ (1*TAG_SIZE)-1 : 0*TAG_SIZE ] = {TAG_SIZE{1'b0}};
	 end else if (way_addr == 1) begin
	    tags_new_value[ (2*TAG_SIZE)-1 : 1*TAG_SIZE ] = {TAG_SIZE{1'b0}};
	 end else if (way_addr == 2) begin
	    tags_new_value[ (3*TAG_SIZE)-1 : 2*TAG_SIZE ] = {TAG_SIZE{1'b0}};
	 end else if (way_addr == 3) begin
	    tags_new_value[ (4*TAG_SIZE)-1 : 3*TAG_SIZE ] = {TAG_SIZE{1'b0}};
	 end

      end else if (state == `STATE_FILL_ZERO) begin
	 // Note zero_way
	 // Zero sets V & D on target line AND updates tag addr.
	 if (zero_way == 0) begin
	    tags_new_value[ (1*TAG_SIZE)-1 : 0*TAG_SIZE ] = {address[31:32-TAG_ADDR_SIZE],
                                                             `TAG_BITS_DIRTY};
	 end else if (zero_way == 1) begin
	    tags_new_value[ (2*TAG_SIZE)-1 : 1*TAG_SIZE ] = {address[31:32-TAG_ADDR_SIZE],
                                                             `TAG_BITS_DIRTY};
	 end else if (zero_way == 2) begin
	    tags_new_value[ (3*TAG_SIZE)-1 : 2*TAG_SIZE ] = {address[31:32-TAG_ADDR_SIZE],
                                                             `TAG_BITS_DIRTY};
	 end else if (zero_way == 3) begin
	    tags_new_value[ (4*TAG_SIZE)-1 : 3*TAG_SIZE ] = {address[31:32-TAG_ADDR_SIZE],
                                                             `TAG_BITS_DIRTY};
	 end

      end else begin
	 // On a fill (STATE_FILL_TRANSFER), the appropriate tag's updated with new address+V:
	 if (destination_way == 0) begin
	    tags_new_value[ (1*TAG_SIZE)-1 : 0*TAG_SIZE ] = {address[31:32-TAG_ADDR_SIZE],
                                                             `TAG_BITS_VALID};
	 end else if (destination_way == 1) begin
	    tags_new_value[ (2*TAG_SIZE)-1 : 1*TAG_SIZE ] = {address[31:32-TAG_ADDR_SIZE],
                                                             `TAG_BITS_VALID};
	 end else if (destination_way == 2) begin
	    tags_new_value[ (3*TAG_SIZE)-1 : 2*TAG_SIZE ] = {address[31:32-TAG_ADDR_SIZE],
                                                             `TAG_BITS_VALID};
	 end else if (destination_way == 3) begin
	    tags_new_value[ (4*TAG_SIZE)-1 : 3*TAG_SIZE ] = {address[31:32-TAG_ADDR_SIZE],
                                                             `TAG_BITS_VALID};
	 end

      end
   end


   ///////////////////////////////////////////////////////////////////////////
   // Data memory, formatters

   // 32 to 64+BWE, 64 to 32 data formatters:
   datafmt3264 DFMTW(.in_data(wdata),
		     .size(size),
		     .address(address[2:0]),
		     .out_bwe(wr_bwe),
		     .out_data(formatted_wrdata)
		     );

   /* The data RAM is a simple single (albeit dual-ported) block.  All ways
    * are stored in this linear memory; the ways are concatenated and addressed
    * using way_addr as the top bits.
    *
    * The address is wholly determined by input address plus the way_addr
    * corresponding to the matching tag.  This may be slower for reads than
    * instantiating say 4 memories and doing 4x reads in parallel (filtering
    * result by tag match) but the tag output is needed before memory
    * access for writes (to determine the way to write to), so I don't think
    * that parallel approach will make a difference (and is more complex).
    *
    * The refill port write enable is based on emi_if_valid (EMI read data valid),
    * in combination with data_ram_enable which is a FF set when the RAM's
    * being filled (and otherwise cleared to protect its contents).
    */
   reg [L2SIZE-1-3:0]  ram_spill_fill_addr; // Wire
   reg 		       data_ram_en_wr; // Wire
   reg [63:0] 	       data_ram_in; // Wire
   wire 	       ram_lookup_enable;

   wire [L2SIZE-1-3:0] ram_lookup_addr = {way_addr, address[L2SIZE-L2WAYS-1:3]};
   wire 	       RnW = !(request_type == `C_REQ_C_WRITE);
   wire 	       data_ram_en_rd = data_ram_read_enable || (data_ram_read_cond && emi_if_valid);


   always @(*) begin
      // ram_spill_fill_addr:
      if (request_type == `C_REQ_CLEAN_INV ||
	  request_type == `C_REQ_CLEAN) begin
	 // A C or CI needs to spill from an existing hit
	 ram_spill_fill_addr = {way_addr, address[L2SIZE-L2WAYS-1:5], internal_burst_counter[1:0]};
      end else if (state == `STATE_FILL_ZERO) begin
	 /* Zero might affect an existing way (at way_addr) on hit, or an
	  * allocated way (destination_way) upon miss.
	  *
	  * Note this is based on state, not request, because in the initial
	  * LOOKUP cycle a RAM access needs to be initiated in the case of a
	  * spill, and that needs to come from destination_way; that falls into
	  * the case below.  Only once the spill is done we then use zero_way
	  * to locate the line being zeroed (once in STATE_FILL_ZERO).
	  */
	 ram_spill_fill_addr = {zero_way, address[L2SIZE-L2WAYS-1:5], internal_burst_counter[1:0]};
      end else begin
	 // General spill/fill accesses a victim line, at destination_way:
	 ram_spill_fill_addr = {destination_way, address[L2SIZE-L2WAYS-1:5], internal_burst_counter[1:0]};
      end


      // data_ram_en_wr and data_ram_in:
      if (state == `STATE_FILL_ZERO) begin
	 data_ram_en_wr = 1;
	 data_ram_in = 64'h0;
      end else begin
	 data_ram_en_wr = (data_ram_write_cond && emi_if_valid);
	 data_ram_in = emi_if_rdata;
      end
   end

   /* Only enable RAM on genuine reads/writes.  Because we're using
    * synchronous-read RAMs the external requester assumes we register
    * output data.  In some cases, this needs to be held even when
    * other requests are submitted (for example, an IFetch that gets stalled
    * and overlaps with a later icbi).
    */
   assign    ram_lookup_enable = (request_type == `C_REQ_C_READ ||
				  request_type == `C_REQ_C_WRITE) && hit;


   dp_ram #(.L2WIDTH(3), // 64b wide
	    .L2SIZE(L2SIZE)
	    )
          DATA_RAM(.clk(clk),
		   .reset(reset),

		   // Lookup port:
		   .a_addr(ram_lookup_addr),
		   .a_wr_data(formatted_wrdata),
		   .a_rd_data(raw_rdata_cache),
		   .a_enable(ram_lookup_enable),
		   .a_WE(!RnW),
		   .a_BWE(wr_bwe),

		   // Spill/fill port
		   .b_addr(ram_spill_fill_addr),
		   .b_wr_data(data_ram_in),
		   .b_rd_data(data_ram_out),
		   .b_enable(data_ram_en_rd || data_ram_en_wr),
		   .b_WE(1'b1),
		   .b_BWE(data_ram_en_wr ? 8'hff : 8'h00) /* See note below */
		   );

   assign raw_rdata = rdata_from_uncached ? uc_reg : raw_rdata_cache;
   datafmt6432 DFMTR(.in_data(raw_rdata),
		     .size(read_size),
		     .address(read_address),
		     .out_data(rdata)
		     );

   /* Note: XST 14.7 fails to infer a block RAM when BWE=ff and WE is the enable
    * strobe.  However, it works when WE=1 and BWE is controlled by the strobe. :(
    */

   ///////////////////////////////////////////////////////////////////////////
   // FSM/state-change logic

   /* States & transitions:
    *
    * LOOKUP:
    * - Normal state, lookup can hit in 1 cycle and stay in LOOKUP.
    *   A write updates tags to dirty.  (Whilst UP, can always write as dirty.
    *   SMP will require state changes elsewhere.)
    * - An uncached access does nothing in LOOKUP besides latching wdata into
    *   UC_REG and going to UNCACHED-W or going to UNCACHED-R.
    * - A miss chooses a victim way in this cycle, and goes to SPILL if victim
    *   was valid && dirty
    * - A miss goes to FILL if victim was/is clean or invalid
    * - A DCBZ that hits goes directly to ZERO to fill zero.
    * - A DCBZ that misses allocates; if the existing line is dirty, goes to SPILL then
    *   to ZERO.  If clean, goes directly to ZERO.
    * - A Clean goes to SPILL-CLEAN on hit (which returns back to LOOKUP, consuming the
    *   access and updating tag to Clean).  On miss (or a hit of a clean line), a NOP.
    * - An Invalidate just writes tags, consuming the access.  On miss, a NOP.
    * - A CleanInvalidate goes to SPILL-CLEANINV on hit (which returns to LOOKUP,
    *   consuming and updating tag to Invalidate).  On miss, a NOP.
    *
    * SPILL:
    * - Victim line has been selected, and it is valid & dirty.  Sub-states/counter
    *   to write N beats of line back.
    * - After writeback complete, goes to FILL
    * - SPILL-CLEAN and SPILL-CLEANINV are the same, except return to LOOKUP.
    *
    * FILL:
    * - A miss indicates address for R or W.  Sub-states/counter reads N beats to
    *   fill the line.
    * - After read is complete, goes to LOOKUP and writes tags valid && clean.
    * - LOOKUP then retries original access, which might write tags to dirty.
    *
    * UNCACHED-R:
    * - Reads one beat from EMI into UC_REG (with appropriate size)
    * - Moves to CONSUME
    *
    * UNCACHED-W:
    * - Writes one beat from UC_REG into EMU (with BWS)
    * - Moves to CONSUME
    *
    * CONSUME:
    * - Simple one-cycle state with no stall.  Shows the outside world that
    *   requested action has occurred (e.g. gives a cycle for UC data to be read).
    *
    * ZERO:
    * - Use refill port/logic to write a line of zeroes.
    * - Update tags (whilst UP, easy - can always write valid && dirty).
    * - Returns to LOOKUP (but this consumes the instruction!)
    *
    * INV_ALL:
    * - Iterates w/ counter through set indices, writing tags in each cycle,
    *   returning to LOOKUP.
    *
    * Future:  SMP/extra states.  Also invalidate-all?  Clean-all?
    * Also, a scrubbing cleaner FSM to write back dirty data when idle?
    * Prefetch?
    *
    * For all, the stall output causes external requester to hold tight, and
    * "consuming" can mean dropping the stall in the cycle transitioning back
    * to LOOKUP.
    *
    * (Some intermediate states can be optimise to shave a cycle off, but
    * KISS and get it working well before performance tuning!)
    */

   always @(posedge clk) begin
      cycle_count <= cycle_count + 1;
      if (!enable) begin
	 state <= `STATE_LOOKUP;

      end else begin
	 /* Enabled: a request is being made this cycle (or we're delaying
	  * replying to one made in an earlier cycle)
	  */
	 case (state)

	   `STATE_LOOKUP: begin
	      // First, deal with uncached case.
	      if (request_type == `C_REQ_UC_WRITE) begin         // Uncached write
		 uc_reg <= formatted_wrdata;
		 emi_bwe <= wr_bwe;
		 emi_req <= 1;
		 emi_size <= size;  // BWS shows bytes to write
		 emi_RnW <= 0;
		 wdata_from_uncached <= 1; // As opposed to Data RAM
		 use_uc_address <= 1;
		 // This cycle asserts stall.
		 // Address and size should be held by this component's stall.
		 // Capture the request to ensure it's the same next time stall=0!
		 requested_address <= address;
		 requested_request <= request_type;
		 requested_size <= size;
		 state <= `STATE_UNCACHED_W;

	      end else if (request_type == `C_REQ_UC_READ) begin // Uncached read
		 // This cycle asserts stall.
		 // Address and size should be held by this component's stall.
		 read_size <= size;
		 read_address <= address[2:0];

		 emi_req <= 1;
		 emi_size <= size;  // No distinction between 1-8 byte reads!
		 emi_RnW <= 1;
		 // Next cycle, if emi_if_valid is asserted, data is captured into uc_reg
		 // which, due to rdata_from_uncached, then generates rdata.
		 // Note this stays high into the cycle after the request,
		 // holding data into the next cycle.
		 rdata_from_uncached <= 1;
		 use_uc_address <= 1;
		 // Capture the request to ensure it's the same next time stall=0!
		 requested_address <= address;
		 requested_request <= request_type;
		 requested_size <= size;
		 state <= `STATE_UNCACHED_R;

	      end else if (request_type == `C_REQ_C_READ ||
			   request_type == `C_REQ_C_WRITE) begin
		 // Store size & address for read; these are used
		 // by the output data formatter.
		 read_size <= size;
		 read_address <= address[2:0];

		 // The tags are being checked against address w/ async read,
		 // did we hit?
		 if (hit) begin
		    if (request_type == `C_REQ_C_WRITE) begin // Cached write hit
		       // Ensure dirty (FIXME parameterise this!)
		       // tags_new_value is prepared above, based on being in STATE_LOOKUP:
		       tag_mem[tag_index] <= tags_new_value;

		    end else begin // Cached read hit
		       // Data RAM outputs data at end of cycle, which is then
		       // formatted for rdata using read_size, read_address.
		       // Make sure we output rdata from the cache RAM:
		       rdata_from_uncached <= 0;
		       // FIXME: Could update LRU counters.
		    end

		 end else begin
		    // It's a miss.  Common stuff:
		    internal_burst_counter <= 0;
		    burst_counter <= 0;
		    emi_bwe <= 8'hff;

		    // We're going to request a fill into destination_way.
		    // If the existing line is dirty with something else, spill that first:
		    if (tag[destination_way][`TAG_V] && tag[destination_way][`TAG_D]) begin
		       state <= `STATE_SPILL;
		       state_next <= `STATE_FILL;
		       spill_address <= {tag[destination_way][`TAG_ADDR + TAG_ADDR_SIZE - 1:`TAG_ADDR],
					 tag_index, {`CL_L2SIZE{1'b0}}};

		       // Prime, read the first beat:
		       data_ram_read_enable <= 1;
		       // Note the RAM address, in *this* cycle, is generated from destination_way.
		    end else begin
		       // Otherwise, it's clean or invalid, so just fill it:
                       // Hacky shortcut:  state_fill just sets up some values & wastes a cycle,
                       // so set up values here and save it!
		       // Was: state <= `STATE_FILL;
                       // Now contents of that state:
                       burst_counter <= 0;
		       internal_burst_counter <= 0;
		       emi_req <= 1;
		       emi_size <= 2'b11; // CL (4 beats)
		       emi_RnW <= 1;
		       use_uc_address <= 0;
		       // Capture EMI read data if valid:
		       data_ram_write_cond <= 1;
		       state <= `STATE_FILL_TRANSFER;
		    end
		 end

	      end else if (request_type == `C_REQ_INV) begin
		 if (hit) begin
		    /* We can do the invalidate here in 1 cycle, but it's a
		     * little less fiddly w/ duplicating tags_new_value to
		     * just do it in another state/cycle.  Plus, that's
		     * needed anyway for other CMOs.
		     */
		    state <= `STATE_INVALIDATE;
		 end
		 // If not a hit, note that valid=1 so the op is consumed this cycle.

	      end else if (request_type == `C_REQ_CLEAN_INV) begin
		 if (hit) begin
		    // If the currently-hitting line (way_addr) is dirty, spill it:
		    if (tag[way_addr][`TAG_D]) begin
		       internal_burst_counter <= 0;
		       burst_counter <= 0;
		       emi_bwe <= 8'hff;

		       state <= `STATE_SPILL;
		       state_next <= `STATE_INVALIDATE;
		       spill_address <= {tag[way_addr][`TAG_ADDR + TAG_ADDR_SIZE - 1:`TAG_ADDR],
					 tag_index, {`CL_L2SIZE{1'b0}}};

		       // Prime, read the first beat:
		       data_ram_read_enable <= 1;
		       /* Note the RAM data address is generated using way_addr
			* rather than destination_way, for this kind of request!
			*/
		    end else begin
		       // Otherwise, go directly to Invalidate
		       state <= `STATE_INVALIDATE;
		    end
		 end

	      end else if (request_type == `C_REQ_CLEAN) begin
		 if (hit) begin
		    // If the currently-hitting line (way_addr) is dirty, spill it:
		    if (tag[way_addr][`TAG_D]) begin
		       internal_burst_counter <= 0;
		       burst_counter <= 0;
		       emi_bwe <= 8'hff;

		       state <= `STATE_SPILL;
		       state_next <= `STATE_CMO_CONSUME;
		       spill_address <= {tag[way_addr][`TAG_ADDR + TAG_ADDR_SIZE - 1:`TAG_ADDR],
					 tag_index, {`CL_L2SIZE{1'b0}}};

		       // Prime, read the first beat (from way_addr)
		       data_ram_read_enable <= 1;
		    end else begin
		       /* Otherwise, nothing to do.  Go to consume the op.
			* This could be optimised, at the expense of complicating
			* the valid/stall calcs below.
			*/
		       state <= `STATE_CMO_CONSUME;
		    end
		 end

	      end else if (request_type == `C_REQ_ZERO) begin
		 /* Now this is the fun one. :)  If the requested address:
		  * - Misses entirely, then allocate (spill if dirty) then fill with zero and mark dirty.
		  * - Hits, then fill with zero and mark dirty.
		  */
		 internal_burst_counter <= 0;

		 if (hit) begin
		    state <= `STATE_FILL_ZERO;
		    // The zeroed line is the existing hitting line:
		    zero_way <= way_addr;
		 end else begin
		    // Allocate.
		    burst_counter <= 0;
		    emi_bwe <= 8'hff;

		    // Set up RAM addr for zero fill:
		    zero_way <= destination_way;

		    // If the existing line is dirty with something else, spill that first:
		    if (tag[destination_way][`TAG_V] && tag[destination_way][`TAG_D]) begin
		       state <= `STATE_SPILL;
		       state_next <= `STATE_FILL_ZERO;
		       spill_address <= {tag[destination_way][`TAG_ADDR + TAG_ADDR_SIZE - 1:`TAG_ADDR],
					 tag_index, {`CL_L2SIZE{1'b0}}};

		       // Prime, read the first beat:
		       data_ram_read_enable <= 1;
		       /* NOTE: RAM address needs to be valid in this cycle
			* & derived from destination_way!
			*/
		    end else begin
		       // Otherwise, it's clean or invalid, so just fill it:
		       state <= `STATE_FILL_ZERO;
		    end
		 end

	      end else if (request_type == `C_REQ_INV_SET) begin
		 state <= `STATE_INV_SET;
	      end
	   end


	   `STATE_UNCACHED_R: begin
	      // Asserting a request on EMI to read data.  When it arrives, capture it:
	      if (emi_if_valid) begin
		 // Capture data into uc_reg:
		 uc_reg <= emi_if_rdata;
		 emi_req <= 0;
		 state <= `STATE_CONSUME;
	      end
	   end


	   `STATE_UNCACHED_W: begin
	      // Asserting a request on EMI to write data stored in uc_reg.
	      if (emi_if_valid) begin
		 // Done, it's a one-beat write.
		 emi_req <= 0;
		 state <= `STATE_CONSUME;
	      end
	   end


	   `STATE_SPILL: begin
	      // The line indicated by destination_way (at current index)
	      // is dirty, and needs to be written to memory.
	      // This state is used for 1 cycle to initiate a read of the
	      // first beat and set up an EMI transfer:

	      burst_counter <= 0; // upwards to 1 << (`CL_L2SIZE - 3); // Typically 4!
	      emi_req <= 1;
	      emi_size <= 2'b11; // CL (4 beats)
	      emi_RnW <= 0;
	      use_uc_address <= 0;

	      // The first RAM read has happened, increment the address
	      // (separate to external write address) so that the next value
	      // will be read upon the next emi_valid=1 cycle:
	      internal_burst_counter <= internal_burst_counter + 1;
	      data_ram_read_enable <= 0;     // This cycle performs a read, but...
	      data_ram_read_cond <= 1;       // ...next read is conditional on EMI wr-ack
	      state <= `STATE_SPILL_TRANSFER;
	   end


	   `STATE_SPILL_TRANSFER: begin
	      if (emi_if_valid) begin
		 if (burst_counter != ((1 << (`CL_L2SIZE - 3))-1)) begin
		    burst_counter <= burst_counter + 1;
		    internal_burst_counter <= internal_burst_counter + 1;
		 end else begin
		    // The clock that just happened captured the last beat.
		    emi_req <= 0;
		    data_ram_read_cond <= 0;
		    state <= state_next;
		    internal_burst_counter <= 0;
		 end
	      end
	   end


	   `STATE_FILL: begin
	      // The line indicated by destination_way (at current index)
	      // is clean/invalid and will be written by a read from EMI.
	      // This state is used for 1 cycle to initiate an EMI read
	      // transfer.
	      burst_counter <= 0;
	      internal_burst_counter <= 0;
	      emi_req <= 1;
	      emi_size <= 2'b11; // CL (4 beats)
	      emi_RnW <= 1;
	      use_uc_address <= 0;

	      // Capture EMI read data if valid:
	      data_ram_write_cond <= 1;

	      state <= `STATE_FILL_TRANSFER;
	   end


	   `STATE_FILL_TRANSFER: begin
	      if (emi_if_valid) begin
		 if (burst_counter != ((1 << (`CL_L2SIZE - 3))-1)) begin
		    burst_counter <= burst_counter + 1;
		    internal_burst_counter <= internal_burst_counter + 1;
		 end else begin
		    // The clock that just happened captured the last beat.
		    emi_req <= 0;
		    data_ram_write_cond <= 0;

		    // Update the destination way for next time
		    // Random, RR, LRU
		    destination_way <= destination_way + cycle_count;

		    // Finally, write tag for this line: address + Valid
		    //
		    // Uses address input (generates tag_index), which must be stable
		    // throughout.
		    //
		    // (FIXME parameterise this!)
		    tag_mem[tag_index] <= tags_new_value;

		    // We done.  Return to LOOKUP, which then retries
		    // (Debug -- make sure the next cycle HITS!)
		    state <= `STATE_LOOKUP;
		 end
	      end
	   end


	   `STATE_CONSUME: begin
	      state <= `STATE_LOOKUP;
	      // Note rdata_from_uncached is kept high here
	      // (if we just did UNCACHED_R) and reset when
	      // the next request is made.
	      wdata_from_uncached <= 0;
	      use_uc_address <= 0;
	   end


	   `STATE_CMO_CONSUME: begin
	      state <= `STATE_LOOKUP;
	   end


	   `STATE_INVALIDATE: begin
	      /* In this state, tags_new_value has V zeroed in the tag
	       * selected by way_addr.
	       */
	      tag_mem[tag_index] <= tags_new_value;
	      state <= `STATE_CMO_CONSUME;
	   end


	   `STATE_FILL_ZERO: begin
	      // Like an external fill, except without the external access!
	      // data_ram_en_wr is asserted in this state.
	      // ram_spill_fill_addr generated from zero_way.

	      if (internal_burst_counter < 3) begin
		 // Cycle 0,1,2
		 internal_burst_counter <= internal_burst_counter + 1;
	      end else begin
		 // Last cycle: new tag for target line, valid and dirty:
		 tag_mem[tag_index] <= tags_new_value;

		 // Move on destination_way.  FIXME: LRU etc.
		 destination_way <= destination_way + cycle_count;

		 // Exit via consume.
		 state <= `STATE_CMO_CONSUME;
	      end

	   end


	   `STATE_INV_SET: begin
              /* Invalidate all tags in the set given by address:
               *
               * An invalidate-all is performed by issuing a series
               * of these (N=128 for a 4-way 16KB config).
               */
              tag_mem[tag_index] <= {((1 << L2WAYS) * TAG_SIZE){1'b0}};
              state <= `STATE_CMO_CONSUME;
	   end

	 endcase
      end

      if (reset) begin
	 state <= `STATE_LOOKUP;
	 rdata_from_uncached <= 0;
	 wdata_from_uncached <= 0;
	 data_ram_read_enable <= 0;
	 data_ram_read_cond <= 0;
	 data_ram_write_cond <= 0;
	 emi_req <= 0;
	 cycle_count <= 0;
      end
   end

   ///////////////////////////////////////////////////////////////////////////
   /* Valid/stall outputs.
    * Valid if:
    *  LOOKUP and cached and a hit.
    *  CONSUME (and requester hasn't changed the request since last time stall was 0...)
    *
    * Stall if:
    *  FILL, SPILL, UNCACHED*, ZERO, LOOKUP when uncached
    *
    * I.e. no stall in CONSUME or LOOKUP for cached!
    */
   reg uc_inputs_same_as_requested;
   always @(*) begin
      valid_out = 0;
      stall_out = 1;

      /* An uncached access follows the form of immediately stalling, then later
       * providing a cycle where stall=0 at which point read data is ready.
       * Since stall=0, inputs are permitted to change in that cycle, and we do not
       * want to give the impression that any output data relates to the changed
       * request.  So, if the conditions change, valid must be 0.  A new request
       * then occurs.
       */
      uc_inputs_same_as_requested = address == requested_address &&
				    requested_request == request_type &&
				    requested_size == size;

      if ((state == `STATE_CONSUME && uc_inputs_same_as_requested) ||
	  (state == `STATE_LOOKUP && (request_type == `C_REQ_C_READ ||
				      request_type == `C_REQ_C_WRITE) && hit) ||
	  /* This is a splendid hack to avoid any penalty for a no-op CMO: */
	  (state == `STATE_LOOKUP && (request_type == `C_REQ_INV ||
				      request_type == `C_REQ_CLEAN_INV ||
				      request_type == `C_REQ_CLEAN) && !hit) ||
	  state == `STATE_CMO_CONSUME) begin

	 valid_out = 1;

	 // FIXME: For a CMO (or write!) could signal valid (so pipeline can
	 // continue on).  Outer world needs to be prepared to see cache signal
	 // stalled in cycles not making a request, though.
      end

      if (state == `STATE_CONSUME ||
	  state == `STATE_LOOKUP /* && cached*/ ||
	  state == `STATE_CMO_CONSUME) begin
	 stall_out = 0;
      end
   end

   always @(*) begin
      // Address bits 2:0 are only useful when a 1-4 byte read are performed.
      // The dword isn't shuffled given 2:0, i.e. the EMI is a dword-granule interface.
      // FIXME: This is a bit confusing, so neaten this up.

      emi_address = {address[31:`CL_L2SIZE],
		     burst_counter[`CL_L2SIZE-3-1:0], 3'b000};

      if (use_uc_address) begin
	 emi_address = address[31:0];
      end else if (state == `STATE_SPILL_TRANSFER) begin
	 emi_address = {spill_address[31:`CL_L2SIZE],
			burst_counter[`CL_L2SIZE-3-1:0], 3'b000};
      end
   end

   ///////////////////////////////////////////////////////////////////////////
   // Assign outputs

   assign stall = stall_out;
   assign valid = valid_out;
   assign emi_if_address[31:0] = emi_address;
   assign emi_if_req = emi_req;
   assign emi_if_RnW = emi_RnW;
   assign emi_if_bws = emi_bwe;
   assign emi_if_wdata = wdata_from_uncached ? uc_reg : data_ram_out;
   assign emi_if_size = emi_size;

endmodule // cache
