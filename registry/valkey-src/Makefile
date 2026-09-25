# Builds one Valkey version for one arch. Driven by registry/scripts/package-valkey.sh:
#   make VERSION=9.1.2 SOURCE_SHA256=<sha256 of the source tarball> ARCH=arm64
VERSION ?= $(error set VERSION)
SOURCE_SHA256 ?= $(error set SOURCE_SHA256)
ARCH ?= $(shell uname -m)
TARBALL = valkey-$(VERSION).tar.gz
OUT = build/$(VERSION)/$(ARCH)
SRC = $(OUT)/valkey-$(VERSION)
export MACOSX_DEPLOYMENT_TARGET ?= 13.0

all: $(OUT)/bin/valkey-server

$(TARBALL):
	curl -fL -o $@.tmp https://github.com/valkey-io/valkey/archive/refs/tags/$(VERSION).tar.gz
	echo "$(SOURCE_SHA256)  $@.tmp" | shasum -a 256 -c -
	mv $@.tmp $@

$(SRC)/Makefile: $(TARBALL)
	mkdir -p $(OUT)
	tar xzf $(TARBALL) -C $(OUT)
	touch $@

$(OUT)/bin/valkey-server: $(SRC)/Makefile
	$(MAKE) -C $(SRC) CC="clang -arch $(ARCH)" BUILD_TLS=no -j$$(sysctl -n hw.ncpu)
	mkdir -p $(OUT)/bin
	cp $(SRC)/src/valkey-server $(SRC)/src/valkey-cli $(OUT)/bin/
	@echo "Built Valkey $(VERSION) ($(ARCH)) in valkey-src/$(OUT)/bin"

clean:
	rm -rf build valkey-*.tar.gz

.PHONY: all clean
