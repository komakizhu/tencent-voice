#!/bin/zsh

set -euo pipefail

permission="${1:-all}"
base_url="x-apple.systempreferences:com.apple.preference.security"

case "${permission}" in
  all)
    settings_url="${base_url}"
    ;;
  microphone)
    settings_url="${base_url}?Privacy_Microphone"
    ;;
  accessibility|post-event)
    settings_url="${base_url}?Privacy_Accessibility"
    ;;
  input-monitoring)
    settings_url="${base_url}?Privacy_ListenEvent"
    ;;
  -h|--help)
    print "用法：$0 [all|microphone|accessibility|post-event|input-monitoring]"
    exit 0
    ;;
  *)
    print -u2 "未知权限类型：${permission}"
    print -u2 "可选：all、microphone、accessibility、post-event、input-monitoring"
    exit 64
    ;;
esac

if ! /usr/bin/open -g "${settings_url}"; then
  print -u2 "无法打开 macOS 隐私与安全性设置"
  exit 69
fi

print "已打开 macOS 隐私与安全性设置（${permission}）。请手动开启 Rime Voice 对应项目。"
