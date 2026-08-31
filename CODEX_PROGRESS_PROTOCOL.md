# Codex progress checkpoint protocol

boring.notch reads one owner-private file at:

`~/Library/Application Support/BoringNotch/agent-progress.json`

Codex should update it through the installed helper so validation, permissions, and atomic replacement stay consistent:

```sh
printf '%s\n' '{"schemaVersion":2,"taskID":"CS-2144","title":"Finish Codex integration","state":"working","phase":"Verify macOS builds","planRevision":3,"planLocked":true,"milestones":[{"id":"transport","title":"Transport","state":"verified","evidence":"Focused tests passed","evidenceAt":"2026-08-30T23:53:00Z"},{"id":"ui","title":"Notch UI","state":"working"},{"id":"release","title":"Public PR","state":"pending"}],"agents":[{"id":"root","title":"Primary agent","state":"working","phase":"Verify macOS builds","updatedAt":"2026-08-30T23:55:00Z"}],"updatedAt":"2026-08-30T23:55:00Z"}' | ~/.local/bin/boring-notch-hook progress
```

Clear a finished or abandoned checkpoint with:

```sh
~/.local/bin/boring-notch-hook progress-clear
```

## Accuracy contract

- The notch shows one aggregate checkpoint bar, never one percentage bar per agent.
- The bar appears only when `planLocked` is true, the document is current, at least two milestones exist, and work remains. Completed, failed, stale, and all-verified-but-still-working tasks use a state label instead of a permanent 100% bar.
- boring.notch computes the fill from milestones whose state is `verified`; writers cannot submit a raw percentage.
- A verified milestone must include a short evidence label and `evidenceAt` timestamp. The app retains both so the UI can show what was actually checked and when. Evidence is descriptive, not secret output.
- Evidence is agent-reported. boring.notch validates its shape, timestamp, revision history, freshness, and terminal agreement, then exposes the label for review; it does not rerun an arbitrary build, test, or external check.
- If a plan changes, a verified checkpoint reopens, or a terminal task reopens, increment `planRevision`, publish the changed plan with `planLocked: false`, then lock that same revision after its denominator is stable. The helper rejects skipped revisions, revision rollback, timestamp rollback, and a newly changed plan that arrives already locked.
- Agent rows carry only state, phase text, and `updatedAt`. They do not carry percentages.
- Active root or agent updates older than five minutes mark the whole checkpoint stale and remove its numeric bar. Documents expire after 24 hours.
- `state: completed` is accepted only for a non-empty locked plan whose milestones are all verified and whose declared agents are all completed.

## Privacy and limits

The file is limited to 64 KB and must be a regular owner-only file. Schema v2 is allowlisted at every level: unknown root, milestone, or agent fields are rejected before bytes are persisted, so prompt text, tool input, operations, raw percentages, and misspelled variants cannot hide in the document. Keep titles, phase labels, and evidence short and non-sensitive. The app accepts at most 50 milestones and 20 agents.
