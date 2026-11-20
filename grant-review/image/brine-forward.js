// Forwards 127.0.0.1:4000 inside the container to the host-provided Unix socket.
// Runs as PID 1's child under tini, as user "fwd", so the reviewer can't kill it.
const net = require('net');
const SOCK = '/run/brine/brine.sock';
net.createServer((client) => {
  const upstream = net.connect(SOCK);
  const close = () => { client.destroy(); upstream.destroy(); };
  client.on('error', close);
  upstream.on('error', close);
  client.pipe(upstream).pipe(client);
}).listen(4000, '127.0.0.1');
