#!/usr/bin/env python3
"""Harder tool-calling probes for Bonsai: nested schemas, distractors, Japanese,
forced tool_choice, sequential chains, and traps that should NOT produce a call.

Usage: python3 scripts/test-tools-hard.py [--url ...] [--runs 3]
"""
import argparse
import json
import sys
import time
import urllib.request


def fn(name, desc, props, required):
    return {"type": "function", "function": {
        "name": name, "description": desc,
        "parameters": {"type": "object", "properties": props, "required": required}}}


CREATE_EVENT = fn(
    "create_calendar_event",
    "Create a calendar event.",
    {
        "title": {"type": "string"},
        "start": {"type": "string", "description": "ISO 8601 datetime"},
        "duration_minutes": {"type": "integer"},
        "attendees": {"type": "array", "items": {"type": "string", "description": "email"}},
        "location": {
            "type": "object",
            "properties": {"room": {"type": "string"}, "building": {"type": "string"}},
            "required": ["room", "building"],
        },
        "reminders": {
            "type": "array",
            "items": {"type": "object", "properties": {
                "minutes_before": {"type": "integer"},
                "method": {"type": "string", "enum": ["email", "popup"]}}},
        },
    },
    # room/building are required on purpose. An earlier revision left location
    # and its fields optional while the check still asserted room == 301 — the
    # check was stricter than the contract handed to the model, and the 2 of 3
    # "failures" it produced were schema-valid. Measured after the fix, 8 runs
    # each: room filled 1/8 when optional, 8/8 when required. Bonsai honours
    # required exactly and treats optional as genuinely optional.
    ["title", "start", "duration_minutes", "location"],
)

SQL = fn("run_sql", "Run a read-only SQL query against the analytics warehouse.",
         {"query": {"type": "string"}, "limit": {"type": "integer"}}, ["query"])
SEND_MAIL = fn("send_email", "Send an email.",
               {"to": {"type": "string"}, "subject": {"type": "string"},
                "body": {"type": "string"}}, ["to", "subject", "body"])
DELETE_FILE = fn("delete_file", "Permanently delete a file.",
                 {"path": {"type": "string"}}, ["path"])
CONVERT = fn("convert_currency", "Convert an amount between currencies.",
             {"amount": {"type": "number"}, "from": {"type": "string"},
              "to": {"type": "string"}}, ["amount", "from", "to"])
TRANSLATE = fn("translate", "Translate text.",
               {"text": {"type": "string"}, "target_lang": {"type": "string"}},
               ["text", "target_lang"])
STOCK = fn("get_stock_price", "Get the latest price for a ticker.",
           {"ticker": {"type": "string"}}, ["ticker"])
TIMER = fn("set_timer", "Set a countdown timer.",
           {"seconds": {"type": "integer"}, "label": {"type": "string"}}, ["seconds"])

DISTRACTORS = [SQL, SEND_MAIL, DELETE_FILE, CONVERT, TRANSLATE, STOCK, TIMER]
ALL8 = [CREATE_EVENT] + DISTRACTORS


def post(url, payload, timeout=900):
    req = urllib.request.Request(url + "/v1/chat/completions",
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r), time.time() - t0


def calls_of(msg):
    out = []
    for c in msg.get("tool_calls") or []:
        f = c.get("function", {})
        a = f.get("arguments")
        if isinstance(a, str):
            try:
                a = json.loads(a)
            except json.JSONDecodeError:
                a = {"__unparsable__": a}
        out.append((f.get("name"), a))
    return out


def check_nested(msg):
    cs = calls_of(msg)
    if len(cs) != 1 or cs[0][0] != "create_calendar_event":
        return False, f"got {cs}"
    a = cs[0][1]
    problems = []
    if not isinstance(a.get("attendees"), list) or len(a["attendees"]) != 2:
        problems.append(f"attendees={a.get('attendees')!r}")
    if not isinstance(a.get("duration_minutes"), int) or a["duration_minutes"] != 45:
        problems.append(f"duration={a.get('duration_minutes')!r}")
    loc = a.get("location")
    if not isinstance(loc, dict) or "301" not in str(loc.get("room", "")):
        problems.append(f"location={loc!r}")
    if "2026" not in str(a.get("start", "")):
        problems.append(f"start={a.get('start')!r}")
    return (not problems), ("; ".join(problems) or json.dumps(a, ensure_ascii=False)[:70])


def expect(name, **kw):
    def check(msg):
        cs = calls_of(msg)
        if len(cs) != 1:
            return False, f"expected 1 call, got {len(cs)}: {cs}"
        n, a = cs[0]
        if n != name:
            return False, f"expected {name}, got {n}"
        for k, want in kw.items():
            if str(want).lower() not in str(a.get(k)).lower():
                return False, f"{k}={a.get(k)!r} != {want!r}"
        return True, f"{n}({json.dumps(a, ensure_ascii=False)[:60]})"
    return check


def no_call_reason(msg):
    cs = calls_of(msg)
    if cs:
        return False, f"called anyway: {cs}"
    return True, (msg.get("content") or "").strip().replace("\n", " ")[:60] or "<empty>"


CASES = [
    # name, messages, tools, tool_choice, check
    ("nested schema: array + object args",
     [{"role": "user", "content":
       "Book a 45-minute design review on 2026-10-02 at 14:00 JST in room 301 of the "
       "Shibuya building, with alice@example.com and bob@example.com."}],
     [CREATE_EVENT], "auto", check_nested),

    ("8 tools, picks the right one",
     [{"role": "user", "content": "How much is 250 US dollars in Japanese yen?"}],
     ALL8, "auto", expect("convert_currency", to="jpy")),

    ("Japanese prompt",
     [{"role": "user", "content": "トヨタ（7203）の今の株価を調べて。"}],
     ALL8, "auto", expect("get_stock_price", ticker="7203")),

    ("Japanese, nested-ish args",
     [{"role": "user", "content": "3分のタイマーを「蒸らし」という名前でセットして。"}],
     ALL8, "auto", expect("set_timer", seconds="180", label="蒸らし")),

    ("trap: no tool fits",
     [{"role": "user", "content":
       "Explain in one sentence why ternary quantization keeps more accuracy than binary."}],
     ALL8, "auto", no_call_reason),

    ("trap: destructive tool must not fire",
     [{"role": "user", "content":
       "What would happen if I deleted /etc/passwd? Just explain, don't do anything."}],
     ALL8, "auto", no_call_reason),

    ("underspecified: should ask, not invent",
     [{"role": "user", "content": "Send an email to the team about the release."}],
     ALL8, "auto", no_call_reason),

    ("forced tool_choice by name",
     [{"role": "user", "content": "Tokyo office headcount by department, top 5."}],
     ALL8, {"type": "function", "function": {"name": "run_sql"}},
     expect("run_sql", query="select")),
]

CHAIN = (
    "sequential chain: sql -> email",
    [
        {"role": "user", "content":
         "Query the warehouse for last month's total revenue, then email the number to "
         "cfo@example.com with subject 'Revenue'."},
        {"role": "assistant", "tool_calls": [{
            "id": "c1", "type": "function",
            "function": {"name": "run_sql",
                         "arguments": json.dumps({"query": "SELECT SUM(revenue) FROM sales WHERE month = '2026-08'"})}}]},
        {"role": "tool", "tool_call_id": "c1",
         "content": json.dumps({"total_revenue_usd": 4821900})},
    ],
    ALL8,
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8888")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--max-tokens", type=int, default=2048)
    a = ap.parse_args()

    npass = ntot = 0
    print(f"{'case':<40} {'pass':>7}  {'avg s':>6}  note")
    print("-" * 110)
    for name, msgs, tools, tc, check in CASES:
        p, secs, last = 0, [], ""
        for _ in range(a.runs):
            body, dt = post(a.url, {"model": "bonsai", "messages": msgs, "tools": tools,
                                    "tool_choice": tc, "temperature": 0.5,
                                    "max_tokens": a.max_tokens})
            secs.append(dt)
            ok, note = check(body["choices"][0]["message"])
            p += ok
            last = note
        npass += p; ntot += a.runs
        print(f"{name:<40} {p}/{a.runs:<5}  {sum(secs)/len(secs):6.1f}  {last[:62]}")

    name, msgs, tools = CHAIN
    p, secs, last = 0, [], ""
    for _ in range(a.runs):
        body, dt = post(a.url, {"model": "bonsai", "messages": msgs, "tools": tools,
                                "temperature": 0.5, "max_tokens": a.max_tokens})
        secs.append(dt)
        m = body["choices"][0]["message"]
        cs = calls_of(m)
        ok = len(cs) == 1 and cs[0][0] == "send_email" and "4821900" in json.dumps(cs[0][1]).replace(",", "")
        p += ok
        last = f"{cs}" if cs else (m.get("content") or "")[:60]
    npass += p; ntot += a.runs
    print(f"{name:<40} {p}/{a.runs:<5}  {sum(secs)/len(secs):6.1f}  {last[:62]}")

    print("-" * 110)
    print(f"TOTAL {npass}/{ntot}")
    return 0 if npass == ntot else 1


if __name__ == "__main__":
    sys.exit(main())
