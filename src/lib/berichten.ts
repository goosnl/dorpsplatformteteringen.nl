import { getCollection, type CollectionEntry } from 'astro:content';

export type Bericht = CollectionEntry<'berichten'>;

export const berichtUrl = (b: Bericht) => `/${b.id}.htm`;

const vandaag = () => {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d;
};

/**
 * Activiteiten in een logische volgorde:
 * 1. komende activiteiten (eerstvolgende eerst)
 * 2. activiteiten zonder vaste datum
 * 3. geweest (meest recente eerst)
 */
export async function getActiviteiten() {
  const alle = await getCollection('berichten', (b) => b.data.categorie === 'agenda' && !b.data.verborgen);
  const nu = vandaag().getTime();
  const komend = alle.filter((b) => b.data.datum && b.data.datum.getTime() >= nu)
    .sort((a, b) => a.data.datum!.getTime() - b.data.datum!.getTime());
  const zonderDatum = alle.filter((b) => !b.data.datum)
    .sort((a, b) => b.data.gepubliceerd.getTime() - a.data.gepubliceerd.getTime());
  const geweest = alle.filter((b) => b.data.datum && b.data.datum.getTime() < nu)
    .sort((a, b) => b.data.datum!.getTime() - a.data.datum!.getTime());
  return { lijst: [...komend, ...zonderDatum, ...geweest], eerstvolgende: komend[0] };
}

export async function getSubsidieBerichten() {
  return (await getCollection('berichten', (b) => b.data.categorie === 'subsidies' && !b.data.verborgen))
    .sort((a, b) => b.data.gepubliceerd.getTime() - a.data.gepubliceerd.getTime());
}

const maanden = ['jan', 'feb', 'mrt', 'apr', 'mei', 'jun', 'jul', 'aug', 'sep', 'okt', 'nov', 'dec'];

/** Korte datum voor het datumlabel, bijv. { groot: '22', klein: 'aug' } */
export function datumLabel(b: Bericht) {
  if (b.data.datum) {
    return { groot: String(b.data.datum.getDate()), klein: maanden[b.data.datum.getMonth()] };
  }
  return { groot: b.data.datumTekst ?? '', klein: b.data.tijd ?? '' };
}
