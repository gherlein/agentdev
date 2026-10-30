# Serving Qwen3.8-27B on dgx1: Ollama vs SGLang + DFlash2

Researched 2026-10-29, during the first factory-test run with `local-qwen27` as the coder.

## Why this matters

The factory test's coder is now `local-qwen27`, which LiteLLM serves as
`qwen3.8:27b-q8_0` from Ollama on dgx1. The model is **dense**: every token passes through
all 27B parameters. On the first run with it, single model turns took 3.5 minutes or more.
The previous coder, qwen3-coder-next, is a mixture-of-experts model with about 3B active
parameters per token, so it is far faster per token.

The pipeline gets its quality from its loops (implement, verify, audit, fix) inside a
90-minute clock. A model too slow to finish the implementer leaves no time for the fix
rounds. Speed therefore matters as much as quality per turn.

## Published single-Spark numbers

Every row is one DGX Spark or another GB10 machine, one stream. These are other people's
measurements; none were taken on dgx1.

| Stack | tok/s | Source |
|---|---|---|
| SGLang + NVFP4 + DFlash2 ([hasso5703/dgx-spark-qwen38](https://github.com/hasso5703/dgx-spark-qwen38/)) | 71.4 (author's figure, greedy median) | repo README |
| SGLang + DFlash2 | 47.9 | [OpenZeka](https://blog.openzeka.com/en/qwen3-8-27b-on-dgx-spark-48-tok-s/) |
| SGLang + DFlash2 | 52–61 on code, 26 on prose | [NVIDIA forum](https://forums.developer.nvidia.com/t/1x-spark-new-workhorse-dflash2-sglang-is-fairly-fast-for-qwen3-8-27b-nvfp4/381142) |
| vLLM + DFlash2 | 54.3, against 11.6 without it (4.7×) | [madeye benchmark](https://madeye.github.io/qwen3.8-dflash2-gb10/) |
| SGLang / vLLM / llama.cpp + DFlash2 | 36.6 / 32.0 / 30.0, against about 11–12.7 without | [runaihome](https://runaihome.com/blog/qwen38-27b-dflash2-speculative-decoding-guide-2026/) |
| SGLang + MTP (an older form of speculative decoding) | 33–38 | [forum](https://forums.developer.nvidia.com/t/qwen3-8-27b-at-34-38-tok-s-on-dgx-spark-open-source-one-command-setup-sglang-nvfp4-dspark/380257), [Context Studios](https://www.contextstudios.ai/blog/qwen-3-8-27b-hardware-guide) |
| No speculative decoding (where dgx1's current Ollama q8 belongs) | about 11–13 | the baselines above |

**Ollama + DFlash2 on GB10: no published benchmark.** Here is what exists:

- One of DFlash2's authors [says it was ported to Ollama](https://x.com/jianchen1799/status/2089998615146348759),
  reaching up to 44 tok/s on an Apple **M5 Pro**, not a GB10.
- An older guide said Ollama 0.32 had no DFlash2 support. dgx1 runs **Ollama 0.34.1**, and
  the official `qwen3.8:27b-dflash2-nvfp4` tag (19 GB) now exists, so support has probably
  arrived since then.
- [smtek/Swift-Qwen3.8-27B:dflash](https://ollama.com/smtek/Swift-Qwen3.8-27B:dflash) claims
  a 2.15× median speedup, but doesn't say what hardware it was measured on.
- Unknown: whether Ollama uses the fast NVFP4 path on the GB10's Blackwell GPU.

### What the numbers mean

1. dgx1's current setup is on the slow baseline. About 11–13 tok/s is consistent with the
   turn times seen in the run.
2. Every published DFlash2 setup is 3–5× faster on a Spark. SGLang + DFlash2 is the proven
   route, at about 48–71 tok/s across several independent reports.
3. Ollama's dflash2 tag is untested on this hardware. It might be close to SGLang, or it
   might fall back to slow paths.
4. Speculative decoding speeds up **code** more than prose (52–61 against 26 tok/s in one
   report). Agent turns mix code with thinking, and thinking behaves more like prose. Expect
   real factory-test speeds below the headline numbers.

## Option A: the Ollama dflash2 tag (cheap, try first)

This needs no new software and is easy to undo.

1. On dgx1: `ollama pull qwen3.8:27b-dflash2-nvfp4`.
2. Add a LiteLLM route next to `local-qwen27` in `~/litellm/config.yaml`, then
   `docker restart litellm`:
   ```yaml
     - model_name: local-qwen27-dflash
       litellm_params:
         model: ollama_chat/qwen3.8:27b-dflash2-nvfp4
         api_base: http://host.docker.internal:11434
         num_ctx: 262144
   ```
3. Time it against `local-qwen27`, through LiteLLM, with the same coding prompt and a streamed
   response. Compare tokens per second.
4. If it is close to the SGLang numbers, point the factory-test coder seed at it.

## Option B: hasso5703/dgx-spark-qwen38 (SGLang), in place of Ollama for this model

### What it is
The repo is an installer for a whole serving stack on GB10 machines, not a model file.

- **Engine:** SGLang serves the Qwen lanes; vLLM serves some of the other models. There is
  no Ollama and no GGUF, so Ollama cannot run this.
- **Default model:** `RadixArk/Qwen3.8-27B-NVFP4` with DFlash2 speculative decoding, drafting
  16 tokens deep. An FP8 lane and larger MoE lanes also exist.
- **Ports:**
  - 30000: the engine, bound to 127.0.0.1;
  - **30001: an OpenAI-compatible keepalive proxy**, `/v1/chat/completions`, with an
    Anthropic-style `/v1/messages` as well;
  - 30090: a web UI.
- **Auth:** a Bearer key in `~/.config/qwen38/api-key`.
- **Served model name:** `qwen3.8-27b`.
- **Context:** 1,010,000 tokens by default through YaRN (`CONTEXT_MODE=1m`), or 262,144 native
  (`CONTEXT_MODE=native`).
- **Install:** `./install.sh` builds the image, downloads the checkpoints and installs a
  systemd service that starts at boot. `./bench.sh` measures tok/s, and `./switch-model.sh`
  changes lanes. The README's one-liner is `curl | bash`; clone the repo and read
  `install.sh` instead of piping it to a shell.
- **Requirements:** stock DGX OS with Docker CE and the NVIDIA Container Toolkit (Docker from
  Snap is not supported). The 27B alone needs about 49 GB of Hugging Face cache plus 52 GB for
  Docker.

### Putting it behind LiteLLM
Add one route; nothing else in the factory test changes except the coder seed's model id.

```yaml
  - model_name: local-qwen27-fast
    litellm_params:
      model: openai/qwen3.8-27b
      api_base: http://host.docker.internal:30001/v1
      api_key: os.environ/QWEN38_API_KEY
```

The key goes into the LiteLLM container's environment, never into `config.yaml`.

### Settle these before installing
1. **Memory.** SGLang reserves 76% of the 128 GB by default (`--mem-fraction-static 0.76`),
   or 50% in native-context mode. The author measured crashes at 0.80. It cannot share dgx1
   with Ollama's loaded models, and any request to an Ollama route on dgx1 (`local-qwen`,
   `qwen-q4`, `devstral`, `local-qwen27`) would reload an Ollama model and risk running out of
   memory. Either remove those dgx1 routes or keep Ollama's dgx1 models stopped while SGLang
   runs. glm-4.5-air on dgx2 is unaffected.
2. **Disk.** About 100 GB for the 27B lane alone.
3. **Network.** LiteLLM reaches the host from inside Docker through `host.docker.internal`,
   so port 30001 must be reachable from the Docker bridge. Keep it closed to the LAN with a
   firewall rule (the same treatment as Ollama's 11434), so every request still goes through
   LiteLLM.
4. **Timing.** Installing or benchmarking takes over dgx1's GPU. Don't do it while a
   factory-test run is in progress.

## Recommendation

1. Let the current `local-qwen27` run finish and record its anchor score and timings.
2. Try **Option A**. Measure tok/s through LiteLLM on dgx1.
3. If Option A is well short of about 45 tok/s, review and install **Option B** with
   `CONTEXT_MODE=native` (262k is enough; the 1M window costs memory the coder does not need),
   then add it behind LiteLLM.
4. Repeat the factory test with the faster backend. Compare the anchor score and the number
   of audit rounds reached against the slow q8 run and the qwen3-coder-next runs.

## Sources

- [hasso5703/dgx-spark-qwen38](https://github.com/hasso5703/dgx-spark-qwen38/)
- [ollama.com qwen3.8 tags](https://ollama.com/library/qwen3.8/tags)
- [OpenZeka: Qwen3.8-27B on DGX Spark, 48 tok/s](https://blog.openzeka.com/en/qwen3-8-27b-on-dgx-spark-48-tok-s/)
- [pangoleen/qwen3.8-27b-dgx-spark-dflash2](https://github.com/pangoleen/qwen3.8-27b-dgx-spark-dflash2)
- [NVIDIA forum: Qwen3.8-27B NVFP4, SGLang + DFlash2](https://forums.developer.nvidia.com/t/qwen3-8-27b-nvfp4-on-single-dual-dgx-spark-sglang-dflash2-fully-openai-compatible/380732)
- [NVIDIA forum: 4× DGX Spark, 107.6 tok/s](https://forums.developer.nvidia.com/t/4x-dgx-spark-running-qwen3-8-27b-nvfp4-with-sglang-dflash2-107-6-tok-s-greedy-full-repro-the-8-pitfalls-that-nearly-killed-the-cluster/382754)
- [NVIDIA forum: 34–38 tok/s one-command setup](https://forums.developer.nvidia.com/t/qwen3-8-27b-at-34-38-tok-s-on-dgx-spark-open-source-one-command-setup-sglang-nvfp4-dspark/380257)
- [NVIDIA forum: 1x Spark DFlash2 + SGLang](https://forums.developer.nvidia.com/t/1x-spark-new-workhorse-dflash2-sglang-is-fairly-fast-for-qwen3-8-27b-nvfp4/381142)
- [NVIDIA forum: Qwen 3.8 27B + DFlash2](https://forums.developer.nvidia.com/t/qwen-3-8-27b-dflash2/380617)
- [morethanamachine: Qwen3.8-27B on One DGX Spark](https://morethanamachine.com/posts/qwen3-8-27b-dgx-spark/)
- [madeye: DFlash2 on GB10, 4.70×](https://madeye.github.io/qwen3.8-dflash2-gb10/)
- [madeye/qwen3.8-dflash2-gb10](https://github.com/madeye/qwen3.8-dflash2-gb10)
- [Jian Chen: DFlash2 ported to Ollama](https://x.com/jianchen1799/status/2089998615146348759)
- [runaihome: DFlash2 guide](https://runaihome.com/blog/qwen38-27b-dflash2-speculative-decoding-guide-2026/)
- [Context Studios: Qwen 3.8 27B hardware guide](https://www.contextstudios.ai/blog/qwen-3-8-27b-hardware-guide)
- [smtek/Swift-Qwen3.8-27B:dflash](https://ollama.com/smtek/Swift-Qwen3.8-27B:dflash)
