const fs=require('node:fs'),assert=require('node:assert/strict'),path=require('node:path');
const {chromium}=require('playwright');
let stub=fs.readFileSync(path.join(__dirname,'catalogue_ui.cjs'),'utf8').match(/const stub = `([\s\S]*?)`;/)[1].replace('MODE','false');
stub=stub.replace('from:t=>new Query(t),',`from:t=>new Query(t),functions:{invoke:async(name,args)=>{window.contactCalls=(window.contactCalls||0)+1;window.contactRequest={name,args};if(window.contactMode==='pending')return new Promise(resolve=>{window.contactResolve=resolve});if(window.contactMode==='rate')return {data:null,error:{context:new Response(JSON.stringify({error:'RATE_LIMIT'}),{status:429})}};if(window.contactMode==='fail')throw new Error('Network failed');return {data:{sent:true},error:null};}},`);
(async()=>{
 const options={headless:true};if(process.env.CHROMIUM_EXECUTABLE)options.executablePath=process.env.CHROMIUM_EXECUTABLE;if(process.env.CHROMIUM_ARGS)options.args=JSON.parse(process.env.CHROMIUM_ARGS);
 const browser=await chromium.launch(options);
 for(const width of [390,1440]){
  const context=await browser.newContext({viewport:{width,height:1000}}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/supabase-js@2',r=>r.fulfill({contentType:'application/javascript',body:stub}));
  await page.route('https://pointage.test/**',r=>{const f=path.resolve('app',new URL(r.request().url()).pathname.slice(1)||'index.html');return fs.existsSync(f)?r.fulfill({path:f}):r.fulfill({status:404,body:''});});
  await page.goto('https://pointage.test/');await page.locator('#mainView').waitFor({state:'visible'});await page.locator('#contactAdminLink').click();
  await page.locator('#contactSend').click();assert.equal(await page.evaluate(()=>window.contactCalls||0),0);
  await page.locator('#contactMessage').fill('Mon message de test');await page.evaluate(()=>{window.contactMode='fail'});await page.locator('#contactSend').click();
  await page.waitForFunction(()=>document.querySelector('#contactFeedback').textContent.includes('conservé'));assert.equal(await page.locator('#contactMessage').inputValue(),'Mon message de test');
  await page.locator('#contactClose').click();await page.locator('#contactAdminLink').click();assert.equal(await page.locator('#contactMessage').inputValue(),'Mon message de test');
  await page.evaluate(()=>{window.contactMode='rate'});await page.locator('#contactSend').click();await page.waitForFunction(()=>document.querySelector('#contactFeedback').textContent.includes('trois envois'));assert.equal(await page.locator('#contactMessage').inputValue(),'Mon message de test');
  await page.evaluate(()=>{window.contactMode='pending'});await page.locator('#contactSend').click();await page.waitForFunction(()=>!!window.contactResolve);
  assert.equal(await page.locator('#contactClose').isDisabled(),true);await page.keyboard.press('Escape');assert.equal(await page.locator('#contactAdminDialog').isVisible(),true);
  await page.evaluate(()=>document.querySelector('#contactAdminForm').dispatchEvent(new Event('submit',{cancelable:true})));
  assert.equal(await page.evaluate(()=>window.contactCalls),3);assert.equal(await page.evaluate(()=>window.contactRequest.name),'contact-admin');
  await page.evaluate(()=>window.contactResolve({data:{sent:true},error:null}));await page.waitForFunction(()=>document.querySelector('#contactFeedback').textContent.includes('a été envoyé'));
  assert.equal(await page.locator('#contactMessage').inputValue(),'');assert.equal(await page.locator('#contactSend').isDisabled(),false);assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);assert.deepEqual(errors,[]);
  await page.screenshot({path:'/tmp/contact-admin-'+width+'.png',fullPage:true});await context.close();
 }
 await browser.close();console.log('PASS: mobile/desktop popup, required message, failure draft retained, rate limit feedback, duplicate blocked, success clears message; mocked transport only.');
})().catch(e=>{console.error(e);process.exit(1)});
