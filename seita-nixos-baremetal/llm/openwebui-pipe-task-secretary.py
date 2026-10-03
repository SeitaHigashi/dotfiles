"""
title: Task Secretary (n8n)
description: n8n の「Task Secretary Chat」webhook を呼びます。__task__ は llama.cpp へ直接。
author: seita
version: 0.4.0
"""

# ---------------------------------------------------------------------------
# 0.4.0 (2026-09-21): Ollama -> llama.cpp (PrismML フォークのルーター) へ移行。
#
#   このファイルはリポジトリから配備できません。Open WebUI の
#   Admin Panel -> Functions に貼り付けて保存し、Enabled にしてください。
#   (原本の控えは ~/bonsai-workspaces.old/openwebui-pipe-task-secretary.py)
#
# Ollama 版からの変更点と、それぞれの理由:
#
#   1. エンドポイント  /api/chat -> /v1/chat/completions
#      llama.cpp は OpenAI 互換であって Ollama 互換ではありません。
#      レスポンスの取り出しも message.content -> choices[0].message.content。
#
#   2. task_model  "gemma4:12b" -> "bonsai"
#      モデル名は Ollama のタグではなく models.ini のプリセット名です。
#      gemma4 ではなく bonsai を選んだのは VRAM の都合です:
#        - gemma4 プリセットは GPU 2 枚を必要とします。
#        - ルーターは --models-max 2 で動いており、OpenViking が常時
#          bonsai (CUDA0) と embedding (CUDA1) を使うため、gemma4 を
#          載せる余地がありません。実際に試すと
#            {"error":"model name=gemma4 failed to load"}
#          が返ります (2026-09-21 実機確認)。
#        - bonsai は OpenViking が温めているので、タイトル生成のたびに
#          モデルの入れ替え (8-48 秒) が起きません。
#
#   3. task_num_ctx (163840) を廃止し task_max_tokens を新設
#      llama.cpp にリクエスト単位の context 指定はありません。context は
#      プリセットごとにサーバー起動時に固定です ([bonsai] は 16384)。
#      163840 という値はそもそも「num_ctx を変えるたびに Ollama が
#      モデルを再ロードする」問題への回避策で、llama.cpp には無い問題です。
#
#   4. ★ reasoning_effort = "none" は必須です ★
#      llama.cpp は推論部分を reasoning_content に分離して返しますが、
#      max_tokens の予算は共有します。指定しないとタイトル生成でも推論に
#      予算を食われ、HTTP 200・finish_reason "stop" のまま content が
#      空文字で返ります。実機で確認 (2026-09-21、同一プロンプト):
#        指定なし            -> reasoning 1713 文字、content ""
#        reasoning_effort=none -> reasoning 0 文字、content "llama.cpp 移行方法"
#      成功に見えて中身が空なので、気づきにくい壊れ方をします。
#      下の空判定はその保険です。
# ---------------------------------------------------------------------------

import requests
from pydantic import BaseModel, Field


class Pipe:
    class Valves(BaseModel):
        webhook_url: str = Field(default="http://127.0.0.1:5678/webhook/task-secretary")
        # llama.cpp のルーター (modules/llama-cpp.nix)。OpenAI 互換なので /v1 まで含める。
        llamacpp_url: str = Field(default="http://127.0.0.1:8888/v1")
        # models.ini のプリセット名。上の 2. の理由で gemma4 ではなく bonsai。
        task_model: str = Field(default="bonsai")
        # 上の 4. の理由で "none" 固定。変えると空タイトルが返るようになります。
        reasoning_effort: str = Field(default="none")
        task_max_tokens: int = Field(default=512)
        timeout: int = Field(default=180)

    def __init__(self):
        self.valves = self.Valves()

    def pipe(
        self,
        body: dict,
        __user__: dict,
        __metadata__: dict,
        __task__: str | None = None,
    ) -> str:
        messages = body.get("messages", [])
        if not messages:
            return ""

        if __task__:
            # Title/follow-up/tags/query generation 等。n8n を通さず llama.cpp に
            # 直接投げることで、実チャットの Buffer Window Memory を汚しません
            # (gotchas.md の 2026-08-05 の項)。
            r = requests.post(
                f"{self.valves.llamacpp_url}/chat/completions",
                json={
                    "model": self.valves.task_model,
                    "messages": messages,
                    "stream": False,
                    "max_tokens": self.valves.task_max_tokens,
                    "reasoning_effort": self.valves.reasoning_effort,
                },
                timeout=self.valves.timeout,
            )
            r.raise_for_status()
            choice = (r.json().get("choices") or [{}])[0]
            content = (choice.get("message") or {}).get("content") or ""
            if not content.strip():
                # 上の 4. の失敗パターン。黙って空文字を返すと Open WebUI 側が
                # 空のタイトルを保存してしまうため、原因が分かる形で落とします。
                raise RuntimeError(
                    f"llama.cpp returned empty content for __task__={__task__} "
                    f"(finish_reason={choice.get('finish_reason')}). "
                    "reasoning_effort が none になっているか、max_tokens が "
                    "足りているかを確認してください。"
                )
            return content

        r = requests.post(
            self.valves.webhook_url,
            json={
                "chatInput": messages[-1]["content"],
                "sessionId": __metadata__.get("chat_id", "default"),
            },
            timeout=self.valves.timeout,
        )
        r.raise_for_status()
        data = r.json()
        if isinstance(data, list):
            data = data[0]
        return data.get("output", "")
