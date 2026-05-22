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
  
  -- Build HTML table rows dynamically
  local rows = {}
  for i, u in ipairs(players) do
    local rankBadge = ""
    if i == 1 then
      rankBadge = '<span class="rank-badge rank-1">#1</span>'
    elseif i == 2 then
      rankBadge = '<span class="rank-badge rank-2">#2</span>'
    elseif i == 3 then
      rankBadge = '<span class="rank-badge rank-3">#3</span>'
    else
      rankBadge = string.format('<span class="rank-badge rank-other">#%d</span>', i)
    end

    local row = string.format([[
          <tr class="table-row-hover">
            <td class="col-rank">
              %s
            </td>
            <td class="col-user">
              <div class="table-user-info">
                <img class="table-avatar" src="https://a.o.ayanomi.io.vn/%s" onerror="this.onerror=null;this.src='/public/avatar.jpg';" alt="Avatar">
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

  local leaderboardRowsHtml = table.concat(rows, "\n")
  
  -- Render the leaderboard page
  local dataContext = {
    title = "Leaderboard",
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
