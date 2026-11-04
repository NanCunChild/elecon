/** Compile-only example of SDK17 host code. URLs and data are synthetic. */
import type {} from '../sdk17.js';

export const capabilities = {
  'notice.list': async () => {
    const request = new Request('https://school.example/notices', {
      headers: new Headers({ accept: 'application/json' }),
    });
    const response = await fetch(request);
    if (!response.ok) throw elecon.errors.create('notices_unavailable');
    return response.json();
  },
};
