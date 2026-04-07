import { WebSocketServer } from 'ws';
import os from 'node:os';

const host = process.env.WS_ECHO_HOST || '0.0.0.0';
const port = Number(process.env.WS_ECHO_PORT || 8787);

const server = new WebSocketServer({ host, port });

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
      urls.push(`ws://${entry.address}:${port}`);
    });
  });

  return [...new Set(urls)];
}

function createServerMessage(type, extra = {}) {
  return JSON.stringify({
    type,
    serverTime: new Date().toISOString(),
    ...extra,
  });
}

server.on('connection', (socket, request) => {
  const client = `${request.socket.remoteAddress || 'unknown'}:${request.socket.remotePort || ''}`;
  console.log(`[ws:echo] client connected from ${client}`);

  socket.send(
    createServerMessage('server.welcome', {
      message: 'echo server connected',
      path: request.url || '/',
    })
  );

  const heartbeat = setInterval(() => {
    if (socket.readyState !== socket.OPEN) {
      return;
    }
    socket.send(
      createServerMessage('server.heartbeat', {
        message: 'heartbeat',
      })
    );
  }, 5000);

  socket.on('message', (data, isBinary) => {
    const payload = isBinary
      ? {
          binary: true,
          bytes: data.length,
          preview: Buffer.from(data).subarray(0, 24).toString('hex'),
        }
      : {
          binary: false,
          text: data.toString(),
        };

    const response = createServerMessage('server.echo', payload);
    console.log(`[ws:echo] ${client} -> ${response}`);
    socket.send(response);
  });

  socket.on('close', (code, reason) => {
    clearInterval(heartbeat);
    console.log(
      `[ws:echo] client disconnected ${client} code=${code} reason=${reason.toString() || '-'}`
    );
  });

  socket.on('error', (error) => {
    console.error(`[ws:echo] socket error from ${client}`, error);
  });
});

server.on('listening', () => {
  console.log(`[ws:echo] listening on ws://${host}:${port}`);
  console.log('[ws:echo] start the Expo app on the same machine or LAN, then connect from the example screen');
  const urls = collectNetworkUrls();
  if (urls.length > 0) {
    console.log('[ws:echo] LAN URLs you can paste into the example on a real device:');
    urls.forEach((url) => {
      console.log(`  - ${url}`);
    });
  }
});

server.on('error', (error) => {
  console.error('[ws:echo] server error', error);
  process.exitCode = 1;
});
