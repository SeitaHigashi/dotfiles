"""
title: MiniMax-H3 Video
description: Text-to-video (+ stereo audio) through llama-swap's minimax-h3 (sd-server).

Open WebUI Pipe function. Not deployed by Nix: paste this file into
Admin Panel -> Functions -> + (see docs/services/open-webui.md#minimax-h3-video-pipe).
Resolution / fps / frames are per-user, from Chat Controls -> Valves.
"""

import asyncio
import base64
import io
import json
import time
import urllib.request
from typing import Literal

from fastapi import UploadFile
from pydantic import BaseModel, Field

from open_webui.models.chats import Chats
from open_webui.models.users import Users
from open_webui.routers.files import upload_file_handler

# Measured ceiling: 864x480 x 56 frames = VRAM peak 7322 MiB of 8192 on the
# 3060 Ti (docs/services/llama-cpp.md#calling-minimax-h3). Every preset keeps
# pixels <= 864*480 and frames <= 56; do not add larger ones without measuring.
# Sides are multiples of 32, like the measured shape.
RESOLUTIONS = {
    "16:9 landscape 864x480": (864, 480),
    "16:9 landscape 640x352": (640, 352),
    "9:16 Shorts/Reels/TikTok 480x864": (480, 864),
    "9:16 Shorts/Reels/TikTok 352x640": (352, 640),
    "4:5 Instagram feed 384x480": (384, 480),
    "1:1 square 480x480": (480, 480),
    "4:3 landscape 640x480": (640, 480),
    "3:4 portrait 480x640": (480, 640),
}
assert all(w * h <= 864 * 480 and w % 32 == 0 and h % 32 == 0 for w, h in RESOLUTIONS.values())


class Pipe:
    class Valves(BaseModel):
        endpoint: str = Field(
            default="http://127.0.0.1:8888/upstream/minimax-h3/sync/vid_gen",
            description="Blocking sd-server endpoint behind llama-swap",
        )
        # One job is 6-11 min, plus model load and queueing behind bonsai.
        timeout_s: int = Field(default=1800, description="HTTP timeout per job")

    class UserValves(BaseModel):
        resolution: Literal[tuple(RESOLUTIONS)] = Field(default="16:9 landscape 864x480")
        fps: Literal[16, 24, 30] = Field(default=24)
        video_frames: Literal[24, 40, 56] = Field(default=56, description="56 frames = 2.3 s at 24 fps")

    def __init__(self):
        self.valves = self.Valves()

    def _post(self, payload: dict) -> dict:
        req = urllib.request.Request(
            self.valves.endpoint,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=self.valves.timeout_s) as r:
            return json.loads(r.read())

    async def pipe(self, body: dict, __user__: dict, __request__, __task__=None,
                   __chat_id__=None, __message_id__=None, __event_emitter__=None):
        # Title/tag/follow-up tasks also route to the chat's model; never start
        # a 10-minute video for them (Open WebUI falls back to the user text).
        if __task__:
            return ""

        content = body["messages"][-1]["content"]
        if isinstance(content, list):
            content = " ".join(p.get("text", "") for p in content if p.get("type") == "text")
        prompt = content.strip()
        if not prompt:
            return "Enter a prompt describing the video."

        uv = __user__.get("valves") or self.UserValves()
        width, height = RESOLUTIONS[uv.resolution]
        shape = f"{width}x{height}, {uv.video_frames} frames @ {uv.fps} fps ({uv.video_frames / uv.fps:.1f} s)"

        async def status(text, done=False):
            if __event_emitter__:
                await __event_emitter__({"type": "status", "data": {"description": text, "done": done}})

        await status(f"Generating {shape} — usually 6-11 min; bonsai requests wait meanwhile")
        start = time.monotonic()
        try:
            res = await asyncio.to_thread(self._post, {
                "prompt": prompt, "width": width, "height": height,
                "video_frames": uv.video_frames, "fps": uv.fps,
            })
        except Exception as e:
            await status(f"Failed: {e}", done=True)
            return f"Video generation failed: `{e}`"
        if res.get("status") != "completed":
            await status("Failed", done=True)
            return f"Video generation failed:\n```\n{json.dumps(res, ensure_ascii=False)[:2000]}\n```"

        result = res["result"]
        mime = result.get("mime_type", "video/webm")
        user = await Users.get_user_by_id(__user__["id"])
        file_item = await upload_file_handler(
            __request__,
            file=UploadFile(
                file=io.BytesIO(base64.b64decode(result["b64_json"])),
                filename="generated-video." + mime.split("/")[-1],
                headers={"content-type": mime},
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
        await status(f"Done in {time.monotonic() - start:.0f} s — {shape}", done=True)
        # HTMLToken.svelte (0.11.3) reads the URL from the <video> element's *text*,
        # and only a block-level token holds the whole element, so <video> must sit
        # alone on its line. The {{VIDEO_FILE_ID_x}} placeholder expands to
        # <video src=...></video>, which that parser prints as raw text.
        return f"<video>\n/api/v1/files/{file_item.id}/content\n</video>\n\n{shape}"
