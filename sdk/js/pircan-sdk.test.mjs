import assert from 'node:assert/strict';
import { createHmac, generateKeyPairSync, createPublicKey, verify } from 'node:crypto';
import test from 'node:test';
import { clientAssertion, parseMcpBody, verifyWebhook } from './pircan-sdk.mjs';

const sign = (secret, t, body) =>
  `t=${t},v1=${createHmac('sha256', secret).update(`${t}.`).update(body).digest('hex')}`;

test('webhook signatures: valid, tampered, wrong key, stale, garbage', () => {
  const body = Buffer.from('{"id":"d1"}');
  const header = sign('secret', 1_700_000_000, body);
  assert.equal(verifyWebhook('secret', header, body, { now: 1_700_000_100 }), true);
  assert.equal(verifyWebhook('secret', header, Buffer.from('{"id":"d2"}'), { now: 1_700_000_100 }), false);
  assert.equal(verifyWebhook('other', header, body, { now: 1_700_000_100 }), false);
  assert.equal(verifyWebhook('secret', header, body, { now: 1_700_000_400 }), false);
  assert.equal(verifyWebhook('secret', 'garbage', body, { now: 1_700_000_000 }), false);
});

test('webhook signature matches the vector produced by the PIRCAN server (Python)', () => {
  // pircan.forwarder.sign("secret", 1700000000, b'{"id":"d1"}')
  const vector = 't=1700000000,v1=1ba9109190da01700025361ed13fd2054498487d336683cd58ecc23e88460eef';
  assert.equal(verifyWebhook('secret', vector, Buffer.from('{"id":"d1"}'), { now: 1_700_000_000 }), true);
  assert.equal(verifyWebhook('secret', vector, Buffer.from('{"id":"d2"}'), { now: 1_700_000_000 }), false);
});

test('client assertion is a valid ES256 JWS with the expected claims', () => {
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const jwt = clientAssertion({ agentId: 'agent-1', privateKeyPem: pem, kid: 'k1',
    audience: 'https://net.test/oauth/token', now: 1_700_000_000 });
  const [h, c, s] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(h, 'base64url')), { alg: 'ES256', typ: 'JWT', kid: 'k1' });
  const claims = JSON.parse(Buffer.from(c, 'base64url'));
  assert.equal(claims.iss, 'agent-1'); assert.equal(claims.sub, 'agent-1');
  assert.equal(claims.aud, 'https://net.test/oauth/token'); assert.equal(claims.exp - claims.iat, 120);
  assert.equal(Buffer.from(s, 'base64url').length, 64); // r||s, as JWS requires
  assert.equal(verify('sha256', Buffer.from(`${h}.${c}`),
    { key: createPublicKey(privateKey), dsaEncoding: 'ieee-p1363' }, Buffer.from(s, 'base64url')), true);
});

test('MCP replies parse from JSON and from a one-event stream', () => {
  assert.deepEqual(parseMcpBody('application/json', '{"a":1}'), { a: 1 });
  assert.deepEqual(parseMcpBody('text/event-stream', 'event: message\ndata: {"a":2}\n\n'), { a: 2 });
  assert.throws(() => parseMcpBody('text/event-stream', '\n\n'));
});
