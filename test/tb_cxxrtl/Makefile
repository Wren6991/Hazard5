.PHONY: clean tb all

all: tb

dut.cpp:
	yosys -p "read_verilog -I ../../hdl $(shell listfiles ../../hdl/hazard5.f); chparam -set RESET_VECTOR 32'hc0 hazard5_cpu; prep -flatten -top hazard5_cpu; async2sync; write_cxxrtl -O2 dut.cpp" 2>&1 > cxxrtl.log

clean::
	rm -f dut.cpp cxxrtl.log

tb: dut.cpp
	clang++ -O3 -std=c++14 -I $(shell yosys-config --datdir)/include tb.cpp -o tb