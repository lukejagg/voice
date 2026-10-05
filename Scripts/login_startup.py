#!/usr/bin/env python3
"""Manage only Voice's per-user login launcher; never read API credentials."""
import argparse
import os
import plistlib
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['enable', 'disable', 'status'])
args = parser.parse_args()
project = Path(__file__).resolve().parent.parent
with (project / 'Info.plist').open('rb') as f:
    label = plistlib.load(f)['CFBundleIdentifier'] + '.login'
agent = Path.home() / 'Library' / 'LaunchAgents' / (label + '.plist')
domain = f'gui/{os.getuid()}'
service = f'{domain}/{label}'
loaded = subprocess.run(['launchctl', 'print', service], capture_output=True).returncode == 0
if args.action == 'status':
    print('Enabled' if agent.exists() else 'Disabled')
elif args.action == 'disable':
    if loaded:
        subprocess.run(['launchctl', 'bootout', service], check=True)
    agent.unlink(missing_ok=True)
    print('Voice login startup disabled.')
else:
    app = project / 'build' / 'Voice.app'
    if not (app / 'Contents' / 'MacOS' / 'Voice').is_file():
        parser.error('Build Voice first with ./build.sh.')
    config = {'Label': label, 'ProgramArguments': ['/usr/bin/open', '-g', str(app)],
              'RunAtLoad': True, 'LimitLoadToSessionType': 'Aqua', 'ProcessType': 'Interactive'}
    agent.parent.mkdir(parents=True, exist_ok=True)
    with agent.open('wb') as f:
        plistlib.dump(config, f)
    agent.chmod(0o644)
    subprocess.run(['launchctl', 'enable', service], check=True)
    if loaded:
        subprocess.run(['launchctl', 'bootout', service], check=True)
    subprocess.run(['launchctl', 'bootstrap', domain, str(agent)], check=True)
    print('Voice will open quietly when you log in.')
