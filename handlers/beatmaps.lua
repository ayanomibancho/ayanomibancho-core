-- handlers/beatmaps.lua
-- JSON API handlers mirroring Cheesegull API

local db = require('../db')
local json = require('json')
local url = require('url')
local config = require('../config')

local beatmaps = {}

local function sendJson(res, data, code)
  local body = json.encode(data)
  res:writeHead(code or 200, {
    ['Content-Type'] = 'application/json; charset=utf-8',
    ['Content-Length'] = tostring(#body)
  })
  res:finish(body)
end

local function formatBeatmap(bm)
  return {
    BeatmapID = bm.id,
    ParentSetID = bm.parent_set_id,
    DiffName = bm.diff_name,
    FileMD5 = bm.file_md5,
    Mode = bm.mode,
    BPM = bm.bpm,
    AR = bm.ar,
    OD = bm.od,
    CS = bm.cs,
    HP = bm.hp,
    TotalLength = bm.total_length,
    HitLength = bm.hit_length,
    Playcount = bm.playcount,
    Passcount = bm.passcount,
    MaxCombo = bm.max_combo,
    DifficultyRating = bm.difficulty_rating
  }
end

local function formatSet(set, children)
  local formattedChildren = {}
  if children then
    for _, bm in ipairs(children) do
      table.insert(formattedChildren, formatBeatmap(bm))
    end
  end
  
  -- Convert timestamps (assuming integers) to ISO8601 strings if needed, but bancho.py doesn't seem to enforce date format strictly as long as it formats it or it's provided.
  -- Wait, bancho.py expects LastUpdate directly in the format string. We'll provide it as string or number.
  local lastUpdate = set.last_update
  if type(lastUpdate) == "number" then
    lastUpdate = os.date("!%Y-%m-%dT%H:%M:%SZ", lastUpdate)
  end

  return {
    SetID = set.id,
    RankedStatus = set.ranked_status,
    ApprovedDate = set.approved_date,
    LastUpdate = lastUpdate,
    LastChecked = set.last_checked,
    Artist = set.artist,
    Title = set.title,
    Creator = set.creator,
    Source = set.source,
    Tags = set.tags,
    HasVideo = (set.has_video == 1),
    Genre = set.genre,
    Language = set.language,
    Favourites = set.favourites,
    ChildrenBeatmaps = formattedChildren
  }
end

function beatmaps.getBeatmap(req, res, captures)
  local id = tonumber(captures[1])
  if not id then
    return sendJson(res, nil, 404)
  end

  local bms = db.query("SELECT * FROM beatmaps WHERE id = ?", id)
  local bm = bms[1]
  if not bm then
    return sendJson(res, nil, 404)
  end

  sendJson(res, formatBeatmap(bm))
end

function beatmaps.getSet(req, res, captures)
  local id = tonumber(captures[1])
  if not id then
    return sendJson(res, nil, 404)
  end

  local sets = db.query("SELECT * FROM beatmapsets WHERE id = ?", id)
  local set = sets[1]
  if not set then
    return sendJson(res, nil, 404)
  end

  local children = db.query("SELECT * FROM beatmaps WHERE parent_set_id = ?", id)
  
  sendJson(res, formatSet(set, children))
end

function beatmaps.search(req, res)
  local parsedUrl = url.parse(req.url, true)
  local params = parsedUrl.query or {}
  
  local query = params.query or ""
  local amount = math.min(tonumber(params.amount) or 50, 100)
  local offset = math.max(tonumber(params.offset) or 0, 0)
  
  local sqlQuery = "SELECT * FROM beatmapsets"
  local sqlParams = {}
  local conditions = {}
  
  if query ~= "" then
    table.insert(conditions, "(title LIKE ? OR artist LIKE ? OR creator LIKE ? OR tags LIKE ?)")
    local likeQuery = "%" .. query .. "%"
    table.insert(sqlParams, likeQuery)
    table.insert(sqlParams, likeQuery)
    table.insert(sqlParams, likeQuery)
    table.insert(sqlParams, likeQuery)
  end
  
  if params.status then
    table.insert(conditions, "ranked_status = ?")
    table.insert(sqlParams, tonumber(params.status))
  end
  
  -- Mode filter (if provided and not -1)
  -- Cheesegull uses `set_modes`, but we can check if any children have this mode.
  -- To keep it simple, we can filter sets after fetching, or add a EXISTS subquery.
  if params.mode and tonumber(params.mode) ~= -1 then
    table.insert(conditions, "EXISTS (SELECT 1 FROM beatmaps WHERE parent_set_id = beatmapsets.id AND mode = ?)")
    table.insert(sqlParams, tonumber(params.mode))
  end
  
  if #conditions > 0 then
    sqlQuery = sqlQuery .. " WHERE " .. table.concat(conditions, " AND ")
  end
  
  sqlQuery = sqlQuery .. " ORDER BY id DESC LIMIT ? OFFSET ?"
  table.insert(sqlParams, amount)
  table.insert(sqlParams, offset)
  
  local sets = db.query(sqlQuery, unpack(sqlParams))
  
  local formattedSets = {}
  for _, set in ipairs(sets) do
    local children = db.query("SELECT * FROM beatmaps WHERE parent_set_id = ?", set.id)
    table.insert(formattedSets, formatSet(set, children))
  end
  
  sendJson(res, formattedSets)
end

local function downloadFromMirror(id, noVideo)
  local childprocess = require('childprocess')
  local co = coroutine.running()
  
  local mirrorUrl = "https://catboy.best/d/" .. id
  if noVideo then
    mirrorUrl = mirrorUrl .. "?n=1"
  end
  
  print("[Beatmaps] Downloading " .. id .. " from mirror using curl: " .. mirrorUrl)
  
  -- Use curl.exe -L to follow redirects and -s for silent
  local cmd = string.format('curl.exe -L -s "%s"', mirrorUrl)
  
  childprocess.exec(cmd, {maxBuffer = 100 * 1024 * 1024}, function(err, stdout, stderr)
    if err then
      print("[Beatmaps] Curl error: ", err, stderr)
      coroutine.resume(co, nil)
    else
      coroutine.resume(co, stdout)
    end
  end)
  
  return coroutine.yield()
end

function beatmaps.download(req, res, captures)
  local id = tonumber(captures[1])
  local noVideo = string.match(req.url, "n$") ~= nil
  
  if not id then
    res:writeHead(400, { ['Content-Type'] = 'text/plain' })
    res:finish('Malformed ID')
    return
  end

  local cacheDir = config.paths.data .. "/beatmaps"
  local fileName = string.format("%d%s.osz", id, noVideo and "n" or "")
  local cachePath = cacheDir .. "/" .. fileName
  local fs = require('fs')
  
  fs.readFile(cachePath, function(err, data)
    if not err then
      print("[Beatmaps] Serving " .. id .. " from local cache.")
      res:writeHead(200, {
        ['Content-Type'] = 'application/octet-stream',
        ['Content-Disposition'] = string.format('attachment; filename="%s"', fileName),
        ['Content-Length'] = tostring(#data)
      })
      res:finish(data)
    else
      -- Not in cache, download from mirror
      coroutine.wrap(function()
        local body = downloadFromMirror(id, noVideo)
        if body then
          -- Save to cache
          fs.mkdir(cacheDir, 511, function()
            fs.writeFile(cachePath, body, function(writeErr)
              if writeErr then print("[Beatmaps] Error caching file: ", writeErr) end
            end)
          end)
          
          res:writeHead(200, {
            ['Content-Type'] = 'application/octet-stream',
            ['Content-Disposition'] = string.format('attachment; filename="%s"', fileName),
            ['Content-Length'] = tostring(#body)
          })
          res:finish(body)
        else
          res:writeHead(404, { ['Content-Type'] = 'text/plain' })
          res:finish("Beatmap not found on mirror.")
        end
      end)()
    end
  end)
end

return beatmaps
