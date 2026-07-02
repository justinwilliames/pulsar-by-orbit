# Release Checklist

## Before Release

- Pull latest `main` and confirm no unexpected local changes
- Run smoke checks:
  - `bash -n scripts/say.sh scripts/warm-cache.sh`
  - Build the app cleanly: `scripts/build-pulsar-app.sh`
- Verify path traversal protection for portraits still holds
- Confirm no secrets are committed:
  - `.env` is ignored
  - No API keys in tracked files
- Ensure generated artifacts are excluded:
  - `cache/` contains only `.gitkeep`
- Review docs for accuracy:
  - `README.md`
  - `CLAUDE.md`
  - `SKILL.md`
  - `SECURITY.md`
  - `docs/SETUP_MAC.md`
- Confirm executable bits on scripts:
  - `scripts/say.sh`

## Release

- Create a version tag: `git tag vX.Y.Z`
- Push code and tags: `git push origin main --tags`
- Create GitHub release notes from tag

## After Release

- Sanity test install from a fresh clone
- Validate daemon start and one end-to-end speak call
