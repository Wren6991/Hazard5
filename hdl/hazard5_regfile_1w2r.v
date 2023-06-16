/**********************************************************************
 * DO WHAT THE FUCK YOU WANT TO AND DON'T BLAME US PUBLIC LICENSE     *
 *                    Version 3, April 2008                           *
 *                                                                    *
 * Copyright (C) 2018 Luke Wren                                       *
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

// Register file
// Single write port, dual read port

// FAKE_DUALPORT: if 1, implement regfile with pair of memories.
// Write ports are ganged together, read ports operate independently.
// This allows BRAM inference on FPGAs with single-read-port BRAMs.
// (Looking at you iCE40)

module hazard5_regfile_1w2r #(
	parameter RESET_REGS = 0,
	parameter N_REGS = 16,
	parameter W_DATA = 32,
	parameter W_ADDR = $clog2(W_DATA)	// should be localparam. ISIM...
) (
	input wire clk,
	input wire rst_n,

	input wire [W_ADDR-1:0] raddr1,
	output reg [W_DATA-1:0] rdata1,

	input wire [W_ADDR-1:0] raddr2,
	output reg [W_DATA-1:0] rdata2,

	input wire [W_ADDR-1:0] waddr,
	input wire [W_DATA-1:0] wdata,
	input wire              wen
);

generate
if (RESET_REGS) begin: real_dualport_reset
	// This will presumably always be implemented with flops
	reg [W_DATA-1:0] mem [0:N_REGS-1];

	integer i;
	always @ (posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			for (i = 0; i < N_REGS; i = i + 1) begin
				mem[i] <= {W_DATA{1'b0}};
			end
		end else begin
			if (wen) begin
				mem[waddr] <= wdata;
			end
			rdata1 <= mem[raddr1];
			rdata2 <= mem[raddr2];
		end
	end
end else begin: real_dualport_noreset
	// This should be inference-compatible on FPGAs with dual-port BRAMs
	`ifdef YOSYS
	`ifdef FPGA_ICE40
	// We do not require write-to-read bypass logic on the BRAM
	(* no_rw_check *)
	`endif
	`endif	reg [W_DATA-1:0] mem [0:N_REGS-1];
 
	always @ (posedge clk) begin
		if (wen) begin
			mem[waddr] <= wdata;
		end
		rdata1 <= mem[raddr1];
		rdata2 <= mem[raddr2];
	end
end
endgenerate

endmodule
