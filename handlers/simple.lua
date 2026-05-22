-- handlers/simple.lua
-- Route handlers for static and simple dynamic pages based on Hanayo specification

local db = require('../db')
local template = require('../template')

local handlers = {}

-- GET /about
function handlers.about(req, res)
  local dataContext = {
    title = "About Us"
  }
  
  local success, renderedHtml = pcall(template.render, "about", dataContext)
  if success then
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = tostring(#renderedHtml)
    })
    res:finish(renderedHtml)
  else
    print("[About Handler] Render Error: ", renderedHtml)
    res:writeHead(500, { ['Content-Type'] = 'text/plain' })
    res:finish('500 Internal Server Error')
  end
end

-- GET /team
function handlers.team(req, res)
  -- Structure the team members with rich details
  local teamList = {
    developers = {
      { username = "Ayanomi", role = "Lua & Backend Architect", github = "ayanomi", twitter = "ayanomi", mail = "ayanomi@ripple.moe" }
    },
    managers = {
      { username = "Miku", role = "Head Community Manager", github = "miku", twitter = "miku_hatsune", mail = "miku@ripple.moe" }
    },
    moderators = {
      { username = "Cookiezi", role = "Global Chat Moderator", github = "cookiezi" }
    },
    bats = {
      { username = "peppy", role = "Mapping Quality Control", github = "peppy" }
    }
  }

  -- Query users asynchronously to get their dynamic stats (rank, country, id)
  local users = db.query("SELECT * FROM users")
  local userMap = {}
  for _, u in ipairs(users) do
    userMap[u.username:lower()] = u
  end

  -- Merge database stats with the static list of members
  local function processGroup(group)
    for _, member in ipairs(group) do
      local dbUser = userMap[member.username:lower()]
      if dbUser then
        member.id = dbUser.id
        member.country = dbUser.country
        member.pp = dbUser.pp
        member.rank = dbUser.rank
      else
        member.id = 1
        member.country = "XX"
        member.pp = 0
        member.rank = 9999
      end
    end
  end

  processGroup(teamList.developers)
  processGroup(teamList.managers)
  processGroup(teamList.moderators)
  processGroup(teamList.bats)

  -- Helper to render lists into HTML in Lua, satisfying clean component separation
  local function renderUserList(members)
    local items = {}
    for _, m in ipairs(members) do
      local socialHtml = ""
      if m.github or m.twitter or m.mail then
        local parts = {}
        if m.github then
          table.insert(parts, string.format('<a href="https://github.com/%s" target="_blank" title="GitHub" class="social-icon">GitHub</a>', m.github))
        end
        if m.twitter then
          table.insert(parts, string.format('<a href="https://twitter.com/%s" target="_blank" title="Twitter" class="social-icon">Twitter</a>', m.twitter))
        end
        if m.mail then
          table.insert(parts, string.format('<a href="mailto:%s" title="Email" class="social-icon">Email</a>', m.mail))
        end
        socialHtml = '<div class="member-socials">' .. table.concat(parts, " &bull; ") .. '</div>'
      end

      local item = string.format([[
        <div class="team-card glass card-hover">
          <div class="team-avatar-container">
            <img class="team-avatar" src="/%d" onerror="this.onerror=null;this.src='/public/avatar.jpg';" alt="%s">
          </div>
          <div class="team-info">
            <h3 class="team-username"><a href="/u/%s">%s</a> <span class="flag-icon">%s</span></h3>
            <div class="team-role">%s</div>
            %s
          </div>
        </div>
      ]], m.id, m.username, m.username, m.username, m.country, m.role, socialHtml)
      table.insert(items, item)
    end
    return table.concat(items, "\n")
  end

  local dataContext = {
    title = "Team",
    developers_list = renderUserList(teamList.developers),
    managers_list = renderUserList(teamList.managers),
    moderators_list = renderUserList(teamList.moderators),
    bats_list = renderUserList(teamList.bats)
  }

  local success, renderedHtml = pcall(template.render, "team", dataContext)
  if success then
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = tostring(#renderedHtml)
    })
    res:finish(renderedHtml)
  else
    print("[Team Handler] Render Error: ", renderedHtml)
    res:writeHead(500, { ['Content-Type'] = 'text/plain' })
    res:finish('500 Internal Server Error')
  end
end

-- GET /irc
function handlers.irc(req, res)
  local dataContext = {
    title = "IRC Token",
    token_display_box = ""
  }

  local success, renderedHtml = pcall(template.render, "irc", dataContext)
  if success then
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = tostring(#renderedHtml)
    })
    res:finish(renderedHtml)
  else
    print("[IRC Handler] Render Error: ", renderedHtml)
    res:writeHead(500, { ['Content-Type'] = 'text/plain' })
    res:finish('500 Internal Server Error')
  end
end

-- POST /irc/generate
function handlers.ircGenerate(req, res)
  -- Generate a secure random token
  local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  local tokenParts = {}
  math.randomseed(os.time())
  for i = 1, 32 do
    local idx = math.random(1, #chars)
    table.insert(tokenParts, string.sub(chars, idx, idx))
  end
  local generatedToken = "irc_" .. table.concat(tokenParts)

  local tokenBoxHtml = string.format([[
    <div class="token-box animate-pulse">
      <div class="token-label">New IRC Token</div>
      <div class="token-value">%s</div>
      <div style="font-size: 12px; color: var(--text-secondary);">Copy this token and use it as your IRC password. It will not be shown again!</div>
    </div>
  ]], generatedToken)

  local dataContext = {
    title = "IRC Token Generated",
    token_display_box = tokenBoxHtml
  }

  local success, renderedHtml = pcall(template.render, "irc", dataContext)
  if success then
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = tostring(#renderedHtml)
    })
    res:finish(renderedHtml)
  else
    print("[IRC Generate Handler] Render Error: ", renderedHtml)
    res:writeHead(500, { ['Content-Type'] = 'text/plain' })
    res:finish('500 Internal Server Error')
  end
end

return handlers
