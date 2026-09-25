# Every version listed here is built and bundled as Valkey.app/Contents/Versions/<major.minor>.
VERSIONS = 8.0.11 8.1.10 9.0.6 9.1.2
SHA256_8.0.11 = e4ee4ad51c2e9cb75c5fac8865d34792482a597bf3b136b42b296c9933bd31f8
SHA256_8.1.10 = c74e50cd83f6d398a3dc570e04ac2fe538249585d021f76ee2449bbf9ebd04ed
SHA256_9.0.6 = 38f1e83faf382637d6e49503903187acb3ceed624e96d7b1d32b8d3d52768414
SHA256_9.1.2 = 19c23908e7d57e8d91ef85b41f5646307582f10f4f0fb999bbf89ed24ec9c983

# One version + one arch per invocation; embed-valkey.sh loops and lipos them together.
VERSION ?= $(lastword $(VERSIONS))
ARCH ?= $(shell uname -m)
TARBALL = valkey-$(VERSION).tar.gz
OUT = build/$(VERSION)/$(ARCH)
SRC = $(OUT)/valkey-$(VERSION)
export MACOSX_DEPLOYMENT_TARGET ?= 13.0

all: $(OUT)/bin/valkey-server

$(TARBALL):
	curl -fL -o $@.tmp https://github.com/valkey-io/valkey/archive/refs/tags/$(VERSION).tar.gz
	echo "$(SHA256_$(VERSION))  $@.tmp" | shasum -a 256 -c -
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

print-versions:
	@echo $(VERSIONS)

clean:
	rm -rf build valkey-*.tar.gz

.PHONY: all clean print-versions
