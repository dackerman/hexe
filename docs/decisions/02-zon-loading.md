# ZON loading details (Zig 0.17.1)

**Context**: Materials and scenarios are loaded at runtime with `std.zon`.
The 0.17 API and the I/O model differ from older Zig, and some schema
spellings collide with Zig syntax.

**Decision**:
- Parse with `std.zon.parse.fromSlice(T, .{ .gpa, .arena, .source, .diagnostics })`.
  Results (strings, slices) live in the arena owned by the `MaterialSet` /
  `Scenario`; `Diagnostics.fmt(path)` gives `path:line:col: error: …` for
  syntax errors, unknown fields and missing required fields (e.g. a missing
  `.ramp`). The source must be `[:0]const u8`, so it is copied with
  `dupeSentinel`.
- All numeric schema fields parse as `i32` (ramp colors as `u32`) and are
  range-checked by the loader, so a bad value reports
  `materials/x.zon: .conductivity: 300 out of range 0–255` instead of a
  parser overflow.
- Every problem in every file is collected before failing; loading returns
  `error.InvalidMaterials` with a `Diagnostics` list, never panics.
- `.name` must equal the file stem; names are `[a-z0-9_]+`.
- The blast response `.break` is a Zig keyword; ZON spells it `.@"break"`.
- Files are read through `std.Io.Dir` (`openDir(.iterate)`, `readFileAlloc`,
  `statFile` for mtimes), so callers pass an `Io` (`std.process.Init.io` in
  `main`, `std.testing.io` in tests).
- Paths: the `build_options` module gives `materials_dir = "materials"` and
  `scenarios_dir = "scenarios"` relative to the build root; the data test
  run sets its cwd to the build root and has side effects enabled so edits
  to data files rerun the tests.

**Alternatives**: `@import` of ZON at compile time (no hot reload). JSON
(no comments, no enum literals, not the project's data format).

**Consequences**: A typo'd field name is caught with a line number. The
`.@"break"` spelling is the one wart authors see.
