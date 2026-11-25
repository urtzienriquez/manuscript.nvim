-- A manuscript: its root (the file that is compiled, with \begin{document}), the folder it is in,
-- its parts (each child='...' of an .Rnw root: 2_main.Rnw is "main"; a .tex root is one part),
-- its .bib files, its git repository and its options.
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

local function is_root(text)
  return text:find("\\begin%s*{document}") ~= nil
end

local function rnw(path)
  return path:match("%.[Rr]nw$") ~= nil
end

-- The root of the manuscript `path` (a file or a folder) belongs to: the one a "% !TeX root = ..."
-- line names, the file itself if it is a root, or the one root in its folder (an .Rnw first: a
-- .tex beside it is its knitted output).
function M.root(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("/$", "")
  local is_dir = vim.fn.isdirectory(path) == 1
  local dir = is_dir and path or vim.fs.dirname(path)
  if not is_dir and (rnw(path) or path:match("%.tex$")) then
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
    if is_root(text) then
      return path
    end
  end
  for _, pattern in ipairs({ "%.[Rr]nw$", "%.tex$" }) do
    local found = {}
    for name, kind in vim.fs.dir(dir) do
      local file = vim.fs.joinpath(dir, name)
      local knitted = pattern == "%.tex$" and (vim.uv.fs_stat((file:gsub("%.tex$", ".Rnw"))) or vim.uv.fs_stat((file:gsub("%.tex$", ".rnw"))))
      if kind == "file" and name:match(pattern) and not name:match("^%.") and not knitted and is_root(M.read(file) or "") then
        found[#found + 1] = file
      end
    end
    if #found == 1 then
      return found[1]
    elseif #found > 1 then
      return nil, "several manuscripts in " .. dir .. ": " .. table.concat(vim.tbl_map(vim.fs.basename, found), ", ")
    end
  end
  return nil, "no manuscript (a file with \\begin{document}) in " .. dir
end

-- Its parts, in order: { name, file }. An .Rnw root's children (<<child='2_main.Rnw'>>= is "main");
-- else the root alone.
function M.parts(root)
  local parts = {}
  if rnw(root) then
    for line in (M.read(root) or ""):gmatch("[^\n]+") do
      local child = line:match("^%s*<<.*child%s*=%s*['\"]([^'\"]+)['\"].*>>=")
      if child then
        local name = vim.fs.basename(child):gsub("%.[^.]+$", ""):gsub("^%d+[_-]", "")
        parts[#parts + 1] = { name = name, file = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(root), child)) }
      end
    end
  end
  if #parts == 0 then
    parts[1] = { name = (vim.fs.basename(root):gsub("%.[^.]+$", "")), file = root }
  end
  return parts
end

-- The .bib files of LaTeX text (\addbibresource, \bibliography), as absolute paths.
function M.bibs(text, dir)
  local out = {}
  local function add(name)
    name = vim.trim(name)
    if name ~= "" then
      name = name:match("%.bib$") and name or name .. ".bib"
      out[#out + 1] = vim.fs.normalize(vim.fs.joinpath(dir, name))
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
-- folder): { root, dir, name, rnw, parts, bibs, git, options }. Errors when there is none.
function M.find(path)
  path = path or (vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) ~= "" and vim.api.nvim_buf_get_name(0)) or vim.fn.getcwd()
  local root, err = M.root(path)
  if not root or not vim.uv.fs_stat(root) then
    error({ msg = err or ("the root " .. tostring(root) .. " doesn't exist") })
  end
  local dir = vim.fs.dirname(root)
  local project = { root = root, dir = dir, name = (vim.fs.basename(root):gsub("%.[^.]+$", "")), rnw = rnw(root) }
  project.parts = M.parts(root)
  local text = M.read(root) or ""
  for _, part in ipairs(project.parts) do
    text = text .. "\n" .. (part.file ~= root and M.read(part.file) or "")
  end
  project.bibs = vim.tbl_filter(function(p) return vim.uv.fs_stat(p) ~= nil end, M.bibs(text, dir))
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
