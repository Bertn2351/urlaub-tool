import Anthropic from 'npm:@anthropic-ai/sdk';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

/* ================= PDF-Text ohne KI auslesen ================= */

async function entpacken(bytes: Uint8Array): Promise<Uint8Array> {
  const strom = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate'));
  return new Uint8Array(await new Response(strom).arrayBuffer());
}

function entschluesseln(roh: string): string {
  return roh.replace(/\\(\d{1,3})/g, (_, o) => String.fromCharCode(parseInt(o, 8)))
            .replace(/\\([()\\])/g, '$1');
}

function lesbar(zeile: string): boolean {
  return /^[\x20-\x7E -ɏ\s]+$/.test(zeile) && /[A-Za-z0-9]/.test(zeile);
}

// Liest echte Textzeilen: Zeichenketten werden gesammelt, die Positionierungsbefehle
// der PDF (Td, TD, T*, ') beenden jeweils eine Zeile. Dadurch bleiben Woerter
// zusammen, die die PDF intern in mehrere Stuecke zerlegt hat.
async function pdfZeilen(pdf: Uint8Array): Promise<string[]> {
  const latin = new TextDecoder('latin1').decode(pdf);
  const zeilen: string[] = [];
  const marke = /stream\r?\n/g;
  let treffer: RegExpExecArray | null;

  while ((treffer = marke.exec(latin)) !== null) {
    const start = treffer.index + treffer[0].length;
    let ende = latin.indexOf('endstream', start);
    if (ende < 0) continue;
    // Der Zeilenumbruch vor "endstream" gehoert nicht zu den Daten.
    // Der Entpacker in Deno bricht sonst mit "Muell nach den Daten" ab.
    while (ende > start && (latin[ende - 1] === '\n' || latin[ende - 1] === '\r')) ende--;

    let inhalt: string;
    try {
      inhalt = new TextDecoder('latin1').decode(await entpacken(pdf.slice(start, ende)));
    } catch {
      continue;
    }

    let aktuell = '';
    for (const m of inhalt.matchAll(/\(((?:\\.|[^\\()])*)\)|(Td|TD|T\*|ET|'|")/g)) {
      if (m[1] !== undefined) {
        aktuell += entschluesseln(m[1]);
      } else {
        const fertig = aktuell.trim();
        if (fertig && lesbar(fertig)) zeilen.push(fertig);
        aktuell = '';
      }
    }
    const rest = aktuell.trim();
    if (rest && lesbar(rest)) zeilen.push(rest);
  }
  return zeilen;
}

/* ================= ÖGK-Formular nach festen Regeln ================= */

function datumIso(deutsch: string | undefined): string {
  if (!deutsch) return '';
  const m = deutsch.match(/(\d{1,2})\.(\d{1,2})\.(\d{4})/);
  return m ? `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}` : '';
}

function schoenerName(roh: string): string {
  return roh.trim().toLowerCase().replace(/(^|[\s\-])(\p{L})/gu, (_, v, b) => v + b.toUpperCase());
}

function geburtstagAusSvnr(svnr: string): string {
  const z = String(svnr).replace(/\D/g, '');
  if (z.length < 10) return '';
  const tag = z.slice(-6, -4), monat = z.slice(-4, -2), jj = Number(z.slice(-2));
  if (Number(tag) < 1 || Number(tag) > 31 || Number(monat) < 1 || Number(monat) > 12) return '';
  const jahrhundert = 2000 + jj > new Date().getFullYear() ? 1900 : 2000;
  return `${jahrhundert + jj}-${monat}-${tag}`;
}

function oegkLesen(zeilen: string[]) {
  const text = zeilen.join('\n');
  if (!/VSNR/i.test(text) || !/Besch(ae|ä)ftigt ab/i.test(text)) return null;

  const svnr = text.match(/VSNR:?\s*(\d{10})/i)?.[1] ?? '';
  const eintritt = datumIso(text.match(/Besch(?:ae|ä)ftigt ab:?\s*(\d{1,2}\.\d{1,2}\.\d{4})/i)?.[1]);
  const stunden = (text.match(/Wochenarbeitszeit:?\s*([\d.,]+)/i)?.[1] ?? '').replace(',', '.');
  const bereich = text.match(/Besch\.?\s?Bereich:?\s*([A-ZÄÖÜ][A-ZÄÖÜa-zäöü]*)/i)?.[1] ?? '';
  const dienstnummer = text.match(/\bDN:?\s*(\d+)/)?.[1] ?? '';
  const geringfuegig = /Geringfuegig:?\s*JA/i.test(text);

  // Auf diesem Formular stehen Nachname und Vorname als eigene Zeilen direkt unter der VSNR.
  let nachname = '', vorname = '';
  const i = zeilen.findIndex((z) => /VSNR/i.test(z));
  if (i >= 0) {
    const namen = zeilen.slice(i + 1, i + 6).filter((z) => /^[A-ZÄÖÜ][A-ZÄÖÜ\s\-]{1,}$/.test(z.trim()));
    if (namen[0]) nachname = schoenerName(namen[0]);
    if (namen[1]) vorname = schoenerName(namen[1]);
  }

  const zahl = Number(stunden);
  const beschaeftigung = geringfuegig ? 'Geringfügig'
    : (zahl > 0 && zahl < 35) ? 'Teilzeit'
    : zahl >= 35 ? 'Vollzeit' : '';

  return {
    art: 'einstellung',
    dienstnummer, vorname, nachname,
    geburtsdatum: geburtstagAusSvnr(svnr),
    sv_nummer: svnr,
    staatsangehoerigkeit: '', adresse: '', telefon: '',
    taetigkeit: bereich ? schoenerName(bereich) : '',
    beschaeftigung,
    wochenstunden: stunden,
    datum_von: eintritt, datum_bis: '',
    sicherheit: 'hoch', hinweis: '',
    quelle: 'Direkt aus dem ÖGK-Formular gelesen – ohne KI',
  };
}

/* ================= Auffangnetz: KI ================= */

async function kiLesen(apiKey: string, dateiBase64: string, mediaType: string, rohtext: string) {
  const client = new Anthropic({ apiKey });
  const istPdf = mediaType === 'application/pdf';
  const dokument = istPdf
    ? { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: dateiBase64 } }
    : { type: 'image', source: { type: 'base64', media_type: mediaType, data: dateiBase64 } };

  const anweisung = [
    'Das ist ein Personal-Dokument einer oesterreichischen Firma: eine Anmeldung zur Sozialversicherung,',
    'eine Abmeldung oder Kuendigung, eine Krankmeldung oder ein Urlaubsantrag.',
    '',
    'Hinweise:',
    '- "DN" ist die Dienstnummer des Mitarbeiters.',
    '- "VSNR" ist die Sozialversicherungsnummer; ihre letzten sechs Ziffern sind das Geburtsdatum TTMMJJ.',
    '- Namen stehen oft als Nachname zuerst, dann Vorname. Schreibe sie normal, nicht in Grossbuchstaben.',
    '- "Beschaeftigt ab" ist das Eintrittsdatum, "Wochenarbeitszeit" sind die Wochenstunden,',
    '  "Besch.Bereich" ist die Taetigkeit.',
    '- Beschaeftigungsart: "Geringfuegig: JA" heisst Geringfuegig, sonst unter 35 Wochenstunden Teilzeit, ab 35 Vollzeit.',
    '- Die firmeninterne Abteilung steht auf solchen Dokumenten normalerweise NICHT.',
    '  Rate sie niemals, sondern lass das Feld leer.',
    '',
    rohtext ? 'Aus der Datei gelesener Rohtext:\n' + rohtext.slice(0, 3000) + '\n' : '',
    'Antworte NUR mit JSON, ohne weiteren Text und ohne Markdown-Codeblock.',
    'Felder, die nicht im Dokument stehen, bleiben leer:',
    '{"art":"einstellung|kuendigung|krankmeldung|urlaubsantrag|unbekannt",',
    '"dienstnummer":"","vorname":"","nachname":"","geburtsdatum":"JJJJ-MM-TT","sv_nummer":"",',
    '"staatsangehoerigkeit":"","adresse":"","telefon":"","taetigkeit":"",',
    '"beschaeftigung":"Vollzeit|Teilzeit|Geringfuegig|","wochenstunden":"",',
    '"datum_von":"JJJJ-MM-TT","datum_bis":"JJJJ-MM-TT",',
    '"weitere_felder":{},',
    '"sicherheit":"hoch|mittel|niedrig","hinweis":"kurze Begruendung falls unsicher"}',
    '',
    'Wichtig zu "weitere_felder": Trage dort JEDE weitere beschriftete Angabe ein, die du im',
    'Dokument findest und die oben keinen eigenen Platz hat – als Paare aus Beschriftung und Wert,',
    'zum Beispiel {"Protokollnr":"19843051","Beitrags-KtoNr":"777527029","Uebersender":"I-TAX"}.',
    'Lass nichts Beschriftetes aus. Diese Angaben werden gesammelt, um das Dokument spaeter',
    'ohne KI auslesen zu koennen.',
  ].filter(Boolean).join('\n');

  const antwort = await client.messages.create({
    model: 'claude-haiku-4-5',
    max_tokens: 1024,
    messages: [{ role: 'user', content: [dokument, { type: 'text', text: anweisung }] }],
  });

  const block = antwort.content.find((b: any) => b.type === 'text');
  let roh = (block?.text || '{}').trim();
  roh = roh.replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/i, '').trim();

  try {
    const ergebnis = JSON.parse(roh);
    ergebnis.quelle = 'Von der KI gelesen';
    // Die SV-Nummer enthaelt das Geburtsdatum. Das ist eine feste Rechenregel und
    // damit verlaesslicher als jede Erkennung - sie hat hier immer Vorrang.
    if (ergebnis.sv_nummer) {
      const abgeleitet = geburtstagAusSvnr(String(ergebnis.sv_nummer));
      if (abgeleitet && abgeleitet !== ergebnis.geburtsdatum) {
        ergebnis.geburtsdatum = abgeleitet;
        ergebnis.quelle += ', Geburtsdatum aus der SV-Nummer berechnet';
      }
    }
    return ergebnis;
  } catch {
    return { art: 'unbekannt', hinweis: 'Antwort konnte nicht gelesen werden: ' + roh, quelle: 'Von der KI gelesen' };
  }
}

/* ================= Ablauf ================= */

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  try {
    const { dateiBase64, mediaType } = await req.json();

    let zeilen: string[] = [];
    if (mediaType === 'application/pdf') {
      try {
        const bytes = Uint8Array.from(atob(dateiBase64), (c) => c.charCodeAt(0));
        zeilen = await pdfZeilen(bytes);
      } catch { /* dann eben ohne Rohtext weiter */ }
    }

    // Der Rohtext wird immer mitgeschickt: aus ihm lassen sich spaeter feste
    // Leseregeln je Formulartyp ableiten, damit die KI entfallen kann.
    const rohtext = zeilen.join('\n').slice(0, 8000);

    const direkt = zeilen.length ? oegkLesen(zeilen) : null;
    if (direkt) return json({ ...direkt, rohtext });

    const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
    if (!apiKey) return json({ error: 'ANTHROPIC_API_KEY fehlt als Secret' }, 500);
    const ergebnis = await kiLesen(apiKey, dateiBase64, mediaType, rohtext);
    return json({ ...ergebnis, rohtext });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
