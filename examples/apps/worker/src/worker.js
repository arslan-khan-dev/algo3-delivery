// Sample worker for templates/dockerfiles/worker.Dockerfile.
const fs = require('node:fs');
let stopping = false;
const tick = () => { if (!stopping) { fs.writeFileSync('/tmp/alive', String(Date.now())); console.log(`tick ${process.env.RELEASE_SHA}`); } };
tick();
const timer = setInterval(tick, 2000);
process.on('SIGTERM', () => { stopping = true; clearInterval(timer); console.log('stopping'); process.exit(0); });
