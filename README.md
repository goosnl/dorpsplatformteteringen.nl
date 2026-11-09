# dorpsplatformteteringen.nl

De nieuwe website van Dorpsplatform Teteringen: een snelle, statische site (gebouwd met [Astro](https://astro.build)) zonder WordPress, zonder database en zonder plug-ins. Alleen het contactformulier draait op een klein, afgeschermd PHP-script.

Elke wijziging die op de branch `main` komt, wordt automatisch door GitHub Actions gebouwd en via SSH op de Strato-VPS gezet.

```
GitHub (main) ──► GitHub Actions: bouwen ──► rsync via SSH ──► VPS /var/www/dorpsplatformteteringen.nl/public
```

---

## 1. Inhoud aanpassen

Alle berichten (activiteiten en subsidieberichten) staan als losse bestanden in
[`src/content/berichten/`](src/content/berichten). Dat kan gewoon via de GitHub-website of de GitHub-app op je telefoon.

### Een nieuwe activiteit toevoegen

1. Open [`docs/sjabloon-activiteit.md`](docs/sjabloon-activiteit.md) en kopieer de inhoud.
2. Ga naar `src/content/berichten/` → **Add file → Create new file**.
3. Geef het een naam zoals `kerstmarkt-2026.md`. Het adres op de site wordt dan `dorpsplatformteteringen.nl/kerstmarkt-2026.htm`.
4. Plak het sjabloon, vul alles in en klik op **Commit changes** (direct op `main`).
5. Na ongeveer 1 minuut staat de activiteit online.

Een foto toevoegen: upload die eerst naar `src/assets/berichten/` en verwijs ernaar met `afbeelding:` (zie het sjabloon). De site maakt er automatisch kleine, snelle versies van.

**Volgorde op de site:** komende activiteiten eerst (de eerstvolgende vooraan), dan activiteiten zonder vaste datum, dan activiteiten die al geweest zijn. Elke nacht wordt de site opnieuw gebouwd, zodat dit vanzelf klopt. Staat er een activiteit binnenkort op de agenda, dan verschijnt die ook als label op de grote foto bovenaan de homepage.

### Vaste pagina's

| Pagina | Bestand |
| --- | --- |
| Homepage | `src/pages/index.astro` |
| Geschiedenis | `src/pages/geschiedenis.astro` |
| Subsidies (overzicht) | `src/pages/subsidies.astro` |
| Activiteiten (overzicht) | `src/pages/activiteiten.astro` |
| Contact | `src/pages/contact.astro` |
| Menu en footer | `src/layouts/Basis.astro` |
| Kleuren en opmaak | `src/styles/global.css` |
| PDF-formulieren | `public/media/` |

### Lokaal bekijken (optioneel)

Je hebt [Node.js](https://nodejs.org) 22 of nieuwer nodig.

```bash
npm install
```

```bash
npm run dev
```

Open daarna http://localhost:4321. Het contactformulier werkt lokaal niet (dat heeft PHP en de server nodig).

---

## 2. Eerste installatie op de VPS

Dit hoef je maar één keer te doen. Log in op de VPS via PowerShell (`ssh jouwgebruiker@IP-ADRES`) of Termius.

### Stap 1 – Installatiescript draaien

```bash
curl -fsSLO https://raw.githubusercontent.com/goosnl/dorpsplatformteteringen.nl/main/deploy/setup-server.sh
```

```bash
sudo bash setup-server.sh
```

Het script:

- kijkt of de VPS **nginx** of **Apache** gebruikt en voegt alleen een eigen site toe; je andere websites blijven ongemoeid. Werkt de nieuwe configuratie niet, dan zet het script automatisch de oude terug;
- installeert wat nodig is (PHP-FPM, rsync, certbot, fail2ban);
- maakt de gebruiker `deploy-dorpsplatform` aan, met een SSH-sleutel die **alleen** bestanden in `/var/www/dorpsplatformteteringen.nl` mag neerzetten (geen shell, niets daarbuiten);
- vraagt het wachtwoord van de mailbox `info@dorpsplatformteteringen.nl` (voor het contactformulier) en bewaart dat buiten de webmap, alleen leesbaar voor de webserver;
- toont aan het eind de gegevens die je in GitHub moet zetten.

Mappen op de server:

```
/var/www/dorpsplatformteteringen.nl/
├── public/   de website (wordt door GitHub gevuld)
├── app/      PHP-code van het contactformulier (wordt door GitHub gevuld)
├── config/   contact-config.php met het mailwachtwoord (alleen root/webserver)
└── data/     tijdelijke gegevens van de spambeveiliging
```

### Stap 2 – Gegevens in GitHub zetten (de "deploy key")

1. Ga in GitHub naar **Settings → Environments → New environment** en noem die `productie`.
   Zet géén "Required reviewers" aan, anders wacht de nachtelijke update op goedkeuring.
2. Voeg onder **Environment secrets** deze vijf secrets toe, met de waarden die het script toonde:

| Secret | Inhoud |
| --- | --- |
| `DEPLOY_HOST` | IP-adres van de VPS |
| `DEPLOY_PORT` | SSH-poort (meestal `22`) |
| `DEPLOY_USER` | `deploy-dorpsplatform` |
| `DEPLOY_SSH_KEY` | de privésleutel (inclusief de BEGIN- en END-regel) |
| `DEPLOY_KNOWN_HOSTS` | de regels met de vingerafdruk van de server |

Gegevens kwijt? Toon ze opnieuw met `sudo bash setup-server.sh sleutel`.

> Over de "deploy key": GitHub kent ook *deploy keys* waarmee een server code uit GitHub ophaalt. Hier werkt het andersom en veiliger: GitHub bouwt de site en duwt alleen de kant-en-klare bestanden naar de server. De server hoeft dus niets van GitHub te weten, en de sleutel kan op de server niets anders dan bestanden in de sitemap zetten.

### Stap 3 – Eerste keer publiceren

Zet de code op `main` (bijvoorbeeld door de pull request samen te voegen). De workflow **Bouwen en publiceren** start dan vanzelf. Je kunt hem ook handmatig starten onder **Actions → Bouwen en publiceren → Run workflow**.

### Stap 4 – Testen vóór het omzetten van de DNS

De DNS wijst nog naar de oude WordPress-site. Om de nieuwe site op de VPS al te bekijken, laat je alleen jouw laptop naar de VPS wijzen:

1. Open PowerShell **als administrator** en voer uit (vervang `IP-ADRES`):

```powershell
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "IP-ADRES dorpsplatformteteringen.nl www.dorpsplatformteteringen.nl"
```

2. Open **http**://dorpsplatformteteringen.nl in een privévenster. Let op: het is nog http, want het HTTPS-certificaat volgt pas in stap 5.
3. Haal de regel daarna weer weg uit `C:\Windows\System32\drivers\etc\hosts` (openen met Kladblok als administrator).

Tip: zet in `config/contact-config.php` tijdelijk `'test_modus' => true` om het formulier te testen zonder echte mail. Berichten komen dan in `data/test-mails.log`.

### Stap 5 – DNS omzetten en HTTPS aanzetten

1. Wijzig in het Strato-klantpaneel bij het domein **alleen de A-records** (en AAAA, als de VPS IPv6 heeft) van `dorpsplatformteteringen.nl` en `www` naar het IP-adres van de VPS.
   **Laat de MX-records (e-mail) en SPF/TXT-records staan**, zodat je mail gewoon bij Strato blijft binnenkomen.
2. Wacht tot de wijziging actief is (controle: `nslookup dorpsplatformteteringen.nl` geeft het IP van de VPS).
3. Draai op de VPS:

```bash
sudo bash setup-server.sh ssl
```

Dit vraagt een gratis Let's Encrypt-certificaat aan, zet HTTP om naar HTTPS en `www` naar het adres zonder `www`. Het certificaat wordt automatisch verlengd.

4. Verstuur een testbericht via het contactformulier en controleer of het in de mailbox `info@` aankomt.

---

## 3. Beveiliging

- **Geen WordPress, geen database, geen beheerderslogin.** Er is niets om in te breken zoals bij de oude site.
- **Alleen `contact.php` wordt als PHP uitgevoerd.** Elk ander `.php`-bestand geeft een 404, ook als het er ooit op zou komen.
- **Inhoud gecontroleerd**: alle tekst is uit de oude site overgenomen zonder code. Het nepbericht *"Hacked by CoupDeGrace"* is niet meegenomen; dat adres geeft nu `410 Gone`. Afbeeldingen zijn opnieuw opgeslagen, zodat er geen verborgen data mee kon komen.
- **Oude WordPress-adressen** (`/wp-admin`, `/wp-login.php`, `/xmlrpc.php` en dergelijke) geven `410 Gone`. De oude PDF-links worden doorgestuurd naar `/media/`. Alle oude pagina-adressen (zoals `/dorpsmaaltijd-2026.htm`) werken nog.
- **Beveiligingsheaders**: een strenge Content-Security-Policy (alleen eigen bestanden, geen externe scripts of lettertypes), plus X-Frame-Options, nosniff en HSTS.
- **Privacy (AVG)**: geen cookies, geen Google Fonts, geen reCAPTCHA en geen tracking. Lettertypes staan op de eigen server.
- **Contactformulier**, spambeveiliging in lagen:
  1. een onzichtbaar honeypot-veld;
  2. een ondertekend, eenmalig token dat alleen met JavaScript wordt opgehaald en minimaal 3 seconden oud moet zijn;
  3. maximaal 3 berichten per 10 minuten en 10 per dag per IP-adres (opgeslagen als anonieme hash);
  4. controle op herkomst (Origin), lengtes, e-mailadres en het aantal links;
  5. snelheidsbegrenzing in nginx.
- **Deploy-sleutel** is beperkt met `rrsync`: alleen rsync, alleen binnen de sitemap, geen shell en geen port-forwarding.

## 4. Na de livegang: oude site opruimen

- Verwijder de WordPress-installatie bij Strato, of zet het oude hostingpakket stop, zodra de nieuwe site live staat en goed werkt.
- Wijzig de wachtwoorden die op de oude site gebruikt werden: WordPress-beheerders, FTP/SFTP, de database en de mailbox als die hetzelfde wachtwoord had.
- Controleer in Google Search Console of de oude hack-pagina's uit Google verdwijnen. De `410`-status helpt daarbij.

## 5. Problemen oplossen

| Probleem | Oplossing |
| --- | --- |
| Workflow faalt bij "Bestanden naar de server sturen" | Controleer de secrets. `Host key verification failed` betekent dat `DEPLOY_KNOWN_HOSTS` niet klopt; `Permission denied` betekent dat `DEPLOY_SSH_KEY` of `DEPLOY_USER` niet klopt. Toon de juiste waarden met `sudo bash setup-server.sh sleutel`. |
| SSH-verbinding geweigerd | Staat poort 22 open in de Strato-firewall? Gebruikt `/etc/ssh/sshd_config` `AllowUsers`? Voeg dan `deploy-dorpsplatform` toe. |
| Contactformulier geeft een foutmelding | Kijk in het foutlog van de webserver (`sudo tail /var/log/nginx/error.log`) naar regels met `[contact]`. Meestal is het mailwachtwoord in `/var/www/dorpsplatformteteringen.nl/config/contact-config.php` niet juist. |
| Webserverconfiguratie opnieuw schrijven | `sudo bash setup-server.sh config` |
