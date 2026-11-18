.DEFAULT_GOAL := kernelrelease

release := $(shell cat kernel.release)
install_root := $(if $(strip $(INSTALL_MOD_PATH)),$(INSTALL_MOD_PATH),/)
module_dir := $(INSTALL_MOD_PATH)/lib/modules/$(release)
DEPMOD ?= depmod

.PHONY: kernelrelease modules_install

kernelrelease:
	@printf '%s\n' "$(release)"

modules_install:
	test -n "$(release)" && test -d "lib/modules/$(release)/kernel"
	install -d "$(module_dir)"
	rm -rf -- "$(module_dir)/kernel"
	cp -R -- "lib/modules/$(release)/." "$(module_dir)/"
	"$(DEPMOD)" -ae -F System.map -b "$(install_root)" "$(release)"
