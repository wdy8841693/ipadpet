#!/usr/bin/env python3
"""WhalePet bridge server entry point.

用法：
    python run.py            # 从环境变量读取配置并启动
    python run.py --token    # 只生成一个随机访问令牌
"""
from __future__ import annotations

import sys

from whalepet_bridge.config import generate_token
from whalepet_bridge.server import main

if __name__ == "__main__":
    if "--token" in sys.argv[1:]:
        print(generate_token())
        raise SystemExit(0)
    main()
