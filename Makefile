.PHONY: helper test format check

helper:
	crystal run scripts/build-helper.cr

test: helper
	crystal spec --no-color --error-on-warnings

format:
	crystal tool format --check src spec scripts examples

check: format test
