# Demo video — how it was actually made (read before presenting)

`INSIGHT_demo.mp4` (23 seconds, 1280x720) walks through the 5 core
scenarios: clear path, obstacle left, obstacle right, obstacle ahead
(STOP), and SOS.

**Be able to say exactly what this is if asked** — it is honest, but
not a raw screen recording:

- Every LED ON/OFF state shown is a **real screenshot captured from an
  actual running Wokwi simulation** via `wokwi-cli --screenshot-part
  --screenshot-time`, using the exact same firmware (`main.ino`) and
  circuit (`diagram.json`) as every other test in this project. The
  `source_assets/*_left.png` / `*_right.png` files are those raw
  captures — nothing about the LED states is invented.
- The distance values and `DECISION ... reason=` text shown on each
  slide are the **actual Serial log output** from that same simulation
  run (`wokwi/video_demo_scenario.yaml` is the exact script used).
- What's NOT a raw recording: Wokwi's screenshot tool only captures one
  component at a time (not the whole circuit board at once), so the
  layout — title, captions, the two motor circles side by side — was
  composited from those real screenshots using a Python script
  (`source_assets/build_video.py`), not screen-recorded directly from
  the Wokwi website/app. The ON/OFF color of each circle is read
  programmatically from the real screenshot's pixel brightness, not
  hand-set. The individual composite slide images
  (`source_assets/slide_*.png`) are also there if you want a single
  still image for a slide deck instead of the video.

If your panel asks to see it running live instead: open `wokwi/` in
the Wokwi VS Code extension or wokwi.com (see README.md §7 "Option A"),
or run `wokwi-cli . --scenario test_scenario.yaml` for the full
automated pass/fail evidence (§8, and `docs/PRE_HARDWARE_VALIDATION_REPORT.md`).

To rebuild the video after any firmware change: re-run the
`wokwi-cli --screenshot-part/--screenshot-time` capture commands (ask
Claude to regenerate), then `python source_assets/build_video.py` from
this folder.
