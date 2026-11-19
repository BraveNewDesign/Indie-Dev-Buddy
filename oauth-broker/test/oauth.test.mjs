import assert from 'node:assert/strict';
import test from 'node:test';
import { makeHandler } from '../netlify/functions/oauth.mjs';

const redirect_uri = 'https://connect.bravenewdesign.com/oauth/callback/facebook';
const credential = 'development-test-credential-with-32-characters';
const fields = { platform: 'facebookPages', redirect_uri, state: 'state-0123456789abcdef' };

function fixture() {
  const blobs = new Map();
  const calls = [];
  let clock = 1_000_000;
  const env = {
    META_FACEBOOK_APP_ID: '123',
    META_FACEBOOK_APP_SECRET: 'fixture',
    META_INSTAGRAM_APP_ID: '456',
    META_INSTAGRAM_APP_SECRET: 'instagram-fixture',
    META_THREADS_APP_ID: '789',
    META_THREADS_APP_SECRET: 'threads-fixture',
    IDB_BROKER_CREDENTIAL: credential
  };
  const handler = makeHandler({
    env: key => env[key],
    now: () => clock,
    storage: () => ({
      async getWithMetadata(key) { return blobs.get(key) ?? null; },
      async setJSON(key, data, options) {
        const previous = blobs.get(key);
        if ((options.onlyIfNew && previous) || (options.onlyIfMatch && previous?.etag !== options.onlyIfMatch)) {
          return { modified: false };
        }
        blobs.set(key, { data, etag: String(Number(previous?.etag ?? 0) + 1) });
        return { modified: true };
      }
    }),
    fetcher: async (url, options) => {
      calls.push({ url, options });
      return Response.json({ access_token: 'fixture-token', expires_in: 5_184_000 });
    }
  });
  const post = (route, data, bearer = credential) => handler(new Request(`https://connect.bravenewdesign.com/oauth/${route}`, {
    method: 'POST', headers: { authorization: `Bearer ${bearer}`, 'content-type': 'application/json' },
    body: JSON.stringify(data)
  }));
  const start = async () => (await post('session', { ...fields, client_id: '123' })).json();
  return { calls, post, start, advance: () => { clock += 600_001; } };
}

test('rejects unauthorized calls, wrong registration and expired sessions', async () => {
  const { calls, post, start, advance } = fixture();
  assert.equal((await post('session', { ...fields, client_id: '123' }, 'bad')).status, 401);
  assert.equal((await post('session', { ...fields, client_id: '456' })).status, 400);
  assert.equal((await post('session', { ...fields, client_id: '123', redirect_uri: redirect_uri + '/' })).status, 400);
  const { session_id } = await start();
  assert.equal((await post('exchange', { ...fields, session_id, code: 'code', state: 'wrong-state-0123456' })).status, 409);
  advance();
  assert.equal((await post('exchange', { ...fields, session_id, code: 'code' })).status, 409);
  assert.equal(calls.length, 0);
});

test('only one concurrent request exchanges a code and a second session cannot replay it', async () => {
  const { calls, post, start } = fixture();
  const { session_id } = await start();
  const request = { ...fields, session_id, code: 'code' };
  const responses = await Promise.all([post('exchange', request), post('exchange', request)]);
  assert.deepEqual(responses.map(response => response.status).sort(), [200, 409]);
  const tokenResponse = responses.find(response => response.ok);
  assert.equal(tokenResponse.headers.get('cache-control'), 'no-store');
  assert.ok((await tokenResponse.json()).expires_at);
  assert.equal(calls.length, 2);
  assert.equal(calls[1].url.searchParams.get('grant_type'), 'fb_exchange_token');
  const other = await start();
  assert.equal((await post('exchange', { ...request, ...other })).status, 409);
  assert.equal(calls.length, 2);
});

for (const [platform, id, shortHost, longHost, grant] of [
  ['instagram', '456', 'api.instagram.com', 'graph.instagram.com', 'ig_exchange_token'],
  ['threads', '789', 'graph.threads.net', 'graph.threads.net', 'th_exchange_token']
]) {
  test(`${platform} discovers registration and obtains a renewable long-lived token`, async () => {
    const { calls, post } = fixture();
    const registration = await post('registration', { platform });
    assert.equal(registration.status, 200);
    const values = await registration.json();
    assert.deepEqual(values, { client_id: id, redirect_uri: `https://connect.bravenewdesign.com/oauth/callback/${platform}` });
    const local = { ...fields, ...values, platform };
    const { session_id } = await (await post('session', local)).json();
    assert.equal((await post('exchange', { ...fields, session_id, code: 'cross-product' })).status, 409);
    const exchanged = await post('exchange', { ...local, session_id, code: 'valid-code' });
    assert.equal(exchanged.status, 200);
    assert.ok((await exchanged.json()).meta_long_lived_refresh_eligible_at);
    assert.equal(calls.length, 2);
    assert.equal(calls[0].url.hostname, shortHost);
    assert.equal(calls[0].options.method, 'POST');
    assert.equal((calls[0].options.body ?? calls[0].url.searchParams).get('grant_type'), 'authorization_code');
    assert.equal(calls[1].url.hostname, longHost);
    assert.equal(calls[1].url.searchParams.get('grant_type'), grant);
  });
}
