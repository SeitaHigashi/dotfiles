# Grafana Alerting

Implementation: [`modules/alerting.nix`](../../modules/alerting.nix)

## What this is

Threshold-based alerts (Grafana Unified Alerting, provisioned) on top of the metrics
collected by [monitoring.md](monitoring.md). Dashboards make silent degradation
(ZFS pool degrading, a disk wearing out, replication stalling) visible only if
someone looks; these rules let the threshold judgment happen automatically. Why this
lives in its own module rather than in `monitoring.nix`, and why notifications go
through n8n instead of SMTP, is in
[the alerting-split decision record](../decisions/2026-08-25-alerting-split-from-monitoring.md).

**git is the single source of truth** — same as dashboards
(`allowUiUpdates = false` in `modules/monitoring.nix`): rules provisioned this way
cannot be edited from the UI. To change a threshold, edit `modules/alerting.nix` and
rebuild.

Rule groups: `infra`, `services`, `backup` — see the file for the full rule list;
this doc covers the conventions that apply across all of them.

## Rule conventions (the `mkRule` helper)

Every rule reduces to "run one instant PromQL query, compare it to a threshold".
Written out with Grafana's native `data`/`condition` structure that's ~40 lines per
rule; `mkRule` in `modules/alerting.nix` folds the boilerplate so each rule reads as
roughly one call. Full rationale, including the "always emit a value" query style
and the `noData` field, is in
[the mkRule decision record](../decisions/2026-08-25-mkrule-instant-query-shape.md).
Key points to know before adding or editing a rule:

- **`uid` must always be set explicitly.** Without it, a restart makes Grafana treat
  the rule as brand new, and any existing silence is lost.
- **`datasourceUid` is pinned to `"victoriametrics"`** — same reason as dashboards
  (see [services/monitoring.md](monitoring.md#data-sources)); changing it turns
  every rule into a "datasource not found" error.
- Write the PromQL expression so it always returns a series (an instant query with a
  threshold comparison), not so a series only appears when something is wrong
  (`metric > 5`-style). If the series disappears, Grafana reports NoData rather than
  "resolved", silently changing what the rule means.

### MetricsQL: the `\.` pitfall

MetricsQL — VictoriaMetrics' PromQL dialect — cannot parse a literal `\.` inside a
double-quoted label matcher: the backslash gets consumed as a *string* escape before
regex parsing even sees it, producing a syntax error (confirmed on hardware). Write
`[.]` instead. Example, from the `syncoid-failed` rule:
```
name=~"syncoid-.*[.]service"
```

### `zfs_pool_health`

node_exporter's `zfs` collector does not expose pool health. It's supplied instead
by `modules/zfs-snapshot-metrics.nix`'s textfile collector (metric name
`zfs_pool_health`).

## Deleting a rule

Removing a rule's entry from `rules.settings.groups` is **not enough** — provisioning
no longer mentioning a rule does not delete it from Grafana's own database, so it
keeps evaluating (and can keep alerting) forever. See
[runbooks/alerting.md](../runbooks/alerting.md) for the `deleteRules` procedure.

## RESOLVED notifications do not fire on rule deletion

Deleting a rule entirely does **not** send a resolved/RESOLVED notification — the
evaluated target simply disappears, so the Alerting → Normal transition that
triggers a resolved notice never happens (confirmed on hardware). To test the
resolved-notification path, change only the *threshold* on an existing rule so it
returns to Normal; don't delete the rule to "clear" it.

## Notification: n8n webhook

The only contact point is a single n8n webhook:
`http://127.0.0.1:5678/webhook/grafana-alert-40b2fc68`. The trailing random suffix
comes from n8n itself and can't be shortened without editing the workflow (a
different path returns 404). The workflow is
"Notify Grafana Alert to Discord" (`fD6js4TzcXdUF4Wx`); both firing and resolved
directions were confirmed working on hardware on 2026-08-04.
`disableResolveMessage = false`, so resolved notifications are sent too — without
them there's no way to tell whether an alert is still firing.

Notification policy re-notifies every 12h (`repeat_interval`) — deliberately
infrequent for a home server, to avoid repeat paging for the same issue.
Severity-based routing (which channel, quiet hours, etc.) is done in the n8n
workflow, not here, so it can be tuned without touching Nix.

If the n8n workflow is missing or disabled, rule evaluation and the Grafana
Alerting UI are unaffected — only delivery fails.

## Verifying the alert path

```sh
systemctl status grafana        # a provisioning syntax error shows up here
                                 # (Grafana fails to start on a bad config)
ls /etc/grafana/provisioning/alerting/
```

Web UI: `https://<host>/grafana/alerting/list` — everything should read Normal;
Error or NoData means a PromQL mistake.

To manually exercise the notification path, add a temporary rule with
`expr = "vector(1)"` and `for = "0s"`, confirm delivery, then remove it (see
[runbooks/alerting.md](../runbooks/alerting.md)).
