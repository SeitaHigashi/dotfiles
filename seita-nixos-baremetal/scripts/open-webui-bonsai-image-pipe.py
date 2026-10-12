"""
title: Bonsai Image
description: Text-to-image, and editing of an attached image, through llama-swap's bonsai-image (Bonsai Image Ternary 4B, gemlite).

Open WebUI Pipe function. Not deployed by Nix: paste this file into
Admin Panel -> Functions -> + (see docs/services/open-webui.md#bonsai-image-pipe).
Resolution and seed are per-user, from Chat Controls -> Valves.
If the last user message carries an image, it is sent to /v1/images/edits as the
reference (output size follows the reference, so the resolution valve is unused;
only that one attached image is used, not earlier generated ones). Otherwise the
prompt goes to /v1/images/generations as text-to-image.
"""

import asyncio
import base64
import io
import json
import re
import time
import uuid
import urllib.error
import urllib.request
from typing import Literal

from fastapi import UploadFile
from pydantic import BaseModel, Field

from open_webui.models.chats import Chats
from open_webui.models.users import Users
from open_webui.routers.files import upload_file_handler

# Measured ceiling: 1024x1024 = 6833 MiB torch peak, 7812 MiB nvidia-smi peak of
# 8192 on the 3060 Ti (docs/services/llama-cpp.md#calling-bonsai-image). Every
# preset keeps both sides <= 1024 and pixels <= 1024*1024, sides multiples of 32.
# The server accepts up to 2560x1440 (measured 2026-10-12, with VAE tiling); the
# presets were left at 1024 and larger ones can be added on request.
RESOLUTIONS = {
    "1:1 square 1024x1024": (1024, 1024),
    "1:1 square 512x512": (512, 512),
    "16:9 landscape 1024x576": (1024, 576),
    "9:16 portrait 576x1024": (576, 1024),
    "3:2 landscape 1024x672": (1024, 672),
    "2:3 portrait 672x1024": (672, 1024),
    "4:3 landscape 1024x768": (1024, 768),
    "3:4 portrait 768x1024": (768, 1024),
}
assert all(w <= 1024 and h <= 1024 and w % 32 == 0 and h % 32 == 0 for w, h in RESOLUTIONS.values())


class Pipe:
    class Valves(BaseModel):
        endpoint: str = Field(
            default="http://127.0.0.1:8888/v1/images/generations",
            description="OpenAI-style images endpoint behind llama-swap",
        )
        edits_endpoint: str = Field(
            default="http://127.0.0.1:8888/v1/images/edits",
            description="OpenAI-style image edit endpoint (multipart), used when an image is attached",
        )
        model: str = Field(default="bonsai-image", description="llama-swap model ID")
        # Warm image: ~10 s. After a swap: ~95-115 s (weights load + Triton
        # compile on a cold cache), plus waiting for bonsai's in-flight requests.
        timeout_s: int = Field(default=900, description="HTTP timeout per image")

    class UserValves(BaseModel):
        resolution: Literal[tuple(RESOLUTIONS)] = Field(default="1:1 square 1024x1024")
        seed: int = Field(default=-1, ge=-1, le=2**31 - 1, description="-1 = random; otherwise fixed")

    def __init__(self):
        self.valves = self.Valves()

    def _post(self, payload: dict, image: bytes | None = None) -> dict:
        if image is None:
            req = urllib.request.Request(
                self.valves.endpoint,
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"},  # llama-swap reads "model" only with this
            )
        else:
            boundary = uuid.uuid4().hex
            body = b""
            for k, v in payload.items():
                body += (f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n').encode()
            body += (f'--{boundary}\r\nContent-Disposition: form-data; name="image"; filename="image.png"\r\n'
                     "Content-Type: application/octet-stream\r\n\r\n").encode() + image + f"\r\n--{boundary}--\r\n".encode()
            req = urllib.request.Request(
                self.valves.edits_endpoint, data=body,
                headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
            )
        try:
            with urllib.request.urlopen(req, timeout=self.valves.timeout_s) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            # The server answers errors as {"error": {"message": ...}}; show that, not "HTTP Error 500".
            raise RuntimeError(f"HTTP {e.code}: {e.read().decode(errors='replace')[:500]}") from None

    async def pipe(self, body: dict, __user__: dict, __request__, __task__=None,
                   __chat_id__=None, __message_id__=None, __event_emitter__=None):
        # Title/tag/follow-up tasks also route to the chat's model; never load the
        # image model (evicting bonsai) for them. Open WebUI falls back to the user text.
        if __task__:
            return ""

        msg = next((m for m in reversed(body["messages"]) if m.get("role") == "user"), body["messages"][-1])
        content = msg["content"]
        ref = None
        if isinstance(content, list):
            for p in content:
                m = re.match(r"data:[^;,]*;base64,(.*)", (p.get("image_url") or {}).get("url", ""), re.S) \
                    if p.get("type") == "image_url" else None
                if m:
                    ref = base64.b64decode(m.group(1))
                    break
            content = " ".join(p.get("text", "") for p in content if p.get("type") == "text")
        prompt = content.strip()
        if not prompt:
            return "Enter a prompt describing the image."

        uv = __user__.get("valves") or self.UserValves()
        width, height = RESOLUTIONS[uv.resolution]
        payload = {"model": self.valves.model, "prompt": prompt}
        if ref is None:  # edits: no size, the server follows the reference
            payload["size"] = f"{width}x{height}"
        if uv.seed >= 0:
            payload["seed"] = uv.seed

        async def status(text, done=False):
            if __event_emitter__:
                await __event_emitter__({"type": "status", "data": {"description": text, "done": done}})

        what = "Editing the attached image" if ref is not None else f"Generating {width}x{height}"
        await status(f"{what} — ~10 s, or ~2 min if the model has to be loaded (bonsai is unloaded meanwhile)")
        start = time.monotonic()
        try:
            res = await asyncio.to_thread(self._post, payload, ref)
            item = res["data"][0]
            png = base64.b64decode(item["b64_json"])
            if ref is not None:
                width, height = item["generated_size"].split("x")
        except Exception as e:
            await status(f"Failed: {e}", done=True)
            return f"Image generation failed: `{e}`"

        user = await Users.get_user_by_id(__user__["id"])
        file_item = await upload_file_handler(
            __request__,
            file=UploadFile(
                file=io.BytesIO(png),
                filename="generated-image.png",
                headers={"content-type": "image/png"},
            ),
            metadata={"chat_id": __chat_id__, "message_id": __message_id__},
            process=False,
            user=user,
        )
        if __chat_id__ and __message_id__:
            await Chats.insert_chat_files(
                chat_id=__chat_id__, message_id=__message_id__,
                file_ids=[file_item.id], user_id=user.id,
            )
        await status(f"Done in {time.monotonic() - start:.0f} s — {width}x{height}", done=True)
        return f"![bonsai-image](/api/v1/files/{file_item.id}/content)\n\n{width}x{height}, seed {item.get('seed', 'unknown')}"
