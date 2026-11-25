-- A manuscript: its root (the file that is compiled: a .tex, .Rnw or .jnw with \begin{document}, or
-- an .Rmd with a YAML header), the folder it is in, its parts (each child chunk of an .Rnw, .jnw or
-- .Rmd root: 2_main.Rnw is "main"; each \include{} of a .tex root; else the root alone), all its files
-- (the parts and every \input/\include in them), its .bib files, git repository and options.
local M = {}

function M.read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

-- Its kind, by its name: "rnw" (Rnoweb), "jnw" (Noweb with Julia: Knit.jl), "rmd" or "tex" (nil:
-- none of them).
function M.kind(path)
  return path:match("%.[Rr]nw$") and "rnw" or path:match("%.[Jj]nw$") and "jnw" or path:match("%.[Rr]md$") and "rmd"
    or path:match("%.tex$") and "tex" or nil
end

local function is_root(text, kind)
  if kind == "rmd" then
    return text:match("^%-%-%-%s*\n") ~= nil
  end
  return text:find("\\begin%s*{document}") ~= nil
end

-- LaTeX without its comments (% to the end of the line, but not \%).
local function uncommented(text)
  return (text:gsub("[^\n]*", function(line)
    local p = 1
    while true do
      local c = line:find("%", p, true)
      if not c then
        return line
      end
      local slashes = #(line:sub(1, c - 1):match("\\*$"))
      if slashes % 2 == 0 then
        return line:sub(1, c - 1)
      end
      p = c + 1
    end
  end))
end

-- The child chunk of a chunk header line: <<..., child='x.Rnw'>>= or ```{r ..., child="x.Rmd"}.
local function child_of(line)
  local options = line:match("^%s*<<(.*)>>=%s*$") or line:match("^%s*```+%s*{%s*[rR][%s,](.*)}%s*$")
  return options and options:match("child%s*=%s*['\"]([^'\"]+)['\"]"), options
end
M.child_of = child_of

-- What a file of kind `kind` includes, in order: { name (as written), how ("child", "input",
-- "include"), body (after \begin{document}) }.
local function includes(text, kind)
  local out = {}
  if kind ~= "tex" then
    for at, line in text:gmatch("()([^\n]+)") do
      local child = child_of(line)
      if child then
        out[#out + 1] = { name = child, how = "child", body = true, at = at }
      end
    end
  end
  local latex = kind == "rmd" and text or uncommented(text)
  local body_at = latex:find("\\begin%s*{document}") or (kind == "tex" and math.huge or 0)
  local p = 1
  while true do
    local a, b, how, name = latex:find("\\(%a+)%s*{([^}]+)}", p)
    if not a then
      break
    end
    if how == "input" or how == "include" then
      out[#out + 1] = { name = vim.trim(name), how = how, body = a > body_at, at = a }
    end
    p = b + 1
  end
  table.sort(out, function(x, y) return x.at < y.at end) -- (in the order they are written)
  return out
end

-- A name (relative to `dir`, absolute, or with ~) as an absolute path.
local function at(dir, name)
  name = vim.fn.expand(name)
  return vim.fs.normalize(name:sub(1, 1) == "/" and name or vim.fs.joinpath(dir, name))
end

M.includes = includes

-- The file an inclusion names (relative to the root's folder, as LaTeX and knitr look for them),
-- or nil if there's none.
local function resolve(name, dir, how)
  local path = at(dir, name)
  if how ~= "child" and not path:match("%.%w+$") then
    path = path .. ".tex"
  end
  local st = vim.uv.fs_stat(path)
  return st and st.type == "file" and path or nil
end

-- All the files of the manuscript `root`: the root first, then everything it includes (child
-- chunks, \input, \include), recursively, in order. dir: where names are relative to (the root's
-- folder; given when `root` is a part of it).
function M.files(root, dir)
  local seen, out = {}, {}
  dir = dir or vim.fs.dirname(root)
  local function walk(path, depth)
    if seen[path] or depth > 20 then
      return
    end
    seen[path] = true
    out[#out + 1] = path
    local kind = M.kind(path) or "tex"
    for _, inc in ipairs(includes(M.read(path) or "", kind)) do
      local file = resolve(inc.name, dir, inc.how)
      if file and M.kind(file) then
        walk(file, depth + 1)
      end
    end
  end
  walk(root, 0)
  return out
end

-- The roots in a folder: .Rnw and .Rmd files that are roots, and .tex roots that aren't the knitted
-- output of one of those (main.tex beside main.Rnw).
local function roots_in(dir)
  local found = {}
  for name, kind in vim.fs.dir(dir) do
    local file = vim.fs.joinpath(dir, name)
    local k = M.kind(name)
    local knitted = k == "tex" and vim.iter({ ".Rnw", ".rnw", ".Rmd", ".rmd", ".jnw", ".Jnw" }):any(function(ext)
      return vim.uv.fs_stat((file:gsub("%.tex$", ext))) ~= nil
    end)
    if kind == "file" and k and not name:match("^[._]") and not knitted and is_root(M.read(file) or "", k) then
      found[#found + 1] = file
    end
  end
  table.sort(found)
  return found
end

-- The root of the manuscript `path` (a file or a folder) belongs to: the one a "% !TeX root = ..."
-- line names, the file itself if it is a root, the root in its folder that includes it, or the one
-- root in its folder (an .Rnw or .Rmd first: a .tex beside it is its knitted output).
function M.root(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("/$", "")
  local is_dir = vim.fn.isdirectory(path) == 1
  local dir = is_dir and path or vim.fs.dirname(path)
  local kind = not is_dir and M.kind(path)
  if kind then
    local text = M.read(path) or ""
    local n = 0
    for line in text:gmatch("[^\n]*") do
      local named = line:match("^%%%s*!%a+%s*root%s*=%s*(%S+)")
      if named then
        local root = vim.fs.normalize(vim.fs.joinpath(dir, named))
        if not vim.uv.fs_stat(root) then
          return nil, ("%s says its root is %s (%% !TeX root), but there's no %s in %s"):format(
            vim.fs.basename(path), named, named, vim.fn.fnamemodify(vim.fs.dirname(root), ":~"))
        end
        return root
      end
      n = n + 1
      if n > 10 then
        break
      end
    end
    if is_root(text, kind) then
      return path
    end
  end
  local found = roots_in(dir)
  -- (a title page, a cover letter, a response to reviewers beside the manuscript: documents of
  -- their own, for :Manuscript submit; not its root, though they \input{} its preamble)
  local companion = { title_page = true, cover_letter = true, response = true }
  local main = vim.tbl_filter(function(f) return not companion[vim.fs.basename(f):gsub("%.[^.]+$", "")] end, found)
  if #main > 0 then
    found = main
  end
  local function including(roots)
    local these = vim.tbl_filter(function(root) return vim.tbl_contains(M.files(root), path) end, roots)
    return #these == 1 and these[1] or nil
  end
  if kind and #found > 1 and including(found) then -- (the one that includes it)
    return including(found)
  end
  if kind and #found == 0 then -- (a file in a folder of the manuscript's: sections/methods.tex)
    local up = dir
    for _ = 1, 3 do
      up = vim.fs.dirname(up)
      local root = including(roots_in(up))
      if root then
        return root
      end
    end
  end
  for _, group in ipairs({ { "rnw", "rmd", "jnw" }, { "tex" } }) do
    local these = vim.tbl_filter(function(f) return vim.tbl_contains(group, M.kind(f)) end, found)
    if #these == 1 then
      return these[1]
    elseif #these > 1 then
      return nil, "several manuscripts in " .. dir .. ": " .. table.concat(vim.tbl_map(vim.fs.basename, these), ", ")
    end
  end
  return nil, "no manuscript (a file with \\begin{document}, or an .Rmd with a YAML header) in " .. dir
end

-- Whether a .tex root's body has text of its own, besides its \include{}s (and commands that show
-- no text of the author's: \maketitle, the bibliography...).
local NO_TEXT = { maketitle = true, tableofcontents = true, printbibliography = true, bibliography = true,
  bibliographystyle = true, clearpage = true, newpage = true, cleardoublepage = true, appendix = true,
  include = true, includeonly = true, label = true, pagebreak = true, noindent = true }
-- Whether LaTeX shows text of its own (anything but those commands).
function M.shows_text(body)
  body = uncommented(body)
  local p = 1
  while true do
    local a, b, name = body:find("\\(%a+)%*?", p)
    if not a then
      break
    end
    if NO_TEXT[name] then -- (it and its arguments go)
      local e = b + 1
      while true do
        local s1, e1 = body:find("^%s*%b[]", e)
        local s2, e2 = body:find("^%s*%b{}", e)
        if not (s1 or s2) then
          break
        end
        e = (e1 or e2) + 1
      end
      body = body:sub(1, a - 1) .. " " .. body:sub(e)
      p = a + 1
    else
      p = b + 1
    end
  end
  return body:find("%S") ~= nil
end

local function own_text(text)
  return M.shows_text(uncommented(text):match("\\begin%s*{document}(.-)\\end%s*{document}") or "")
end

-- Its parts, in order: { name, file }. An .Rnw or .Rmd root's child chunks (2_main.Rnw is "main"),
-- a .tex root's \include{}s (and the root itself, "main", if it has text of its own besides them);
-- else the root alone.
function M.parts(root)
  local parts = {}
  local kind = M.kind(root) or "tex"
  local dir = vim.fs.dirname(root)
  for _, inc in ipairs(includes(M.read(root) or "", kind)) do
    if (kind == "tex" and inc.how == "include" and inc.body) or (kind ~= "tex" and inc.how == "child") then
      local file = resolve(inc.name, dir, inc.how)
      if file or inc.how == "child" then
        local name = vim.fs.basename(inc.name):gsub("%.[^.]+$", ""):gsub("^%d+[_-]", "")
        parts[#parts + 1] = { name = name, file = file or vim.fs.normalize(vim.fs.joinpath(dir, inc.name)) }
      end
    end
  end
  if kind == "tex" and #parts > 0 and own_text(M.read(root) or "") then -- (its own text: a part too)
    local taken = vim.tbl_map(function(p) return p.name end, parts)
    local name = vim.tbl_contains(taken, "main") and (vim.fs.basename(root):gsub("%.[^.]+$", "") .. "-main") or "main"
    table.insert(parts, 1, { name = name, file = root })
  end
  if #parts == 0 then
    parts[1] = { name = (vim.fs.basename(root):gsub("%.[^.]+$", "")), file = root }
  end
  return parts
end

-- LaTeX with its \input{}s and \include{}s replaced by the files' text (relative to `dir`), so that
-- it can be read elsewhere (pandoc, latexdiff). Those in comments, of missing files and of files
-- that aren't .tex (an .Rnw named for texlab's sake, say) stay.
function M.flatten(text, dir, depth)
  depth = depth or 0
  if depth > 20 then
    return text
  end
  return (text:gsub("[^\n]*", function(line)
    local code = uncommented(line)
    local rest = line:sub(#code + 1)
    code = code:gsub("\\(%a+)(%s*){([^}]+)}", function(how, space, name)
      if how ~= "input" and how ~= "include" then
        return nil
      end
      local file = resolve(vim.trim(name), dir, how)
      local inner = file and file:match("%.tex$") and M.read(file) -- (an .Rnw's is not LaTeX yet)
      if not inner then
        return nil
      end
      inner = M.flatten(inner, dir, depth + 1)
      return how == "include" and ("\\clearpage\n" .. inner .. "\n\\clearpage") or inner
    end)
    return code .. rest
  end))
end

-- The .bib files an .Rmd's YAML header names (bibliography: a.bib, or a list).
local function yaml_bibs(text)
  local header = text:match("^%-%-%-%s*\n(.-)\n%-%-%-") or text:match("^%-%-%-%s*\n(.-)\n%.%.%.") or ""
  local out = {}
  local value, rest = header:match("\nbibliography:([^\n]*)(.*)")
  if not value then
    value, rest = header:match("^bibliography:([^\n]*)(.*)")
  end
  if not value then
    return out
  end
  local function add(name)
    name = vim.trim(name):gsub("^['\"]", ""):gsub("['\"]$", "")
    if name ~= "" then
      out[#out + 1] = name
    end
  end
  value = vim.trim(value)
  if value:match("^%[") then
    for name in value:sub(2, -2):gmatch("[^,]+") do
      add(name)
    end
  elseif value ~= "" then
    add(value)
  else
    for line in (rest .. "\n"):gmatch("([^\n]*)\n") do
      local item = line:match("^%s+%-%s*(.+)$")
      if item then
        add(item)
      elseif line:match("^%S") then
        break
      end
    end
  end
  return out
end

-- The .bib files of LaTeX text (\addbibresource, \bibliography), as absolute paths.
function M.bibs(text, dir)
  local out = {}
  local function add(name)
    name = vim.trim(name)
    if name ~= "" then
      name = name:match("%.bib$") and name or name .. ".bib"
      out[#out + 1] = at(dir, name)
    end
  end
  for name in text:gmatch("\\addbibresource%s*%b[]%s*{([^}]+)}") do
    add(name)
  end
  for name in text:gmatch("\\addbibresource%s*{([^}]+)}") do
    add(name)
  end
  for list in text:gmatch("\\bibliography%s*{([^}]+)}") do
    for name in list:gmatch("[^,]+") do
      add(name)
    end
  end
  for _, name in ipairs(yaml_bibs(text)) do
    out[#out + 1] = at(dir, name)
  end
  return vim.fn.uniq(vim.fn.sort(out))
end

-- The manuscripts you exported or merged into (their roots, the last first): so that a document
-- opened anywhere (in Downloads, say) finds its own (see merge.lua).
M.memory = vim.fs.joinpath(vim.fn.stdpath("state"), "manuscript-projects.json")
function M.known()
  local f = io.open(M.memory)
  local ok, list = pcall(vim.json.decode, f and f:read("*a") or "[]")
  if f then
    f:close()
  end
  return vim.tbl_filter(function(root) return type(root) == "string" and vim.uv.fs_stat(root) ~= nil end, ok and type(list) == "table" and list or {})
end
function M.remember(root)
  local list = { root }
  for _, old in ipairs(M.known()) do
    if old ~= root and #list < 50 then
      list[#list + 1] = old
    end
  end
  vim.fn.mkdir(vim.fs.dirname(M.memory), "p")
  local f = io.open(M.memory, "w")
  if f then
    f:write(vim.json.encode(list))
    f:close()
  end
end

-- The manuscript `path` belongs to (a file, a folder, or nil: the current file, else the current
-- folder): { root, dir, name, kind, parts, files, bibs, git, options }. Errors when there is none.
function M.find(path)
  path = path or (vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) ~= "" and vim.api.nvim_buf_get_name(0)) or vim.fn.getcwd()
  local root, err = M.root(path)
  if not root or not vim.uv.fs_stat(root) then
    error({ msg = err or ("the root " .. tostring(root) .. " doesn't exist") })
  end
  local dir = vim.fs.dirname(root)
  local kind = M.kind(root) or "tex"
  local project = { root = root, dir = dir, name = (vim.fs.basename(root):gsub("%.[^.]+$", "")), kind = kind }
  project.parts = M.parts(root)
  project.files = M.files(root)
  local bibs = {}
  for _, file in ipairs(project.files) do -- (each file's: an .Rmd's YAML header starts its own)
    vim.list_extend(bibs, M.bibs(M.read(file) or "", dir))
  end
  project.bibs = vim.tbl_filter(function(p) return vim.uv.fs_stat(p) ~= nil end, vim.fn.uniq(vim.fn.sort(bibs)))
  if #project.bibs == 0 then
    project.bibs = vim.tbl_map(function(name) return vim.fs.joinpath(dir, name) end,
      vim.tbl_filter(function(name) return name:match("%.bib$") end, vim.fn.readdir(dir)))
  end
  local git = vim.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, { text = true }):wait()
  project.git = git.code == 0 and vim.trim(git.stdout) or nil
  project.options = require("manuscript").options(dir)
  return project
end

return M
