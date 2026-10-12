# Triage: how the inventory scores a flow, and how to recalibrate

The estimate for this programme priced OSB flows in three tiers with fixed unit efforts (simple, medium, complex;
the figures are internal and are not repeated here or on any customer artefact). The inventory script assigns a tier
so that the estimate can be reconciled against evidence instead of a top-down split, and so that batch migration can
start with the flows that teach the most for the least risk.

## The score (`scripts/osb_inventory.py::triage`)

| Signal | Points | Why it costs effort |
|---|---|---|
| Each pipeline action | +1 | Each is a card row, a code step and usually a test row |
| Each downstream service (route, callout, publish target) | +3 | A backend means a stub set, a configuration block, a timeout/retry decision |
| Each hard action present (`javaCallout`, `mflTransform`, `nXSDTransform`, `dynamicRoute`, `dynamicPublish`, `forEach`) | +8 | No mechanical mapping; design per occurrence |
| Java callouts | +10 | The jar must be found, read, ported or stubbed |
| XQuery/XSLT lines | +1 per 20 lines | Golden fixtures and review grow with the transform |
| Each distinct `fn-bea:` function | +4 | Shim entry or rewrite, plus the proof |
| Each transport outside `http`, `ws`, `sb`, `local`, `jms` | +6 | File/FTP/email/JCA/MQ need infrastructure decisions |
| WS-Security policies attached | +6 | Blocked on the security owner |
| Throttling configured | +3 | A decision: route-level or gateway |
| Result caching | +4 | A decision: cache component or drop |
| Each branch node beyond the first | +2 | More paths, more tests |
| Unknown actions | +5 | Something the mapping table has not met |

Thresholds: `simple` < 12, `medium` < 28, `complex` ≥ 28.

## Signals that force `complex` regardless of score

Treat the flow as complex, and design it on its own card, when any of these is true: a split-join (`.flow`) is involved;
a Java callout has no source; `mflTransform`/`nXSDTransform` is used; `fn-bea:execute-sql`, `lookupBasicCredentials`,
`isUserInGroup/Role` appear; a JCA adapter is the inbound or outbound transport; the proxy is a transactional JMS
consumer that publishes in the same transaction; WS-Security policies are attached; the pipeline reads `$header`
(SOAP headers) or `$attachments`. The script does not enforce this list yet; the card does. Add the rule to the script
once the first slice shows which ones occur.

## Recalibration after the first slice

The thresholds above are a guess shaped like the estimate. They become a measurement like this:

1. Migrate the first slice (the programme's own proposal was about twenty flows across the three tiers) with the skill,
   recording actual effort per flow in the migration record (design, code, tests, review, separately).
2. Plot score against actual effort. Set the two thresholds so that the tier bands match the estimate's unit-effort
   bands; if the relationship is not monotonic, find the signal that explains the outliers and change its weight.
3. Re-run the inventory over the whole export with the new weights; the tier counts are what the estimate
   reconciliation uses. Keep the old `INVENTORY.md` next to the new one; the delta is the evidence.
4. Repeat after each wave. The script's docstring says the thresholds are uncalibrated; remove that sentence only when
   they are.

## How the tiers drive batch order

- `simple` first, grouped by shared business services: the stubs and configuration blocks are built once and the team
  learns the mapping tables on low-risk flows.
- `medium` next, by project folder, because folders tend to share transforms and namespaces.
- `complex` one card at a time, each approved individually; schedule the Java-callout and JCA flows last, after their
  owners have answered the open items.

## Never

Never quote the tier counts as an effort figure outside the estimate workbook, and never let the script's tier override
a reviewer's judgement on the card without a written reason; the score is an input, the card is the decision.
