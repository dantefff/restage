# restage — developer convenience targets.
#
#   make lint        static analysis (shellcheck + syntax)
#   make test        run the bats test suite
#   make check       lint + test (what CI runs)
#   make install     install the bin/restage launcher to /usr/local/bin
#   make release     prepare a new semver release (interactive)
#
SHELL := /usr/bin/env bash

PREFIX ?= /usr/local

.PHONY: lint test check install release

lint:
	./scripts/lint.sh

test:
	./tests/run.sh

check: lint test

install:
	install -d "$(DESTDIR)$(PREFIX)/lib/restage"
	cp -r restage.sh bin lib flows runtime data VERSION "$(DESTDIR)$(PREFIX)/lib/restage/"
	install -d "$(DESTDIR)$(PREFIX)/bin"
	printf '#!/usr/bin/env bash\nset -o nounset\n_P="$$(readlink -f "$${BASH_SOURCE[0]}")"\nexec "$$(dirname "$$_P")/../lib/restage/restage.sh" "$$@"\n' > "$(DESTDIR)$(PREFIX)/bin/restage"
	chmod 0755 "$(DESTDIR)$(PREFIX)/bin/restage"

release:
	./scripts/release.sh
