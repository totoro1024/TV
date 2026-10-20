#!/usr/bin/env python3
"""从 XCTest 合同测试生成 CLT 独立运行入口，保证两种运行器覆盖相同用例。"""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
chunks=[]; calls=[]; count=0
for name in ['ProtocolTests','SyncEngineTests']:
 text=(root/'Tests/TVCoreTests'/f'{name}.swift').read_text()
 for method,attributes in re.findall(r'func (test\w+)\(\)([^\{]*)\{',text):
  calls.append('        '+('try ' if 'throws' in attributes else '')+('await ' if 'async' in attributes else '')+name[0].lower()+name[1:]+'.'+method+'()')
  count+=1
 text=text.replace('import XCTest','import Foundation').replace('@testable import TVCore','import TVCore').replace(': XCTestCase','')
 for a,b in [('XCTAssertEqual','checkEqual'),('XCTAssertTrue','checkTrue'),('XCTAssertFalse','checkFalse'),('XCTAssertNotNil','checkNotNil'),('XCTAssertThrowsError','checkThrows'),('XCTFail','checkFail')]:text=text.replace(a,b)
 chunks.append(text)
(root/'Sources/TVCoreChecks/Checks.swift').write_text('// 自动从 Tests/TVCoreTests 生成；修改测试后运行 scripts/generate-checks.py。\n'+'\n'.join(chunks))
p=root/'Sources/TVCoreChecks/Runner.swift'; old=p.read_text();old=old[:old.index('@main struct Runner')]
old+='@main struct Runner {\n    static func main() async throws {\n        let protocolTests = ProtocolTests()\n        let syncEngineTests = SyncEngineTests()\n'+'\n'.join(calls)+'\n        if let address = ProcessInfo.processInfo.environment["TVCORE_LOCAL_DAV"] { try await HTTPChecks.run(address: address) }'+f'\n        print("{count} 项核心合同校验通过（独立 Swift 运行器）")\n    }}\n}}\n'
p.write_text(old)
