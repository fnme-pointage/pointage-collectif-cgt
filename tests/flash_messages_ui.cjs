const fs=require('fs'),path=require('path'),assert=require('node:assert/strict'),{chromium}=require('playwright');
const base=fs.readFileSync(path.join(__dirname,'catalogue_ui.cjs'),'utf8').match(/const stub = `([\s\S]*?)`;/)[1];
const rpc=`window.calls.push({name,args});
if(name==='pointage_list_flash_messages')return {data:{server_now:new Date().toISOString(),messages:window.flashRows},error:null};
if(name==='pointage_get_flash_messages')return {data:{server_now:new Date().toISOString(),messages:window.flashRows.filter(m=>!m.cancelled_at&&Date.parse(m.starts_at)<=Date.now()&&Date.parse(m.ends_at)>Date.now())},error:null};
if(name==='pointage_create_flash_message'){if(!window.flashRows.some(m=>m.id===args.p_id))window.flashRows.unshift({id:args.p_id,title:args.p_title,body:args.p_body,starts_at:args.p_start,ends_at:args.p_end,send_email:args.p_email,email_sent:0,email_pending:args.p_email?2:0,email_failed:0,email_skipped:0});return {data:args.p_id,error:null};}
if(name==='pointage_stop_flash_message'){window.flashRows.find(m=>m.id===args.p_id).cancelled_at=new Date().toISOString();return {data:null,error:null};}
`;
(async()=>{
const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_EXECUTABLE,args:JSON.parse(process.env.CHROMIUM_ARGS||'[]')});
for(const width of [390,1440])for(const admin of [true,false]){
 const context=await browser.newContext({viewport:{width,height:1000}}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(10000);
 await page.clock.install({time:new Date('2026-10-02T11:00:00Z')});
 const stub=base.replace('MODE',String(admin)).replace('window.calls.push({name,args});',rpc)+`window.flashRows=[];`;
 await page.route('**/supabase-js@2',r=>r.fulfill({contentType:'application/javascript',body:stub}));
 await page.route('https://pointage.test/**',r=>{const f=path.resolve('app',new URL(r.request().url()).pathname.slice(1)||'index.html');return fs.existsSync(f)?r.fulfill({path:f}):r.fulfill({status:404,body:''});});
 await page.goto('https://pointage.test/');await page.locator('#mainView').waitFor();
 if(admin){
  await page.locator('[data-admin-tab="flash"]').click();await page.getByText('Aucun message flash publié.').waitFor();assert.equal(await page.locator('#flashEmail').isChecked(),false);assert.equal(await page.locator('#admin-results').isVisible(),false);
  await page.locator('#flashTitle').fill('Information <test>');await page.locator('#flashBody').fill('Ligne 1\nLigne 2 & fin');await page.locator('#flashStart').fill('2026-10-02T10:00');await page.locator('#flashEnd').fill('2026-10-03T10:00');await page.locator('#publishFlash').click();await page.locator('#flashFeedback').getByText(/Message publié dans/).waitFor();
  assert.match(await page.locator('#flashHistory').textContent(),/Information <test>/);assert.equal(await page.locator('#flashHistory test').count(),0);assert.equal(await page.evaluate(()=>window.calls.find(c=>c.name==='pointage_create_flash_message').args.p_email),false);
  await page.locator('#flashTitle').fill('Préavis');await page.locator('#flashBody').fill('Information prévue');await page.locator('#flashStart').fill('2026-10-03T10:00');await page.locator('#flashEnd').fill('2026-10-04T10:00');await page.locator('#flashEmail').check();await page.locator('#publishFlash').click();await page.locator('#confirmAccept').click();await page.locator('#flashFeedback').getByText(/mails sont mis en file/).waitFor();
  assert.match(await page.locator('#flashHistory').textContent(),/Programmé/);assert.match(await page.locator('#flashHistory').textContent(),/2 en attente/);
  await page.locator('[data-stop-flash]').first().click();await page.locator('#confirmAccept').click();await page.waitForFunction(()=>document.querySelector('#flashHistory').textContent.includes('Arrêté'));
  await page.locator('#flashTitle').fill('Dates invalides');await page.locator('#flashBody').fill('Test');await page.locator('#flashStart').fill('2026-10-04T10:00');await page.locator('#flashEnd').fill('2026-10-03T10:00');await page.locator('#publishFlash').click();assert.match(await page.locator('#flashFeedback').textContent(),/fin postérieure/);
  assert.equal(await page.locator('#flashBanner').isVisible(),false);await page.screenshot({path:'/tmp/flash-admin-'+width+'.png',fullPage:true});
 }else{
  assert.equal(await page.locator('[data-admin-tab="flash"]').isVisible(),false);
  await page.evaluate(()=>{window.flashRows=[{id:'current',title:'Alerte <test>',body:'Information & détails\nDeuxième ligne',starts_at:new Date(Date.now()-1000).toISOString(),ends_at:new Date(Date.now()+8000).toISOString()},{id:'future',title:'Plus tard',body:'Futur',starts_at:new Date(Date.now()+60000).toISOString(),ends_at:new Date(Date.now()+120000).toISOString()}];document.dispatchEvent(new Event('visibilitychange'));});
  await page.locator('#flashBanner').waitFor();assert.match(await page.locator('#flashBanner').textContent(),/Alerte <test>/);assert.doesNotMatch(await page.locator('#flashBanner').textContent(),/Plus tard/);assert.equal(await page.locator('#flashBanner test').count(),0);await page.screenshot({path:'/tmp/flash-user-'+width+'.png',fullPage:true});
  await page.clock.runFor(9000);assert.equal(await page.locator('#flashBanner').isVisible(),false);
  await page.clock.runFor(85000);await page.locator('#flashBanner').waitFor();assert.match(await page.locator('#flashBanner').textContent(),/Plus tard/);
  await page.evaluate(()=>{window.flashRows[1].cancelled_at=new Date().toISOString();document.dispatchEvent(new Event('visibilitychange'));});await page.waitForFunction(()=>document.querySelector('#flashBanner').classList.contains('hidden'));
 }
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'horizontal overflow');assert.deepEqual(errors,[]);await context.close();
}
await browser.close();console.log('PASS: mobile/desktop tab, dates, optional mail, schedule/history/stop, escaping, user visibility/expiry/programmed appearance/cancellation without reload; no real mail.');
})().catch(e=>{console.error(e);process.exit(1)});
