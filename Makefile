EMACS ?= emacs
UV ?= uv
# Directory with package-lint.el; lint skips package-lint when it is empty.
PACKAGE_LINT_DIR ?= $(firstword $(wildcard $(HOME)/.emacs.d/straight/build/package-lint $(HOME)/.emacs.d/elpa/package-lint-*))

ELS = codec.el
BATCH = $(EMACS) -Q --batch -L .

.PHONY: all deps model test test-elisp test-python compile lint clean

all: lint test

## Install the listener's Python packages into listener/.venv.
deps:
	$(UV) sync --project listener --frozen

## Download the default Whisper model (needs network once).
model: deps
	$(UV) run --project listener --frozen python listener/codec_listener.py --download-only

test: test-elisp test-python

test-elisp: compile
	$(BATCH) -l test/codec-test.el -f ert-run-tests-batch-and-exit

test-python:
	$(UV) run --project listener --frozen pytest -q listener

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(ELS)

lint: compile
	@out=$$($(BATCH) --eval '(dolist (f command-line-args-left) (checkdoc-file f))' $(ELS) 2>&1); \
	  if [ -n "$$out" ]; then echo "$$out"; exit 1; fi; echo "checkdoc: clean"
ifneq ($(PACKAGE_LINT_DIR),)
	$(BATCH) -L $(PACKAGE_LINT_DIR) --eval '(require (quote package-lint))' \
	  --eval '(setq package-lint-main-file "codec.el")' \
	  -f package-lint-batch-and-exit $(ELS)
else
	@echo "package-lint: not installed, skipped (set PACKAGE_LINT_DIR)"
endif

clean:
	rm -f *.elc
