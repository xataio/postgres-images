# Replace xatautils with the white label build of the security library.
# Args: $lib (library name), $ver (package version), $major (PG major).
.extensions |= map(
  if .name == "xatautils" then {
    name: $lib,
    version: $ver,
    description: "Security library (local build)",
    docs_url: "",
    preload_required: true,
    test_enabled: true,
    test_commands: [
      "DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_get_loaded_modules() WHERE file_name = '\($lib).so') THEN RAISE EXCEPTION '\($lib) is not loaded'; END IF; END $$;",
      "DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_settings WHERE name LIKE '\($lib).%') THEN RAISE EXCEPTION 'no \($lib) settings'; END IF; END $$;",
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_settings WHERE name ILIKE '%xata%' OR setting ILIKE '%xata%') THEN RAISE EXCEPTION 'legacy name in settings'; END IF; END $$;"
    ],
    file_check: "/usr/lib/postgresql/\($major)/lib/\($lib).so"
  } else . end
)
| if any(.extensions[]; .name == $lib) then . else error("no xatautils entry to replace") end
