-- scripts/tools/wiki/wiki_filter.lua
-- Pandoc filter for the BIOME-CALC wiki docx build (run with --file-scope).
-- Links between Markdown files of the same guide become internal links;
-- links to repo files outside the guide are unwrapped to plain text, because
-- repo-relative paths are dead links inside a docx on SharePoint.
-- Metadata in: wiki_sources (source paths relative to docs/, same order as the
-- input files). --file-scope wraps each input in a top-level Div, in order.

local function dirname(path)
  return path:match("^(.*)/[^/]*$") or ""
end

local function resolve(base_dir, rel)
  local parts = {}
  local full = (base_dir ~= "" and (base_dir .. "/") or "") .. rel
  for seg in full:gmatch("[^/]+") do
    if seg == ".." then
      if #parts > 0 then table.remove(parts) end
    elseif seg ~= "." then
      table.insert(parts, seg)
    end
  end
  return table.concat(parts, "/")
end

function Pandoc(doc)
  local paths = {}
  for _, src in ipairs(doc.meta.wiki_sources or {}) do
    table.insert(paths, pandoc.utils.stringify(src))
  end

  local div_of_path, path_of_block, k = {}, {}, 0
  for i, block in ipairs(doc.blocks) do
    if block.t == "Div" then
      k = k + 1
      if paths[k] then
        div_of_path[paths[k]] = block.identifier
        path_of_block[i] = paths[k]
      end
    end
  end

  local ids = {}
  doc:walk({
    Header = function(h) ids[h.identifier] = true end,
    Div = function(d) ids[d.identifier] = true end,
  })

  local function retarget(link, base)
    local t = link.target
    if t:match("^%a[%w+.-]*:") or t:match("^#") then
      return nil
    end
    local file, anchor = t:match("^([^#]*)#?(.*)$")
    local div_id = div_of_path[resolve(base, file)]
    if not div_id then
      return link.content
    end
    local full = div_id .. "__" .. anchor
    link.target = "#" .. ((anchor ~= "" and ids[full]) and full or div_id)
    return link
  end

  for i, block in ipairs(doc.blocks) do
    local path = path_of_block[i]
    if path then
      local base = dirname(path)
      doc.blocks[i] = pandoc.walk_block(block, {
        Link = function(link) return retarget(link, base) end,
        RawBlock = function(raw) if raw.format == "html" then return {} end end,
      })
    end
  end

  -- Static linked contents (Word TOC fields stay empty in SharePoint's viewer).
  local toc = { pandoc.Div({ pandoc.Para({ pandoc.Str("Contents") }) }, { ["custom-style"] = "Wiki TOC Title" }) }
  doc:walk({
    Header = function(h)
      if h.level <= 2 and h.identifier ~= "" then
        local entry = pandoc.Para({ pandoc.Link(pandoc.utils.blocks_to_inlines({ pandoc.Plain(h.content) }), "#" .. h.identifier) })
        table.insert(toc, pandoc.Div({ entry }, { ["custom-style"] = "Wiki TOC " .. h.level }))
      end
    end,
  })
  table.insert(doc.blocks, 1, pandoc.Div(toc))
  return doc
end
