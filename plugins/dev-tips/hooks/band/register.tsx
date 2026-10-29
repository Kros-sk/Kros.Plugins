/**
 * Draws the tip above the prompt.
 *
 * On the desktop Code tab a SessionStart hook's `systemMessage` is accepted, stored as a
 * `hook_system_message` attachment and never drawn (anthropics/claude-code#75534), so the
 * only deterministic way to put a notice in front of someone there is to draw it from a
 * mod. That is decision D14; this is its renderer.
 *
 * It decides nothing. Show-DevTip.ps1 applies the cooldown, maxShows, the usage
 * suppression and the source ranking, and writes what it picked to a handshake file. This
 * reads that file, draws it, and writes the answer back.
 */
import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Answer } from '../../types'

const isOpen = atom({ plugin: 'dev-tips', key: 'isOpen' } as const, false)
const answeredId = atom({ plugin: 'dev-tips', key: 'answeredId' } as const, null)

/**
 * A rule rather than a tool: an ADR or a guideline. It is not run and nobody "already uses" it,
 * so the band asks about it in different words and records the answer without a suppression.
 */
/**
 * Which session this is.
 *
 * Asked of the engine rather than taken from `classic.SessionStart`: that event never reaches this
 * module - cc-plugin-sec-default hooks it first and sends it on past us - so the hook sat there
 * doing nothing and the engine reported it skipped to everybody who installed the plugin. Asking
 * is also the only way the handshake's session key has ever actually been read. See D19.
 */
async function sessionId($: any) {
  try {
    return await $.session.id()
  } catch {
    return null
  }
}

/**
 * Whether a handshake picked in one place belongs to the session drawing it.
 *
 * Not an equality: the hook writes the git top level and the session names the folder it was
 * opened on, which is often a folder inside it - a plugin's own directory in a monorepo, say. One
 * containing the other is the same project. Unknown on either side means yes, since refusing on
 * what we do not know would hide tips rather than misplace them.
 */
function sameProject(theirs?: string | null, ours?: string | null) {
  if (!theirs || !ours) return true

  const tidy = (p: string) => p.split('\\').join('/').replace(/\/+$/, '').toLowerCase()
  const a = tidy(theirs)
  const b = tidy(ours)

  return a === b || a.startsWith(`${b}/`) || b.startsWith(`${a}/`)
}

/**
 * The repository this session is in, or null where it cannot be had.
 *
 * Caught, not left to throw: a failing call here would skip the whole render hook and the band
 * would vanish without a word - the silent failure this plugin has already been bitten by twice.
 * Not knowing means drawing the tip, which is the harmless direction.
 */
async function sessionRoot($: any) {
  try {
    return await $.session.root()
  } catch {
    return null
  }
}

/**
 * Where the document actually is.
 *
 * An ADR lives in the mirror under the state directory. A guideline is relative to the repository
 * it was picked in - which is not necessarily the one on screen: the band reaches most handshakes
 * through its machine-wide fallback, because the classic.SessionStart that would key them by
 * session never reaches this module. Saying "in this repository" was true only by luck.
 */
function documentPath(pending: Pending) {
  if (pending.kind === 'adr') return `${pending.stateDir}/adr/${pending.ref}`
  if (pending.repoRoot) return `${pending.repoRoot}/${pending.ref}`

  return pending.ref ?? pending.title
}

function isDocument(pending: Pending) {
  return pending.kind === 'adr' || pending.kind === 'guideline'
}

type Pending = {
  id: string
  kind: string
  title: string
  body: string
  ref: string | null
  url: string | null
  installState: string
  stateDir: string
  /** The whole document, for a notice whose body is only its opening. Absent for everything else. */
  full?: string | null
  /** The repository the tip was picked in. A guideline's `ref` is relative to it. */
  repoRoot?: string | null
  /** Written by the band the first time this handshake is drawn. */
  shownAt?: string
}

/**
 * The handshake this load drew.
 *
 * A file is marked `shownAt` the first time it is drawn, and the fallback below then leaves
 * it alone. Without the mark the fallback kept handing the newest file on the machine to
 * every session that had no id of its own - and since the cooldown writes no new handshake
 * for days, "newest" stayed the same file and the same tip came back session after session.
 *
 * This load keeps redrawing the one it drew, which the mark would otherwise end mid-session.
 * Per load on purpose: a reload is a fresh start, and the mark on disk decides from there.
 */
let owned: string | null = null

/**
 * Takes the handshake for this load and leaves the mark that says it was delivered.
 *
 * A failed write must not cost the draw: the tip is on screen either way, and an unmarked
 * file is offered once more, which is the harmless direction to fail in.
 */
async function claim($: any, path: string, found: Pending) {
  owned = path

  if (!found.shownAt) {
    try {
      await $.fs.write(path, JSON.stringify({ ...found, shownAt: new Date().toISOString() }, null, 2))
    } catch {
      // Left unmarked on purpose; see above.
    }
  }

  return found
}

/**
 * The handshake path. A module never receives CLAUDE_PLUGIN_DATA - the engine sets it for
 * hook processes - and the real data directory is named after the marketplace that
 * installed us, which a module has no way to learn. So both sides spell a fixed path, and
 * the session id keys it so two sessions starting together do not read each other's tip.
 */
async function readPending($: any, id: string | null) {
  const home = (await $.env.get('USERPROFILE')) ?? (await $.env.get('HOME'))
  if (!home) return null

  const dir = `${home}/.claude/plugins/data/dev-tips-shared`

  if (id) {
    const path = `${dir}/pending-${id}.json`
    try {
      const found = JSON.parse(await $.fs.read(path)) as Pending

      // Delivered already, and not by this load: the same rule the fallback keeps. Before the
      // session key was ever read this branch could not run, so the mark guarded everything by
      // accident; once it did run, the same tip came back on every reload until it was answered
      // again - six answers in one afternoon for two tips the hook had picked once.
      if (found.shownAt && owned !== path) return null

      return { found, path }
    } catch {
      return null
    }
  }

  // No id means this module loaded after the session started - a reload, or the plugin
  // installed mid-session. Rather than stay blank until tomorrow, take the newest handshake
  // on the machine: it is a tip meant for this person either way.
  try {
    const entries = await $.fs.list(dir)
    const newest = entries
      .filter(entry => entry.name.startsWith('pending-'))
      .sort((a, b) => b.mtimeMs - a.mtimeMs)[0]
    if (!newest) return null

    const path = `${dir}/${newest.name}`
    const found = JSON.parse(await $.fs.read(path)) as Pending

    // Somebody has already been shown this one. Only the load that drew it keeps drawing it.
    if (found.shownAt && owned !== path) return null

    return { found, path }
  } catch {
    return null
  }
}

/**
 * Records the press and, for `known`, the suppression itself.
 *
 * `usage.json` is the file Test-AlreadyUsed reads, so pressing "already use it" writes the
 * same signal Record-SkillUse.ps1 writes live and the transcript scan infers. That is the
 * point of the band: the inference becomes a statement.
 *
 * `$.fs` has no move, so these are written in place rather than temp-plus-move as the
 * PowerShell does. The window is small and both files are small; a torn read leaves
 * Read-JsonFile with null, which Test-AlreadyUsed reads as "not used" - the tip is offered
 * once more, which is the harmless direction to fail in.
 */
async function recordAnswer($: any, pending: Pending, answer: Answer) {
  const at = new Date().toISOString()

  try {
    let log = ''
    try { log = await $.fs.read(`${pending.stateDir}/answers.log`) } catch { log = '' }
    await $.fs.write(`${pending.stateDir}/answers.log`, `${log}${at} ${pending.id} ${answer}
`)
  } catch { /* a notice is never worth an error in front of someone */ }

  if (answer === 'show') {
    // The same call the engine makes for a typed prompt, so it becomes a turn of its own
    // once the session is idle. The model reads it as this plugin's, not as the person's.
    // A rule is read, not run. Asking how it is "used" is the wording D18 retired, and the
    // model cannot find the document either unless it is told where it is: an ADR lives in the
    // mirror under the state directory, a guideline in the repository the person is working in.
    const text = isDocument(pending)
      ? `Vysvetli mi, čo hovorí „${pending.title}" a čo to znamená pre moju prácu. Dokument je v ${documentPath(pending)}.`
      : `Ukáž mi, ako sa používa ${pending.ref ?? pending.title}, a na čo je to dobré.`

    // Caught, not voided: where nothing can take a prompt the press must still be recorded
    // and the band must stay standing.
    void $.prompt.submit({ text }).catch(() => undefined)
  }

  // Usage suppression answers "do not offer me a tool I already run". A rule has nothing to run,
  // and maxShows: 1 already keeps it from coming back.
  if (answer !== 'known' || isDocument(pending)) return

  try {
    let usage: Record<string, string> = {}
    try { usage = JSON.parse(await $.fs.read(`${pending.stateDir}/usage.json`)) } catch { usage = {} }

    // A live record wins, as Merge-UsageFile has it: write only what is absent.
    if (usage[pending.id] === undefined) {
      usage[pending.id] = at
      await $.fs.write(`${pending.stateDir}/usage.json`, JSON.stringify(usage, null, 2))
    }
  } catch { /* as above */ }
}

export const register: Register = on => {
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const beneath = await next(e)
    // The handshake and where it lives: the path is needed to mark it, once it is clear it will
    // actually be drawn.
    const held = await readPending($, await sessionId($))
    if (held === null) return beneath

    const pending = held.found

    // Picked for a different repository, so not this person's to see here. The fallback that found
    // it is machine-wide - it has to be, since classic.SessionStart never reaches this module - and
    // a rule that belongs to another project is noise at best and wrong at worst. A handshake
    // written before the repository was recorded carries none, and is drawn as it always was.
    const here = await sessionRoot($)
    if (!sameProject(pending.repoRoot, here)) return beneath

    // Claimed only now, with every refusal behind us. Marking it in readPending burned a tip that
    // was then refused: delivered according to the file, never seen by anybody.
    await claim($, held.path, pending)

    // Keyed by tip, not a flag: an answer must not silence the tip that comes after it.
    if ((await read($, answeredId)) === pending.id) return beneath

    const open = await read($, isOpen)
    // A rule is not a tool: same two presses, so answers stay comparable across kinds, but the
    // words have to be true of what is on screen.
    const doc = isDocument(pending)
    const { Box, Button, Link, Text } = $.ui.resolve(e)
    const choose = async (value: Answer) => {
      await update($, answeredId, () => pending.id)
      await recordAnswer($, pending, value)
    }

    return (
      <Box flexDirection="column">
        {/*
          The body stays out of this row. Sharing one narrows its column, and the terminal
          then wraps it inside that column while the row is one line tall, strewing the
          remainder across the title.
        */}
        <Box gap={1}>
          <Box flexGrow={1}>
            <Text>
              💡 <Text bold>{pending.title}</Text>
            </Text>
          </Box>
          <Box gap={1} flexShrink={0}>
            {!open && <Button key="open" label="Rozbaliť" hotkey="1" onPress={() => update($, isOpen, () => true)} />}
            {open && <Button key="close" label="Zbaliť" hotkey="1" onPress={() => update($, isOpen, () => false)} />}
            {/* U+00D7: one cell wide everywhere, unlike U+2715, which shifts the row. */}
            <Button key="drop" label="×" hotkey="2" onPress={() => choose('dropped')} />
          </Box>
        </Box>

        {/* Expanding a document that was announced from its opening shows the rest of it. For a
            skill, body and full say the same thing and the row is unchanged. */}
        <Text dimColor={!open}>{open && pending.full ? pending.full : pending.body}</Text>

        {pending.ref && pending.installState === 'installed' && (
          <Text dimColor>Spúšťa sa cez {pending.ref}.</Text>
        )}

        {open && (
          // A blank row above the answers: pressed against the body they read as part of the
          // sentence rather than as a question being put to the person.
          <Box gap={2} marginTop={1}>
            <Button key="show" label={doc ? 'Vysvetli mi to' : 'Ukáž ako'} hotkey="3" onPress={() => choose('show')} />
            <Button key="known" label={doc ? 'Poznám' : 'Už to používam'} hotkey="4" onPress={() => choose('known')} />
            {pending.url ? <Link href={pending.url} label="Dokumentácia" /> : null}
          </Box>
        )}

        {/* Only the terminal needs this: there a Button takes a click once its site holds
            the focus, and nothing on screen says so. */}
        {e.surface === 'terminal' && <Text dimColor>tab aktivuje ovládanie</Text>}

        {beneath}
      </Box>
    )
  })
}
