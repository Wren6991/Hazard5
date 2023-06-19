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

`default_nettype none

module hazard5_regfile_1w2r #(
	parameter RESET_REGS = 0,
	parameter N_REGS = 32,
	parameter W_DATA = 32,
	parameter W_ADDR = $clog2(N_REGS)
) (
	input  wire              clk,
	input  wire              rst_n,

	input  wire              ren,

	input  wire [W_ADDR-1:0] raddr1,
	output reg  [W_DATA-1:0] rdata1,

	input  wire [W_ADDR-1:0] raddr2,
	output reg  [W_DATA-1:0] rdata2,

	input  wire [W_ADDR-1:0] waddr,
	input  wire [W_DATA-1:0] wdata,
	input  wire              wen
);

reg [W_DATA-1:0] rdata1_q_neg;
reg [W_DATA-1:0] rdata2_q_neg;

generate
if (RESET_REGS) begin: reset_g
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
		end
	end
	always @ (negedge clk or negedge rst_n) begin
		if (!rst_n) begin
			rdata1_q_neg <= {W_DATA{1'b0}};
			rdata2_q_neg <= {W_DATA{1'b0}};
		end else begin
			rdata1_q_neg <= mem[raddr1];
			rdata2_q_neg <= mem[raddr2];
		end
	end
end else begin: no_reset_g
	// This should be inference-compatible on FPGAs with dual-port BRAMs
	`ifdef YOSYS
	`ifdef FPGA_ICE40
	// We do not require write-to-read bypass logic on the BRAM
	(* no_rw_check *)
	`endif
	`endif
	reg [W_DATA-1:0] mem [0:N_REGS-1];
	always @ (posedge clk) begin
		if (wen) begin
			mem[waddr] <= wdata;
		end
	end
	always @ (negedge clk) begin
		// Note we avoid using ren here because it's assumed to be a fairly
		// late signal (bus-stall-dependent) so shouldn't be used on the negedge.
		rdata1_q_neg <= mem[raddr1];
		rdata2_q_neg <= mem[raddr2];
	end
end
endgenerate

reg [W_ADDR-1:0] raddr1_prev;
reg [W_ADDR-1:0] raddr2_prev;

// If read enable is low, the output remains stable, *except* when the
// last-read register is written to, in which case we update.
always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		rdata1 <= {W_DATA{1'b0}};
		rdata2 <= {W_DATA{1'b0}};
		raddr1_prev <= {W_ADDR{1'b0}};
		raddr2_prev <= {W_ADDR{1'b0}};
	end else if (ren) begin
		raddr1_prev <= raddr1;
		raddr2_prev <= raddr2;
		rdata1 <= {W_DATA{|raddr1}} & (wen && raddr1 == waddr ? wdata : rdata1_q_neg);
		rdata2 <= {W_DATA{|raddr2}} & (wen && raddr2 == waddr ? wdata : rdata2_q_neg);
	end else if (wen) begin
		if (|raddr1_prev && raddr1_prev == waddr) begin
			rdata1 <= wdata;
		end
		if (|raddr2_prev && raddr2_prev == waddr) begin
			rdata2 <= wdata;
		end
	end
end

endmodule

`ifndef YOSYS
`default_nettype wire
`endif