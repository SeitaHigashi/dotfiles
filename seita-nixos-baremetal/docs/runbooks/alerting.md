# Alerting runbook

Service overview: [services/alerting.md](../services/alerting.md).

## Add a rule

1. Add a `mkRule { ... }` call to the relevant group's `rules` list in
   `modules/alerting.nix`. Give it a unique, permanent `uid`.
2. Write the PromQL expression so it always returns a value (see
   [the mkRule conventions](../services/alerting.md#rule-conventions-the-mkrule-helper)).
3. Pick `noData`: `"OK"` (default) unless the series disappearing is itself the
   failure mode, in which case `"Alerting"`.
4. `nixos-rebuild switch`, then check `https://<host>/grafana/alerting/list` — the
   new rule should read Normal (or Pending, if `for` hasn't elapsed), not Error.

## Change a threshold

Edit the `limit` (and/or `op`/`pending`) argument on the existing `mkRule` call and
rebuild. No need to touch `uid`.

## Delete a rule

Removing the `mkRule` entry from `groups` alone is not enough — Grafana's alerting
database keeps the rule even after it disappears from provisioning, so it silently
keeps evaluating.

1. Remove the rule from its group's `rules` list.
2. Add a `deleteRules` entry to `rules.settings` in `modules/alerting.nix`:
   ```nix
   rules.settings = {
     apiVersion = 1;
     deleteRules = [ { orgId = 1; uid = "<uid being removed>"; } ];
     groups = [ ... ];
   };
   ```
3. `nixos-rebuild switch` once, confirm the rule is gone from the Alerting UI.
4. Remove the `deleteRules` entry (leaving it in place has no further effect but
   there's no reason to keep it).

## Test the notification path (fire + resolve)

1. Add a temporary rule with `expr = "vector(1)"` and `for = "0s"` so it fires
   immediately.
2. Confirm the n8n webhook delivers (check the Discord channel / n8n execution log).
3. **Do not delete the rule to test the resolved notification** — deleting a rule
   does not send RESOLVED (the evaluated series just disappears; there is no
   Alerting → Normal transition to trigger it). Instead, change the rule's
   threshold so its condition evaluates to Normal, confirm the resolved
   notification arrives, then remove the temporary rule as in "Delete a rule" above.
