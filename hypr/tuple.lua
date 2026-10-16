-- Tuple window rules, loaded by ~/.local/state/omarchy/toggles/hypr/tuple.lua
-- (written by install.sh). See https://wiki.hypr.land/Configuring/Basics/Window-Rules/
--
-- Tuple v2026_09_16.1 draws all of its windows over X11 with class "Tuple" and
-- no title. bin/tuple-windows names each one after its role (tuple-webcams,
-- tuple-screen, tuple-join-request, …) and does the placement that has to
-- happen after the window maps: the camera stage, centring prompts.

-- Video shouldn't be see-through: opt Tuple's windows out of Omarchy's
-- default opacity.
o.window({ class = "^Tuple$" }, {
  tag = "-default-opacity",
  opacity = "1 1",
  no_dim = true,
})

-- Your camera (bin/tuple-selfcam): a square tile that appears straight in the
-- bottom-right corner. tuple-windows lines it up with their webcam.
o.window({ class = "^tuple-selfcam$" }, {
  tag = "-default-opacity",
  float = true,
  pin = true,
  size = { "(monitor_h*0.18)", "(monitor_h*0.18)" },
  move = { "(monitor_w-monitor_h*0.18-40)", "(monitor_h-monitor_h*0.18-40)" },
  keep_aspect_ratio = true,
  no_initial_focus = true,
  no_dim = true,
  opacity = "1 1",
})

-- Should a future Tuple open its webcam window natively on Wayland, it uses
-- this app id; treat it like the X11 one.
o.window({ class = "^tuple-webcams$" }, {
  tag = "-default-opacity",
  float = true,
  pin = true,
  keep_aspect_ratio = true,
  no_initial_focus = true,
  no_dim = true,
  opacity = "1 1",
})

o.window({ class = "^tuple-(incoming-call|join-request|error|external-url)$" }, {
  float = true,
  center = true,
})
