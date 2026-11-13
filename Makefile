REXTINA_REX ?= rex
REX_DEFAULT := $(HOME)/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex
REX_PATH := $(shell sh -c 'command -v "$(REXTINA_REX)" || { [ -x "$(REX_DEFAULT)" ] && echo "$(REX_DEFAULT)"; }')
ifneq ($(REX_PATH),)
REXTINA_REX := $(REX_PATH)
endif
export REXTINA_REX

SHELL_TESTS := $(wildcard test/*_test.sh)

.PHONY: test test-integration lint

test:
	@set -e; for t in $(SHELL_TESTS); do sh $$t; done
	@if [ -f test/run.lua ]; then "$(REXTINA_REX)" do test/run.lua root="$(CURDIR)"; fi

test-integration:
	@sh test/integration.sh

lint:
	@shellcheck -x bin/* test/*.sh

SHARE_DIR ?= $(HOME)/.local/share/rextina
CONFIG_DIR ?= $(or $(XDG_CONFIG_HOME),$(HOME)/.config)/rex
AGENT_PLIST ?= $(HOME)/Library/LaunchAgents/com.rextina.watch.plist
WATCH_LOG ?= $(HOME)/Library/Logs/rextina-watch.log
REXTINA_MIN_WORKING ?= 30
UNAME := $(shell uname)
DOMAIN := gui/$(shell id -u)

.PHONY: install install-watch install-action uninstall

install: install-watch install-action

install-watch:
	@mkdir -p "$(SHARE_DIR)/bin" "$(SHARE_DIR)/lua"
	@cp bin/rextina-status bin/rextina-watch bin/rextina-init "$(SHARE_DIR)/bin/"
	@cp lua/watch.lua lua/rextina_status.lua "$(SHARE_DIR)/lua/"
ifeq ($(UNAME),Darwin)
	@test -n "$(REX_PATH)" || { echo "rex not found; run: make install REXTINA_REX=/path/to/rex"; exit 1; }
	@mkdir -p "$(dir $(AGENT_PLIST))" "$(dir $(WATCH_LOG))"
	@sed -e 's|@WATCH@|$(SHARE_DIR)/bin/rextina-watch|' -e 's|@REX@|$(REX_PATH)|' \
		-e 's|@MIN_WORKING@|$(REXTINA_MIN_WORKING)|' -e 's|@LOG@|$(WATCH_LOG)|g' \
		launchd/com.rextina.watch.plist.in > "$(AGENT_PLIST)"
	@plutil -lint "$(AGENT_PLIST)" > /dev/null
	@launchctl bootout $(DOMAIN)/com.rextina.watch 2> /dev/null || true
	@launchctl bootstrap $(DOMAIN) "$(AGENT_PLIST)"
	@echo "watcher installed; log: $(WATCH_LOG)"
endif

install-action:
ifeq ($(UNAME),Darwin)
	@test -n "$(REX_PATH)" || { echo "rex not found; run: make install REXTINA_REX=/path/to/rex"; exit 1; }
	@mkdir -p "$(CONFIG_DIR)"
	@cp lua/rextina.lua lua/rextina_status.lua "$(CONFIG_DIR)/"
	@sh bin/rextina-init add "$(CONFIG_DIR)/init.lua"
	@"$(REX_PATH)" config check
	@"$(REX_PATH)" config reload
	@echo "action installed in $(CONFIG_DIR)"
endif

uninstall:
ifeq ($(UNAME),Darwin)
	@launchctl bootout $(DOMAIN)/com.rextina.watch 2> /dev/null || true
	@rm -f "$(AGENT_PLIST)"
	@sh bin/rextina-init remove "$(CONFIG_DIR)/init.lua"
	@rm -f "$(CONFIG_DIR)/rextina.lua" "$(CONFIG_DIR)/rextina_status.lua"
	@"$(REX_PATH)" config reload > /dev/null 2>&1 || true
endif
	@rm -rf "$(SHARE_DIR)"
