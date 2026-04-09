#!/bin/sh
set -eu

WP_CLI_BIN="wp"
WP_PATH="."
TARGET_DEFAULT_THEME=""
DEFAULT_THEME_CANDIDATES="twentytwentysix twentytwentyfive twentytwentyfour twentytwentythree twentytwentytwo twentytwentyone twentytwenty"
WP_URL=""
WP_CLI_ALLOW_ROOT="0"
CURRENT_THEME=""
RESOLVED_DEFAULT_THEME=""
THEME=""

while getopts "b:p:t:c:u:r" OPTION; do
    case "$OPTION" in
        b) WP_CLI_BIN=$OPTARG ;;
        p) WP_PATH=$OPTARG ;;
        t) TARGET_DEFAULT_THEME=$OPTARG ;;
        c) DEFAULT_THEME_CANDIDATES=$OPTARG ;;
        u) WP_URL=$OPTARG ;;
        r) WP_CLI_ALLOW_ROOT="1" ;;
        *) exit 2 ;;
    esac
done

if ! command -v "$WP_CLI_BIN" >/dev/null 2>&1; then
    printf '%s\n' "$WP_CLI_BIN"
    exit 1
fi

if [ ! -f "$WP_PATH/wp-config.php" ]; then
    printf '%s\n' "$WP_PATH"
    exit 1
fi

wp_cmd() {
    if [ "$WP_CLI_ALLOW_ROOT" = "1" ]; then
        if [ -n "$WP_URL" ]; then
            "$WP_CLI_BIN" --path="$WP_PATH" --allow-root --url="$WP_URL" "$@"
        else
            "$WP_CLI_BIN" --path="$WP_PATH" --allow-root "$@"
        fi
    else
        if [ -n "$WP_URL" ]; then
            "$WP_CLI_BIN" --path="$WP_PATH" --url="$WP_URL" "$@"
        else
            "$WP_CLI_BIN" --path="$WP_PATH" "$@"
        fi
    fi
}

CURRENT_THEME=$(wp_cmd theme list --status=active --field=name | awk 'NR==1 { print; exit }')

if [ -n "$TARGET_DEFAULT_THEME" ]; then
    RESOLVED_DEFAULT_THEME=$TARGET_DEFAULT_THEME
else
    for THEME in $DEFAULT_THEME_CANDIDATES; do
        if wp_cmd theme is-installed "$THEME" >/dev/null 2>&1; then
            RESOLVED_DEFAULT_THEME=$THEME
            break
        fi
    done
fi

if [ -z "$RESOLVED_DEFAULT_THEME" ]; then
    printf '%s\n' "$CURRENT_THEME"
    exit 1
fi

if ! wp_cmd theme is-installed "$RESOLVED_DEFAULT_THEME" >/dev/null 2>&1; then
    printf '%s\n' "$RESOLVED_DEFAULT_THEME"
    exit 1
fi

if [ "$CURRENT_THEME" != "$RESOLVED_DEFAULT_THEME" ]; then
    wp_cmd theme activate "$RESOLVED_DEFAULT_THEME" >/dev/null
fi

wp_cmd theme list --status=active --field=name | awk 'NR==1 { print; exit }'
