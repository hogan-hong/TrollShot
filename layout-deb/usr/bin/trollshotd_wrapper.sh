#!/bin/sh
# TrollShot daemon 启动包装脚本
# launchd 直接启动 trollshotd 二进制会被 iOS 系统杀掉(SIGKILL)，
# 通过 /bin/sh 包装脚本 fork 出来则不会，这是 iOS 越狱环境的已知行为。
# 保持脚本存活，daemon 崩溃时自动重启。
# 检查 /var/mobile/trollshot/stop.flag 标志，存在则不启动 daemon（用户通过 app 停止）
# 同时监视 api_port 文件：App 修改端口后自动把 daemon 重启到新端口（约 1~2 秒生效），
# App 无需手动停止/启动服务。

DEBUG_FLAG="/var/mobile/trollshot/debug_mode"
LOG_FILE="/var/mobile/trollshot/trollshotd.log"
WRAPPER_LOG="/var/mobile/trollshot/wrapper.log"
STOP_FLAG="/var/mobile/trollshot/stop.flag"
PORT_FILE="/var/mobile/trollshot/api_port"

# 开机/启动时清除停止标志--stop.flag 仅作为运行时停止信号，不跨重启持久化。
# 重启后 wrapper 总是自动启动 daemon，用户无需手动开启服务。
rm -f "$STOP_FLAG"

# 简单的启动日志（不受调试模式控制，方便排查开机自启问题）
echo "[$(date '+%Y-%m-%d %H:%M:%S')] wrapper 启动，清除 stop.flag" >> "$WRAPPER_LOG" 2>/dev/null

# 检查调试模式是否开启
is_debug() {
    [ -f "$DEBUG_FLAG" ] && [ "$(cat "$DEBUG_FLAG" 2>/dev/null)" = "1" ]
}

# 读取 API 端口（TrollShot App 主界面可改，非法/缺失回退 6688）
read_api_port() {
    local p
    p=$(cat "$PORT_FILE" 2>/dev/null)
    case "$p" in
        ''|*[!0-9]*) p=6688 ;;
    esac
    API_PORT=$p
}

while true; do
    if [ ! -f "$STOP_FLAG" ]; then
        read_api_port
        RUN_PORT=$API_PORT
        # 后台方式启动 daemon，wrapper 保持监视（fork 路径与前台一致，规避 iOS SIGKILL）
        if is_debug; then
            # 调试模式：重定向日志到文件，启动前清空旧日志（避免无限增长）
            > "$LOG_FILE"
            /usr/bin/trollshotd --port "$RUN_PORT" >> "$LOG_FILE" 2>&1 &
        else
            # 非调试模式：丢弃日志输出
            /usr/bin/trollshotd --port "$RUN_PORT" > /dev/null 2>&1 &
        fi
        DPID=$!
        # 监视循环：daemon 退出 / 用户停止 / 端口文件变化，任一发生即跳出重启
        while kill -0 "$DPID" 2>/dev/null; do
            if [ -f "$STOP_FLAG" ]; then
                kill "$DPID" 2>/dev/null
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] stop.flag 出现，停止 daemon" >> "$WRAPPER_LOG" 2>/dev/null
                break
            fi
            read_api_port
            if [ "$API_PORT" != "$RUN_PORT" ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检测到端口变化 $RUN_PORT -> $API_PORT，重启 daemon" >> "$WRAPPER_LOG" 2>/dev/null
                kill "$DPID" 2>/dev/null
                break
            fi
            sleep 1
        done
        wait "$DPID" 2>/dev/null
        if [ ! -f "$STOP_FLAG" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] trollshotd 退出，1秒后重启" >> "$WRAPPER_LOG" 2>/dev/null
        fi
    else
        # stop.flag 存在，等待用户通过 app 重新启动（app 会删除 stop.flag）
        :
    fi
    sleep 1
done
