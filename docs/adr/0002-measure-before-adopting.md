<!-- docs/adr/0002-measure-before-adopting.md -->
# ADR-0002: Measure before adopting, and say how far the evidence reaches

Status: Proposed
Date: 2026-10-12

<!-- Adapted (not copied) from gsamuele78/AI-Platform-Infrastructure ADR-013 and
     gsamuele78/AiAgentInfrastructure ADR-0021. -->

## Context

This repository runs on live BIOME-CALC hosts. Changes arrive with claimed benefits
("safer", "faster", "fixes X") from humans, AI agents and other repositories'
practices. Two facts from the history show why a claim is not enough:

- CI was "green" for months while it tested a layout that no longer existed and
  masked every step with `|| true` (header of `.github/workflows/ci.yml`).
- The `setwd` fix was written in June and never reached the hosts; the defect stayed
  live for four months (`docs/planning/ROADMAP_EXECUTION_PLAN.md`, D-R03, PR #26).

The first is a measurement that did not measure; the second is a fix that was never
verified where it matters. Both are cheaper to prevent than to discover.

## Decision

Every change that claims an improvement **pre-registers its measurement in the PR,
before the result is known**, and states **how far the evidence reaches**.

1. **Pre-registration.** The PR states the metric, the baseline (measured on `main`,
   with the command used), the target, and a guard metric that must not get worse.
   A threshold changed after seeing the numbers needs a new PR that says why.
2. **Evidence level.** Each result is labelled with the highest level it reached:
   `L0 static` (lint, structure) → `L1 CI` (tests on the runner) → `L2 VM`
   (disposable Ubuntu 24.04 VM) → `L3 canary` (one production host) → `L4 fleet`
   (every host, confirmed). A production behaviour change is not "done" below L3, and
   a fix is not "deployed" below L4 (D-R03).
3. **Repetition only where results vary.** Counts on a fixed corpus or file set are
   deterministic: one run is enough. Durations: ≥ 5 runs, median and IQR. Pass rates
   of non-deterministic things: ≥ 20 attempts with a Wilson interval.
4. **Prove the test can fail.** A new gate ships with a mutation: break the rule it
   guards and show the gate goes red (examples: the agent-guard mutation test in
   PR #28, the ShellCheck ratchet in PR #29, the CHANGELOG gate in PR #30).
5. **Missed target → revert or supersede.** A change that does not reach its target
   is reverted or replaced by a new ADR; it is not kept "because it is there".

## Consequences

- Positive: claims become checkable; false-green gates are caught by their mutation;
  "merged" and "deployed" stop being confused.
- Negative: every PR carries a measurement table, which costs time. For pure docs or
  typo PRs the table is "n/a".
- Some metrics need the hosts (L3/L4). Until there is a way to read what a host runs
  (ADR-0003, `release.json`), L4 is confirmed by hand.

## Alternatives considered

- **Full AI-Platform protocol (ABBA runs, fixed metric families).** Rejected here: it
  is designed for inference performance; most changes in this repo are deterministic.
- **No protocol, trust review.** Rejected: both incidents above passed review.

## Rollback

Delete this ADR's status line requirement from the PR checklist. Nothing in the
runtime depends on it.
