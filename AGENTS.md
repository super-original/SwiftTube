# Agent Instructions

- Create a git commit after every change set that materially updates code or configuration.
- Keep commits small and focused; avoid bundling unrelated changes.
- Use clear, present-tense commit messages (e.g., "Add backend bootstrap", "Fix navigation routing").
- Before committing, check `git status` and include only intended files.
- Do not commit secrets or large binary artifacts.
- When making material app changes, also update the user-visible app version shown in `SwiftTube > About`. Keep that version in sync with the build metadata used for the packaged app.
