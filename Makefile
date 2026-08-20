.PHONY: test lint format format-check check

test:
	./scripts/test.sh

lint:
	luacheck lua/ plugin/ tests/

format:
	stylua lua/ plugin/ tests/

format-check:
	stylua --check lua/ plugin/ tests/

check: format-check lint test
