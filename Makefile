ALL: build deploy
update:
	@git fetch
	@git merge origin/MSX2
	@git merge origin/MSX2test
	@git fetch
	$(build)
build:
	quartus_sh --flow compile MSX1.qpf
	cp output_files/MSX1.rbf output_files/MSX1_$(shell date +%Y%m%d).rbf
deploy:
#	scp output_files/MSX1_$(shell date +%Y%m%d).rbf root@192.168.1.34:/media/fat/_Computer/
	scp output_files/MSX1_$(shell date +%Y%m%d).rbf root@192.168.1.86:/media/fat/_Computer/

