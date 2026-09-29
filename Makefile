# Name of the local code signing certificate (see README).
CERT ?= ratoncito-codesign
IDENTIFIER := local.ratoncito
BIN := .build/release/ratoncito
# Options passed to `ratoncito install`, e.g. make install ARGS="--verbose"
ARGS ?=

.PHONY: build sign install uninstall clean

build:
	swift build -c release $(BUILD_FLAGS)

# A stable signing identity keeps the Accessibility grant valid across rebuilds;
# ad-hoc signatures change with every build, so the grant goes stale.
sign: build
	@if security find-identity -p codesigning | grep -Fq '"$(CERT)"'; then \
		codesign --force --sign "$(CERT)" --identifier $(IDENTIFIER) $(BIN); \
		echo "Signed $(BIN) with \"$(CERT)\""; \
	else \
		echo "warning: no \"$(CERT)\" certificate found; signing ad-hoc." >&2; \
		echo "warning: the Accessibility grant will need re-adding after each rebuild (see README)." >&2; \
		codesign --force --sign - --identifier $(IDENTIFIER) $(BIN); \
	fi

install: sign
	$(BIN) install $(ARGS)

uninstall: build
	$(BIN) uninstall

clean:
	rm -rf .build
