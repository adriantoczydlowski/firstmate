# Azure DevOps merge-watch: live verification (2026-09-18)

Driven against the real forge (org `https://dev.azure.com/mubadalacapital`, project/repo `FnO`)
using `bin/fm-pr-check.sh` to arm and the published `state/<id>.check.sh` sidecar to poll,
in a throwaway `FM_HOME`/state directory (`/tmp/fm-ado-live-test.*`, removed after the run).
All reads were `az repos pr show` (read-only); nothing was created, edited, completed,
abandoned, voted on, or commented.

## Scenario A — merged pull request bound to the right repository

| task | PR | az status/repo/mergeCommit | check.sh output |
|---|---|---|---|
| task-a | 2585 | completed / FnO / 540c794... (40 hex) | `merged` |
| task-b | 2530 | completed / FnO / fd1b09c... (40 hex) | `merged` |

## Scenario B — non-landed / misidentified pull requests stay silent, poll stays armed

| task | PR / URL | az status/repo/mergeCommit | check.sh output | poll artifacts after |
|---|---|---|---|---|
| task-c | 2584 (abandoned) | abandoned / FnO / None | *(empty)*, exit 0 | `.pr-poll` + `.check.sh` intact |
| task-d | 2298 (active) | active / FnO / e04da84... (non-null!) | *(empty)*, exit 0 | `.pr-poll` + `.check.sh` intact |
| task-e | `.../FnO/_git/CarryIntel/pullrequest/2585` (id collision) | completed / **FnO** (not CarryIntel) / 540c794... | *(empty)*, exit 0 | `.pr-poll` + `.check.sh` intact |

task-d proves the silence comes from the `status=completed` gate, not from an absent merge
commit: PR 2298 is `active` yet already carries a non-null `lastMergeCommit` (a merge-preview
commit), and the watch still stayed silent.

task-e proves the id-collision guard: Azure DevOps pull-request ids are organisation-wide, so
`az repos pr show --id 2585` resolves to repository `FnO` regardless of the `CarryIntel` segment
in the armed URL. The watch compares the forge's returned `repository.name` against the URL's
own repo segment and refuses the match.

## Scenario C — refuse to arm without the `azure-devops` extension

Not re-driven live: doing so would require removing the `azure-devops` extension from the
installed, shared `az` CLI, disturbing other live users of this environment. This path is
exercised by the `FM_TEST_AZ_NO_EXT=1` case in
`tests/fm-pr-check-security.test.sh::test_azure_devops_merge_watch` against a test double, which
was accepted as sufficient evidence for this path in the prior review round.
