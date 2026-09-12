#!/usr/bin/env python3
"""Exercise the compiled AT utility on real PTYs, never physical modems.

Run in a disposable container: the unpatched utility leaves named semaphores
behind when killed. argv[1] is the compiled tom_modem binary.
"""
import os
import pty
import select
import subprocess
import sys
import time

binary = sys.argv[1]
children = []
fds = []

def port():
    master, slave = pty.openpty()
    fds.extend([master, slave])
    return master, os.ttyname(slave)

def start(device, label):
    p = subprocess.Popen([binary, '-d', device, '-o', 'a', '-c', 'AT+' + label, '-t', '3'],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    children.append(p)
    return p

def command(master, label, wait=3):
    received = b''
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.05)[0]:
            received += os.read(master, 4096)
            if b'\n' in received:
                break
    assert received.strip() == ('AT+' + label).encode(), (label, received)

def quiet(master):
    assert not select.select([master], [], [], 0.3)[0], 'overlapping AT commands on one physical port'

def reply(master, label):
    os.write(master, ('\r\n+' + label + ': 1\r\nOK\r\n').encode())

def done(p, label):
    stdout, stderr = p.communicate(timeout=4)
    assert p.returncode == 0, (p.returncode, stderr)
    assert ('+' + label + ': 1').encode() in stdout and b'OK' in stdout, stdout

try:
    master, device = port()
    a = start(device, 'A')
    command(master, 'A')
    b = start(device, 'B')
    quiet(master)
    reply(master, 'A')
    done(a, 'A')
    command(master, 'B')
    c = start(device, 'C')
    quiet(master)  # old sem_unlink creates a second lock while B holds the first
    other_master, other_device = port()
    independent = start(other_device, 'OTHER')
    command(other_master, 'OTHER')
    reply(other_master, 'OTHER')
    done(independent, 'OTHER')
    reply(master, 'B')
    done(b, 'B')
    command(master, 'C')
    reply(master, 'C')
    done(c, 'C')
    print('PASS: queued AT requests keep one lock; separate modems run independently')

    owner = start(device, 'OWNER')
    command(master, 'OWNER')
    waiter = start(device, 'WAITER')
    quiet(master)
    owner.kill()
    owner.communicate(timeout=3)
    command(master, 'WAITER')
    reply(master, 'WAITER')
    done(waiter, 'WAITER')
    print('PASS: SIGKILL releases ownership without a stale lock')

    p = start(device, 'TIMEOUT')
    command(master, 'TIMEOUT')
    p.communicate(timeout=5)
    assert p.returncode != 0, 'AT transport timeout must not report success'
    p = start(device, 'AFTER_TIMEOUT')
    command(master, 'AFTER_TIMEOUT')
    reply(master, 'AFTER_TIMEOUT')
    done(p, 'AFTER_TIMEOUT')
    p = subprocess.run([binary, '--not-an-option'], capture_output=True, timeout=3)
    assert p.returncode != 0
    print('PASS: timeout/invalid arguments fail honestly and release the port')
finally:
    for p in children:
        if p.poll() is None:
            p.kill()
        p.communicate(timeout=3)
    for fd in fds:
        os.close(fd)
