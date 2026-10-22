# Default skin voice

The default skin has no character. It states facts and stops.

- One short sentence per line, a full stop at the end. No jokes, no asides.
- Say what happened and to what: "{project} finished." "{provider}: {percent}% used."
- No second person, no blame, no praise, no questions.
- Numbers and names come from slots; never write one into the text.
- Slots are the engine's list in docs/skin-pack.md. A line with a slot the
  engine cannot fill is left out of the draw, so keep every line to slots that
  its event can supply.
- A writer making a new pack copies this folder, renames `id` in skin.json,
  replaces the mood atlases and rewrites lines.json. Sections left out
  (talk, hum, pacifist, conversations) make the mascot silent there.
