-- UI-scripting helper for scripts/ui-checks (System Events; needs Accessibility for the
-- terminal running it). Every command addresses the app by process id, never by name, so a
-- second WizRec copy that happens to be running is never touched.
--
--   osascript ax.applescript <command> <pid> [args…]
--
--   keys <pid> <key> [mods]   keystroke (or "esc"/"return"/"delete"/"up"/"down"); mods: any of "cmd,shift,opt,ctrl"
--   windows <pid>             window titles, one per line
--   raise <pid> <text>        app to front, the first window whose title contains <text> raised (main)
--   dump <pid>                every element: role | title | value | description | identifier
--   has <pid> <key>           "yes" when an element matches <key>
--   click <pid> <key>         press the first element matching <key>
--   check <pid> <key>         tick the checkbox matching <key> (no-op when ticked)
--   popup-items <pid> <key>   open the pop-up button matching <key>, list its items, close it
--   frame <pid> <key>         "x y w h" (screen points, top-left origin) of the element; app to front
--   enabled <pid> <key>       "true"/"false": AXEnabled of the element ("missing" when none matches)
--   toolbar <pid> <text>      the toolbar items of the first window whose title contains <text>:
--                             one "<description or title> | <enabled>" line each
--   toolbar-press <pid> <text> <name>  press the toolbar item <name> (description or title) of
--                             the first window whose title contains <text>
--   set <pid> <key> <text>    focus the text field matching <key>, set its text, press Return
--
-- <key> matches an element's title (AXTitle), its description (AXDescription) or its
-- accessibility identifier. SwiftUI controls here expose no title to System Events, so the app
-- gives the controls the checks use an `.accessibilityIdentifier`; AppKit alerts have titles.

-- Depth limit of `find`; lowered for the quick first pass over every window.
property maxDepth : 16

on run argv
	set cmd to item 1 of argv
	set pid to (item 2 of argv) as integer
	tell application "System Events"
		set p to first process whose unix id is pid
		if cmd is "keys" then
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
			else if k is "delete" then
				key code 51 using mods
			else if k is "up" then
				key code 126 using mods
			else if k is "down" then
				key code 125 using mods
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
		else if cmd is "raise" then
			set frontmost of p to true
			repeat with w in (windows of p)
				if (name of w as text) contains (item 3 of argv) then
					perform action "AXRaise" of w
					try
						set value of attribute "AXMain" of w to true
					end try
					delay 0.3
					return "ok"
				end if
			end repeat
			return "missing"
		else if cmd is "toolbar-press" then
			set frontmost of p to true
			repeat with w in (windows of p)
				if (name of w as text) contains (item 3 of argv) then
					repeat with t in (toolbars of w)
						repeat with b in (UI elements of t)
							repeat with c in ({contents of b} & (UI elements of b))
								if my attr(c, "AXDescription") is (item 4 of argv) or my attr(c, "AXTitle") is (item 4 of argv) then
									perform action "AXPress" of c
									return "ok"
								end if
							end repeat
						end repeat
					end repeat
				end if
			end repeat
			return "missing"
		else if cmd is "toolbar" then
			set out to ""
			repeat with w in (windows of p)
				if (name of w as text) contains (item 3 of argv) then
					repeat with t in (toolbars of w)
						repeat with b in (UI elements of t)
							set n to my attr(b, "AXDescription")
							if n is "" then set n to my attr(b, "AXTitle")
							-- Toolbar buttons may sit inside a group (one per item).
							if n is "" then
								repeat with c in (UI elements of b)
									set n to my attr(c, "AXDescription")
									if n is "" then set n to my attr(c, "AXTitle")
									if n is not "" then
										set out to out & n & " | " & my attr(c, "AXEnabled") & linefeed
									end if
								end repeat
							else
								set out to out & n & " | " & my attr(b, "AXEnabled") & linefeed
							end if
						end repeat
					end repeat
					return out
				end if
			end repeat
			return "missing"
		else if cmd is "dump" then
			set out to ""
			repeat with w in (windows of p)
				set out to out & "window: " & (name of w as text) & linefeed & my walk(w, "  ", 0)
			end repeat
			return out
		end if
		set wanted to item 3 of argv
		set e to missing value
		-- Sheets first (export sheet, alerts): a walk of a whole editor window takes seconds.
		repeat with w in (windows of p)
			try
				repeat with s in (sheets of w)
					set e to my find(s, wanted, 0)
					if e is not missing value then exit repeat
				end repeat
			end try
			if e is not missing value then exit repeat
		end repeat
		-- Then every window, shallow first (alert windows), then in full.
		repeat with limit in {1, 16}
			if e is not missing value then exit repeat
			set maxDepth to contents of limit
			repeat with w in (windows of p)
				set e to my find(w, wanted, 0)
				if e is not missing value then exit repeat
			end repeat
		end repeat
		if cmd is "has" then
			if e is missing value then return "no"
			return "yes"
		end if
		if e is missing value then return "missing"
		if cmd is "click" then
			perform action "AXPress" of e
			return "ok"
		else if cmd is "check" then
			if (value of e as integer) is 0 then perform action "AXPress" of e
			return "ok"
		else if cmd is "enabled" then
			return my attr(e, "AXEnabled")
		else if cmd is "frame" then
			-- Brings the app to the front: the caller is about to send real mouse events there.
			set frontmost of p to true
			set {x, y} to position of e
			set {w, h} to size of e
			return (x as text) & " " & (y as text) & " " & (w as text) & " " & (h as text)
		else if cmd is "set" then
			set frontmost of p to true
			set focused of e to true
			delay 0.2
			set value of e to (item 4 of argv)
			delay 0.2
			key code 36
			return "ok"
		else if cmd is "popup-items" then
			set frontmost of p to true
			perform action "AXPress" of e
			delay 0.5
			set out to ""
			repeat with mi in (every menu item of menu 1 of e)
				set out to out & (name of mi as text) & linefeed
			end repeat
			key code 53
			return out
		end if
	end tell
	error "unknown command " & cmd
end run

on attr(e, n)
	tell application "System Events"
		try
			set v to value of attribute n of e
			if v is missing value then return ""
			return v as text
		end try
	end tell
	return ""
end attr

on matches(e, wanted)
	if my attr(e, "AXTitle") is wanted then return true
	if my attr(e, "AXDescription") is wanted then return true
	if my attr(e, "AXIdentifier") is wanted then return true
	return false
end matches

-- Depth-first search below `e` (sheets included: they are children of their window).
on find(e, wanted, d)
	if d > maxDepth then return missing value
	tell application "System Events"
		set kids to {}
		try
			set kids to UI elements of e
		end try
		repeat with k in kids
			if my matches(k, wanted) then return contents of k
			set r to my find(k, wanted, d + 1)
			if r is not missing value then return r
		end repeat
	end tell
	return missing value
end find

on walk(e, ind, d)
	if d > 16 then return ""
	set out to ""
	tell application "System Events"
		set kids to {}
		try
			set kids to UI elements of e
		end try
		repeat with k in kids
			set out to out & ind & my attr(k, "AXRole") & " | " & my attr(k, "AXTitle") & " | " & my attr(k, "AXValue") & " | " & my attr(k, "AXDescription") & " | " & my attr(k, "AXIdentifier") & linefeed
			set out to out & my walk(k, ind & "  ", d + 1)
		end repeat
	end tell
	return out
end walk
