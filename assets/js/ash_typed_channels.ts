import type { SessionsChannel, SessionsChannelEvents, SessionsChannelHandlers, SessionsChannelRefs, TerminalChannel, TerminalChannelEvents, TerminalChannelHandlers, TerminalChannelRefs } from "./ash_types";
export type * from "./ash_types";

export function createSessionsChannel(
  socket: { channel(topic: string, params?: object): unknown }
): SessionsChannel {
  return socket.channel("sessions") as SessionsChannel;
}

export function onSessionsChannelMessage<E extends keyof SessionsChannelEvents>(
  channel: SessionsChannel,
  event: E,
  handler: (payload: SessionsChannelEvents[E]) => void
): number {
  return channel.on(event, (payload: unknown) => handler(payload as SessionsChannelEvents[E]));
}

export function onSessionsChannelMessages(
  channel: SessionsChannel,
  handlers: SessionsChannelHandlers
): SessionsChannelRefs {
  const refs: SessionsChannelRefs = {};
  for (const event in handlers) {
    const e = event as keyof SessionsChannelEvents;
    const handler = handlers[e];
    if (handler) {
      refs[e] = channel.on(event, (payload) => (handler as (p: unknown) => void)(payload));
    }
  }
  return refs;
}

export function unsubscribeSessionsChannel(
  channel: SessionsChannel,
  refs: SessionsChannelRefs
): void {
  for (const event in refs) {
    const e = event as keyof SessionsChannelRefs;
    const ref = refs[e];
    if (ref !== undefined) {
      channel.off(event, ref);
    }
  }
}

export function createTerminalChannel(
  socket: { channel(topic: string, params?: object): unknown },
  suffix: string
): TerminalChannel {
  return socket.channel(`terminal:${suffix}`) as TerminalChannel;
}

export function onTerminalChannelMessage<E extends keyof TerminalChannelEvents>(
  channel: TerminalChannel,
  event: E,
  handler: (payload: TerminalChannelEvents[E]) => void
): number {
  return channel.on(event, (payload: unknown) => handler(payload as TerminalChannelEvents[E]));
}

export function onTerminalChannelMessages(
  channel: TerminalChannel,
  handlers: TerminalChannelHandlers
): TerminalChannelRefs {
  const refs: TerminalChannelRefs = {};
  for (const event in handlers) {
    const e = event as keyof TerminalChannelEvents;
    const handler = handlers[e];
    if (handler) {
      refs[e] = channel.on(event, (payload) => (handler as (p: unknown) => void)(payload));
    }
  }
  return refs;
}

export function unsubscribeTerminalChannel(
  channel: TerminalChannel,
  refs: TerminalChannelRefs
): void {
  for (const event in refs) {
    const e = event as keyof TerminalChannelRefs;
    const ref = refs[e];
    if (ref !== undefined) {
      channel.off(event, ref);
    }
  }
}