# Splitting Grafana alerting into its own module

- Date: 2026-08-25
- Scope: `modules/alerting.nix` vs `modules/monitoring.nix`

## Why alerting is a separate file

`modules/monitoring.nix` had already grown past 400 lines. Collection (exporters,
scraping) and judgment (alert rules) change for different reasons, so they were split.
`services.grafana` attributes merge across modules fine — there is no "single
location only" constraint here, unlike `nixpkgs.config.allowUnfreePredicate`.

## git is the single source of truth

Alert rules are provisioned the same way as dashboards
(`allowUiUpdates = false` in `modules/monitoring.nix`): editing them in the Grafana
UI is not possible. To change a threshold, edit `modules/alerting.nix` and rebuild.

## Notification path

Everything goes to a single n8n webhook. SMTP was rejected because there is nowhere
to store a password yet (no sops-nix or agenix in this repo at the time). n8n runs on
the same host (`127.0.0.1`), so no new secret is introduced. Routing decisions
(Discord vs. email, quiet hours, etc.) live in the n8n workflow, not in Nix.

If the webhook's n8n workflow is missing entirely, alert state still shows up in
Grafana's Alerting UI — only delivery fails, rule evaluation is unaffected.
