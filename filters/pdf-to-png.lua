-- pdf-to-png.lua
-- Word cannot display PDF images embedded in a .docx. Convert every PDF image
-- to PNG with pdftocairo (200 dpi, or $TOWORD_DPI) and point the image to it.
-- PNGs are cached in "toword_png/" and only regenerated when the PDF is newer.

local DIR = "toword_png"
local DPI = os.getenv("TOWORD_DPI") or "200"

local function mtime(path)
	local p = io.popen('stat -c %Y "' .. path .. '" 2>/dev/null')
	local t = p and tonumber(p:read("*l")) or nil
	if p then p:close() end
	return t
end

function Image(img)
	local src = img.src
	if not src:lower():match("%.pdf$") then
		return nil
	end
	-- cache name from the last two path components, e.g. 2_final_fig1-conceptual
	local dir, base = src:match("([^/]+)/([^/]+)%.[Pp][Dd][Ff]$")
	local stem = dir and (dir .. "_" .. base) or src:gsub("%.[Pp][Dd][Ff]$", ""):gsub("[/\\]", "_")
	local png = DIR .. "/" .. stem .. ".png"
	local src_t, png_t = mtime(src), mtime(png)
	if not src_t then
		io.stderr:write("[pdf-to-png] image not found: " .. src .. "\n")
		return nil
	end
	if not png_t or png_t < src_t then
		os.execute('mkdir -p "' .. DIR .. '"')
		local cmd = string.format('pdftocairo -png -r %s -singlefile "%s" "%s"', DPI, src, png:gsub("%.png$", ""))
		if not os.execute(cmd) then
			io.stderr:write("[pdf-to-png] conversion failed: " .. src .. "\n")
			return nil
		end
	end
	img.src = png
	return img
end
