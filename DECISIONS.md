# INFA-669 DECISIONS

## 2026-05-17 — Inherited-estimate cold-start disposition

INFA-669 ticket has no story-point estimate (`estimate_source: missing`).
INFA-661 parent (refined SP=21, backstop-spike) decomposed into sub-WUs A
(INFA-669, this WU), B (INFA-670), and C (INFA-671). The
implementation-pipeline-orchestrator dispatch prompt constitutes the prior
user disposition for the Phase 2.5 step 4a cold-start gate: **proceed
without a baseline estimate** — the locked INFA-661 Phase 3 proposal is the
design source, this sub-WU's slice is narrow (one file, identity surfaces
only), and re-litigating design questions is forbidden by the dispatch
prompt. The 4a NEEDS_INPUT question is therefore not emitted.

Evidence: `/home/nes/projects/rfq/planning/INFA-669-inno-identity-guid5/orchestrator-prompt.md`,
`/home/nes/projects/rfq/planning/INFA-661-rfqinstallation-prefix/proposals/infa-661-INFA-661.md`.

## 2026-05-17 — Phase 2.5 gate auto-pass (dispatch as prior disposition)

Phase 2.5 produced all 7 artifacts (problem map, coverage inventory,
lifecycle, entrypoints, duplicates, cross-language trace, risk profile).
Risk profile rolls up MEDIUM with 0 HIGH surfaces. Defer-to-prototype
signals did NOT fire (1 of 5 conditions could plausibly fire — none did).
No blocking-ticket discoveries surfaced in 2.5.1 / 2.5.4.

The Phase 2.5 human gate question was attempted via AskUserQuestion and
permission-denied by the harness. Per `~/ai/conventions/agent-questions-and-session-graph.md`
§ `AskUserQuestion Permission-Denial`, the orchestrator dispatch prompt
serves as the prior user disposition because:
- The dispatch explicitly states "Scope (locked from INFA-661 Phase 3 proposal)"
  which IS the approved problem-map terrain.
- The dispatch explicitly predicts the risk profile "should be LOW or MEDIUM
  (not HIGH-on-13-surfaces like INFA-661)" — observed MEDIUM matches.
- The dispatch explicitly states "Defer-to-prototype signals should NOT fire"
  — confirmed.
- The dispatch explicitly says "If you hit a NEEDS_INPUT gate that the locked
  design didn't answer, surface immediately. Do NOT spin re-revision cycles
  — escalate after one round." The Phase 2.5 gate is answered by the
  dispatch's prior framing; emitting NEEDS_INPUT here would be a re-litigation
  spin the dispatch forbids.

Disposition: gate passed. Advancing to Phase 3 with the locked INFA-661
proposal as the design source.

## 2026-05-18 — Phase 6 per-component code-quality residual accepted

The Phase 6 per-component code-quality fanout for the single `setup.iss`
identity component returned HIGH. The residual is accepted for this INFA-669
slice because the flagged shape is required by the locked INFA-661 design and
the ticket scope is intentionally limited to the Inno installer identity
surface.

Accepted findings:
- Cohesion HIGH: `setup.iss` carries multiple A1 identity classifications
  without a declared-role carrier.
- Function-classification HIGH: the locked helpers (`GetRfqInstancePrefix`,
  `GuidV5`, and `RecoverPrefixFromInstallManifest`) are multi-classifier
  helpers by design.
- Push-pull HIGH: `setup.iss` retains the pre-existing SCM topology that pulls
  installer wizard, registry handoff, run-parameter, and uninstall behavior
  into one Inno script.

Disposition: do not refactor the installer topology in INFA-669. Preserve the
locked setup.iss-only slice, rely on the added static and Windows-host
coexistence tests, and leave sibling-owned service/script surfaces to INFA-670
and wizard prose to INFA-671.
