-- handlers/leaderboard.lua
-- Route handler for rendering the global leaderboard page (/leaderboard)

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

local function handleLeaderboard(req, res)
  local parsedUrl = url.parse(req.url, true)
  local params = parsedUrl.query or {}
  
  local modeInt = tonumber(params.m) or 0
  local isRelax = tonumber(params.relax) or 0
  
  local modeSuffixes = { [0] = "std", [1] = "taiko", [2] = "ctb", [3] = "mania" }
  local modeSuffix = modeSuffixes[modeInt] or "std"
  
  local statsTable = isRelax == 1 and "users_stats_relax" or "users_stats"
  
  -- Query top players ordered by ranked score for the selected mode
  local query = string.format([[
    SELECT users.*, s.ranked_score_%s as score, s.avg_accuracy_%s as accuracy, s.playcount_%s as playcount
    FROM users 
    INNER JOIN %s s ON users.id = s.id 
    WHERE (s.ranked_score_%s > 0 OR s.playcount_%s > 0)
    ORDER BY s.ranked_score_%s DESC 
    LIMIT 50
  ]], modeSuffix, modeSuffix, modeSuffix, statsTable, modeSuffix, modeSuffix, modeSuffix)
  
  local players = db.query(query)
  
  -- Build HTML table rows and Podium HTML
  local podiumCards = {}
  local rows = {}
  
  for i, u in ipairs(players) do
    if i <= 3 then
      -- Render Podium card
      local crown = ""
      local badgeClass = ""
      local cardClass = ""
      if i == 1 then
        crown = '<div class="podium-crown">👑</div>'
        badgeClass = "badge-podium-1"
        cardClass = "rank-1-card"
      elseif i == 2 then
        badgeClass = "badge-podium-2"
        cardClass = "rank-2-card"
      elseif i == 3 then
        badgeClass = "badge-podium-3"
        cardClass = "rank-3-card"
      end
      
      local card = string.format([[
        <div class="podium-card %s glass">
          %s
          <div class="podium-badge %s">Rank #%d</div>
          <div class="podium-avatar-wrapper">
            <div class="podium-avatar-ring"></div>
            <img class="podium-avatar" src="/%s" onerror="this.onerror=null;this.src='/public/avatar.jpg';" alt="Avatar">
          </div>
          <a href="/u/%s" class="podium-username">%s</a>
          <div class="podium-country">%s</div>
          <div class="podium-score text-glow-teal">%s</div>
          <div class="podium-label">Ranked Score</div>
          <div class="podium-sub-stats">
            <div class="podium-sub-item">
              <span class="podium-sub-val text-glow-pink">%.2f%%</span>
              <span class="podium-sub-lbl">Acc</span>
            </div>
            <div class="podium-sub-item">
              <span class="podium-sub-val">%s</span>
              <span class="podium-sub-lbl">Plays</span>
            </div>
          </div>
        </div>
      ]], cardClass, crown, badgeClass, i, tostring(u.id or ""), u.username or "Guest", u.username or "Guest", u.country or "XX", formatNumber(u.score or 0), u.accuracy or 0, formatNumber(u.playcount or 0))
      
      table.insert(podiumCards, card)
    else
      -- Render Table Row for rank 4+
      local rankBadge = string.format('<span class="rank-badge rank-other">#%d</span>', i)
      local row = string.format([[
            <tr class="table-row-hover">
              <td class="col-rank" style="text-align: center;">
                %s
              </td>
              <td class="col-user">
                <div class="table-user-info">
                  <img class="table-avatar" src="/%s" onerror="this.onerror=null;this.src='/public/avatar.jpg';" alt="Avatar">
                  <div class="table-user-details">
                    <a href="/u/%s" class="table-username">%s</a>
                    <span class="table-country-code">%s</span>
                  </div>
                </div>
              </td>
              <td class="col-pp text-glow-teal font-bold">%s</td>
              <td class="col-accuracy text-glow-pink">%.2f%%</td>
              <td class="col-playcount">%s</td>
              <td class="col-level">
                <div class="level-indicator">
                  <span class="level-number">Lv.100</span>
                </div>
              </td>
            </tr>
      ]], rankBadge, tostring(u.id or ""), u.username or "Guest", u.username or "Guest", u.country or "XX", formatNumber(u.score or 0), u.accuracy or 0, formatNumber(u.playcount or 0))
      
      table.insert(rows, row)
    end
  end
  
  local topPodiumHtml = ""
  if #podiumCards > 0 then
    topPodiumHtml = '<div class="podium-container animate-fade-in">' .. table.concat(podiumCards, "\n") .. '</div>'
  end
  
  if #rows == 0 and #podiumCards == 0 then
    table.insert(rows, '<tr><td colspan="6" style="text-align: center; padding: 30px;">No players found for this mode.</td></tr>')
  end
  
  local leaderboardRowsHtml = table.concat(rows, "\n")
  
  -- Render the leaderboard page
  local dataContext = {
    title = "Leaderboard",
    top_podium_html = topPodiumHtml,
    leaderboard_rows = leaderboardRowsHtml,
    mode = modeSuffix,
    relax_text = isRelax == 1 and "(Relax)" or ""
  }
  
  local success, renderedHtml = pcall(template.render, "leaderboard", dataContext)
  
  if success then
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = tostring(#renderedHtml)
    })
    res:finish(renderedHtml)
  else
    print("[Leaderboard Handler] Render Error: ", renderedHtml)
    res:writeHead(500, { ['Content-Type'] = 'text/plain' })
    res:finish('500 Internal Server Error: Template rendering failed')
  end
end

return handleLeaderboard
