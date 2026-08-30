# Codex progress checkpoint protocol

boring.notch reads one owner-private file at:

`~/Library/Application Support/BoringNotch/agent-progress.json`

Codex should update it through the installed helper so validation, permissions, and atomic replacement stay consistent:

```sh
printf '%s\n' '{"schemaVersion":1,"taskID":"CS-2144","title":"Finish Codex integration","state":"working","phase":"Verify macOS builds","planRevision":3,"planLocked":true,"milestones":[{"id":"transport","title":"Transport","state":"verified","evidence":"Focused tests passed"},{"id":"ui","title":"Notch UI","state":"working"},{"id":"release","title":"Public PR","state":"pending"}],"agents":[{"id":"root","title":"Primary agent","state":"working","phase":"Verify macOS builds"}],"updatedAt":"2026-08-30T23:55:00Z"}' | ~/.local/bin/boring-notch-hook progress
```

Clear a finished or abandoned checkpoint with:

```sh
~/.local/bin/boring-notch-hook progress-clear
```

## Accuracy contract

- The notch shows one aggregate checkpoint bar, never one percentage bar per agent.
- The bar appears only when `planLocked` is true and the document declares at least two milestones.
- boring.notch computes the fill from milestones whose state is `verified`; writers cannot submit a raw percentage.
- A verified milestone must include a short evidence label. Evidence is descriptive, not secret output.
- If a plan changes, increment `planRevision`, update the full milestone list, and set `planLocked` to false until the new denominator is stable.
- Agent rows carry only state and phase text. They do not carry percentages.
- Active documents older than five minutes are marked stale and lose their numeric bar. Documents expire after 24 hours.

## Privacy and limits

The file is limited to 64 KB, must be a regular owner-only file, and may not contain prompt text, tool input, operations, or percentage fields. Keep titles, phase labels, and evidence short and non-sensitive. The app accepts at most 50 milestones and 20 agents.
