// Minimal hello-world API — the whole point of the video is the JOURNEY
// (laptop -> ECR -> Fargate), not the app. Keep this boring on purpose.
const express = require('express');
const os = require('os');

const app = express();
const PORT = process.env.PORT || 3000;

app.get('/', (req, res) => {
  res.json({
    message: 'Hello from AWS Fargate! 🚀',
    servedBy: os.hostname(), // the Fargate task ID — proves it is NOT your laptop
    version: process.env.APP_VERSION || 'v1.0.0',
  });
});

// ECS runs this as the container health check (see task-definition.json).
// Get the path or the port wrong here and your task loops PENDING -> STOPPED.
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

// Bind to 0.0.0.0, NOT localhost. Inside a container, 127.0.0.1 is
// unreachable from outside the container's network namespace.
app.listen(PORT, '0.0.0.0', () => {
  console.log(`hello-fargate listening on :${PORT}`);
});
