/** What the person pressed. Unambiguous and countable, which a sentence never was. */
export type Answer = 'show' | 'known' | 'dropped'

declare module 'claude-code' {
  interface PluginState {
    'dev-tips': {
      /** From `classic.SessionStart`; names the handshake file this session was given. */
      sessionId: string | null
      isOpen: boolean
      /**
       * The id of the tip already answered, not a flag. A flag would suppress the next
       * tip too, and the state outlives a reload.
       */
      answeredId: string | null
    }
  }
}
