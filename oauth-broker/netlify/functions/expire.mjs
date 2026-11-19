import { getStore } from '@netlify/blobs';

export default async () => {
  if (!Netlify.env.get('IDB_BROKER_CREDENTIAL')) return;
  const store = getStore({ name: 'oauth-sessions', consistency: 'strong' });
  const cutoff = Date.now();
  for await (const page of store.list({ paginate: true })) {
    for (const { key } of page.blobs) {
      const value = await store.get(key, { type: 'json' });
      if (value?.expires <= cutoff) await store.delete(key);
    }
  }
};

export const config = { schedule: '17 9 * * *' };
