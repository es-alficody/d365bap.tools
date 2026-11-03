'use strict';

// Runs the real Get-SignatureDelta.ps1 in one long-lived pwsh process instead of
// one process per comparison. Every comparison is still a fresh script
// invocation: parameters, the git cat-file batch process, parsing and the
// fail-closed checks are unchanged. Only PowerShell start-up is amortised.
//
// The caller keeps a real subprocess contract check: signature-approval.test.cjs
// and Get-SignatureDelta.test.cjs each assert one end-to-end execFileSync
// invocation, including the non-zero exit for a fail-closed input.

const { spawn } = require('node:child_process');
const path = require('node:path');

const SESSION_SCRIPT = path.join(__dirname, 'Invoke-SignatureDeltaSession.ps1');
const DELTA_SCRIPT = path.join(__dirname, 'Get-SignatureDelta.ps1');

class SignatureDeltaSession {
  constructor(directory) {
    this.pending = [];
    this.buffer = '';
    this.closed = null;
    this.child = spawn('pwsh', [
      '-NoProfile', '-NonInteractive', '-File', SESSION_SCRIPT, '-ScriptPath', DELTA_SCRIPT,
    ], { cwd: directory, stdio: ['pipe', 'pipe', 'pipe'] });
    this.child.stdout.setEncoding('utf8');
    this.child.stderr.resume();
    this.child.stdout.on('data', chunk => this.onData(chunk));
    this.exitPromise = new Promise(resolve => {
      this.child.on('exit', (code, signal) => {
        this.closed = new Error(`signature delta session exited (code ${code}, signal ${signal})`);
        for (const entry of this.pending.splice(0)) entry.reject(this.closed);
        resolve();
      });
      this.child.on('error', error => {
        this.closed = error;
        for (const entry of this.pending.splice(0)) entry.reject(error);
        resolve();
      });
    });
  }

  onData(chunk) {
    this.buffer += chunk;
    let index;
    while ((index = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, index).replace(/\r$/, '');
      this.buffer = this.buffer.slice(index + 1);
      const entry = this.pending.shift();
      if (!entry) continue;
      const space = line.indexOf(' ');
      const status = space < 0 ? line : line.slice(0, space);
      const payload = space < 0 ? '' : line.slice(space + 1);
      const text = Buffer.from(payload, 'base64').toString('utf8');
      if (status === 'OK') entry.resolve(text);
      else entry.reject(new Error(text || 'signature delta session failed'));
    }
  }

  // Resolves with the parsed delta (same shape as the script's JSON output) or
  // rejects with the script's error message, exactly like a direct invocation.
  request(baseRef, headRef) {
    if (this.closed) return Promise.reject(this.closed);
    return new Promise((resolve, reject) => {
      this.pending.push({ resolve: text => { try { resolve(JSON.parse(text)); } catch (error) { reject(error); } }, reject });
      this.child.stdin.write(`${baseRef}\t${headRef}\n`);
    });
  }

  async close() {
    if (!this.closed) this.child.stdin.end();
    await this.exitPromise;
  }
}

// One session per fixture repository; the session is closed even when the test
// body throws.
function withSignatureDeltaSession(directory, body) {
  const session = new SignatureDeltaSession(directory);
  return Promise.resolve()
    .then(() => body(session))
    .finally(() => session.close());
}

module.exports = { SignatureDeltaSession, withSignatureDeltaSession, SESSION_SCRIPT, DELTA_SCRIPT };
