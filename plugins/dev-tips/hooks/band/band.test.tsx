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

  // The module asks the engine for the id; nothing hands it over. classic.SessionStart never
  // reaches it - another plugin takes that event first - so no test may depend on it either.
  on('session.id', () => ({ value: SESSION }))
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
  on('session.id', () => ({ value: SESSION }))

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

/**
 * A session the module has no id for: the handshake is found through the fallback.
 *
 * `classic.SessionStart` is deliberately not called - measured on 14 Oct, the band reached
 * its first draw with no id and took this path, which is how a tip picked 41 hours earlier
 * came back session after session.
 */
const OTHER = `${SHARED}/pending-session-0.json`

const givenNoId = (on: any, handshake: Record<string, unknown>) => {
  engineBeneath(on)
  mock.env(on, { USERPROFILE: HOME })

  on('fs.list', () => ({
    value: [
      { name: 'pending-session-0.json', kind: 'file' as const, size: 1, mtimeMs: Date.now() - 41 * 3600_000 },
    ],
  }))
  on('fs.read', (_$: unknown, e: { path: string }) => {
    if (normalise(e.path) === OTHER) return { value: JSON.stringify(handshake) }

    throw new Error(`no such file: ${e.path}`)
  })
}

test('a tip already delivered to somebody is not offered again by the fallback', async ($, on) => {
  givenNoId(on, { ...TIP, shownAt: '2026-10-12T12:06:56Z' })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /az-pr/ })).toBeUndefined()

  await ui.unmount()
})

test('a tip nobody has been shown is still drawn, however old the handshake', async ($, on) => {
  givenNoId(on, TIP)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /az-pr/ })).toBeDefined()

  await ui.unmount()
})

test('drawing through the fallback marks the handshake, so the next session leaves it', async ($, on) => {
  const writes = writesOf(on)
  givenNoId(on, TIP)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.unmount()

  expect(JSON.parse(writes[OTHER]).shownAt).toBeDefined()
})

/**
 * A rule rather than a tool. It has nothing to install and nothing to run, so `Get-InstallState`
 * hands over `n/a` and the band has to say something true about it.
 */
const DOC = {
  id: '0018-CompanyId',
  kind: 'adr',
  title: 'CompanyId vs TenantId',
  body: 'CompanyId identifikuje spoločnosť, TenantId zákazníka.',
  ref: '0018-CompanyId.md',
  url: null,
  installState: 'n/a',
  stateDir: `${HOME}/.claude/plugins/data/dev-tips-state`,
}

test('a document is offered to be read, not to be run', async ($, on) => {
  await given($, on, DOC)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })

  expect(await ui.find({ type: 'Button', text: 'Už to používam' })).toBeUndefined()
  expect(await ui.find({ type: 'Button', text: 'Poznám' })).toBeDefined()
  expect(await ui.find({ type: 'Button', text: 'Vysvetli mi to' })).toBeDefined()

  await ui.unmount()
})

test('knowing a rule writes no usage suppression, because a rule is not a tool', async ($, on) => {
  const writes = writesOf(on)
  await given($, on, DOC)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })
  await ui.press({ key: 'known' })
  await ui.unmount()

  expect(writes[`${DOC.stateDir}/usage.json`]).toBeUndefined()
  expect(writes[`${DOC.stateDir}/answers.log`]).toBeDefined()
})

test('a skill still says what a skill says', async ($, on) => {
  await given($, on)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })

  expect(await ui.find({ type: 'Button', text: 'Už to používam' })).toBeDefined()
  expect(await ui.find({ type: 'Button', text: 'Ukáž ako' })).toBeDefined()

  await ui.unmount()
})

test('asking about a rule asks what it says, and says where it is', async ($, on) => {
  const asked: string[] = []
  on('prompt.submit', (_$: unknown, e: { text: string }) => {
    asked.push(e.text)

    return { text: e.text }
  })
  await given($, on, { ...DOC, ref: 'Adrs/0018-CompanyId.md' }, { quiet: true })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })
  await ui.press({ key: 'show' })
  await ui.unmount()

  const text = asked.join('\n')
  expect(text).not.toMatch(/ako sa použ/)
  expect(text).toMatch(/CompanyId vs TenantId/)
  expect(text).toMatch(/adr\/Adrs\/0018-CompanyId\.md/)
})

test('a guideline is pointed at in the repository, not in the mirror', async ($, on) => {
  const asked: string[] = []
  on('prompt.submit', (_$: unknown, e: { text: string }) => {
    asked.push(e.text)

    return { text: e.text }
  })
  await given($, on, { ...DOC, kind: 'guideline', title: 'Development Workflow', ref: 'docs/guidelines/workflow.md' }, { quiet: true })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })
  await ui.press({ key: 'show' })
  await ui.unmount()

  const text = asked.join('\n')
  expect(text).toMatch(/docs\/guidelines\/workflow\.md/)
  expect(text).not.toMatch(/ako sa použ/)
  expect(text).not.toMatch(/dev-tips-state/)
})

test('a document with no sections shows its opening, and the whole of it once expanded', async ($, on) => {
  const long = { ...DOC, body: 'Prvý odsek, ktorý sa zmestí do pásu.', full: 'Prvý odsek, ktorý sa zmestí do pásu.\n\nDruhý odsek, ktorý je vidieť až po rozbalení.' }
  await given($, on, long)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /Druhý odsek/ })).toBeUndefined()
  await ui.press({ key: 'open' })
  expect(await ui.find({ type: 'Text', text: /Druhý odsek/ })).toBeDefined()

  await ui.unmount()
})

test('a tip with no full text shows the same body expanded or not', async ($, on) => {
  await given($, on, DOC)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })

  expect(await ui.find({ type: 'Text', text: /CompanyId identifikuje/ })).toBeDefined()

  await ui.unmount()
})

test('a guideline is named by its own repository, not by whichever one is on screen', async ($, on) => {
  on('session.root', () => ({ value: 'C:/src/Invoicing' }))
  const asked: string[] = []
  on('prompt.submit', (_$: unknown, e: { text: string }) => {
    asked.push(e.text)

    return { text: e.text }
  })
  await given($, on, {
    ...DOC,
    kind: 'guideline',
    title: 'Development Workflow',
    ref: 'docs/guidelines/workflow.md',
    repoRoot: 'C:/src/Invoicing',
  }, { quiet: true })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })
  await ui.press({ key: 'show' })
  await ui.unmount()

  const text = asked.join('\n')
  expect(text).toMatch(/C:\/src\/Invoicing\/docs\/guidelines\/workflow\.md/)
  expect(text).not.toMatch(/v tomto repozitári/)
})

test('a guideline whose handshake predates the repository being recorded still says where it is', async ($, on) => {
  const asked: string[] = []
  on('prompt.submit', (_$: unknown, e: { text: string }) => {
    asked.push(e.text)

    return { text: e.text }
  })
  await given($, on, { ...DOC, kind: 'guideline', title: 'Workflow', ref: 'docs/guidelines/workflow.md' }, { quiet: true })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })
  await ui.press({ key: 'show' })
  await ui.unmount()

  expect(asked.join('\n')).toMatch(/docs\/guidelines\/workflow\.md/)
})

test('a guideline picked in another repository is not drawn here', async ($, on) => {
  on('session.root', () => ({ value: 'C:/src/Kros.Plugins' }))
  await given($, on, {
    ...DOC,
    kind: 'guideline',
    title: 'Development Workflow',
    body: 'Toto je pravidlo Invoicingu.',
    ref: 'docs/guidelines/workflow.md',
    repoRoot: 'C:/src/Invoicing',
  })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /Toto je pravidlo Invoicingu/ })).toBeUndefined()

  await ui.unmount()
})

test('a tip picked in this repository is drawn', async ($, on) => {
  on('session.root', () => ({ value: 'C:/src/Invoicing' }))
  await given($, on, {
    ...DOC,
    kind: 'guideline',
    title: 'Development Workflow',
    body: 'Toto je pravidlo Invoicingu.',
    ref: 'docs/guidelines/workflow.md',
    repoRoot: 'C:/src/Invoicing',
  })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /Toto je pravidlo Invoicingu/ })).toBeDefined()

  await ui.unmount()
})

test('a handshake written before the repository was recorded is still drawn', async ($, on) => {
  on('session.root', () => ({ value: 'C:/src/Kros.Plugins' }))
  await given($, on, DOC)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /CompanyId identifikuje/ })).toBeDefined()

  await ui.unmount()
})

test('the tip is still drawn when the session cannot say which repository it is in', async ($, on) => {
  on('session.root', () => { throw new Error('no root here') })
  await given($, on, { ...DOC, kind: 'guideline', body: 'Pravidlo, ktoré sa má zobraziť.', repoRoot: 'C:/src/Invoicing' })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /Pravidlo, ktoré sa má zobraziť/ })).toBeDefined()

  await ui.unmount()
})

test('the band asks the engine which session it is in, rather than waiting to be told', async ($, on) => {
  engineBeneath(on)
  mock.env(on, { USERPROFILE: HOME })
  on('session.id', () => ({ value: SESSION }))
  on('session.root', () => ({ value: 'C:/src/Invoicing' }))
  on('fs.read', ($$: unknown, e: { path: string }) => {
    if (isPending(e.path)) return { value: JSON.stringify({ ...TIP, repoRoot: 'C:/src/Invoicing' }) }

    throw new Error(`no such file: ${e.path}`)
  })
  // Deliberately no classic.SessionStart: cc-plugin-sec-default takes that event before it
  // reaches this module, so nothing here may depend on it arriving.

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /az-pr/ })).toBeDefined()

  await ui.unmount()
})

test('the band registers no classic.SessionStart hook for another plugin to swallow', async ($, on) => {
  const hooked: string[] = []
  on('classic.SessionStart', () => { hooked.push('taken'); return {} })
  mock.env(on, { USERPROFILE: HOME })
  on('session.id', () => ({ value: SESSION }))
  on('fs.read', () => { throw new Error('no file') })

  await $.classic.SessionStart({ session_id: SESSION })

  expect(hooked).toHaveLength(1)
})

test('a tip already delivered to this session is not drawn again by a later load', async ($, on) => {
  engineBeneath(on)
  mock.env(on, { USERPROFILE: HOME })
  on('session.id', () => ({ value: SESSION }))
  on('fs.read', ($$: unknown, e: { path: string }) => {
    if (isPending(e.path)) return { value: JSON.stringify({ ...TIP, shownAt: '2026-10-27T12:08:00Z' }) }

    throw new Error(`no such file: ${e.path}`)
  })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /az-pr/ })).toBeUndefined()

  await ui.unmount()
})

test('a tip handed to this session for the first time is drawn', async ($, on) => {
  await given($, on)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /az-pr/ })).toBeDefined()

  await ui.unmount()
})

test('a session opened inside the repository still gets its tip', async ($, on) => {
  writesOf(on)
  engineBeneath(on)
  mock.env(on, { USERPROFILE: HOME })
  on('session.id', () => ({ value: SESSION }))
  // The hook writes the git top level; the session was opened on a folder inside it.
  on('session.root', () => ({ value: 'C:\\src\\Kros.Plugins\\plugins\\dev-tips' }))
  on('fs.read', ($$: unknown, e: { path: string }) => {
    if (isPending(e.path)) return { value: JSON.stringify({ ...TIP, repoRoot: 'C:/src/Kros.Plugins' }) }

    throw new Error(`no such file: ${e.path}`)
  })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /az-pr/ })).toBeDefined()

  await ui.unmount()
})

test('a tip refused for belonging elsewhere is not burned', async ($, on) => {
  const writes = writesOf(on)
  engineBeneath(on)
  mock.env(on, { USERPROFILE: HOME })
  on('session.id', () => ({ value: SESSION }))
  on('session.root', () => ({ value: 'C:/src/Something-Else' }))
  on('fs.read', ($$: unknown, e: { path: string }) => {
    if (isPending(e.path)) return { value: JSON.stringify({ ...TIP, repoRoot: 'C:/src/Invoicing' }) }

    throw new Error(`no such file: ${e.path}`)
  })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /az-pr/ })).toBeUndefined()

  await ui.unmount()

  expect(writes[`${SHARED}/pending-${SESSION}.json`]).toBeUndefined()
})
