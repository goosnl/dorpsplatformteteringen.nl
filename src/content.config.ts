import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';

const berichten = defineCollection({
  // Bestanden die met _ beginnen worden overgeslagen (handig voor concepten)
  loader: glob({ pattern: '**/[^_]*.md', base: './src/content/berichten' }),
  schema: ({ image }) =>
    z.object({
      titel: z.string(),
      categorie: z.enum(['agenda', 'subsidies']),
      gepubliceerd: z.coerce.date(),
      samenvatting: z.string(),
      /** Echte datum (JJJJ-MM-DD), gebruikt voor de volgorde. Leeg laten als de datum nog niet bekend is. */
      datum: z.coerce.date().optional(),
      /** Zoals de datum op de site getoond wordt, bijv. "maandag 27 april 2026" */
      datumTekst: z.string().optional(),
      tijd: z.string().optional(),
      locatie: z.string().optional(),
      afbeelding: image().optional(),
      galerij: z.array(image()).optional(),
      downloads: z.array(z.object({ tekst: z.string(), bestand: z.string() })).optional(),
      verborgen: z.boolean().default(false),
    }),
});

export const collections = { berichten };
