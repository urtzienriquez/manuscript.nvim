-- Variants: versions of the same sources, as a set of LaTeX switches (\ifanonymous, \iflinenumbers...)
-- that a build turns on. Each is a name: `anon`, `review`, `draft`, and a manuscript's own in its
-- .manuscript.lua (`variants = { geb = { anonymous = true, linenumbers = true } }`, which may also
-- redefine these). Every build defines every switch (off, but for its variant's), before its
-- source is read: a template's preamble uses them, with a guard for builds made otherwise:
--
--   \ifcsname ifanonymous\endcsname\else\expandafter\newif\csname ifanonymous\endcsname\fi
--
-- (built with \csname: a skipped `\ifanonymous` would count as an \if, and break the \fi's).
local M = {}

-- The switches every build defines, those of no variant included: what the templates use.
-- (\ifdraftversion, not \ifdraft: the ifdraft package's.)
M.SWITCHES = { "anonymous", "draftversion", "linenumbers", "doublespacing", "figuresatend" }

M.BUILTIN = {
  anon = { anonymous = true }, -- (for review: no authors, no acknowledgements)
  review = { linenumbers = true, doublespacing = true },
  draft = { draftversion = true, linenumbers = true },
}

-- All the variants of a manuscript: { [name] = { [switch] = true|false, ... other keys } }.
function M.all(project)
  return vim.tbl_extend("force", vim.deepcopy(M.BUILTIN), (project.options or {}).variants or {})
end

-- Their names, sorted.
function M.names(project)
  local names = vim.tbl_keys(M.all(project))
  table.sort(names)
  return names
end

-- The switches a variant turns on or off (its boolean keys); fails on a name TeX can't take.
function M.switches(variant)
  local out = {}
  for key, value in pairs(variant or {}) do
    if type(value) == "boolean" then
      if not key:match("^%a+$") then
        error(("a variant's switch must be letters only (\\if%s can't be)"):format(key), 0)
      end
      out[key] = value
    end
  end
  return out
end

-- Every switch a build defines (the templates', and each variant's), with its value in variant
-- `name` (nil: none): { [switch] = true|false }.
function M.values(project, name)
  local all = M.all(project)
  local variant = name and all[name]
  if name and not variant then
    error(("no variant %s (the variants: %s)"):format(name, table.concat(M.names(project), ", ")), 0)
  end
  local out = {}
  for _, s in ipairs(M.SWITCHES) do
    out[s] = false
  end
  for _, v in pairs(all) do
    for s in pairs(M.switches(v)) do
      out[s] = false
    end
  end
  for s, value in pairs(M.switches(variant)) do
    out[s] = value
  end
  return out
end

-- What a build runs before its source (latexmk's -usepretex): every switch defined, those of
-- `name` turned on, and \manuscriptvariant (the variant's name; empty for none). nil name: none.
function M.pretex(project, name)
  local values = M.values(project, name)
  local names = vim.tbl_keys(values)
  table.sort(names)
  local on = values
  local out = {}
  for _, s in ipairs(names) do
    out[#out + 1] = ("\\newif\\if%s"):format(s)
    if on[s] then
      out[#out + 1] = ("\\%strue"):format(s)
    end
  end
  out[#out + 1] = ("\\def\\manuscriptvariant{%s}"):format(name or "")
  if on.anonymous then -- (and nothing of who made it in the PDF: hyperref's author, the paths of figures)
    out[#out + 1] = "\\AtBeginDocument{\\ifdefined\\hypersetup\\hypersetup{pdfauthor={},pdfcreator={},pdfproducer={}}\\fi}"
      .. "\\ifdefined\\pdfsuppressptexinfo\\pdfsuppressptexinfo=-1\\fi"
      .. "\\ifdefined\\pdfvariable\\pdfvariable suppressoptionalinfo 1023\\fi"
  end
  return table.concat(out)
end

return M
