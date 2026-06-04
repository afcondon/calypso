// deal.mjs — deal a specific genre straight to the rig, no card draw.
//
//   node scripts/deal.mjs <genre> [seed]
//   node scripts/deal.mjs            # lists known genres
//
// Reuses the compiled lowering: samples the genre prior (Arcana
// `sampleGenre`), lowers it to a Calypso.Generated.Session module
// (`manifestToModule`), then drives the calypso-server exactly as the
// Tarot pane's "deal" does — minus the randomness:
//   1. take the edit Pen over the WS (force; the human's tab yields it),
//   2. POST the module to /session-source (write → purs → backend-erl →
//      erlc → reload-baseline on the BEAM),
//   3. fire stop-piece / hush / bpm / play-piece over /eval,
//   4. yield the Pen.
// For bring-up / iteration only. Needs the calypso-server (:3060) up.

import * as G from '../output/Generate.Genre/index.js'
import * as Lower from '../output/Calypso.Frontend.Tarot.Lower/index.js'

import { house } from '../output/Generate.Genres.House/index.js'
import { goa } from '../output/Generate.Genres.Goa/index.js'
import { dubTechno } from '../output/Generate.Genres.DubTechno/index.js'
import { glass } from '../output/Generate.Genres.Glass/index.js'
import { webern } from '../output/Generate.Genres.Webern/index.js'
import { part } from '../output/Generate.Genres.Part/index.js'
import { dembow } from '../output/Generate.Genres.Dembow/index.js'
import { rawDnB } from '../output/Generate.Genres.RawDnB/index.js'
import { deepTechHouse } from '../output/Generate.Genres.DeepTechHouse/index.js'
import { incessantDnB } from '../output/Generate.Genres.IncessantDnB/index.js'
import { subzeroTechno } from '../output/Generate.Genres.SubzeroTechno/index.js'
import { miles } from '../output/Generate.Genres.Miles/index.js'
import { makuta } from '../output/Generate.Genres.Makuta/index.js'
import { gaga } from '../output/Generate.Genres.Gaga/index.js'
import { son23 } from '../output/Generate.Genres.Son23/index.js'
import { sonKick23 } from '../output/Generate.Genres.SonKick23/index.js'
import { guaguanco1 } from '../output/Generate.Genres.Guaguanco1/index.js'
import { bembe4 } from '../output/Generate.Genres.Bembe4/index.js'

const REGISTRY = {
  house, goa, dubTechno, glass, webern, part, dembow,
  rawDnB, deepTechHouse, incessantDnB, subzeroTechno, miles,
  makuta, gaga, son23, sonKick23, guaguanco1, bembe4,
}

const BACKEND = process.env.CALYPSO_BACKEND || 'http://localhost:3060'
const WS_URL = (process.env.CALYPSO_BACKEND || 'http://localhost:3060')
  .replace(/^http/, 'ws') + '/session/ws'

const name = process.argv[2]
const seed = Number.parseInt(process.argv[3] ?? '0', 10)

if (!name || !REGISTRY[name]) {
  if (name) console.error(`unknown genre: ${name}\n`)
  console.error('usage: node scripts/deal.mjs <genre> [seed]')
  console.error('genres: ' + Object.keys(REGISTRY).join(', '))
  process.exit(name ? 1 : 0)
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// Connect, grab the Pen (force takes it from a released/idle holder), and
// return { sid, close }.  The WS stays open while we build + play so the
// holder identity is live, then we yield + close.
function takePen() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS_URL)
    let sid = null
    const t = setTimeout(() => reject(new Error('timed out waiting for pen grant')), 8000)
    ws.addEventListener('message', (ev) => {
      let m; try { m = JSON.parse(ev.data) } catch { return }
      if (m.type === 'welcome') {
        sid = m.yourId
        ws.send(JSON.stringify({ type: 'force-pen' }))
      } else if (m.type === 'pen' && m.pen && m.pen.holder === sid) {
        clearTimeout(t)
        resolve({
          sid,
          close: () => { try { ws.send(JSON.stringify({ type: 'yield-pen' })) } catch {} ws.close() },
        })
      }
    })
    ws.addEventListener('error', (e) => { clearTimeout(t); reject(new Error('ws error: ' + (e.message || e))) })
  })
}

async function post(path, source, sid) {
  const res = await fetch(BACKEND + path, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'X-Atelier-Subscriber-Id': sid },
    body: JSON.stringify({ source }),
  })
  return { status: res.status, text: await res.text() }
}

const genre = REGISTRY[name]
const manifest = G.sampleGenre(genre)(seed)
const src = Lower.manifestToModule(manifest)
const bpm = manifest.tempo.bpm

console.log(`dealing "${name}" (seed ${seed}, ${bpm} bpm, ${manifest.voices.length} voices)`)

const pen = await takePen()
console.log(`✓ pen held (${pen.sid.slice(0, 8)}…)`)

try {
  const build = await post('/session-source', src, pen.sid)
  if (build.status !== 200) { console.error(`✗ /session-source ${build.status}: ${build.text}`); process.exit(1) }
  let reply; try { reply = JSON.parse(build.text) } catch { reply = null }
  if (reply && reply.ok === false) {
    console.error(`✗ build failed: ${reply.error || reply.reply}`)
    if (reply.pursErrorsJson) console.error(reply.pursErrorsJson)
    process.exit(1)
  }
  console.log('✓ built + loaded')

  for (const verb of ['stop-piece', 'hush', `bpm ${bpm}`, 'play-piece piece']) {
    const r = await post('/eval', verb, pen.sid)
    console.log(`  ${verb}  →  ${r.status === 200 ? r.text : 'HTTP ' + r.status}`)
  }
  console.log('▶ playing.  (hush / stop-piece to stop.)')
} finally {
  pen.close()
}
