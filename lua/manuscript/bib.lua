-- .bib files: their entries, read by their braces (an entry may be on one line or many).
local M = {}

-- { [key] = { type, fields = { [name] = value } } } of a .bib file's text (@comment, @string and
-- @preamble aren't entries).
function M.parse(text)
  local out = {}
  for kind, entry in text:gmatch("@(%a+)%s*(%b{})") do
    local key, body = entry:match("^{%s*([^,%s]+)%s*,(.*)}$")
    if key and not ({ comment = true, string = true, preamble = true })[kind:lower()] then
      local fields = {}
      for name, value in body:gmatch("[%s,]([%a_%-]+)%s*=%s*(%b{})") do
        fields[name:lower()] = fields[name:lower()] or value:sub(2, -2)
      end
      for name, value in body:gmatch('[%s,]([%a_%-]+)%s*=%s*"([^"]*)"') do
        fields[name:lower()] = fields[name:lower()] or value
      end
      for name, value in body:gmatch("[%s,]([%a_%-]+)%s*=%s*(%d+)") do
        fields[name:lower()] = fields[name:lower()] or value
      end
      out[key] = { type = kind:lower(), fields = fields }
    end
  end
  return out
end

function M.read(paths)
  local out = {}
  for _, path in ipairs(paths) do
    local f = io.open(path)
    if f then
      out = vim.tbl_extend("force", out, M.parse(f:read("*a")))
      f:close()
    end
  end
  return out
end

-- The keys a build cites, from its .bbl: biblatex's \entry{key}, BibTeX's \bibitem{key}, in order.
function M.cited(bbl)
  local keys, seen = {}, {}
  local function add(key)
    if not seen[key] then
      seen[key], keys[#keys + 1] = true, key
    end
  end
  for key in bbl:gmatch("\\entry{([^}]+)}") do
    add(key)
  end
  for key in bbl:gmatch("\\bibitem%s*%b[]%s*{([^}]+)}") do
    add(key)
  end
  for key in bbl:gmatch("\\bibitem%s*{([^}]+)}") do
    add(key)
  end
  return keys
end

-- A .bib file with only the entries of `keys` (and those they name in crossref, xdata or set),
-- as they are written in `paths` (the first file that has one wins), and every @string.
function M.subset(paths, keys)
  local raw, strings = {}, {}
  for _, path in ipairs(paths) do
    local f = io.open(path)
    local text = f and f:read("*a") or ""
    if f then
      f:close()
    end
    for kind, entry in text:gmatch("@(%a+)%s*(%b{})") do
      local key = entry:match("^{%s*([^,%s]+)%s*,")
      if kind:lower() == "string" then
        strings[#strings + 1] = "@" .. kind .. entry
      elseif key and not ({ comment = true, preamble = true })[kind:lower()] and not raw[key] then
        raw[key] = "@" .. kind .. entry
      end
    end
  end
  local out, seen, queue = {}, {}, vim.deepcopy(keys)
  while #queue > 0 do
    local key = table.remove(queue, 1)
    if raw[key] and not seen[key] then
      seen[key], out[#out + 1] = true, raw[key]
      local fields = (M.parse(raw[key])[key] or {}).fields or {}
      for _, name in ipairs({ "crossref", "xdata", "set" }) do
        for other in (fields[name] or ""):gmatch("[^,%s]+") do
          queue[#queue + 1] = other
        end
      end
    end
  end
  return table.concat(vim.list_extend(strings, out), "\n\n") .. (#out > 0 and "\n" or "")
end

-- Keys renamed from `old` to `new` (entries read by M.parse): the same DOI, or else the same title
-- and year, under another key. { [old key] = new key }
function M.renames(old, new)
  local function id(entry)
    local doi = entry.fields.doi and entry.fields.doi:lower():gsub("^https?://[^/]+/", ""):gsub("%s", "")
    if doi and doi ~= "" then
      return "doi:" .. doi
    end
    local title = (entry.fields.title or ""):lower():gsub("[^%w]", "")
    return title ~= "" and ("title:" .. title .. ":" .. (entry.fields.year or entry.fields.date or ""):sub(1, 4)) or nil
  end
  local by_id = {}
  for key, entry in pairs(new) do
    local i = id(entry)
    if i then
      by_id[i] = key
    end
  end
  local out = {}
  for key, entry in pairs(old) do
    local i = id(entry)
    if not new[key] and i and by_id[i] then
      out[key] = by_id[i]
    end
  end
  return out
end

return M
