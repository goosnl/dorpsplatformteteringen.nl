<?php
/**
 * Contactformulier Dorpsplatform Teteringen
 *
 * GET  /contact.php?token=1  -> geeft een ondertekend formulier-token terug
 * POST /contact.php          -> controleert het bericht en mailt het naar info@
 *
 * Spambeveiliging (zonder externe diensten / cookies):
 *  1. Honeypot-veld dat mensen niet zien en bots wel invullen
 *  2. Ondertekend token (HMAC) dat alleen met JavaScript wordt opgehaald,
 *     minimaal 3 seconden oud moet zijn en maar één keer bruikbaar is
 *  3. Maximaal aantal berichten per IP-adres (opgeslagen als anonieme hash)
 *  4. Controle op Origin-header, lengtes, links en verboden tekens
 *  5. Daarnaast begrenst nginx het aantal verzoeken op /contact.php
 */

declare(strict_types=1);

use PHPMailer\PHPMailer\PHPMailer;

require __DIR__ . '/vendor/autoload.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Robots-Tag: noindex, nofollow');

const TOKEN_MIN_LEEFTIJD = 3;          // seconden
const TOKEN_MAX_LEEFTIJD = 2 * 3600;   // seconden
const LIMIET_KORT = [3, 600];          // max 3 berichten per 10 minuten
const LIMIET_DAG = [10, 86400];        // max 10 berichten per dag
const MAX_LINKS = 3;

function antwoord(int $status, array $data): never
{
    http_response_code($status);
    echo json_encode($data, JSON_UNESCAPED_UNICODE);
    exit;
}

function fout(int $status, string $melding): never
{
    antwoord($status, ['ok' => false, 'melding' => $melding]);
}

/** Doe alsof het gelukt is (voor bots), zonder iets te versturen. */
function stilWeigeren(string $reden): never
{
    error_log('[contact] geweigerd: ' . $reden);
    antwoord(200, ['ok' => true]);
}

// ---------- Configuratie ----------
$configPad = getenv('DPT_CONTACT_CONFIG') ?: dirname(__DIR__) . '/config/contact-config.php';
if (!is_readable($configPad)) {
    error_log('[contact] configuratiebestand ontbreekt: ' . $configPad);
    fout(500, 'Het formulier is tijdelijk niet beschikbaar. Mail naar info@dorpsplatformteteringen.nl.');
}
$cfg = require $configPad;
$geheim = (string)($cfg['geheim'] ?? '');
if (strlen($geheim) < 32) {
    error_log('[contact] "geheim" in de configuratie is te kort');
    fout(500, 'Het formulier is tijdelijk niet beschikbaar. Mail naar info@dorpsplatformteteringen.nl.');
}
$dataMap = rtrim((string)($cfg['data_map'] ?? sys_get_temp_dir() . '/dpt-contact'), '/');
foreach (['', '/tokens', '/limiet'] as $sub) {
    if (!is_dir($dataMap . $sub) && !@mkdir($dataMap . $sub, 0770, true) && !is_dir($dataMap . $sub)) {
        error_log('[contact] kan map niet aanmaken: ' . $dataMap . $sub);
        fout(500, 'Het formulier is tijdelijk niet beschikbaar. Mail naar info@dorpsplatformteteringen.nl.');
    }
}

// ---------- Token ----------
function maakToken(string $geheim): string
{
    $tijd = (string)time();
    $nonce = bin2hex(random_bytes(12));
    $sig = hash_hmac('sha256', $tijd . '.' . $nonce, $geheim);
    return $tijd . '.' . $nonce . '.' . $sig;
}

/** @return string|null foutreden of null als het token geldig is */
function controleerToken(string $token, string $geheim, string $dataMap): ?string
{
    $delen = explode('.', $token);
    if (count($delen) !== 3 || !ctype_digit($delen[0]) || !ctype_xdigit($delen[1]) || !ctype_xdigit($delen[2])) {
        return 'ongeldig token';
    }
    [$tijd, $nonce, $sig] = $delen;
    if (!hash_equals(hash_hmac('sha256', $tijd . '.' . $nonce, $geheim), $sig)) {
        return 'handtekening klopt niet';
    }
    $leeftijd = time() - (int)$tijd;
    if ($leeftijd < TOKEN_MIN_LEEFTIJD) {
        return 'te snel verstuurd';
    }
    if ($leeftijd > TOKEN_MAX_LEEFTIJD) {
        return 'verlopen';
    }
    // Eenmalig gebruik: maak een bestand aan; bestaat het al, dan is het token al gebruikt
    $bestand = $dataMap . '/tokens/' . $nonce;
    $fh = @fopen($bestand, 'x');
    if ($fh === false) {
        return 'token al gebruikt';
    }
    fclose($fh);
    // Oude tokens af en toe opruimen
    if (random_int(1, 20) === 1) {
        foreach (glob($dataMap . '/tokens/*') ?: [] as $f) {
            if (filemtime($f) < time() - TOKEN_MAX_LEEFTIJD - 60) {
                @unlink($f);
            }
        }
    }
    return null;
}

// ---------- Limiet per IP ----------
function binnenLimiet(string $ip, string $geheim, string $dataMap): bool
{
    $bestand = $dataMap . '/limiet/' . substr(hash_hmac('sha256', $ip, $geheim), 0, 32);
    $fh = fopen($bestand, 'c+');
    if ($fh === false) {
        return true;
    }
    flock($fh, LOCK_EX);
    $inhoud = stream_get_contents($fh);
    $nu = time();
    $tijden = array_values(array_filter(
        array_map('intval', $inhoud ? explode(',', $inhoud) : []),
        fn(int $t) => $t > $nu - LIMIET_DAG[1]
    ));
    $kort = count(array_filter($tijden, fn(int $t) => $t > $nu - LIMIET_KORT[1]));
    $toegestaan = $kort < LIMIET_KORT[0] && count($tijden) < LIMIET_DAG[0];
    if ($toegestaan) {
        $tijden[] = $nu;
    }
    ftruncate($fh, 0);
    rewind($fh);
    fwrite($fh, implode(',', $tijden));
    flock($fh, LOCK_UN);
    fclose($fh);
    if (random_int(1, 50) === 1) {
        foreach (glob($dataMap . '/limiet/*') ?: [] as $f) {
            if (filemtime($f) < $nu - LIMIET_DAG[1]) {
                @unlink($f);
            }
        }
    }
    return $toegestaan;
}

// ---------- Hulpfuncties ----------
function veld(string $naam, int $max, bool $meerdereRegels = false): string
{
    $w = $_POST[$naam] ?? '';
    if (!is_string($w)) {
        return '';
    }
    $w = trim($w);
    // Verwijder onzichtbare stuurtekens; enkele regels mogen geen regeleinden bevatten
    $w = $meerdereRegels
        ? preg_replace('/[^\P{C}\n\t]/u', '', str_replace("\r\n", "\n", $w))
        : preg_replace('/\p{C}/u', '', $w);
    if ($w === null) {
        return '';
    }
    return mb_substr($w, 0, $max);
}

function aantalLinks(string $tekst): int
{
    return preg_match_all('~(https?://|www\.)~i', $tekst);
}

// ================= GET: token ophalen =================
$methode = $_SERVER['REQUEST_METHOD'] ?? 'GET';
if ($methode === 'GET' && isset($_GET['token'])) {
    antwoord(200, ['token' => maakToken($geheim)]);
}
if ($methode !== 'POST') {
    header('Allow: GET, POST');
    fout(405, 'Methode niet toegestaan.');
}

// ================= POST: bericht versturen =================
$hosts = $cfg['toegestane_hosts'] ?? [];
$origin = $_SERVER['HTTP_ORIGIN'] ?? '';
if ($origin !== '') {
    $originHost = parse_url($origin, PHP_URL_HOST);
    if (!in_array($originHost, $hosts, true)) {
        fout(403, 'Verzoek geweigerd.');
    }
}

// 1. Honeypot
if (($_POST['website'] ?? '') !== '') {
    stilWeigeren('honeypot ingevuld');
}

// 2. Token
$tokenFout = controleerToken((string)($_POST['token'] ?? ''), $geheim, $dataMap);
if ($tokenFout === 'te snel verstuurd' || $tokenFout === 'token al gebruikt') {
    stilWeigeren($tokenFout);
}
if ($tokenFout !== null) {
    fout(400, 'Je sessie is verlopen. Vernieuw de pagina en probeer het opnieuw.');
}

// 3. Invoer controleren
$naam = veld('naam', 100);
$email = veld('email', 150);
$telefoon = veld('telefoon', 30);
$onderwerp = veld('onderwerp', 150);
$bericht = veld('bericht', 5000, true);

if ($naam === '' || $email === '' || $bericht === '') {
    fout(422, 'Vul je naam, e-mailadres en bericht in.');
}
if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
    fout(422, 'Controleer je e-mailadres.');
}
if ($telefoon !== '' && !preg_match('/^[0-9 +()\-.]{6,30}$/', $telefoon)) {
    fout(422, 'Controleer je telefoonnummer.');
}
if (aantalLinks($naam . ' ' . $onderwerp) > 0) {
    stilWeigeren('link in naam of onderwerp');
}
if (preg_match('~\[url=|<a\s+href|\[link=~i', $bericht)) {
    stilWeigeren('bbcode/html-link in bericht');
}
if (aantalLinks($bericht) > MAX_LINKS) {
    fout(422, 'Je bericht bevat te veel links.');
}

// 4. Limiet per IP
$ip = $_SERVER['REMOTE_ADDR'] ?? 'onbekend';
if (!binnenLimiet($ip, $geheim, $dataMap)) {
    fout(429, 'Je hebt al meerdere berichten verstuurd. Probeer het later opnieuw.');
}

// 5. Versturen
$tekst = "Nieuw bericht via het contactformulier op dorpsplatformteteringen.nl\n\n"
    . "Naam:      {$naam}\n"
    . "E-mail:    {$email}\n"
    . 'Telefoon:  ' . ($telefoon !== '' ? $telefoon : '-') . "\n"
    . 'Onderwerp: ' . ($onderwerp !== '' ? $onderwerp : '-') . "\n"
    . 'Datum:     ' . (new DateTimeImmutable('now', new DateTimeZone('Europe/Amsterdam')))->format('d-m-Y H:i') . "\n\n"
    . "Bericht:\n{$bericht}\n\n"
    . "-- \nJe kunt direct op deze e-mail antwoorden; je antwoord gaat naar {$email}.\n";
$titel = 'Contactformulier: ' . ($onderwerp !== '' ? $onderwerp : 'nieuw bericht van ' . $naam);

if (!empty($cfg['test_modus'])) {
    file_put_contents($dataMap . '/test-mails.log', "=== {$titel}\n{$tekst}\n", FILE_APPEND | LOCK_EX);
    antwoord(200, ['ok' => true]);
}

try {
    $mail = new PHPMailer(true);
    $mail->isSMTP();
    $mail->Host = (string)$cfg['smtp_host'];
    $mail->Port = (int)$cfg['smtp_port'];
    $mail->SMTPSecure = ($cfg['smtp_secure'] ?? 'ssl') === 'tls' ? PHPMailer::ENCRYPTION_STARTTLS : PHPMailer::ENCRYPTION_SMTPS;
    $mail->SMTPAuth = true;
    $mail->Username = (string)$cfg['smtp_user'];
    $mail->Password = (string)$cfg['smtp_pass'];
    $mail->Timeout = 15;
    $mail->CharSet = PHPMailer::CHARSET_UTF8;
    $mail->setFrom((string)$cfg['van'], 'Website Dorpsplatform Teteringen');
    $mail->addAddress((string)$cfg['naar']);
    $mail->addReplyTo($email, $naam);
    $mail->Subject = $titel;
    $mail->Body = $tekst;
    $mail->isHTML(false);
    $mail->send();
} catch (Throwable $e) {
    error_log('[contact] versturen mislukt: ' . $e->getMessage());
    fout(500, 'Er ging iets mis bij het versturen. Probeer het later opnieuw of mail naar info@dorpsplatformteteringen.nl.');
}

antwoord(200, ['ok' => true]);
