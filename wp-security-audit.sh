#!/bin/sh
set -eu

SCRIPT_NAME=$(basename "$0")
DATE_FORMAT="%Y%m%d_%H%M%S"
RUN_TIMESTAMP=""
CONFIG_FILE=""
WP_PATH="."
SITE_URL=""
OUTPUT_DIR="./security_audit_reports"
REPORT_PREFIX="wordpress_security_audit"
REPORT_FILE=""
DETAIL_FILE=""
TMP_PARENT_DIR="/tmp"
TMP_PREFIX="wp_security_audit"
TMP_DIR=""
KEEP_TMP="0"
EXIT_CODE="0"
MAX_FINDINGS_PER_SECTION="200"

CMD_DATE="date"
CMD_MKDIR="mkdir"
CMD_MKTEMP="mktemp"
CMD_RM="rm"
CMD_FIND="find"
CMD_GREP="grep"
CMD_SORT="sort"
CMD_AWK="awk"
CMD_TR="tr"
CMD_WC="wc"
CMD_HEAD="head"
CMD_TAIL="tail"
CMD_CKSUM="cksum"
CMD_CAT="cat"
CMD_CURL="curl"
CMD_WP="wp"
CMD_PHP="php"
CMD_SED="sed"
CMD_WPSCAN="wpscan"

SCAN_EXTENSIONS="php phtml php3 php4 php5 php7 phar inc js"
MALICIOUS_PATTERN_REGEX='(eval[[:space:]]*\(|assert[[:space:]]*\(|shell_exec[[:space:]]*\(|system[[:space:]]*\(|passthru[[:space:]]*\(|exec[[:space:]]*\(|popen[[:space:]]*\(|proc_open[[:space:]]*\(|base64_decode[[:space:]]*\(|gzinflate[[:space:]]*\(|gzuncompress[[:space:]]*\(|str_rot13[[:space:]]*\(|preg_replace[[:space:]]*\(.*\/e|create_function[[:space:]]*\(|include[[:space:]]*\(\$_(GET|POST|REQUEST|COOKIE)|require[[:space:]]*\(\$_(GET|POST|REQUEST|COOKIE)|move_uploaded_file[[:space:]]*\(|file_put_contents[[:space:]]*\()'
OBFUSCATION_PATTERN_REGEX='([A-Za-z0-9+\/]{200,}={0,2}|\\x[0-9A-Fa-f]{2}|chr[[:space:]]*\([[:space:]]*[0-9]{2,}[[:space:]]*\)|fromCharCode[[:space:]]*\(|rawurldecode[[:space:]]*\()'

HTACCESS_FILENAME=".htaccess"
HTACCESS_RECENT_DAYS="30"
HTACCESS_BASELINE_FILE=""
HTACCESS_SUSPICIOUS_PATTERN_REGEX='(php_value[[:space:]]+auto_prepend_file|AddHandler[[:space:]]+application\/x-httpd-php|RewriteRule[[:space:]].*(https?:\/\/|base64|eval\(|gzinflate|shell_exec)|SetHandler[[:space:]]+application\/x-httpd-php|Options[[:space:]]+\+ExecCGI|RewriteCond[[:space:]]+%\{REQUEST_URI\}[[:space:]]+\^\/.+\$[[:space:]]+\[NC\])'

UNWANTED_FILES=$(cat <<'EOF'
wp-config-sample.php
wp-admin/install.php
readme.html
license.txt
xmlrpc.php
wp-content/debug.log
wp-content/uploads/shell.php
wp-content/uploads/.htaccess
EOF
)

ENABLE_WPCLI_CHECKS="1"
ADMIN_ROLE_NAME="administrator"
ADMIN_SUSPECT_USERNAME_REGEX='^(admin|administrator|test|demo|temp|root|support|webmaster|wpadmin)([0-9_]*)$'
LAST_LOGIN_UNKNOWN_VALUE="unknown"
LAST_LOGIN_META_KEYS=$(cat <<'EOF'
last_login
last_login_time
wp_last_login
um_last_login
wfls-last-login
EOF
)

ENABLE_WEAK_PASSWORD_SCAN="1"
WEAK_PASSWORD_LIST=$(cat <<'EOF'
123456
12345678
123456789
1234567890
password
password123
admin
admin123
qwerty
qwerty123
letmein
welcome
wordpress
iloveyou
abc123
111111
000000
changeme
P@ssw0rd
EOF
)

HTTP_TIMEOUT_SECONDS="20"
CURL_FOLLOW_REDIRECTS="1"
CURL_INSECURE_TLS="0"
SECURITY_HEADERS=$(cat <<'EOF'
Strict-Transport-Security
Content-Security-Policy
X-Frame-Options
X-Content-Type-Options
Referrer-Policy
Permissions-Policy
Cross-Origin-Opener-Policy
Cross-Origin-Resource-Policy
Cross-Origin-Embedder-Policy
EOF
)

ENABLE_PLUGIN_THEME_CHECKS="1"
PLUGIN_ABANDON_DAYS="365"
THEME_ABANDON_DAYS="365"
WORDPRESS_PLUGIN_API_URL_TEMPLATE='https://api.wordpress.org/plugins/info/1.2/?action=plugin_information&request[slug]=%s&request[fields][last_updated]=1&request[fields][sections]=0&request[fields][versions]=0&format=json'
WORDPRESS_THEME_API_URL_TEMPLATE='https://api.wordpress.org/themes/info/1.2/?action=theme_information&request[slug]=%s&request[fields][last_updated]=1&request[fields][sections]=0&format=json'

ENABLE_WPSCAN="1"
WPSCAN_API_TOKEN=""
WPSCAN_FORMAT="cli-no-color"
WPSCAN_PLUGINS_DETECTION="mixed"
WPSCAN_ENUMERATE="vp,vt,cb,dbe,u,m"

COUNT_BACKDOOR_HITS="0"
COUNT_OBFUSCATION_HITS="0"
COUNT_SUSPICIOUS_HTACCESS="0"
COUNT_UNWANTED_FILES="0"
COUNT_ADMIN_USERS="0"
COUNT_SUSPECT_ADMIN_USERS="0"
COUNT_WEAK_PASSWORD_USERS="0"
COUNT_MISSING_HEADERS="0"
COUNT_OUTDATED_PLUGINS="0"
COUNT_OUTDATED_THEMES="0"
COUNT_ABANDONED_PLUGINS="0"
COUNT_ABANDONED_THEMES="0"
COUNT_WPSCAN_VULN_LINES="0"

usage() {
    printf '%s\n' "Usage: $SCRIPT_NAME [-c config_file] [-p wp_path] [-u site_url] [-o output_dir]"
}

cleanup() {
    if [ "${KEEP_TMP}" = "0" ] && [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
        "$CMD_RM" -rf "${TMP_DIR}"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

section() {
    printf '\n[%s]\n' "$1" >>"$REPORT_FILE"
}

line() {
    printf '%s\n' "$1" >>"$REPORT_FILE"
}

limit_dump() {
    src_file="$1"
    max_lines="$2"
    n="0"
    if [ -f "$src_file" ]; then
        while IFS= read -r l; do
            line "$l"
            n=$((n + 1))
            if [ "$n" -ge "$max_lines" ]; then
                break
            fi
        done <"$src_file"
    fi
}

days_since() {
    d="$1"
    if ! command_exists "$CMD_PHP"; then
        printf '%s\n' ""
        return 0
    fi
    "$CMD_PHP" -r 'date_default_timezone_set("UTC"); $d = strtotime($argv[1]); if ($d === false) { exit(1);} $days = floor((time() - $d)/86400); if ($days < 0) {$days = 0;} echo $days;' "$d" 2>/dev/null || true
}

load_config_file() {
    cfg="$1"
    if [ -n "$cfg" ]; then
        if [ -f "$cfg" ]; then
            . "$cfg"
        else
            printf '%s\n' "Configuration file not found: $cfg" >&2
            exit 1
        fi
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -c|--config)
                if [ "$#" -lt 2 ]; then
                    usage
                    exit 1
                fi
                CONFIG_FILE="$2"
                load_config_file "$CONFIG_FILE"
                shift 2
                ;;
            -p|--path)
                if [ "$#" -lt 2 ]; then
                    usage
                    exit 1
                fi
                WP_PATH="$2"
                shift 2
                ;;
            -u|--url)
                if [ "$#" -lt 2 ]; then
                    usage
                    exit 1
                fi
                SITE_URL="$2"
                shift 2
                ;;
            -o|--output)
                if [ "$#" -lt 2 ]; then
                    usage
                    exit 1
                fi
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage
                exit 1
                ;;
        esac
    done
}

prepare_environment() {
    RUN_TIMESTAMP=$("$CMD_DATE" +"$DATE_FORMAT")
    "$CMD_MKDIR" -p "$OUTPUT_DIR"
    REPORT_FILE="${OUTPUT_DIR}/${REPORT_PREFIX}_${RUN_TIMESTAMP}.txt"
    DETAIL_FILE="${OUTPUT_DIR}/${REPORT_PREFIX}_${RUN_TIMESTAMP}.detail.log"
    TMP_DIR=$("$CMD_MKTEMP" -d "${TMP_PARENT_DIR%/}/${TMP_PREFIX}.XXXXXX")
    : >"$REPORT_FILE"
    : >"$DETAIL_FILE"
}

scan_backdoors_webshells() {
    section "Scan backdoors et webshells"
    file_list="$TMP_DIR/source_files.txt"
    unique_list="$TMP_DIR/source_files_unique.txt"
    mal_hits="$TMP_DIR/malicious_hits.txt"
    obf_hits="$TMP_DIR/obfuscation_hits.txt"
    : >"$file_list"
    : >"$mal_hits"
    : >"$obf_hits"

    for ext in $SCAN_EXTENSIONS; do
        "$CMD_FIND" "$WP_PATH" -type f -name "*.${ext}" -print >>"$file_list" 2>>"$DETAIL_FILE" || true
    done

    if [ ! -s "$file_list" ]; then
        line "Aucun fichier cible trouve"
        return 0
    fi

    "$CMD_SORT" -u "$file_list" >"$unique_list"

    while IFS= read -r f; do
        "$CMD_GREP" -En "$MALICIOUS_PATTERN_REGEX" "$f" >>"$mal_hits" 2>>"$DETAIL_FILE" || true
        "$CMD_GREP" -En "$OBFUSCATION_PATTERN_REGEX" "$f" >>"$obf_hits" 2>>"$DETAIL_FILE" || true
    done <"$unique_list"

    COUNT_BACKDOOR_HITS=$("$CMD_WC" -l <"$mal_hits" | "$CMD_TR" -d ' ')
    COUNT_OBFUSCATION_HITS=$("$CMD_WC" -l <"$obf_hits" | "$CMD_TR" -d ' ')

    line "Fichiers analyses: $("$CMD_WC" -l <"$unique_list" | "$CMD_TR" -d ' ')"
    line "Signatures malveillantes detectees: $COUNT_BACKDOOR_HITS"
    if [ "$COUNT_BACKDOOR_HITS" -gt 0 ]; then
        limit_dump "$mal_hits" "$MAX_FINDINGS_PER_SECTION"
    fi
    line "Signatures d'obfuscation detectees: $COUNT_OBFUSCATION_HITS"
    if [ "$COUNT_OBFUSCATION_HITS" -gt 0 ]; then
        limit_dump "$obf_hits" "$MAX_FINDINGS_PER_SECTION"
    fi
}

check_htaccess_files() {
    section "Verification des .htaccess"
    ht_list="$TMP_DIR/htaccess_files.txt"
    ht_hits="$TMP_DIR/htaccess_hits.txt"
    : >"$ht_list"
    : >"$ht_hits"

    "$CMD_FIND" "$WP_PATH" -type f -name "$HTACCESS_FILENAME" -print >"$ht_list" 2>>"$DETAIL_FILE" || true

    if [ ! -s "$ht_list" ]; then
        line "Aucun fichier $HTACCESS_FILENAME trouve"
        return 0
    fi

    line "Fichiers .htaccess trouves: $("$CMD_WC" -l <"$ht_list" | "$CMD_TR" -d ' ')"

    while IFS= read -r h; do
        recent="0"
        if "$CMD_FIND" "$h" -prune -type f -mtime "-$HTACCESS_RECENT_DAYS" -print | "$CMD_GREP" -q .; then
            recent="1"
        fi
        suspicious_lines="$TMP_DIR/htaccess_suspicious_lines.txt"
        : >"$suspicious_lines"
        "$CMD_GREP" -En "$HTACCESS_SUSPICIOUS_PATTERN_REGEX" "$h" >"$suspicious_lines" 2>>"$DETAIL_FILE" || true
        suspicious_count=$("$CMD_WC" -l <"$suspicious_lines" | "$CMD_TR" -d ' ')

        baseline_status=""
        if [ -n "$HTACCESS_BASELINE_FILE" ] && [ -f "$HTACCESS_BASELINE_FILE" ]; then
            current_cksum=$("$CMD_CKSUM" "$h" | "$CMD_AWK" '{print $1" "$2}')
            expected_cksum=$("$CMD_AWK" -F '\t' -v p="$h" '$1==p {print $2" "$3}' "$HTACCESS_BASELINE_FILE" | "$CMD_HEAD" -n 1)
            if [ -n "$expected_cksum" ] && [ "$current_cksum" != "$expected_cksum" ]; then
                baseline_status="modified_vs_baseline"
            fi
        fi

        if [ "$recent" = "1" ] || [ "$suspicious_count" -gt 0 ] || [ -n "$baseline_status" ]; then
            COUNT_SUSPICIOUS_HTACCESS=$((COUNT_SUSPICIOUS_HTACCESS + 1))
            printf '%s\n' "$h|recent=${recent}|suspicious_lines=${suspicious_count}|baseline=${baseline_status:-none}" >>"$ht_hits"
            if [ "$suspicious_count" -gt 0 ]; then
                limit_dump "$suspicious_lines" "$MAX_FINDINGS_PER_SECTION"
            fi
        fi
    done <"$ht_list"

    line "Fichiers .htaccess suspects ou recents: $COUNT_SUSPICIOUS_HTACCESS"
    if [ -s "$ht_hits" ]; then
        limit_dump "$ht_hits" "$MAX_FINDINGS_PER_SECTION"
    fi
}

check_unwanted_root_files() {
    section "Presence de fichiers non desires"
    unwanted_hits="$TMP_DIR/unwanted_hits.txt"
    list_file="$TMP_DIR/unwanted_list.txt"
    : >"$unwanted_hits"
    printf '%s\n' "$UNWANTED_FILES" >"$list_file"

    while IFS= read -r rel; do
        if [ -n "$rel" ]; then
            full_path="${WP_PATH%/}/$rel"
            if [ -e "$full_path" ]; then
                COUNT_UNWANTED_FILES=$((COUNT_UNWANTED_FILES + 1))
                printf '%s\n' "$full_path" >>"$unwanted_hits"
            fi
        fi
    done <"$list_file"

    line "Fichiers non desires detectes: $COUNT_UNWANTED_FILES"
    if [ "$COUNT_UNWANTED_FILES" -gt 0 ]; then
        limit_dump "$unwanted_hits" "$MAX_FINDINGS_PER_SECTION"
    fi
}

check_admin_users() {
    section "Verification des utilisateurs administrateurs"

    if [ "$ENABLE_WPCLI_CHECKS" != "1" ]; then
        line "Verification admin desactivee"
        return 0
    fi

    if ! command_exists "$CMD_WP"; then
        line "WP-CLI indisponible"
        return 0
    fi

    admins_csv_file="$TMP_DIR/admins.csv"
    admins_suspect_file="$TMP_DIR/admins_suspect.csv"
    keys_file="$TMP_DIR/last_login_keys.txt"
    : >"$admins_csv_file"
    : >"$admins_suspect_file"
    printf '%s\n' "$LAST_LOGIN_META_KEYS" >"$keys_file"

    "$CMD_WP" --path="$WP_PATH" user list --role="$ADMIN_ROLE_NAME" --fields=ID,user_login,user_email,user_registered --format=csv >"$admins_csv_file" 2>>"$DETAIL_FILE" || true

    if [ ! -s "$admins_csv_file" ]; then
        line "Impossible de recuperer la liste des administrateurs"
        return 0
    fi

    COUNT_ADMIN_USERS=$("$CMD_AWK" -F ',' 'NR>1 && NF>0 {c++} END{print c+0}' "$admins_csv_file")
    line "Nombre d'administrateurs: $COUNT_ADMIN_USERS"

    "$CMD_AWK" -F ',' -v r="$ADMIN_SUSPECT_USERNAME_REGEX" 'NR>1 {u=tolower($2); if (u ~ r) print $0}' "$admins_csv_file" >"$admins_suspect_file" || true
    COUNT_SUSPECT_ADMIN_USERS=$("$CMD_WC" -l <"$admins_suspect_file" | "$CMD_TR" -d ' ')
    line "Usernames admins suspects: $COUNT_SUSPECT_ADMIN_USERS"
    if [ "$COUNT_SUSPECT_ADMIN_USERS" -gt 0 ]; then
        limit_dump "$admins_suspect_file" "$MAX_FINDINGS_PER_SECTION"
    fi

    db_prefix=$("$CMD_WP" --path="$WP_PATH" db prefix 2>>"$DETAIL_FILE" || true)
    if [ -z "$db_prefix" ]; then
        line "Impossible de determiner le prefixe de base"
        return 0
    fi

    line "Derniers logins disponibles"
    "$CMD_AWK" -F ',' 'NR>1 {print $1"|"$2}' "$admins_csv_file" >"$TMP_DIR/admin_pairs.txt"
    while IFS='|' read -r uid login; do
        found_value=""
        while IFS= read -r k; do
            if [ -n "$k" ]; then
                q="SELECT meta_value FROM ${db_prefix}usermeta WHERE user_id=${uid} AND meta_key='${k}' ORDER BY umeta_id DESC LIMIT 1;"
                v=$("$CMD_WP" --path="$WP_PATH" db query "$q" --skip-column-names 2>>"$DETAIL_FILE" || true)
                if [ -n "$v" ]; then
                    found_value="$k=$v"
                    break
                fi
            fi
        done <"$keys_file"
        if [ -z "$found_value" ]; then
            found_value="$LAST_LOGIN_UNKNOWN_VALUE"
        fi
        line "$login|$found_value"
    done <"$TMP_DIR/admin_pairs.txt"
}

check_weak_passwords() {
    section "Scan des mots de passe faibles"

    if [ "$ENABLE_WEAK_PASSWORD_SCAN" != "1" ]; then
        line "Scan mots de passe desactive"
        return 0
    fi

    if ! command_exists "$CMD_WP" || ! command_exists "$CMD_PHP"; then
        line "WP-CLI ou PHP indisponible"
        return 0
    fi

    db_prefix=$("$CMD_WP" --path="$WP_PATH" db prefix 2>>"$DETAIL_FILE" || true)
    if [ -z "$db_prefix" ]; then
        line "Impossible de determiner le prefixe de base"
        return 0
    fi

    users_hash_file="$TMP_DIR/users_hashes.tsv"
    weak_pw_file="$TMP_DIR/weak_passwords.txt"
    weak_hits_file="$TMP_DIR/weak_password_hits.tsv"
    checker_php="$TMP_DIR/weak_checker.php"

    : >"$users_hash_file"
    : >"$weak_pw_file"
    : >"$weak_hits_file"

    printf '%s\n' "$WEAK_PASSWORD_LIST" >"$weak_pw_file"
    "$CMD_WP" --path="$WP_PATH" db query "SELECT ID,user_login,user_pass FROM ${db_prefix}users;" --skip-column-names >"$users_hash_file" 2>>"$DETAIL_FILE" || true

    if [ ! -s "$users_hash_file" ]; then
        line "Impossible de recuperer les hashes utilisateurs"
        return 0
    fi

    "$CMD_CAT" >"$checker_php" <<'PHP'
<?php
$wpLoad = $argv[1];
$pwFile = $argv[2];
$userFile = $argv[3];
if (!is_file($wpLoad)) {
    exit(2);
}
require $wpLoad;
$passwords = @file($pwFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
if (!is_array($passwords)) {
    exit(3);
}
$fh = @fopen($userFile, 'r');
if (!$fh) {
    exit(4);
}
while (($line = fgets($fh)) !== false) {
    $line = rtrim($line, "\r\n");
    if ($line === '') {
        continue;
    }
    $parts = explode("\t", $line);
    if (count($parts) < 3) {
        continue;
    }
    $uid = (int)$parts[0];
    $login = $parts[1];
    $hash = $parts[2];
    foreach ($passwords as $pw) {
        if (wp_check_password($pw, $hash, $uid)) {
            echo $uid, "\t", $login, "\t", $pw, "\n";
            break;
        }
    }
}
fclose($fh);
PHP

    wp_load_path="${WP_PATH%/}/wp-load.php"
    "$CMD_PHP" "$checker_php" "$wp_load_path" "$weak_pw_file" "$users_hash_file" >"$weak_hits_file" 2>>"$DETAIL_FILE" || true

    COUNT_WEAK_PASSWORD_USERS=$("$CMD_WC" -l <"$weak_hits_file" | "$CMD_TR" -d ' ')
    line "Utilisateurs avec mot de passe faible detecte: $COUNT_WEAK_PASSWORD_USERS"
    if [ "$COUNT_WEAK_PASSWORD_USERS" -gt 0 ]; then
        limit_dump "$weak_hits_file" "$MAX_FINDINGS_PER_SECTION"
    fi
}

check_http_security_headers() {
    section "Verification des headers de securite HTTP"

    if ! command_exists "$CMD_CURL"; then
        line "curl indisponible"
        return 0
    fi

    if [ -z "$SITE_URL" ] && command_exists "$CMD_WP"; then
        SITE_URL=$("$CMD_WP" --path="$WP_PATH" option get home 2>>"$DETAIL_FILE" || true)
    fi

    if [ -z "$SITE_URL" ]; then
        line "URL du site manquante"
        return 0
    fi

    headers_file="$TMP_DIR/http_headers.txt"
    : >"$headers_file"

    if [ "$CURL_FOLLOW_REDIRECTS" = "1" ]; then
        if [ "$CURL_INSECURE_TLS" = "1" ]; then
            "$CMD_CURL" -k -sS -I -L -m "$HTTP_TIMEOUT_SECONDS" "$SITE_URL" >"$headers_file" 2>>"$DETAIL_FILE" || true
        else
            "$CMD_CURL" -sS -I -L -m "$HTTP_TIMEOUT_SECONDS" "$SITE_URL" >"$headers_file" 2>>"$DETAIL_FILE" || true
        fi
    else
        if [ "$CURL_INSECURE_TLS" = "1" ]; then
            "$CMD_CURL" -k -sS -I -m "$HTTP_TIMEOUT_SECONDS" "$SITE_URL" >"$headers_file" 2>>"$DETAIL_FILE" || true
        else
            "$CMD_CURL" -sS -I -m "$HTTP_TIMEOUT_SECONDS" "$SITE_URL" >"$headers_file" 2>>"$DETAIL_FILE" || true
        fi
    fi

    if [ ! -s "$headers_file" ]; then
        line "Impossible de recuperer les headers HTTP"
        return 0
    fi

    headers_list_file="$TMP_DIR/security_headers.txt"
    printf '%s\n' "$SECURITY_HEADERS" >"$headers_list_file"

    missing="0"
    present="0"
    while IFS= read -r h; do
        if [ -n "$h" ]; then
            hv=$("$CMD_GREP" -i "^${h}:" "$headers_file" | "$CMD_HEAD" -n 1 || true)
            if [ -n "$hv" ]; then
                present=$((present + 1))
                line "present|$hv"
            else
                missing=$((missing + 1))
                line "missing|${h}"
            fi
        fi
    done <"$headers_list_file"

    COUNT_MISSING_HEADERS="$missing"
    line "Headers presents: $present"
    line "Headers manquants: $missing"
}

fetch_last_updated_from_wp_api() {
    item_type="$1"
    slug="$2"
    if ! command_exists "$CMD_CURL" || ! command_exists "$CMD_PHP"; then
        printf '%s\n' ""
        return 0
    fi

    safe_slug=$(printf '%s' "$slug" | "$CMD_TR" '/ ' '__')
    json_file="$TMP_DIR/wp_api_${item_type}_${safe_slug}.json"

    if [ "$item_type" = "plugin" ]; then
        req_url=$(printf "$WORDPRESS_PLUGIN_API_URL_TEMPLATE" "$slug")
    else
        req_url=$(printf "$WORDPRESS_THEME_API_URL_TEMPLATE" "$slug")
    fi

    "$CMD_CURL" -sS -m "$HTTP_TIMEOUT_SECONDS" "$req_url" >"$json_file" 2>>"$DETAIL_FILE" || true
    if [ ! -s "$json_file" ]; then
        printf '%s\n' ""
        return 0
    fi

    "$CMD_PHP" -r '$j = json_decode(stream_get_contents(STDIN), true); if (is_array($j) && isset($j["last_updated"])) { echo $j["last_updated"]; }' <"$json_file" 2>/dev/null || true
}

check_plugins_themes() {
    section "Plugins et themes abandonnes ou vulnerables"

    if [ "$ENABLE_PLUGIN_THEME_CHECKS" != "1" ]; then
        line "Verification plugins/themes desactivee"
        return 0
    fi

    if ! command_exists "$CMD_WP"; then
        line "WP-CLI indisponible"
        return 0
    fi

    plugin_csv="$TMP_DIR/plugins.csv"
    theme_csv="$TMP_DIR/themes.csv"
    plugin_slugs="$TMP_DIR/plugin_slugs.txt"
    theme_slugs="$TMP_DIR/theme_slugs.txt"
    abandoned_plugins="$TMP_DIR/abandoned_plugins.txt"
    abandoned_themes="$TMP_DIR/abandoned_themes.txt"

    : >"$plugin_csv"
    : >"$theme_csv"
    : >"$plugin_slugs"
    : >"$theme_slugs"
    : >"$abandoned_plugins"
    : >"$abandoned_themes"

    "$CMD_WP" --path="$WP_PATH" plugin list --fields=name,status,version,update,update_version --format=csv >"$plugin_csv" 2>>"$DETAIL_FILE" || true
    "$CMD_WP" --path="$WP_PATH" theme list --fields=name,status,version,update,update_version --format=csv >"$theme_csv" 2>>"$DETAIL_FILE" || true

    if [ -s "$plugin_csv" ]; then
        COUNT_OUTDATED_PLUGINS=$("$CMD_AWK" -F ',' 'NR>1 && $4=="available" {c++} END{print c+0}' "$plugin_csv")
        line "Plugins avec mise a jour disponible: $COUNT_OUTDATED_PLUGINS"
        if [ "$COUNT_OUTDATED_PLUGINS" -gt 0 ]; then
            "$CMD_AWK" -F ',' 'NR>1 && $4=="available" {print}' "$plugin_csv" >"$TMP_DIR/outdated_plugins.csv"
            limit_dump "$TMP_DIR/outdated_plugins.csv" "$MAX_FINDINGS_PER_SECTION"
        fi
        "$CMD_WP" --path="$WP_PATH" plugin list --field=name >"$plugin_slugs" 2>>"$DETAIL_FILE" || true
    else
        line "Impossible de recuperer la liste des plugins"
    fi

    if [ -s "$theme_csv" ]; then
        COUNT_OUTDATED_THEMES=$("$CMD_AWK" -F ',' 'NR>1 && $4=="available" {c++} END{print c+0}' "$theme_csv")
        line "Themes avec mise a jour disponible: $COUNT_OUTDATED_THEMES"
        if [ "$COUNT_OUTDATED_THEMES" -gt 0 ]; then
            "$CMD_AWK" -F ',' 'NR>1 && $4=="available" {print}' "$theme_csv" >"$TMP_DIR/outdated_themes.csv"
            limit_dump "$TMP_DIR/outdated_themes.csv" "$MAX_FINDINGS_PER_SECTION"
        fi
        "$CMD_WP" --path="$WP_PATH" theme list --field=name >"$theme_slugs" 2>>"$DETAIL_FILE" || true
    else
        line "Impossible de recuperer la liste des themes"
    fi

    if [ -s "$plugin_slugs" ]; then
        while IFS= read -r slug; do
            if [ -n "$slug" ]; then
                lu=$(fetch_last_updated_from_wp_api "plugin" "$slug")
                if [ -n "$lu" ]; then
                    days=$(days_since "$lu")
                    if [ -n "$days" ] && [ "$days" -gt "$PLUGIN_ABANDON_DAYS" ]; then
                        COUNT_ABANDONED_PLUGINS=$((COUNT_ABANDONED_PLUGINS + 1))
                        printf '%s\n' "$slug|last_updated=$lu|days=$days" >>"$abandoned_plugins"
                    fi
                fi
            fi
        done <"$plugin_slugs"
    fi

    if [ -s "$theme_slugs" ]; then
        while IFS= read -r slug; do
            if [ -n "$slug" ]; then
                lu=$(fetch_last_updated_from_wp_api "theme" "$slug")
                if [ -n "$lu" ]; then
                    days=$(days_since "$lu")
                    if [ -n "$days" ] && [ "$days" -gt "$THEME_ABANDON_DAYS" ]; then
                        COUNT_ABANDONED_THEMES=$((COUNT_ABANDONED_THEMES + 1))
                        printf '%s\n' "$slug|last_updated=$lu|days=$days" >>"$abandoned_themes"
                    fi
                fi
            fi
        done <"$theme_slugs"
    fi

    line "Plugins potentiellement abandonnes: $COUNT_ABANDONED_PLUGINS"
    if [ "$COUNT_ABANDONED_PLUGINS" -gt 0 ]; then
        limit_dump "$abandoned_plugins" "$MAX_FINDINGS_PER_SECTION"
    fi
    line "Themes potentiellement abandonnes: $COUNT_ABANDONED_THEMES"
    if [ "$COUNT_ABANDONED_THEMES" -gt 0 ]; then
        limit_dump "$abandoned_themes" "$MAX_FINDINGS_PER_SECTION"
    fi
}

run_wpscan_vulnerabilities() {
    section "Detection de vulnerabilites connues"

    if [ "$ENABLE_WPSCAN" != "1" ]; then
        line "WPScan desactive"
        return 0
    fi

    if ! command_exists "$CMD_WPSCAN"; then
        line "WPScan indisponible"
        return 0
    fi

    if [ -z "$SITE_URL" ] && command_exists "$CMD_WP"; then
        SITE_URL=$("$CMD_WP" --path="$WP_PATH" option get home 2>>"$DETAIL_FILE" || true)
    fi

    if [ -z "$SITE_URL" ]; then
        line "URL du site manquante"
        return 0
    fi

    wpscan_out="$TMP_DIR/wpscan_output.txt"
    : >"$wpscan_out"

    if [ -n "$WPSCAN_API_TOKEN" ]; then
        "$CMD_WPSCAN" --url "$SITE_URL" --format "$WPSCAN_FORMAT" --plugins-detection "$WPSCAN_PLUGINS_DETECTION" --enumerate "$WPSCAN_ENUMERATE" --no-update --api-token "$WPSCAN_API_TOKEN" >"$wpscan_out" 2>>"$DETAIL_FILE" || true
    else
        "$CMD_WPSCAN" --url "$SITE_URL" --format "$WPSCAN_FORMAT" --plugins-detection "$WPSCAN_PLUGINS_DETECTION" --enumerate "$WPSCAN_ENUMERATE" --no-update >"$wpscan_out" 2>>"$DETAIL_FILE" || true
    fi

    if [ ! -s "$wpscan_out" ]; then
        line "Aucune sortie WPScan"
        return 0
    fi

    "$CMD_GREP" -Ein 'vulnerab|cve-|fixed in|known vulnerabilities' "$wpscan_out" >"$TMP_DIR/wpscan_vuln_lines.txt" || true
    COUNT_WPSCAN_VULN_LINES=$("$CMD_WC" -l <"$TMP_DIR/wpscan_vuln_lines.txt" | "$CMD_TR" -d ' ')
    line "Lignes de vulnerabilite detectees par WPScan: $COUNT_WPSCAN_VULN_LINES"
    if [ "$COUNT_WPSCAN_VULN_LINES" -gt 0 ]; then
        limit_dump "$TMP_DIR/wpscan_vuln_lines.txt" "$MAX_FINDINGS_PER_SECTION"
    fi
}

write_summary() {
    section "Synthese"
    line "Signatures malveillantes: $COUNT_BACKDOOR_HITS"
    line "Signatures d'obfuscation: $COUNT_OBFUSCATION_HITS"
    line ".htaccess suspects: $COUNT_SUSPICIOUS_HTACCESS"
    line "Fichiers non desires: $COUNT_UNWANTED_FILES"
    line "Admins: $COUNT_ADMIN_USERS"
    line "Admins suspects: $COUNT_SUSPECT_ADMIN_USERS"
    line "Mots de passe faibles: $COUNT_WEAK_PASSWORD_USERS"
    line "Headers HTTP manquants: $COUNT_MISSING_HEADERS"
    line "Plugins obsoletes: $COUNT_OUTDATED_PLUGINS"
    line "Themes obsoletes: $COUNT_OUTDATED_THEMES"
    line "Plugins potentiellement abandonnes: $COUNT_ABANDONED_PLUGINS"
    line "Themes potentiellement abandonnes: $COUNT_ABANDONED_THEMES"
    line "Vulnerabilites WPScan detectees: $COUNT_WPSCAN_VULN_LINES"
    line "Detail log: $DETAIL_FILE"
}

main() {
    parse_args "$@"
    prepare_environment
    trap cleanup EXIT INT TERM

    section "Contexte"
    line "Horodatage: $RUN_TIMESTAMP"
    line "Chemin WordPress: $WP_PATH"
    line "URL cible: ${SITE_URL:-auto}"

    scan_backdoors_webshells
    check_htaccess_files
    check_unwanted_root_files
    check_admin_users
    check_weak_passwords
    check_http_security_headers
    check_plugins_themes
    run_wpscan_vulnerabilities
    write_summary

    printf '%s\n' "$REPORT_FILE"
}

main "$@"
