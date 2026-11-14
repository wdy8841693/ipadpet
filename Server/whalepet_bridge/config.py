"""Environment-driven configuration for the WhalePet bridge server."""
from __future__ import annotations

import os
import secrets
from dataclasses import dataclass, field

from .textnorm import DEFAULT_WAKE_ALIASES, VoiceSessionConfig


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, "").strip() or default)
    except ValueError:
        return default


@dataclass
class BridgeConfig:
    host: str = "0.0.0.0"
    port: int = 8787
    token: str = ""
    tls_cert: str = ""
    tls_key: str = ""

    # DSH
    dsh_home: str = ""
    workspace: str = ""
    profile: str = "sdk"
    provider: str = "deepseek-official"
    model: str = "deepseek-v4-flash"
    dsh_request_timeout_s: float = 600.0
    # 首轮发送的权限指令（安全默认：只读）。
    dsh_permission_preset: str = "read-only"

    # ASR
    asr_model: str = "small"
    asr_device: str = "cpu"
    asr_compute_type: str = "int8"

    wake_phrase: str = "小鲸小鲸"
    wake_aliases: tuple[str, ...] = DEFAULT_WAKE_ALIASES

    voice: VoiceSessionConfig = field(default_factory=VoiceSessionConfig)

    @classmethod
    def from_env(cls) -> "BridgeConfig":
        aliases = list(DEFAULT_WAKE_ALIASES)
        extra = os.environ.get("WHALEPET_WAKE_ALIASES", "")
        if extra.strip():
            aliases += [a.strip() for a in extra.split(",") if a.strip()]
        return cls(
            host=os.environ.get("WHALEPET_HOST", "0.0.0.0"),
            port=_env_int("WHALEPET_PORT", 8787),
            token=os.environ.get("WHALEPET_TOKEN", "").strip(),
            tls_cert=os.environ.get("WHALEPET_TLS_CERT", "").strip(),
            tls_key=os.environ.get("WHALEPET_TLS_KEY", "").strip(),
            dsh_home=os.environ.get("DSH_HOME", "").strip(),
            workspace=os.environ.get("WHALEPET_WORKSPACE", "").strip(),
            profile=os.environ.get("DSH_PROFILE", "sdk"),
            provider=os.environ.get("DSH_PROVIDER", "deepseek-official"),
            model=os.environ.get("DSH_MODEL", "deepseek-v4-flash"),
            dsh_request_timeout_s=float(
                os.environ.get("WHALEPET_DSH_TIMEOUT_S", "600") or 600
            ),
            dsh_permission_preset=os.environ.get(
                "WHALEPET_DSH_PERMISSION", "read-only"
            ),
            asr_model=os.environ.get("WHALEPET_ASR_MODEL", "small"),
            asr_device=os.environ.get("WHALEPET_ASR_DEVICE", "cpu"),
            asr_compute_type=os.environ.get("WHALEPET_ASR_COMPUTE", "int8"),
            wake_phrase=os.environ.get("WHALEPET_WAKE_PHRASE", "小鲸小鲸"),
            wake_aliases=tuple(dict.fromkeys(aliases)),
        )

    def validate(self) -> list[str]:
        problems: list[str] = []
        if not self.token:
            problems.append(
                "WHALEPET_TOKEN 未设置：这是客户端访问令牌，必须显式配置（"
                "可用 `python -c \"import secrets; print(secrets.token_urlsafe(24))\"` 生成）。"
            )
        if self.token and len(self.token) < 16:
            problems.append("WHALEPET_TOKEN 太短，至少 16 个字符。")
        if (self.tls_cert and not self.tls_key) or (self.tls_key and not self.tls_cert):
            problems.append("WHALEPET_TLS_CERT 与 WHALEPET_TLS_KEY 必须同时配置。")
        if not self.dsh_home:
            problems.append("DSH_HOME 未设置：必须为 DSH 指定独立的 Harness home。")
        if not self.workspace:
            problems.append("WHALEPET_WORKSPACE 未设置：必须为 DSH 指定受限工作目录。")
        return problems


def generate_token() -> str:
    return secrets.token_urlsafe(24)
