ROOT := $(abspath ..)

.PHONY: smoke clean

smoke:
	cd $(ROOT) && verilator --binary --timing -j 0 \
	  --top-module tb_hsl_smoke \
	  -f sim/filelist.f \
	  --Mdir sim/build/obj \
	  -o smoke
	$(ROOT)/sim/build/obj/smoke

clean:
	rm -rf $(ROOT)/sim/build
