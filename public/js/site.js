// Dorpsplatform Teteringen – kleine scripts voor menu, carrousel en contactformulier.
(function () {
  'use strict';

  // ---------- Mobiel menu ----------
  function menu() {
    var knop = document.querySelector('.menu-knop');
    var lijst = document.getElementById('menu');
    if (!knop || !lijst) return;
    knop.addEventListener('click', function () {
      var open = knop.getAttribute('aria-expanded') === 'true';
      knop.setAttribute('aria-expanded', String(!open));
      lijst.classList.toggle('open', !open);
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && lijst.classList.contains('open')) {
        knop.setAttribute('aria-expanded', 'false');
        lijst.classList.remove('open');
        knop.focus();
      }
    });
  }

  // ---------- Carrousel met activiteiten ----------
  function carrousel() {
    var c = document.querySelector('.carrousel');
    if (!c) return;
    var track = c.querySelector('.track');
    var slides = Array.prototype.slice.call(track.children);
    var dots = c.querySelector('.dots');
    var pijlen = document.querySelector('.pijlen');
    var rustig = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var i = 0;
    var timer = null;
    var INTERVAL = 5000;

    function stap() {
      if (slides.length < 2) return track.clientWidth;
      return slides[1].offsetLeft - slides[0].offsetLeft;
    }
    function perScherm() { return Math.max(1, Math.round(track.clientWidth / stap())); }
    function aantal() { return Math.max(1, slides.length - perScherm() + 1); }

    function teken() {
      var n = aantal();
      if (pijlen) pijlen.hidden = n < 2;
      dots.innerHTML = '';
      if (n < 2) return;
      for (var k = 0; k < n; k++) {
        var b = document.createElement('button');
        b.type = 'button';
        b.tabIndex = -1;
        if (k === i) b.className = 'actief';
        b.addEventListener('click', (function (k) { return function () { ga(k); herstart(); }; })(k));
        dots.appendChild(b);
      }
    }
    function ga(k) {
      var n = aantal();
      i = ((k % n) + n) % n;
      track.scrollTo({ left: i * stap(), behavior: rustig ? 'auto' : 'smooth' });
      teken();
    }
    function stop() { if (timer) { clearInterval(timer); timer = null; } }
    function herstart() {
      stop();
      if (!rustig && aantal() > 1) timer = setInterval(function () { ga(i + 1); }, INTERVAL);
    }

    if (pijlen) {
      pijlen.querySelectorAll('button').forEach(function (b) {
        b.addEventListener('click', function () { ga(i + Number(b.getAttribute('data-richting'))); herstart(); });
      });
    }
    c.addEventListener('mouseenter', stop);
    c.addEventListener('mouseleave', herstart);
    c.addEventListener('focusin', stop);
    c.addEventListener('focusout', herstart);
    c.addEventListener('touchstart', stop, { passive: true });
    document.addEventListener('visibilitychange', function () { document.hidden ? stop() : herstart(); });

    var scrollTimer;
    track.addEventListener('scroll', function () {
      clearTimeout(scrollTimer);
      scrollTimer = setTimeout(function () {
        var n = Math.min(aantal() - 1, Math.round(track.scrollLeft / stap()));
        if (n !== i) { i = n; teken(); }
      }, 80);
    }, { passive: true });
    window.addEventListener('resize', function () { i = Math.min(i, aantal() - 1); teken(); });

    teken();
    herstart();
  }

  // ---------- Contactformulier ----------
  function formulier() {
    var form = document.getElementById('contactformulier');
    if (!form) return;
    var status = form.querySelector('.formulier-status');
    var knop = form.querySelector('button[type="submit"]');
    var tokenVeld = form.querySelector('input[name="token"]');
    var foutMail = 'Er ging iets mis bij het versturen. Probeer het later opnieuw of mail naar info@dorpsplatformteteringen.nl.';

    function meld(tekst, soort) {
      status.textContent = tekst;
      status.className = 'formulier-status ' + (soort || '');
    }
    function haalToken() {
      return fetch('/contact.php?token=1', { credentials: 'same-origin', cache: 'no-store' })
        .then(function (r) { return r.ok ? r.json() : null; })
        .then(function (j) { if (j && j.token) tokenVeld.value = j.token; })
        .catch(function () {});
    }
    haalToken();

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var naam = form.naam.value.trim();
      var email = form.email.value.trim();
      var bericht = form.bericht.value.trim();
      if (!naam || !email || !bericht) { meld('Vul je naam, e-mailadres en bericht in.', 'fout'); return; }
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { meld('Controleer je e-mailadres.', 'fout'); return; }

      knop.disabled = true;
      meld('Bezig met versturen…');
      fetch('/contact.php', { method: 'POST', body: new FormData(form), credentials: 'same-origin', headers: { Accept: 'application/json' } })
        .then(function (r) { return r.json().catch(function () { return { ok: false }; }); })
        .then(function (j) {
          if (j.ok) {
            form.reset();
            meld('Bedankt! Je bericht is verstuurd.', 'ok');
          } else {
            meld(j.melding || foutMail, 'fout');
          }
        })
        .catch(function () { meld(foutMail, 'fout'); })
        .then(function () { knop.disabled = false; haalToken(); });
    });
  }

  function start() { menu(); carrousel(); formulier(); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
