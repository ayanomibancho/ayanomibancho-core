-- handlers/profile.lua
-- Route handler for rendering player profile pages (/u/:username)

local db = require('../db')
local template = require('../template')
local url = require('url')

local function formatNumber(num)
  local formatted = tostring(num or 0)
  while true do
    local k
    formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
    if k == 0 then break end
  end
  return formatted
end

local function handleProfile(req, res, captures)
  local username = captures[1]
  if not username then
    res:writeHead(400, { ['Content-Type'] = 'text/plain' })
    res:finish('400 Bad Request: Missing username')
    return
  end

  -- Decode URL-encoded username (e.g. "%20" -> " ")
  username = string.gsub(username, "%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)

  local parsedUrl = url.parse(req.url, true)
  local params = parsedUrl.query or {}
  local modeInt = tonumber(params.m) or 0
  local isRelax = tonumber(params.relax) or 0
  local modeSuffixes = { [0] = "std", [1] = "taiko", [2] = "ctb", [3] = "mania" }
  local modeSuffix = modeSuffixes[modeInt] or "std"
  local statsTable = isRelax == 1 and "users_stats_relax" or "users_stats"

  -- Query player details and stats for the selected mode
  local query = string.format([[
    SELECT users.*, 0 as pp, s.avg_accuracy_%s as accuracy, s.playcount_%s as playcount, s.ranked_score_%s as ranked_score, s.total_score_%s as total_score
    FROM users 
    LEFT JOIN %s s ON users.id = s.id 
    WHERE users.username = ?
  ]], modeSuffix, modeSuffix, modeSuffix, modeSuffix, statsTable)
  
  local queryResult = db.query(query, username)
  
  local player = queryResult[1]
  if not player then
    res:writeHead(404, { ['Content-Type'] = 'text/html; charset=utf-8' })
    res:finish('<h1>404 Not Found</h1><p>Player "' .. username .. '" could not be found on this server.</p>')
    return
  end

  -- Calculate global rank based on ranked score
  local globalRank = 0
  local rankRows = db.query(string.format(
    "SELECT COUNT(*) as cnt FROM %s WHERE ranked_score_%s > ?", statsTable, modeSuffix
  ), player.ranked_score or 0)
  if rankRows[1] then
    globalRank = (rankRows[1].cnt or 0) + 1
  end

  -- Fetch top scores for this player with beatmap metadata
  local scoresQuery = [[
    SELECT scores.*, b.diff_name, s.artist, s.title
    FROM scores 
    LEFT JOIN beatmaps b ON scores.beatmap_md5 = b.file_md5
    LEFT JOIN beatmapsets s ON b.parent_set_id = s.id
    WHERE scores.userid = ? AND play_mode = ? AND is_relax = ? AND completed = 3
    ORDER BY score DESC 
    LIMIT 10
  ]]
  local topScores = db.query(scoresQuery, player.id, modeInt, isRelax)
  
  -- Pre-render top scores rows HTML (No PP column)
  local scoreRows = {}
  if #topScores > 0 then
    for _, s in ipairs(topScores) do
      local acc = 0
      local totalHits = (s.count300 or 0) + (s.count100 or 0) + (s.count50 or 0) + (s.countmiss or 0)
      if totalHits > 0 then
        acc = ((s.count300 or 0) * 300 + (s.count100 or 0) * 100 + (s.count50 or 0) * 50) / (totalHits * 300) * 100
      end

      local beatmapName = "Unknown Beatmap"
      if s.title and s.title ~= "" then
        beatmapName = string.format("%s - %s [%s]", s.artist or "Unknown", s.title, s.diff_name or "Normal")
      else
        beatmapName = s.beatmap_md5 or "Unknown"
      end

      local row = string.format([[
        <tr class="table-row-hover">
          <td>%s</td>
          <td class="text-glow-teal font-bold">%s</td>
          <td>%dx</td>
          <td class="text-glow-pink">%.2f%%</td>
        </tr>
      ]], beatmapName, formatNumber(s.score or 0), s.max_combo or 0, acc)
      table.insert(scoreRows, row)
    end
  else
    table.insert(scoreRows, '<tr><td colspan="4" style="text-align: center; padding: 20px;">No scores found for this mode.</td></tr>')
  end

  -- Format accuracy
  local accuracyStr = string.format("%.2f", player.accuracy or 0)

  -- Pre-format large numbers with commas
  local formattedPlaycount = formatNumber(player.playcount or 0)
  local formattedRankedScore = formatNumber(player.ranked_score or 0)
  local formattedTotalScore = formatNumber(player.total_score or 0)

  -- Render the profile page
  local dataContext = {
    title = player.username .. "'s Profile",
    user = player,
    user_rank = formatNumber(globalRank),
    user_accuracy = accuracyStr,
    formatted_playcount = formattedPlaycount,
    formatted_ranked_score = formattedRankedScore,
    formatted_total_score = formattedTotalScore,
    mode = modeSuffix,
    relax_text = isRelax == 1 and "(Relax)" or "",
    top_scores_rows = table.concat(scoreRows, "\n")
  }
  
  local success, renderedHtml = pcall(template.render, "profile", dataContext)
  
  if success then
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = tostring(#renderedHtml)
    })
    res:finish(renderedHtml)
  else
    print("[Profile Handler] Render Error: ", renderedHtml)
    res:writeHead(500, { ['Content-Type'] = 'text/plain' })
    res:finish('500 Internal Server Error: Template compilation failed')
  end
end

return handleProfile
