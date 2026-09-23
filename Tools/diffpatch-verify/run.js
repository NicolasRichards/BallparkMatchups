const fs = require('fs');
const path = require('path');
const mine = require('./algorithm-port');

// The fixtures and the cross-check implementation come from AlecM33/mlb-gameday-bot,
// which is GPL-3.0. Nothing from it is vendored here — see README.md. Clone it
// next to this directory before running:
//   git clone --depth 1 https://github.com/AlecM33/mlb-gameday-bot ./reference
const REF = path.join(__dirname, 'reference');
if (!fs.existsSync(REF)) {
  console.error('Missing fixtures. Run:\n  git clone --depth 1 ' +
    'https://github.com/AlecM33/mlb-gameday-bot ' + REF);
  process.exit(2);
}
const theirs = require(path.join(REF, 'modules/diff-patch'));

const DATA = path.join(REF, 'spec/data');
const load = f => JSON.parse(fs.readFileSync(path.join(DATA, f)));
const clone = o => JSON.parse(JSON.stringify(o));

let failures = 0;
function check(name, cond, detail) {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : '\n      ' + detail}`);
  if (!cond) failures++;
}

for (const [feedFile, diffFile] of [
  ['live-feed-no-move.json', 'diff-patch-no-move.json'],
  ['live-feed-with-move.json', 'diff-patch-with-move.json'],
]) {
  const patches = load(diffFile);
  const list = Array.isArray(patches) ? patches : [patches];

  const a = load(feedFile);   // mine
  const b = load(feedFile);   // theirs

  let mineErr = null;
  try { for (const p of list) mine.apply(a, p.diff); }
  catch (e) { mineErr = e; }

  let theirErr = null;
  try { for (const p of list) theirs.hydrate(b, p); }
  catch (e) { theirErr = e; }

  check(`${diffFile}: mine applied without error`, mineErr === null, mineErr && mineErr.message);
  check(`${diffFile}: reference applied without error`, theirErr === null, theirErr && theirErr.message);

  if (!mineErr && !theirErr) {
    const sa = JSON.stringify(a), sb = JSON.stringify(b);
    check(`${diffFile}: my result === reference result`, sa === sb,
      firstDivergence(a, b));
  }
}

// Assertions transcribed from the reference project's own spec file.
{
  const feed = load('live-feed-no-move.json');
  const diff = load('diff-patch-no-move.json');
  mine.apply(feed, diff[0].diff);
  check('spec: metaData.timeStamp replaced',
    feed.metaData.timeStamp === '20240612_041302', feed.metaData.timeStamp);
  check('spec: gameEvents[0] === ball',
    feed.metaData.gameEvents[0] === 'ball', feed.metaData.gameEvents[0]);
  check('spec: logicalEvents[0] === countChange (add)',
    feed.metaData.logicalEvents[0] === 'countChange', feed.metaData.logicalEvents[0]);
  check('spec: logicalEvents[1] === count12 (sequential add)',
    feed.metaData.logicalEvents[1] === 'count12', feed.metaData.logicalEvents[1]);
  const r = feed.liveData.plays.allPlays[61].result;
  check('spec: result.event removed', !('event' in r), Object.keys(r).join(','));
  check('spec: result.eventType removed', !('eventType' in r), Object.keys(r).join(','));
  check('spec: result.description removed', !('description' in r), Object.keys(r).join(','));
  check('spec: allPlays[61].about.endTime replaced',
    feed.liveData.plays.allPlays[61].about.endTime === '2024-06-12T04:13:02.349Z',
    feed.liveData.plays.allPlays[61].about.endTime);
  check('spec: copy op landed',
    feed.liveData.plays.allPlays[61].pitchIndex[2] ===
      feed.liveData.boxscore.teams.home.teamStats.pitching.hits,
    `${feed.liveData.plays.allPlays[61].pitchIndex[2]} vs ${feed.liveData.boxscore.teams.home.teamStats.pitching.hits}`);
  check('spec: playEvents[3] appended with nested pitchData',
    feed.liveData.plays.allPlays[61].playEvents[3]?.pitchData?.endSpeed === 81.7,
    JSON.stringify(feed.liveData.plays.allPlays[61].playEvents[3]?.pitchData?.endSpeed));
}

// RFC 6901 escape handling — the reference's slash-to-dot split cannot express this.
{
  const doc = { 'a/b': 1, 'c~d': 2, 'plain': { 'x.y': 3 } };
  mine.apply(doc, [
    { op: 'replace', path: '/a~1b', value: 99 },
    { op: 'replace', path: '/c~0d', value: 98 },
    { op: 'replace', path: '/plain/x.y', value: 97 },
  ]);
  check('rfc6901: ~1 decodes to /', doc['a/b'] === 99, JSON.stringify(doc));
  check('rfc6901: ~0 decodes to ~', doc['c~d'] === 98, JSON.stringify(doc));
  check('rfc6901: literal dot in key survives', doc.plain['x.y'] === 97, JSON.stringify(doc));
}

// Auto-vivification of absent intermediate containers.
{
  const doc = {};
  mine.apply(doc, [{ op: 'add', path: '/liveData/plays/allPlays/0/result/rbi', value: 2 }]);
  check('vivify: builds object/array chain from nothing',
    doc.liveData.plays.allPlays[0].result.rbi === 2 && Array.isArray(doc.liveData.plays.allPlays),
    JSON.stringify(doc));
}

// A failed op must throw so the caller can full-refresh, not silently corrupt.
{
  let threw = false;
  try { mine.apply({ arr: [1, 2] }, [{ op: 'replace', path: '/arr/7', value: 0 }]); }
  catch (e) { threw = true; }
  check('safety: out-of-bounds replace throws', threw, 'did not throw');

  let threw2 = false;
  try { mine.apply({ a: 1 }, [{ op: 'remove', path: '/missing' }]); }
  catch (e) { threw2 = true; }
  check('safety: removing an absent key throws', threw2, 'did not throw');
}

function firstDivergence(a, b, p = '') {
  if (JSON.stringify(a) === JSON.stringify(b)) return '';
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    for (const k of keys) {
      const d = firstDivergence(a[k], b[k], p + '/' + k);
      if (d) return d;
    }
  }
  return `${p}: ${JSON.stringify(a)?.slice(0,120)} !== ${JSON.stringify(b)?.slice(0,120)}`;
}

console.log(failures === 0 ? '\nALL CHECKS PASSED' : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
