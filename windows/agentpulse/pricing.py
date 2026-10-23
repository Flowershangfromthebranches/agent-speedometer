"""Model pricing table and token cost estimation matching ModelPricing.swift."""
from dataclasses import dataclass
from typing import Optional, List, Dict
import re
from .models import TokenTotals, CostEstimate

@dataclass
class ModelPrice:
    display_name: str
    input: float
    output: float
    cache_read: float
    cache_creation: float

def _p(name: str, inp: float, out: float, read: float, creation: float) -> ModelPrice:
    return ModelPrice(display_name=name, input=inp, output=out, cache_read=read, cache_creation=creation)

class ModelPricingTable:
    prices: Dict[str, ModelPrice] = {
        # Anthropic
        "claude-fable-5-1": _p("Claude Fable 5.1", 10, 50, 0.25, 12.50),
        "claude-mythos-5-1": _p("Claude Mythos 5.1", 10, 50, 0.25, 12.50),
        "claude-fable-5": _p("Claude Fable 5", 10, 50, 1.00, 12.50),
        "claude-mythos-5": _p("Claude Mythos 5", 10, 50, 1.00, 12.50),
        "claude-opus-5-5": _p("Claude Opus 5.5", 4, 20, 0.20, 5),
        "claude-opus-5": _p("Claude Opus 5", 5, 25, 0.50, 6.25),
        "claude-opus-4-8": _p("Claude Opus 4.8", 5, 25, 0.50, 6.25),
        "claude-opus-4-7": _p("Claude Opus 4.7", 5, 25, 0.50, 6.25),
        "claude-opus-4-6": _p("Claude Opus 4.6", 5, 25, 0.50, 6.25),
        "claude-opus-4-5": _p("Claude Opus 4.5", 5, 25, 0.50, 6.25),
        "claude-opus-4-1": _p("Claude Opus 4.1", 15, 75, 1.50, 18.75),
        "claude-opus-4": _p("Claude Opus 4", 15, 75, 1.50, 18.75),
        "claude-sonnet-5-5": _p("Claude Sonnet 5.5", 2, 10, 0.10, 2.50),
        "claude-sonnet-5": _p("Claude Sonnet 5", 2, 10, 0.20, 2.50),
        "claude-sonnet-4-6": _p("Claude Sonnet 4.6", 3, 15, 0.30, 3.75),
        "claude-sonnet-4-5": _p("Claude Sonnet 4.5", 3, 15, 0.30, 3.75),
        "claude-sonnet-4": _p("Claude Sonnet 4", 3, 15, 0.30, 3.75),
        "claude-haiku-5-5": _p("Claude Haiku 5.5", 0.10, 0.50, 0.01, 0.125),
        "claude-haiku-4-5": _p("Claude Haiku 4.5", 1, 5, 0.10, 1.25),
        "claude-3-5-haiku": _p("Claude 3.5 Haiku", 0.80, 4, 0.08, 1),
        "claude-3-5-sonnet": _p("Claude 3.5 Sonnet", 3, 15, 0.30, 3.75),

        # OpenAI
        "gpt-6-astra": _p("GPT-6 Astra", 10, 50, 1, 12.5),
        "gpt-6.1-sol": _p("GPT-6.1 Sol", 2, 10, 0.10, 2.50),
        "gpt-6-sol": _p("GPT-6 Sol", 2, 10, 0.20, 2.50),
        "gpt-6-luna": _p("GPT-6 Luna", 0.10, 0.50, 0.01, 0.125),
        "gpt-5.6-sol": _p("GPT-5.6 Sol", 4, 20, 0.40, 5),
        "gpt-5.6-terra": _p("GPT-5.6 Terra", 2, 12, 0.20, 2.50),
        "gpt-5.6-luna": _p("GPT-5.6 Luna", 0.20, 1.20, 0.02, 0.25),
        "gpt-5.6-cyber": _p("GPT-5.6 Cyber", 12.50, 75, 1.25, 15.625),
        "gpt-5.6": _p("GPT-5.6 Sol", 4, 20, 0.40, 5),
        "gpt-5.5": _p("GPT-5.5", 5, 30, 0.50, 0),
        "gpt-5.4": _p("GPT-5.4", 2.50, 15, 0.25, 0),
        "gpt-5.4-mini": _p("GPT-5.4 Mini", 0.75, 4.50, 0.075, 0),
        "gpt-5.4-nano": _p("GPT-5.4 Nano", 0.20, 1.25, 0.02, 0),
        "gpt-5.3-codex-spark": _p("GPT-5.3 Codex Spark", 1.75, 14, 0.175, 0),
        "gpt-5.3-codex": _p("GPT-5.3 Codex", 1.75, 14, 0.175, 0),
        "gpt-5.2-codex": _p("GPT-5.2 Codex", 1.75, 14, 0.175, 0),
        "gpt-5.2": _p("GPT-5.2", 1.75, 14, 0.175, 0),
        "gpt-5.1-codex": _p("GPT-5.1 Codex", 1.25, 10, 0.125, 0),
        "gpt-5-codex": _p("GPT-5 Codex", 1.25, 10, 0.125, 0),
        "gpt-5": _p("GPT-5", 1.25, 10, 0.125, 0),
        "gpt-5-mini": _p("GPT-5 Mini", 0.25, 2, 0.025, 0),
        "gpt-5-nano": _p("GPT-5 Nano", 0.05, 0.40, 0.005, 0),
        "codex-mini": _p("Codex Mini", 0.75, 3, 0.025, 0),
        "o3-pro": _p("OpenAI o3-pro", 20, 80, 0, 0),
        "o3-mini": _p("OpenAI o3-mini", 1.10, 4.40, 0.55, 0),
        "o1": _p("OpenAI o1", 15, 60, 7.50, 0),
        "o1-mini": _p("OpenAI o1-mini", 0.55, 2.20, 0.55, 0),

        # DeepSeek
        "deepseek-v4.1-flash": _p("DeepSeek V4.1 Flash", 0.3, 1.2, 0.006, 0),
        "deepseek-v4-flash": _p("DeepSeek V4 Flash", 0.3, 1.2, 0.006, 0),
        "deepseek-flash": _p("DeepSeek V4.1 Flash", 0.3, 1.2, 0.006, 0),
        "deepseek-v4-pro": _p("DeepSeek V4 Pro", 1.32, 3.96, 0.044, 0),
        "deepseek-v3.2": _p("DeepSeek V3.2", 0.28, 0.42, 0.028, 0),
        "deepseek-v3.1": _p("DeepSeek V3.1", 0.55, 1.67, 0.055, 0),
        "deepseek-v3": _p("DeepSeek V3", 0.28, 1.11, 0.028, 0),
        "deepseek-chat": _p("DeepSeek Chat", 0.44, 1.32, 0.014, 0),
        "deepseek-reasoner": _p("DeepSeek Reasoner", 0.44, 1.32, 0.014, 0),
        "deepseek-v4-flash-free": _p("DeepSeek V4 Flash Free", 0, 0, 0, 0),

        # Moonshot / Kimi
        "kimi-k3": _p("Kimi K3", 3, 15, 0.30, 3),
        "k3": _p("Kimi K3", 3, 15, 0.30, 3),
        "kimi-k2.7-code-highspeed": _p("Kimi K2.7 Code HighSpeed", 1.90, 8, 0.38, 0),
        "kimi-k2.7-code": _p("Kimi K2.7 Code", 0.95, 4, 0.19, 0),
        "kimi-k2.7": _p("Kimi K2.7", 0.95, 4, 0.19, 0),
        "kimi-k2.6": _p("Kimi K2.6", 0.95, 4, 0.16, 0),
        "kimi-k2.5": _p("Kimi K2.5", 0.60, 3, 0.10, 0),
        "kimi-k2-thinking": _p("Kimi K2 Thinking", 0.55, 2.20, 0.10, 0),
        "kimi-k2-turbo": _p("Kimi K2 Turbo", 1.11, 8.06, 0.14, 0),
        "kimi-k2-0905": _p("Kimi K2", 0.55, 2.20, 0.10, 0),

        # Tencent Hunyuan
        "hunyuan-hy3": _p("Hunyuan Hy3", 0.14, 0.56, 0.035, 0),
        "hy3": _p("Hunyuan Hy3", 0.14, 0.56, 0.035, 0),
        "hy4-preview": _p("Hunyuan Hy4 Preview", 0.84, 2.52, 0.042, 0),

        # Zhipu GLM
        "glm-5.3-flashx": _p("GLM-5.3-FlashX", 0.37, 1.25, 0.075, 0),
        "glm-5.3-flash": _p("GLM-5.3-Flash", 0.15, 0.50, 0.03, 0),
        "glm-5.3": _p("GLM-5.3", 1.4, 4.4, 0.26, 0),
        "glm-5.2": _p("GLM-5.2", 1.4, 4.4, 0.26, 0),
        "glm-5.1": _p("GLM-5.1", 1.4, 4.4, 0.26, 0),
        "glm-5": _p("GLM-5", 1, 3.2, 0.2, 0),
        "glm-5-turbo": _p("GLM-5-Turbo", 1.2, 4, 0.24, 0),
        "glm-5v-turbo": _p("GLM-5V-Turbo", 1.2, 4, 0.24, 0),
        "glm-4.7": _p("GLM-4.7", 0.6, 2.2, 0.11, 0),
        "glm-4.6": _p("GLM-4.6", 0.6, 2.2, 0.11, 0),

        # Xiaomi MiMo
        "mimo-v2.6-pro-ultraspeed": _p("MiMo V2.6 Pro UltraSpeed", 4.35, 8.7, 0.036, 0),
        "mimo-v2.6-pro": _p("MiMo V2.6 Pro", 0.435, 0.87, 0.0036, 0),
        "mimo-v2.6-flash": _p("MiMo V2.6 Flash", 0.14, 0.28, 0.0028, 0),
        "mimo-v2.5-pro": _p("MiMo V2.5 Pro", 0.435, 0.87, 0.0036, 0),
        "mimo-v2.5": _p("MiMo V2.5", 0.14, 0.28, 0.0028, 0),
        "mimo-v2.5-free": _p("MiMo V2.5 Free", 0, 0, 0, 0),
        "mimo-v2-pro": _p("MiMo V2 Pro", 0.435, 0.87, 0.0036, 0),
        "mimo-v2-flash": _p("MiMo V2 Flash", 0.09, 0.29, 0.009, 0),

        # Alibaba Qwen
        "qwen3.8-max": _p("Qwen3.8 Max", 2, 6, 0.25, 2.50),
        "qwen3.8-flash": _p("Qwen3.8 Flash", 0.15, 0.47, 0.016, 0.20),
        "qwen3.8-2.4t-a95b": _p("Qwen3.8 2.4T A95B", 2, 6, 0.25, 2.50),
        "qwen3.8-27b": _p("Qwen3.8 27B", 0.50, 3, 0.10, 0.625),
        "qwen3.7-max": _p("Qwen3.7 Max", 2.50, 7.50, 0.25, 0),
        "qwen3.7-plus": _p("Qwen3.7 Plus", 0.40, 1.60, 0.08, 0),
        "qwen3.7-flash": _p("Qwen3.7 Flash", 0.03, 0.13, 0.006, 0.0375),
        "qwen3.6-27b": _p("Qwen3.6 27B", 0.60, 3.60, 0, 0),

        # MiniMax
        "minimax-m3.1-flash": _p("MiniMax M3.1 Flash", 0.15, 0.60, 0.015, 0),
        "minimax-m2.1": _p("MiniMax M2.1", 0.30, 1.20, 0.03, 0.375),

        # StepFun
        "step-5-preview": _p("Step 5 Preview", 0.98, 2.80, 0.10, 0),
        "step-3.7-flash": _p("Step 3.7 Flash", 0.19, 1.13, 0.04, 0),
        "step-3.5-flash": _p("Step 3.5 Flash", 0.10, 0.30, 0.02, 0),

        # xAI Grok
        "grok-4.7-build": _p("Grok 4.7 Build", 2, 6, 0.50, 0),
        "grok-4.6-build": _p("Grok 4.6 Build", 2, 6, 0.50, 0),
        "grok-4.5-build": _p("Grok 4.5 Build", 2, 6, 0.30, 0),
        "grok-4.7": _p("Grok 4.7", 2, 6, 0.50, 0),
        "grok-4.6": _p("Grok 4.6", 2, 6, 0.50, 0),
        "grok-4.5": _p("Grok 4.5", 2, 6, 0.30, 0),
        "grok-4": _p("Grok 4", 3, 15, 0.75, 0),
        "grok-3": _p("Grok 3", 3, 15, 0.75, 0),
        "grok-3-mini": _p("Grok 3 Mini", 0.25, 0.50, 0.075, 0),

        # Google
        "gemini-3.8-flash": _p("Gemini 3.8 Flash", 0.75, 3.75, 0.075, 0),
        "gemini-3.5-flash": _p("Gemini 3.5 Flash", 1.50, 9.00, 0.15, 0),

        # ByteDance Doubao
        "doubao-seed-2-1-pro": _p("Doubao Seed 2.1 Pro", 0.84, 4.20, 0.17, 0),
        "doubao-seed-2-1-turbo": _p("Doubao Seed 2.1 Turbo", 0.42, 2.10, 0.08, 0),
        "doubao-seed-2-0-pro": _p("Doubao Seed 2.0 Pro", 0.47, 2.37, 0.09, 0),
        "doubao-seed-code": _p("Doubao Seed Code", 0.17, 1.11, 0.02, 0),

        # OpenCode Zen free
        "space-bunny": _p("Space Bunny", 0, 0, 0, 0),
        "big-pickle": _p("Big Pickle", 0, 0, 0, 0),
    }

    @classmethod
    def display_name(cls, model: Optional[str]) -> str:
        if not model:
            return "未知模型"
        p = cls.price(model)
        return p.display_name if p else model

    @classmethod
    def price(cls, model: Optional[str]) -> Optional[ModelPrice]:
        key = cls.canonical_key(model)
        return cls.prices.get(key) if key else None

    @classmethod
    def canonical_key(cls, model: Optional[str]) -> Optional[str]:
        if not model:
            return None
        cands = cls.candidates(model)
        for c in cands:
            if c in cls.prices:
                return c
        best_key = None
        for c in cands:
            for k in cls.prices.keys():
                if cls._token_prefix(k, c):
                    if best_key is None or len(k) > len(best_key):
                        best_key = k
        return best_key or (cands[0] if cands else None)

    @classmethod
    def estimate(cls, totals: TokenTotals, model: Optional[str]) -> CostEstimate:
        p = cls.price(model)
        if not p:
            return CostEstimate(usd=0.0, priced_tokens=0, unpriced_tokens=totals.total)
        million = 1_000_000.0
        write_1h = max(0, min(totals.cache_write_1h, totals.cache_write))
        write_5m = max(0, totals.cache_write - write_1h)
        cost = (
            float(totals.uncached_input) * p.input / million
            + float(totals.output) * p.output / million
            + float(totals.cache_read) * p.cache_read / million
            + float(write_5m) * p.cache_creation / million
            + float(write_1h) * p.cache_creation * 1.6 / million
        )
        return CostEstimate(usd=cost, priced_tokens=totals.total, unpriced_tokens=0)

    @classmethod
    def candidates(cls, model: str) -> List[str]:
        cleaned = model.strip().lower()
        if "/" in cleaned:
            cleaned = cleaned.split("/")[-1]
        if ":" in cleaned:
            cleaned = cleaned.split(":")[0]
        cleaned = cleaned.replace("@", "-").replace("(1m)", "").replace("[1m]", "").strip("-_ ")

        queue = [cleaned]
        out: List[str] = []
        seen = set()
        while queue:
            c = queue.pop()
            if not c or c in seen:
                continue
            seen.add(c)
            out.append(c)

            idx = c.rfind("claude-")
            if idx > 0:
                queue.append(c[idx:])
            for marker in ["openai.", "anthropic.", "google.", "moonshot.", "moonshotai.",
                           "bedrock.", "global.", "stepfun."]:
                if c.startswith(marker):
                    queue.append(c[len(marker):])
            sv = cls._strip_version(c)
            if sv: queue.append(sv)
            sd = cls._strip_date(c)
            if sd: queue.append(sd)
            se = cls._strip_effort(c)
            if se: queue.append(se)
            sl = cls._strip_latest(c)
            if sl: queue.append(sl)
            if c.startswith("claude-") and "." in c:
                queue.append(c.replace(".", "-"))
        return out

    @staticmethod
    def _strip_version(s: str) -> Optional[str]:
        idx = s.rfind("-v")
        if idx != -1:
            suffix = s[idx+2:]
            if suffix.isdigit():
                base = s[:idx]
                return base if base else None
        return None

    @staticmethod
    def _strip_date(s: str) -> Optional[str]:
        # YYYY-MM-DD
        if len(s) > 11 and s[-11] == "-" and s[-10:-6].isdigit() and s[-6] == "-" and s[-5:-3].isdigit() and s[-3] == "-" and s[-2:].isdigit():
            return s[:-11]
        idx = s.rfind("-")
        if idx != -1:
            suffix = s[idx+1:]
            if suffix.isdigit():
                if len(suffix) == 8:
                    return s[:idx]
                if len(suffix) == 6:
                    mo = int(suffix[2:4])
                    day = int(suffix[4:6])
                    if 1 <= mo <= 12 and 1 <= day <= 31:
                        return s[:idx]
        return None

    @staticmethod
    def _strip_effort(s: str) -> Optional[str]:
        for suf in ["-minimal", "-low", "-medium", "-high", "-xhigh"]:
            if s.endswith(suf):
                base = s[:-len(suf)]
                if base: return base
        return None

    @staticmethod
    def _strip_latest(s: str) -> Optional[str]:
        for suf in ["-latest", "-preview"]:
            if s.endswith(suf):
                base = s[:-len(suf)]
                if base: return base
        return None

    @staticmethod
    def _token_prefix(key: str, cand: str) -> bool:
        if len(cand) > len(key) and cand.startswith(key):
            next_char = cand[len(key)]
            return next_char in ("-", ".")
        return False
