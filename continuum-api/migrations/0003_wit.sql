-- 0003: store each version's synthesized WIT world (the published contract).
--
-- The Continuum stores SOURCE archives, not compiled wasm, so the WIT world is
-- not an archive artifact. It is synthesized by the toolchain at publish (the
-- same way `capabilities` is — `qube publish` runs the compiler) and uploaded
-- alongside the manifest. A library's surface IS its world; this column makes
-- the registry a browsable interface catalogue (WIT rung 3). Nullable: older
-- versions and non-component qubes carry no world.
ALTER TABLE versions ADD COLUMN wit TEXT;
