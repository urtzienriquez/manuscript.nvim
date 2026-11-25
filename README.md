# manuscript.nvim

A LaTeX, Rnoweb (`.Rnw`), R Markdown (`.Rmd`) or jnoweb (`.jnw`, Julia) manuscript's round trip
with collaborators who use Word, from Neovim, in one file or several, all four the same way:
export it to Word, bring their revisions back into your sources, and make the tracked-changes PDF
for the journal.

**This is a project under development. Please, feel free to open issues or pull requests.**

## Features

From the first line to the publication, the same few commands for all four kinds:

- `:Manuscript new` — a new manuscript from a template (one per kind, or your own): a main text and
  an appendix, a title page, a cover letter, and the switches for anonymous and review versions.
- `:Manuscript build` — while you write: the PDF of the part you're in (or of the whole), in the
  background, rebuilt incrementally (a text edit: a few seconds). Errors in the quickfix list, at
  their line in your sources. `:Manuscript build watch` builds on each write. Standalone LaTeX
  figures (TikZ) it includes are built too, when they changed. Only the PDF goes beside your
  sources: the rest is in `.build/`.
- Variants — `:Manuscript build anon` (or `review`, `draft`, or a journal's, defined in a few lines)
  builds the same sources with LaTeX switches on: `\ifanonymous`, `\iflinenumbers`... into
  `main-anon.pdf`, beside the usual one.
- `:Manuscript export` — a Word file per part (main text, appendices) in `export/<date>/`, named
  with the date (`main_2026-11-25.docx`). `.Rnw`, `.Rmd` and `.jnw` files are knitted part by part,
  with references between parts numbered. Citations, units, cross-references, appendices and
  figures are converted for Word. Nothing is left in your folder.
- Each export is a snapshot of what you sent: the LaTeX it was made from, and the git commit.
- `:Manuscript merge` — open the last Word file of the review, wherever it is (after any number of
  rounds, tracked or not), and its edits go into your sources in a diff view. Citations
  typed by collaborators are looked up in your `.bib`. Edits are written in your sources'
  language (LaTeX, or Markdown in an `.Rmd`). Every edit and comment is listed in the quickfix
  list.
- `:Manuscript submit [variant]` — what a journal asks for, in `submission/<variant>-<date>/`: the
  main text and each appendix as PDFs, the title page and cover letter, and a zip of the LaTeX that
  compiles the main text and nothing else (knitted, flattened, comments out, only the references
  it cites, its figures). The zip is compiled on its own before it is kept. An anonymous one has
  no authors in its source at all (the switches are resolved in the text), none in its PDFs'
  metadata, and is searched for their names and emails. A resubmission has the tracked changes
  since the last one in it.
- `:Manuscript diff [part] [variant] [old] [new]` — a PDF with the changes as tracked changes
  (latexdiff), since the last export or submission (`@geb`), a git revision or any file; of the
  whole, or of one part (`:Manuscript diff main`). Renamed citation keys don't show as changes.
- `:Manuscript respond` — paste the reviewers' comments, and `response.tex` has a point for each.
- `:Manuscript archive` — the repository's code and data in one zip, for Zenodo or Dryad.

No keymaps are set. See `:help manuscript`.

## Requirements

- Neovim 0.10+
- [neoffice.nvim](https://github.com/urtzienriquez/neoffice.nvim) (to read Word files)
- [pandoc](https://pandoc.org)
- For `.Rnw` and `.Rmd` files: R with [knitrmini](https://github.com/urtzienriquez/knitrmini) (or
  knitr; rmarkdown for an `.Rmd` with an output format in its YAML header)
- For `.jnw` files: Julia with [Knit.jl](https://github.com/urtzienriquez/Knit.jl), run in a
  background Julia that starts once per project (later builds take under a second)
- For `:Manuscript build` and `:Manuscript diff`: latexmk (and latexdiff for the diff)
- For `:Manuscript submit` and `:Manuscript archive`: zip (and pdftotext, pdfinfo: poppler)
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
  figures = true, -- build the standalone LaTeX figures it includes (fig1.tex -> fig1.pdf)
})
```

A manuscript can have its own options in a `.manuscript.lua` that returns a table of the same keys.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
