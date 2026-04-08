import http from 'node:http';
import os from 'node:os';

const host = process.env.HTTP_MOCK_HOST || '0.0.0.0';
const port = Number(process.env.HTTP_MOCK_PORT || 8788);

function collectNetworkUrls() {
  const interfaces = os.networkInterfaces();
  const urls = [];
  const ignoredInterfacePrefixes = ['utun', 'awdl', 'llw', 'bridge', 'gif', 'stf'];
  const ignoredAddressPrefixes = ['169.254.', '198.18.', '198.19.'];

  Object.entries(interfaces).forEach(([name, entries]) => {
    const normalizedName = name.toLowerCase();
    if (ignoredInterfacePrefixes.some((prefix) => normalizedName.startsWith(prefix))) {
      return;
    }
    entries?.forEach((entry) => {
      if (!entry || entry.family !== 'IPv4' || entry.internal) {
        return;
      }
      if (ignoredAddressPrefixes.some((prefix) => entry.address.startsWith(prefix))) {
        return;
      }
      urls.push(`http://${entry.address}:${port}`);
    });
  });

  return [...new Set(urls)];
}

function readRequestBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on('data', (chunk) => {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    });
    request.on('end', () => {
      resolve(Buffer.concat(chunks).toString('utf8'));
    });
    request.on('error', reject);
  });
}

function safeParseJSON(text) {
  if (!text) {
    return null;
  }
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function delay(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function sendJSON(response, statusCode, payload) {
  const body = JSON.stringify(payload, null, 2);
  response.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    Connection: 'close',
  });
  response.end(body);
}

function requestSummary(request, url) {
  return {
    method: request.method || 'GET',
    path: url.pathname,
    query: Object.fromEntries(url.searchParams.entries()),
    headers: {
      'content-type': request.headers['content-type'] || '',
      'x-debug-demo': request.headers['x-debug-demo'] || '',
      'user-agent': request.headers['user-agent'] || '',
    },
  };
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url || '/', `http://${request.headers.host || `${host}:${port}`}`);
  const method = request.method || 'GET';
  const startedAt = new Date().toISOString();

  if (method === 'GET' && url.pathname === '/debug-http/get') {
    await delay(180);
    const payload = {
      ok: true,
      type: 'mock.get',
      serverTime: startedAt,
      summary: requestSummary(request, url),
      data: {
        id: `order_${Date.now()}`,
        title: 'local GET payload',
        status: 'ready',
        tags: ['fetch', 'local', 'demo'],
      },
      message: 'GET response body from local mock server',
    };
    console.log(`[http:mock] GET ${url.pathname}${url.search} -> 200`);
    sendJSON(response, 200, payload);
    return;
  }

  if (method === 'POST' && url.pathname === '/debug-http/post') {
    const rawBody = await readRequestBody(request);
    const parsedBody = safeParseJSON(rawBody);
    await delay(260);
    const payload = {
      ok: true,
      type: 'mock.post',
      serverTime: startedAt,
      summary: requestSummary(request, url),
      requestBody: parsedBody ?? rawBody,
      responseBody: {
        received: true,
        id: `submission_${Date.now()}`,
        echo: parsedBody ?? rawBody,
        savedAt: new Date().toISOString(),
      },
      message: 'POST response body from local mock server',
    };
    console.log(
      `[http:mock] POST ${url.pathname}${url.search} -> 201 body=${rawBody.slice(0, 160) || '-'}`
    );
    sendJSON(response, 201, payload);
    return;
  }

  console.warn(`[http:mock] ${method} ${url.pathname}${url.search} -> 404`);
  sendJSON(response, 404, {
    ok: false,
    error: 'Not Found',
    serverTime: startedAt,
    summary: requestSummary(request, url),
  });
});

server.on('listening', () => {
  console.log(`[http:mock] listening on http://${host}:${port}`);
  console.log('[http:mock] start the Expo app on the same machine or LAN, then trigger GET/POST from the example screen');
  const urls = collectNetworkUrls();
  if (urls.length > 0) {
    console.log('[http:mock] LAN URLs you can paste into the example on a real device:');
    urls.forEach((url) => {
      console.log(`  - ${url}`);
    });
  }
});

server.on('error', (error) => {
  console.error('[http:mock] server error', error);
  process.exitCode = 1;
});

server.listen(port, host);
