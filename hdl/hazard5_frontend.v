module hazard5_frontend #(
	parameter EXTENSION_C = 1,
	parameter W_ADDR = 32,     // other sizes currently unsupported
	parameter W_DATA = 32,     // other sizes currently unsupported
	parameter FIFO_DEPTH = 2,  // power of 2, >= 1
	parameter RESET_VECTOR = 0
) (
	input wire clk,
	input wire rst_n,

	// Fetch interface
	// addr_vld may be asserted at any time, but after assertion,
	// neither addr nor addr_vld may change until the cycle after addr_rdy.
	// There is no backpressure on the data interface; the front end
	// must ensure it does not request data it cannot receive.
	// addr_rdy and dat_vld may be functions of hready, and
	// may not be used to compute combinational outputs.
	output wire              mem_size, // 1'b1 -> 32 bit access
	output wire [W_ADDR-1:0] mem_addr,
	output wire              mem_addr_vld,
	input wire               mem_addr_rdy,
	input wire  [W_DATA-1:0] mem_data,
	input wire               mem_data_vld,

	// Jump/flush interface
	// Processor may assert vld at any time. The request will not go through
	// unless rdy is high. Processor *may* alter request during this time.
	// Inputs must not be a function of hready.
	input wire  [W_ADDR-1:0] jump_target,
	input wire               jump_target_vld,
	output wire              jump_target_rdy,

	// Interface to Decode
	// Note reg/wire distinction
	// => decode is providing live feedback on the CIR it is decoding,
	//    which we fetched previously
	// This works OK because size is decoded from 2 LSBs of instruction, so cheap.
	output reg  [31:0]       cir,
	output reg  [1:0]        cir_vld, // number of valid halfwords in CIR
	input wire  [1:0]        cir_use, // number of halfwords D intends to consume
	                                  // *may* be a function of hready
	input wire               cir_lock // Lock-in current contents and level of CIR.
	                                  // Assert simultaneously with a jump request,
	                                  // if decode is going to stall. This stops the CIR
	                                  // from being trashed by incoming fetch data;
	                                  // jump instructions have other side effects besides jumping!
);

`undef ASSERT
`ifdef HAZARD5_FRONTEND_ASSERTIONS
`define ASSERT(x) assert(x)
`else
`define ASSERT(x)
`endif

// ISIM doesn't support some of this:
// //synthesis translate_off
// initial if (W_DATA != 32) begin $error("Frontend requires 32-bit databus"); end
// initial if ((1 << $clog2(FIFO_DEPTH)) != FIFO_DEPTH) begin $error("Frontend FIFO depth must be power of 2"); end
// initial if (~|FIFO_DEPTH) begin $error("Frontend FIFO depth must be > 0"); end
// //synthesis translate_on

localparam W_BUNDLE = W_DATA / 2;
parameter W_FIFO_PTR = $clog2(FIFO_DEPTH + 1);

// ============================================================================
// Fetch Queue (FIFO)
// ============================================================================
// This is a little different from either a normal sync fifo or sync fwft fifo
// so it's worth implementing from scratch

wire jump_now = jump_target_vld && jump_target_rdy;

reg [W_DATA-1:0] fifo_mem [0:FIFO_DEPTH-1];
reg [W_FIFO_PTR-1:0] fifo_wptr;
reg [W_FIFO_PTR-1:0] fifo_rptr;

wire [W_FIFO_PTR-1:0] fifo_level = fifo_wptr - fifo_rptr;
wire fifo_full = (fifo_wptr ^ fifo_rptr) == (1'b1 & {W_FIFO_PTR{1'b1}}) << (W_FIFO_PTR - 1);
wire fifo_empty = fifo_wptr == fifo_rptr;
wire fifo_almost_full = fifo_level == FIFO_DEPTH - 1;

wire fifo_push;
wire fifo_pop;
wire [W_DATA-1:0] fifo_wdata = mem_data;
wire [W_DATA-1:0] fifo_rdata;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		fifo_wptr <= {W_FIFO_PTR{1'b0}};
		fifo_rptr <= {W_FIFO_PTR{1'b0}};
	end else begin
		`ASSERT(!(fifo_pop && fifo_empty));
		`ASSERT(!(fifo_push && fifo_full));
		`ASSERT(fifo_level <= FIFO_DEPTH);
		if (fifo_push) begin
			fifo_wptr <= fifo_wptr + 1'b1;
			fifo_mem[fifo_wptr & ~FIFO_DEPTH] <= fifo_wdata;
		end
		if (jump_now) begin
			fifo_rptr <= fifo_wptr + fifo_push;
		end else if (fifo_pop) begin
			fifo_rptr <= fifo_rptr + 1'b1;
		end
	end
end

assign fifo_rdata = fifo_mem[fifo_rptr & ~FIFO_DEPTH];

// ============================================================================
// Fetch Request + State Logic
// ============================================================================

// Keep track of some useful state of the memory interface

reg        mem_addr_hold;
reg  [1:0] pending_fetches;
reg  [1:0] ctr_flush_pending;
wire [1:0] pending_fetches_next = pending_fetches + (mem_addr_vld && !mem_addr_hold) - mem_data_vld;

wire cir_must_refill;
// If fetch data is forwarded past the FIFO, ensure it is not also written to it.
assign fifo_push = mem_data_vld && ~|ctr_flush_pending && !(cir_must_refill && fifo_empty);

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		mem_addr_hold <= 1'b0;
		pending_fetches <= 2'h0;
		ctr_flush_pending <= 2'h0;
	end else begin
		`ASSERT(ctr_flush_pending <= pending_fetches);
		`ASSERT(pending_fetches < 2'd3);
		`ASSERT(!(mem_data_vld && !pending_fetches));
		// `ASSERT(!($past(mem_addr_hold) && $past(mem_addr_vld) && !$stable(mem_addr)));
		mem_addr_hold <= mem_addr_vld && !mem_addr_rdy;
		pending_fetches <= pending_fetches_next;
		if (jump_now) begin
			ctr_flush_pending <= pending_fetches - mem_data_vld;
		end else if (|ctr_flush_pending && mem_data_vld) begin
			ctr_flush_pending <= ctr_flush_pending - 1'b1;
		end
	end
end

// Fetch addr runs ahead of the PC, in word increments.
reg [W_ADDR-1:0] fetch_addr;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		fetch_addr <= RESET_VECTOR;
	end else begin
		if (jump_now) begin
			// Post-increment if jump request is going straight through
			fetch_addr <= {jump_target[W_ADDR-1:2] + (mem_addr_rdy && !mem_addr_hold), 2'b00};
		end else if (mem_addr_vld && mem_addr_rdy) begin
			fetch_addr <= fetch_addr + 3'h4;
		end
	end
end

// Using the non-registered version of pending_fetches would improve FIFO
// utilisation, but create a combinatorial path from hready to address phase!
wire fetch_stall = fifo_full
	|| fifo_almost_full && |pending_fetches    // TODO causes issue with depth 1: only one in flight, so bus rate halved.
	|| pending_fetches > 2'h1;


// unaligned jump is handled in two different places:
// - during address phase, offset may be applied to fetch_addr if hready was low when jump_target_vld was high
// - during data phase, need to assemble CIR differently.


wire unaligned_jump_now = EXTENSION_C && jump_now && jump_target[1];
reg unaligned_jump_aph;
reg unaligned_jump_dph;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		unaligned_jump_aph <= 1'b0;
		unaligned_jump_dph <= 1'b0;
	end else if (EXTENSION_C) begin
		`ASSERT(!(unaligned_jump_aph && !unaligned_jump_dph));
		`ASSERT(!($past(jump_now && !jump_target[1]) && unaligned_jump_aph));
		`ASSERT(!($past(jump_now && !jump_target[1]) && unaligned_jump_dph));
		if (mem_addr_rdy || (jump_now && !unaligned_jump_now)) begin
			unaligned_jump_aph <= 1'b0;
		end
		if ((mem_data_vld && ~|ctr_flush_pending)
			|| (jump_now && !unaligned_jump_now)) begin
			unaligned_jump_dph <= 1'b0;
		end
		if (unaligned_jump_now) begin
			unaligned_jump_dph <= 1'b1;
			unaligned_jump_aph <= !mem_addr_rdy;
		end
	end
end

// Combinatorially generate the address-phase request

reg reset_holdoff;
always @ (posedge clk or negedge rst_n)
	if (!rst_n)
		reset_holdoff <= 1'b1;
	else
		reset_holdoff <= 1'b0;

reg [W_ADDR-1:0] mem_addr_r;
reg mem_addr_vld_r;
reg mem_size_r;

assign mem_addr = mem_addr_r;
assign mem_addr_vld = mem_addr_vld_r && !reset_holdoff;
assign mem_size = mem_size_r;

always @ (*) begin
	mem_addr_r = {W_ADDR{1'b0}};
	mem_addr_vld_r = 1'b1;
	mem_size_r = 1'b1; // almost all accesses are 32 bit
	case (1'b1)
		mem_addr_hold   : begin mem_addr_r = {fetch_addr[W_ADDR-1:2], unaligned_jump_aph, 1'b0}; mem_size_r = !unaligned_jump_aph; end
		jump_target_vld : begin mem_addr_r = jump_target; mem_size_r = !unaligned_jump_now; end
		!fetch_stall    : begin mem_addr_r = fetch_addr; end
		default         : begin mem_addr_vld_r = 1'b0; end
	endcase
end

assign jump_target_rdy = !mem_addr_hold;


// ============================================================================
// Instruction assembly yard
// ============================================================================

// buf_level is the number of valid halfwords in {hwbuf, cir}.
// cir_vld and hwbuf_vld are functions of this.
reg [1:0] buf_level;
reg [W_BUNDLE-1:0] hwbuf;
reg hwbuf_vld;

wire [W_DATA-1:0] fetch_data = fifo_empty ? mem_data : fifo_rdata;
wire fetch_data_vld = !fifo_empty || (mem_data_vld && ~|ctr_flush_pending);

// Shift any recycled instruction data down to backfill D's consumption
// We don't care about anything which is invalid or will be overlaid with fresh data,
// so choose these values in a way that minimises muxes
wire [3*W_BUNDLE-1:0] instr_data_shifted =
	cir_use[1]                ? {hwbuf, cir[W_BUNDLE +: W_BUNDLE], hwbuf} :
	cir_use[0] && EXTENSION_C ? {hwbuf, hwbuf, cir[W_BUNDLE +: W_BUNDLE]} :
	                            {hwbuf, cir};

// Saturating subtraction: on cir_lock dassertion,
// buf_level will be 0 but cir_use will be positive!
wire [1:0] cir_use_clipped = buf_level ? cir_use : 2'h0;

wire [1:0] level_next_no_fetch = buf_level - cir_use_clipped;

// Overlay fresh fetch data onto the shifted/recycled instruction data
// Again, if something won't be looked at, generate cheapest possible garbage.
// Don't care if fetch data is valid or not, as will just retry next cycle (as long as flags set correctly)
wire [3*W_BUNDLE-1:0] instr_data_plus_fetch =
	cir_lock || (level_next_no_fetch[1] && !unaligned_jump_dph) ? instr_data_shifted :
	unaligned_jump_dph     && EXTENSION_C ? {instr_data_shifted[W_BUNDLE +: 2*W_BUNDLE], fetch_data[W_BUNDLE +: W_BUNDLE]} :
	level_next_no_fetch[0] && EXTENSION_C ? {fetch_data, instr_data_shifted[0 +: W_BUNDLE]} :
	                         {instr_data_shifted[2*W_BUNDLE +: W_BUNDLE], fetch_data};

assign cir_must_refill = !cir_lock && !level_next_no_fetch[1];
assign fifo_pop = cir_must_refill && !fifo_empty;

wire [1:0] buf_level_next =
	jump_now || |ctr_flush_pending ? 2'h0 :
	fetch_data_vld && unaligned_jump_dph ? 2'h1 :
	buf_level + {cir_must_refill && fetch_data_vld, 1'b0} - cir_use_clipped;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		buf_level <= 2'h0;
		hwbuf_vld <= 1'b0;
		cir_vld <= 2'h0;
	end else begin
		`ASSERT(cir_vld <= 2);
		`ASSERT(cir_use <= 2);
		`ASSERT(cir_use <= cir_vld);
		`ASSERT(cir_vld <= buf_level || $past(cir_lock));
		// Update CIR flags
		buf_level <= buf_level_next;
		hwbuf_vld <= &buf_level_next;
		if (!cir_lock)
			cir_vld <= buf_level_next & ~(buf_level_next >> 1'b1);
		// Update CIR contents
	end
end

// No need to reset these as they will be written before first use
always @ (posedge clk)
	{hwbuf, cir} <= instr_data_plus_fetch;

endmodule
