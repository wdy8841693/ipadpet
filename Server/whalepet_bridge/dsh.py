"""DeepSeek Harness wrapper via the official Python SDK.

Design notes:
- DeepSeekHarness.run() is blocking -> always call from asyncio.to_thread.
- One harness instance per process is enough for a single-user home pet;
  access is serialized behind a lock (the SDK runtime is a subprocess with
  its own JSON-RPC session handling, but we keep calls one-at-a-time to keep
  the iPad experience predictable).
- The first run of a fresh session sends ``/permission read-only`` so the
  default policy is read-only; the operator can raise it deliberately via
  WHALEPET_DSH_PERMISSION.
"""
from __future__ import annotations

import logging
import threading
from typing import Optional

from .config import BridgeConfig

logger = logging.getLogger("whalepet.dsh")


class DSHError(RuntimeError):
    pass


class DSHRunner:
    def __init__(self, config: BridgeConfig) -> None:
        self._config = config
        self._lock = threading.Lock()
        self._harness = None
        self._init_error: Optional[str] = None

    # -- lifecycle -------------------------------------------------------

    def close(self) -> None:
        with self._lock:
            if self._harness is not None:
                try:
                    self._harness.close()
                except Exception as exc:  # pragma: no cover
                    logger.warning("关闭 DSH runtime 出错: %s", exc)
                finally:
                    self._harness = None

    def _ensure(self):
        """Caller must hold self._lock."""
        if self._harness is not None:
            return self._harness
        if self._init_error is not None:
            raise DSHError(self._init_error)
        try:
            from deepseek_harness import DeepSeekHarness  # type: ignore
        except Exception as exc:
            self._init_error = f"deepseek-harness-sdk 未安装: {exc}"
            raise DSHError(self._init_error) from exc
        try:
            # sdk-minimal pins a full-access shell; use the standard `sdk`
            # profile so the workspace-write/read-only permission presets are
            # available, and default the session to read-only on first use.
            self._harness = DeepSeekHarness(
                dsh_home=self._config.dsh_home,
                cwd=self._config.workspace,
                provider=self._config.provider,
                model=self._config.model,
                profile=self._config.profile,
            )
            logger.info(
                "DSH runtime ready (profile=%s model=%s)",
                self._config.profile,
                self._config.model,
            )
        except Exception as exc:
            self._init_error = f"启动 DSH runtime 失败: {exc}"
            self._harness = None
            raise DSHError(self._init_error) from exc
        return self._harness

    # -- prompting ---------------------------------------------------------

    def ask(self, session_id: str, prompt: str) -> str:
        """Run one prompt through DSH. Blocking; call from a worker thread."""
        with self._lock:
            harness = self._ensure()
            try:
                result = harness.run(prompt, session_id=session_id)
            except Exception as exc:
                # 运行时可能已处于坏状态；先关闭旧 runtime（避免子进程泄漏），
                # 下次调用重新初始化。
                broken, self._harness = self._harness, None
                if broken is not None:
                    try:
                        broken.close()
                    except Exception:  # pragma: no cover
                        pass
                raise DSHError(f"DSH 执行失败: {exc}") from exc
        reply = (getattr(result, "final_response", "") or "").strip()
        finish = getattr(result, "finish_reason", None)
        if finish and str(finish) == "error" and not reply:
            raise DSHError("DSH 返回错误（finish_reason=error）")
        if not reply:
            raise DSHError("DSH 没有返回文本回复")
        return reply

    def apply_permission(self, session_id: str) -> None:
        """Send the configured /permission preset once for a new session."""
        preset = self._config.dsh_permission_preset
        if not preset:
            return
        with self._lock:
            harness = self._ensure()
            try:
                harness.run(f"/permission {preset}", session_id=session_id)
            except Exception as exc:
                logger.warning("设置权限预设 %s 失败: %s", preset, exc)
