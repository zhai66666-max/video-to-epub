#!/usr/bin/env python3
"""
修复中文引号问题：把英文 ASCII 直引号 " 按出现顺序奇偶配对替换为中文角引号「」。
- 中文文本里的引号必须用「」(U+300C) / 」」(U+300D)，不要用英文 " (U+0022)，
  否则在 EPUB/多数阅读器里显示混乱（开闭方向不明）。
- 用法: python3 fix_quotes.py <md文件或目录>
"""
import glob
import os
import sys


def fix_file(path: str) -> int:
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    Q = chr(0x22)
    n = content.count(Q)
    if n == 0:
        return 0
    result, toggle = [], False
    for ch in content:
        if ch == Q:
            result.append(chr(0x300C) if not toggle else chr(0x300D))
            toggle = not toggle
        else:
            result.append(ch)
    with open(path, "w", encoding="utf-8") as f:
        f.write("".join(result))
    return n // 2


def main() -> None:
    if len(sys.argv) < 2:
        print("用法: python3 fix_quotes.py <md文件或目录>")
        sys.exit(1)
    target = sys.argv[1]
    files = (
        glob.glob(os.path.join(target, "*.md"))
        if os.path.isdir(target)
        else [target]
    )
    total = 0
    for fp in files:
        pairs = fix_file(fp)
        if pairs:
            print(f"{fp}: {pairs} 对引号已修复")
            total += pairs
    print(f"合计 {total} 对")


if __name__ == "__main__":
    main()
