#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在已安装的调试应用中播放测试视频，检测运行时缺类及实际播放状态。"""
import argparse
import functools
import http.server
import re
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--adb', default='adb')
parser.add_argument('--serial', required=True)
parser.add_argument('--fixture', type=Path, required=True)
parser.add_argument('--with-siblings', action='store_true')
args = parser.parse_args()
adb = [args.adb, '-s', args.serial]
package = 'com.fongmi.android.tv.webdav'

def run(*items):
    return subprocess.run(adb + list(items), capture_output=True, text=True, timeout=12)

class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

with tempfile.TemporaryDirectory(prefix='webdav-mp4-repro-') as directory:
    fixture = Path(directory) / args.fixture.name
    if args.with_siblings:
        shutil.copytree(args.fixture.parent, directory, dirs_exist_ok=True)
    else:
        shutil.copyfile(args.fixture, fixture)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Quiet, directory=directory))
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    if run('reverse', f'tcp:{port}', f'tcp:{port}').returncode:
        raise SystemExit('无法建立模拟设备与本机测试服务的连接')
    log = subprocess.Popen(adb + ['logcat', '-T', '1', '-v', 'brief', 'AndroidRuntime:E', 'CustomActivityOnCrash:E', '*:S'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    lines = []
    def consume():
        for line in log.stdout:
            lines.append(line)
    threading.Thread(target=consume, daemon=True).start()
    try:
        run('shell', 'am', 'force-stop', package)
        time.sleep(0.3)
        opened = run('shell', 'am', 'start', '-W', '-a', 'android.intent.action.SEND', '-t', 'text/plain', '--es', 'android.intent.extra.TEXT', f'http://127.0.0.1:{port}/{fixture.name}', '-p', package)
        if opened.returncode:
            raise SystemExit('无法启动测试播放入口')
        playing = False
        for _ in range(16):
            time.sleep(0.5)
            text = ''.join(lines)
            if package in text and ('NoClassDefFoundError' in text or 'FATAL EXCEPTION' in text):
                missing = sorted(set(re.findall(r'(?:Failed resolution of: L|Didn.t find class ")([^;"\s]+)', text)))
                print('失败：播放触发应用崩溃；缺失类：' + ', '.join(missing))
                raise SystemExit(1)
            sessions = run('shell', 'dumpsys', 'media_session').stdout
            if package in sessions and re.search(r'state=3[,\s]', sessions):
                playing = True
        if not playing:
            print('失败：未进入系统报告的播放状态（本脚本不输出媒体地址或配置）')
            raise SystemExit(1)
        print('通过：测试视频 已进入播放状态，观察期内没有捕获应用崩溃')
    finally:
        log.terminate()
        log.wait(timeout=5)
        run('reverse', '--remove', f'tcp:{port}')
        server.shutdown()
