-- Keep only your personal keybinding overrides here. Add new bindings or
-- unbind defaults before replacing them.

-- See current bindings and descriptions:
--   omarchy menu keybindings --print

-- To disable every Omarchy default binding, set this in
-- ~/.config/hypr/hyprland.lua before require("default.hypr.omarchy"), then add
-- only the bindings you want below:
--   omarchy_default_bindings = false

-- To disable all preinstalled app/webapp bindings, set:
--   omarchy_preinstalled_bindings = false

-- Add a new binding.
-- o.bind("SUPER + SHIFT + R", "SSH", "alacritty -e ssh your-server")

-- Change an existing binding by unbinding it first, then binding the key again.
-- This example changes SUPER+SPACE from the launcher to the Omarchy root menu.
-- hl.unbind("SUPER + SPACE")
-- o.bind("SUPER + SPACE", "Omarchy menu", "omarchy-menu toggle root")


-- Disable a default binding without replacing it.
-- hl.unbind("SUPER + SHIFT + B")

-- Logitech MX Keys examples:
-- o.bind("SUPER + SHIFT + S", nil, "omarchy-capture-screenshot")
-- o.bind("SUPER + H", nil, "voxtype record toggle")
-- o.bind("SUPER + PERIOD", nil, "omarchy-shell shell toggle omarchy.emojis")

hl.unbind("SUPER + L")
hl.unbind("SUPER + J")
hl.unbind("SUPER + K")
hl.unbind("SUPER + Q")
hl.unbind("SUPER + SPACE")
hl.unbind("ALT + SPACE")


o.bind("SUPER + ALT + K", "Keybindings", "omarchy-menu-keybindings")

o.bind("SUPER + H", "Focus on left window", hl.dsp.focus({ direction = "left" }))
o.bind("SUPER + L", "Focus on right window", hl.dsp.focus({ direction = "right" }))
o.bind("SUPER + K", "Focus on window above", hl.dsp.focus({ direction = "up" }))
o.bind("SUPER + J", "Focus on window below", hl.dsp.focus({ direction = "down" }))

o.bind("SUPER + SHIFT + H", "Swipe window to the left", hl.dsp.window.move({ direction = "left" }))
o.bind("SUPER + SHIFT + L", "Swipe window to the right", hl.dsp.window.move({ direction = "right" }))
o.bind("SUPER + SHIFT + K", "Swipe window up", hl.dsp.window.move({ direction = "up" }))
o.bind("SUPER + SHIFT + J", "Swipe window down", hl.dsp.window.move({ direction = "down" }))


hl.unbind("SUPER + c")
hl.unbind("SUPER + S")
hl.unbind("SUPER + v")
hl.unbind("SUPER + w")

o.bind("SUPER + C", "close window", hl.dsp.window.close())

hl.unbind("SUPER + RETURN")
hl.unbind("SUPER + SHIFT + RETURN")

o.bind("SUPER + W", "Browser", "brave --disable-gpu-memory-buffer-video-frames")
o.bind("SUPER + Q", "Terminal", { launch = "kitty" })

o.bind("SUPER + SHIFT + Q", "Screensaver", "omarchy-launch-screensaver")
o.bind("SUPER + S", "Minesweeper", "omarchy-shell shell toggle jankeesvw.omasweeper")

