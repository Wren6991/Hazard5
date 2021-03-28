/**********************************************************************
 * DO WHAT THE FUCK YOU WANT TO AND DON'T BLAME US PUBLIC LICENSE     *
 *                    Version 3, April 2008                           *
 *                                                                    *
 * Copyright (C) 2021 Luke Wren                                       *
 *                                                                    *
 * Everyone is permitted to copy and distribute verbatim or modified  *
 * copies of this license document and accompanying software, and     *
 * changing either is allowed.                                        *
 *                                                                    *
 *   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION  *
 *                                                                    *
 * 0. You just DO WHAT THE FUCK YOU WANT TO.                          *
 * 1. We're NOT RESPONSIBLE WHEN IT DOESN'T FUCKING WORK.             *
 *                                                                    *
 *********************************************************************/

// Single-ported top level file for Hazard5 CPU. This file instantiates the
// Hazard5 core, and arbitrates its instruction fetch and load/store signals
// down to a single AHB-Lite master port.

module hazard5_cpu_1port #(
	parameter RESET_VECTOR    = 32'h0,// Address of first instruction executed
	parameter EXTENSION_C     = 1,    // Support for compressed (variable-width) instructions
	parameter EXTENSION_M     = 1,    // Support for hardware multiply/divide/modulo instructions
	parameter MULDIV_UNROLL   = 1,    // Bits per clock for multiply/divide circuit, if present. Pow2.

	parameter CSR_M_MANDATORY = 1,    // Bare minimum e.g. misa. Spec says must = 1, but I won't tell anyone
	parameter CSR_M_TRAP      = 1,    // Include M-mode trap-handling CSRs
	parameter CSR_COUNTER     = 0,    // Include performance counters and relevant M-mode CSRs
	parameter MTVEC_WMASK     = 32'hfffff000,
	                                  // Save gates by making trap vector base partly fixed (legal, as it's WARL).
	                                  // Note the entire vector table must always be aligned to its size, rounded
	                                  // up to a power of two, so careful with the low-order bits.
	parameter MTVEC_INIT      = 32'h00000000,
	                                  // Initial value of trap vector base. Bits clear in MTVEC_WMASK will
	                                  // never change from this initial value. Bits set in MTVEC_WMASK can
	                                  // be written/set/cleared as normal.

	parameter REDUCED_BYPASS  = 0,    // Remove all forwarding paths except X->X
	                                  // (so back-to-back ALU ops can still run at 1 CPI)

	parameter W_ADDR          = 32,   // Do not modify
	parameter W_DATA          = 32    // Do not modify
) (
	// Global signals
	input wire               clk,
	input wire               rst_n,

	`ifdef RISCV_FORMAL
	`RVFI_OUTPUTS ,
	`endif

	// AHB-lite Master port
	output reg  [W_ADDR-1:0] ahblm_haddr,
	output reg               ahblm_hwrite,
	output reg  [1:0]        ahblm_htrans,
	output reg  [2:0]        ahblm_hsize,
	output wire [2:0]        ahblm_hburst,
	output reg  [3:0]        ahblm_hprot,
	output wire              ahblm_hmastlock,
	input  wire              ahblm_hready,
	input  wire              ahblm_hresp,
	output wire [W_DATA-1:0] ahblm_hwdata,
	input  wire [W_DATA-1:0] ahblm_hrdata,

	// External level-sensitive interrupt sources (tie 0 if unused)
	input wire [15:0]        irq
);

// ----------------------------------------------------------------------------
// Processor core

// Instruction fetch signals
wire              bus_aph_req_i;
wire              bus_aph_panic_i;
wire              bus_aph_ready_i;
wire              bus_dph_ready_i;
wire              bus_dph_err_i;

wire [2:0]        bus_hsize_i;
wire [W_ADDR-1:0] bus_haddr_i;
wire [W_DATA-1:0] bus_rdata_i;


// Load/store signals
wire              bus_aph_req_d;
wire              bus_aph_ready_d;
wire              bus_dph_ready_d;
wire              bus_dph_err_d;

wire [W_ADDR-1:0] bus_haddr_d;
wire [2:0]        bus_hsize_d;
wire              bus_hwrite_d;
wire [W_DATA-1:0] bus_wdata_d;
wire [W_DATA-1:0] bus_rdata_d;


hazard5_core #(
	.RESET_VECTOR    (RESET_VECTOR),
	.EXTENSION_C     (EXTENSION_C),
	.EXTENSION_M     (EXTENSION_M),
	.MULDIV_UNROLL   (MULDIV_UNROLL),
	.CSR_M_MANDATORY (CSR_M_MANDATORY),
	.CSR_M_TRAP      (CSR_M_TRAP),
	.CSR_COUNTER     (CSR_COUNTER),
	.MTVEC_WMASK     (MTVEC_WMASK),
	.MTVEC_INIT      (MTVEC_INIT),
	.REDUCED_BYPASS  (REDUCED_BYPASS)
) core (
	.clk             (clk),
	.rst_n           (rst_n),

	`ifdef RISCV_FORMAL
	`RVFI_CONN ,
	`endif

	.bus_aph_req_i   (bus_aph_req_i),
	.bus_aph_panic_i (bus_aph_panic_i),
	.bus_aph_ready_i (bus_aph_ready_i),
	.bus_dph_ready_i (bus_dph_ready_i),
	.bus_dph_err_i   (bus_dph_err_i),
	.bus_hsize_i     (bus_hsize_i),
	.bus_haddr_i     (bus_haddr_i),
	.bus_rdata_i     (bus_rdata_i),

	.bus_aph_req_d   (bus_aph_req_d),
	.bus_aph_ready_d (bus_aph_ready_d),
	.bus_dph_ready_d (bus_dph_ready_d),
	.bus_dph_err_d   (bus_dph_err_d),
	.bus_haddr_d     (bus_haddr_d),
	.bus_hsize_d     (bus_hsize_d),
	.bus_hwrite_d    (bus_hwrite_d),
	.bus_wdata_d     (bus_wdata_d),
	.bus_rdata_d     (bus_rdata_d),

	.irq             (irq)
);


// ----------------------------------------------------------------------------
// Arbitration state machine

wire      bus_gnt_i;
wire      bus_gnt_d;

reg       bus_hold_aph;
reg [1:0] bus_gnt_id_prev;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		bus_hold_aph <= 1'b0;
		bus_gnt_id_prev <= 2'h0;
	end else begin
		bus_hold_aph <= ahblm_htrans[1] && !ahblm_hready;
		bus_gnt_id_prev <= {bus_gnt_i, bus_gnt_d};
	end
end

assign {bus_gnt_i, bus_gnt_d} =
	bus_hold_aph  ? bus_gnt_id_prev :
	bus_aph_panic_i  ? 2'b10 :
	bus_aph_req_d    ? 2'b01 :
	bus_aph_req_i    ? 2'b10 :
	                   2'b00 ;

// Keep track of whether instr/data access is active in AHB dataphase.
reg bus_active_dph_i;
reg bus_active_dph_d;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		bus_active_dph_i <= 1'b0;
		bus_active_dph_d <= 1'b0;
	end else if (ahblm_hready) begin
		bus_active_dph_i <= bus_gnt_i;
		bus_active_dph_d <= bus_gnt_d;
	end
end

// ----------------------------------------------------------------------------
// Address phase request muxing

localparam HTRANS_IDLE = 2'b00;
localparam HTRANS_NSEQ = 2'b10;

// Noncacheable nonbufferable privileged data/instr:
localparam HPROT_DATA  = 4'b0011;
localparam HPROT_INSTR = 4'b0010;

assign ahblm_hburst = 3'b000;   // HBURST_SINGLE
assign ahblm_hmastlock = 1'b0;

always @ (*) begin
	if (bus_gnt_d) begin
		ahblm_htrans = HTRANS_NSEQ;
		ahblm_haddr  = bus_haddr_d;
		ahblm_hsize  = bus_hsize_d;
		ahblm_hwrite = bus_hwrite_d;
		ahblm_hprot  = HPROT_DATA;
	end else if (bus_gnt_i) begin
		ahblm_htrans = HTRANS_NSEQ;
		ahblm_haddr  = bus_haddr_i;
		ahblm_hsize  = bus_hsize_i;
		ahblm_hwrite = 1'b0;
		ahblm_hprot  = HPROT_INSTR;
	end else begin
		ahblm_htrans = HTRANS_IDLE;
		ahblm_haddr  = {W_ADDR{1'b0}};
		ahblm_hsize  = 3'h0;
		ahblm_hwrite = 1'b0;
		ahblm_hprot  = 4'h0;
	end
end

// ----------------------------------------------------------------------------
// Response routing

// Data buses directly connected
assign bus_rdata_d = ahblm_hrdata;
assign bus_rdata_i = ahblm_hrdata;
assign ahblm_hwdata = bus_wdata_d;

// Handhshake based on grant and bus stall
assign bus_aph_ready_i = ahblm_hready && bus_gnt_i;
assign bus_dph_ready_i = ahblm_hready && bus_active_dph_i;
assign bus_dph_err_i   = ahblm_hresp  && bus_active_dph_i;

assign bus_aph_ready_d = ahblm_hready && bus_gnt_d;
assign bus_dph_ready_d = ahblm_hready && bus_active_dph_d;
assign bus_dph_err_d   = ahblm_hresp  && bus_active_dph_d;

endmodule