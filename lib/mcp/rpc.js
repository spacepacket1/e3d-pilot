// Server-initiated JSON-RPC requests (roots/list, elicitation/create, sampling/createMessage).
// The client answers on stdin like any other message; handleResponse() routes those answers back.
export function createRpc(send) {
  let next = 1;
  const pending = new Map();
  return {
    request(method, params, timeoutMs = 120000) {
      const id = `s-${next++}`;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out after ${timeoutMs / 1000}s`)); }, timeoutMs);
        pending.set(id, { resolve, reject, timer });
        send({ jsonrpc: '2.0', id, method, params });
      });
    },
    // Returns true when msg was a response to one of our requests.
    handleResponse(msg) {
      if (msg.method || msg.id === undefined || msg.id === null || !pending.has(msg.id)) return false;
      const { resolve, reject, timer } = pending.get(msg.id);
      pending.delete(msg.id);
      clearTimeout(timer);
      if (msg.error) reject(Object.assign(new Error(msg.error.message || 'request failed'), { code: msg.error.code }));
      else resolve(msg.result);
      return true;
    },
    notify(method, params) { send({ jsonrpc: '2.0', method, params }); },
  };
}
