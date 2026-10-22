APP_NAME   := MD QuickLook.app
BUILD_APP  := build/$(APP_NAME)
INSTALL_DIR ?= /Applications
VERSION    := $(shell tr -d '[:space:]' < VERSION)
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Quick Look helpers, matched by full path (their process names are truncated).
THUMBNAILS_AGENT := /System/Library/Frameworks/QuickLookThumbnailing.framework/Support/com.apple.quicklook.ThumbnailsAgent
QL_UI_SERVICE := /System/Library/Frameworks/QuickLookUI.framework/Versions/A/XPCServices/QuickLookUIService.xpc/Contents/MacOS/QuickLookUIService

.PHONY: all build native install uninstall reset test bench release clean snapshot-tool

all: build

build:            ## Universal (arm64 + x86_64) build
	scripts/build.sh

native:           ## Build for this Mac's architecture only
	ARCHS=$(shell uname -m) scripts/build.sh

install: native   ## Build and install into /Applications
	@pkill -x MDQuickLook 2>/dev/null || true
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	cp -R "$(BUILD_APP)" "$(INSTALL_DIR)/"
	$(LSREGISTER) -f -R "$(INSTALL_DIR)/$(APP_NAME)"
	open "$(INSTALL_DIR)/$(APP_NAME)"
	@$(MAKE) --no-print-directory reset

uninstall:        ## Remove the app and its extensions
	@pkill -x MDQuickLook 2>/dev/null || true
	-pluginkit -r "$(INSTALL_DIR)/$(APP_NAME)/Contents/PlugIns/MDQuickLookPreview.appex"
	-pluginkit -r "$(INSTALL_DIR)/$(APP_NAME)/Contents/PlugIns/MDQuickLookThumbnail.appex"
	-$(LSREGISTER) -u "$(INSTALL_DIR)/$(APP_NAME)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	@$(MAKE) --no-print-directory reset

reset:            ## Make Quick Look pick up changes
	@qlmanage -r >/dev/null 2>&1 || true
	@qlmanage -r cache >/dev/null 2>&1 || true
	@pkill -f '^$(THUMBNAILS_AGENT)' 2>/dev/null || true
	@pkill -f '^$(QL_UI_SERVICE)' 2>/dev/null || true

test:             ## Run the Rust core tests
	cargo test --manifest-path core/Cargo.toml

bench:            ## Time rendering of the showcase document
	cargo run --quiet --release --manifest-path core/Cargo.toml -- examples/showcase.md --bench 500

release: build    ## Zip the universal app for a GitHub release
	cd build && ditto -c -k --sequesterRsrc --keepParent "$(APP_NAME)" "MD-QuickLook-$(VERSION).zip"
	@shasum -a 256 "build/MD-QuickLook-$(VERSION).zip"

snapshot-tool:    ## Dev tool: render Markdown natively to a PNG (build/native-snapshot)
	scripts/build-snapshot-tool.sh

clean:
	rm -rf build
	cargo clean --manifest-path core/Cargo.toml
