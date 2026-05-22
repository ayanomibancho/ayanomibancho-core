-- pagemappings.lua
-- Legacy page redirect mappings and middleware mirroring Ripple's pagemappings.go

local pagemappings = {}

-- Page redirect mapping definitions
pagemappings.pageMappings = {
  [1]  = "/",
  [2]  = "/login",
  [3]  = "/register",
  [4]  = "/",
  [5]  = "/settings/avatar",
  [6]  = "/settings",
  [7]  = "/settings/password",
  [8]  = "/settings/userpage",
  [9]  = "/",
  [10] = "/",
  [11] = "/",
  [12] = "/",
  [13] = "/leaderboard",
  [14] = "/doc",
  [15] = "/",
  [16] = function(query) return "/doc/" .. (query.id or "") end,
  [17] = "/changelog",
  [18] = "/pwreset",
  [19] = function(query) return "/pwreset/continue?k=" .. (query.k or "") end,
  [20] = "/",
  [21] = "/about",
  [22] = "/",
  [23] = "/doc/rules",
  [24] = "/",
  [25] = "/",
  [26] = "/friends",
  [27] = "https://status.ripple.moe",
  [28] = "/",
  [29] = "/2fa_gateway",
  [30] = "/settings/2fa",
  [31] = "/rank_request",
  [32] = "/dev/applications",
  [33] = "/dev/applications",
  [34] = "/donate",
  [35] = "/team",
  [36] = "/irc",
  [37] = "/beatmaps",
  [38] = "/register/verify",
  [39] = "/register/welcome",
  [40] = "/settings/discord",
  [41] = "/register"
}

-- Checks and performs redirections to avoid broken links from the old website
function pagemappings.checkRedirect(req, res, path, query)
  if path ~= "/" and path ~= "/index.php" then
    return false
  end

  if query and query.u and query.u ~= "" then
    res:writeHead(302, { ['Location'] = "/u/" .. query.u })
    res:finish()
    return true
  elseif query and query.p then
    local pNum = tonumber(query.p)
    if pNum then
      local mapped = pagemappings.pageMappings[pNum]
      if not mapped then
        -- Build original path & query parameters to redirect to old.ripple.moe
        local queryParams = {}
        for k, v in pairs(query) do
          table.insert(queryParams, k .. "=" .. v)
        end
        local qs = #queryParams > 0 and ("?" .. table.concat(queryParams, "&")) or ""
        res:writeHead(302, { ['Location'] = "https://old.ripple.moe" .. path .. qs })
        res:finish()
        return true
      end

      local loc
      if type(mapped) == "function" then
        loc = mapped(query)
      else
        loc = mapped
      end
      res:writeHead(302, { ['Location'] = loc })
      res:finish()
      return true
    end
  end

  return false
end

return pagemappings
