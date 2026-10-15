.PHONY: all test lint fmt doc check-doc clean

all: fmt doc test

# The suites reuse an existing lazy.nvim install for their dependencies and clone into
# tests/.deps otherwise, so this needs no deps target of its own.
test:
	@LC_ALL=C ./tests/run_tests.sh

# No stylua.toml on purpose: the tree is formatted to stylua's defaults, and adding a config with
# any other setting would reformat all of it.
lint:
	@stylua --check lua/ plugin/ tests/

fmt:
	@stylua lua/ plugin/ tests/

# LC_ALL=C: panvimdoc's Lua filter uppercases headings with string.upper, which is byte-based —
# under a UTF-8 locale glibc's toupper() mangles multi-byte characters like em dashes one byte at
# a time. The C locale's toupper() only touches ASCII, so UTF-8 sequences pass through untouched.
doc: .deps/panvimdoc
	@mkdir -p doc
	@LC_ALL=C pandoc \
		--metadata="project:ducktape" \
		--metadata="vimversion:NVIM v0.11" \
		--metadata="titledatepattern:%Y %B %d" \
		--metadata="toc:true" \
		--metadata="incrementheadinglevelby:0" \
		--metadata="treesitter:true" \
		--metadata="dedupsubheadings:true" \
		--metadata="ignorerawblocks:true" \
		--metadata="docmapping:false" \
		--lua-filter .deps/panvimdoc/scripts/include-files.lua \
		--lua-filter .deps/panvimdoc/scripts/skip-blocks.lua \
		-t .deps/panvimdoc/scripts/panvimdoc.lua \
		scripts/vimdoc.md \
		-o doc/ducktape.txt
	@$(MAKE) --no-print-directory check-doc

# Match the helptags step plugin managers run during installation; fail on duplicate tags.
check-doc:
	@nvim --headless -u NONE -c 'lua local ok, err = pcall(vim.cmd, "helptags doc"); if not ok then vim.api.nvim_err_writeln(err); vim.cmd("cquit") end' -c 'qa!'

.deps/panvimdoc:
	@mkdir -p .deps
	@git clone --filter=blob:none --depth=1 https://github.com/kdheepak/panvimdoc $@

clean:
	@rm -rf .deps tests/.deps doc/tags
