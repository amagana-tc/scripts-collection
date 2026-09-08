SHELL := /bin/sh

# Ficheros a analizar
SH_FILES  := $(shell grep -rIl --include='*.sh' '' . 2>/dev/null)
PY_FILES  := $(shell find . -path ./.git -prune -o -name '*.py' -print 2>/dev/null)

.PHONY: help lint lint-sh lint-py install-hooks

help: ## Muestra esta ayuda
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

lint: lint-sh lint-py ## Ejecuta todos los linters

lint-sh: ## Analiza los scripts shell con shellcheck (respeta el shebang de cada fichero)
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck no está instalado"; exit 1; }
	@echo "==> shellcheck"
	@fail=0; \
	for f in $(SH_FILES); do \
		shellcheck -x "$$f" || fail=1; \
	done; \
	exit $$fail

lint-py: ## Comprueba la sintaxis de los ficheros Python
	@command -v python3 >/dev/null 2>&1 || { echo "python3 no está instalado"; exit 1; }
	@echo "==> python3 syntax check (ast)"
	@fail=0; \
	for f in $(PY_FILES); do \
		python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$$f" || fail=1; \
	done; \
	exit $$fail

install-hooks: ## Instala los hooks de pre-commit
	@command -v pre-commit >/dev/null 2>&1 || { echo "pre-commit no está instalado (pipx install pre-commit)"; exit 1; }
	pre-commit install
