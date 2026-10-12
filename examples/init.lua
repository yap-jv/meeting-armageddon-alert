hs.loadSpoon("MeetingAlert")

spoon.MeetingAlert:configure({
    autoJoin = true,
    soundName = "Sosumi",
    dismissKey = { { "cmd", "shift" }, "return" },
    urlFile = os.getenv("HOME") .. "/.hammerspoon/meet_ics_url.txt",
    refreshInterval = 300,
    tickInterval = 20,
    lateGrace = 300,
    horizon = 36 * 3600,
}):start()

hs.autoLaunch(true)
require("hs.ipc")
