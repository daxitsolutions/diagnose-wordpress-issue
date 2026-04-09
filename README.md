# reset-wordpress-default-theme

Script POSIX `sh` pour désactiver le thème WordPress actif et activer un thème par défaut déjà installé.

## Installation (Debian)

```sh
sudo apt update
sudo apt install -y git

git clone https://github.com/<owner>/diagnose-wordpress-issue.git
cd diagnose-wordpress-issue
chmod +x reset-wordpress-default-theme.sh
```

## Prérequis

- `wp-cli` installé et disponible dans le `PATH` (ou via un binaire personnalisé avec `-b`)
- Accès au dossier d'une installation WordPress existante

## Utilisation

```sh
./reset-wordpress-default-theme.sh [options]
```

Le script:

1. lit le thème actif,
2. choisit un thème par défaut,
3. active ce thème par défaut si nécessaire,
4. affiche le thème actif final.

## Options

- `-b <wp_cli_bin>`: binaire `wp` à utiliser
- `-p <wp_path>`: chemin de l'installation WordPress (doit contenir `wp-config.php`)
- `-t <theme>`: thème par défaut à forcer
- `-c "<themes...>"`: liste ordonnée des thèmes candidats
- `-u <url>`: URL du site WordPress (multisite/proxy)
- `-r`: ajoute `--allow-root` à `wp-cli`

## Variables par défaut dans le script

- `WP_CLI_BIN="wp"`
- `WP_PATH="."`
- `TARGET_DEFAULT_THEME=""`
- `DEFAULT_THEME_CANDIDATES="twentytwentysix twentytwentyfive twentytwentyfour twentytwentythree twentytwentytwo twentytwentyone twentytwenty"`
- `WP_URL=""`
- `WP_CLI_ALLOW_ROOT="0"`

## Exemples

Activer automatiquement le premier thème par défaut disponible:

```sh
./reset-wordpress-default-theme.sh -p /var/www/html
```

Forcer un thème précis:

```sh
./reset-wordpress-default-theme.sh -p /var/www/html -t twentytwentysix
```

Exécution en root:

```sh
./reset-wordpress-default-theme.sh -p /var/www/html -r
```

---

# wp-security-audit

Script POSIX `sh` d’audit sécurité WordPress orienté détection d’indicateurs de compromission et d’hygiène sécurité.

## Objectif

Le script `wp-security-audit.sh` génère un rapport texte horodaté avec:

- scan approfondi de signatures backdoor/webshell et motifs d’obfuscation
- vérification des `.htaccess` récents/suspects (et comparaison baseline si fournie)
- détection de fichiers non désirés à la racine WordPress
- contrôle des comptes administrateurs (volume, usernames suspects, derniers logins si métadonnées disponibles)
- détection de mots de passe faibles via validation de hash WordPress
- vérification des en-têtes HTTP de sécurité
- détection de plugins/thèmes obsolètes ou potentiellement abandonnés
- extraction d’indices de vulnérabilités connues via `wpscan` (si disponible)

## Prérequis

- Shell POSIX (`/bin/sh`)
- Utilitaires système: `find`, `grep`, `awk`, `sort`, `cksum`, `curl`, `mktemp`
- Optionnel mais recommandé:
- `wp` (WP-CLI) pour les contrôles utilisateurs/plugins/thèmes/URL auto
- `php` pour contrôle des hashes et datation API WordPress.org
- `wpscan` pour enrichir la détection de vulnérabilités connues

## Utilisation

```sh
./wp-security-audit.sh [options]
```

## Options

- `-c <config_file>`: charge un fichier de configuration shell (surcharge les variables du script)
- `-p <wp_path>`: chemin de l’installation WordPress cible
- `-u <site_url>`: URL cible pour le contrôle des headers HTTP et WPScan
- `-o <output_dir>`: dossier de sortie des rapports

## Sorties

Chaque exécution crée:

- un rapport principal `wordpress_security_audit_<timestamp>.txt`
- un journal technique `wordpress_security_audit_<timestamp>.detail.log`

Le script affiche à la fin le chemin absolu/relatif du rapport principal.

## Exemples

Audit local d’une instance:

```sh
./wp-security-audit.sh -p /var/www/html -o ./security_audit_reports
```

Audit avec URL explicite:

```sh
./wp-security-audit.sh -p /var/www/html -u https://example.com -o ./security_audit_reports
```

Audit avec configuration dédiée:

```sh
./wp-security-audit.sh -c ./audit-security.conf -p /var/www/html
```

## Exemple de fichier de configuration

```sh
SITE_URL="https://example.com"
OUTPUT_DIR="./security_audit_reports"
HTTP_TIMEOUT_SECONDS="30"
ENABLE_WPSCAN="1"
WPSCAN_API_TOKEN=""
HTACCESS_RECENT_DAYS="14"
PLUGIN_ABANDON_DAYS="365"
THEME_ABANDON_DAYS="365"
ENABLE_WEAK_PASSWORD_SCAN="1"
```

## Lecture rapide du rapport

- section `Scan backdoors et webshells`: nombre de matches de patterns malveillants et obfuscation
- section `Verification des .htaccess`: fichiers récents/suspects + lignes détectées
- section `Verification des utilisateurs administrateurs`: volume admins et usernames à risque
- section `Scan des mots de passe faibles`: comptes validés contre la liste faible paramétrée
- section `Verification des headers de securite HTTP`: headers présents/manquants
- section `Plugins et themes abandonnes ou vulnerables`: mises à jour disponibles + abandon probable
- section `Detection de vulnerabilites connues`: lignes WPScan contenant des indicateurs de vulnérabilité
- section `Synthese`: vue consolidée des compteurs
