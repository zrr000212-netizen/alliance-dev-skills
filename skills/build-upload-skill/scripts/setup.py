#!/usr/bin/env python3
"""OBS Upload Skill - 交互式配置脚本
运行此脚本设置 OBS 上传参数，配置保存到同目录下的 config.json
"""
import json
import os
import sys

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'config.json')

PARAMS = [
    ("AK",            "OBS Access Key ID",                                  None),
    ("SK",            "OBS Secret Access Key",                               None),
    ("SERVER",        "OBS Endpoint",                                       "obs.cn-north-4.myhuaweicloud.com"),
    ("BUCKET",        "OBS Bucket Name",                                    "obs-hd-dev-static"),
    ("PROJECT_PATH",  "项目源码路径(填写则先打包再上传,留空则直接上传)",        None),
    ("LOCAL_DIR",     "本地上传目录(填了PROJECT_PATH可留空,自动推导为dist)",  None),
    ("OBS_PREFIX",    "OBS目标路径前缀",                                     None),
]

def load_existing():
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, 'r') as f:
            return json.load(f)
    return {}

def save_config(cfg):
    with open(CONFIG_PATH, 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f"\n配置已保存到: {CONFIG_PATH}")

def main():
    print("=" * 50)
    print("  OBS Upload Skill - 参数配置")
    print("=" * 50)

    existing = load_existing()
    if existing:
        print(f"\n检测到已有配置 ({CONFIG_PATH}):")
        for k, v in existing.items():
            # 对敏感信息做掩码
            if k in ("AK", "SK") and v:
                display = v[:4] + "****" + v[-4:] if len(v) > 8 else "****"
            else:
                display = v
            print(f"  {k} = {display}")
        choice = input("\n是否重新配置? (y/N): ").strip().lower()
        if choice != 'y':
            print("保持现有配置，退出。")
            return

    config = {}
    print()
    for key, desc, default in PARAMS:
        prompt = f"请输入 {desc}"
        if default:
            prompt += f" (默认: {default})"
        prompt += ": "

        # PROJECT_PATH 和 LOCAL_DIR 允许留空
        allow_empty = key in ("PROJECT_PATH", "LOCAL_DIR")

        while True:
            val = input(prompt).strip()
            if not val and default:
                val = default
            if not val and not allow_empty:
                print(f"  错误: {desc} 不能为空，请重新输入。")
                continue
            # 对敏感参数确认
            if key in ("AK", "SK") and val:
                mask = val[:4] + "****" + val[-4:] if len(val) > 8 else "****"
                confirm = input(f"  确认 {key} = {mask} ? (Y/n): ").strip().lower()
                if confirm == 'n':
                    continue
            config[key] = val
            break

    # 校验: PROJECT_PATH 和 LOCAL_DIR 至少填一个
    if not config.get("PROJECT_PATH") and not config.get("LOCAL_DIR"):
        print("\n错误: PROJECT_PATH 和 LOCAL_DIR 至少需要填写一个!")
        print("  - 填 PROJECT_PATH: 先打包再上传 (LOCAL_DIR 自动推导)")
        print("  - 填 LOCAL_DIR: 直接上传指定目录")
        sys.exit(1)

    save_config(config)
    print("\n配置完成! 现在可以使用 obs-upload skill 上传文件了。")

if __name__ == '__main__':
    main()
