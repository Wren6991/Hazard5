#include <cstdint>
#include <cassert>
#include <cstdio>
#include <iostream>
#include <fstream>
#include <optional>
#include <tuple>
#include <vector>

#include "rv_types.h"
#include "mem.h"

// Minimal RISC-V interpreter, supporting RV32IM only

// Use unsigned arithmetic everywhere, with explicit sign extension as required.
static inline ux_t sext(ux_t bits, int sign_bit) {
	if (sign_bit >= XLEN - 1)
		return bits;
	else
		return (bits & (1u << sign_bit + 1) - 1) - ((bits & 1u << sign_bit) << 1);
}

static inline ux_t imm_i(uint32_t instr) {
	return (instr >> 20) - (instr >> 19 & 0x1000);
}

static inline ux_t imm_s(uint32_t instr) {
	return (instr >> 20 & 0xfe0u)
		+ (instr >> 7 & 0x1fu)
		- (instr >> 19 & 0x1000u);
}

static inline ux_t imm_u(uint32_t instr) {
	return instr & 0xfffff000u;
}

static inline ux_t imm_b(uint32_t instr) {
	return (instr >> 7 & 0x1e)
		+ (instr >> 20 & 0x7e0)
		+ (instr << 4 & 0x800)
		- (instr >> 19 & 0x1000);
}

static inline ux_t imm_j(uint32_t instr) {
	 return (instr >> 20 & 0x7fe)
	 	+ (instr >> 9 & 0x800)
	 	+ (instr & 0xff000)
	 	- (instr >> 11 & 0x100000);
}

struct RVCSR {
	enum {
		WRITE = 0,
		WRITE_SET = 1,
		WRITE_CLEAR = 2
	};

	enum {
		MSCRATCH = 0x340,
		MCYCLE = 0xb00,
		MTIME = 0xb01,
		MINSTRET = 0xb02
	};

	ux_t mcycle;
	ux_t mscratch;

	RVCSR(): mcycle(0), mscratch(0) {}

	void step() {++mcycle;}

	ux_t read(uint16_t addr, bool side_effect=true) {
		if (addr == MCYCLE || addr == MTIME || addr == MINSTRET)
			return mcycle;
		else if (addr == MSCRATCH)
			return mscratch;
		else
			return 0;
	}

	void write(uint16_t addr, ux_t data, uint op=WRITE) {
		if (op == WRITE_CLEAR)
			data = read(addr, false) & ~data;
		else if (op == WRITE_SET)
			data = read(addr, false) | data;
		if (addr == MCYCLE)
			mcycle = data;
		else if (addr == MSCRATCH)
			mscratch = data;
	}

};

struct RVCore {
	std::array<ux_t, 32> regs;
	ux_t pc;
	RVCSR csr;

	RVCore(ux_t reset_vector=0xc0) {
		std::fill(std::begin(regs), std::end(regs), 0);
		pc = reset_vector;
	}

	enum {
		OPC_LOAD     = 0b00'000,
		OPC_MISC_MEM = 0b00'011,
		OPC_OP_IMM   = 0b00'100,
		OPC_AUIPC    = 0b00'101,
		OPC_STORE    = 0b01'000,
		OPC_OP       = 0b01'100,
		OPC_LUI      = 0b01'101,
		OPC_BRANCH   = 0b11'000,
		OPC_JALR     = 0b11'001,
		OPC_JAL      = 0b11'011,
		OPC_SYSTEM   = 0b11'100
	};

	void step(MemBase32 &mem) {
		uint32_t instr = mem.r32(pc);
		std::optional<ux_t> rd_wdata;
		std::optional<ux_t> pc_wdata;
		uint regnum_rs1 = instr >> 15 & 0x1f;
		uint regnum_rs2 = instr >> 20 & 0x1f;
		uint regnum_rd  = instr >> 7 & 0x1f;
		ux_t rs1 = regs[regnum_rs1];
		ux_t rs2 = regs[regnum_rs2];
		bool instr_invalid = false;

		uint opc = instr >> 2 & 0x1f;
		uint funct3 = instr >> 12 & 0x7;
		uint funct7 = instr >> 25 & 0x7f;

		switch (opc) {

		case OPC_OP: {
			if (funct7 == 0b00'00000) {
				if (funct3 == 0b000)
					rd_wdata = rs1 + rs2;
				else if (funct3 == 0b001)
					rd_wdata = rs1 << (rs2 & 0x1f);
				else if (funct3 == 0b010)
					rd_wdata = (sx_t)rs1 < (sx_t)rs2;
				else if (funct3 == 0b011)
					rd_wdata = rs1 < rs2;
				else if (funct3 == 0b100)
					rd_wdata = rs1 ^ rs2;
				else if (funct3 == 0b101)
					rd_wdata = rs1  >> (rs2 & 0x1f);
				else if (funct3 == 0b110)
					rd_wdata = rs1 | rs2;
				else if (funct3 == 0b111)
					rd_wdata = rs1 & rs2;
				else
					instr_invalid = true;
			}
			else if (funct7 == 0b01'00000) {
				if (funct3 == 0b000)
					rd_wdata = rs1 - rs2;
				else if (funct3 == 0b101)
					rd_wdata = (sx_t)rs1 >> (rs2 & 0x1f);
				else
					instr_invalid = true;
			}
			else if (funct7 == 0b00'00001) {
				if (funct3 < 0b100) {
					sdx_t mul_op_a = rs1;
					sdx_t mul_op_b = rs2;
					if (funct3 != 0b011)
						mul_op_a -= (mul_op_a & (1 << XLEN - 1)) << 1;
					if (funct3 < 0b010)
						mul_op_b -= (mul_op_b & (1 << XLEN - 1)) << 1;
					sdx_t mul_result = mul_op_a * mul_op_b;
					if (funct3 == 0b000)
						rd_wdata = mul_result;
					else
						rd_wdata = mul_result >> XLEN;
				}
				else {
					asm volatile("" : : : "memory");
					if (funct3 == 0b100) {
						if (rs2 == 0)
							rd_wdata = -1;
						else if (rs2 == ~0u)
							rd_wdata = -rs1;
						else
							rd_wdata = (sx_t)rs1 / (sx_t)rs2;
					}
					else if (funct3 == 0b101) {
						rd_wdata = rs2 ? rs1 / rs2 : ~0ul;
					}
					else if (funct3 == 0b110) {
						if (rs2 == 0)
							rd_wdata = rs1;
						else if (rs2 == ~0u) // potential overflow of division
							rd_wdata = 0;
						else
							rd_wdata = (sx_t)rs1 % (sx_t)rs2;
					}
					else if (funct3 == 0b111) {
						rd_wdata = rs2 ? rs1 % rs2 : rs1;
					}
				}
			}
			else {
				instr_invalid = true;
			}
			break;
		}

		case OPC_OP_IMM: {
			ux_t imm = imm_i(instr);
			if (funct3 == 0b000)
				rd_wdata = rs1 + imm;
			else if (funct3 == 0b010)
				rd_wdata = !!((sx_t)rs1 < (sx_t)imm);
			else if (funct3 == 0b011)
				rd_wdata = !!(rs1 < imm);
			else if (funct3 == 0b100)
				rd_wdata = rs1 ^ imm;
			else if (funct3 == 0b110)
				rd_wdata = rs1 | imm;
			else if (funct3 == 0b111)
				rd_wdata = rs1 & imm;
			else if (funct3 == 0b001 || funct3 == 0b101) {
				// shamt is regnum_rs2
				if (funct7 == 0b00'00000 && funct3 == 0b001) {
					rd_wdata = rs1 << regnum_rs2;
				}
				else if (funct7 == 0b00'00000 && funct3 == 0b101) {
					rd_wdata = rs1 >> regnum_rs2;
				}
				else if (funct7 == 0b01'00000 && funct3 == 0b101) {
					rd_wdata = (sx_t)rs1 >> regnum_rs2;
				}
				else {
					instr_invalid = true;
				}
			}
			else {
				instr_invalid = true;
			}
			break;
		}

		case OPC_BRANCH: {
			ux_t target = pc + imm_b(instr);
			bool taken = false;
			if ((funct3 & 0b110) == 0b000)
				taken = rs1 == rs2;
			else if ((funct3 & 0b110) == 0b100)
				taken = (sx_t)rs1 < (sx_t) rs2;
			else if ((funct3 & 0b110) == 0b110)
				taken = rs1 < rs2;
			else
				instr_invalid = true;
			if (!instr_invalid && funct3 & 0b001)
				taken = !taken;
			if (taken)
				pc_wdata = target;
			break;
		}

		case OPC_LOAD: {
			ux_t load_addr = rs1 + imm_i(instr);
			if (funct3 == 0b000)
				rd_wdata = sext(mem.r8(load_addr), 7);
			else if (funct3 == 0b001)
				rd_wdata = sext(mem.r16(load_addr), 15);
			else if (funct3 == 0b010)
				rd_wdata = mem.r32(load_addr);
			else if (funct3 == 0b100)
				rd_wdata = mem.r8(load_addr);
			else if (funct3 == 0b101)
				rd_wdata = mem.r16(load_addr);
			else
				instr_invalid = true;
			break;
		}

		case OPC_STORE: {
			ux_t store_addr = rs1 + imm_s(instr);
			if (funct3 == 0b000)
				mem.w8(store_addr, rs2 & 0xffu);
			else if (funct3 == 0b001)
				mem.w16(store_addr, rs2 & 0xffffu);
			else if (funct3 == 0b010)
				mem.w32(store_addr, rs2);
			else
				instr_invalid = true;
			break;
		}

		case OPC_JAL:
			rd_wdata = pc + 4;
			pc_wdata = pc + imm_j(instr);
			break;

		case OPC_JALR:
			rd_wdata = pc + 4;
			pc_wdata = (rs1 + imm_i(instr)) & -2u;
			break;

		case OPC_LUI:
			rd_wdata = imm_u(instr);
			break;

		case OPC_AUIPC:
			rd_wdata = pc + imm_u(instr);
			break;

		case OPC_SYSTEM: {
			uint16_t csr_addr = instr >> 20;
			if (funct3 >= 0b001 && funct3 <= 0b011) {
				// csrrw, csrrs, csrrc
				uint write_op = funct3 - 0b001;
				if (write_op != RVCSR::WRITE || regnum_rd != 0)
					rd_wdata = csr.read(csr_addr);
				if (write_op == RVCSR::WRITE || regnum_rs1 != 0)
					csr.write(csr_addr, rs1, write_op);
			}
			else if (funct3 >= 0b101 && funct3 <= 0b111) {
				// csrrwi, csrrsi, csrrci
				uint write_op = funct3 - 0b101;
				if (write_op != RVCSR::WRITE || regnum_rd != 0)
					rd_wdata = csr.read(csr_addr);
				if (write_op == RVCSR::WRITE || regnum_rs1 != 0)
					csr.write(csr_addr, regnum_rs1, write_op);
			}
			else {
				instr_invalid = true;
			}
			break;
		}

		default:
			instr_invalid = true;
			break;
		}

		if (instr_invalid)
			printf("Invalid instr %08x at %08x\n", instr, pc);

		if (pc_wdata)
			pc = *pc_wdata;
		else
			pc = pc + 4;
		if (rd_wdata && regnum_rd != 0)
			regs[regnum_rd] = *rd_wdata;
		csr.step();
	}
};


const char *help_str =
"Usage: tb binfile [--dump start end] [--cycles n]\n"
"    binfile          : Binary to load into start of memory\n"
"    --dump start end : Print out memory contents between start and end (exclusive)\n"
"                       after execution finishes. Can be passed multiple times.\n"
"    --cycles n       : Maximum number of cycles to run before exiting.\n"
"    --memsize n      : Memory size in units of 1024 bytes, default is 16 MB\n"
;

void exit_help(std::string errtext = "") {
	std::cerr << errtext << help_str;
	exit(-1);
}

int main(int argc, char **argv) {
	if (argc < 2)
		exit_help();

	std::vector<std::tuple<uint32_t, uint32_t>> dump_ranges;
	int64_t max_cycles = 100000;
	uint32_t ramsize = 16 * (1 << 20);

	for (int i = 2; i < argc; ++i) {
		std::string s(argv[i]);
		if (s == "--dump") {
			if (argc - i < 3)
				exit_help("Option --dump requires 2 arguments\n");
			dump_ranges.push_back(std::make_tuple(
				std::stoul(argv[i + 1], 0, 0),
				std::stoul(argv[i + 2], 0, 0)
			));
			i += 2;
		}
		else if (s == "--cycles") {
			if (argc - i < 2)
				exit_help("Option --cycles requires an argument\n");
			max_cycles = std::stol(argv[i + 1], 0, 0);
			i += 1;
		}
		else if (s == "--memsize") {
			if (argc - i < 2)
				exit_help("Option --memsize requires an argument\n");
			ramsize = 1024 * std::stol(argv[i + 1], 0, 0);
			i += 1;
		}
		else {
			std::cerr << "Unrecognised argument " << s << "\n";
			exit_help("");
		}
	}

	FlatMem32 ram(ramsize);
	TBMemIO io;
	MemMap32 mem;
	mem.add(0, ramsize, &ram);
	mem.add(0x80000000u, 12, &io);

	std::ifstream fd(argv[1], std::ios::binary | std::ios::ate);
	std::streamsize bin_size = fd.tellg();
	if (bin_size > ramsize) {
		std::cerr << "Binary file (" << bin_size << " bytes) is larger than memory (" << ramsize << " bytes)\n";
		return -1;
	}
	fd.seekg(0, std::ios::beg);
	fd.read((char*)ram.mem, bin_size);

	RVCore core;

	int64_t cyc;
	try {
		for (cyc = 0; cyc < max_cycles; ++cyc)
			core.step(mem);
	}
	catch (TBExitException e) {
		printf("CPU requested halt. Exit code %d\n", e.exitcode);
		printf("Ran for %ld cycles\n", cyc + 1);
	}

	for (auto [start, end] : dump_ranges) {
		printf("Dumping memory from %08x to %08x:\n", start, end);
		for (uint32_t i = 0; i < end - start; ++i)
			printf("%02x%c", mem.r8(start + i), i % 16 == 15 ? '\n' : ' ');
		printf("\n");
	}

	return 0;
}
