#!/usr/bin/env python3
"""Discord Gateway bot: forwards channel messages and slash commands to n8n.

Holds the only outbound connection (Gateway WebSocket); nothing needs to be
reachable from the internet. Discord REST calls and the n8n webhook call both
use stdlib urllib — websockets is the one dependency that's unavoidable for
the Gateway connection itself.
"""

import asyncio
import json
import logging
import os
import random
import sys
import urllib.error
import urllib.request

import websockets

API_BASE = "https://discord.com/api/v10"
GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json"

# Discord's Cloudflare front blocks urllib's default "Python-urllib/3.x"
# User-Agent as a bot signature (seen as a plain-text "error code: 1010"
# response, not Discord's usual JSON error body). Discord's own docs ask for
# this format anyway: https://discord.com/developers/docs/reference#user-agent
USER_AGENT = "DiscordBot (https://github.com/seita, 1.0)"

# GUILDS | GUILD_MESSAGES | MESSAGE_CONTENT
INTENTS = (1 << 0) | (1 << 9) | (1 << 15)

# Slash command definitions, registered (idempotently) on every startup via
# PUT /applications/{id}/commands. Actual command handling lives in n8n
# (branches on `data.name`) — this list only controls what Discord offers
# in its UI.
SLASH_COMMANDS = [
    {
        "name": "ask",
        "description": "Task Secretaryに質問する",
        "options": [
            {
                "name": "message",
                "description": "内容",
                "type": 3,  # STRING
                "required": True,
            }
        ],
    },
]

TOKEN = os.environ["DISCORD_BOT_TOKEN"]
APPLICATION_ID = os.environ["DISCORD_APPLICATION_ID"]
WATCH_CHANNEL_IDS = {
    c.strip() for c in os.environ.get("DISCORD_WATCH_CHANNEL_IDS", "").split(",") if c.strip()
}
N8N_WEBHOOK_URL = os.environ["N8N_WEBHOOK_URL"]

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("discord-bot")


def discord_request(method: str, path: str, body: dict | None = None) -> None:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"{API_BASE}{path}",
        data=data,
        method=method,
        headers={
            "Authorization": f"Bot {TOKEN}",
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
    except urllib.error.HTTPError as e:
        log.error("discord %s %s -> %s: %s", method, path, e.code, e.read())


def register_slash_commands() -> None:
    discord_request("PUT", f"/applications/{APPLICATION_ID}/commands", SLASH_COMMANDS)
    log.info("registered %d slash command(s)", len(SLASH_COMMANDS))


def defer_interaction(interaction_id: str, interaction_token: str) -> None:
    # Discord requires an ack within 3s; deferring here buys n8n unlimited
    # time to actually answer via the followup-message endpoint later.
    req = urllib.request.Request(
        f"{API_BASE}/interactions/{interaction_id}/{interaction_token}/callback",
        data=json.dumps({"type": 5}).encode(),
        method="POST",
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
    except urllib.error.HTTPError as e:
        log.error("defer interaction -> %s: %s", e.code, e.read())


def forward_to_n8n(payload: dict) -> None:
    req = urllib.request.Request(
        N8N_WEBHOOK_URL,
        data=json.dumps(payload).encode(),
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
    except urllib.error.URLError as e:
        log.error("forward to n8n failed: %s", e)


def handle_dispatch(event_type: str, data: dict) -> None:
    # Nested under "event" rather than spread flat: Discord's own payloads
    # already have a `type` field (message type / interaction type as an
    # int), which would silently clobber a flat `type: "message"` marker.
    if event_type == "MESSAGE_CREATE":
        if data.get("author", {}).get("bot"):
            return
        if WATCH_CHANNEL_IDS and data.get("channel_id") not in WATCH_CHANNEL_IDS:
            return
        forward_to_n8n({"kind": "message", "event": data})
    elif event_type == "INTERACTION_CREATE":
        if data.get("type") == 2:  # APPLICATION_COMMAND
            defer_interaction(data["id"], data["token"])
        forward_to_n8n({"kind": "interaction", "event": data})


async def run_gateway() -> None:
    session_id = None
    resume_gateway_url = None
    seq = None

    while True:
        url = resume_gateway_url or GATEWAY_URL
        try:
            async with websockets.connect(url) as ws:
                hello = json.loads(await ws.recv())
                heartbeat_interval = hello["d"]["heartbeat_interval"] / 1000

                async def heartbeat():
                    await asyncio.sleep(heartbeat_interval * random.random())
                    while True:
                        await ws.send(json.dumps({"op": 1, "d": seq}))
                        await asyncio.sleep(heartbeat_interval)

                hb_task = asyncio.create_task(heartbeat())

                if session_id:
                    await ws.send(json.dumps({
                        "op": 6,
                        "d": {"token": TOKEN, "session_id": session_id, "seq": seq},
                    }))
                else:
                    await ws.send(json.dumps({
                        "op": 2,
                        "d": {
                            "token": TOKEN,
                            "intents": INTENTS,
                            "properties": {"os": "linux", "browser": "n8n-discord-bot", "device": "n8n-discord-bot"},
                        },
                    }))

                async for raw in ws:
                    msg = json.loads(raw)
                    op = msg.get("op")
                    if op == 0:  # Dispatch
                        seq = msg["s"]
                        t = msg["t"]
                        if t == "READY":
                            session_id = msg["d"]["session_id"]
                            resume_gateway_url = msg["d"]["resume_gateway_url"] + "/?v=10&encoding=json"
                            log.info("READY as %s", msg["d"]["user"]["username"])
                        elif t == "RESUMED":
                            log.info("RESUMED")
                        else:
                            handle_dispatch(t, msg["d"])
                    elif op == 7:  # Reconnect
                        log.info("gateway requested reconnect")
                        break
                    elif op == 9:  # Invalid Session
                        resumable = msg.get("d")
                        log.warning("invalid session (resumable=%s)", resumable)
                        if not resumable:
                            session_id = None
                            resume_gateway_url = None
                        await asyncio.sleep(1 + random.random() * 4)
                        break

                hb_task.cancel()
        except (websockets.exceptions.ConnectionClosed, OSError) as e:
            log.warning("gateway connection lost: %s", e)

        await asyncio.sleep(5)


def main() -> None:
    register_slash_commands()
    asyncio.run(run_gateway())


if __name__ == "__main__":
    main()
