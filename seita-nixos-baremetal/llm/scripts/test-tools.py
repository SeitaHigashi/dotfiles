#!/usr/bin/env python3
"""Tool-calling test suite for Ternary-Bonsai-27B served by llama-server.

Assumes `bonsai-server` (llama-server --jinja) is already listening.
Usage: python3 scripts/test-tools.py [--url http://127.0.0.1:8888] [--runs 3]
"""
import argparse
import json
import sys
import time
import urllib.request

WEATHER = {
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
            "type": "object",
            "properties": {
                "city": {"type": "string", "description": "City name"},
                "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]},
            },
            "required": ["city"],
        },
    },
}

CALC = {
    "type": "function",
    "function": {
        "name": "calculate",
        "description": "Evaluate an arithmetic expression.",
        "parameters": {
            "type": "object",
            "properties": {"expression": {"type": "string"}},
            "required": ["expression"],
        },
    },
}

SEARCH = {
    "type": "function",
    "function": {
        "name": "web_search",
        "description": "Search the web for a query.",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "max_results": {"type": "integer", "minimum": 1, "maximum": 10},
            },
            "required": ["query"],
        },
    },
}

ALL_TOOLS = [WEATHER, CALC, SEARCH]


def post(url, payload, timeout=600):
    req = urllib.request.Request(
        url + "/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = json.load(r)
    return body, time.time() - t0


def calls_of(msg):
    out = []
    for c in msg.get("tool_calls") or []:
        fn = c.get("function", {})
        args = fn.get("arguments")
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except json.JSONDecodeError:
                args = {"__unparsable__": args}
        out.append((fn.get("name"), args))
    return out


# --- checks -----------------------------------------------------------------

def one_call(name, **expect):
    def check(msg):
        cs = calls_of(msg)
        if len(cs) != 1:
            return False, f"expected 1 tool_call, got {len(cs)}: {cs}"
        got_name, args = cs[0]
        if got_name != name:
            return False, f"expected {name}, got {got_name}"
        for k, want in expect.items():
            have = args.get(k)
            if isinstance(want, (list, tuple)):
                ok = any(str(w).lower() in str(have).lower() for w in want)
            else:
                ok = str(want).lower() in str(have).lower()
            if not ok:
                return False, f"arg {k}={have!r} does not match {want!r}"
        return True, f"{got_name}({args})"
    return check


def no_call(msg):
    cs = calls_of(msg)
    if cs:
        return False, f"unexpected tool_call: {cs}"
    if not (msg.get("content") or "").strip():
        return False, "no tool_call and no content"
    return True, "answered directly"


def two_calls_weather(msg):
    cs = calls_of(msg)
    if len(cs) != 2:
        return False, f"expected 2 parallel tool_calls, got {len(cs)}: {cs}"
    if any(n != "get_weather" for n, _ in cs):
        return False, f"wrong tool names: {[n for n, _ in cs]}"
    cities = " ".join(str(a.get("city", "")).lower() for _, a in cs)
    if "tokyo" not in cities or "osaka" not in cities:
        return False, f"cities not both present: {cities!r}"
    return True, f"{cs}"


CASES = [
    ("single tool, obvious call",
     [{"role": "user", "content": "What's the weather in Tokyo right now?"}],
     [WEATHER], one_call("get_weather", city="tokyo")),

    ("tool selection among 3",
     [{"role": "user", "content": "What is 1234 * 5678?"}],
     ALL_TOOLS, one_call("calculate", expression="1234")),

    ("enum arg extraction",
     [{"role": "user", "content": "Weather in Osaka, in fahrenheit please."}],
     ALL_TOOLS, one_call("get_weather", city="osaka", unit="fahrenheit")),

    ("integer arg extraction",
     [{"role": "user", "content": "Search the web for 'ternary quantization', give me 3 results."}],
     ALL_TOOLS, one_call("web_search", query="ternary", max_results="3")),

    ("negative: must NOT call a tool",
     [{"role": "user", "content": "Hi! Briefly, what is the capital of France?"}],
     ALL_TOOLS, no_call),

    ("parallel calls",
     [{"role": "user", "content": "Compare the weather in Tokyo and Osaka."}],
     [WEATHER], two_calls_weather),
]

FOLLOWUP = (
    "multi-turn: tool result -> final answer",
    [
        {"role": "user", "content": "What's the weather in Tokyo?"},
        {"role": "assistant", "tool_calls": [{
            "id": "call_1", "type": "function",
            "function": {"name": "get_weather",
                         "arguments": json.dumps({"city": "Tokyo", "unit": "celsius"})},
        }]},
        {"role": "tool", "tool_call_id": "call_1",
         "content": json.dumps({"city": "Tokyo", "temp_c": 31, "condition": "humid, clear"})},
    ],
    [WEATHER],
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8888")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--max-tokens", type=int, default=1024)
    args = ap.parse_args()

    total_pass = total = 0
    print(f"{'case':<38} {'pass':>7}  {'avg s':>6}  note")
    print("-" * 100)

    for name, messages, tools, check in CASES:
        passes, secs, last = 0, [], ""
        for _ in range(args.runs):
            body, dt = post(args.url, {
                "model": "bonsai", "messages": messages, "tools": tools,
                "tool_choice": "auto", "temperature": 0.5,
                "max_tokens": args.max_tokens,
            })
            secs.append(dt)
            msg = body["choices"][0]["message"]
            ok, note = check(msg)
            passes += ok
            last = note
        total_pass += passes
        total += args.runs
        print(f"{name:<38} {passes}/{args.runs:<5}  {sum(secs)/len(secs):6.1f}  {last[:60]}")

    # multi-turn
    name, messages, tools = FOLLOWUP
    passes, secs, last = 0, [], ""
    for _ in range(args.runs):
        body, dt = post(args.url, {
            "model": "bonsai", "messages": messages, "tools": tools,
            "temperature": 0.5, "max_tokens": args.max_tokens,
        })
        secs.append(dt)
        msg = body["choices"][0]["message"]
        content = (msg.get("content") or "")
        ok = "31" in content and not calls_of(msg)
        passes += ok
        last = content.strip().replace("\n", " ")[:60] or "<empty>"
    total_pass += passes
    total += args.runs
    print(f"{name:<38} {passes}/{args.runs:<5}  {sum(secs)/len(secs):6.1f}  {last}")

    print("-" * 100)
    print(f"TOTAL {total_pass}/{total}")
    return 0 if total_pass == total else 1


if __name__ == "__main__":
    sys.exit(main())
