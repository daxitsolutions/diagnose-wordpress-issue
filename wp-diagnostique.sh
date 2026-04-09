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

# ====================== 3. Liste plugins & thèmes ======================
echo -e "\n🔌 Plugins installés :"
wp plugin list --path="$WP_PATH" --format=table

echo -e "\n🎨 Thèmes installés :"
wp theme list --path="$WP_PATH" --format=table

# ====================== 4. Vérification mises à jour ======================
echo -e "\n🔄 Mises à jour disponibles :"
wp plugin update --dry-run --path="$WP_PATH" 2>/dev/null || true
wp theme update --dry-run --path="$WP_PATH" 2>/dev/null || true

# ====================== 5. Compatibilité version ======================
echo -e "\n📋 Vérification compatibilité plugins/thèmes..."

check_compatibility() {
    local dir=$1
    local type=$2
    for plugin in "$dir"/*/; do
        [ -d "$plugin" ] || continue
        mainfile=$(find "$plugin" -maxdepth 1 -name "*.php" -exec grep -l "Plugin Name:\|Theme Name:" {} + | head -n1)
        [[ -z "$mainfile" ]] && continue

        requires=$(grep -m1 "Requires at least:" "$mainfile" 2>/dev/null | awk -F: '{print $2}' | tr -d ' ' || echo "N/A")
        tested=$(grep -m1 "Tested up to:" "$mainfile" 2>/dev/null | awk -F: '{print $2}' | tr -d ' ' || echo "N/A")

        if [[ "$requires" != "N/A" && "$WP_VERSION" < "$requires" ]]; then
            echo "⚠️  $type incompatible : $(basename "$plugin") (nécessite WP >= $requires)"
        fi
    done
}

check_compatibility "$WP_PATH/wp-content/plugins" "Plugin"
check_compatibility "$WP_PATH/wp-content/themes" "Thème"

# ====================== 6. Permissions & propriétaire ======================
echo -e "\n🔐 Vérification permissions..."

find "$WP_PATH" -type d -not -perm 755 -exec echo "⚠️  Dossier incorrect : {}" \;
find "$WP_PATH" -type f -not -perm 644 -exec echo "⚠️  Fichier incorrect : {}" \;

# wp-config.php doit être plus restrictif
if [[ -f wp-config.php ]]; then
    ls -l wp-config.php | grep -q "600\|640" || echo "⚠️  wp-config.php devrait être 600 ou 640"
fi

# ====================== 7. Code suspect (backdoors) ======================
echo -e "\n🛡️  Scan code suspect (heuristique)..."
SUSPICIOUS=$(grep -rE --include="*.php" \
    'eval\(|base64_decode|shell_exec|system\(|exec\(|passthru|assert\(' \
    wp-content/plugins/ wp-content/themes/ 2>/dev/null | head -n 20 || true)

if [[ -n "$SUSPICIOUS" ]]; then
    echo "🚨 Code potentiellement malveillant détecté :"
    echo "$SUSPICIOUS"
else
    echo "✅ Aucun pattern suspect trouvé"
fi

# ====================== 8. Analyse logs ======================
echo -e "\n📜 Analyse des logs d’erreurs..."

DEBUG_LOG="$WP_PATH/wp-content/debug.log"
if [[ -f "$DEBUG_LOG" ]]; then
    echo "→ debug.log trouvé ($(wc -c < "$DEBUG_LOG") octets)"
    tail -n 100 "$DEBUG_LOG" | grep -E "(Fatal error|Warning|Notice|plugin|theme)" | tail -n 15 || true
fi

# Logs serveur (les plus courants)
for log in /var/log/php*.log /var/log/apache2/error.log /var/log/nginx/error.log /var/log/php-fpm/*.log; do
    [[ -f "$log" ]] || continue
    echo "→ Analyse $log (dernières 50 lignes avec plugins)..."
    tail -n 50 "$log" 2>/dev/null | grep -E "(plugin|theme|wp-content)" | tail -n 10 || true
done

# ====================== 9. Rapport final ======================
REPORT="rapport-diagnostic-$(date +%Y%m%d-%H%M).txt"
{
    echo "Rapport de diagnostic WordPress - $(date)"
    echo "Chemin : $WP_PATH"
    echo "=================================================="
    echo "Généré par wp-diagnostique.sh"
} > "$REPORT"

echo -e "\n✅ Rapport sauvegardé : $REPORT"
echo "   (ouvre-le avec : cat $REPORT | less)"

# ====================== 10. Mode test de conflit (optionnel) ======================
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