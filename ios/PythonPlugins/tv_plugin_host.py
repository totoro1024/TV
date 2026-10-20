"""只运行随应用打包的插件；不下载或执行远端 Python 代码。"""
import json
import sys
import types
import _tvcrypto

base = types.ModuleType('base')
spider_module = types.ModuleType('base.spider')
spider_module.Spider = type('Spider', (), {})
sys.modules['base'] = base
sys.modules['base.spider'] = spider_module

# 原插件只需要无填充 AES-CBC/CTR；由本机 CommonCrypto 提供。
class AES:
    MODE_CBC = 2
    MODE_CTR = 6
    @staticmethod
    def new(key, mode, iv=None, nonce=b'', initial_value=None):
        if mode == AES.MODE_CTR:
            iv = initial_value.to_bytes(16, 'big') if isinstance(initial_value, int) else initial_value
        class Cipher:
            def decrypt(self, data):
                return _tvcrypto.decrypt(mode, bytes(key), bytes(iv), bytes(data))
        return Cipher()

crypto = types.ModuleType('Crypto')
cipher = types.ModuleType('Crypto.Cipher')
cipher.AES = AES
sys.modules['Crypto'] = crypto
sys.modules['Crypto.Cipher'] = cipher

_key = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
_plain = bytes.fromhex('6bc1bee22e409f96e93d7e117393172a')
if _tvcrypto.decrypt(2, _key, bytes.fromhex('000102030405060708090a0b0c0d0e0f'), bytes.fromhex('7649abac8119b246cee98e9b12e9197d')) != _plain:
    raise RuntimeError('AES-CBC self check failed')
if _tvcrypto.decrypt(6, _key, bytes.fromhex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff'), bytes.fromhex('874d6191b620e3261bef6864990db6ce')) != _plain:
    raise RuntimeError('AES-CTR self check failed')

import hongguo
_plugin = hongguo.Spider()
_plugin.init()

def dispatch(method, payload):
    args = json.loads(payload)
    if method == 'home':
        result = _plugin.homeContent(False)
    elif method == 'browse':
        result = _plugin.categoryContent(args.get('category') or 'comic', str(args.get('page', 1)), False, {})
    elif method == 'search':
        result = _plugin.searchContent(args['keyword'], False, str(args.get('page', 1)))
    elif method == 'detail':
        result = _plugin.detailContent([args['id']])
    elif method == 'play':
        result = _plugin.playerContent(args.get('line', ''), args['id'], [])
    else:
        raise ValueError('unknown plugin method')
    return json.dumps(result, ensure_ascii=False)
