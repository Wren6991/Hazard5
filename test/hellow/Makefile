SRCS         := ../common/init.S main.c
APP          := hellow

LDSCRIPT     := ../common/memmap.ld
CROSS_PREFIX := riscv32-unknown-elf-
TBDIR        := ../tb_cxxrtl

###############################################################################

.SUFFIXES:
.PHONY: all run view clean tb

all: run

run: $(APP).bin
	$(TBDIR)/tb $(APP).bin $(APP)_run.vcd

view: run
	gtkwave $(APP)_run.vcd

bin: $(APP).bin

tb:
	$(MAKE) -C $(TBDIR) tb

clean:
	$(MAKE) -C $(TBDIR) clean
	rm -f $(APP).elf $(APP).bin $(APP).dis $(APP)_run.vcd

###############################################################################

$(APP).bin: $(APP).elf
	$(CROSS_PREFIX)objcopy -O binary $^ $@
	$(CROSS_PREFIX)objdump -h $(APP).elf > $(APP).dis
	$(CROSS_PREFIX)objdump -D $(APP).elf >> $(APP).dis

$(APP).elf: $(SRCS) $(wildcard %.h)
	$(CROSS_PREFIX)gcc $(SRCS) -T $(LDSCRIPT) -o $(APP).elf
