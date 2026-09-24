# Alert rules: always-emitting instant query + threshold expression

- Date: 2026-08-25
- Scope: `mkRule` in `modules/alerting.nix`

## The shape

Every rule in this repo reduces to "run one instant PromQL query, compare the value
to a threshold". A Grafana alert rule's native structure is `data` (an array of query
and expression nodes) + `condition` (the `refId` of the final node) — written out
directly, that's about 40 lines per rule, and threshold values get buried. `mkRule`
folds the common structure so the interesting part of each rule — the query and the
threshold — reads as roughly one line.

## Query style: always emit a value

Rules are written so the PromQL expression always returns a series, and the
threshold comparison is left to Grafana's evaluator — not written so that a series
only appears when something is wrong (e.g. `metric > 5`). When a query's series
disappears, Grafana treats that as NoData rather than "resolved", which silently
changes what the threshold means. `noData` is set per rule: default `"OK"` (the
metric doesn't exist yet, which is not itself abnormal), or `"Alerting"` for rules
where the series disappearing *is* the failure mode (e.g. a metrics-collection timer
dying).

## Fields worth knowing

- `uid` must always be explicit. Omitting it makes Grafana treat the rule as new on
  every restart, losing any silences attached to the old one.
- `datasourceUid` is fixed to `victoriametrics` — see
  `docs/services/alerting.md` for why.
