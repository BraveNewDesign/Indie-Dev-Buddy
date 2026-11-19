import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { getStore } from '@netlify/blobs';

const defaultOrigin = 'https://connect.bravenewdesign.com';
const providers = new Map([
  ['facebookPages', { key: 'FACEBOOK', path: 'facebook', short: 'https://graph.facebook.com/v27.0/oauth/access_token',
    long: 'https://graph.facebook.com/v27.0/oauth/access_token', grant: 'fb_exchange_token' }],
  ['instagram', { key: 'INSTAGRAM', path: 'instagram', short: 'https://api.instagram.com/oauth/access_token',
    long: 'https://graph.instagram.com/access_token', grant: 'ig_exchange_token', form: true }],
  ['threads', { key: 'THREADS', path: 'threads', short: 'https://graph.threads.net/oauth/access_token',
    long: 'https://graph.threads.net/access_token', grant: 'th_exchange_token', post: true }]
]);
const sessionLifetime = 10 * 60_000;
const replayLifetime = 24 * 60 * 60_000;
const digest = value => createHash('sha256').update(value).digest('hex');

function reply(status, body) {
  return Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });
}

function authorized(request, credential) {
  const header = request.headers.get('authorization') ?? '';
  return credential.length >= 32 &&
    timingSafeEqual(Buffer.from(digest(header)), Buffer.from(digest(`Bearer ${credential}`)));
}

async function bodyJSON(request) {
  if (!request.body || request.headers.get('content-type')?.split(';')[0] !== 'application/json') return null;
  const reader = request.body.getReader();
  const chunks = [];
  let length = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    length += value.length;
    if (length > 8192) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

async function providerToken(endpoint, parameters, fetcher, method = 'GET', form = false) {
  const url = new URL(endpoint);
  const encoded = new URLSearchParams(parameters);
  const options = { method, redirect: 'error', signal: AbortSignal.timeout(10_000) };
  if (form) {
    const body = new FormData();
    for (const [field, value] of encoded) body.set(field, value);
    options.body = body;
  } else {
    url.search = encoded.toString();
  }
  const response = await fetcher(url, options);
  if (!response.ok) throw new Error('Provider exchange failed');
  const value = await response.json();
  if (typeof value.access_token !== 'string' || !value.access_token) throw new Error('Missing provider token');
  return value;
}

function registration(platform, env) {
  const provider = providers.get(platform);
  if (!provider) return null;
  const origin = new URL(env('IDB_CALLBACK_ORIGIN') || defaultOrigin);
  if (origin.protocol !== 'https:' || origin.username || origin.password || origin.port ||
      origin.pathname !== '/' || origin.search || origin.hash) return null;
  return {
    provider,
    callback: new URL(`/oauth/callback/${provider.path}`, origin).href,
    clientID: env(`META_${provider.key}_APP_ID`) ?? '',
    secret: env(`META_${provider.key}_APP_SECRET`) ?? ''
  };
}

async function exchangeToken({ provider, callback, clientID, secret }, code, fetcher, now) {
  const parameters = { client_id: clientID, client_secret: secret, redirect_uri: callback, code };
  if (provider.form || provider.post) parameters.grant_type = 'authorization_code';
  const short = await providerToken(provider.short, parameters, fetcher, provider.form || provider.post ? 'POST' : 'GET', provider.form);
  const longParameters = { client_secret: secret, grant_type: provider.grant };
  if (provider.key === 'FACEBOOK') {
    longParameters.client_id = clientID;
    longParameters.fb_exchange_token = short.access_token;
  } else {
    longParameters.access_token = short.access_token;
  }
  const long = await providerToken(provider.long, longParameters, fetcher);
  const result = { access_token: long.access_token };
  const issuedAt = now();
  const lifetime = Number(long.expires_in);
  if (Number.isFinite(lifetime) && lifetime > 0 && lifetime <= 366 * 86400) {
    result.expires_at = new Date(issuedAt + lifetime * 1000).toISOString();
    if (provider.key !== 'FACEBOOK' && lifetime > 86400) {
      result.meta_long_lived_refresh_eligible_at = new Date(issuedAt + 86400_000).toISOString();
    }
  }
  if (provider.key === 'INSTAGRAM' && Array.isArray(short.permissions) &&
      short.permissions.every(scope => typeof scope === 'string' && /^[a-z_]+$/.test(scope))) {
    result.granted_scopes = short.permissions;
  }
  return result;
}

export function makeHandler({ env, storage, fetcher = fetch, now = Date.now }) {
  return async request => {
    if (request.method !== 'POST') return reply(405, { error: 'method_not_allowed' });
    const credential = env('IDB_BROKER_CREDENTIAL') ?? '';
    if (credential.length < 32) return reply(503, { error: 'broker_not_configured' });
    if (!authorized(request, credential)) return reply(401, { error: 'unauthorized' });

    let body;
    try {
      body = await bodyJSON(request);
    } catch {
      return reply(400, { error: 'invalid_request' });
    }
    try {
      const configured = registration(body?.platform, env);
      if (!configured) return reply(400, { error: 'invalid_registration' });
      const { clientID, secret, callback } = configured;
      if (!/^\d+$/.test(clientID) || !secret) return reply(503, { error: 'provider_not_configured' });

      const path = new URL(request.url).pathname;
      if (path === '/oauth/registration') {
        return reply(200, { client_id: clientID, redirect_uri: callback });
      }
      if (body.redirect_uri !== callback || typeof body.state !== 'string' ||
          !/^[A-Za-z0-9_-]{16,256}$/.test(body.state)) {
        return reply(400, { error: 'invalid_registration' });
      }
      const store = storage();
      if (path === '/oauth/session') {
        if (body.client_id !== clientID) return reply(400, { error: 'invalid_registration' });
        const id = randomBytes(32).toString('base64url');
        const session = { state: digest(body.state), operator: digest(credential), clientID, platform: body.platform, callback, expires: now() + sessionLifetime };
        const write = await store.setJSON(`session/${id}`, session, { onlyIfNew: true });
        if (!write.modified) return reply(503, { error: 'session_unavailable' });
        return reply(200, { session_id: id });
      }

      if (path !== '/oauth/exchange') return reply(404, { error: 'not_found' });
      if (typeof body.session_id !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(body.session_id) ||
          typeof body.code !== 'string' || !body.code || body.code.length > 4096) {
        return reply(400, { error: 'invalid_exchange' });
      }
      const key = `session/${body.session_id}`;
      const entry = await store.getWithMetadata(key, { type: 'json' });
      const session = entry?.data;
      if (!entry?.etag || !session || session.consumed || session.expires <= now() ||
          session.state !== digest(body.state) || session.operator !== digest(credential) ||
          session.clientID !== clientID || session.platform !== body.platform || session.callback !== callback) {
        return reply(409, { error: 'start_new_sign_in' });
      }

      // Claim both the session and the provider code before contacting Meta.
      const consumed = await store.setJSON(key, { consumed: true, expires: session.expires }, { onlyIfMatch: entry.etag });
      if (!consumed.modified) return reply(409, { error: 'start_new_sign_in' });
      const replay = await store.setJSON(`code/${body.platform}/${digest(body.code)}`, { expires: now() + replayLifetime }, { onlyIfNew: true });
      if (!replay.modified) return reply(409, { error: 'start_new_sign_in' });

      return reply(200, await exchangeToken(configured, body.code, fetcher, now));
    } catch {
      return reply(502, { error: 'exchange_unavailable_start_new_sign_in' });
    }
  };
}

export default makeHandler({
  env: key => Netlify.env.get(key),
  storage: () => getStore({ name: 'oauth-sessions', consistency: 'strong' })
});

export const config = { path: ['/oauth/registration', '/oauth/session', '/oauth/exchange'] };
