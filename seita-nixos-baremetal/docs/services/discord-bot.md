# Discord Gateway bot → n8n webhook forwarder

Implementation: [`modules/discord-bot.nix`](../../modules/discord-bot.nix), [`modules/discord-bot/bot.py`](../../modules/discord-bot/bot.py)

## What it is

A small Python script (stdlib + `websockets`) that holds a Discord Gateway
WebSocket connection, and forwards channel messages / slash-command
interactions to an n8n webhook (same loopback pattern as the Grafana alert
webhook: `http://127.0.0.1:5678/...`). All conversation logic and replies are
handled by the existing "Task Secretary Chat" n8n workflow — this bot is
purely a transport.

## Why Gateway, not the Interactions endpoint

Discord offers two ways to receive events:

- **Interactions endpoint**: Discord makes an inbound HTTP call to a URL you
  host — requires opening a port to the internet.
- **Gateway**: the bot makes an *outbound* WebSocket connection to Discord.

This bot uses Gateway, so nothing on this host needs to be reachable from the
internet (the Developer Portal's Interactions Endpoint URL is left blank).

## Secrets

`DISCORD_BOT_TOKEN`, `DISCORD_APPLICATION_ID`, `DISCORD_WATCH_CHANNEL_IDS`,
`N8N_WEBHOOK_URL` come from `secrets/discord-bot-env.age` (agenix), decrypted
with a host key at `/etc/age/host.key`. See
[`docs/decisions/2026-08-05-agenix-ssh-to-age-host-key.md`](../decisions/2026-08-05-agenix-ssh-to-age-host-key.md)
for why that key is `ssh-to-age`-converted rather than the raw SSH host key,
and how to recreate it. General agenix layout: [`docs/secrets.md`](../secrets.md).

## Runtime notes

- Runs as a dedicated unprivileged user (`discord-bot`), not `seita`.
- `Restart = "on-failure"`, 10s backoff.
- Slash commands (`/ask`) are (re-)registered idempotently on every startup
  via `PUT /applications/{id}/commands` — Discord only uses this list to
  populate its UI; actual command handling is in n8n, branching on
  `data.name`.
- The Discord User-Agent must match Discord's documented format
  (`DiscordBot (<url>, <version>)`); their Cloudflare front silently blocks
  urllib's default UA with a plain-text `error code: 1010`, not Discord's
  usual JSON error body.
