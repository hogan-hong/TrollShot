#!/bin/sh
# TrollShot daemon 启动包装脚本
# launchd 直接启动 trollshotd 二进制会被 iOS 系统杀掉(SIGKILL)，
# 通过 /bin/sh 包装脚本 fork 出来则不会，这是 iOS 越狱环境的已知行为。
# 保持脚本存活，daemon 崩溃时自动重启。
# 检查 /tmp/trollshotd.stop 标志，存在则不启动 daemon（用户通过 app 停止）
while true; do
    if [ ! -f /tmp/trollshotd.stop ]; then
        /usr/bin/trollshotd --port 6688
    fi
    sleep 1
done
