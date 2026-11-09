<?php
// Voorbeeld. Het echte bestand staat op de server in
// /var/www/dorpsplatformteteringen.nl/config/contact-config.php
// en hoort NOOIT in Git (er staat een wachtwoord in).
return [
    // SMTP-gegevens van de Strato-mailbox
    'smtp_host'   => 'smtp.strato.de',
    'smtp_port'   => 465,
    'smtp_secure' => 'ssl',            // 'ssl' (poort 465) of 'tls' (poort 587)
    'smtp_user'   => 'info@dorpsplatformteteringen.nl',
    'smtp_pass'   => 'WACHTWOORD-VAN-DE-MAILBOX',

    'van'  => 'info@dorpsplatformteteringen.nl',   // afzender (moet de SMTP-gebruiker zijn)
    'naar' => 'info@dorpsplatformteteringen.nl',   // ontvanger

    // Willekeurige lange tekst voor het ondertekenen van formulier-tokens
    // (maak er een met: openssl rand -hex 32)
    'geheim' => 'VERVANG-DOOR-64-WILLEKEURIGE-TEKENS',

    // Map waar PHP tijdelijke gegevens bewaart (tokens en limieten per IP)
    'data_map' => '/var/www/dorpsplatformteteringen.nl/data',

    'toegestane_hosts' => ['dorpsplatformteteringen.nl', 'www.dorpsplatformteteringen.nl'],

    // true = niets versturen, maar berichten in data/test-mails.log zetten
    'test_modus' => false,
];
