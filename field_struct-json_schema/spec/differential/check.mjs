// The JavaScript half of the differential check (see results.rb): every
// pattern pattern_for emits must compile under the `u` flag (what JSON
// Schema 2020-12 and Ajv use) and match exactly the samples Ruby matches.
// Reads results.rb's JSON on stdin; exits 1 on any compile error or mismatch,
// or when too few patterns were translated to have checked anything: a
// pattern_for that gave up on everything would otherwise pass.
import { readFileSync } from 'node:fs';

// The corpus translates 352 Regexps today; well below that means pattern_for
// stopped translating, not that the corpus shrank. Raise it with the corpus.
const MIN_TRANSLATED = 300;

const { ruby, cases } = JSON.parse(readFileSync(0, 'utf8'));
const counts = { translated: 0, untranslated: 0, 'ruby-rejects': 0 };
let samples = 0;
const problems = [];

for (const c of cases) {
  counts[c.status] += 1;
  if (c.status !== 'translated') continue;

  const label = `${JSON.stringify(c.src)}/${c.flags} -> ${JSON.stringify(c.pattern)}`;
  let regexp;
  try {
    regexp = new RegExp(c.pattern, 'u');
  } catch (error) {
    problems.push(`COMPILE ERROR ${label}: ${error.message}`);
    continue;
  }
  for (const [sample, rubyMatches] of c.samples) {
    samples += 1;
    if (regexp.test(sample) !== rubyMatches) {
      problems.push(`MISMATCH ${label}: ${JSON.stringify(sample)} ruby=${rubyMatches} js=${!rubyMatches}`);
    }
  }
}

if (counts.translated < MIN_TRANSLATED) {
  problems.push(`ONLY ${counts.translated} Regexps translated (expected at least ${MIN_TRANSLATED}): pattern_for stopped translating, or the corpus is missing`);
}

for (const problem of problems) console.log(problem);
console.log(
  `Ruby ${ruby}, Node ${process.versions.node}: ${cases.length} Regexps, ${counts.translated} translated ` +
  `(${samples} samples compared), ${counts.untranslated} left untranslated, ${counts['ruby-rejects']} rejected by Ruby; ` +
  `${problems.length} problem(s)`
);
process.exit(problems.length === 0 ? 0 : 1);
