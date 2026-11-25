-- crossref.lua
-- Numbers figures and tables as in the PDF (1, 2, ... in the main text;
-- S<n>.1, S<n>.2, ... in appendix n), prefixes captions with "Figure X:" /
-- "Table X:", resolves \ref{} to figures, tables and appendices (also in the
-- abstract), and inserts a page break before each appendix.
--
-- Appendices are announced by marker paragraphs "TOWORDAPPENDIX:<n>:<label>",
-- written by the pre-processing step in place of \appendixsetup{n}.

local stringify = pandoc.utils.stringify
local PAGE_BREAK = pandoc.RawBlock("openxml", '<w:p><w:r><w:br w:type="page"/></w:r></w:p>')

local numbers = {} -- label -> number string

local function prefix_caption(caption, text)
	local prefix = { pandoc.Strong({ pandoc.Str(text .. ":") }), pandoc.Space() }
	local long = caption.long
	if #long > 0 and long[1].content then
		for i = #prefix, 1, -1 do
			long[1].content:insert(1, prefix[i])
		end
	else
		long:insert(1, pandoc.Plain(prefix))
	end
end

-- Pass 1: walk the top-level blocks in document order, numbering as we go
local function number_blocks(doc)
	local app, nfig, ntab = nil, 0, 0
	local out = pandoc.List()

	local function label(n)
		return app and ("S" .. app .. "." .. n) or tostring(n)
	end

	local function visit(blk)
		if blk.t == "Figure" then
			nfig = nfig + 1
			local num = label(nfig)
			if blk.identifier ~= "" then numbers[blk.identifier] = num end
			blk.attributes["number"] = num
			prefix_caption(blk.caption, "Figure " .. num)
		elseif blk.t == "Table" then
			ntab = ntab + 1
			local num = label(ntab)
			if blk.identifier ~= "" then numbers[blk.identifier] = num end
			blk.attributes["number"] = num
			prefix_caption(blk.caption, "Table " .. num)
		end
		return blk
	end

	for _, blk in ipairs(doc.blocks) do
		local txt = (blk.t == "Para" or blk.t == "Plain") and stringify(blk) or ""
		local n, lab = txt:match("^TOWORDAPPENDIX:(%d+):(%S*)$")
		if n then
			app, nfig, ntab = n, 0, 0
			if lab ~= "" then numbers[lab] = n end
			out:insert(PAGE_BREAK)
		else
			if blk.t == "Figure" or blk.t == "Table" then
				out:insert(visit(blk))
			else
				-- figures/tables can be nested in Divs; a table's \label ends up
				-- as the identifier of the Div that wraps it
				if blk.t == "Div" and blk.identifier ~= "" and #blk.content == 1
					and blk.content[1].t == "Table" and blk.content[1].identifier == "" then
					blk.content[1].identifier = blk.identifier
				end
				out:insert(pandoc.walk_block(blk, { Figure = visit, Table = visit }))
			end
		end
	end
	doc.blocks = out
	return doc
end

-- Pass 2: replace the text of every \ref link by the number
local function resolve(el)
	local ref = el.attributes["reference"]
	if ref and numbers[ref] then
		el.content = { pandoc.Str(numbers[ref]) }
		el.attributes["reference"] = nil
		el.attributes["reference-type"] = nil
		return el
	end
end

function Pandoc(doc)
	doc = number_blocks(doc)
	doc = doc:walk({ Link = resolve })
	if doc.meta.abstract then
		doc.meta.abstract = pandoc.walk_block(pandoc.Div(doc.meta.abstract), { Link = resolve }).content
	end
	return doc
end
