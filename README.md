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
