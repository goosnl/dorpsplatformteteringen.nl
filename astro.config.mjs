// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://dorpsplatformteteringen.nl',
  trailingSlash: 'never',
  build: {
    // /activiteiten -> activiteiten.html, /dorpsmaaltijd-2026.htm -> dorpsmaaltijd-2026.htm.html
    format: 'file',
    // Geen inline CSS, zodat een strenge Content-Security-Policy mogelijk is
    inlineStylesheets: 'never',
  },
  vite: {
    // Nooit bestanden als data:-URL inbakken (houdt de Content-Security-Policy streng)
    build: { assetsInlineLimit: 0 },
  },
  integrations: [sitemap()],
});
