import Anthropic from 'npm:@anthropic-ai/sdk';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  try {
    const { dateiBase64, mediaType } = await req.json();
    const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
    if (!apiKey) {
      return new Response(JSON.stringify({ error: 'ANTHROPIC_API_KEY fehlt als Secret' }), {
        status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const client = new Anthropic({ apiKey });
    const isPdf = mediaType === 'application/pdf';
    const docBlock = isPdf
      ? { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: dateiBase64 } }
      : { type: 'image', source: { type: 'base64', media_type: mediaType, data: dateiBase64 } };

    const anweisung = [
      'Das ist ein Personal-Dokument einer oesterreichischen Firma: eine Anmeldung zur Sozialversicherung (OEGK),',
      'eine Abmeldung/Kuendigung, eine Krankmeldung oder ein Urlaubsantrag.',
      '',
      'Lies alle Felder aus, die vorhanden sind. Wichtige Hinweise:',
      '- "DN" oder "DN:" ist die Dienstnummer des Mitarbeiters.',
      '- "VSNR" ist die Sozialversicherungsnummer. Ihre letzten sechs Ziffern sind das Geburtsdatum TTMMJJ.',
      '  Beispiel: VSNR 7378050976 bedeutet geboren am 05.09.1976.',
      '- Namen stehen oft als Nachname zuerst, dann Vorname (z.B. "YILDIRIN" in einer Zeile, "BEDRETTIN" in der naechsten).',
      '  Ordne Vorname und Nachname richtig zu und schreibe sie in normaler Schreibweise, nicht in Grossbuchstaben.',
      '- "Beschaeftigt ab" ist das Eintrittsdatum.',
      '- "Wochenarbeitszeit" sind die Wochenstunden.',
      '- "Besch.Bereich" ist die Taetigkeit (z.B. ARBEITER, ANGESTELLTER).',
      '- Beschaeftigungsart: "Geringfuegig: JA" bedeutet Geringfuegig.',
      '  Sonst gilt: weniger als 35 Wochenstunden = Teilzeit, ab 35 = Vollzeit.',
      '',
      'Antworte NUR mit JSON, exakt in diesem Format, ohne weiteren Text und ohne Markdown-Codeblock.',
      'Felder, die im Dokument nicht vorkommen, bleiben leere Zeichenketten:',
      '{"art":"einstellung|kuendigung|krankmeldung|urlaubsantrag|unbekannt",',
      '"dienstnummer":"","vorname":"","nachname":"","geburtsdatum":"JJJJ-MM-TT","sv_nummer":"",',
      '"staatsangehoerigkeit":"","adresse":"","telefon":"","taetigkeit":"",',
      '"beschaeftigung":"Vollzeit|Teilzeit|Geringfuegig|","wochenstunden":"",',
      '"datum_von":"JJJJ-MM-TT","datum_bis":"JJJJ-MM-TT",',
      '"sicherheit":"hoch|mittel|niedrig","hinweis":"kurze Begruendung falls unsicher"}',
    ].join('\n');

    const message = await client.messages.create({
      model: 'claude-haiku-4-5',
      max_tokens: 1024,
      messages: [{ role: 'user', content: [docBlock, { type: 'text', text: anweisung }] }],
    });

    const textBlock = message.content.find((b: any) => b.type === 'text');
    let rohtext = (textBlock?.text || '{}').trim();
    rohtext = rohtext.replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/i, '').trim();

    let ergebnis: Record<string, unknown>;
    try {
      ergebnis = JSON.parse(rohtext);
    } catch {
      ergebnis = { art: 'unbekannt', hinweis: 'Antwort konnte nicht gelesen werden: ' + rohtext };
    }

    // Sicherheitsnetz: Geburtsdatum aus der Sozialversicherungsnummer ableiten,
    // falls die Erkennung es nicht gefunden hat.
    const svZiffern = String(ergebnis.sv_nummer || '').replace(/\D/g, '');
    if (!ergebnis.geburtsdatum && svZiffern.length >= 10) {
      const tt = svZiffern.slice(-6, -4);
      const mm = svZiffern.slice(-4, -2);
      const jj = Number(svZiffern.slice(-2));
      const jahrhundert = 2000 + jj > new Date().getFullYear() ? 1900 : 2000;
      const tag = Number(tt), monat = Number(mm);
      if (tag >= 1 && tag <= 31 && monat >= 1 && monat <= 12) {
        ergebnis.geburtsdatum = `${jahrhundert + jj}-${mm}-${tt}`;
        ergebnis.geburtsdatum_quelle = 'aus SV-Nummer abgeleitet';
      }
    }

    return new Response(JSON.stringify(ergebnis), {
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }
});
