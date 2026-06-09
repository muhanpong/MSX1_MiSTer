export PATH := /run/media/muhanpong/0eb4bebc-0644-4c2f-9a97-ddca5afcd8f3/intelFPGA_lite/17.1/quartus/bin/:$(PATH)
ALL: build deploy
update:
	@git fetch
	@git merge origin/MSX2
	@git merge origin/MSX2test
	@git fetch
	$(build)
build:
	quartus_sh --flow compile MSX1.qpf
	-quartus_sta -t report_paths.tcl
	cp output_files/MSX1.rbf output_files/MSX1_$(shell date +%Y%m%d).rbf
	@echo ""
	@echo "================================================================"
	@echo " Build complete — timing summary:"
	@echo "================================================================"
	@cat output_files/MSX1.timing_summary.txt 2>/dev/null || echo "(no timing summary generated)"
deploy:
#	scp output_files/MSX1_$(shell date +%Y%m%d).rbf root@192.168.1.34:/media/fat/_Computer/
	scp output_files/MSX1_$(shell date +%Y%m%d).rbf root@192.168.1.86:/media/fat/_Computer/

