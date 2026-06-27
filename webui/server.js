const http = require('http');
const { handleRequest } = require('./src/routes');

const PORT = 8888;

// Bootstrap server
const server = http.createServer(handleRequest);

server.listen(PORT, () => {
  console.log(`Homeserver WebUI server running at http://localhost:${PORT}`);
});
