#!/usr/bin/env python3
"""Check the exact Git index for private files and credential-shaped strings.

Findings print paths/categories only, never matching content. An optional local
key comparison also catches this machine's key without displaying it.
"""
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
patterns = {
    'OpenAI credential': rb'sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{40,}',
    'GitHub credential': rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})',
    'private key': rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
    'AWS access key': rb'(?:AKIA|ASIA)[A-Z0-9]{16}',
    'Slack credential': rb'xox[baprs]-[A-Za-z0-9-]{20,}',
    'machine-specific home': rb'/Users/(?:L|lisa|luke)/',
}
actual_key = None
key_file = Path.home() / 'secrets/openai.env'
if key_file.is_file():
    for line in key_file.read_text().splitlines():
        match = re.match(r'\s*(?:export\s+)?OPENAI_API_KEY\s*=\s*(.+)', line)
        if match:
            candidate = match.group(1).strip().strip('"\'')
            if len(candidate) > 20 and candidate.startswith('sk-'):
                actual_key = candidate.encode()
            break
findings = []
for name in filter(None, files):
    path = Path(name)
    if (any(part in {'History', 'build', 'secrets', '.git', 'xcuserdata'} for part in path.parts)
            or path.name.startswith('.env') or path.suffix in {'.env', '.pem', '.key', '.p12', '.pfx', '.log', '.ips'}):
        findings.append((name, 'private/generated file'))
    # Audit staged bytes, not working-tree bytes that may differ from the commit.
    data = subprocess.check_output(['git', 'show', ':' + name], cwd=root)
    if actual_key and actual_key in data:
        findings.append((name, 'local OpenAI key'))
    for category, pattern in patterns.items():
        if re.search(pattern, data):
            findings.append((name, category))
if findings:
    for name, category in findings:
        print(f'BLOCKED: {name}: {category}', file=sys.stderr)
    sys.exit(1)
print(f'Public-file audit passed: {len(list(filter(None, files)))} indexed files; no detected credentials or private/generated paths.')
