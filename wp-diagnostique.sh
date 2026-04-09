#!/bin/bash
# ================================================
# wp-diagnostique.sh - Diagnostic plugins & thèmes WordPress
# Auteur : Grok (créé pour toi) - Root only
# Usage : ./wp-diagnostique.sh /chemin/vers/wp
# ================================================

set -euo pipefail

WP_PATH="${1:-}"
if [[ -z "$WP_PATH" || ! -f "$WP_PATH/wp-config.php" ]]; then
    echo "❌ Usage : $0 /chemin/vers/dossier/wordpress"
    echo "   (le dossier doit contenir wp-config.php)"
    exit 1
fi

cd "$WP_PATH"
echo "🔍 Diagnostic WordPress lancé sur : $WP_PATH"
echo "=================================================="

# ====================== Variables globales ======================
REPORT="rapport-diagnostic-$(date +%Y%m%d-%H%M).txt"

CORE_UPDATES=0
PLUGIN_UPDATES=0
THEME_UPDATES=0
INCOMPATIBLE_COUNT=0
OUTDATED_TESTED_COUNT=0
BAD_DIR_COUNT=0
BAD_FILE_COUNT=0
WP_CONFIG_PERM_OK=1
WP_CONFIG_PERM_STATUS="oui"
SUSPICIOUS_COUNT=0
DEBUG_ISSUES=0
SERVER_LOG_ISSUES=0
LOG_ISSUES=0

RECO_CRITICAL=()
RECO_HIGH=()
RECO_MEDIUM=()
RECO_LOW=()

TMP_FILES=()

cleanup_tmp() {
    local f
    for f in "${TMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup_tmp EXIT

new_tmp_file() {
    local t
    t=$(mktemp)
    TMP_FILES+=("$t")
    echo "$t"
}

is_version() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)*$ ]]
}

version_lt() {
    local left="$1"
    local right="$2"
    [[ "$left" != "$right" ]] && [[ "$(printf '%s\n' "$left" "$right" | sort -V | head -n1)" == "$left" ]]
}

contains_reco() {
    local needle="$1"
    shift
    local reco
    for reco in "$@"; do
        [[ "$reco" == "$needle" ]] && return 0
    done
    return 1
}

add_recommendation() {
    local severity="$1"
    shift
    local message="$*"

    case "$severity" in
        critical)
            contains_reco "$message" "${RECO_CRITICAL[@]}" || RECO_CRITICAL+=("$message")
            ;;
        high)
            contains_reco "$message" "${RECO_HIGH[@]}" || RECO_HIGH+=("$message")
            ;;
        medium)
            contains_reco "$message" "${RECO_MEDIUM[@]}" || RECO_MEDIUM+=("$message")
            ;;
        *)
            contains_reco "$message" "${RECO_LOW[@]}" || RECO_LOW+=("$message")
            ;;
    esac
}

print_reco_block() {
    local label="$1"
    shift
    local message
    for message in "$@"; do
        echo "  $RECO_INDEX. [$label] $message"
        RECO_INDEX=$((RECO_INDEX + 1))
    done
}

append_report_reco_block() {
    local label="$1"
    shift
    local message
    for message in "$@"; do
        printf "%d. [%s] %s\n" "$REPORT_RECO_INDEX" "$label" "$message" >> "$REPORT"
        REPORT_RECO_INDEX=$((REPORT_RECO_INDEX + 1))
    done
}

# ====================== 1. WP-CLI ======================
if ! command -v wp >/dev/null 2>&1; then
    echo "📥 Installation de WP-CLI..."
    curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
    echo "✅ WP-CLI installé"
fi

# ====================== 2. Infos système ======================
WP_VERSION=$(wp core version --path="$WP_PATH" 2>/dev/null || echo "inconnue")
PHP_VERSION=$(php -v | head -n1 | awk '{print $2}')
DB_NAME=$(wp config get DB_NAME --path="$WP_PATH")
WEB_USER=$(ps aux | grep -E 'apache|nginx|php-fpm' | grep -v grep | awk '{print $1}' | head -n1 || echo "www-data")

echo "📊 Infos système :
   • WordPress : $WP_VERSION
   • PHP        : $PHP_VERSION
   • DB         : $DB_NAME
   • Web user   : $WEB_USER"

PHP_MAJOR=$(echo "$PHP_VERSION" | cut -d. -f1)
PHP_MINOR=$(echo "$PHP_VERSION" | cut -d. -f2)
if [[ "$PHP_MAJOR" =~ ^[0-9]+$ && "$PHP_MINOR" =~ ^[0-9]+$ ]]; then
    if (( PHP_MAJOR < 8 )); then
        add_recommendation high "Mettre à niveau PHP vers 8.1+ (idéalement 8.2/8.3) car votre version actuelle est vieillissante."
    elif (( PHP_MAJOR == 8 && PHP_MINOR < 1 )); then
        add_recommendation medium "Planifier une mise à niveau PHP vers 8.2/8.3 pour de meilleures performances et un support plus durable."
    fi
fi

# ====================== 3. Liste plugins & thèmes ======================
echo -e "\n🔌 Plugins installés :"
wp plugin list --path="$WP_PATH" --format=table

echo -e "\n🎨 Thèmes installés :"
wp theme list --path="$WP_PATH" --format=table

# ====================== 4. Vérification mises à jour ======================
echo -e "\n🔄 Mises à jour disponibles :"
wp plugin update --dry-run --path="$WP_PATH" 2>/dev/null || true
wp theme update --dry-run --path="$WP_PATH" 2>/dev/null || true

CORE_UPDATES=$(wp core check-update --path="$WP_PATH" --format=csv 2>/dev/null | tail -n +2 | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ' || echo "0")
PLUGIN_UPDATES=$(wp plugin list --path="$WP_PATH" --update=available --field=name 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ' || echo "0")
THEME_UPDATES=$(wp theme list --path="$WP_PATH" --update=available --field=name 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ' || echo "0")

if (( CORE_UPDATES > 0 || PLUGIN_UPDATES > 0 || THEME_UPDATES > 0 )); then
    add_recommendation high "Appliquer les mises à jour en priorité sur une préproduction, puis en production avec sauvegarde complète."
    if (( CORE_UPDATES > 0 )); then
        add_recommendation high "Mettre à jour WordPress core ($CORE_UPDATES version(s) disponible(s))."
    fi
    if (( PLUGIN_UPDATES > 0 )); then
        add_recommendation high "Mettre à jour les plugins ($PLUGIN_UPDATES en attente) pour corriger vulnérabilités et bugs."
    fi
    if (( THEME_UPDATES > 0 )); then
        add_recommendation medium "Mettre à jour les thèmes ($THEME_UPDATES en attente), surtout le thème actif."
    fi
fi

# ====================== 5. Compatibilité version ======================
echo -e "\n📋 Vérification compatibilité plugins/thèmes..."

check_compatibility() {
    local dir="$1"
    local type="$2"
    local item
    local mainfile
    local requires
    local tested

    for item in "$dir"/*/; do
        [[ -d "$item" ]] || continue
        mainfile=$(find "$item" -maxdepth 1 -name "*.php" -exec grep -l "Plugin Name:\|Theme Name:" {} + | head -n1)
        [[ -z "$mainfile" ]] && continue

        requires=$(grep -m1 "Requires at least:" "$mainfile" 2>/dev/null | awk -F: '{print $2}' | tr -d ' ' || echo "N/A")
        tested=$(grep -m1 "Tested up to:" "$mainfile" 2>/dev/null | awk -F: '{print $2}' | tr -d ' ' || echo "N/A")

        if [[ "$requires" != "N/A" ]] && is_version "$requires" && is_version "$WP_VERSION" && version_lt "$WP_VERSION" "$requires"; then
            echo "⚠️  $type incompatible : $(basename "$item") (nécessite WP >= $requires)"
            INCOMPATIBLE_COUNT=$((INCOMPATIBLE_COUNT + 1))
        fi

        if [[ "$tested" != "N/A" ]] && is_version "$tested" && is_version "$WP_VERSION" && version_lt "$tested" "$WP_VERSION"; then
            OUTDATED_TESTED_COUNT=$((OUTDATED_TESTED_COUNT + 1))
        fi
    done
}

check_compatibility "$WP_PATH/wp-content/plugins" "Plugin"
check_compatibility "$WP_PATH/wp-content/themes" "Thème"

if (( INCOMPATIBLE_COUNT > 0 )); then
    add_recommendation high "Remplacer ou désactiver les extensions incompatibles avec votre version de WordPress."
fi

if (( OUTDATED_TESTED_COUNT > 0 )); then
    add_recommendation medium "Vérifier les extensions peu testées sur votre version de WordPress ($OUTDATED_TESTED_COUNT cas), surtout avant une montée de version."
fi

# ====================== 6. Permissions & propriétaire ======================
echo -e "\n🔐 Vérification permissions..."

BAD_DIR_FILE=$(new_tmp_file)
BAD_REG_FILE=$(new_tmp_file)

find "$WP_PATH" -type d -not -perm 755 > "$BAD_DIR_FILE"
find "$WP_PATH" -type f -not -perm 644 > "$BAD_REG_FILE"

BAD_DIR_COUNT=$(wc -l < "$BAD_DIR_FILE" | tr -d ' ')
BAD_FILE_COUNT=$(wc -l < "$BAD_REG_FILE" | tr -d ' ')

if (( BAD_DIR_COUNT > 0 )); then
    echo "⚠️  Dossiers avec permissions inattendues (affichage limité à 10) :"
    sed -n '1,10p' "$BAD_DIR_FILE" | while IFS= read -r p; do
        [[ -n "$p" ]] && echo "   - $p"
    done
    if (( BAD_DIR_COUNT > 10 )); then
        echo "   ... +$((BAD_DIR_COUNT - 10)) autre(s)"
    fi
else
    echo "✅ Permissions dossiers globalement correctes (755)"
fi

if (( BAD_FILE_COUNT > 0 )); then
    echo "⚠️  Fichiers avec permissions inattendues (affichage limité à 10) :"
    sed -n '1,10p' "$BAD_REG_FILE" | while IFS= read -r p; do
        [[ -n "$p" ]] && echo "   - $p"
    done
    if (( BAD_FILE_COUNT > 10 )); then
        echo "   ... +$((BAD_FILE_COUNT - 10)) autre(s)"
    fi
else
    echo "✅ Permissions fichiers globalement correctes (644)"
fi

# wp-config.php doit être plus restrictif
if [[ -f wp-config.php ]]; then
    WP_CONFIG_PERM=$(stat -c '%a' wp-config.php 2>/dev/null || stat -f '%Lp' wp-config.php 2>/dev/null || echo "unknown")
    if [[ "$WP_CONFIG_PERM" != "600" && "$WP_CONFIG_PERM" != "640" ]]; then
        WP_CONFIG_PERM_OK=0
        WP_CONFIG_PERM_STATUS="non"
        echo "⚠️  wp-config.php devrait être 600 ou 640 (actuel : $WP_CONFIG_PERM)"
    else
        WP_CONFIG_PERM_STATUS="oui"
        echo "✅ wp-config.php est correctement protégé ($WP_CONFIG_PERM)"
    fi
fi

if (( BAD_DIR_COUNT > 0 || BAD_FILE_COUNT > 0 || WP_CONFIG_PERM_OK == 0 )); then
    add_recommendation high "Corriger les permissions: dossiers en 755, fichiers en 644, et wp-config.php en 600/640."
fi

# ====================== 7. Code suspect (backdoors) ======================
echo -e "\n🛡️  Scan code suspect (heuristique)..."
SUSPICIOUS=$(grep -rE --include="*.php" \
    'eval\(|base64_decode|shell_exec|system\(|exec\(|passthru|assert\(' \
    wp-content/plugins/ wp-content/themes/ 2>/dev/null | head -n 20 || true)

if [[ -n "$SUSPICIOUS" ]]; then
    SUSPICIOUS_COUNT=$(printf '%s\n' "$SUSPICIOUS" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    echo "🚨 Code potentiellement malveillant détecté :"
    echo "$SUSPICIOUS"
    add_recommendation critical "Isoler immédiatement les extensions suspectes, lancer un scan sécurité complet (Wordfence/Sucuri) et changer les mots de passe administrateur/DB/FTP."
    add_recommendation critical "Comparer les fichiers suspects avec une source officielle et restaurer les fichiers compromis depuis une sauvegarde saine."
else
    echo "✅ Aucun pattern suspect trouvé"
fi

# ====================== 8. Analyse logs ======================
echo -e "\n📜 Analyse des logs d’erreurs..."

DEBUG_LOG="$WP_PATH/wp-content/debug.log"
if [[ -f "$DEBUG_LOG" ]]; then
    echo "→ debug.log trouvé ($(wc -c < "$DEBUG_LOG") octets)"
    DEBUG_EXTRACT=$(tail -n 100 "$DEBUG_LOG" | grep -E "(Fatal error|Warning|Notice|plugin|theme)" | tail -n 15 || true)
    if [[ -n "$DEBUG_EXTRACT" ]]; then
        echo "$DEBUG_EXTRACT"
        DEBUG_ISSUES=$(printf '%s\n' "$DEBUG_EXTRACT" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    fi
fi

# Logs serveur (les plus courants)
for log in /var/log/php*.log /var/log/apache2/error.log /var/log/nginx/error.log /var/log/php-fpm/*.log; do
    [[ -f "$log" ]] || continue
    echo "→ Analyse $log (dernières 50 lignes avec plugins)..."
    LOG_EXTRACT=$(tail -n 50 "$log" 2>/dev/null | grep -E "(plugin|theme|wp-content)" | tail -n 10 || true)
    if [[ -n "$LOG_EXTRACT" ]]; then
        echo "$LOG_EXTRACT"
        SERVER_LOG_ISSUES=$((SERVER_LOG_ISSUES + $(printf '%s\n' "$LOG_EXTRACT" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')))
    fi
done

LOG_ISSUES=$((DEBUG_ISSUES + SERVER_LOG_ISSUES))
if (( LOG_ISSUES > 0 )); then
    add_recommendation high "Corriger en priorité les erreurs des logs (fatal/warnings), puis revérifier le front-office et l'admin après correction."
fi

if (( INCOMPATIBLE_COUNT > 0 || OUTDATED_TESTED_COUNT > 0 || LOG_ISSUES > 0 )); then
    add_recommendation medium "Lancer le mode test de conflit plugins/thèmes pour isoler rapidement l’extension responsable."
fi

if (( ${#RECO_CRITICAL[@]} == 0 && ${#RECO_HIGH[@]} == 0 && ${#RECO_MEDIUM[@]} == 0 && ${#RECO_LOW[@]} == 0 )); then
    add_recommendation low "Aucun risque majeur détecté. Conserver une politique de sauvegardes quotidiennes + mises à jour hebdomadaires."
fi

# ====================== 9. Recommandations ======================
echo -e "\n🧠 Recommandations prioritaires :"
RECO_INDEX=1
print_reco_block "CRITIQUE" "${RECO_CRITICAL[@]}"
print_reco_block "ÉLEVÉE" "${RECO_HIGH[@]}"
print_reco_block "MOYENNE" "${RECO_MEDIUM[@]}"
print_reco_block "INFO" "${RECO_LOW[@]}"

# ====================== 10. Rapport final ======================
{
    echo "Rapport de diagnostic WordPress - $(date)"
    echo "Chemin : $WP_PATH"
    echo "=================================================="
    echo "Généré par wp-diagnostique.sh"
    echo
    echo "Résumé chiffré :"
    echo " - Mises à jour core disponibles      : $CORE_UPDATES"
    echo " - Mises à jour plugins disponibles   : $PLUGIN_UPDATES"
    echo " - Mises à jour thèmes disponibles    : $THEME_UPDATES"
    echo " - Incompatibilités détectées         : $INCOMPATIBLE_COUNT"
    echo " - Extensions peu testées             : $OUTDATED_TESTED_COUNT"
    echo " - Dossiers à permissions atypiques   : $BAD_DIR_COUNT"
    echo " - Fichiers à permissions atypiques   : $BAD_FILE_COUNT"
    echo " - wp-config.php correctement protégé : $WP_CONFIG_PERM_STATUS"
    echo " - Occurrences code suspect (aperçu)  : $SUSPICIOUS_COUNT"
    echo " - Événements logs détectés           : $LOG_ISSUES"
    echo
    echo "Recommandations prioritaires :"
} > "$REPORT"

REPORT_RECO_INDEX=1
append_report_reco_block "CRITIQUE" "${RECO_CRITICAL[@]}"
append_report_reco_block "ÉLEVÉE" "${RECO_HIGH[@]}"
append_report_reco_block "MOYENNE" "${RECO_MEDIUM[@]}"
append_report_reco_block "INFO" "${RECO_LOW[@]}"

echo -e "\n✅ Rapport sauvegardé : $REPORT"
echo "   (ouvre-le avec : cat $REPORT | less)"

# ====================== 11. Mode test de conflit (optionnel) ======================
read -p "Voulez-vous lancer le mode 'Test de conflit plugins/thèmes' ? (très lent - y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "⚠️  Attention : ce mode va désactiver TOUS les plugins et passer au thème par défaut."
    read -p "Continuer ? (y/N) " -n 1 -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Sauvegarde de l’état actuel..."
        wp plugin list --path="$WP_PATH" --format=csv > plugins_backup.csv
        wp theme list --path="$WP_PATH" --format=csv > themes_backup.csv

        CURRENT_THEME=$(wp theme list --status=active --field=name --path="$WP_PATH")
        wp theme activate twentytwentyfour --path="$WP_PATH" || wp theme activate twentytwentythree --path="$WP_PATH"
        wp plugin deactivate --all --path="$WP_PATH"

        echo "Tous les plugins désactivés + thème par défaut activé."
        echo "Test du site (curl) :"
        SITE_URL=$(wp option get home --path="$WP_PATH")
        curl -I -s "$SITE_URL" | head -n 5

        read -p "Réactive tout maintenant ? (y/N) " -n 1 -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            wp theme activate "$CURRENT_THEME" --path="$WP_PATH" 2>/dev/null || true
            while IFS=, read -r name status; do
                [[ "$status" == "active" ]] && wp plugin activate "$name" --path="$WP_PATH" 2>/dev/null || true
            done < plugins_backup.csv
            echo "✅ État restauré"
        fi
    fi
fi

echo -e "\n🎉 Diagnostic terminé !"
