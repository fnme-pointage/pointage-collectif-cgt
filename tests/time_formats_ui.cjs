const fs=require('node:fs'),assert=require('node:assert/strict'),path=require('node:path');
const {chromium}=require('playwright');
let stub=fs.readFileSync(path.join(__dirname,'catalogue_ui.cjs'),'utf8').match(/const stub = `([\s\S]*?)`;/)[1].replace('MODE','false');
stub=stub.replace('window.calls.push({name,args});',`window.calls.push({name,args});if(name==='pointage_save_entries'){db.entries=db.entries.filter(e=>e.user_id!==p.id||e.month_key!==args.p_month_key).concat(args.p_entries.map(e=>{const c=db.month_codes.find(c=>c.id===e.code_id);return {...e,id:e.code_id,user_id:p.id,unit_id:args.p_unit_id,month_key:args.p_month_key,hours:Math.round(e.duration_seconds/3600*100)/100,saved_code:c.code,saved_label:c.label,saved_document:c.document};}));}`);
(async()=>{
 const options={headless:true};if(process.env.CHROMIUM_EXECUTABLE)options.executablePath=process.env.CHROMIUM_EXECUTABLE;if(process.env.CHROMIUM_ARGS)options.args=JSON.parse(process.env.CHROMIUM_ARGS);
 const browser=await chromium.launch(options);
 for(const width of [390,1440]){
  const context=await browser.newContext({viewport:{width,height:1000}}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.clock.install({time:new Date('2026-10-01T10:00:00Z')});
  await page.route('**/supabase-js@2',r=>r.fulfill({contentType:'application/javascript',body:stub}));
  await page.route('https://pointage.test/**',r=>{const f=path.resolve('app',new URL(r.request().url()).pathname.slice(1)||'index.html');return fs.existsSync(f)?r.fulfill({path:f}):r.fulfill({status:404,body:''});});
  await page.goto('https://pointage.test/');await page.locator('#entryHours0').waitFor();
  assert.equal(await page.locator('#entryHours0').inputValue(),'7,5');
  await page.locator('#timeInputMode').selectOption('clock');assert.equal(await page.locator('#entryHours0').inputValue(),'7:30');assert.match(await page.locator('#entrySaveStatus').textContent(),/Données enregistrées/);
  await page.locator('#entryHours0').fill('7:60');await page.locator('#saveEntries').click();assert.match(await page.locator('#userNotice').textContent(),/durée valide/);
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.name==='pointage_save_entries').length),0);
  await page.locator('#timeInputMode').selectOption('decimal');assert.equal(await page.locator('#timeInputMode').inputValue(),'clock');assert.equal(await page.locator('#entryHours0').inputValue(),'7:60');
  await page.locator('#entryHours0').fill('0:01');await page.locator('#saveEntries').click();await page.waitForFunction(()=>document.querySelector('#userNotice').textContent.includes('Tes données sont enregistrées'));
  assert.equal(await page.evaluate(()=>window.testDb.entries.find(e=>e.month_key==='2026-10').duration_seconds),60);assert.equal(await page.locator('#entryHours0').inputValue(),'0:01');
  await page.locator('#timeInputMode').selectOption('decimal');assert.equal(await page.locator('#entryHours0').inputValue(),'0,016667');assert.match(await page.locator('#entrySaveStatus').textContent(),/Données enregistrées/);
  await page.locator('#addEntry').click();await page.locator('#entryCode1').click();await page.locator('[data-pick-entry="1"][data-pick-code]').filter({hasText:'52'}).click();await page.locator('#entryHours1').fill('1,50');
  assert.equal(await page.locator('#userTotalDuration').textContent(),'1:31:00 (h:min:s)');
  await page.locator('#timeInputMode').selectOption('clock');assert.equal(await page.locator('#entryHours1').inputValue(),'1:30');await page.locator('#saveEntries').click();await page.waitForFunction(()=>document.querySelector('#userNotice').textContent.includes('Tes données sont enregistrées'));
  const saved=await page.evaluate(()=>window.calls.filter(c=>c.name==='pointage_save_entries').at(-1).args.p_entries.map(e=>e.duration_seconds));assert.deepEqual(saved,[60,5400]);
  await page.reload();await page.locator('#entryHours0').waitFor();assert.equal(await page.locator('#timeInputMode').inputValue(),'clock');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);assert.deepEqual(errors,[]);
  await page.screenshot({path:'/tmp/time-formats-'+width+'.png',fullPage:true});await context.close();
 }
 await browser.close();console.log('PASS: mobile/desktop modes, format switch preserves values and saved state, invalid input blocks, minute persists, mixed-format sums, preference restored.');
})().catch(e=>{console.error(e);process.exit(1)});
