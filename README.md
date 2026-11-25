# manuscript.nvim

A LaTeX or Rnoweb (`.Rnw`) manuscript's round trip with collaborators who use Word, from Neovim:
export it to Word, bring their revisions back into your sources, and make the tracked-changes PDF
for the journal.

**This is a project under development. Please, feel free to open issues or pull requests.**

## Features

- `:Manuscript build` — while you write: the PDF of the part you're in (or of the whole), in the
  background, rebuilt incrementally (a text edit: a few seconds). Errors in the quickfix list, at
  their line in your `.Rnw`. `:Manuscript build watch` builds on each write.
- `:Manuscript export` — a Word file per part (main text, appendices) in `export/<date>/`, named
  with the date (`main_2026-11-25.docx`). `.Rnw` files are knitted part by part, with references
  between parts numbered. Citations, units, cross-references, appendices and figures are converted
  for Word. Nothing is left in your folder.
- Each export is a snapshot of what you sent: the LaTeX it was made from, and the git commit.
- `:Manuscript merge` — open the last Word file of the review, wherever it is (after any number of
  rounds, tracked or not), and its edits go into your sources in a diff view, as LaTeX. Citations
  typed by collaborators are looked up in your `.bib`. Every edit and comment is listed in the
  quickfix list.
- `:Manuscript diff [part] [old] [new]` — a PDF with the changes as tracked changes (latexdiff),
  since the last export, a git revision or any file; of the whole, or of one part
  (`:Manuscript diff main`). Renamed citation keys don't show as changes.

No keymaps are set. See `:help manuscript`.

## Requirements

- Neovim 0.10+
- [neoffice.nvim](https://github.com/urtzienriquez/neoffice.nvim) (to read Word files)
- [pandoc](https://pandoc.org)
- For `.Rnw` files: R with [knitrmini](https://github.com/urtzienriquez/knitrmini) (or knitr)
- For `:Manuscript build` and `:Manuscript diff`: latexmk (and latexdiff for the diff)
- Optional: pdftocairo (poppler) for PDF figures

## Installation

```lua
vim.pack.add({
  "https://github.com/urtzienriquez/neoffice.nvim",
  "https://github.com/urtzienriquez/manuscript.nvim",
})
```

No `setup()` needed. Optional (these are the defaults):

```lua
require("manuscript").setup({
  export_dir = "export", -- in the manuscript's folder
  csl = nil, -- a .csl in the manuscript's folder, or the bundled one
  move_figures = false, -- figures at the end of each Word file
  move_tables = false,
})
```

A manuscript can have its own options in a `.manuscript.lua` that returns a table of the same keys.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
