--- === MeetingAlert ===
---
--- Full-screen alarm + auto-join at meeting start time.
---
--- Reads your Google Calendar's private iCal (.ics) feed directly over HTTPS.
--- No Calendar.app, no Apple events, no macOS automation permissions.
---
--- Every `refreshInterval` seconds the feed(s) are downloaded in the background and
--- parsed. Every `tickInterval` seconds the script checks whether an event has just
--- hit its start time. At start time it shows a full-screen alarm and opens the
--- Google Meet link. Events without a Meet link are ignored.
---
--- Reloading within `lateGrace` seconds after a meeting starts re-fires its alarm;
--- that is deliberate, so a reboot mid-meeting still alerts you.

local obj = {}
obj.__index = obj

obj.name = "MeetingAlert"
obj.version = "1.0.0"
obj.author = "Yann Parent"
obj.license = "MIT - https://opensource.org/licenses/MIT"

obj.tickInterval = 20
obj.refreshInterval = 300
obj.lateGrace = 300
obj.horizon = 36 * 3600
obj.soundName = "Sosumi"
obj.dismissKey = { { "cmd", "shift" }, "return" }
obj.urlFile = os.getenv("HOME") .. "/.hammerspoon/meet_ics_url.txt"
obj.autoJoin = true
obj.logger = hs.logger.new("MeetingAlert", "info")

local SYSTEM_TZID
local MEET_FIELDS = { "X%-GOOGLE%-CONFERENCE", "LOCATION", "DESCRIPTION" }
local WEEKDAYS = { SU = 1, MO = 2, TU = 3, WE = 4, TH = 5, FR = 6, SA = 7 }

--- iCal parsing -------------------------------------------------------------

local function systemTZID()
    local out = hs.execute("readlink /etc/localtime 2>/dev/null")
    return out and out:gsub("%s+$", ""):match("zoneinfo/(.+)$")
end

local function epochAtZone(y, mo, d, h, mi, s, tzid)
    if not tzid or tzid == "" or tzid == SYSTEM_TZID then
        return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s })
    end
    if not tzid:match("^[%w_+%-/]+$") then return nil end
    local cmd = string.format(
        "TZ=%s /bin/date -j -f '%%Y%%m%%dT%%H%%M%%S' '%04d%02d%02dT%02d%02d%02d' '+%%s' 2>/dev/null",
        tzid, y, mo, d, h, mi, s)
    local out = hs.execute(cmd)
    return out and tonumber((out:gsub("%s+$", "")))
end

local function extractTZID(params)
    return params and params:match("TZID=([%w_+%-/]+)")
end

local function icalToEpoch(value, tzid)
    local y, mo, d, h, mi, s = value:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)")
    if not y then return nil end
    y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
    if value:sub(-1) == "Z" then
        return epochAtZone(y, mo, d, h, mi, s, "UTC")
    end
    return epochAtZone(y, mo, d, h, mi, s, tzid)
end

local function dayNumber(epoch)
    local t = os.date("*t", epoch)
    return math.floor(os.time({ year = t.year, month = t.month, day = t.day, hour = 12 }) / 86400)
end

local function unfold(body)
    return (body:gsub("\r\n", "\n"):gsub("\n[ \t]", ""))
end

local function prop(block, name)
    local rest = block:match("\n" .. name .. "([;:][^\n]*)")
    if not rest then return nil, "" end
    if rest:sub(1, 1) == ":" then return rest:sub(2), "" end
    local params, value = rest:match("^(;[^:]*):(.*)$")
    return value, params or ""
end

local function findMeetURL(block)
    for _, name in ipairs(MEET_FIELDS) do
        local text = prop(block, name)
        if text and text ~= "" then
            local url = text:gsub("\\", ""):match("(https?://meet%.google%.com/[%w%-]+)")
            if url then return url end
        end
    end
    return nil
end

local function parseRRule(rule)
    local r = {}
    for k, v in rule:gmatch("([A-Z%-]+)=([^;]*)") do r[k] = v end
    return r
end

local function ruleMatches(rrule, dtstart, candidate)
    local r = parseRRule(rrule)
    local interval = tonumber(r.INTERVAL) or 1
    local freq = r.FREQ

    if r.UNTIL then
        local untilEpoch = icalToEpoch(r.UNTIL)
        if untilEpoch and candidate > untilEpoch then return false end
    end

    local a, b = os.date("*t", dtstart), os.date("*t", candidate)

    if freq == "DAILY" then
        return (dayNumber(candidate) - dayNumber(dtstart)) % interval == 0
    elseif freq == "WEEKLY" then
        local weeks = math.floor((dayNumber(candidate) - dayNumber(dtstart)) / 7)
        if weeks % interval ~= 0 then return false end
        if r.BYDAY and r.BYDAY ~= "" then
            for code in r.BYDAY:gmatch("[A-Z][A-Z]") do
                if WEEKDAYS[code] == b.wday then return true end
            end
            return false
        end
        return a.wday == b.wday
    elseif freq == "MONTHLY" then
        local months = (b.year - a.year) * 12 + (b.month - a.month)
        return months % interval == 0 and a.day == b.day
    elseif freq == "YEARLY" then
        return (b.year - a.year) % interval == 0 and a.month == b.month and a.day == b.day
    end
    return false
end

local function parseICS(body, lateGrace, horizon)
    local out, overrides = {}, {}
    body = unfold(body)

    for block in body:gmatch("BEGIN:VEVENT(.-)END:VEVENT") do
        block = "\n" .. block
        local recurrenceId, recurrenceParams = prop(block, "RECURRENCE%-ID")
        if recurrenceId then
            local uid = prop(block, "UID") or ""
            local e = icalToEpoch(recurrenceId, extractTZID(recurrenceParams))
            if e then overrides[uid .. "@" .. e] = true end
        end
    end

    local now = os.time()

    for block in body:gmatch("BEGIN:VEVENT(.-)END:VEVENT") do
        block = "\n" .. block
        local status = prop(block, "STATUS")
        local meetURL = findMeetURL(block)
        local dtstartRaw, dtstartParams = prop(block, "DTSTART")
        local dtstart = dtstartRaw and icalToEpoch(dtstartRaw, extractTZID(dtstartParams))

        if meetURL and dtstart and status ~= "CANCELLED" then
            local title = (prop(block, "SUMMARY") or "Meeting"):gsub("\\,", ","):gsub("\\n", " ")
            local uid = prop(block, "UID") or title
            local rrule = prop(block, "RRULE")

            local excluded = {}
            local exdateRaw, exdateParams = prop(block, "EXDATE")
            if exdateRaw then
                local exdateTZID = extractTZID(exdateParams)
                for part in exdateRaw:gmatch("[^,]+") do
                    local e = icalToEpoch(part, exdateTZID)
                    if e then excluded[e] = true end
                end
            end

            local starts = {}
            if not rrule or rrule == "" then
                if dtstart > now - lateGrace and dtstart < now + horizon then
                    starts[#starts + 1] = dtstart
                end
            else
                local base = os.date("*t", dtstart)
                for offset = 0, 2 do
                    local probe = os.date("*t", now + offset * 86400)
                    local candidate = os.time({
                        year = probe.year, month = probe.month, day = probe.day,
                        hour = base.hour, min = base.min, sec = base.sec,
                    })
                    if candidate >= dtstart - 60
                        and candidate > now - lateGrace and candidate < now + horizon
                        and not excluded[candidate]
                        and not overrides[uid .. "@" .. candidate]
                        and ruleMatches(rrule, dtstart, candidate) then
                        starts[#starts + 1] = candidate
                    end
                end
            end

            for _, startAt in ipairs(starts) do
                out[#out + 1] = {
                    title = title, url = meetURL, startAt = startAt,
                    key = uid .. "@" .. startAt,
                }
            end
        end
    end

    table.sort(out, function(x, y) return x.startAt < y.startAt end)
    return out
end

--- Alarm --------------------------------------------------------------------

function obj:stopAlarm()
    if self._alarmLoopTimer then self._alarmLoopTimer:stop(); self._alarmLoopTimer = nil end
    if self._alarmCanvas then self._alarmCanvas:delete(); self._alarmCanvas = nil end
    return self
end

function obj:startAlarm(title, headline)
    self:stopAlarm()
    local screen = hs.screen.mainScreen():fullFrame()
    local dismissLabel = table.concat(self.dismissKey[1], "+") .. "+" .. self.dismissKey[2]

    local canvas = hs.canvas.new(screen)
    canvas[1] = { type = "rectangle", action = "fill", fillColor = { red = 0.85, alpha = 0.95 } }
    canvas[2] = {
        type = "text",
        text = (headline or "MEETING STARTING NOW") .. "\n\n" .. title ..
               "\n\nPress " .. dismissLabel .. " to dismiss",
        textSize = 42, textAlignment = "center", textColor = { white = 1 },
        frame = { x = 0, y = screen.h / 2 - 100, w = screen.w, h = 200 },
    }
    canvas:level(hs.canvas.windowLevels.screenSaver)
    canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    canvas:show()
    self._alarmCanvas = canvas

    local sound = hs.sound.getByName(self.soundName)
    if sound then
        self._alarmLoopTimer = hs.timer.doEvery(1.2, function() sound:play() end)
    end
    return self
end

--- Fetch --------------------------------------------------------------------

function obj:_readURLs()
    local f = io.open(self.urlFile, "r")
    if not f then return {} end
    local urls = {}
    for line in f:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and not line:match("^#") then
            urls[#urls + 1] = (line:gsub("^webcal://", "https://"))
        end
    end
    f:close()
    return urls
end

function obj:refresh()
    local urls = self:_readURLs()
    if #urls == 0 then
        self._lastError = "No calendar URL in " .. self.urlFile
        return self
    end

    local collected, pending = {}, #urls
    for _, url in ipairs(urls) do
        hs.http.asyncGet(url, nil, function(status, body)
            if status == 200 and body then
                local ok, parsed = pcall(parseICS, body, self.lateGrace, self.horizon)
                if ok then
                    for _, e in ipairs(parsed) do collected[#collected + 1] = e end
                else
                    self._lastError = "Parse failed: " .. tostring(parsed)
                    self.logger.e(self._lastError)
                end
            else
                self._lastError = "HTTP " .. tostring(status)
                self.logger.e("fetch failed: " .. self._lastError)
            end

            pending = pending - 1
            if pending == 0 then
                table.sort(collected, function(x, y) return x.startAt < y.startAt end)
                self._events = collected
                self._lastFetch = os.time()
                if #collected > 0 then self._lastError = nil end
                self.logger.i(string.format("%d upcoming meeting(s) with Meet links", #collected))
            end
        end)
    end
    return self
end

--- Trigger ------------------------------------------------------------------

function obj:_tick()
    local now = os.time()
    for _, e in ipairs(self._events) do
        local secsUntil = e.startAt - now
        if secsUntil <= 0 and secsUntil > -self.lateGrace and not self._joined[e.key] then
            self._joined[e.key] = true
            self.logger.i("firing: " .. e.title .. " -> " .. e.url)
            self:startAlarm(e.title, "MEETING STARTING NOW")
            if self.autoJoin then hs.urlevent.openURL(e.url) end
        end
    end
end

--- MeetingAlert:configure(options)
--- Method
--- Overrides any of the public fields (tickInterval, refreshInterval, lateGrace, horizon,
--- soundName, dismissKey, urlFile, autoJoin) from a table.
function obj:configure(options)
    for k, v in pairs(options or {}) do self[k] = v end
    return self
end

--- MeetingAlert:start()
--- Method
--- Binds the dismiss hotkey, starts the timers and fetches the calendar feed(s).
function obj:start()
    self:stop()
    SYSTEM_TZID = systemTZID()
    self._events = {}
    self._joined = {}
    self._hotkey = hs.hotkey.bind(self.dismissKey[1], self.dismissKey[2], function() self:stopAlarm() end)
    self._refreshTimer = hs.timer.doEvery(self.refreshInterval, function() self:refresh() end)
    self._tickTimer = hs.timer.doEvery(self.tickInterval, function() self:_tick() end)
    self:refresh()
    return self
end

--- MeetingAlert:stop()
--- Method
--- Stops the timers, removes the hotkey and dismisses any alarm.
function obj:stop()
    if self._hotkey then self._hotkey:delete(); self._hotkey = nil end
    if self._refreshTimer then self._refreshTimer:stop(); self._refreshTimer = nil end
    if self._tickTimer then self._tickTimer:stop(); self._tickTimer = nil end
    self:stopAlarm()
    return self
end

--- MeetingAlert:testAlarm(title)
--- Method
--- Shows the alarm immediately so you can check the look, sound and dismiss key.
function obj:testAlarm(title)
    return self:startAlarm(title or "Test meeting", "TEST ALARM")
end

--- MeetingAlert:status()
--- Method
--- Returns a human readable summary of feeds, last fetch, last error and upcoming meetings.
function obj:status()
    local events = self._events or {}
    local lines = {
        "URL file: " .. self.urlFile .. " (" .. #self:_readURLs() .. " feed(s))",
        "Last fetch: " .. (self._lastFetch and os.date("%H:%M:%S", self._lastFetch) or "never"),
        "Last error: " .. (self._lastError or "none"),
        "Upcoming with Meet links: " .. #events,
    }
    for _, e in ipairs(events) do
        lines[#lines + 1] = string.format("  %s  %s", os.date("%a %d %b %H:%M", e.startAt), e.title)
    end
    return table.concat(lines, "\n")
end

obj._parseICS = parseICS

return obj
