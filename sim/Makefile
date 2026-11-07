ROOT := $(abspath ..)

.PHONY: smoke lint clean

smoke:
	cd $(ROOT) && verilator --binary --timing -j 0 \
	  --top-module tb_hsl_smoke \
	  -f sim/filelist.f \
	  --Mdir sim/build/obj \
	  -o smoke
	$(ROOT)/sim/build/obj/smoke

# RTL lint, -Wall, with the waivers (and their reasons) in syn/lint.vlt.
lint:
	cd $(ROOT) && verilator --lint-only -Wall syn/lint.vlt 	  --top-module hsl_base_die_lite -f syn/filelist.f

clean:
	rm -rf $(ROOT)/sim/build
