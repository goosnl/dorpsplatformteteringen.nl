#!/usr/bin/env bash
# =============================================================================
#  Installatiescript voor dorpsplatformteteringen.nl op een Ubuntu-VPS
#
#  Gebruik (als root of met sudo):
#    sudo bash setup-server.sh            # stap 1: alles klaarzetten (veilig om vaker te draaien)
#    sudo bash setup-server.sh ssl        # stap 2: NA het omzetten van de DNS: HTTPS-certificaat aanvragen
#    sudo bash setup-server.sh sleutel    # toon opnieuw de gegevens voor GitHub
#
#  Werkt naast bestaande websites: er wordt alleen een eigen vhost toegevoegd.
#  Ondersteunt nginx (voorkeur) en Apache; het script kiest wat er al draait.
# =============================================================================
set -euo pipefail

DOMEIN="dorpsplatformteteringen.nl"
SITE_MAP="/var/www/${DOMEIN}"
DEPLOY_GEBRUIKER="deploy-dorpsplatform"
ACME_MAP="/var/www/letsencrypt"
LE_EMAIL="info@${DOMEIN}"
SLEUTEL="/root/${DEPLOY_GEBRUIKER}-sleutel"
NAAM="dorpsplatformteteringen"
FASE="${1:-installeren}"

groen() { printf '\033[1;32m%s\033[0m\n' "$*"; }
geel()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
rood()  { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
stap()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { rood "Draai dit script als root: sudo bash $0 ${FASE}"; exit 1; }
[[ -f /etc/os-release ]] && . /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *debian* ]] || geel "Let op: dit script is gemaakt voor Ubuntu (gevonden: ${PRETTY_NAME:-onbekend})."

HEEFT_SYSTEMD=1
command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || HEEFT_SYSTEMD=0

dienst_actief() { [[ $HEEFT_SYSTEMD -eq 1 ]] && systemctl is-active --quiet "$1"; }

# ---------------------------------------------------------------- webserver
kies_webserver() {
  if [[ -n "${WEBSERVER:-}" ]]; then echo "$WEBSERVER"; return; fi
  if [[ -d /usr/local/psa ]]; then
    rood "Deze server gebruikt Plesk. Voeg het domein dan via Plesk toe in plaats van met dit script."; exit 1
  fi
  if dienst_actief nginx || { [[ $HEEFT_SYSTEMD -eq 0 ]] && command -v nginx >/dev/null; }; then echo nginx
  elif dienst_actief apache2 || { [[ $HEEFT_SYSTEMD -eq 0 ]] && command -v apache2 >/dev/null; }; then echo apache
  else echo nginx
  fi
}
WEB="$(kies_webserver)"

herlaad_web() {
  if [[ "$WEB" == nginx ]]; then
    nginx -t
    if [[ $HEEFT_SYSTEMD -eq 1 ]]; then systemctl reload nginx || systemctl restart nginx
    else nginx -s reload 2>/dev/null || nginx; fi
  else
    apache2ctl configtest
    if [[ $HEEFT_SYSTEMD -eq 1 ]]; then systemctl reload apache2; else apache2ctl graceful; fi
  fi
}

php_socket() {
  local s
  s="$(ls /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n1 || true)"
  [[ -n "$s" ]] || s="$(ls /run/php/php-fpm.sock 2>/dev/null || true)"
  echo "$s"
}

php_versie() { php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true; }

ssh_poort() { local p; p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"; echo "${p:-22}"; }

server_ip() {
  local i; i="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  [[ -n "$i" ]] || i="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "$i"
}

heeft_ipv6() { [[ -f /proc/net/if_inet6 ]] && [[ -s /proc/net/if_inet6 ]]; }

certificaat_bestaat() { [[ -f "/etc/letsencrypt/live/${DOMEIN}/fullchain.pem" ]]; }

# ---------------------------------------------------------------- pakketten
installeer_pakketten() {
  stap "Pakketten installeren (webserver: ${WEB})"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  local pakketten=(rsync certbot openssl fail2ban)
  if [[ "$WEB" == nginx ]]; then pakketten+=(nginx); else pakketten+=(apache2); fi
  if [[ -z "$(php_socket)" ]] && ! ls /etc/php/*/fpm >/dev/null 2>&1; then pakketten+=(php-fpm php-mbstring); fi
  apt-get install -y -q "${pakketten[@]}"
  local v; v="$(php_versie)"
  if [[ -n "$v" ]] && ! php -m 2>/dev/null | grep -qi '^mbstring$'; then
    apt-get install -y -q "php${v}-mbstring" || apt-get install -y -q php-mbstring
  fi
  if [[ $HEEFT_SYSTEMD -eq 1 ]]; then
    for d in /lib/systemd/system/php*-fpm.service; do
      [[ -e "$d" ]] && systemctl enable --now "$(basename "$d" .service)" >/dev/null 2>&1 || true
    done
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
  fi
  if [[ "$WEB" == apache ]]; then a2enmod -q rewrite headers proxy_fcgi setenvif ssl expires >/dev/null; fi
}

# ---------------------------------------------------------------- mappen
maak_mappen() {
  stap "Gebruiker '${DEPLOY_GEBRUIKER}' en mappen aanmaken"
  if ! id "$DEPLOY_GEBRUIKER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --comment "GitHub deploy dorpsplatform" "$DEPLOY_GEBRUIKER"
    passwd -l "$DEPLOY_GEBRUIKER" >/dev/null
  fi
  install -d -o root -g root -m 755 "$SITE_MAP"
  install -d -o "$DEPLOY_GEBRUIKER" -g "$DEPLOY_GEBRUIKER" -m 755 "$SITE_MAP/public" "$SITE_MAP/app"
  install -d -o root -g www-data -m 750 "$SITE_MAP/config"
  install -d -o www-data -g www-data -m 770 "$SITE_MAP/data"
  install -d -o root -g root -m 755 "$ACME_MAP"
  if [[ ! -f "$SITE_MAP/public/index.html" ]]; then
    cat > "$SITE_MAP/public/index.html" <<'HTML'
<!doctype html><html lang="nl"><meta charset="utf-8"><title>Dorpsplatform Teteringen</title><p>De nieuwe website wordt binnenkort geplaatst.</p></html>
HTML
    chown "$DEPLOY_GEBRUIKER:$DEPLOY_GEBRUIKER" "$SITE_MAP/public/index.html"
  fi
}

# ---------------------------------------------------------------- config contactformulier
maak_contact_config() {
  local bestand="$SITE_MAP/config/contact-config.php"
  stap "Instellingen contactformulier"
  if [[ -f "$bestand" ]]; then
    groen "Bestaat al: $bestand (niet aangepast)"; return
  fi
  local wachtwoord="${SMTP_WACHTWOORD:-}"
  if [[ -z "$wachtwoord" ]]; then
    echo "Het contactformulier verstuurt mail via de Strato-mailbox info@${DOMEIN}."
    read -rsp "Wachtwoord van de mailbox info@${DOMEIN}: " wachtwoord; echo
  fi
  local geheim; geheim="$(openssl rand -hex 32)"
  local ww_php; ww_php="$(printf '%s' "$wachtwoord" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g")"
  umask 027
  cat > "$bestand" <<PHP
<?php
// Instellingen voor het contactformulier. NIET in Git zetten.
return [
    'smtp_host'   => 'smtp.strato.de',
    'smtp_port'   => 465,
    'smtp_secure' => 'ssl',
    'smtp_user'   => 'info@${DOMEIN}',
    'smtp_pass'   => '${ww_php}',
    'van'         => 'info@${DOMEIN}',
    'naar'        => 'info@${DOMEIN}',
    'geheim'      => '${geheim}',
    'data_map'    => '${SITE_MAP}/data',
    'toegestane_hosts' => ['${DOMEIN}', 'www.${DOMEIN}'],
    'test_modus'  => false,
];
PHP
  umask 022
  chown root:www-data "$bestand"; chmod 640 "$bestand"
  groen "Aangemaakt: $bestand"
}

# ---------------------------------------------------------------- SSH-sleutel voor GitHub
maak_deploy_sleutel() {
  stap "SSH-sleutel voor GitHub Actions"
  local rrsync; rrsync="$(command -v rrsync || true)"
  if [[ -z "$rrsync" && -f /usr/share/doc/rsync/scripts/rrsync.gz ]]; then
    gunzip -c /usr/share/doc/rsync/scripts/rrsync.gz > /usr/local/bin/rrsync; chmod 755 /usr/local/bin/rrsync
    rrsync=/usr/local/bin/rrsync
  fi
  [[ -n "$rrsync" ]] || { rood "rrsync niet gevonden (onderdeel van het pakket rsync)."; exit 1; }

  if [[ ! -f "$SLEUTEL" ]]; then
    ssh-keygen -q -t ed25519 -N "" -C "github-actions@${DOMEIN}" -f "$SLEUTEL"
    chmod 600 "$SLEUTEL"
  fi
  local home; home="$(getent passwd "$DEPLOY_GEBRUIKER" | cut -d: -f6)"
  install -d -o "$DEPLOY_GEBRUIKER" -g "$DEPLOY_GEBRUIKER" -m 700 "$home/.ssh"
  # De sleutel mag ALLEEN bestanden via rsync in de sitemap zetten (geen shell, geen forwarding)
  local regel="command=\"${rrsync} ${SITE_MAP}\",restrict $(cat "${SLEUTEL}.pub")"
  local ak="$home/.ssh/authorized_keys"
  touch "$ak"
  grep -qF "$(cut -d' ' -f2 "${SLEUTEL}.pub")" "$ak" || echo "$regel" >> "$ak"
  chown "$DEPLOY_GEBRUIKER:$DEPLOY_GEBRUIKER" "$ak"; chmod 600 "$ak"

  local beperking; beperking="$(sshd -T 2>/dev/null | grep -Ei '^(allowusers|allowgroups) ' || true)"
  if [[ -n "$beperking" ]]; then
    geel "Let op: SSH staat alleen bepaalde gebruikers/groepen toe:"; echo "$beperking"
    geel "Voeg '${DEPLOY_GEBRUIKER}' toe aan AllowUsers in /etc/ssh/sshd_config en herstart ssh."
  fi
}

toon_github_gegevens() {
  local poort ip; poort="$(ssh_poort)"; ip="$(server_ip)"
  local kh=""
  for f in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
    [[ -f "$f" ]] || continue
    if [[ "$poort" == 22 ]]; then kh+="${ip} $(cut -d' ' -f1,2 "$f")"$'\n'
    else kh+="[${ip}]:${poort} $(cut -d' ' -f1,2 "$f")"$'\n'; fi
  done
  cat <<TXT

$(groen "=== Zet deze gegevens in GitHub ===")
Repository > Settings > Environments > productie > Environment secrets

  DEPLOY_HOST          ${ip}
  DEPLOY_PORT          ${poort}
  DEPLOY_USER          ${DEPLOY_GEBRUIKER}
  DEPLOY_KNOWN_HOSTS   (alle regels hieronder, tussen de streepjes)
------------------------------------------------------------
${kh}------------------------------------------------------------
  DEPLOY_SSH_KEY       (alles hieronder, inclusief de BEGIN- en END-regel)
------------------------------------------------------------
$(cat "$SLEUTEL")
------------------------------------------------------------
Bewaar de privésleutel nergens anders dan in GitHub. Je kunt deze gegevens
later opnieuw tonen met:  sudo bash $0 sleutel
TXT
}

# ---------------------------------------------------------------- webserverconfig: nginx
schrijf_nginx() {
  local sock; sock="$(php_socket)"
  [[ -n "$sock" ]] || { rood "Geen PHP-FPM-socket gevonden in /run/php."; exit 1; }

  cat > "/etc/nginx/conf.d/${NAAM}-limiet.conf" <<CONF
# Begrenzing voor het contactformulier van ${DOMEIN}
limit_req_zone \$binary_remote_addr zone=${NAAM}_contact:1m rate=10r/m;
CONF

  local https=0; certificaat_bestaat && https=1
  local csp="default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; font-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'self'; object-src 'none'"
  [[ $https -eq 1 ]] && csp+="; upgrade-insecure-requests"

  cat > "/etc/nginx/snippets/${NAAM}-site.conf" <<CONF
# Gedeelde instellingen voor ${DOMEIN} (gegenereerd door setup-server.sh)
root ${SITE_MAP}/public;
index index.html;
charset utf-8;
server_tokens off;
client_max_body_size 64k;

add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), interest-cohort=()" always;
add_header Content-Security-Policy "${csp}" always;
$( [[ $https -eq 1 ]] && echo 'add_header Strict-Transport-Security "max-age=31536000" always;' )

error_page 404 /404.html;
location = /404.html { internal; }

# --- Oude WordPress-adressen ---
location = /7ef081809f6a-htm.htm { return 410; }
location ~* "^/wp-content/uploads/[0-9]{4}/[0-9]{2}/(002026-Aanvraagformulier-wijkplatform\.pdf|002026-Leeg-aanmeldformulier\.pdf)\$" { return 301 /media/\$1; }
location ~* ^/(wp-admin|wp-includes|wp-content|wp-json)(/|\$) { return 410; }
location ~* ^/(wp-login|xmlrpc|wp-cron|wp-config|wp-signup|wp-trackback)\.php\$ { return 410; }
location ~ ^/(comments/)?feed/?\$ { return 301 /; }

# --- Contactformulier: het ENIGE PHP-bestand dat wordt uitgevoerd ---
location = /contact.php {
    limit_req zone=${NAAM}_contact burst=10 nodelay;
    limit_req_status 429;
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:${sock};
}
location ~* \.(php|phtml|phar)\$ { return 404; }

# Verborgen bestanden blokkeren
location ~ /\.(?!well-known/) { deny all; }

# Slash aan het eind weghalen (oude WordPress-links)
location ~ ^(.+)/\$ { return 301 \$1; }

location /_astro/ { expires max; access_log off; }
location /media/  { expires 30d; }
location /        { try_files \$uri \$uri.html \$uri/index.html =404; }
CONF

  local acme="location ^~ /.well-known/acme-challenge/ { root ${ACME_MAP}; default_type text/plain; }"
  local v6_80="" v6_443=""
  if heeft_ipv6; then v6_80="listen [::]:80;"; v6_443="listen [::]:443 ssl http2;"; fi
  local vhost="/etc/nginx/sites-available/${DOMEIN}"
  if [[ $https -eq 1 ]]; then
    cat > "$vhost" <<CONF
# ${DOMEIN} (gegenereerd door setup-server.sh)
server {
    listen 80;
    ${v6_80}
    server_name ${DOMEIN} www.${DOMEIN};
    ${acme}
    location / { return 301 https://${DOMEIN}\$request_uri; }
}
server {
    listen 443 ssl http2;
    ${v6_443}
    server_name www.${DOMEIN};
    ssl_certificate     /etc/letsencrypt/live/${DOMEIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMEIN}/privkey.pem;
    return 301 https://${DOMEIN}\$request_uri;
}
server {
    listen 443 ssl http2;
    ${v6_443}
    server_name ${DOMEIN};
    ssl_certificate     /etc/letsencrypt/live/${DOMEIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMEIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:${NAAM}_ssl:5m;
    include snippets/${NAAM}-site.conf;
}
CONF
  else
    cat > "$vhost" <<CONF
# ${DOMEIN} (gegenereerd door setup-server.sh) – nog zonder HTTPS
server {
    listen 80;
    ${v6_80}
    server_name ${DOMEIN} www.${DOMEIN};
    ${acme}
    include snippets/${NAAM}-site.conf;
}
CONF
  fi
  ln -sf "$vhost" "/etc/nginx/sites-enabled/${DOMEIN}"
}

# ---------------------------------------------------------------- webserverconfig: Apache
schrijf_apache() {
  local sock; sock="$(php_socket)"
  [[ -n "$sock" ]] || { rood "Geen PHP-FPM-socket gevonden in /run/php."; exit 1; }
  local https=0; certificaat_bestaat && https=1
  local csp="default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; font-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'self'; object-src 'none'"
  [[ $https -eq 1 ]] && csp+="; upgrade-insecure-requests"

  cat > "/etc/apache2/${NAAM}-site.conf" <<CONF
# Gedeelde instellingen voor ${DOMEIN} (gegenereerd door setup-server.sh)
DocumentRoot ${SITE_MAP}/public
ServerSignature Off
AddDefaultCharset utf-8
LimitRequestBody 65536
ErrorDocument 404 /404.html

Alias /.well-known/acme-challenge/ ${ACME_MAP}/.well-known/acme-challenge/
<Directory ${ACME_MAP}>
    Require all granted
</Directory>

<Directory ${SITE_MAP}/public>
    Options -Indexes -ExecCGI +SymLinksIfOwnerMatch
    AllowOverride None
    Require all granted
    DirectoryIndex index.html
    # Alleen contact.php mag als PHP worden uitgevoerd
    <FilesMatch "\.(php|phtml|phar)\$">
        Require all denied
    </FilesMatch>
    <Files "contact.php">
        Require all granted
        SetHandler "proxy:unix:${sock}|fcgi://localhost"
    </Files>
</Directory>

Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "DENY"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
Header always set Permissions-Policy "camera=(), microphone=(), geolocation=(), interest-cohort=()"
Header always set Content-Security-Policy "${csp}"
$( [[ $https -eq 1 ]] && echo 'Header always set Strict-Transport-Security "max-age=31536000"' )
<LocationMatch "^/_astro/">
    Header set Cache-Control "public, max-age=31536000, immutable"
</LocationMatch>

RewriteEngine On
RewriteRule ^/7ef081809f6a-htm\.htm\$ - [G]
RewriteRule ^/wp-content/uploads/[0-9]{4}/[0-9]{2}/(002026-Aanvraagformulier-wijkplatform\.pdf|002026-Leeg-aanmeldformulier\.pdf)\$ /media/\$1 [R=301,L]
RewriteRule ^/(wp-admin|wp-includes|wp-content|wp-json)(/|\$) - [G]
RewriteRule ^/(wp-login|xmlrpc|wp-cron|wp-config|wp-signup|wp-trackback)\.php\$ - [G]
RewriteRule ^/(comments/)?feed/?\$ / [R=301,L]
RewriteRule ^/\.well-known/ - [L]
RewriteRule ^/\. - [F]
RewriteRule ^/(.+)/\$ /\$1 [R=301,L]
RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI} !-f
RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.html -f
RewriteRule ^(.+)\$ \$1.html [L]
CONF

  local vhost="/etc/apache2/sites-available/${DOMEIN}.conf"
  if [[ $https -eq 1 ]]; then
    cat > "$vhost" <<CONF
# ${DOMEIN} (gegenereerd door setup-server.sh)
<VirtualHost *:80>
    ServerName ${DOMEIN}
    ServerAlias www.${DOMEIN}
    Alias /.well-known/acme-challenge/ ${ACME_MAP}/.well-known/acme-challenge/
    <Directory ${ACME_MAP}>
        Require all granted
    </Directory>
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^ https://${DOMEIN}%{REQUEST_URI} [R=301,L]
</VirtualHost>
<VirtualHost *:443>
    ServerName ${DOMEIN}
    ServerAlias www.${DOMEIN}
    SSLEngine on
    SSLCertificateFile    /etc/letsencrypt/live/${DOMEIN}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${DOMEIN}/privkey.pem
    RewriteEngine On
    RewriteCond %{HTTP_HOST} ^www\. [NC]
    RewriteRule ^ https://${DOMEIN}%{REQUEST_URI} [R=301,L]
    Include /etc/apache2/${NAAM}-site.conf
</VirtualHost>
CONF
  else
    cat > "$vhost" <<CONF
# ${DOMEIN} (gegenereerd door setup-server.sh) – nog zonder HTTPS
<VirtualHost *:80>
    ServerName ${DOMEIN}
    ServerAlias www.${DOMEIN}
    Include /etc/apache2/${NAAM}-site.conf
</VirtualHost>
CONF
  fi
  a2ensite -q "${DOMEIN}.conf" >/dev/null
}

eigen_bestanden() {
  if [[ "$WEB" == nginx ]]; then
    echo "/etc/nginx/conf.d/${NAAM}-limiet.conf /etc/nginx/snippets/${NAAM}-site.conf /etc/nginx/sites-available/${DOMEIN} /etc/nginx/sites-enabled/${DOMEIN}"
  else
    echo "/etc/apache2/${NAAM}-site.conf /etc/apache2/sites-available/${DOMEIN}.conf /etc/apache2/sites-enabled/${DOMEIN}.conf"
  fi
}

schrijf_webconfig() {
  stap "Webserver-configuratie schrijven (${WEB}$(certificaat_bestaat && echo ', met HTTPS' || echo ', nog zonder HTTPS'))"
  # Eerst testen of de bestaande configuratie in orde is, anders niets aanraken
  if [[ "$WEB" == nginx ]]; then nginx -t 2>/dev/null; else apache2ctl configtest 2>/dev/null; fi || {
    rood "De huidige ${WEB}-configuratie geeft al een fout (los van deze site). Los die eerst op:"
    if [[ "$WEB" == nginx ]]; then nginx -t; else apache2ctl configtest; fi
    exit 1
  }
  local backup; backup="/root/${NAAM}-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  for f in $(eigen_bestanden); do [[ -e "$f" || -L "$f" ]] && cp -a "$f" "$backup/" || true; done
  if [[ "$WEB" == nginx ]]; then schrijf_nginx; else schrijf_apache; fi
  if ! herlaad_web; then
    rood "De nieuwe configuratie werkt niet; ik zet de vorige terug zodat je andere sites blijven werken."
    for f in $(eigen_bestanden); do rm -f "$f"; [[ -e "$backup/$(basename "$f")" || -L "$backup/$(basename "$f")" ]] && cp -a "$backup/$(basename "$f")" "$f"; done
    herlaad_web || true
    exit 1
  fi
  rmdir "$backup" 2>/dev/null || true
  groen "Webserver herladen."
}

firewall() {
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    stap "Firewall (ufw): poort 80 en 443 openzetten"
    ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  else
    geel "ufw staat niet aan. Ik zet hem niet zelf aan (dat kan andere sites/SSH blokkeren)."
    geel "Controleer ook de firewall in het Strato-klantpaneel: poort 22, 80 en 443 moeten open staan."
  fi
}

# ---------------------------------------------------------------- SSL
vraag_ssl_aan() {
  stap "HTTPS-certificaat aanvragen bij Let's Encrypt"
  local ip; ip="$(server_ip)"
  for h in "$DOMEIN" "www.$DOMEIN"; do
    local a; a="$(getent ahostsv4 "$h" | awk 'NR==1{print $1}')"
    if [[ "$a" != "$ip" ]]; then
      rood "$h wijst naar '${a:-niets}', maar deze server is ${ip}."
      rood "Zet eerst bij Strato de A-records van ${DOMEIN} en www.${DOMEIN} op ${ip} en wacht tot dat actief is."
      exit 1
    fi
  done
  local herlaad_cmd="systemctl reload nginx"; [[ "$WEB" == apache ]] && herlaad_cmd="systemctl reload apache2"
  certbot certonly --webroot -w "$ACME_MAP" -d "$DOMEIN" -d "www.$DOMEIN" \
    --non-interactive --agree-tos -m "$LE_EMAIL" --keep-until-expiring \
    --deploy-hook "$herlaad_cmd"
  schrijf_webconfig
  groen "HTTPS staat aan. Het certificaat wordt automatisch verlengd."
}

# ================================================================ start
case "$FASE" in
  installeren)
    installeer_pakketten
    maak_mappen
    maak_contact_config
    maak_deploy_sleutel
    schrijf_webconfig
    firewall
    toon_github_gegevens
    cat <<TXT

$(groen "Klaar met stap 1.")
Volgende stappen:
  1. Zet de gegevens hierboven in GitHub (environment 'productie').
  2. Start in GitHub de workflow 'Bouwen en publiceren' (of push naar main).
  3. Test de site vóór het omzetten van de DNS via je hosts-bestand (zie README).
  4. Zet de DNS om en draai daarna:  sudo bash $0 ssl
TXT
    ;;
  ssl)     vraag_ssl_aan ;;
  sleutel) toon_github_gegevens ;;
  config)  schrijf_webconfig ;;
  *) rood "Onbekende stap '$FASE'. Gebruik: installeren | ssl | sleutel | config"; exit 1 ;;
esac
