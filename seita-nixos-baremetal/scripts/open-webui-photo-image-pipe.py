"""
title: Photo Image
description: Text-to-image through llama-swap's z-image-turbo (Z-Image Turbo) and realvisxl (RealVisXL V5.0, SDXL).

Open WebUI manifold Pipe function: one paste yields two models in the model picker.
Not deployed by Nix: paste this file into Admin Panel -> Functions -> + (see
docs/services/open-webui.md#photo-image-pipe). Text-to-image only; the bonsai-image
Pipe (scripts/open-webui-bonsai-image-pipe.py) is the one that edits attached images.
Resolution and seed are per-user, from Chat Controls -> Valves.
"""

import asyncio
import base64
import io
import json
import time
import urllib.error
import urllib.request
from typing import Literal

from fastapi import UploadFile
from pydantic import BaseModel, Field

from open_webui.models.chats import Chats
from open_webui.models.users import Users
from open_webui.routers.files import upload_file_handler

# llama-swap model ID per picker entry (aliases image-photo / image-sdxl also work).
MODELS = {"z-image-turbo": "Z-Image Turbo (photo)", "realvisxl": "RealVisXL V5.0 (SDXL photo)"}

# Both models were only measured at 1024x1024 (docs/services/llama-cpp.md#calling-z-image-turbo--realvisxl),
# so every preset keeps both sides <= 1024 and pixels <= 1024*1024, sides multiples of 64.
RESOLUTIONS = {
    "1:1 square 1024x1024": (1024, 1024),
    "1:1 square 512x512": (512, 512),
    "16:9 landscape 1024x576": (1024, 576),
    "9:16 portrait 576x1024": (576, 1024),
    "3:2 landscape 960x640": (960, 640),
    "2:3 portrait 640x960": (640, 960),
    "4:3 landscape 1024x768": (1024, 768),
    "3:4 portrait 768x1024": (768, 1024),
}
assert all(w <= 1024 and h <= 1024 and w % 64 == 0 and h % 64 == 0 for w, h in RESOLUTIONS.values())


class Pipe:
    class Valves(BaseModel):
        endpoint: str = Field(
            default="http://127.0.0.1:8888/v1/images/generations",
            description="OpenAI-style images endpoint behind llama-swap",
        )
        # Measured with sd-cli: 32-44 s per 1024x1024 image including the cold load;
        # waiting for bonsai's in-flight requests comes on top.
        timeout_s: int = Field(default=900, description="HTTP timeout per image")

    class UserValves(BaseModel):
        resolution: Literal[tuple(RESOLUTIONS)] = Field(default="1:1 square 1024x1024")
        seed: int = Field(default=-1, ge=-1, le=2**31 - 1, description="-1 = random; otherwise fixed")

    def __init__(self):
        self.valves = self.Valves()

    def pipes(self):
        return [{"id": k, "name": v} for k, v in MODELS.items()]

    def _post(self, payload: dict) -> dict:
        req = urllib.request.Request(
            self.valves.endpoint,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},  # llama-swap reads "model" only with this
        )
        try:
            with urllib.request.urlopen(req, timeout=self.valves.timeout_s) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"HTTP {e.code}: {e.read().decode(errors='replace')[:500]}") from None

    async def pipe(self, body: dict, __user__: dict, __request__, __task__=None,
                   __chat_id__=None, __message_id__=None, __event_emitter__=None):
        # Title/tag/follow-up tasks also route to the chat's model; never load an
        # image model (evicting bonsai) for them.
        if __task__:
            return ""

        # Open WebUI passes "<function id>.<pipe id>" as the model.
        model = body.get("model", "").rsplit(".", 1)[-1]
        if model not in MODELS:
            return f"Unknown model `{model}`."

        msg = next((m for m in reversed(body["messages"]) if m.get("role") == "user"), body["messages"][-1])
        content = msg["content"]
        if isinstance(content, list):
            content = " ".join(p.get("text", "") for p in content if p.get("type") == "text")
        prompt = content.strip()
        if not prompt:
            return "Enter a prompt describing the image."

        uv = __user__.get("valves") or self.UserValves()
        width, height = RESOLUTIONS[uv.resolution]
        payload = {"model": model, "prompt": prompt, "size": f"{width}x{height}"}
        if uv.seed >= 0:
            payload["seed"] = uv.seed

        async def status(text, done=False):
            if __event_emitter__:
                await __event_emitter__({"type": "status", "data": {"description": text, "done": done}})

        await status(f"Generating {width}x{height} with {model} — ~35 s, longer if bonsai has to be unloaded first")
        start = time.monotonic()
        try:
            res = await asyncio.to_thread(self._post, payload)
            item = res["data"][0]
            png = base64.b64decode(item["b64_json"])
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
        return f"![{model}](/api/v1/files/{file_item.id}/content)\n\n{width}x{height}, seed {uv.seed if uv.seed >= 0 else 'random'}"
