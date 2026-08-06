.PHONY: all test lint fmt doc clean

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

doc: .deps/panvimdoc
	@mkdir -p doc
	@pandoc \
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

.deps/panvimdoc:
	@mkdir -p .deps
	@git clone --filter=blob:none --depth=1 https://github.com/kdheepak/panvimdoc $@

clean:
	@rm -rf .deps tests/.deps doc/tags
