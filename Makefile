# All build output stays in build/ (gitignored). Requires Xcode (see README).

CONFIG ?= Debug
PKG := Packages/MindmapKit
SWIFTPM := --package-path $(PKG) --scratch-path build/swiftpm --disable-sandbox
# Keep nested sandboxes disabled so builds also work inside an agent sandbox
# (Codex workspace-write mode or the Claude Code sandbox).
# The manifest-sandbox flags mirror --disable-sandbox for package manifests.
XCODEBUILD := xcodebuild -project mindmap.xcodeproj -scheme mindmap -destination 'platform=macOS' -derivedDataPath build/DerivedData -IDEPackageSupportDisableManifestSandbox=YES
PRODUCTS := build/DerivedData/Build/Products
SOURCES := App $(PKG) scripts
DEV_NAME := mindmap dev
DEV_APP := $(PRODUCTS)/Debug/$(DEV_NAME).app

.PHONY: build run stop screenshot logs install check-isolation test preview lint format clean

build:
	$(XCODEBUILD) -configuration $(CONFIG) build

# Debug build = "mindmap dev", bundle ID ...mindmap.dev, its own sandbox container.
# ARGS go to the app, e.g. make run ARGS="-fixture sample".
run: stop
	$(MAKE) build CONFIG=Debug
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
	log show --last 2m --style compact --predicate 'subsystem == "io.github.roshanmatrubai.mindmap.dev"'

install:
	$(MAKE) build CONFIG=Release
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

lint:
	swift format lint --strict --recursive --parallel $(SOURCES)

format:
	swift format format --in-place --recursive --parallel $(SOURCES)

clean:
	rm -rf build
