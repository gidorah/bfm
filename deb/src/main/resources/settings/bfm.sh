#!/bin/bash

SERVICE_NAME=bfm
PATH_TO_JAR=/etc/bfm/bfmwatcher/bfm-app.jar
PATH_TO_APP_PROP=/etc/bfm/bfmwatcher/application.properties
PATH_TO_LOG_ROTATE=/etc/logrotate.conf
PATH_TO_LOGD=/etc/logrotate.d/bfmlog
PID_FILE=/var/run/bfm.pid
LOG_FILE=/etc/bfm/bfmwatcher/bfm.log

is_running() {

    [ -f "$PID_FILE" ] || return 1

    PID=$(cat "$PID_FILE")

    [ -d "/proc/$PID" ] || {
        rm -f "$PID_FILE"
        return 1
    }

    CMD=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null)

    echo "$CMD" | grep -q "$PATH_TO_JAR"

    if [ $? -eq 0 ]; then
        return 0
    fi

    echo "Stale PID file found: $PID"
    rm -f "$PID_FILE"
    return 1
}

start() {
    echo "Starting $SERVICE_NAME ..."

    if is_running; then
        echo "$SERVICE_NAME is already running on PID $(cat "$PID_FILE")"
        return 0
    fi

    nohup java \
        -Dspring.config.location="$PATH_TO_APP_PROP" \
        -jar "$PATH_TO_JAR" \
        >> "$LOG_FILE" 2>&1 &

    PID=$!
    echo "$PID" > "$PID_FILE"

    sleep 2

    if kill -0 "$PID" 2>/dev/null; then
        logrotate -s /etc/bfm/bfmwatcher/logrotate.state $PATH_TO_LOG_ROTATE
        logrotate -s /etc/bfm/bfmwatcher/logrotate.state -f $PATH_TO_LOGD

        echo "$SERVICE_NAME started on PID $PID"
        return 0
    else
        rm -f "$PID_FILE"
        echo "$SERVICE_NAME could not start"
        return 1
    fi
}

stop() {
    if ! is_running; then
        echo "$SERVICE_NAME is not running"
        return 0
    fi

    PID=$(cat "$PID_FILE")

    echo "Stopping $SERVICE_NAME (PID=$PID)..."

    kill "$PID"

    for i in {1..30}
    do
        if ! kill -0 "$PID" 2>/dev/null; then
            rm -f "$PID_FILE"
            echo "$SERVICE_NAME stopped"
            return 0
        fi
        sleep 1
    done

    echo "Force killing PID $PID"
    kill -9 "$PID" 2>/dev/null

    rm -f "$PID_FILE"
    echo "$SERVICE_NAME stopped"
}

restart() {
    stop
    sleep 2
    start
}

status() {
    if is_running; then
        echo "$SERVICE_NAME is running on PID $(cat "$PID_FILE")"
        return 0
    else
        echo "$SERVICE_NAME is not running"
        return 1
    fi
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    status)
        status
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
