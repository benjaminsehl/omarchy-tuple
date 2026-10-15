-- Tuple window rules, loaded by ~/.local/state/omarchy/toggles/hypr/tuple.lua
-- (written by install.sh). See https://wiki.hypr.land/Configuring/Basics/Window-Rules/
--
-- The Tuple Linux client names its Wayland windows by role:
--   tuple-main, tuple-incoming-call, tuple-join-request, tuple-screen,
--   tuple-overlay, tuple-error, tuple-external-url, tuple-webcams
-- (all titled "Tuple").

-- Peer webcams: a picture-in-picture that floats above everything, follows you
-- across workspaces, and keeps its shape when resized. Drag with SUPER + left
-- mouse, resize with SUPER + right mouse — same as Omarchy's PiP windows.
o.window({ class = "^tuple-webcams$" }, {
  tag = "-default-opacity",
  float = true,
  pin = true,
  size = { "(monitor_h*0.32)", "(monitor_h*0.18)" },
  keep_aspect_ratio = true,
  no_initial_focus = true,
  no_dim = true,
  opacity = "1 1",
  -- Spelled out rather than window_w/window_h: those are the window's
  -- pre-rule size when move is evaluated.
  move = { "(monitor_w-monitor_h*0.32-40)", "(monitor_h-monitor_h*0.18-40)" },
})

-- The small prompts Tuple pops up (incoming call, join requests, errors,
-- "open this link?") are dialogs, not documents: float and center them.
o.window({ class = "^tuple-(incoming-call|join-request|error|external-url)$" }, {
  float = true,
  center = true,
})
