#!/usr/bin/env node

const { spawn } = require('child_process');
const path = require('path');

// Change to the project directory
process.chdir('/Users/avitaltamir/projects/contextdb');

// Spawn the Zig MCP server
const child = spawn('/opt/homebrew/bin/zig', ['build', 'mcp-server'], {
  stdio: ['inherit', 'inherit', 'inherit'],
  cwd: '/Users/avitaltamir/projects/contextdb'
});

// Forward signals
process.on('SIGTERM', () => child.kill('SIGTERM'));
process.on('SIGINT', () => child.kill('SIGINT'));

// Exit when child exits
child.on('exit', (code) => {
  process.exit(code);
}); 