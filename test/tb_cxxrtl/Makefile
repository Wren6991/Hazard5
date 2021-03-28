CPU_RESET_VECTOR := 32'hc0
EXTENSION_C      := 1
EXTENSION_M      := 1
MULDIV_UNROLL    := 1
REDUCED_BYPASS   := 0

.PHONY: clean tb all

all: tb

SYNTH_CMD += read_verilog -I ../../hdl $(shell listfiles ../../hdl/hazard5.f);
SYNTH_CMD += chparam -set EXTENSION_C $(EXTENSION_C) hazard5_cpu_1port;
SYNTH_CMD += chparam -set EXTENSION_M $(EXTENSION_M) hazard5_cpu_1port;
SYNTH_CMD += chparam -set CSR_COUNTER 1 hazard5_cpu_1port;
SYNTH_CMD += chparam -set RESET_VECTOR $(CPU_RESET_VECTOR) hazard5_cpu_1port;
SYNTH_CMD += chparam -set REDUCED_BYPASS $(REDUCED_BYPASS) hazard5_cpu_1port;
SYNTH_CMD += chparam -set MULDIV_UNROLL $(MULDIV_UNROLL) hazard5_cpu_1port;
SYNTH_CMD += prep -flatten -top hazard5_cpu_1port; async2sync;
SYNTH_CMD += write_cxxrtl dut.cpp

dut.cpp:
	yosys -p "$(SYNTH_CMD)" 2>&1 > cxxrtl.log

clean::
	rm -f dut.cpp cxxrtl.log tb

tb: dut.cpp
	clang++ -O3 -std=c++14 -I $(shell yosys-config --datdir)/include tb.cpp -o tb
