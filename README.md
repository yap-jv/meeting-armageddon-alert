# MeetingAlert

A [Hammerspoon](https://www.hammerspoon.org) Spoon that makes sure you never miss a meeting.

At the start time of any Google Calendar event with a Google Meet link it:

- takes over the screen with a full-screen red alarm and plays a sound on loop
- opens the Meet link for you
- stays there until you press **⌘⇧Return**

It reads your calendar's private iCal feed over HTTPS. No Calendar.app, no OAuth, no macOS automation
permissions. The feed URL never leaves your Mac.

## Install

1. Install Hammerspoon: `brew install --cask hammerspoon`, then open it once and grant the Accessibility permission
   it asks for.
2. Clone and link the Spoon:

   ```bash
   git clone git@github.com:yap-jv/meeting-armageddon-alert.git ~/code/meeting-armageddon-alert
   mkdir -p ~/.hammerspoon/Spoons
   ln -s ~/code/meeting-armageddon-alert/MeetingAlert.spoon ~/.hammerspoon/Spoons/MeetingAlert.spoon
   ```

3. Get your calendar's secret iCal URL: Google Calendar → hover your calendar → ⋮ → **Settings and sharing** →
   **Integrate calendar** → copy **Secret address in iCal format**.
4. Save it as `~/.hammerspoon/meet_ics_url.txt`, one URL per line (several calendars are fine, `#` starts a comment):

   ```bash
   echo 'https://calendar.google.com/calendar/ical/.../basic.ics' > ~/.hammerspoon/meet_ics_url.txt
   ```

5. Add this to `~/.hammerspoon/init.lua`:

   ```lua
   hs.loadSpoon("MeetingAlert")
   spoon.MeetingAlert:start()
   ```

6. Hammerspoon menu bar icon → **Reload Config**.

Treat the secret URL like a password: anyone who has it can read your calendar. Never commit it or paste it in chat.

To update later: `git -C ~/code/meeting-armageddon-alert pull`, then reload Hammerspoon.

## Configuration

Ready-to-copy examples live in [`examples/`](examples): [`init.lua`](examples/init.lua) with every option set to its
default, and [`meet_ics_url.txt.example`](examples/meet_ics_url.txt.example) for the feed URL file.

```lua
hs.loadSpoon("MeetingAlert")
spoon.MeetingAlert:configure({
    autoJoin = false,
    soundName = "Glass",
    dismissKey = { { "ctrl", "alt" }, "escape" },
}):start()
```

| Option            | Default                       | Meaning                                                          |
| ----------------- | ----------------------------- | ---------------------------------------------------------------- |
| `autoJoin`        | `true`                        | Open the Meet link at start time. `false` = alarm only           |
| `soundName`       | `"Sosumi"`                    | Any macOS system sound name                                      |
| `dismissKey`      | `{ { "cmd", "shift" }, "return" }` | Hotkey that dismisses the alarm                             |
| `urlFile`         | `~/.hammerspoon/meet_ics_url.txt`  | Where the feed URL(s) live                                  |
| `refreshInterval` | `300`                         | Seconds between calendar downloads                               |
| `tickInterval`    | `20`                          | Seconds between "has a meeting started?" checks                  |
| `lateGrace`       | `300`                         | Seconds after the start time that a meeting still fires          |
| `horizon`         | `36 * 3600`                   | How far ahead events are loaded                                  |

## Try it and debug it

Open the Hammerspoon Console and run:

```lua
spoon.MeetingAlert:testAlarm("Standup")   -- shows the alarm now
spoon.MeetingAlert:status()               -- feeds, last fetch, last error, upcoming meetings
spoon.MeetingAlert:refresh()              -- re-download the calendar now
```

## Good to know

- Only events with a `meet.google.com` link (in the conference data, location or description) fire.
- Cancelled events and cancelled/moved instances of recurring events are skipped.
- Reloading Hammerspoon within `lateGrace` seconds after a meeting started fires its alarm again. That is on purpose,
  so a reboot mid-meeting still alerts you.
- Google's iCal feed can lag a few minutes behind calendar changes.
- It is aggressive on purpose. If it's too much, set `autoJoin = false` or change the dismiss key.

## Troubleshooting

| Symptom                          | Check                                                                              |
| -------------------------------- | ---------------------------------------------------------------------------------- |
| Nothing fires                    | `spoon.MeetingAlert:status()`. Does it list your meeting? Is "Last error" empty?    |
| `No calendar URL in ...`         | `meet_ics_url.txt` is missing or empty                                              |
| `HTTP 404` / `HTTP 403`          | The secret URL was reset in Google Calendar. Copy the new one                       |
| No sound                         | Check `soundName`, and that the Mac isn't muted                                     |
| Hotkey does nothing              | Hammerspoon needs Accessibility permission (System Settings → Privacy & Security)   |

## License

MIT
