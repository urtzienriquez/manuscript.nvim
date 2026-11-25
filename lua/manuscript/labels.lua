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
  local own = {}
  for label in tex:gmatch("\\label%s*{([^}]+)}") do
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
