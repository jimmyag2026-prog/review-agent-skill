#!/usr/bin/env python3
"""_model.py — resolve which OpenRouter model to use for review-agent LLM calls.

v2.2.4+ precedence (highest → lowest):
  1. REVIEW_AGENT_MODEL env var (explicit override)
  2. ~/.openclaw/openclaw.json → agents.defaults.model.primary
     (the SAME source the per-peer subagent uses for its IM replies; this
      keeps skill scripts in sync with the subagent's model)
  3. ~/.openclaw/openclaw.json → agents.defaults.models[*].alias == "default"
     (back-compat for older configs)
  4. ~/.openclaw/openclaw.json → models.providers.openrouter.models[0]
     (back-compat for v2.0–v2.2.3, which read this list directly)
  5. Hard fallback: "anthropic/claude-sonnet-4.6"

Returns a string ready for OpenRouter /chat/completions, with the
`openrouter/` prefix stripped if present (openclaw stores fully-qualified
ids like "openrouter/deepseek/deepseek-v4-flash"; the OpenRouter API takes
"deepseek/deepseek-v4-flash"). Direct-provider ids like
"google/gemini-3-pro-preview" pass through unchanged — but note: those
will only work via OpenRouter if OR routes that exact id; otherwise
scripts hit a 404 and fall back to FALLBACK_MODEL. To pin a specific
OpenRouter-routable model, set REVIEW_AGENT_MODEL.
"""
import json
import os
from pathlib import Path


FALLBACK_MODEL = "anthropic/claude-sonnet-4.6"


def _strip_or_prefix(mid):
    if isinstance(mid, str) and mid.startswith("openrouter/"):
        return mid[len("openrouter/"):]
    return mid


def _openclaw_default_model():
    cfg_path = Path.home() / ".openclaw" / "openclaw.json"
    if not cfg_path.exists():
        return None
    try:
        cfg = json.loads(cfg_path.read_text())
    except Exception:
        return None

    defaults_node = ((cfg.get("agents") or {}).get("defaults") or {})

    # (2) NEW: agents.defaults.model.primary — what the per-peer subagent uses
    model_primary = (defaults_node.get("model") or {}).get("primary")
    if model_primary:
        return _strip_or_prefix(model_primary)

    # (3) Back-compat: agents.defaults.models[*] with alias == "default"
    defaults = defaults_node.get("models") or {}
    if isinstance(defaults, dict):
        for model_id, meta in defaults.items():
            if isinstance(meta, dict) and meta.get("alias") == "default":
                return _strip_or_prefix(model_id)

    # (4) Back-compat: first openrouter model in providers list
    providers = ((cfg.get("models") or {}).get("providers") or {})
    openrouter = providers.get("openrouter") or {}
    models_list = openrouter.get("models") or []
    for m in models_list:
        mid = m.get("id") if isinstance(m, dict) else None
        if mid:
            return mid

    return None


def get_main_agent_model():
    env_model = os.environ.get("REVIEW_AGENT_MODEL", "").strip()
    if env_model:
        return env_model

    picked = _openclaw_default_model()
    if picked:
        return picked

    return FALLBACK_MODEL


if __name__ == "__main__":
    # Self-test
    override_cases = [
        ("explicit env", {"REVIEW_AGENT_MODEL": "openai/gpt-5"}, "openai/gpt-5"),
        ("no env, uses config/fallback", {"REVIEW_AGENT_MODEL": ""}, None),
    ]
    for name, env_patch, expected in override_cases:
        saved = {k: os.environ.get(k) for k in env_patch}
        os.environ.update({k: v for k, v in env_patch.items()})
        got = get_main_agent_model()
        if expected is not None:
            ok = "✓" if got == expected else "✗"
            print(f"  {ok} {name}: got={got} expected={expected}")
        else:
            print(f"  · {name}: resolved to → {got}")
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
