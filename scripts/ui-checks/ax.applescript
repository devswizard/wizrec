-- UI-scripting helper for scripts/ui-checks (System Events; needs Accessibility for the
-- terminal running it). Every command addresses the app by process id, never by name, so a
-- second WizRec copy that happens to be running is never touched.
--
--   osascript ax.applescript <command> <pid> [args…]
--
--   front                         bring the process to the front
--   keys <pid> <key> [mods]       keystroke; mods: any of "cmd,shift,opt,ctrl"
--   windows <pid>                 window titles, one per line
--   window-count <pid>
--   buttons <pid>                 names of every button in windows, sheets and dialogs
--   click <pid> <name>            click the first button named <name> (windows, sheets, dialogs)
--   check <pid> <name>            tick the checkbox named <name> (no-op when already ticked)
--   toolbar <pid> <window> <name> click the toolbar item named <name> in window <window>
--   texts <pid> <window>          every static text, radio button and pop-up value in <window>
--   menu <pid> <menu> <item>      click menu bar <menu> ▸ <item>

on run argv
	set cmd to item 1 of argv
	set pid to (item 2 of argv) as integer
	tell application "System Events"
		set p to first process whose unix id is pid
		if cmd is "front" then
			set frontmost of p to true
			return "ok"
		else if cmd is "keys" then
			set frontmost of p to true
			delay 0.2
			set k to item 3 of argv
			set mods to {}
			if (count of argv) > 3 then
				set m to item 4 of argv
				if m contains "cmd" then set end of mods to command down
				if m contains "shift" then set end of mods to shift down
				if m contains "opt" then set end of mods to option down
				if m contains "ctrl" then set end of mods to control down
			end if
			if k is "esc" then
				key code 53 using mods
			else if k is "return" then
				key code 36 using mods
			else
				keystroke k using mods
			end if
			return "ok"
		else if cmd is "windows" then
			set out to ""
			repeat with w in (windows of p)
				set out to out & (name of w as text) & linefeed
			end repeat
			return out
		else if cmd is "window-count" then
			return (count of windows of p) as text
		else if cmd is "buttons" then
			set out to ""
			repeat with w in (windows of p)
				repeat with b in my allButtons(w)
					set out to out & (name of b as text) & linefeed
				end repeat
			end repeat
			return out
		else if cmd is "click" then
			set target to item 3 of argv
			repeat with w in (windows of p)
				repeat with b in my allButtons(w)
					if (name of b as text) is target then
						click b
						return "ok"
					end if
				end repeat
			end repeat
			return "missing"
		else if cmd is "check" then
			set target to item 3 of argv
			repeat with w in (windows of p)
				set boxes to {}
				try
					set boxes to (every checkbox of entire contents of w)
				end try
				repeat with c in boxes
					if (name of c as text) is target then
						if (value of c as integer) is 0 then click c
						return "ok"
					end if
				end repeat
			end repeat
			return "missing"
		else if cmd is "toolbar" then
			set w to window (item 3 of argv) of p
			set target to item 4 of argv
			repeat with b in (every button of toolbar 1 of w)
				if (name of b as text) is target or (description of b as text) is target then
					click b
					return "ok"
				end if
			end repeat
			return "missing"
		else if cmd is "texts" then
			set w to window (item 3 of argv) of p
			set out to ""
			repeat with e in (entire contents of w)
				try
					set r to role of e
					if r is "AXStaticText" then
						set out to out & "text: " & (value of e as text) & linefeed
					else if r is "AXRadioButton" then
						set out to out & "radio: " & (name of e as text) & " = " & (value of e as text) & linefeed
					else if r is "AXPopUpButton" then
						set out to out & "popup: " & (value of e as text) & linefeed
					else if r is "AXMenuItem" then
						set out to out & "item: " & (name of e as text) & linefeed
					end if
				end try
			end repeat
			return out
		else if cmd is "popup-items" then
			-- Opens the first pop-up button of <window>, lists its menu items, closes it.
			set frontmost of p to true
			set w to window (item 3 of argv) of p
			set pb to missing value
			repeat with e in (entire contents of w)
				try
					if role of e is "AXPopUpButton" then
						set pb to e
						exit repeat
					end if
				end try
			end repeat
			if pb is missing value then return "missing"
			click pb
			delay 0.5
			set out to ""
			repeat with mi in (every menu item of menu 1 of pb)
				set out to out & (name of mi as text) & linefeed
			end repeat
			key code 53
			return out
		else if cmd is "menu" then
			set frontmost of p to true
			click menu item (item 4 of argv) of menu (item 3 of argv) of menu bar item (item 3 of argv) of menu bar 1 of p
			return "ok"
		end if
	end tell
	error "unknown command " & cmd
end run

-- Buttons of a window plus those of its sheets (alerts shown as sheets).
on allButtons(w)
	tell application "System Events"
		set bs to {}
		try
			set bs to bs & (every button of w)
		end try
		try
			repeat with s in (every sheet of w)
				set bs to bs & (every button of s)
				try
					set bs to bs & (every button of every group of s)
				end try
			end repeat
		end try
		try
			set bs to bs & (every button of every group of w)
		end try
		return bs
	end tell
end allButtons
