---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A `forge=external` task reports `done [at=<epoch>]: review <url> uploaded for review` instead: run `bin/fm-review-check.sh <id> <review url>` rather than `bin/fm-pr-check.sh`, which arms no merge watch, then always escalate the review URL to the captain whatever the yolo setting, because firstmate can neither observe nor perform its approval or merge.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
In no-mistakes mode the earlier `done [at=<epoch>]: {summary}` is the pipeline handoff and is not gated.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

When the captain's standing instruction calls for an independent review of finished work, take the review tier from `bin/fm-review-tier.sh <worktree> <base> <candidate>` on the frozen candidate, never from memory of the task's size or subject.
`cross-family` means a reviewer from the other model family than the builder reads the candidate, and it does not land, deploy, or go live before that review reports.
`standard` means one same-family reviewer reads it against the severity rubric, and `none` means no independent review.
When no reviewer of the other family can launch, because a captain override or a launcher refusal is in force, do not hold the landing for a `cross-family` verdict: use a same-family reviewer with the rubric, keep `tier=cross-family` in the record, and tell the captain which candidates landed without their other-family review.
The captain's own standing instruction still wins where it asks for more than the tier does, such as one review for every candidate of a named project.
Build each review brief from the home's `data/review-brief-template.md` when it has one, and run the script again when the candidate changes, because a new commit can change the tier.
The script's header owns the rules file and the output.

A `local-only` landing goes through `bin/fm-merge-local.sh`, which consults `bin/fm-landing-proof.sh` when the home's `config/landing-proof` names the project: every validation that file lists must have passed on the exact commit being landed.
A refusal there means the proof belongs to another commit or was never produced, so run the missing validation on that commit; record `bin/fm-landing-proof.sh waive <id> --reason <text>` only when the requirement does not apply to this change, and say why.

When a project's final validation takes about as long as its default branch takes to move, land reviewed candidates in batches instead of one at a time, because a validation that is not first in line is stale when it finishes.
A unit then stops at a reviewed candidate: rebased on the default branch, its targeted checks passing, the commit and the targeted command recorded in its report, and no final full validation of its own.
Dispatch one landing-train ship per batch of up to about six such candidates, with a brief that lists each member branch and its exact head in merge order.
The train merges each member with `git merge --no-ff` at exactly that head, never a rebase, squash or cherry-pick, so member tips stay ancestors of the default branch.
It resolves only mechanical conflicts, runs the project's format, lint and that member's targeted command after each merge, and drops a member (reset to before its merge, reason recorded) on a semantic conflict or a failing check.
On the exact final train commit it runs the project's full validations once and reports that commit with its proof paths.
Land the train with `bin/fm-merge-local.sh <train-id>`; each member branch is then an ancestor of the default branch and is torn down as landed, and each dropped member is told why and what its new base is.
Hold other landings on that project while a train validates, and after a failure rerun only what failed: once for an infrastructure failure, otherwise drop the suspect member and validate the new final commit.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
