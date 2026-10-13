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

const sessionId = atom({ plugin: 'dev-tips', key: 'sessionId' } as const, null)
const isOpen = atom({ plugin: 'dev-tips', key: 'isOpen' } as const, false)
const answeredId = atom({ plugin: 'dev-tips', key: 'answeredId' } as const, null)

type Pending = {
  id: string
  kind: string
  title: string
  body: string
  ref: string | null
  url: string | null
  installState: string
  stateDir: string
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
    try {
      return JSON.parse(await $.fs.read(`${dir}/pending-${id}.json`)) as Pending
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

    return JSON.parse(await $.fs.read(`${dir}/${newest.name}`)) as Pending
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
    const what = pending.ref ?? pending.title
    // Caught, not voided: where nothing can take a prompt the press must still be recorded
    // and the band must stay standing.
    void $.prompt
      .submit({ text: `Ukáž mi, ako sa používa ${what}, a na čo je to dobré.` })
      .catch(() => undefined)
  }

  if (answer !== 'known') return

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
  on('classic.SessionStart', async ($, e, next) => {
    // The same payload the PowerShell hook reads, so both name the handshake file alike.
    if (e.session_id) {
      await update($, sessionId, () => e.session_id)
    }

    return next(e)
  }).catch(($, e, next) => {
    // This hook gates the start of a session. A tip is never worth delaying one, so a
    // failure here hands the event on untouched and the band simply has no id to use.
    if (next.called) return undefined

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const beneath = await next(e)
    const pending = await readPending($, await read($, sessionId))
    if (pending === null) return beneath

    // Keyed by tip, not a flag: an answer must not silence the tip that comes after it.
    if ((await read($, answeredId)) === pending.id) return beneath

    const open = await read($, isOpen)
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

        <Text dimColor={!open}>{pending.body}</Text>

        {pending.ref && pending.installState === 'installed' && (
          <Text dimColor>Spúšťa sa cez {pending.ref}.</Text>
        )}

        {open && (
          <Box gap={2}>
            <Button key="show" label="Ukáž ako" hotkey="3" onPress={() => choose('show')} />
            <Button key="known" label="Už to používam" hotkey="4" onPress={() => choose('known')} />
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
