-- Text transforms of LaTeX for a submission's source: its comments out, and the variant's switches
-- resolved in the text (\ifanonymous A\else B\fi: only A or B left, so that an anonymous source has
-- no authors even in a branch TeX would skip).
local M = {}

-- TeX's conditionals: a \fi closes each (their nesting decides which \else and \fi are a switch's).
local PRIMITIVE = {}
for _, name in ipairs({ "if", "ifcat", "ifnum", "ifdim", "ifodd", "ifvmode", "ifhmode", "ifmmode", "ifinner",
  "ifvoid", "ifhbox", "ifvbox", "ifx", "ifeof", "iftrue", "iffalse", "ifcase", "ifdefined", "ifcsname",
  "iffontchar", "ifincsname", "ifpdfprimitive", "ifpdfabsnum", "ifpdfabsdim", "ifprimitive", "ifabsnum",
  "ifabsdim" }) do
  PRIMITIVE[name] = true
end

-- Where a control word ends, and the spaces TeX skips after it (and one end of line, not a blank
-- line, which is a paragraph).
local function skip_after(text, i)
  local j = i
  while text:sub(j, j):match("[ \t]") do
    j = j + 1
  end
  if text:sub(j, j) == "\n" then
    local k = j + 1
    while text:sub(k, k):match("[ \t]") do
      k = k + 1
    end
    if text:sub(k, k) ~= "\n" then
      return k
    end
  end
  return j
end

-- a .. b, with a space between when a ends with a control word and b starts with a letter (else
-- they would make another one; TeX skips that space).
local function join(a, b)
  if a:match("\\%a+$") and b:match("^%a") then
    return a .. " " .. b
  end
  return a .. b
end

-- The conditionals of a text: TeX's, those \newif defines, and the switches.
local function conditionals(text, switches)
  local out = vim.deepcopy(PRIMITIVE)
  for name in text:gmatch("\\newif%s*\\(if%a+)") do
    out[name] = true
  end
  for name in text:gmatch("\\newif%s*\\csname%s*(if%a+)%s*\\endcsname") do
    out[name] = true
  end
  for name in pairs(switches) do
    out["if" .. name] = true
  end
  return out
end

-- The text with each `\if<switch> A \else B \fi` (switches: { name = true|false }) replaced by A or
-- B, nested ones too; \newif\if<switch> and \let\if<switch> stay as they are.
function M.resolve(text, switches)
  local known = conditionals(text, switches)
  local function one(s)
    local pos = 1
    while true do
      local a, b, name = s:find("\\(if%a+)", pos)
      if not a then
        return s
      end
      local switch = name:sub(3)
      local before = s:sub(math.max(a - 12, 1), a - 1)
      local defining = before:match("\\newif%s*$") or before:match("\\let%s*$") or before:match("\\def%s*$")
      if switches[switch] ~= nil and not s:sub(b + 1, b + 1):match("%a") and not defining then
        -- its \else and \fi: at its depth, counting the conditionals inside it
        local depth, i, else_at, fi_at, fi_end = 0, b + 1, nil, nil, nil
        while true do
          local c, d, word = s:find("\\(%a+)", i)
          if not c then
            break
          end
          local prev = s:sub(math.max(c - 12, 1), c - 1)
          if known[word] and not prev:match("\\newif%s*$") and not prev:match("\\let%s*$") then
            depth = depth + 1
          elseif word == "fi" then
            if depth == 0 then
              fi_at, fi_end = c, d
              break
            end
            depth = depth - 1
          elseif word == "else" and depth == 0 and not else_at then
            else_at = { c, d }
          end
          i = d + 1
        end
        if not fi_at then -- (unbalanced: left as it is)
          pos = b + 1
        else
          local yes = else_at and s:sub(skip_after(s, b + 1), else_at[1] - 1) or s:sub(skip_after(s, b + 1), fi_at - 1)
          local no = else_at and s:sub(skip_after(s, else_at[2] + 1), fi_at - 1) or ""
          local rest = s:sub(skip_after(s, fi_end + 1))
          return join(join(s:sub(1, a - 1), one(switches[switch] and yes or no)), one(rest))
        end
      else
        pos = b + 1
      end
    end
  end
  return one(text)
end

-- Where comments can't be: verbatim environments and the arguments of \url, \href, \nolinkurl (a
-- % there is a character). { [start] = end } of those spans.
local VERBATIM = { "verbatim", "Verbatim", "lstlisting", "minted", "comment", "alltt" }
local function protected(text)
  local spans = {}
  for _, env in ipairs(VERBATIM) do
    local pos = 1
    while true do
      local a = text:find("\\begin%s*{" .. env .. "%*?}", pos)
      if not a then
        break
      end
      local _, e = text:find("\\end%s*{" .. env .. "%*?}", a)
      e = e or #text
      spans[a] = e
      pos = e + 1
    end
  end
  for _, cmd in ipairs({ "url", "href", "nolinkurl" }) do
    local pos = 1
    while true do
      local a, b = text:find("\\" .. cmd .. "%s*{", pos)
      if not a then
        break
      end
      local _, e = text:find("^%b{}", b)
      e = e or b
      spans[a] = e
      pos = e + 1
    end
  end
  return spans
end

-- The text without its comments, as TeX reads it: a comment line goes (with its end of line), a
-- comment at the end of a line takes the end of line with it (and the next line's indentation);
-- \% stays, and so does a % in a verbatim environment or a URL.
function M.strip_comments(text)
  local spans = protected(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    if spans[i] then
      out[#out + 1] = text:sub(i, spans[i])
      i = spans[i] + 1
    else
      local c = text:sub(i, i)
      if c == "\\" then
        out[#out + 1] = text:sub(i, i + 1)
        i = i + 2
      elseif c == "%" then
        local eol = text:find("\n", i, true) or n + 1
        local line_start = (text:sub(1, i - 1):match(".*\n()") or 1)
        local whole_line = text:sub(line_start, i - 1):match("^[ \t]*$")
        if whole_line then -- (the line goes: its indentation, copied already, too)
          while #out > 0 and out[#out]:match("^[ \t]*$") do
            out[#out] = nil
          end
          if #out > 0 then
            out[#out] = out[#out]:gsub("[ \t]*$", "")
          end
          i = eol + 1
        else -- (the end of line goes too, and the next line's indentation)
          i = eol + 1
          while text:sub(i, i):match("[ \t]") do
            i = i + 1
          end
          local tail = (out[#out - 1] or "") .. (out[#out] or "") -- (a control word: "\r" .. "elax")
          if tail:match("\\%a+$") and text:sub(i, i):match("%a") then
            out[#out + 1] = " " -- (\foo%<eol>bar: \foo bar, not \foobar)
          end
        end
      else
        local j = i
        while j <= n and not spans[j] and not text:sub(j, j):match("[\\%%]") do
          j = j + 1
        end
        out[#out + 1] = text:sub(i, j - 1)
        i = j
      end
    end
  end
  return table.concat(out)
end

return M
