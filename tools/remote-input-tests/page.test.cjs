// 验证真实手机页脚本的草稿、连续发送及输入目标切换逻辑。
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const html=fs.readFileSync(require('node:path').join(__dirname,'../../app/src/main/assets/remote-input/index.html'),'utf8');
function page(){
 const elements={};
 for(const id of ['text','secret','target','send','message','switch'])elements[id]={value:'',hidden:id==='secret'||id==='switch',disabled:false,textContent:'',handlers:{},addEventListener(k,v){this.handlers[k]=v;}};
 const requests=[];let state={ready:true,title:'服务器目录地址',revision:'a',password:false};let denied=false;
 const context=vm.createContext({document:{getElementById:id=>elements[id]},location:{pathname:'/remote-input/test-key'},URLSearchParams,setInterval(){},fetch:async(url,options={})=>{requests.push({url,...options});if(denied)return {ok:false,status:403};return {ok:true,json:async()=>state,text:async()=> '已发送到电视，请在电视上确认或搜索'};}});
 vm.runInContext(html.match(/<script>([\s\S]*?)<\/script>/)[1],context);
 return {elements,requests,run:s=>vm.runInContext(s,context),state:s=>state=s,deny:()=>denied=true};
}
const initial={ready:true,title:'账号',revision:'a',password:false};
test('同一链接可连续发送，成功后清除手机内容',async()=>{const p=page();await p.run('poll()');for(const value of ['第一次中文输入','第二次 & + = 输入']){p.elements.text.value=value;p.elements.text.handlers.input();await p.elements.send.onclick();assert.equal(p.elements.text.value,'');}const sent=p.requests.filter(r=>r.method==='POST');assert.equal(sent.length,2);assert.equal(sent[0].url,sent[1].url);assert.equal(new URLSearchParams(sent[1].body).get('text'),'第二次 & + = 输入');});
test('输入框变化后禁止将旧草稿发往新字段',async()=>{const p=page();await p.run('poll()');p.elements.text.value='账号草稿';p.elements.text.handlers.input();p.state({...initial,revision:'b',title:'密码'});await p.run('poll()');assert.equal(p.elements.send.disabled,true);assert.equal(p.elements.switch.hidden,false);await p.elements.send.onclick();assert.equal(p.requests.filter(r=>r.method==='POST').length,0);p.elements.switch.onclick();assert.equal(p.elements.text.value,'');assert.equal(p.elements.send.disabled,false);});
test('WebDAV 明文密码沿用普通输入，其他密码采用密码框',async()=>{const p=page();p.state({...initial,title:'密码',password:false});await p.run('poll()');assert.equal(p.elements.text.hidden,false);assert.equal(p.elements.secret.hidden,true);p.state({...initial,revision:'b',password:true});await p.run('poll()');assert.equal(p.elements.text.hidden,true);assert.equal(p.elements.secret.hidden,false);});
test('没有电视输入框或连接重置时不能发送',async()=>{const p=page();p.state({...initial,ready:false});await p.run('poll()');assert.equal(p.elements.send.disabled,true);p.deny();await p.run('poll()');assert.equal(p.elements.send.disabled,true);assert.match(p.elements.message.textContent,/重新扫描/);});
