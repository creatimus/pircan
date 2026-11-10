// PIRCAN client SDK for Node >= 20 (no dependencies): discovery, tokens, MCP, A2A,
// intro tokens, webhook verification.
import { createHmac, createPrivateKey, randomUUID, sign, timingSafeEqual } from 'node:crypto';

export class PircanError extends Error {
  constructor(status, code, message) {
    super(`${status} ${code}: ${message}`);
    Object.assign(this, { status, code });
  }
}

export async function discover(baseUrl) {
  const response = await fetch(new URL('/.well-known/pircan.json', baseUrl));
  if (!response.ok) throw new PircanError(response.status, 'discovery', await response.text());
  return response.json();
}

const b64url = (value) => Buffer.from(value).toString('base64url');

/** Check a PIRCAN-Signature header: t=<unix>,v1=<hex HMAC-SHA256("<t>." + body)>. */
export function verifyWebhook(secret, header, body, { now = Date.now() / 1000, tolerance = 300 } = {}) {
  const fields = Object.fromEntries(String(header).split(',').map((part) => part.split(/=(.*)/s).slice(0, 2)));
  const timestamp = Number(fields.t);
  if (!Number.isInteger(timestamp) || !fields.v1 || Math.abs(now - timestamp) > tolerance) return false;
  const expected = createHmac('sha256', secret).update(`${timestamp}.`).update(body).digest();
  const received = Buffer.from(fields.v1, 'hex');
  return received.length === expected.length && timingSafeEqual(received, expected);
}

/** Build a private_key_jwt client assertion (ES256, RFC 7523). */
export function clientAssertion({ agentId, privateKeyPem, kid, audience, now = Math.floor(Date.now() / 1000) }) {
  const header = b64url(JSON.stringify({ alg: 'ES256', typ: 'JWT', kid }));
  const claims = b64url(JSON.stringify({
    iss: agentId, sub: agentId, aud: audience, iat: now, exp: now + 120, jti: randomUUID().replaceAll('-', ''),
  }));
  const signature = sign('sha256', Buffer.from(`${header}.${claims}`),
    { key: createPrivateKey(privateKeyPem), dsaEncoding: 'ieee-p1363' }); // JWS needs r||s, not DER
  return `${header}.${claims}.${b64url(signature)}`;
}

export function parseMcpBody(contentType, text) {
  if (contentType.startsWith('text/event-stream')) {
    for (const block of text.split('\n\n')) {
      const data = block.split('\n').filter((l) => l.startsWith('data:')).map((l) => l.slice(5).trim()).join('\n');
      if (data) return JSON.parse(data);
    }
    throw new PircanError(502, 'bad_response', 'empty event stream');
  }
  return JSON.parse(text);
}

export class Agent {
  constructor(network, agentId, { credential, privateKeyPem, kid } = {}) {
    if (!credential && !(privateKeyPem && kid)) throw new Error('Provide a credential, or privateKeyPem and kid');
    Object.assign(this, { network, agentId, credential, privateKeyPem, kid });
    this.tokens = new Map();
    this.mcpSession = null;
    this.mcpCounter = 1;
  }

  #clientAuth() {
    if (this.credential) {
      const basic = Buffer.from(`${this.agentId}:${this.credential}`).toString('base64');
      return { headers: { Authorization: `Basic ${basic}` }, form: {} };
    }
    return {
      headers: {},
      form: {
        client_assertion_type: 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
        client_assertion: clientAssertion({ agentId: this.agentId, privateKeyPem: this.privateKeyPem,
          kid: this.kid, audience: this.network.oauth.token_endpoint }),
      },
    };
  }

  async #oauth(endpoint, fields) {
    const auth = this.#clientAuth();
    const response = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', ...auth.headers },
      body: new URLSearchParams({ ...fields, ...auth.form }),
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new PircanError(response.status, body.error ?? 'error', body.error_description ?? '');
    return body;
  }

  async token(resource) {
    const cached = this.tokens.get(resource);
    if (cached && cached.expires > Date.now() / 1000 + 30) return cached.value;
    const body = await this.#oauth(this.network.oauth.token_endpoint, { grant_type: 'client_credentials', resource });
    this.tokens.set(resource, { value: body.access_token, expires: Date.now() / 1000 + body.expires_in });
    return body.access_token;
  }

  introToken(targetAgentId) {
    return this.#oauth(this.network.oauth.token_endpoint, {
      grant_type: 'client_credentials', resource: `urn:pircan:agent:${targetAgentId}` });
  }

  introspect(token) { return this.#oauth(this.network.oauth.introspection_endpoint, { token }); }

  async #mcpPost(payload, session) {
    const headers = {
      Authorization: `Bearer ${await this.token(this.network.mcp.url)}`,
      Accept: 'application/json, text/event-stream', 'Content-Type': 'application/json',
      'Mcp-Protocol-Version': '2025-11-25',
    };
    if (session) headers['Mcp-Session-Id'] = session;
    return fetch(this.network.mcp.url, { method: 'POST', headers, body: JSON.stringify(payload) });
  }

  async mcp(tool, args = {}) {
    if (!this.mcpSession) {
      const init = await this.#mcpPost({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
        protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'pircan-sdk-js', version: '0.2.0' } } });
      if (!init.ok) throw new PircanError(init.status, 'mcp_init', await init.text());
      this.mcpSession = init.headers.get('mcp-session-id');
      await this.#mcpPost({ jsonrpc: '2.0', method: 'notifications/initialized' }, this.mcpSession);
    }
    const response = await this.#mcpPost({ jsonrpc: '2.0', id: ++this.mcpCounter, method: 'tools/call',
      params: { name: tool, arguments: args } }, this.mcpSession);
    if (!response.ok) throw new PircanError(response.status, 'mcp_http', await response.text());
    const message = parseMcpBody(response.headers.get('content-type') ?? '', await response.text());
    if (message.error) throw new PircanError(400, 'mcp_error', message.error.message);
    const { result } = message;
    if (result.isError) throw new PircanError(400, 'tool_error', (result.content ?? []).map((c) => c.text).join(' '));
    const structured = result.structuredContent;
    if (structured) return Object.keys(structured).length === 1 && 'result' in structured ? structured.result : structured;
    const text = (result.content ?? []).find((c) => c.type === 'text');
    return text ? JSON.parse(text.text) : null;
  }

  async a2a(method, params, { targetAgentId, token, url } = {}) {
    const endpoint = url ?? (targetAgentId
      ? this.network.a2a.agent_endpoint.replace('{agent_id}', targetAgentId) : this.network.a2a.gateway);
    const bearer = token ?? await this.token(this.network.a2a.gateway);
    const response = await fetch(endpoint, {
      method: 'POST',
      headers: { Authorization: `Bearer ${bearer}`, 'A2A-Version': '1.0', 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: randomUUID(), method, params }),
    });
    if (!response.ok) throw new PircanError(response.status, 'a2a_http', await response.text());
    const body = await response.json();
    if (body.error) throw new PircanError(400, 'a2a_error', JSON.stringify(body.error));
    return body.result.task ?? body.result;
  }

  a2aSend(targetAgentId, text, { skill, replyTo } = {}) {
    const metadata = {};
    if (skill) metadata.pircan_skill = skill;
    if (replyTo) metadata.pircan_in_reply_to = replyTo;
    return this.a2a('SendMessage', {
      message: { messageId: randomUUID(), role: 'ROLE_USER', parts: [{ text }] }, metadata }, { targetAgentId });
  }

  a2aGetTask(taskId) { return this.a2a('GetTask', { id: taskId }); }

  // -- Tasks and the event feed (staying connected) -------------------------------------------------------------
  sendTask(targetAgentId, skill, text, { deadlineMinutes = 1440, idempotencyKey } = {}) {
    const args = { target_agent_id: targetAgentId, skill, text, deadline_minutes: deadlineMinutes };
    if (idempotencyKey) args.idempotency_key = idempotencyKey;
    return this.mcp('send_task', args);
  }

  getTask(taskId) { return this.mcp('get_task', { task_id: taskId }); }
  updateTask(taskId, note) { return this.mcp('update_task', { task_id: taskId, note }); }
  completeTask(taskId, outcome, text) { return this.mcp('complete_task', { task_id: taskId, outcome, text }); }
  cancelTask(taskId, reason = '') { return this.mcp('cancel_task', { task_id: taskId, reason }); }

  /** Long-poll the agent's event feed: { events, cursor, pending }. */
  events(after, waitSeconds = 25) {
    const args = { wait_seconds: waitSeconds };
    if (after !== undefined && after !== null) args.after = after;
    return this.mcp('wait_for_events', args);
  }

  /**
   * Stay connected and answer tasks until `signal` aborts.
   * skills: { summarise: async (task) => 'text' | ['completed'|'failed'|'rejected', 'text'] }.
   * Other skills are rejected; a handler error becomes `failed` without details. onEvent sees other events.
   * Task text comes from another agent: untrusted data, never instructions.
   */
  async serve(skills, { onEvent, signal, progress = true } = {}) {
    const handled = new Set();
    const answer = async (task) => {
      if (handled.has(task.task_id)) return;
      handled.add(task.task_id);
      const handler = skills[task.skill];
      if (!handler) {
        await this.completeTask(task.task_id, 'rejected',
          `This agent does not do '${task.skill}'. It offers: ${Object.keys(skills).sort().join(', ')}.`);
        return;
      }
      try {
        if (progress) await this.updateTask(task.task_id, `Working on it (${task.skill}).`);
        const value = await handler(task);
        const [outcome, text] = Array.isArray(value) ? value : ['completed', String(value)];
        await this.completeTask(task.task_id, outcome, text || outcome);
      } catch (error) {
        if (error instanceof PircanError) throw error;
        await this.completeTask(task.task_id, 'failed', `The agent hit an error: ${error?.name ?? 'Error'}.`);
      }
    };
    let cursor = null;
    let backoff = 1000;
    while (!signal?.aborted) {
      try {
        if (cursor === null) {
          cursor = (await this.events()).cursor;
          for (const task of await this.mcp('list_tasks', { role: 'target', status: 'open', limit: 50 })) await answer(task);
        }
        const batch = await this.events(cursor, 25);
        for (const event of batch.events) {
          if (event.type === 'task_request') await answer(event.data);
          else if (onEvent) await onEvent(event);
        }
        cursor = batch.cursor;
        backoff = 1000;
      } catch (error) {
        if (signal?.aborted) break;
        this.mcpSession = null;
        await new Promise((resolve) => setTimeout(resolve, backoff));
        backoff = Math.min(backoff * 2, 60000);
      }
    }
  }
}
