-- manuscript.nvim: a LaTeX or Rnoweb manuscript's round trip with Word, and its tracked-changes
-- PDF. Export (knit, then Word files in export/<date>/), merge a revised Word file back into the
-- sources (see merge.lua), and diff two versions (latexdiff).
local M = {}

-- Defaults. setup() changes them; a project can too, with a `.manuscript.lua` in its folder that
-- returns a table of the same keys (see M.options).
M.config = {
  export_dir = "export", -- where exports go, in the manuscript's folder: export/<date>/
  csl = nil, -- the citation style: nil = a .csl in the manuscript's folder, or the bundled one
  reference_docx = nil, -- the Word file whose styles the export uses: nil = the bundled one
  move_figures = false, -- figures to the end of each Word file
  move_tables = false, -- tables to the end
  dpi = 200, -- PDF figures become PNG images at this resolution
  knit = nil, -- how it is knitted: "knitrmini", "knitr", "rmarkdown" (an .Rmd), "knit.jl" (a .jnw); nil:
  -- a .jnw with Knit.jl; an .Rmd with rmarkdown if its YAML header names an output format, else
  -- knitrmini; an .Rnw with knitrmini if installed, else knitr
  julia = { "julia" }, -- the command of the Julia worker that knits .jnw files (Knit.jl must be installed)
  r_worker = true, -- knitrmini in an R kept running (R and the packages a document loads, started
  -- once); false: a new R for each knit
  latex = "lualatex", -- the LaTeX engine for PDFs (builds, diffs): "lualatex", "pdflatex", "xelatex"
  build_on_save = false, -- :Manuscript build when a file of a manuscript is written
  figures = true, -- build the standalone LaTeX figures it includes (fig1.tex -> fig1.pdf) when they
  -- changed; false: never; or a list of globs of more (relative to the manuscript's folder)
  latexdiff = { "--math-markup=whole" }, -- latexdiff's options
  templates = nil, -- a folder of your templates for :Manuscript new (each a folder; they win over
  -- the plugin's by name), e.g. "~/Templates"
  identity = nil, -- more words :Manuscript submit looks for in an anonymous submission (who you are)
  variants = {}, -- your variants (see variants.lua): { name = { switch = true, ..., submit = {...} } }
  archive = nil, -- :Manuscript archive: { include = { globs }, exclude = { globs } } (relative to the repository)
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if opts and opts.build_on_save ~= nil then
    require("manuscript.build").watch(M.config.build_on_save, true)
  end
end

-- The options for a project: the defaults, setup()'s, and its folder's `.manuscript.lua`.
function M.options(dir)
  local file = vim.fs.joinpath(dir, ".manuscript.lua")
  local ok, own = false, nil
  if vim.uv.fs_stat(file) then
    ok, own = pcall(dofile, file)
    if not ok then
      vim.notify("[manuscript] " .. file .. ": " .. tostring(own), vim.log.levels.ERROR)
    end
  end
  return vim.tbl_deep_extend("force", M.config, ok and type(own) == "table" and own or {})
end

-- latexmk's option for an engine ("pdflatex" is -pdf).
function M.latexmk_flag(engine)
  return engine == "pdflatex" and "-pdf" or "-" .. engine
end

-- The plugin's own files (filters/, assets/).
function M.path(...)
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) -- (lua/manuscript)
  return vim.fs.normalize(vim.fs.joinpath(here, "..", "..", ...))
end

return M
