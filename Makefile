# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Z Stadia contributors
#
#   make            build the rumble library and the zstadia tool into build/
#   make test       run the automated tests (no controller needed)
#   make sanitize   run the tests again under AddressSanitizer and ThreadSanitizer
#   make live-test  play both motors through a real controller (hold it)
#   make install    copy zstadia to $(PREFIX)/bin (default ~/.local/bin)
#   make clean      remove build/

MIN_MACOS  := 14.0
ARCHS      := arm64 x86_64
PREFIX     ?= $(HOME)/.local
BUILD      := build

FRAMEWORKS := -framework Foundation -framework GameController -framework CoreHaptics -framework IOKit
CFLAGS     := -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=$(MIN_MACOS)
ARCH_FLAGS := $(foreach a,$(ARCHS),-arch $(a))

DYLIB      := $(BUILD)/ZStadiaRumble.dylib
TOOL       := $(BUILD)/zstadia
TESTS      := $(BUILD)/rumble_tests
SWIFT_SRC  := $(wildcard src/zstadia/*.swift)

.PHONY: all test live-test sanitize install uninstall clean

all: $(DYLIB) $(TOOL)

$(BUILD):
	@mkdir -p $(BUILD)

$(DYLIB): src/ZStadiaRumble/ZStadiaRumble.m | $(BUILD)
	clang -dynamiclib $(CFLAGS) -fvisibility=hidden $(ARCH_FLAGS) \
	  -install_name @rpath/ZStadiaRumble.dylib $(FRAMEWORKS) $< -o $@
	codesign --force --sign - $@

# The library is embedded in the tool, so a single file is all a user needs.
$(TOOL): $(SWIFT_SRC) $(DYLIB) | $(BUILD)
	@for a in $(ARCHS); do \
	  swiftc -O -swift-version 5 -target $$a-apple-macos$(MIN_MACOS) \
	    -Xlinker -sectcreate -Xlinker __DATA -Xlinker __zstadia_lib -Xlinker $(DYLIB) \
	    $(SWIFT_SRC) -o $(BUILD)/zstadia-$$a || exit 1; \
	done
	lipo -create $(foreach a,$(ARCHS),$(BUILD)/zstadia-$(a)) -output $@
	rm -f $(foreach a,$(ARCHS),$(BUILD)/zstadia-$(a))
	codesign --force --sign - $@

$(TESTS): tests/rumble_tests.m | $(BUILD)
	clang -fobjc-arc -O1 -Wall -Wno-arc-performSelector-leaks -mmacosx-version-min=$(MIN_MACOS) $(FRAMEWORKS) $< -o $@

test: $(DYLIB) $(TESTS)
	$(TESTS) $(DYLIB)

live-test: $(DYLIB) | $(BUILD)
	clang -fobjc-arc -O1 -mmacosx-version-min=$(MIN_MACOS) $(FRAMEWORKS) tests/live_test.m -o $(BUILD)/live_test
	@echo "Hold the controller: strong motor, weak motor, then both rising."
	$(BUILD)/live_test $(DYLIB)

sanitize: | $(BUILD)
	@for s in address,undefined thread; do \
	  echo "== $$s"; \
	  clang -dynamiclib $(CFLAGS) -O1 -g -fsanitize=$$s -fvisibility=hidden $(FRAMEWORKS) \
	    src/ZStadiaRumble/ZStadiaRumble.m -o $(BUILD)/ZStadiaRumble-san.dylib || exit 1; \
	  clang -fobjc-arc -O1 -g -fsanitize=$$s -Wno-arc-performSelector-leaks -mmacosx-version-min=$(MIN_MACOS) \
	    $(FRAMEWORKS) tests/rumble_tests.m -o $(BUILD)/rumble_tests-san || exit 1; \
	  $(BUILD)/rumble_tests-san $(BUILD)/ZStadiaRumble-san.dylib || exit 1; \
	done
	rm -f $(BUILD)/ZStadiaRumble-san.dylib $(BUILD)/rumble_tests-san
	rm -rf $(BUILD)/*.dSYM

install: $(TOOL)
	install -d $(PREFIX)/bin
	install -m 755 $(TOOL) $(PREFIX)/bin/zstadia
	@echo "Installed $(PREFIX)/bin/zstadia"

uninstall:
	rm -f $(PREFIX)/bin/zstadia

clean:
	rm -rf $(BUILD)
