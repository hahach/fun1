#!/usr/bin/env python3
"""打印「最新 iOS runtime 里第一台 iPhone」的模拟器 UDID。

部署目标跟着最新 iOS 走，老 runtime 跑不了；因此按 runtime 版本从新到旧挑，
而不是按 xcrun 输出的字典顺序（那是字符串序，iOS-18 会排在 iOS-26 前面）。
"""

import json
import subprocess
import sys


def runtime_version(runtime: str) -> tuple[int, ...]:
    part = runtime.split("iOS-")[-1].replace("-", ".") if "iOS-" in runtime else "0"
    return tuple(int(piece) for piece in part.split(".") if piece.isdigit())


devices = json.loads(
    subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
)["devices"]

for runtime in sorted(devices, key=runtime_version, reverse=True):
    for device in devices[runtime]:
        if "iPhone" in device["name"]:
            print(device["udid"])
            sys.exit(0)

sys.exit("no iPhone simulator available")
