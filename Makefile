# All build output stays in build/ (gitignored). Requires Xcode (see README).

CONFIG ?= Debug
# Standalone builds work without keychain access. The dev launch retains Local.xcconfig signing.
SIGNING ?= adhoc
SIGNING_FLAGS := $(if $(filter adhoc,$(SIGNING)),CODE_SIGN_IDENTITY=-,)
PKG := Packages/MindmapKit
CACHE_ROOT := $(CURDIR)/build/caches
export CLANG_MODULE_CACHE_PATH := $(CACHE_ROOT)/clang
export SWIFTPM_MODULECACHE_OVERRIDE := $(CACHE_ROOT)/swift-modules
SWIFTPM := --package-path $(PKG) --scratch-path build/swiftpm --cache-path $(CACHE_ROOT)/swiftpm --config-path $(CACHE_ROOT)/swiftpm-config --security-path $(CACHE_ROOT)/swiftpm-security --manifest-cache local --disable-sandbox
# Keep nested sandboxes disabled so builds also work inside an agent sandbox
# (Codex workspace-write mode or the Claude Code sandbox).
# The manifest-sandbox flags mirror --disable-sandbox for package manifests.
XCODEBUILD_FLAGS := -project mindmap.xcodeproj -derivedDataPath build/DerivedData -IDEPackageSupportDisableManifestSandbox=YES -packageCachePath $(CACHE_ROOT)/xcode-packages -IDEPackageCacheDirPath=$(CACHE_ROOT)/xcode-packages -IDEDisablePackageManifestCaching=YES CLANG_MODULE_CACHE_PATH=$(CLANG_MODULE_CACHE_PATH)
XCODEBUILD := xcodebuild -scheme mindmap -destination 'platform=macOS' $(XCODEBUILD_FLAGS) $(SIGNING_FLAGS)
# iPad simulator builds need no signing. A generic destination works without any particular simulator (CI).
IPAD_XCODEBUILD := xcodebuild -scheme mindmap-ipad -destination 'generic/platform=iOS Simulator' $(XCODEBUILD_FLAGS)
PRODUCTS := build/DerivedData/Build/Products
SOURCES := App $(PKG) scripts
DEV_NAME := mindmap dev
DEV_APP := $(PRODUCTS)/Debug/$(DEV_NAME).app
DEV_ID := io.github.roshanmatrubai.mindmap.dev
IPAD_DEV_APP := $(PRODUCTS)/Debug-iphonesimulator/$(DEV_NAME).app
# The simulator ipad-run uses: the custom "iPad Pro 12.9 M1" if it exists, else a stock one.
SIM ?= $(shell xcrun simctl list devices available | grep -qF "    iPad Pro 12.9 M1 " && echo "iPad Pro 12.9 M1" || echo "iPad Pro 13-inch (M5)")

.PHONY: build run stop screenshot logs install check-isolation test preview lint format clean icon \
	ipad-build ipad-run ipad-stop ipad-screenshot ipad-logs ipad-install

build:
	$(XCODEBUILD) -configuration $(CONFIG) build

# Debug build = "mindmap dev", bundle ID ...mindmap.dev, its own sandbox container.
# ARGS go to the app, e.g. make run ARGS="-fixture sample".
run: stop
	$(MAKE) build CONFIG=Debug SIGNING=configured
	open "$(DEV_APP)" --args $(ARGS)

stop:
	@pkill -x "$(DEV_NAME)" && while pgrep -qx "$(DEV_NAME)"; do sleep 0.1; done || true

# Captures only the dev app's window (needs Screen Recording for the terminal app).
screenshot:
	@id=$$(swift scripts/dev-window.swift id "$(DEV_NAME)") || { echo "no $(DEV_NAME) window; run make run first"; exit 1; }; \
	mkdir -p build && screencapture -x -o -l $$id build/screenshot.png && echo "build/screenshot.png"; \
	if swift scripts/dev-window.swift blank build/screenshot.png; then \
	  echo "screenshot is blank: grant Screen Recording to your terminal app in System Settings > Privacy & Security > Screen & System Audio Recording, then restart the terminal"; exit 1; fi

logs:
	log show --last 2m --style compact --predicate 'subsystem == "$(DEV_ID)"'

# iPad: the same Debug app ("mindmap dev", .dev bundle ID) in the iPad simulator, whose storage is
# its own sandbox. ARGS go to the app, e.g. make ipad-run ARGS="-fixture sample" SIM="iPad Air 13-inch (M4)".
ipad-build:
	$(IPAD_XCODEBUILD) -configuration $(CONFIG) build

ipad-run:
	$(MAKE) ipad-build CONFIG=Debug
	@udid=$$(xcrun simctl list devices available | grep -F "    $(SIM) (" | head -1 | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}'); \
	if [ -z "$$udid" ]; then echo "no simulator named $(SIM); pass SIM=\"<name>\" (xcrun simctl list devices)"; exit 1; fi; \
	xcrun simctl boot $$udid 2>/dev/null; xcrun simctl bootstatus $$udid -b >/dev/null && \
	{ open -b com.apple.iphonesimulator 2>/dev/null || true; } && \
	xcrun simctl terminate $$udid $(DEV_ID) 2>/dev/null; \
	xcrun simctl install $$udid "$(IPAD_DEV_APP)" && \
	xcrun simctl launch $$udid $(DEV_ID) $(ARGS)

ipad-stop:
	@xcrun simctl terminate booted $(DEV_ID) 2>/dev/null || true

ipad-screenshot:
	@mkdir -p build && xcrun simctl io booted screenshot build/ipad-screenshot.png >/dev/null 2>&1 && echo "build/ipad-screenshot.png"

# LAST=15m reaches further back (a whole smoke run); SINCE="2026-10-06 05:00:00" starts there.
LAST ?= 2m
ipad-logs:
	xcrun simctl spawn booted log show $(if $(SINCE),--start "$(SINCE)",--last $(LAST)) --style compact --predicate 'subsystem == "$(DEV_ID)"'

# For the human only: the Release iPad app on a connected iPad, signed by Xcode with the team in
# Config/Local.xcconfig (a free Personal Team works; reinstall every 7 days). DEVICE=<name> picks one.
IPAD_DEVICE_APP := $(PRODUCTS)/Release-iphoneos/mindmap.app
ipad-install:
	@grep -qs '^DEVELOPMENT_TEAM *= *[A-Z0-9]' Config/Local.xcconfig || { echo "set DEVELOPMENT_TEAM in Config/Local.xcconfig first (see Config/Local.xcconfig.example)"; exit 1; }
	@mkdir -p build && xcrun devicectl list devices --json-output build/devices.json >/dev/null 2>&1 || { echo "devicectl couldn't list devices (Xcode 26 needed)"; exit 1; }
	@id=$$(swift scripts/ipad-device.swift build/devices.json "$(DEVICE)") || exit 1; \
	xcodebuild -scheme mindmap-ipad -destination 'generic/platform=iOS' $(XCODEBUILD_FLAGS) -configuration Release -allowProvisioningUpdates build && \
	xcrun devicectl device install app --device $$id "$(IPAD_DEVICE_APP)" && \
	echo "installed mindmap on the iPad. if it won't open: Settings > General > VPN & Device Management > trust your developer certificate"

install:
	$(MAKE) build CONFIG=Release SIGNING=configured
	rm -rf /Applications/mindmap.app
	ditto "$(PRODUCTS)/Release/mindmap.app" /Applications/mindmap.app
	@echo "installed /Applications/mindmap.app"

# For the human only (agents never run it): can this shell read the maps folder, or everything?
# Only exit statuses are used; nothing is printed from any folder. FOLDER defaults to ~/Documents.
check-isolation:
	@echo "if macOS asks for access, click Don't Allow."
	@dir="$(or $(FOLDER),$(HOME)/Documents)"; \
	if [ ! -d "$$dir" ]; then echo "no folder at $$dir"; exit 1; fi; \
	fda=0; \
	for probe in "$(HOME)/Library/Safari" "$(HOME)/Library/Mail" "$(HOME)/Library/Messages"; do \
	  if [ -d "$$probe" ] && ls "$$probe" >/dev/null 2>&1; then fda=1; break; fi; \
	done; \
	if [ "$$fda" = 1 ]; then \
	  echo "EXPOSED: your terminal has Full Disk Access, so it can read every folder. Turn it off in System Settings > Privacy & Security > Full Disk Access."; \
	elif ls "$$dir" >/dev/null 2>&1; then \
	  echo "EXPOSED: this shell can read $$dir. Either macOS doesn't protect that folder (it protects Documents, Desktop, Downloads and iCloud Drive), or your terminal was allowed in once (check System Settings > Privacy & Security > Files & Folders)."; \
	else echo "PROTECTED: this shell can't read $$dir and has no Full Disk Access."; fi

test:
	swift test $(SWIFTPM)
	$(MAKE) build CONFIG=Debug

preview:
	swift run $(SWIFTPM) mindmap-preview --fixture $(PKG)/Tests/Fixtures/sample.mindmap --out build/preview.png

# Renders the app icon from code (scripts/make-icon.swift).
icon:
	swift scripts/make-icon.swift

lint:
	swift format lint --strict --recursive --parallel $(SOURCES)

format:
	swift format format --in-place --recursive --parallel $(SOURCES)

clean:
	rm -rf build
