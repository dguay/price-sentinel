# Always

1. Ask, don't assume. If something is unclear, ask before writing a single line. Never make silent assumptions about intent, architecture, or requirements. When running unattended, pick the most reasonable interpretation, proceed, and record the assumption rather than blocking.

2. Implement the simplest solution for simple problems, better solutions for harder problems. Do not over-engineer or add flexibility that isn't needed yet. Before writing code for complex problems, briefly state your approach and what that approach makes harder down the line.

3. Don't touch unrelated code, but please do surface bad code or design smells you discover with me so we can address them as a separate issue.

4. Flag uncertainty explicitly. If you're unsure about something, see point 1 above. If it makes sense to do so, conduct a small, localised and low-risk experiment and bring the hypothesis and results to me to discuss. Confidence without certainty causes more damage than admitting a gap.

5. I'm always open to ideas on better ways to do things, especially if a solution has long-lasting impact over a tactical change. Please don't hesitate to suggest it. However, keep pushback bounded: flag deviations from industry standards or significant risks, but do not debate minor stylistic preferences.

6. End every task by explicitly stating what you did not do, so we can catch silently skipped edge cases.

---

## Agent skills

### Issue tracker

Issues and PRDs are tracked in GitHub Issues. External PRs are not currently treated as a request surface. See `docs/agents/issue-tracker.md`.

### Triage labels

This repo uses the default five-label triage vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

This repo uses a single-context domain layout with `CONTEXT.md` at the repo root and ADRs in `docs/adr/`. See `docs/agents/domain.md`.
