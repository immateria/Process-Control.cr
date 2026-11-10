.PHONY: helper test format check
CRYSTAL ?= crystal

helper:
	$(CRYSTAL) run scripts/build-helper.cr -- --compiler "$(CRYSTAL)"

test: helper
	$(CRYSTAL) spec --no-color --error-on-warnings

format:
	$(CRYSTAL) tool format --check src spec scripts examples native

check: format test
