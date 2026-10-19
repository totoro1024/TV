#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""检查 APK 的真实 DEX 类定义，避免把类名引用误当作已经打包的实现。"""
import argparse
import struct
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('apk')
args = parser.parse_args()
required = {
    'Landroidx/media3/container/NalUnitUtil;',
    'Landroidx/media3/exoplayer/hls/HlsMediaSource$Factory;',
    'Landroidx/media3/exoplayer/dash/DashMediaSource$Factory;',
    'Landroidx/media3/exoplayer/rtsp/RtspMediaSource$Factory;',
    'Landroidx/media3/exoplayer/smoothstreaming/SsMediaSource$Factory;',
}
provided = set()
with zipfile.ZipFile(args.apk) as apk:
    for name in apk.namelist():
        if not name.startswith('classes') or not name.endswith('.dex'):
            continue
        data = apk.read(name)
        if not data.startswith(b'dex\n'):
            raise ValueError('不支持的 DEX 格式')
        def u32(offset):
            return struct.unpack_from('<I', data, offset)[0]
        strings = u32(60)
        types = u32(68)
        for i in range(u32(96)):
            class_index = u32(u32(100) + i * 32)
            string_index = u32(types + class_index * 4)
            position = u32(strings + string_index * 4)
            while data[position] & 128:
                position += 1
            position += 1
            descriptor = data[position:data.index(b'\0', position)].decode('utf-8')
            if descriptor in required:
                provided.add(descriptor)
missing = required - provided
if missing:
    print('失败，APK 缺少播放器实现：' + ', '.join(sorted(missing)))
    raise SystemExit(1)
print('通过：APK 包含容器解析器和 HLS/DASH/RTSP/SmoothStreaming 工厂类定义')
