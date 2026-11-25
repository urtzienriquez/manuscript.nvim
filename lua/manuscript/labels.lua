-- The numbers of references to other parts, in a part built alone: its \ref{x} to labels it doesn't
-- define get their numbers from the whole's last build (its .aux, and those of its \include{}s), as
-- knitrmini's label snapshot does for .Rnw.
local project_ = require("manuscript.project")
local M = {}

-- The labels in a build's .aux (and the .aux files it reads): { [label] = { num, page } }.
function M.read(aux, labels, depth)
  labels, depth = labels or {}, depth or 0
  local dir = vim.fs.dirname(aux)
  for line in (project_.read(aux) or ""):gmatch("[^\n]+") do
    local label, value = line:match("^\\newlabel{([^}]+)}(%b{})")
    if label and not label:match("@cref$") then
      local inner = value:sub(2, -2)
      local num, page = inner:match("^(%b{})(%b{})")
      num = num or inner:match("^(%b{})")
      if num then
        labels[label] = { num = num:sub(2, -2), page = page and page:sub(2, -2) }
      end
    end
    local other = line:match("^\\@input{([^}]+)}")
    if other and depth < 10 then
      M.read(vim.fs.joinpath(dir, other), labels, depth + 1)
    end
  end
  return labels
end

-- LaTeX with its references to labels it doesn't define (\ref, \ref*, \eqref, \pageref) replaced by
-- their numbers in `labels`; the others stay.
function M.resolve(tex, labels)
  local own = {} -- (the labels it defines: not those in its comments)
  for label in require("manuscript.latex").strip_comments(tex):gmatch("\\label%s*{([^}]+)}") do
    own[label] = true
  end
  local function number(cmd, label, star)
    local l = not own[label] and labels[label]
    if not l then
      return nil
    end
    if cmd == "eqref" then
      return "(" .. l.num .. ")"
    elseif cmd == "pageref" then
      return l.page
    end
    return l.num
  end
  for _, cmd in ipairs({ "ref", "eqref", "pageref" }) do -- (each by its name: inside \textbf{...} too)
    tex = tex:gsub("\\" .. cmd .. "(%*?)%s*{([^}]+)}", function(star, label)
      return number(cmd, label, star)
    end)
  end
  return tex
end

-- The labels of the whole's last build (the snapshot): .build/<root>-labels.aux, \newlabel lines as
-- knitrmini's and Knit.jl's (which read it, copied beside a part's copy of the root).
function M.snapshot(project)
  return vim.fs.joinpath(project.dir, ".build", project.name .. "-labels.aux")
end

-- Writes the snapshot from a whole's build (its .aux, and those of its \include{}s).
function M.write_snapshot(project, aux)
  local lines = {}
  for line in (project_.read(aux) or ""):gmatch("[^\n]+") do
    if line:match("^\\newlabel{") then
      lines[#lines + 1] = line
    end
  end
  local dir = vim.fs.dirname(aux) -- (an \include{}'s .aux: \@input{part.aux})
  for other in (project_.read(aux) or ""):gmatch("\\@input{([^}]+)}") do
    for line in (project_.read(vim.fs.joinpath(dir, other)) or ""):gmatch("[^\n]+") do
      if line:match("^\\newlabel{") then
        lines[#lines + 1] = line
      end
    end
  end
  if #lines > 0 then
    vim.fn.mkdir(vim.fs.dirname(M.snapshot(project)), "p")
    vim.fn.writefile(lines, M.snapshot(project))
  end
end

-- What a part refers to outside itself, in its sources (`texts`, comments out): whether it does
-- (a \ref, \eqref... to a label it doesn't define: \label{}, or a chunk's fig:/tab:<label>), and
-- whether by page (\pageref).
function M.refers_outside(texts)
  local strip = require("manuscript.latex").strip_comments
  local defined, refs, pages = {}, {}, false
  for _, text in ipairs(texts) do
    text = strip(text)
    for label in text:gmatch("\\label%s*{([^}]+)}") do
      defined[label] = true
    end
    for chunk in text:gmatch("<<%s*([^,>=%s]+)") do -- (a chunk's figure and table: fig:<label>, tab:<label>)
      defined["fig:" .. chunk], defined["tab:" .. chunk] = true, true
    end
    for chunk in text:gmatch("```+%s*{%a+%s+([^,}=%s]+)") do
      defined["fig:" .. chunk], defined["tab:" .. chunk] = true, true
    end
    for cmd, list in text:gmatch("\\(%a*ref)%*?%s*{([^}]+)}") do
      if cmd:match("ref$") then
        pages = pages or cmd == "pageref"
        for label in list:gmatch("[^,%s]+") do
          refs[#refs + 1] = label
        end
      end
    end
  end
  local outside = vim.tbl_filter(function(l) return not defined[l] end, refs)
  return #outside > 0, pages
end

-- Whether the labels a part's references can point to (`before` and `after`: M.read's, of the
-- whole; `own`: those the part defines) changed: their numbers, or (pages) their pages.
function M.changed(before, after, own, pages)
  for label, a in pairs(after) do
    if not own[label] then
      local b = before[label]
      if not b or b.num ~= a.num or (pages and b.page ~= a.page) then
        return true
      end
    end
  end
  for label in pairs(before) do
    if not own[label] and not after[label] then
      return true
    end
  end
  return false
end

-- Resolves them in a file, with the labels of the whole's build (`aux`).
function M.resolve_file(path, aux)
  if not vim.uv.fs_stat(aux) then
    return
  end
  local text = project_.read(path) or ""
  local resolved = M.resolve(text, M.read(aux))
  if resolved ~= text then
    local f = assert(io.open(path, "wb"))
    f:write(resolved)
    f:close()
  end
end

return M
