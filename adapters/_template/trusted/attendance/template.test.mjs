import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const code=await readFile(new URL('./index.js',import.meta.url),'utf8');
const {capabilities,createAttendanceHandler}=await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
for(const kind of ['button','qr','photo','face-image','location']) {
  test(`${kind}: explicit input, one binary submit and independent verification`,async()=>{
    const calls=[], inputs=[];
    const image={bytes:new Uint8Array([137,80,78,71,0,128,255]),mimeType:'image/png',width:1,height:1};
    const ctx={now:()=>123,credentials:{get:async()=>({value:'SYNTHETIC'})},ui:{
      requestInput:async()=>({kind}),scanQRCode:async()=>{inputs.push('qr');return {text:'SYNTHETIC_QR'};},
      capturePhoto:async()=>{inputs.push('photo');return image;},pickImage:async()=>{inputs.push('face-image');return image;},
      getCurrentPosition:async()=>{inputs.push('location');return {latitude:12,longitude:34,accuracyMeters:8,capturedAt:'2026-11-02T00:00:00Z',coordinateSystem:'wgs84'};},
    },fetch:async(url,init)=>{calls.push({url,...init});return {json:async()=>calls.length===1?{requestId:'synthetic'}:{requestId:'synthetic',status:'confirmed'}};}};
    assert.deepEqual(await createAttendanceHandler({configured:true,origin:'https://attendance.example.invalid'})(ctx),{status:'confirmed'});
    assert.equal(calls.length,2);assert.equal(calls[0].method,'POST');assert.equal(calls[0].redirect,'error');assert.ok(calls[0].body instanceof Uint8Array);assert.equal(calls[1].method,undefined);
    assert.deepEqual(inputs,kind==='button'?[]:[kind]);
  });
}
test('unconfigured template never prompts or sends',async()=>{await assert.rejects(()=>capabilities['attendance.checkin']({}),{code:'configuration_required'});});
test('lost submit response never retries or invents success',async()=>{
 let sends=0;
 const ctx={now:()=>123,credentials:{get:async()=>({value:'SYNTHETIC'})},ui:{requestInput:async()=>({kind:'button'})},fetch:async()=>{sends++;throw Error('synthetic network loss');}};
 assert.deepEqual(await createAttendanceHandler({configured:true,origin:'https://attendance.example.invalid'})(ctx),{status:'unknown'});assert.equal(sends,1);
});
