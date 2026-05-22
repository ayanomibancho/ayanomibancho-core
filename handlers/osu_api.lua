-- handlers/osu_api.lua
-- Handler for in-game osu! client requests (e.g. /web/osu-getscores.php)

local url = require('url')
local querystring = require('querystring')
local db = require('../db')
local bit = require('bit')
local config = require('../config')

-- Helper to read POST request body asynchronously
local function readBody(req)
  local co = coroutine.running()
  local chunks = {}
  req:on('data', function(chunk)
    table.insert(chunks, chunk)
  end)
  req:on('end', function()
    coroutine.resume(co, table.concat(chunks))
  end)
  return coroutine.yield()
end

local function handleGetScores(req, res)
  -- 1. Gather request parameters from URL query string
  local parsedUrl = url.parse(req.url, true)
  local params = parsedUrl.query or {}

  -- 2. If client uses POST, read and parse body
  if req.method == "POST" then
    local body = readBody(req)
    local postParams = querystring.parse(body)
    for k, v in pairs(postParams) do
      params[k] = v
    end
  end

  -- 'c' parameter contains the Beatmap MD5 hash sent by the osu! client
  local mapMd5 = params.c
  if not mapMd5 then
    local errBody = "error: missing"
    res:writeHead(200, {
      ['Content-Type'] = 'text/plain; charset=utf-8',
      ['Content-Length'] = tostring(#errBody)
    })
    res:finish(errBody)
    return
  end

  local mode = tonumber(params.m) or 0
  local isRelax = tonumber(params.relax) or 0
  local limit = tonumber(params.limit) or 50
  local username = params.us or ""

  -- Query beatmap info (column is file_md5, not md5)
  local beatmaps = db.query([[
    SELECT beatmaps.*, beatmapsets.artist, beatmapsets.title, beatmapsets.creator
    FROM beatmaps
    LEFT JOIN beatmapsets ON beatmaps.parent_set_id = beatmapsets.id
    WHERE beatmaps.file_md5 = ?
  ]], mapMd5)
  local beatmap = beatmaps[1]

  if not beatmap then
    -- Beatmap not in DB: treat as ranked (2) so players can play any map
    -- Return minimal ranked response with no scores
    local lines = {}
    table.insert(lines, "2|false")   -- Ranked
    table.insert(lines, "0")         -- offset
    table.insert(lines, "")          -- display title (client uses local)
    table.insert(lines, "10.0")      -- online rating
    table.insert(lines, "")          -- no personal best
    local output = table.concat(lines, "\n")
    res:writeHead(200, {
      ['Content-Type'] = 'text/plain; charset=utf-8',
      ['Content-Length'] = tostring(#output)
    })
    res:finish(output)
    return
  end

  -- Get ranked status from beatmapsets
  local setStatus = db.query("SELECT ranked_status FROM beatmapsets WHERE id = ?", beatmap.parent_set_id)
  local rankedStatus = setStatus[1] and setStatus[1].ranked_status or 0

  -- Map internal status to osu! client status
  -- osu! expects: -1=NotSubmitted, 0=Pending, 1=NeedsUpdate, 2=Ranked, 3=Approved, 4=Qualified, 5=Loved
  local displayTitle = string.format("[bold:0,size:20]%s - %s [%s]",
    beatmap.artist or "Unknown",
    beatmap.title or "Unknown",
    beatmap.diff_name or "Normal"
  )

  -- Query scores for this beatmap
  local sqlQuery = [[
    SELECT scores.*, users.username
    FROM scores
    INNER JOIN users ON scores.userid = users.id
    WHERE beatmap_md5 = ? AND play_mode = ? AND is_relax = ? AND completed = 3
    ORDER BY score DESC
    LIMIT ?
  ]]
  local scores = db.query(sqlQuery, mapMd5, mode, isRelax, limit)

  -- Build response in osu! stable format
  local lines = {}

  -- Line 1: rankedStatus|serverHasOsz2
  table.insert(lines, string.format("%d|false", rankedStatus))

  -- Line 2: offset
  table.insert(lines, "0")

  -- Line 3: display title
  table.insert(lines, displayTitle)

  -- Line 4: online rating
  table.insert(lines, "10.0")

  -- Personal best score for this user (empty line if none)
  local personalBest = ""
  if username ~= "" then
    local pbQuery = [[
      SELECT scores.*, users.username
      FROM scores
      INNER JOIN users ON scores.userid = users.id
      WHERE beatmap_md5 = ? AND play_mode = ? AND is_relax = ? AND completed = 3 AND users.username = ?
      ORDER BY score DESC
      LIMIT 1
    ]]
    local pbScores = db.query(pbQuery, mapMd5, mode, isRelax, username)
    if pbScores[1] then
      local s = pbScores[1]
      -- Find rank of personal best
      local rank = 1
      for i, sc in ipairs(scores) do
        if sc.id == s.id then rank = i break end
      end
      personalBest = string.format(
        "%d|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|1",
        s.id, s.username, s.score, s.max_combo,
        s.count50 or 0, s.count100 or 0, s.count300 or 0,
        s.countmiss or 0, s.countkatu or 0, s.countgeki or 0,
        s.full_combo or 0, s.mods or 0, s.userid,
        rank, s.time or 0
      )
    end
  end
  table.insert(lines, personalBest)

  -- Other scores
  for i, s in ipairs(scores) do
    local scoreLine = string.format(
      "%d|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|1",
      s.id, s.username, s.score, s.max_combo,
      s.count50 or 0, s.count100 or 0, s.count300 or 0,
      s.countmiss or 0, s.countkatu or 0, s.countgeki or 0,
      s.full_combo or 0, s.mods or 0, s.userid,
      i, s.time or 0
    )
    table.insert(lines, scoreLine)
  end

  local output = table.concat(lines, "\n")

  res:writeHead(200, {
    ['Content-Type'] = 'text/plain; charset=utf-8',
    ['Content-Length'] = tostring(#output),
    ['Connection'] = 'close'
  })
  res:finish(output)
end

local function handleGetScoresOsz2(req, res)
  -- For now, just proxy to handleGetScores
  return handleGetScores(req, res)
end

local function decryptScore(scoreB64, hashB64, ivB64, osuVersion)
  local childprocess = require('childprocess')
  local co = coroutine.running()
  
  -- Input validation to prevent command injection
  if not string.match(scoreB64 or "", "^[a-zA-Z0-9+/=%s\r\n]+$") then
    return nil, "Invalid score base64 parameter"
  end
  if hashB64 and not string.match(hashB64, "^[a-zA-Z0-9+/=%s\r\n]+$") then
    return nil, "Invalid hash base64 parameter"
  end
  if not string.match(ivB64 or "", "^[a-zA-Z0-9+/=%s\r\n]+$") then
    return nil, "Invalid IV base64 parameter"
  end
  if not string.match(osuVersion or "", "^[a-zA-Z0-9%.-]+$") then
    return nil, "Invalid osu version parameter"
  end

  -- Use double quotes for arguments to handle potential special characters in shell
  local cmd = string.format('python decrypt_score.py "%s" "%s" "%s" "%s"', scoreB64, hashB64 or "", ivB64, osuVersion)
  
  childprocess.exec(cmd, {}, function(err, stdout, stderr)
    if err then
      coroutine.resume(co, nil, tostring(err) .. ": " .. (stderr or ""))
    else
      coroutine.resume(co, require('json').decode(stdout))
    end
  end)
  
  return coroutine.yield()
end

local function recalculateUserStats(userId, mode, isRelax)
  local modeSuffixes = { [0] = "std", [1] = "taiko", [2] = "ctb", [3] = "mania" }
  local modeSuffix = modeSuffixes[mode] or "std"
  local statsTable = isRelax == 1 and "users_stats_relax" or "users_stats"

  -- Ensure stats row exists
  db.query(string.format("INSERT OR IGNORE INTO %s (id) VALUES (?)", statsTable), userId)

  -- Query playcount: count of all scores (passed or failed) for this mode & relax status
  local playcountResult = db.query([[
    SELECT COUNT(*) as cnt FROM scores 
    WHERE userid = ? AND play_mode = ? AND is_relax = ?
  ]], userId, mode, isRelax)
  local playcount = playcountResult[1] and playcountResult[1].cnt or 0

  -- Query total_score: sum of all scores (passed or failed) for this mode & relax status
  local totalScoreResult = db.query([[
    SELECT SUM(score) as sum_score FROM scores 
    WHERE userid = ? AND play_mode = ? AND is_relax = ?
  ]], userId, mode, isRelax)
  local totalScore = totalScoreResult[1] and totalScoreResult[1].sum_score or 0

  -- Query best score per beatmap (only completed/passed scores)
  local bestScores = db.query([[
    SELECT beatmap_md5, MAX(score) as max_score, count300, count100, count50, countmiss, countkatu, countgeki
    FROM scores
    WHERE userid = ? AND play_mode = ? AND is_relax = ? AND completed = 3
    GROUP BY beatmap_md5
    ORDER BY max_score DESC
  ]], userId, mode, isRelax)

  -- Calculate Ranked Score (sum of highest scores per beatmap)
  local rankedScore = 0
  for _, s in ipairs(bestScores) do
    rankedScore = rankedScore + (s.max_score or 0)
  end

  -- Calculate average accuracy: weighted accuracy of the top 100 best scores
  local avgAccuracy = 0
  if #bestScores > 0 then
    local weightedAccSum = 0
    local weightSum = 0
    local limit = math.min(#bestScores, 100)
    for i = 1, limit do
      local s = bestScores[i]
      local count300 = s.count300 or 0
      local count100 = s.count100 or 0
      local count50 = s.count50 or 0
      local countmiss = s.countmiss or 0
      local countkatu = s.countkatu or 0
      local countgeki = s.countgeki or 0
      
      -- Calculate score accuracy based on mode
      local acc = 0
      if mode == 0 then -- std
        local totalHits = count300 + count100 + count50 + countmiss
        if totalHits > 0 then
          acc = (count300 * 300 + count100 * 100 + count50 * 50) / (totalHits * 300) * 100
        end
      elseif mode == 1 then -- taiko
        local totalHits = count300 + count100 + countmiss
        if totalHits > 0 then
          acc = (count300 * 2 + count100) / (totalHits * 2) * 100
        end
      elseif mode == 2 then -- ctb
        local totalHits = count300 + count100 + count50 + countkatu + countmiss
        if totalHits > 0 then
          acc = (count300 + count100 + count50) / totalHits * 100
        end
      elseif mode == 3 then -- mania
        local totalHits = countgeki + count300 + countkatu + count100 + count50 + countmiss
        if totalHits > 0 then
          acc = (countgeki * 300 + count300 * 300 + countkatu * 200 + count100 * 100 + count50 * 50) / (totalHits * 300) * 100
        end
      end
      
      local weight = 0.95 ^ (i - 1)
      weightedAccSum = weightedAccSum + (acc * weight)
      weightSum = weightSum + weight
    end
    
    if weightSum > 0 then
      avgAccuracy = weightedAccSum / weightSum
    end
  end

  -- Update db
  db.query(string.format([[
    UPDATE %s SET
      playcount_%s = ?,
      total_score_%s = ?,
      ranked_score_%s = ?,
      avg_accuracy_%s = ?
    WHERE id = ?
  ]], statsTable, modeSuffix, modeSuffix, modeSuffix, modeSuffix), playcount, totalScore, rankedScore, avgAccuracy, userId)
end

local function handleSubmitScore(req, res)
  local body = readBody(req)
  local contentType = req.headers['content-type'] or ""
  local boundary = string.match(contentType, "boundary=(.*)")
  
  if not boundary then
    res:writeHead(400)
    res:finish("error: no boundary")
    return
  end

  -- Simple multipart parser to extract parts
  local parts = {}
  local boundaryStr = "--" .. boundary
  local searchStart = 1
  while true do
    local partStart, partEnd = string.find(body, boundaryStr, searchStart, true)
    if not partStart then break end
    
    local nextBoundaryStart = string.find(body, boundaryStr, partEnd + 1, true)
    if not nextBoundaryStart then break end
    
    local partContent = string.sub(body, partEnd + 1, nextBoundaryStart - 1)
    local headerEnd = string.find(partContent, "\r\n\r\n", 1, true)
    if headerEnd then
      local header = string.sub(partContent, 1, headerEnd)
      local name = string.match(header, 'name="([^"]+)"')
      local content = string.sub(partContent, headerEnd + 4, #partContent - 2) -- strip \r\n
      if name == "score" then
        table.insert(parts, {name = name, content = content})
      else
        parts[name] = content
      end
    end
    searchStart = nextBoundaryStart
  end

  -- osu! modular selector params
  local scoreB64 = parts[1] and parts[1].content -- First "score" part is B64 data
  local replayData = parts[2] and parts[2].content -- Second "score" part is replay file
  local ivB64 = parts.iv
  local osuVersion = parts.osuver
  local clientHashB64 = parts.s
  local passMd5 = parts['pass']
  
  if not scoreB64 or not ivB64 or not osuVersion then
    local errBody = "error: missing params"
    res:writeHead(200, { ['Content-Type'] = 'text/plain', ['Content-Length'] = tostring(#errBody) })
    res:finish(errBody)
    return
  end

  local decrypted, err = decryptScore(scoreB64, clientHashB64, ivB64, osuVersion)
  if not decrypted or not decrypted.success then
    print("[Score] Decryption failed: ", err or (decrypted and decrypted.error))
    local errBody = "error: decrypt"
    res:writeHead(200, { ['Content-Type'] = 'text/plain', ['Content-Length'] = tostring(#errBody) })
    res:finish(errBody)
    return
  end

  local scoreData = decrypted.score_data
  -- scoreData indices (translated from bancho.py):
  -- 0: mapMd5, 1: username (w/ optional space), 2: onlineChecksum, 3: n300, 4: n100, 5: n50, 6: ngeki, 7: nkatu, 8: nmiss, 9: score, 10: maxCombo, 11: perfect (True/False), 12: grade, 13: mods, 14: passed (True/False), 15: mode, 16: playTime
  
  local mapMd5 = scoreData[1]
  local username = scoreData[2]:gsub("%s+$", "")
  local n300 = tonumber(scoreData[4]) or 0
  local n100 = tonumber(scoreData[5]) or 0
  local n50 = tonumber(scoreData[6]) or 0
  local ngeki = tonumber(scoreData[7]) or 0
  local nkatu = tonumber(scoreData[8]) or 0
  local nmiss = tonumber(scoreData[9]) or 0
  local totalScore = tonumber(scoreData[10]) or 0
  local maxCombo = tonumber(scoreData[11]) or 0
  local perfect = (scoreData[12] == "True" and 1 or 0)
  local grade = scoreData[13]
  local mods = tonumber(scoreData[14]) or 0
  local passed = (scoreData[15] == "True")
  local mode = tonumber(scoreData[16]) or 0
  
  -- Verify user
  local users = db.query("SELECT id FROM users WHERE username = ? AND password_md5 = ?", username, passMd5)
  local user = users[1]
  if not user then
    local errBody = "error: auth"
    res:writeHead(200, { ['Content-Type'] = 'text/plain', ['Content-Length'] = tostring(#errBody) })
    res:finish(errBody)
    return
  end

  -- Verify beatmap - auto-create if not found
  local bms = db.query("SELECT id, parent_set_id FROM beatmaps WHERE file_md5 = ?", mapMd5)
  local bm = bms[1]
  if not bm then
    -- Attempt lookup from Nerinyan API (non-blocking HTTP request)
    local http = require('coro-http')
    local json = require('json')
    
    local apiSuccess, res, body = pcall(http.request, "GET", "https://api.nerinyan.moe/v1/get_beatmaps?h=" .. mapMd5)
    
    local mapData
    if apiSuccess and res.code == 200 and body then
      local parseSuccess, data = pcall(json.parse, body)
      if parseSuccess and type(data) == "table" and data[1] then
        mapData = data[1]
      end
    end

    local setId, mapId, diffName, artist, title, creator, bpm, ar, od, cs, hp, totalLength, hitLength, maxCombo, difficultyRating
    
    if mapData then
      setId = tonumber(mapData.beatmapset_id)
      mapId = tonumber(mapData.beatmap_id)
      diffName = mapData.version or "Normal"
      artist = mapData.artist or "Unknown"
      title = mapData.title or "Unknown"
      creator = mapData.creator or "Unknown"
      bpm = tonumber(mapData.bpm) or 0
      ar = tonumber(mapData.diff_approach) or 0
      od = tonumber(mapData.diff_overall) or 0
      cs = tonumber(mapData.diff_size) or 0
      hp = tonumber(mapData.diff_drain) or 0
      totalLength = tonumber(mapData.total_length) or 0
      hitLength = tonumber(mapData.hit_length) or 0
      maxCombo = tonumber(mapData.max_combo) or 0
      difficultyRating = tonumber(mapData.difficultyrating) or 0
      mode = tonumber(mapData.mode) or mode
    else
      setId = os.time()
      mapId = nil
      diffName = "Normal"
      artist = "Unknown"
      title = "Unknown"
      creator = "Unknown"
      bpm, ar, od, cs, hp, totalLength, hitLength, maxCombo, difficultyRating = 0, 0, 0, 0, 0, 0, 0, 0, 0
    end

    -- Insert beatmapset
    local setResult = db.query([[
      INSERT OR IGNORE INTO beatmapsets (id, ranked_status, artist, title, creator)
      VALUES (?, 2, ?, ?, ?)
    ]], setId, artist, title, creator)
    
    if not setId or setId == 0 then
      setId = setResult.insert_id or os.time()
    end

    -- Insert beatmap
    local bmResult
    if mapId then
      bmResult = db.query([[
        INSERT OR IGNORE INTO beatmaps (id, parent_set_id, diff_name, file_md5, mode, bpm, ar, od, cs, hp, total_length, hit_length, max_combo, difficulty_rating)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ]], mapId, setId, diffName, mapMd5, mode, bpm, ar, od, cs, hp, totalLength, hitLength, maxCombo, difficultyRating)
      
      if bmResult and (bmResult.affected_rows or 0) > 0 then
        bm = { id = mapId, parent_set_id = setId }
      else
        bmResult = db.query([[
          INSERT INTO beatmaps (parent_set_id, diff_name, file_md5, mode, bpm, ar, od, cs, hp, total_length, hit_length, max_combo, difficulty_rating)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]], setId, diffName, mapMd5, mode, bpm, ar, od, cs, hp, totalLength, hitLength, maxCombo, difficultyRating)
        bm = { id = bmResult.insert_id, parent_set_id = setId }
      end
    else
      bmResult = db.query([[
        INSERT INTO beatmaps (parent_set_id, diff_name, file_md5, mode, bpm, ar, od, cs, hp, total_length, hit_length, max_combo, difficulty_rating)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ]], setId, diffName, mapMd5, mode, bpm, ar, od, cs, hp, totalLength, hitLength, maxCombo, difficultyRating)
      bm = { id = bmResult.insert_id, parent_set_id = setId }
    end

    print(string.format("[Score] Auto-created beatmap entry for md5=%s (id=%d, set_id=%d, title=%s)", mapMd5, bm.id, bm.parent_set_id, title))
  end

  -- Determine if it's Relax mode
  local isRelax = bit.band(mods, 128) ~= 0 and 1 or 0

  -- Check current leaderboard to determine rank (for replay saving)
  local existingScores = db.query([[
    SELECT score FROM scores
    WHERE beatmap_md5 = ? AND play_mode = ? AND is_relax = ? AND completed = 3
    ORDER BY score DESC
    LIMIT 1
  ]], mapMd5, mode, isRelax)

  local isTop1 = (#existingScores == 0) or (totalScore > existingScores[1].score)

  -- Insert score
  local res_insert = db.query([[
    INSERT INTO scores (userid, beatmap_md5, score, max_combo, full_combo, mods, count300, count100, count50, countmiss, countkatu, countgeki, play_mode, is_relax, completed, time)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ]], user.id, mapMd5, totalScore, maxCombo, perfect, mods, n300, n100, n50, nmiss, nkatu, ngeki, mode, isRelax, (passed and 3 or 0), os.time())

  local scoreId = res_insert.insert_id or 0

  -- Update user stats (recalculate)
  recalculateUserStats(user.id, mode, isRelax)

  print(string.format("[Score] %s submitted score %d on %s (top1=%s)", username, totalScore, mapMd5, tostring(isTop1)))

  -- Save replay only if this score is top 1
  if isTop1 and passed and replayData and #replayData > 0 then
    local fs = require('fs')
    fs.mkdir(config.paths.data .. "/replays", 511, function()
      fs.writeFile(string.format("%s/replays/%d.osr", config.paths.data, scoreId), replayData, function(err)
        if err then
          print("[Score] Error saving replay: ", err)
        else
          print(string.format("[Score] Replay saved for #1 score (id=%d)", scoreId))
        end
      end)
    end)
  end

  -- Construct response charts (Mocked values for now)
  -- beatmapId:1|beatmapSetId:1|beatmapPlaycount:1|beatmapPasscount:1|approvedDate:0|
  -- chartId:beatmap|chartUrl:https://osu.ppy.sh/s/1|chartName:Beatmap Ranking|rankBefore:|rankAfter:1|...
  -- chartId:overall|chartUrl:https://osu.ppy.sh/u/1|chartName:Overall Ranking|...
  
  local beatmapId = bm.id
  local beatmapSetId = bm.parent_set_id
  
  local response = table.concat({
    "beatmapId:" .. beatmapId,
    "beatmapSetId:" .. beatmapSetId,
    "beatmapPlaycount:1",
    "beatmapPasscount:1",
    "approvedDate:0",
    "\n",
    "chartId:beatmap",
    "chartUrl:https://osu.ppy.sh/s/" .. beatmapSetId,
    "chartName:Beatmap Ranking",
    "rankBefore:|rankAfter:1",
    "scoreBefore:|scoreAfter:" .. totalScore,
    "comboBefore:|comboAfter:" .. maxCombo,
    "accuracyBefore:|accuracyAfter:100.00", -- Mocked
    "ppBefore:|ppAfter:0", -- Mocked
    "onlineScoreId:" .. scoreId,
    "\n",
    "chartId:overall",
    "chartUrl:https://osu.ppy.sh/u/" .. user.id,
    "chartName:Overall Ranking",
    "rankBefore:|rankAfter:1",
    "scoreBefore:|scoreAfter:" .. totalScore,
    "comboBefore:|comboAfter:" .. maxCombo,
    "accuracyBefore:|accuracyAfter:100.00",
    "ppBefore:|ppAfter:0",
  }, "|")

  res:writeHead(200, {
    ['Content-Type'] = 'text/plain; charset=utf-8',
    ['Content-Length'] = tostring(#response)
  })
  res:finish(response)
end

local function handleGetReplay(req, res, captures)
  local parsedUrl = url.parse(req.url, true)
  local params = parsedUrl.query or {}
  
  -- 'c' is scoreId in getreplay.php
  local scoreId = tonumber(params.c)
  if not scoreId then
    res:writeHead(404, { ['Content-Type'] = 'text/plain' })
    res:finish('error: replay not found')
    return
  end

  local filePath = string.format("%s/replays/%d.osr", config.paths.data, scoreId)
  local fs = require('fs')
  
  fs.readFile(filePath, function(err, data)
    if err then
      res:writeHead(404, { ['Content-Type'] = 'text/plain' })
      res:finish('error: replay not found')
      return
    end
    
    res:writeHead(200, {
      ['Content-Type'] = 'application/octet-stream',
      ['Content-Length'] = tostring(#data)
    })
    res:finish(data)
  end)
end

-- Helper to parse multipart file from raw POST body
local function parseMultipartFile(body, boundary)
  if not boundary then return nil end
  local boundaryStr = "--" .. boundary
  
  local partStart = string.find(body, boundaryStr, 1, true)
  if not partStart then return nil end
  
  local headerEnd = string.find(body, "\r\n\r\n", partStart, true)
  if not headerEnd then return nil end
  
  local fileStart = headerEnd + 4
  local fileEnd = string.find(body, boundaryStr, fileStart, true)
  if not fileEnd then return nil end
  
  return string.sub(body, fileStart, fileEnd - 3)
end

local function handleSubmitScreenshot(req, res)
  local body = readBody(req)
  local contentType = req.headers['content-type'] or ""
  local boundary = string.match(contentType, "boundary=(.*)")
  
  local fileData = parseMultipartFile(body, boundary)
  if not fileData or #fileData == 0 then
    res:writeHead(400, { ['Content-Type'] = 'text/plain' })
    res:finish('error: invalid file upload')
    return
  end
  
  local filename = "ss_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".png"
  local filepath = "public/screenshots/" .. filename
  
  local fs = require('fs')
  fs.mkdir("public/screenshots", 511, function()
    fs.writeFile(filepath, fileData, function(err)
      if err then
        print("[Screenshot] Error writing file: ", err)
        res:writeHead(500, { ['Content-Type'] = 'text/plain' })
        res:finish('error: failed to save screenshot')
        return
      end
      
      local host = req.headers['host'] or "127.0.0.1:3000"
      local screenshotUrl = "http://" .. host .. "/public/screenshots/" .. filename
      print("[Screenshot] Saved new screenshot: ", screenshotUrl)
      
      res:writeHead(200, {
        ['Content-Type'] = 'text/plain; charset=utf-8',
        ['Content-Length'] = tostring(#screenshotUrl)
      })
      res:finish(screenshotUrl)
    end)
  end)
end

local function handleSubmitBeatmap(req, res)
  local _ = readBody(req)
  local output = "ok"
  res:writeHead(200, {
    ['Content-Type'] = 'text/plain; charset=utf-8',
    ['Content-Length'] = tostring(#output),
    ['Connection'] = 'close'
  })
  res:finish(output)
end

return {
  getScores = handleGetScores,
  getScoresOsz2 = handleGetScoresOsz2,
  submitScore = handleSubmitScore,
  getReplay = handleGetReplay,
  submitScreenshot = handleSubmitScreenshot,
  submitBeatmap = handleSubmitBeatmap
}
