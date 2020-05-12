Hazard5
=======

Hazard5 is a RISC-V processor I designed for [the RISCBoy games console](https://github.com/Wren6991/RISCBoy). I'm pulling it out into a separate repo to make it easily reusable, and to allow some development work that is outside the scope of the RISCBoy project.

The processor supports the RV32IMC instruction set, and passes the RISC-V compliance suite for these instructions, as well as the [riscv-formal](https://github.com/SymbioticEDA/riscv-formal) verification suite, and some of my own formal property checks for instruction frontend consistency and basic bus compliance. It also supports M-mode CSRs, exceptions, and a simple compliant extension for vectored external interrupts.

It's a 5-stage in-order pipeline, with static branch prediction. The design is documented fairly extensively in the [RISCBoy Documentation (PDF)](https://github.com/Wren6991/RISCBoy/raw/master/doc/riscboy_doc.pdf).
