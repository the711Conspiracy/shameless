const { EventEmitter } = require('events')
const log = require('../../core/log')

const bus = new EventEmitter()
bus.setMaxListeners(50)

const EVENTS = [
  'library.track.added',
  'library.track.removed',
  'library.track.updated',
  'audio.track.started',
  'audio.track.finished',
  'audio.track.skipped',
  'audio.position',
  'peer.connected',
  'peer.disconnected',
  'peer.slow',
  'pod.rotated',
  'node.rotated',
  'pod.member.revoked',
  'pod.deleted',
  'analysis.complete',
  'analysis.queued',
  'analysis.track.done',
  'shuffle.requested',
  'queue.track.added',
  'queue.cleared',
  'party.state',
  'party.created',
  'party.closed',
  'reaction.added',
  'chat.message',
  'identity.rotated'
]

function emit(event, payload) {
  if (!EVENTS.includes(event)) throw new Error(`Unregistered event: ${event}`)
  try {
    bus.emit(event, payload)
  } catch (e) {
    log.error('events', `listener threw on ${event}`, e)
  }
}

function on(event, handler) { bus.on(event, handler) }
function off(event, handler) { bus.off(event, handler) }
function once(event, handler) { bus.once(event, handler) }

module.exports = { emit, on, off, once, EVENTS }
