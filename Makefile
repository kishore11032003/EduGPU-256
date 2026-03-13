OUT := ./build
VFLAGS := --binary --trace --trace-structs --trace-depth 5 --timing --assert -Wall -Wno-fatal -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-MULTIDRIVEN +define+SIMULATION
PKG := edugpu_pkg.sv

.PHONY: all unit-tests sim-top tb-fetch tb-decode tb-alu tb-rf tb-sched tb-cache tb-ldst tb-vram tb-tex driver clean help

all: unit-tests

unit-tests: tb-fetch tb-decode tb-alu tb-rf tb-sched tb-cache tb-ldst
	@echo ""
	@echo "=== All unit tests complete ==="

tb-fetch:
	@mkdir -p $(OUT)/tb_fetch
	verilator $(VFLAGS) --top tb_fetch_unit --Mdir $(OUT)/tb_fetch $(PKG) fetch_unit.sv tb_fetch_unit.sv
	$(OUT)/tb_fetch/Vtb_fetch_unit

tb-decode:
	@mkdir -p $(OUT)/tb_decode
	verilator $(VFLAGS) --top tb_decode_unit --Mdir $(OUT)/tb_decode $(PKG) decode_unit.sv tb_decode_unit.sv
	$(OUT)/tb_decode/Vtb_decode_unit

tb-alu:
	@mkdir -p $(OUT)/tb_alu
	verilator $(VFLAGS) --top tb_alu_fpu --Mdir $(OUT)/tb_alu $(PKG) alu_fpu_unit.sv tb_units.sv
	$(OUT)/tb_alu/Vtb_alu_fpu

tb-rf:
	@mkdir -p $(OUT)/tb_rf
	verilator $(VFLAGS) --top tb_register_file --Mdir $(OUT)/tb_rf $(PKG) register_file.sv tb_units.sv
	$(OUT)/tb_rf/Vtb_register_file

tb-sched:
	@mkdir -p $(OUT)/tb_sched
	verilator $(VFLAGS) --top tb_warp_scheduler --Mdir $(OUT)/tb_sched $(PKG) warp_scheduler.sv tb_units.sv
	$(OUT)/tb_sched/Vtb_warp_scheduler

tb-cache:
	@mkdir -p $(OUT)/tb_cache
	verilator $(VFLAGS) --top tb_cache --Mdir $(OUT)/tb_cache $(PKG) cache_subsystem.sv tb_units.sv
	$(OUT)/tb_cache/Vtb_cache

tb-ldst:
	@mkdir -p $(OUT)/tb_ldst
	verilator $(VFLAGS) --top tb_ldst --Mdir $(OUT)/tb_ldst $(PKG) ldst_unit.sv tb_units.sv
	$(OUT)/tb_ldst/Vtb_ldst

tb-vram:
	@mkdir -p $(OUT)/tb_vram
	verilator $(VFLAGS) --top tb_vram_controller --Mdir $(OUT)/tb_vram $(PKG) vram_controller.sv tb_vram_texture.sv
	$(OUT)/tb_vram/Vtb_vram_controller

tb-tex:
	@mkdir -p $(OUT)/tb_tex
	verilator $(VFLAGS) --top tb_texture_unit --Mdir $(OUT)/tb_tex $(PKG) texture_unit.sv tb_vram_texture.sv
	$(OUT)/tb_tex/Vtb_texture_unit

sim-top:
	@mkdir -p $(OUT)/sim_top
	verilator $(VFLAGS) --top tb_edugpu_top --Mdir $(OUT)/sim_top $(PKG) fetch_unit.sv decode_unit.sv register_file.sv alu_fpu_unit.sv texture_unit.sv warp_scheduler.sv ldst_unit.sv streaming_multiprocessor.sv cache_subsystem.sv vram_controller.sv graphics_pipeline.sv edugpu_top.sv tb_edugpu_top.sv
	$(OUT)/sim_top/Vtb_edugpu_top
	@echo "Done! Run: gtkwave edugpu_sim.vcd"

driver:
	gcc -O2 -Wall -DEDUGPU_SIM_MODE -c edugpu_driver.c -o edugpu_driver.o
	@echo "Driver built: edugpu_driver.o"

clean:
	rm -rf $(OUT) *.vcd *.o

help:
	@echo "make tb-fetch      test fetch unit"
	@echo "make tb-decode     test decode unit"
	@echo "make tb-alu        test ALU/FPU"
	@echo "make tb-rf         test register file"
	@echo "make tb-sched      test warp scheduler"
	@echo "make tb-cache      test L1/L2 cache"
	@echo "make tb-ldst       test LD/ST unit"
	@echo "make tb-vram       test VRAM controller"
	@echo "make tb-tex        test texture unit"
	@echo "make unit-tests    run ALL unit tests"
	@echo "make sim-top       full GPU simulation"
	@echo "make driver        build C host driver"
	@echo "make clean         remove build files"
