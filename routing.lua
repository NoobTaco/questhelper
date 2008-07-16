QuestHelper_File["routing.lua"] = "Development Version"

-- Create module
QuestHelper.Routing = {}
local Routing = QuestHelper.Routing
Routing.qh = QuestHelper

-- Constants:
local improve_margin = 1e-8

-- Module Status:
local work_done = 0
local route_pass = 0
local coroutine_running = false
local coroutine_stop_time = 0

function QuestHelper:yieldIfNeeded()
  if coroutine_running then
    -- Check if we've run our alotted time
    if GetTime() > coroutine_stop_time then
      -- As a safety, reset stop time to 0.  If somehow we fail to set it next time,
      -- we'll be sure to yield promptly.
      coroutine_stop_time = 0
      coroutine.yield()
    end
  end
end

local function CalcObjectivePriority(obj)
  local priority = obj.priority
  
  for o in pairs(obj.before) do
    if o.watched then
      priority = math.min(priority, CalcObjectivePriority(o))
    end
  end
  
  obj.real_priority = priority
  return priority
end

local Route = {}
Route.__index = Route
Routing.Route = Route       -- Make it available as a member

function Route:sanity()
  local assert = assert
  
  if QuestHelper.Error then
    assert = function(a, b)
      if not a then
        QuestHelper:TextOut("Route:sanity(): id="..self.id.."; best_route="..Routing.best_route.id)
        QuestHelper:Error(b or "Assertion Failed")
      end
    end
  end
  
  local l = 0
  
  for i = 0,#self-1 do
    assert(self[i].len)
    l = l + self[i].len
  end
  
  assert(math.abs(l-self.distance) < 0.0001)
  
  for i, info in ipairs(self) do
    assert(self.index[info.obj] == i)
    assert(info.pos)
  end
  
  for obj, i in pairs(self.index) do
    assert(self[i].obj == obj)
  end
  
  --for i = 1, #self-1 do
  --  local l = QuestHelper:ComputeTravelTime(self[i].pos, self[i+1].pos)
  --  assert(math.abs(l-self[i].len) < 0.0001)
  --end
  
  return true
end

function Route:findObjectiveRange(obj)
  local mn, smn = 1, 1
  local smx = #self
  local mx = smx+1
  
  local l = math.floor((smn+smx)*0.5)
  local r = l+1
  
  while true do
    while true do
      if l < smn then
        return mn, mx
      end
      
      local o = self[l].obj
      
      if obj.real_priority > o.real_priority or obj.after[o] then
        mn = l+1
        smn = r
        l = math.floor((smn+smx)*0.5)
        r = l+1
        break
      elseif obj.real_priority < o.real_priority or obj.before[o] then
        mx = l
        smx = l-1
        l = math.floor((smn+smx)*0.5)
        r = l+1
        break
      end
      
      if r > smx then
        return mn, mx
      end
      
      o = self[r].obj
      
      if obj.real_priority > o.real_priority or obj.after[o] then
        mn = r+1
        smn = r+1
        l = math.floor((smn+smx)*0.5)
        r = l+1
        break
      elseif obj.real_priority < o.real_priority or obj.before[o] then
        mx = r
        smx = l-1
        l = math.floor((smn+smx)*0.5)
        r = l+1
        break
      end
      
      l = l - 1
      r = r + 1
    end
  end
end

function Route:addObjectiveFast(obj)
  assert(self:sanity())
  local indexes = self.index
  local len = #self
  local info = QuestHelper:CreateTable()
  assert(not indexes[obj])
  
  info.obj = obj
  
  if len == 0 then
    local d
    self[1] = info
    indexes[obj] = 1
    d, info.pos = obj:TravelTime(self[0].pos, true)
    self[0].len = d
    self.distance = d
    return 1
  end
  
  local player_pos = QuestHelper.pos
  local pos = obj.location
  local c, x, y = pos[1].c, pos[3], pos[4]
  
  local mn, mx = self:findObjectiveRange(obj)
  local index, distsqr
  
  for i = mn, math.min(mx, len) do
    local p = self[i].pos
    if c == p[1].c then
      local u, v = p[3]-x, p[4]-y
      local d2 = u*u+v*v
      if not index or d2 < distsqr then
        index, distsqr = i, d2
      end
    end
  end
  
  if not index then
    -- No nodes with the same continent already.
    -- If the same continent as the player, add to start of list, otherwise add to end of the list.
    index = c == player_pos[1].c and mn or mx
  end
  
  -- The next question, do I insert at that point, or do I insert after it?
  if index ~= mx and index <= len then
    local p1 = self[index].pos
    
    if p1[1].c == c then
      local p0
      
      if index == 1 then
        p0 = player_pos
      else
        p0 = self[index-1].pos
      end
      
      local oldstart, newstart
      
      if p0[1].c == c then
        local u, v = p0[3]-x, p0[4]-y
        newstart = math.sqrt(u*u+v*v)
        u, v = p0[3]-p1[3], p0[4]-p1[4]
        oldstart = math.sqrt(u*u+v*v)
      else
        newstart = 0
        oldstart = 0
      end
      
      local p2
      if index ~= len then
        p2 = self[index+1].pos
      end
      
      local oldend, newend
      if p2 and p2[1].c == c then
        local u, v = p2[3]-x, p2[4]-y
        newend = math.sqrt(u*u+v*v)
        u, v = p2[3]-p1[3], p2[4]-p1[4]
        oldend = math.sqrt(u*u+v*v)
      else
        newend = 0
        oldend = 0
      end
      
      if oldstart+newend < newstart+oldend then
        index = index + 1
      end
      
    end
  end
  
  QuestHelper:yieldIfNeeded((mn-mx+3)*0.05) -- The above checks don't require much effort.
  
  if index > len then
    local previnfo = self[index-1]
    assert(previnfo)
    local d
    d, info.pos = obj:TravelTime(previnfo.pos)
    assert(info.pos)
    QuestHelper:yieldIfNeeded(0.5)
    previnfo.len = d
    self.distance = self.distance + d
  else
    local d1, d2
    
    local previnfo = self[index-1]
    d1, d2, info.pos = obj:TravelTime2(previnfo.pos, self[index].pos, previnfo.no_cache)
    info.len = d2
    self.distance = self.distance + (d1 - previnfo.len + d2)
    previnfo.len = d1
    
    QuestHelper:yieldIfNeeded(1)
  end
  
  -- Finally, insert the objective.
  table.insert(self, index, info)
  indexes[obj] = index
  
  -- Fix indexes of shifted elements.
  for i = index+1,len+1 do
    local obj = self[i].obj
    assert(indexes[obj] == i-1)
    indexes[obj] = i
  end
  
  assert(self:sanity())
  
  return index
end

function Route:addObjectiveBest(obj, old_index, old_distance)
  assert(self:sanity())
  
  local indexes = self.index
  local len = #self
  local info = QuestHelper:CreateTable()
  assert(not indexes[obj])
  
  info.obj = obj
  
  if len == 0 then
    indexes[obj] = 1
    self.distance, info.pos = obj:TravelTime(self[0].pos, true)
    info.len = 0
    self[0].len = self.distance
    self[1] = info
    return 1
  end
  
  local best_index, best_delta, best_d1, best_d2, best_p
  local no_cache, prev_pos, prev_len
  local mn, mx = self:findObjectiveRange(obj)

  if old_index and mn <= old_index and old_index <= mx then
    -- We're trying to re-evaluate it, and it could remain in the same place.
    -- So that place is our starting best known place.
    best_index, best_delta = old_index, old_distance - self.distance

    if best_delta < 0 then
      -- Somehow, removing the objective actually made the route worse...
      -- Just re-figure things from scratch.
      best_index, best_delta = nil, nil
    end
  end

  local pinfo = self[mn-1]
  no_cache, prev_pos, prev_len = pinfo.no_cache, pinfo.pos, pinfo.len
  
  for i = mn, math.min(mx, len) do
    assert(prev_pos == self[i-1].pos)
    
    local info = self[i]
    local pos = info.pos
    
    local d1, d2, p = obj:TravelTime2(prev_pos, pos, no_cache)
    
    QuestHelper:yieldIfNeeded(1)
    
    local delta = d1 + d2 - prev_len
    
    if not best_index or ((delta + improve_margin) < best_delta) or ((i == best_index) and not best_d1) then
      -- Best so far is:
      --  * First item we reach
      --  * Better than previous best
      --  * We're looking at our best already.  But we just got here; how could this be best?
      --    If this was our prior location and we didn't find anything better earlier in the route,
      --    that's how.  Save the specifics, 'cause we didn't compute them when setting up.
      best_index, best_delta, best_d1, best_d2, best_p = i, delta, d1, d2, p
    end
    
    prev_pos = pos
    prev_len = info.len
    no_cache = false
  end
  
  if mx > len then
    assert(mx == len+1)
    assert(prev_pos == self[len].pos)
    local delta, p = obj:TravelTime(prev_pos, no_cache)
    
    QuestHelper:yieldIfNeeded(.5)
    
    if not best_index or ((delta + improve_margin) < best_delta) or ((mx == best_index) and not best_d1) then
      info.pos = p
      info.len = 0
      self[len].len = delta
      self.distance = self.distance + delta
      table.insert(self, info)
      indexes[obj] = mx

      assert(self:sanity())
      
      return mx
    end
  end

  info.pos = best_p
  info.len = best_d2
  
  local pinfo = self[best_index-1]
  self.distance = self.distance + (best_d1 - pinfo.len + best_d2)
  pinfo.len = best_d1
  
  table.insert(self, best_index, info)
  
  indexes[obj] = best_index
  
  for i = best_index+1,len+1 do
    assert(indexes[self[i].obj] == i-1)
    indexes[self[i].obj] = i
  end
  
  assert(self:sanity())
  
  return best_index
end

function Route:removeObjective(obj)
  assert(self:sanity())
  
  local indexes = self.index
  local index = indexes[obj]
  local old_distance = self.distance
  
  assert(index)
  local info = self[index]
  assert(info.obj == obj)
  
  --[[
  Removing end item: subtract last distance, nothing to recalculate
  Removing other item: recalculate location of next objective, between prior position and objective after next
  Special case: if there is no location after next, just recalc location of next objective
  --]]
  if index == #self then
    self.distance = self.distance - self[index-1].len
    self[index-1].len = 0
  else
    local pinfo = self[index-1]
    local info1 = self[index+1]
    local info2 = self[index+2]
    local no_cache = (index == 1)
    
    local d1, d2

    if info2 then
      d1, d2, info1.pos = info1.obj:TravelTime2(pinfo.pos, info2.pos, no_cache)
      QuestHelper:yieldIfNeeded(1)
      self.distance = self.distance - pinfo.len - info.len - info1.len + d1 + d2
      info1.len = d2
    else
      d1, info1.pos = info1.obj:TravelTime(pinfo.pos, no_cache)
      QuestHelper:yieldIfNeeded(0.5)
      self.distance = self.distance - pinfo.len - info.len + d1
    end
    
    pinfo.len = d1
  end
  
  QuestHelper:ReleaseTable(info)
  indexes[obj] = nil
  table.remove(self, index)
  
  for i = index,#self do
    -- Fix indexes of shifted elements.
    local obj = self[i].obj
    assert(indexes[obj] == i+1)
    indexes[obj] = i
  end
  
  assert(self:sanity())
--  assert(self.distance <= old_distance)
  
  return index
end

local links = {}
local seen = {}

function Route:breed(route_map)
  local indexes = self.index
  local len = #self
  
  local info
  local r
  
  local prev_pos = QuestHelper.pos
  assert(self[0].pos == prev_pos)
  
  -- Pick which objective goes first, selecting from first objective of each route,
  -- and scaling by the route's fitness and distance from player, with a random adjustment factor.
  -- While we're at it, record some data about the fitness of adjacent objectives
  for route in pairs(route_map) do
    assert(route:sanity())
    local fit = route.fitness
    local pos = route[1].pos
    local w
    
    if prev_pos[1].c == pos[1].c then
      local u, v = prev_pos[3]-pos[3], prev_pos[4]-pos[4]
      w = math.sqrt(u*u+v*v)
    else
      w = 500
    end
    
    w = fit * math.random() / w
    
    if not info or w > r then
      info, r = route[1], w
    end
    
    for i = 1,len do
      local obj = route[i].obj
      local tbl = links[obj]
      if not tbl then
        tbl = QuestHelper:CreateTable()
        links[obj] = tbl
      end
      
      if i ~= 1 then
        local info = route[i-1]
        local obj2 = info.obj
        tbl[info] = (tbl[info] or 0) + fit
      end
      
      if i ~= len then
        local info = route[i+1]
        local obj2 = info.obj
        if obj.real_priority <= obj2.real_priority or obj.before[obj2] then
          tbl[info] = (tbl[info] or 0) + fit
        end
      end
    end
    
    QuestHelper:yieldIfNeeded(0.01*len)
  end

  -- Record info for the 'Player Position' objective, so we don't mess it up later
  seen[self[0].obj] = self[0].pos
  
  -- Record the objective that we chose to put first
  local obj = info.obj
  indexes[obj] = 1
  seen[obj] = info.pos      -- Save its position, because we don't want to clobber any of the info objects yet
  prev_pos = info.pos

  last = links[obj]
  links[obj] = nil
  
  -- Scan the rest of the places in the route, and pick objectives to go there
  for index = 2,len do
    info = nil
    local c = 1
    
    -- Scan the list of scores from the prior objective
    for i, weight in pairs(last) do
      if links[i.obj] then
        -- Only consider an item if we have scores for that item
        local w
        local pos = i.pos
        if prev_pos[1].c == pos[1].c then
          local u, v = prev_pos[3]-pos[3], prev_pos[4]-pos[4]
          w = math.sqrt(u*u+v*v)
        else
          w = 500
        end
        
        w = weight * math.random() / w
        
        if not info or w > r then
          info, r = i, w
        end
      end
      c = c + 1
    end
    
    -- In case we had no valid scores, scan the remaining objectives and score by distance
    if not info then
      for obj in pairs(links) do
        local pos = obj.pos
        local w
        if prev_pos[1] == pos[1] then
          -- Same zone
          local u, v = prev_pos[3]-pos[3], prev_pos[4]-pos[4]
          w = math.sqrt(u*u+v*v)
        elseif prev_pos[1].c == pos[1].c then
          -- Same continent. -- Assume twices as long.
          local u, v = prev_pos[3]-pos[3], prev_pos[4]-pos[4]
          w = 2*math.sqrt(u*u+v*v)
        else
          -- Different continent. Assume fixed value of 5 minutes.
          w = 300
        end
        
        w = math.random() / w
        
        if not info or w > r then
          local route = next(route_map)
          info, r = route[route.index[obj]], w
        end
      end
      
      assert(info)
    end
    
    -- Add the selected item to the route
    obj = info.obj
    indexes[obj] = index
    prev_pos = info.pos
    seen[obj] = prev_pos
    assert(info.obj == obj)
    
    -- Get the scores table for this objective, clear it out, discard the scores from the prior objective, and save these scores for next time around
    local link = links[obj]
    links[obj] = nil
    QuestHelper:ReleaseTable(last)
    last = link
    
    QuestHelper:yieldIfNeeded(0.01*c)
  end
  
  -- Clean up the last table
  QuestHelper:ReleaseTable(last)
  
  -- Now that we've got our objectives lined up, fill in the info objects with the positions we saved
  for obj, i in pairs(indexes) do
    assert(seen[obj])
    local info = self[i]
    info.obj, info.pos = obj, seen[obj]
    seen[obj] = nil
  end

  -- Now randomly randomize some of the route (aka mutation)
  while math.random() > 0.3 do
    local l = math.floor(math.random()^1.6*(len-1))+1
    local i = math.random(1, len-l)
    local j = i+l
    
    -- Reverse a chunk of the route
    for k = 0, j-i-1 do
      self[i+k], self[j-k] = self[j-k], self[i+k]
    end
  end

  -- But wait, after all that some objectives might violate the rules.  Make sure the route follows
  -- the rules.
  local invalid = true
  while invalid do
    invalid = false
    local i = 1
    while i <= #self do
      -- Make sure all the objectives have valid positions in the list.
      local info = self[i]
      local mn, mx = self:findObjectiveRange(info.obj)
      if i < mn then
        -- In theory, 'i' shouldn't be increased here, as the next
        -- element will be shifted down into the current position.
        
        -- However, it is possible for an infinite loop to be created
        -- by this, with a small range of objectives constantly
        -- being shifted.
        
        -- So, I mark the route as invalid and go through it another time.
        -- It's probably still possible to get into an infinite loop,
        -- but it seems much less likely.
        
        table.insert(self, mn, info)
        table.remove(self, i)
        invalid = true
      elseif i > mx then
        table.remove(self, i)
        table.insert(self, mx, info)
        invalid = true
      end
      i = i + 1
    end
  end

  -- Now that we've chosen a route, re-calculate the cost of each leg of the route
  local distance = 0
  local prev_info = self[0]
  local next_info = self[1]
  local prev_pos = prev_info.pos
  local next_pos = next_info.pos
  assert(prev_pos)
  assert(next_pos)
  
  QuestHelper:yieldIfNeeded(0.03*len)
  
  for i = 1, len-1 do
    local d1, d2
    local pos
    local info = next_info
    next_info = self[i+1]
    next_pos = next_info.pos
    
    indexes[info.obj] = i
    
    d1, d2, pos = info.obj:TravelTime2(prev_pos, next_pos, prev_info.no_cache)
    assert(pos)
    QuestHelper:yieldIfNeeded(1)
    
    prev_info.len = d1
    info.len = d2
    info.pos = pos
    distance = distance + d1

    prev_info = info
    prev_pos = pos
  end
  
  self.distance = distance + prev_info.len
  
  indexes[self[len].obj] = len
  self[len].len = 0

  assert(self:sanity())
end

function Route:pathResetBegin()
  for i, info in ipairs(self) do
    local pos = info.pos
    info[1], info[2], info[3] = pos[1].c, pos[3], pos[4]
  end
end

function Route:pathResetEnd()
  for i, info in ipairs(self) do
    -- Try to find a new position for this objective, near where we had it originally.
    local p, d = nil, 0
    
    local a, b, c = info[1], info[2], info[3]
    
    for z, pl in pairs(info.obj.p) do
      for i, point in ipairs(pl) do
        if a == point[1].c then
          local x, y = b-point[3], c-point[4]
          local d2 = x*x+y*y
          if not p or d2 < d then
            p, d = point, d2
          end
        end
      end
    end
    
    -- Assuming that there will still be positions on the same continents as before, i.e., locations are only added and not removed.
    assert(p)
    
    info.pos = p
  end
end

function Routing:RoutingSetup()
  Routing.map_walker = self.qh:CreateWorldMapWalker()
  Routing.add_swap = {}
  Routing.routes = {}

  local routes = Routing.routes
  local pos = QuestHelper.pos
  local PlayerObjective = self.qh:NewObjectiveObject()  -- Pseudo-objective which reflects player's current position.  Always at index 0 of each route.
  PlayerObjective.pos = pos
  PlayerObjective.cat = "loc"       -- A special case of a location
  PlayerObjective.obj = "Player's current position"     -- Player shouldn't see this, so no need to localize
  PlayerObjective.icon_id = 6     -- Don't think we'll need these; just filling them in for completeness
  PlayerObjective.o = {pos=pos}
  PlayerObjective.fb = {}
  
  for i = 1,15 do -- Create some empty routes to use for our population.
    local new_rt = { index={ [PlayerObjective]=0 },
                     distance=0,
                     [0]={ obj=PlayerObjective, pos=pos, len=0, no_cache=true },  -- Player's current position is always objective #0
                     id=i       -- So I can keep track of which route is which; only for debugging.
                    }
    setmetatable(new_rt, Route)
    routes[new_rt] = true
  end

  -- All the routes are the same right now, so it doesn't matter which we're considering the best.
  self.best_route = next(routes)
  self.recheck_position = 1

end

function Routing:RouteUpdateRoutine()
  local qh = QuestHelper
  local map_walker = Routing.map_walker
  local minimap_dodad = qh.minimap_dodad

  local route = qh.route
  local to_add, to_remove, add_swap = qh.to_add, qh.to_remove, self.add_swap

  local routes = self.routes
  local pos = qh.pos

  local best_route = self.best_route
  
  while true do
    -- Update the player's position data.
    if qh.target then
      -- We know the player will be at the target location at target_time, so fudge the numbers
      -- to pretend we're traveling there.
      
      pos[1], pos[3], pos[4] = qh.target[1], qh.target[3], qh.target[4]
      local extra_time = math.max(0, qh.target_time-time())
      for i, t in ipairs(qh.target[2]) do
        pos[2][i] = t+extra_time
      end
    else
      if not pos[1] -- Need a valid position, in case the player was dead when they loaded the game.
        or not UnitIsDeadOrGhost("player") then
        -- Don't update the player's position if they're dead, assume they'll be returning to their corpse.
        pos[3], pos[4] = qh.Astrolabe:TranslateWorldMapPosition(qh.c, qh.z, qh.x, qh.y, qh.c, 0)
        assert(pos[3])
        assert(pos[4])
        pos[1] = qh.zone_nodes[qh.i]
        pos[3], pos[4] = pos[3] * qh.continent_scales_x[qh.c], pos[4] * qh.continent_scales_y[qh.c]
        
        for i, n in ipairs(pos[1]) do
          if not n.x then
            for i, j in pairs(n) do qh:TextOut("[%q]=%s %s", i, type(j), tostring(j) or "???") end
            assert(false)
          end
          
          local a, b = n.x-pos[3], n.y-pos[4]
          pos[2][i] = math.sqrt(a*a+b*b)
        end
      end
    end
    
    local changed = false
    
    if #route > 0 then
      if self.recheck_position > #route then self.recheck_position = 1 end
      local o = route[self.recheck_position]
      
      assert(o.zones)
      o.filter_zone = o.zones[pos[1].i] == nil
      o.filter_watched = not o:IsWatched()
      
      if not o:Known() then
        -- Objective was probably made to depend on an objective that we don't know about yet.
        -- We add it to both lists, because although we need to remove it, we need it added again when we can.
        -- This creates an inconsistancy, but it'll get fixed in the removal loop before anything has a chance to
        -- explode from it.
        
        to_remove[o] = true
        to_add[o] = true
      else
        if o.swap_before then
          qh:ReleaseTable(o.before)
          o.before = o.swap_before
          o.swap_before = nil
        end
        
        if o.swap_after then
          qh:ReleaseTable(o.after)
          o.after = o.swap_after
          o.swap_after = nil
        end
        
        if o.is_sharing ~= o.want_share then
          o.is_sharing = o.want_share
          
          if o.want_share then
            qh:DoShareObjective(o)
          else
            qh:DoUnshareObjective(o)
          end
        end
        
        CalcObjectivePriority(o)
        
        -- Make sure the objective in best_route is still in a valid position.
        -- Won't worry about other routes, they should forced into valid configurations by breeding.
        local old_distance, old_index = best_route.distance, best_route:removeObjective(o)
        local new_index = best_route:addObjectiveBest(o, old_index, old_distance)
        
        if old_index > new_index then
          old_index, new_index = new_index, old_index
        end
        
        for i = math.max(1, old_index-1), new_index do
          local info = best_route[i]
          local obj = info.obj
          obj.pos = info.pos
          route[i] = obj
        end
        
        --if old_index == new_index then
          -- We don't advance recheck_position unless the node doesn't get moved.
          -- TODO: As the this code is apparently bugged, it's gotten into an infinite loop of constantly swapping
          -- and hence never advancing. As a work around for now, we'll always advance.
          self.recheck_position = self.recheck_position + 1
        --else
        if old_index ~= new_index then
          if old_index == 1 then
            minimap_dodad:SetObjective(route[1])
          end
          
          changed = true
        end
      end
    end
    
    -- Remove any waypoints if needed.
    while true do
      local obj = next(to_remove)
      if not obj then break end
      to_remove[obj] = nil
      
      if obj.is_sharing then
        obj.is_sharing = false
        qh:DoUnshareObjective(obj)
      end
      
      for r in pairs(routes) do
        if r == best_route then
          local index = r:removeObjective(obj)
          table.remove(route, index)
          if index == 1 then
            minimap_dodad:SetObjective(route[1])
          end
        else
          r:removeObjective(obj)
        end
      end
      
      obj:DoneRouting()
      changed = true
    end
    
    -- Add any waypoints if needed
    while true do
      local obj = next(to_add)
      if not obj then break end
      to_add[obj] = nil
      
      obj.filter_zone = obj.zones and obj.zones[pos[1].i] == nil
      obj.filter_watched = not obj:IsWatched()
      
      if obj:Known() then
        obj:PrepareRouting()
        
        obj.filter_zone = obj.zones[pos[1].i] == nil
        
        if obj.filter_zone and QuestHelper_Pref.filter_zone then
          -- Not going to add it, wrong zone.
          obj:DoneRouting()
          add_swap[obj] = true
        else
          if not obj.is_sharing and obj.want_share then
            obj.is_sharing = true
            qh:DoShareObjective(obj)
          end
          
          CalcObjectivePriority(obj)
          
          for r in pairs(routes) do
            if r == best_route then
              local index = r:addObjectiveBest(obj)
              obj.pos = r[index].pos
              table.insert(route, index, obj)
              if index == 1 then
                minimap_dodad:SetObjective(route[1])
              end
            else
              r:addObjectiveFast(obj)
            end
          end
          
          changed = true
        end
      else
        add_swap[obj] = true
      end
    end
    
    for obj in pairs(add_swap) do
      -- If one of the objectives we were considering adding was removed, it would be in both lists.
      -- That would be bad. We can't remove it because we haven't actually added it yet, so
      -- handle that special case here.
      if to_remove[obj] then
        to_remove[obj] = nil
        to_add[obj] = nil
        add_swap[obj] = nil
      end
    end
    
    to_add, add_swap = add_swap, to_add
    qh.to_add = to_add
    self.add_swap = add_swap
    
    if #best_route > 1 then
      -- If there is 2 or more objectives, randomly combine routes to (hopefully) create something better than we had before.
      
      -- Calculate best_route first, so that if other routes are identical, we don't risk swapping with them and
      -- updating the map_walker.
      local best, max_fitness = best_route, 1/(qh:ComputeTravelTime(pos, best_route[1].pos)+best_route.distance)
      best_route.fitness = max_fitness
      
      qh:yieldIfNeeded(.3)
      
      for r in pairs(routes) do
        if r ~= best_route then
          local fit = 1/(qh:ComputeTravelTime(pos, r[1].pos)+r.distance)
          r.fitness = fit
          if fit > max_fitness then
            best, max_fitness = r, fit
          end
          qh:yieldIfNeeded(.3)
        end
      end
      
      local to_breed, score
      
      for r in pairs(routes) do
        if r ~= best then
          local s = math.random()*r.fitness
          if not to_breed or s < score then
            to_breed, score = r, s
          end
        end
      end
      
      to_breed:breed(routes)
      
      if 1/(qh:ComputeTravelTime(pos, to_breed[1].pos)+to_breed.distance+improve_margin) > max_fitness then
        best = to_breed
      end
      
      qh:yieldIfNeeded(.3)
      
      if best ~= best_route then
        best_route = best
        self.best_route = best_route
        
        for i, info in ipairs(best) do
          local obj = info.obj
          obj.pos = info.pos
          route[i] = obj
        end
        
        minimap_dodad:SetObjective(route[1])
        
        changed = true
      end
    end
    
    if qh.defered_flight_times then
      qh:buildFlightTimes()
      qh.defered_flight_times = false
      assert(qh.defered_graph_reset)
    end
    
    if qh.defered_graph_reset then
      for r in pairs(routes) do
        r:pathResetBegin()
      end
      
      qh:yieldIfNeeded(10)
      qh.graph_in_limbo = true
      qh:ResetPathing()
      qh.graph_in_limbo = false
      qh.defered_graph_reset = false
      
      for r in pairs(routes) do
        r:pathResetEnd()
      end
      
      for i, info in ipairs(best_route) do
        local obj = info.obj
        obj.pos = info.pos
        route[i] = obj
      end
      
      minimap_dodad:SetObjective(route[1])
      
      qh:yieldIfNeeded(9)
    end
    
    if changed then
      map_walker:RouteChanged()
    end
    
    assert(#route == #best_route)
    
    if route_pass > 0 then
      route_pass = route_pass - 1
    end
    
    qh:yieldIfNeeded(1)
  end
end

local update_route

function QuestHelper:RunCoroutine()
  if coroutine.status(update_route) ~= "dead" then
    coroutine_running = true
    -- At perf = 100%, we will run 5 ms / frame.
    coroutine_stop_time = GetTime() + 4e-3 * QuestHelper_Pref.perf_scale * ((route_pass > 0) and 5 or 1)
    local state, err = coroutine.resume(update_route, self)
    coroutine_running = false
    if not state then
      self:TextOut("|cffff0000The routing co-routine just exploded|r: |cffffff77"..tostring(err).."|r")
    end
  end
end

function QuestHelper:ForceRouteUpdate(passes)
  route_pass = math.max(2, passes or 1)
end

function Routing:Initialize()
  self:RoutingSetup()

  if coroutine.coco then
    -- coco allows yielding across c boundries, which allows me to use xpcall to get
    -- stack traces for coroutines without calls to yield resulting in thermal nuclear meltdown.

    -- This isn't part of WoW, I was using it in my driver program: Development/routetest

    update_route = coroutine.create(
      function()
        local state, err = xpcall(
          function()
            Routing:RouteUpdateRoutine()
          end,
        function (err)
          if debugstack then
            return tostring(err).."\n"..debugstack(2)
          else
            return debug.traceback(tostring(err), 2)
          end
        end)

        if not state then
          error(err, 0)
        end
      end)
  else
    update_route = coroutine.create(function() Routing:RouteUpdateRoutine() end)
  end
end
