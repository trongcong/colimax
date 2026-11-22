## Summary

<!-- What does this change and why? Link the related issue if there is one. -->

## Related feature (docs/FEATURES.md)

<!-- Feature ID, e.g. G15. Has its status been updated in docs/FEATURES.md? -->

## Checklist

- [ ] `WARNINGS_AS_ERRORS=1 scripts/dev-build.sh` — 0 warnings
- [ ] `scripts/run-tests.sh` — passes
- [ ] `scripts/run-tests.sh --integration` (if Docker/Colima code changed) — passes
- [ ] `scripts/check-strings.sh` (if UI strings changed) — passes
- [ ] Tested in the UI (if the UI changed) — screens tested:
- [ ] New destructive actions ask for confirmation
- [ ] No shell commands built by concatenating user input
- [ ] Updated docs/FEATURES.md / CHANGELOG.md (`[Unreleased]` section) / related docs
