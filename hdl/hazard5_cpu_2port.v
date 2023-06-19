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

// Dual-ported top level file for Hazard5 CPU. This file instantiates the
// Hazard5 core, and interfaces its instruction fetch and load/store signals
// to a pair of AHB-Lite master ports.

module hazard5_cpu_2port #(
`include "hazard5_config.vh"
) (
	// Global signals
	input wire               clk,
	input wire               rst_n,

	`ifdef RISCV_FORMAL
	`RVFI_OUTPUTS ,
	`endif

	// Instruction fetch port
	output wire [W_ADDR-1:0] i_haddr,
	output wire              i_hwrite,
	output wire [1:0]        i_htrans,
	output wire [2:0]        i_hsize,
	output wire [2:0]        i_hburst,
	output wire [3:0]        i_hprot,
	output wire              i_hmastlock,
	input  wire              i_hready,
	input  wire              i_hresp,
	output wire [W_DATA-1:0] i_hwdata,
	input  wire [W_DATA-1:0] i_hrdata,

	// Load/store port
	output wire [W_ADDR-1:0] d_haddr,
	output wire              d_hwrite,
	output wire [1:0]        d_htrans,
	output wire [2:0]        d_hsize,
	output wire [2:0]        d_hburst,
	output wire [3:0]        d_hprot,
	output wire              d_hmastlock,
	input  wire              d_hready,
	input  wire              d_hresp,
	output wire [W_DATA-1:0] d_hwdata,
	input  wire [W_DATA-1:0] d_hrdata,

	// External level-sensitive interrupt sources (tie 0 if unused)
	input wire [15:0]        irq
);

// ----------------------------------------------------------------------------
// Processor core

// Instruction fetch signals
wire              core_aph_req_i;
wire              core_aph_panic_i; // unused as there's no arbitration
wire              core_aph_ready_i;
wire              core_dph_ready_i;
wire              core_dph_err_i;

wire [2:0]        core_hsize_i;
wire [W_ADDR-1:0] core_haddr_i;
wire [W_DATA-1:0] core_rdata_i;


// Load/store signals
wire              core_aph_req_d;
wire              core_aph_ready_d;
wire              core_dph_ready_d;
wire              core_dph_err_d;

wire [W_ADDR-1:0] core_haddr_d;
wire [2:0]        core_hsize_d;
wire              core_hwrite_d;
wire [W_DATA-1:0] core_wdata_d;
wire [W_DATA-1:0] core_rdata_d;


hazard5_core #(
	.RESET_VECTOR      (RESET_VECTOR),
	.EXTENSION_C       (EXTENSION_C),
	.EXTENSION_M       (EXTENSION_M),
	.MULDIV_UNROLL     (MULDIV_UNROLL),
	.MUL_FAST          (MUL_FAST),
	.CSR_M_MANDATORY   (CSR_M_MANDATORY),
	.CSR_M_TRAP        (CSR_M_TRAP),
	.CSR_COUNTER       (CSR_COUNTER),
	.MTVEC_WMASK       (MTVEC_WMASK),
	.MTVEC_INIT        (MTVEC_INIT),
	.REDUCED_BYPASS    (REDUCED_BYPASS),
	.NO_LS_ALIGN_CHECK (NO_LS_ALIGN_CHECK)
) core (
	.clk             (clk),
	.rst_n           (rst_n),

	`ifdef RISCV_FORMAL
	`RVFI_CONN ,
	`endif

	.bus_aph_req_i   (core_aph_req_i),
	.bus_aph_panic_i (core_aph_panic_i),
	.bus_aph_ready_i (core_aph_ready_i),
	.bus_dph_ready_i (core_dph_ready_i),
	.bus_dph_err_i   (core_dph_err_i),
	.bus_hsize_i     (core_hsize_i),
	.bus_haddr_i     (core_haddr_i),
	.bus_rdata_i     (core_rdata_i),

	.bus_aph_req_d   (core_aph_req_d),
	.bus_aph_ready_d (core_aph_ready_d),
	.bus_dph_ready_d (core_dph_ready_d),
	.bus_dph_err_d   (core_dph_err_d),
	.bus_haddr_d     (core_haddr_d),
	.bus_hsize_d     (core_hsize_d),
	.bus_hwrite_d    (core_hwrite_d),
	.bus_wdata_d     (core_wdata_d),
	.bus_rdata_d     (core_rdata_d),

	.irq             (irq)
);

// ----------------------------------------------------------------------------
// Instruction port

localparam HTRANS_IDLE = 2'b00;
localparam HTRANS_NSEQ = 2'b10;

assign i_haddr = core_haddr_i;
assign i_htrans = core_aph_req_i ? HTRANS_NSEQ : HTRANS_IDLE;
assign i_hsize = core_hsize_i;

reg dphase_active_i;
always @ (posedge clk or negedge rst_n)
	if (!rst_n)
		dphase_active_i <= 1'b0;
	else if (i_hready)
		dphase_active_i <= core_aph_req_i;

assign core_aph_ready_i = i_hready && core_aph_req_i;
assign core_dph_ready_i = i_hready && dphase_active_i;
assign core_dph_err_i   = i_hready && dphase_active_i && i_hresp;

assign core_rdata_i = i_hrdata;

assign i_hwrite = 1'b0;
assign i_hburst = 3'h0;
assign i_hprot = 4'b0010;
assign i_hmastlock = 1'b0;
assign i_hwdata = {W_DATA{1'b0}};

// ----------------------------------------------------------------------------
// Load/store port

assign d_haddr = core_haddr_d;
assign d_htrans = core_aph_req_d ? HTRANS_NSEQ : HTRANS_IDLE;
assign d_hwrite = core_hwrite_d;
assign d_hsize = core_hsize_d;

reg dphase_active_d;
always @ (posedge clk or negedge rst_n)
	if (!rst_n)
		dphase_active_d <= 1'b0;
	else if (d_hready)
		dphase_active_d <= core_aph_req_d;

assign core_aph_ready_d = d_hready && core_aph_req_d;
assign core_dph_ready_d = d_hready && dphase_active_d;
assign core_dph_err_d   = d_hready && dphase_active_d && d_hresp;

assign core_rdata_d = d_hrdata;
assign d_hwdata = core_wdata_d;

assign d_hburst = 3'h0;
assign d_hprot = 4'b0010;
assign d_hmastlock = 1'b0;

endmodule
