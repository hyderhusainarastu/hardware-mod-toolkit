# Photo shot list

The shots a board actually needs before a recon pass can stop asking for more photographs,
distilled from a real project's 16 numbered photo requests. Zero-risk, zero-disassembly shots are
listed first because they're free and often the single highest-value action available.

## Zero-risk shots (no disassembly)

1. **The device's exterior, as used, screen on if possible.** If the board drives a display,
   photographing the *product* -- not the board -- can settle the display technology, rough size,
   and colour-vs-monochrome in one frame that costs nothing and risks nothing. Do this before any
   board-level photography if the case is closed; on a real project this single shot was
   identified as "by a wide margin, the single highest-value action" for its display subsystem
   and was still outstanding when the recon otherwise concluded.
2. **Whole top side, board-upright**, straight down, even diffuse light. The index shot every
   other crop gets referenced against.
3. **Whole top side again, from a second angle/rotation**, as an independent cross-check on
   designators and layout -- a second full-board photo catches misreads the first one's crops
   propagate.
4. **Each module at a raking angle**, laser-etched top marking readable. See lighting rules below.
5. **Every connector and pad group, perpendicular, at pitch-resolving magnification**, with a
   steel rule or calipers in the same focal plane. This is the shot that turns a derived,
   ±10%-uncertain pitch into a measured one.
6. **Every test point**, one overview crop showing all of them with landmarks, so their relative
   positions survive into a pinout diagram.
7. **The battery label**, flat, legible without upscaling if possible -- chemistry, capacity, and
   model code are usually all on one printed label.
8. **The board's edges and any exposed connector/FPC**, straight down, to catch flex routing and
   fold geometry.

## Shots that need the owner's judgement (minor disassembly)

9. **Display FPC/flex, seated in its connector** -- low-angle shot sighting along the flex into
   the connector's cable slot, so the seating is silhouetted rather than occluded.
10. **Display FPC/flex, unseated, laid flat**, grazing light, to read any panel model string
    printed on the polyimide itself -- this is usually the fastest definitive panel identification
    and is very often skipped because it requires gently unmating a ZIF connector. **Never force
    a ZIF actuator** to get this shot; skip it if the flex or a battery lead would be stressed.
11. **The solder side**, full view plus quadrant macros -- only if the board can be lifted without
    stressing any flex cable or battery lead. This is frequently the only remaining photographic
    route to seeing where an unlabeled connector's traces actually go, once the component side has
    been exhausted.
12. **Solder side directly behind an unlabeled programming/pad-group footprint**, straight down,
    diffuse light (not raking -- raking blows out gold and hides low-contrast mask-over-copper
    shading), to see whether its traces fan out on the bottom layer and whether any escape is
    labeled.

## Lighting and angle reference

| Situation | Light | Angle | Why |
|---|---|---|---|
| Laser-etched marks on black IC/module packages | **Raking** (near-parallel to the surface), two exposures from opposite directions | Perpendicular camera | Etching is invisible under flat/overhead light; raking light is the only way the glyph strokes cast a shadow. Two directions distinguish a real glyph (visible both ways) from a lighting artifact (visible one way only). |
| Glossy module labels, white plastic | **Diffuse** (bounced off a white card), 1-2 stops under-exposed | Perpendicular | Direct light blows these out to unreadable white. |
| Anything being counted or measured (pin counts, pitch, span) | Even, from directly above | **Perpendicular, zero tilt** | An oblique shot foreshortens the exact dimension you're trying to measure. |
| Fine top-layer traces / distinguishing real copper from glare | **Two exposures, light swung to opposite sides**, differenced | Perpendicular | Specular glare moves between the two exposures; real copper doesn't. Differencing separates them. |
| Solder-side trace fan-out | **Diffuse**, not raking | Perpendicular | Raking blows out gold-plated vias/pads and hides the low-contrast shading that shows mask-over-copper. |

General rules that apply throughout:

- **Rotate the board**, not the image afterward, so the silkscreen reads upright in the
  viewfinder -- this keeps "as photographed" orientation trustworthy for later work.
- **Camera perpendicular** (not oblique) for anything being counted or measured; oblique framing
  is fine for a first read of a laser mark, where catching the light matters more than avoiding
  foreshortening.
- **Put a steel rule or calipers in the same focal plane** in at least one full-board shot. Every
  millimetre figure derived from an internal reference (a module's known castellation pitch, a
  connector's known body size) instead of a ruler carries a real, honestly-stated error margin
  until a ruler shot closes it.
- Take **two shots minimum** of anything load-bearing to a conclusion (a contact count, a value
  marking) so a second independent reading exists before the claim is graded above `POSSIBLE`.
