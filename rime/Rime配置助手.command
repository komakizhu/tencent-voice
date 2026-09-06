#!/bin/bash

# 2. 检测是否就在 RIME_DIR 文件夹中
TARGET_DIR="$HOME/Library/Rime"
if [ "$(pwd)" != "$TARGET_DIR" ]; then
    cd "$TARGET_DIR"
fi

# 运行程序
./rime-mate-config/rime-mate

echo ""
