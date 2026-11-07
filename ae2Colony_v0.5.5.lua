local scriptName = "AE2 Colony"
local scriptVersion = "0.5.5"
local requiredAP = advancedperipherals and advancedperipherals.getAPVersion()
local apVersionText = tostring(requiredAP or "unknown")
if not (apVersionText:find("0.8.2a",1,true) or apVersionText:find("0.8.1a",1,true) or apVersionText:find("0.8.0a",1,true)) then
  error("This script targets Advanced Peripherals 0.8.0a-0.8.2a. Detected: "..apVersionText)
end

-- Diagnostic build: logging is intentionally enabled.
local exportSide, craftMaxStack, scanInterval = "@front", false, 30
local doLog, doLogExtra = false, false
local logFolder, maxLogs, maxLogSize = "ae2Colony_logs", 10, 200*1024
local alarm = nil
local blacklistedTags = { ["c:foods"] = true }
local whitelistItemName = {
  ["minecraft:beef"] = true, ["minecraft:carrot"] = true,
  ["minecraft:potato"] = true, ["minecolonies:apple_pie"] = true,
}
local gearTypes = {
  chestplate="$_chestplate", boots="$_boots", leggings="$_leggings", helmet="$_helmet",
  sword="$_sword", pickaxe="$_pickaxe", axe="$_axe", shovel="$_shovel", hoe="$_hoe",
  shield="minecraft:shield", bow="minecraft:bow",
}
local gearMaterials = {
  wood="minecraft:wooden", leather="minecraft:leather", stone="minecraft:stone",
  chain="minecraft:chainmail", iron="minecraft:iron", gold="minecraft:golden", diamond="minecraft:diamond",
}

if not fs.exists(logFolder) then fs.makeDir(logFolder) end
local function nextLogFile()
  local nums={}
  for _,f in ipairs(fs.list(logFolder)) do local n=f:match("^log_(%d+)%.log$"); if n then nums[#nums+1]=tonumber(n) end end
  table.sort(nums); return string.format("%s/log_%03d.log",logFolder,(nums[#nums] or 0)+1)
end
local function logLine(msg)
  if not doLog then return end
  local files=fs.list(logFolder); table.sort(files)
  local path=#files>0 and (logFolder.."/"..files[#files]) or nextLogFile()
  if fs.exists(path) and fs.getSize(path)>=maxLogSize then path=nextLogFile() end
  local f=fs.open(path,"a")
  if f then f.writeLine("["..os.date("%H:%M:%S",os.epoch("local")/1000).."] "..tostring(msg)); f.close() end
end
local function cleanupOldLogs()
  local files={}; for _,f in ipairs(fs.list(logFolder)) do if f:match("^log_%d+%.log$") then files[#files+1]=f end end
  table.sort(files); while #files>maxLogs do fs.delete(logFolder.."/"..table.remove(files,1)) end
end
local function dump(v)
  if v==nil then return "nil" end
  local ok,s=pcall(textutils.serialize,v); return ok and s or tostring(v)
end
local monitorLines,currentPage,totalPages={},1,1
local function logAndDisplay(s) logLine(s); monitorLines[#monitorLines+1]=s end
local function setupMonitor()
  local m=peripheral.find("monitor"); if m then m.setTextScale(0.5); m.clear(); m.setCursorPos(1,1) end; return m
end
local function updateMonitorGrouped(m)
  if not m then return end
  local w,h=m.getSize(); local groups={ERROR={},MISSING={},CRAFT={},SENT={},MANUAL={},INFO={}}
  local cmap={ERROR=colors.red,MISSING=colors.orange,CRAFT=colors.green,SENT=colors.lime,MANUAL=colors.cyan,INFO=colors.yellow}
  local flat={}
  for _,line in ipairs(monitorLines) do for label in pairs(groups) do if line:find("%["..label.."%]") then groups[label][#groups[label]+1]=line; break end end end
  for _,label in ipairs({"ERROR","MISSING","CRAFT","SENT","MANUAL","INFO"}) do
    if #groups[label]>0 then flat[#flat+1]={text="== "..label.." ==",color=colors.white}; for _,s in ipairs(groups[label]) do flat[#flat+1]={text=s,color=cmap[label]} end end
  end
  local perPage=math.max(1,h-2); totalPages=math.max(1,math.ceil(#flat/perPage)); if currentPage>totalPages then currentPage=1 end
  for y=3,h do m.setCursorPos(1,y); m.write(string.rep(" ",w)) end
  local first=(currentPage-1)*perPage+1
  for i=first,math.min(first+perPage-1,#flat) do m.setCursorPos(1,3+i-first); m.setTextColor(flat[i].color); m.write(flat[i].text:sub(1,w)) end
end
local function setupPeripherals()
  term.clear(); term.setCursorPos(1,1)
  local b=peripheral.find("me_bridge") or error("me_bridge missing")
  local c=peripheral.find("colony_integrator") or error("colony_integrator missing")
  if not c.isInColony() then error("colony_integrator not in a colony") end
  return b,c,setupMonitor()
end
local function confirmConnection(b)
  local a,x=pcall(function() return b.isConnected() end); local c,y=pcall(function() return b.isOnline() end)
  return a and x==true and c and y==true
end
local exportBuffer={}
local function queueExport(name,nbt,count,target)
  if name and count and count>0 then exportBuffer[#exportBuffer+1]={name=name,nbt=nbt,count=count,target=target} end
end
local function countBridgeItems(b,name,nbt)
  local ok,items=pcall(function() return b.getItems({}) end)
  if not ok or type(items)~="table" then return nil end
  local total=0
  for _,entry in ipairs(items) do
    if entry.name==name and entry.nbt==nbt then
      total=total+(tonumber(entry.count) or 0)
    end
  end
  return total
end
local function processExportBuffer(b)
  for _,it in ipairs(exportBuffer) do
    local filter={name=it.name,count=it.count}; if it.nbt then filter.nbt=it.nbt end
    local before=countBridgeItems(b,it.name,it.nbt)
    logLine("[EXPORT DEBUG] filter="..dump(filter).." side="..exportSide.." before="..tostring(before))
    local ok,res,err=pcall(function() return b.exportItem(exportSide,filter) end)
    local after=countBridgeItems(b,it.name,it.nbt)
    local moved=0
    if before~=nil and after~=nil then moved=math.max(0,before-after) end
    -- Some AP versions can throw/return an error after partially moving the stack.
    -- Trust the observed ME inventory decrease over the API error response.
    if moved>0 then
      logAndDisplay(string.format("[SENT] x%d %s > %s",moved,it.name,tostring(it.target)))
      if moved<it.count then logLine(string.format("[EXPORT DEBUG] Partial export: requested=%d moved=%d",it.count,moved)) end
    elseif ok and type(res)=="table" and (tonumber(res.count) or 0)>0 then
      moved=tonumber(res.count)
      logAndDisplay(string.format("[SENT] x%d %s > %s",moved,it.name,tostring(it.target)))
    else
      local reason=not ok and res or err or (type(res)=="table" and "No items moved" or res)
      logAndDisplay("[ERROR] Export failed: "..it.name.." - "..tostring(reason or "No items moved"))
    end
    logLine("[EXPORT DEBUG] ok="..tostring(ok).." result="..dump(res).." err="..tostring(err).." before="..tostring(before).." after="..tostring(after).." moved="..tostring(moved))
  end
end

-- Read AE2 inventory and log every Domum stack with all useful metadata.
local function bridgeDataHandler(b)
  local byName={}; local ok,res,err=pcall(function() return b.getItems({}) end)
  if not ok or type(res)~="table" then logAndDisplay("[ERROR] ME Bridge getItems failed: "..tostring(err or res)); return byName end
  local n=0
  for _,it in ipairs(res) do
    if it.name then
      byName[it.name]=byName[it.name] or {}; table.insert(byName[it.name],it)
      if it.name:find("domum_ornamentum",1,true) then
        n=n+1
        logLine("[DOMUM DEBUG][AE2] #"..n.." name="..tostring(it.name).." count="..tostring(it.count).." nbt="..tostring(it.nbt).." nbtHash="..tostring(it.nbtHash).." components="..dump(it.components))
      end
    end
  end
  logLine("[DOMUM DEBUG][AE2] Total Domum stacks found="..n)
  return byName
end
local function requestNbt(it) return (type(it.nbt)=="string" and it.nbt) or it.nbtHash end
local function findBridgeItem(byName,it)
  if not it or not it.name then return nil end
  local c=byName[it.name]; if not c then return nil end
  local nbt=requestNbt(it)
  if nbt then for _,v in ipairs(c) do if v.nbt==nbt then return v end end; return nil end
  return c[1]
end
-- Domum variant matching: exact NBT first; otherwise compare complete texture_data.
-- Deliberately refuses a name-only match to avoid exporting the wrong material variant.
local function findDomumBridgeItem(byName,it)
  local candidates=byName[it.name] or {}; local nbt=requestNbt(it)
  local comps=it.components or {}; local wanted=comps["domum_ornamentum:texture_data"]
  logLine("[DOMUM DEBUG][REQUEST] name="..tostring(it.name).." count="..tostring(it.count).." nbt="..tostring(it.nbt).." nbtHash="..tostring(it.nbtHash).." components="..dump(it.components))
  if #candidates==0 then logLine("[DOMUM DEBUG][MATCH] No AE2 candidate with exact item name"); return nil end
  if nbt then
    for _,v in ipairs(candidates) do if v.nbt==nbt then logLine("[DOMUM DEBUG][MATCH] Exact NBT match"); return v end end
    logLine("[DOMUM DEBUG][MATCH] NBT mismatch; testing texture_data")
  else logLine("[DOMUM DEBUG][MATCH] Request has no string NBT; testing texture_data") end
  if type(wanted)~="table" then
    logLine("[DOMUM DEBUG][MATCH] Request has no texture_data table")
    -- Plain Domum materials can have no NBT or texture data. Match by registry
    -- name only if there is exactly one AE2 stack and it is also plain.
    if #candidates==1 then
      local candidate=candidates[1]
      local candidateComponents=candidate.components
      local hasComponents=type(candidateComponents)=="table" and next(candidateComponents)~=nil
      if candidate.nbt==nil and not hasComponents then
        logLine("[DOMUM DEBUG][MATCH] Unique plain item matched by registry name")
        return candidate
      end
      logLine("[DOMUM DEBUG][MATCH] Unique candidate has NBT/components; refusing name-only match")
    else
      logLine("[DOMUM DEBUG][MATCH] Name-only match is ambiguous; refusing export")
    end
    return nil
  end
  local matches={}
  for _,v in ipairs(candidates) do
    local got=v.components and v.components["domum_ornamentum:texture_data"]
    logLine("[DOMUM DEBUG][CANDIDATE] count="..tostring(v.count).." nbt="..tostring(v.nbt).." texture_data="..dump(got))
    if type(got)=="table" and dump(got)==dump(wanted) then matches[#matches+1]=v end
  end
  if #matches==1 then logLine("[DOMUM DEBUG][MATCH] Unique texture_data match"); return matches[1] end
  if #matches>1 then logLine("[DOMUM DEBUG][MATCH] Ambiguous texture_data match; no export") else logLine("[DOMUM DEBUG][MATCH] No exact texture_data match") end
  return nil
end
local function updateHeader(m,b,tick)
  if not m then return end
  local w=m.getSize(); local a,x=pcall(function() return b.isConnected() end); local c,y=pcall(function() return b.isOnline() end)
  local status=a and x==true and c and y==true
  local s=not a and "BRIDGE ERROR" or (not x and "NO GRID" or (not y and "GRID OFFLINE" or "AE2 ONLINE"))
  m.setCursorPos(1,1); m.setTextColor(colors.orange); m.write(string.rep(" ",w)); m.setCursorPos(1,1); m.write(scriptName.." v"..scriptVersion)
  m.setCursorPos(math.max(1,w-#s+1),1); m.setTextColor(status and colors.lime or colors.red); m.write(s)
  m.setCursorPos(1,2); m.setTextColor(colors.gray); m.write(string.rep("-",w)); m.setCursorPos(1,2); m.setTextColor(status and colors.green or colors.red)
  m.write(string.rep("#",math.max(0,math.min(w,math.floor((tick/scanInterval)*w)))))
end
local function handleMonitorTouch(m)
  if not m then return end; local name=peripheral.getName(m)
  while true do local _,side=os.pullEvent("monitor_touch"); if side==name then os.queueEvent("ae2colony_refresh") end end
end
local function colonyRequestHandler(c)
  local ok,res=pcall(function() return c.getRequests() end)
  if ok then if type(res)~="table" or not next(res) then return nil end; return res end
  alarm=res; logAndDisplay("[ERROR] colony_integrator getRequests failed: "..tostring(res)); os.sleep(1); return nil
end
local function gearNameHandler(req)
  local it=req and req.items and req.items[1]; local n=it and it.name
  if n=="minecraft:bow" or n=="minecraft:shield" then return n end
  local gear=string.lower(req.name or ""); local desc=string.lower(req.desc or "")
  local level=desc:match("maximal level:%s*(%w+)"); if not level then return nil end
  local typ; for key,val in pairs(gearTypes) do if gear:find(key,1,true) then typ=val; break end end
  local mat=gearMaterials[level]; if typ and mat then return typ:gsub("%$",mat) end
end
local function tagHandler(it)
  if it and whitelistItemName[it.name] then return true,true end
  if it and it.tags then for _,tag in pairs(it.tags) do if type(tag)=="string" and tag:find("c:foods",1,true) then return true,false end end end
  return false,nil
end
local function domumHandler(req,count)
  local it=req.items and req.items[1]; if not it then return end
  local display=req.displayName or req.description or req.name or it.name or "Unknown Domum item"
  logAndDisplay("[MANUAL] x"..tostring(count or req.count or 1).." "..tostring(display))
  logAndDisplay("[MANUAL] Item: "..tostring(it.name).." | request NBT: "..tostring(requestNbt(it) or "none"))
  local td=it.components and it.components["domum_ornamentum:texture_data"]
  if type(td)=="table" then for k,v in pairs(td) do logAndDisplay("[MANUAL] Material: "..tostring(k).." = "..tostring(v)) end
  else logAndDisplay("[MANUAL] WARNING: no domum_ornamentum:texture_data in request") end
end
local function craftHandler(req,b)
  local it=req.items and req.items[1]; if not it or not it.name then logAndDisplay("[ERROR] Cannot craft request: missing item name"); return end
  local count=(craftMaxStack and (it.maxStackSize or 64)) or (req.count or 1); if count<=0 then count=1 end
  local filter={name=it.name,count=count}; local nbt=requestNbt(it); if nbt then filter.nbt=nbt end
  local ok,craftable=pcall(function() return b.isCraftable(filter) end)
  if not ok then logAndDisplay("[ERROR] isCraftable failed for "..it.name..": "..tostring(craftable)); return end
  if craftable then
    local ok2,job,err=pcall(function() return b.craftItem(filter) end)
    if ok2 and type(job)=="table" then logAndDisplay("[CRAFT] Requested x"..count.." - "..it.name)
    else logAndDisplay("[ERROR] Craft rejected for "..it.name..": "..tostring(err or job)) end
  else logAndDisplay("[MISSING] No recipe x"..count.." - "..it.name) end
end

local function mainHandler(b,c)
  local requests=colonyRequestHandler(c); if not requests then logAndDisplay("[INFO] No colony requests detected"); return end
  local byName=bridgeDataHandler(b)
  for _,req in ipairs(requests) do
    local it=req.items and req.items[1]; local count=req.count or 0
    if it and it.name then
      local target=req.target or req.name or req.displayName or "Unknown Target"
      -- Special-case Domum BEFORE generic matching/autocrafting.
      if it.name:find("domum_ornamentum",1,true) then
        local found=findDomumBridgeItem(byName,it)
        if found then
          local available=tonumber(found.count) or 0; local send=math.min(available,count); local missing=count-send
          logAndDisplay(string.format("[INFO] Domum matched: %s | AE2=%d | requested=%d",it.name,available,count))
          if send>0 then queueExport(it.name,found.nbt,send,target) end
          if missing>0 then domumHandler(req,missing) end
        else
          domumHandler(req,count); logAndDisplay("[MISSING] "..it.name)
        end
      else
        local blacklisted,exception=tagHandler(it); local gear=gearNameHandler(req); local found=findBridgeItem(byName,it); local nbt=requestNbt(it)
        if blacklisted then
          if exception then local stock=(found and found.count) or 0; if stock>=count then queueExport(it.name,nbt,count,target) else craftHandler(req,b) end
          else logAndDisplay("[INFO] Tag blacklist; skipping x"..count.." "..it.name) end
        elseif gear then
          local ok,stock=pcall(function() return b.getItem({name=gear}) end)
          if ok and stock and (stock.count or 0)>0 then queueExport(gear,nil,count,target)
          else craftHandler({count=count,items={{name=gear,maxStackSize=it.maxStackSize}}},b) end
        elseif found then
          local stock=found.count or 0
          if stock>=count then queueExport(it.name,nbt,count,target)
          elseif stock>0 then queueExport(it.name,nbt,stock,target); craftHandler(req,b)
          else craftHandler(req,b) end
        else craftHandler(req,b) end
      end
    end
  end
end

cleanupOldLogs()
local bridge,colony,monitor=setupPeripherals()
local title=string.format("[INFO] %s v%s initialized - AP %s",scriptName,scriptVersion,apVersionText)
print(title); logLine(title)
local function main()
  local tick=scanInterval
  while true do
    exportBuffer={}; monitorLines={}; mainHandler(bridge,colony); processExportBuffer(bridge); updateMonitorGrouped(monitor)
    while tick>0 do
      if confirmConnection(bridge) then tick=tick-1 end
      updateHeader(monitor,bridge,tick)
      local timer=os.startTimer(1); local event,arg=os.pullEvent()
      while event~="ae2colony_refresh" and not (event=="timer" and arg==timer) do event,arg=os.pullEvent() end
      if event=="ae2colony_refresh" then tick=0 end
    end
    tick=scanInterval
  end
end
parallel.waitForAll(main,function() handleMonitorTouch(monitor) end)
