# llama.cpp の運用手順

サービスの概要は [services/llama-cpp.md](../services/llama-cpp.md)。

## PrismML フォークを更新する

1. `~/bonsai-workspaces` 側の `flake.lock` を先に上げる (**正は向こう側**)。
2. `modules/llama-cpp.nix` の `prismRev` / `prismHash` を向こうの lock と同じ値に合わせる。
   hash は lock の `narHash` をそのまま使えます。食い違ったら nix が期待値を出すので、それに差し替える。
3. 下の「switch 前にビルドを通す」を行う。

## switch 前にビルドを通す

CUDA 付きのソースビルドでバイナリキャッシュが効かず、初回や更新時は長くかかります。
bonsai-workspaces で `nix build .#llama-cpp-prism-cuda` 済みのものが store にあっても、nixpkgs のピンが違うため
(向こうは向こうのピン、こちらは `modules/unstable.nix` の nixpkgs-unstable) store パスは一致せず再ビルドになります。

```sh
nix build --no-link \
  .#nixosConfigurations.seita-nixos-baremetal.config.system.build.toplevel
```

## Laya の初回セットアップを見る

torch (cu121) の wheel が約 2.5 GB あり初回は数分かかります。`nixos-rebuild switch` 自体は待たずに終わり、
`laya-setup.service` が裏で走ります (タイムアウト 30 分)。

```sh
journalctl -u laya-setup -f
```

冪等です。venv が無ければ作り、あれば pip で追随し、重みが HF キャッシュにあれば再ダウンロードしません。

## GPU を載せ替えた

1. `nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv` で対応表を実測し直し、
   [GPU と VRAM の予算](../gpu-vram-budget.md) を更新する。
2. `modules/llama-cpp.nix` の各モデルの `CUDA_VISIBLE_DEVICES` を合わせる。
3. `CMAKE_CUDA_ARCHITECTURES` (`75;86`) を新しいカードの SM に合わせる
   (合わない SM の GPU では起動時に CUDA エラー。対応表は NVIDIA の CUDA GPUs)。
4. fukurou は Vulkan の列挙順で別系統です (`modules/fukurou.nix` の `GGML_VK_VISIBLE_DEVICES`)。

## 1660 SUPER 側のモデルが起動しなくなった

まず `embedding` の `-ngl` を下げるか、`CUDA_VISIBLE_DEVICES=""` + `-ngl 0` の CPU 実行に戻す
(CPU でも 66 ms/リクエストで実用範囲)。内訳は [GPU と VRAM の予算](../gpu-vram-budget.md#gtx-1660-super-index-0)。

## クラッシュループ

`startLimitBurst = 3` / `startLimitIntervalSec = 300` で、5 分に 3 回失敗したら諦めます。
止まっていたら `systemctl reset-failed llama-cpp` のうえで原因 (多くは VRAM 不足) を直してから start。
