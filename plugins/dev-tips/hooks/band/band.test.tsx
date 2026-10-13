import { expect, mock, test } from 'claude-code/testing'

const BAND = { component: 'AbovePrompt' as const, props: {} }
const HOME = 'C:/fake-home'
const SESSION = 'session-1'
const SHARED = `${HOME}/.claude/plugins/data/dev-tips-shared`

/** The engine normalises a path to the platform's separator before the event carries it. */
const normalise = (path: string) => path.split('\\').join('/')

const isPending = (path: string) => normalise(path) === `${SHARED}/pending-${SESSION}.json`

const TIP = {
  id: 'az-pr',
  kind: 'skill',
  title: '/kros-shared:az-pr',
  body: 'Creates an Azure DevOps pull request from the current branch.',
  ref: '/kros-shared:az-pr',
  url: null,
  installState: 'installed',
  stateDir: `${HOME}/.claude/plugins/data/dev-tips-local`,
}

/**
 * The engine beneath the plugin. Nothing stands under a test's hooks, so every event the
 * plugin hands on has to be answered here or the chain has no bottom.
 */
const engineBeneath = (on: any, options: { quiet?: boolean; beneath?: string } = {}) => {
  on('classic.SessionStart', () => ({}))
  if (!options.quiet) on('prompt.submit', (_$: unknown, e: { text: string }) => ({ text: e.text }))
  on('ui.render', { component: 'AbovePrompt' }, ($: any, e: any) => {
    const { Box, Text } = $.ui.resolve(e)

    return options.beneath ? <Text>{options.beneath}</Text> : <Box />
  })
}

/**
 * A session that has started and been handed a tip.
 *
 * The test environment has no filesystem on purpose, so the handshake is served by
 * answering the engine's own `fs.read` from beneath the plugin - which is also a tighter
 * assertion than a real file: it proves the module asks for the path both sides agreed on.
 */
const given = async ($: any, on: any, tip: unknown = TIP, options: { quiet?: boolean; beneath?: string } = {}) => {
  engineBeneath(on, options)
  mock.env(on, { USERPROFILE: HOME })

  on('fs.read', ($$: unknown, e: { path: string }) => {
    if (isPending(e.path)) {
      return { value: JSON.stringify(tip) }
    }

    throw new Error(`no such file: ${e.path}`)
  })

  await $.classic.SessionStart({ session_id: SESSION })
}

test('nothing was handed over, nothing is drawn', async ($, on) => {
  engineBeneath(on)
  mock.env(on, { USERPROFILE: HOME })
  await $.classic.SessionStart({ session_id: 'no-such-session' })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /💡/ })).toBeUndefined()

  await ui.unmount()
})

test('the handed-over tip is drawn, on every surface', async ($, on) => {
  await given($, on)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ plugin: 'dev-tips', surface, ...BAND })

    expect(await ui.find({ type: 'Text', text: /az-pr/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Creates an Azure DevOps/ })).toBeDefined()

    await ui.unmount()
  }
})

test('how to run it shows only once it is installed', async ($, on) => {
  await given($, on, { ...TIP, installState: 'marketplace-only' })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /Spúšťa sa cez/ })).toBeUndefined()

  await ui.unmount()
})

test('a tip with a document carries a link once opened', async ($, on) => {
  await given($, on, { ...TIP, url: 'https://example.invalid/doc.md' })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })

  expect(await ui.find({ type: 'Link' })).toBeDefined()

  await ui.unmount()
})

test('answering puts that tip away', async ($, on) => {
  await given($, on)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })
  await ui.press({ key: 'known' })

  expect(await ui.find({ type: 'Text', text: /az-pr/ })).toBeUndefined()

  await ui.unmount()
})

test('answering one tip does not silence the next one', async ($, on) => {
  engineBeneath(on)
  mock.env(on, { USERPROFILE: HOME })

  let served: unknown = TIP
  on('fs.read', ($$: unknown, e: { path: string }) => {
    if (isPending(e.path)) return { value: JSON.stringify(served) }

    throw new Error(`no such file: ${e.path}`)
  })
  await $.classic.SessionStart({ session_id: SESSION })

  const first = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await first.press({ key: 'drop' })
  await first.unmount()

  served = { ...TIP, id: 'teapie', title: '/teapie' }

  const second = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await second.find({ type: 'Text', text: /teapie/ })).toBeDefined()

  await second.unmount()
})

test('the focus hint shows on a terminal and nowhere else', async ($, on) => {
  await given($, on)

  const term = await $.ui.mount({ plugin: 'dev-tips', surface: 'terminal', ...BAND })
  expect(await term.find({ type: 'Text', text: /tab aktivuje/ })).toBeDefined()
  await term.unmount()

  const desk = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  expect(await desk.find({ type: 'Text', text: /tab aktivuje/ })).toBeUndefined()
  await desk.unmount()
})

/** Collects what the plugin writes, keyed by a path normalised like the engine's. */
const writesOf = (on: any) => {
  const writes: Record<string, string> = {}
  on('fs.write', (_$: unknown, e: { path: string; text: string }) => {
    writes[normalise(e.path)] = e.text

    return { value: undefined }
  })

  return writes
}

test('"already use it" writes the suppression the PowerShell reads', async ($, on) => {
  const writes = writesOf(on)
  await given($, on)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })
  await ui.press({ key: 'known' })
  await ui.unmount()

  const usage = JSON.parse(writes[`${TIP.stateDir}/usage.json`])
  expect(usage['az-pr']).toBeDefined()
})

test('dropping records the press but suppresses nothing', async ($, on) => {
  const writes = writesOf(on)
  await given($, on)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'drop' })
  await ui.unmount()

  expect(writes[`${TIP.stateDir}/usage.json`]).toBeUndefined()
  expect(writes[`${TIP.stateDir}/answers.log`]).toMatch(/az-pr dropped/)
})

test('every press is recorded, so the notice can finally be measured', async ($, on) => {
  const writes = writesOf(on)
  await given($, on)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })
  await ui.press({ key: 'show' })
  await ui.unmount()

  expect(writes[`${TIP.stateDir}/answers.log`]).toMatch(/az-pr show/)
})

test('"show me how" asks the model, naming the tool', async ($, on) => {
  const asked: string[] = []
  on('prompt.submit', (_$: unknown, e: { text: string }) => {
    asked.push(e.text)

    return { text: e.text }
  })
  await given($, on, TIP, { quiet: true })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })
  await ui.press({ key: 'show' })
  await ui.unmount()

  expect(asked.join('\n')).toMatch(/kros-shared:az-pr/)
})

test('the other answers ask the model nothing', async ($, on) => {
  const asked: string[] = []
  on('prompt.submit', (_$: unknown, e: { text: string }) => {
    asked.push(e.text)

    return { text: e.text }
  })
  await given($, on, TIP, { quiet: true })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'drop' })
  await ui.unmount()

  expect(asked).toHaveLength(0)
})

test('a band beneath this one is drawn too while a tip is shown, not replaced', async ($, on) => {
  await given($, on, TIP, { beneath: 'riadok iného pluginu' })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ plugin: 'dev-tips', surface, ...BAND })

    expect(await ui.find({ type: 'Text', text: /az-pr/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: 'riadok iného pluginu' })).toBeDefined()

    await ui.unmount()
  }
})
