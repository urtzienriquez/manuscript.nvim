-- :Manuscript merge into R Markdown: a revised document's edits made in the .Rmd, in Markdown, and
-- only those (the same as into LaTeX: see merge_spec.lua).
local H = dofile("tests/helpers.lua")
local merge = require("manuscript.merge")
local project = require("manuscript.project")
project.memory = vim.fn.tempname() .. ".json" -- (the manuscripts merged into: not the user's)
local api = vim.api

local BIB = [[
@article{smith2020, author = {Smith, A. and Lee, B. and Kim, C.}, year = {2020} }
@article{jones2019, author = {Jones, D.}, year = {2019} }
@article{brown2018, author = {Brown, E. and Green, F.}, year = {2018} }
@article{martinez2021, author = {Mart{\'\i}nez-Fre{\'\i}ria, F. and Santos, X. and Brito, J.}, date = {2021-03} }
]]

local SOURCE = [[
---
title: "A paper"
bibliography: refs.bib
---

```{r setup, include=FALSE}
rise <- function() 12
```

# Introduction

We studied *Vipera aspis* in the north of Iberia
[@smith2020; @jones2019]. <!-- (wrapped as I like it) -->
Warming raised its water loss by `r rise()` percent.

A second paragraph, with **bold words** and \textbf{raw ones} in it.

@smith2020 found the same in the south.
]]

local DOCUMENT = {
  "# Introduction",
  "",
  "We studied *Vipera aspis* in the north of Iberia (Smith et al., 2020; Jones, 2019). Warming raised its water loss by 12 percent.",
  "",
  "A second paragraph, with **bold words** and **raw ones** in it.",
  "",
  "Smith et al. (2020) found the same in the south.",
}

-- The source, its .bib, and the document it was exported to, opened with tracking on: the source's
-- path.
local function setup(source)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for name, text in pairs({ ["main.Rmd"] = source or SOURCE, ["refs.bib"] = BIB }) do
    local f = assert(io.open(dir .. "/" .. name, "w"))
    f:write(text)
    f:close()
  end
  H.open(dir .. "/main.docx")
  api.nvim_buf_set_lines(0, 0, -1, false, DOCUMENT)
  H.save()
  H.open(dir .. "/main.docx")
  vim.cmd("Neoffice track on")
  return dir .. "/main.Rmd"
end

-- The proposal, the notes, and the edits.
local function run(path)
  local out, issues = merge.compute(api.nvim_get_current_buf(), { path })
  local notes, edits = {}, {}
  for _, i in ipairs(issues) do
    table.insert(i.user_data == "edit" and edits or notes, i.text)
  end
  return out[path], notes, edits
end

local function has(list, text)
  return vim.iter(list):any(function(t) return t:find(text, 1, true) ~= nil end)
end

describe(":Manuscript merge into R Markdown", function()
  it("changes nothing when nothing changed: its YAML header, chunks, comments as they are", function()
    local path = setup()
    local out, notes, edits = run(path)
    assert.equals(SOURCE, out)
    assert.same({}, notes)
    assert.same({}, edits)
  end)

  it("changes only the words edited, keeping the wrapping, comments, citations and values", function()
    local path = setup()
    H.replace(2, "north", "south")
    H.replace(3, "second", "last")
    local out, _, edits = run(path)
    assert.equals(SOURCE:gsub("north of", "south of"):gsub("second", "last"), out)
    assert.same({ "change: north → south", "change: second → last" }, edits)
  end)

  it("edits a heading", function()
    local path = setup()
    H.replace(1, "Introduction", "Background")
    local out = run(path)
    assert.equals(SOURCE:gsub("# Introduction", "# Background"), out)
  end)

  it("writes typed formatting in Markdown, inside formatting of its own and raw LaTeX too", function()
    local path = setup()
    H.replace(2, "We studied", "We *carefully* studied")
    H.replace(2, "the north", "the **far** north")
    H.replace(3, "bold words", "bold, new words")
    H.replace(3, "raw ones", "raw old ones")
    local out = run(path)
    assert.truthy(out:find("We *carefully* studied *Vipera aspis* in the **far** north of Iberia\n", 1, true), out)
    assert.truthy(out:find("with **bold, new words** and \\textbf{raw old ones} in it.", 1, true), out)
  end)

  it("rebuilds a citation from which a reference was removed, keeps a narrative one", function()
    local path = setup()
    H.replace(2, "; Jones, 2019", "")
    H.replace(4, "the south", "the far south")
    local out, notes = run(path)
    assert.equals(SOURCE:gsub("%[@smith2020; @jones2019%]", "[@smith2020]"):gsub("in the south", "in the far south"), out)
    assert.same({}, notes)
  end)

  it("looks up typed citations in the .bib (its YAML header's), and lists those it can't find", function()
    local path = setup()
    H.replace(3, "in it.", "in it (Brown & Green, 2018; Martínez-Freiría et al., 2021).")
    local out = run(path)
    assert.truthy(out:find("in it [@brown2018; @martinez2021].", 1, true), out)
    setup()
    H.replace(3, "in it.", "in it (Nobody, 1999).")
    local _, notes = run(path)
    assert.truthy(has(notes, "citation not found in the .bib: Nobody 1999"))
  end)

  it("keeps a computed value (`r ...`) edited in the document, and says so", function()
    local path = setup()
    H.replace(2, "by 12 percent", "by 15 percent")
    local out, notes = run(path)
    assert.equals(SOURCE, out)
    assert.truthy(has(notes, "a computed value changed in the document: the source keeps it (`r rise()`)"))
  end)

  it("escapes what Markdown would read otherwise, and writes a new paragraph in Markdown", function()
    local path = setup()
    H.replace(3, "in it.", "in it, 5\\*3 [sic] for user_id.") -- (in neoffice, a literal * is \*)
    local r = H.row(3)
    api.nvim_buf_set_lines(0, r, r, false, { "", "A *new* paragraph, added here." })
    require("neoffice.changes").after_edit(api.nvim_get_current_buf())
    local out, notes = run(path)
    assert.truthy(out:find("in it, 5\\*3 \\[sic\\] for user\\_id.", 1, true), out)
    assert.truthy(out:find("\n\nA *new* paragraph, added here.", 1, true), out)
    assert.truthy(has(notes, "new paragraph after this one"))
  end)
end)
