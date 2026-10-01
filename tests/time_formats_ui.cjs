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
  assert.equal(await page.locator('#timeInputMode').count(),0);
  assert.match(await page.locator('#timeInputHelp').locator('..').textContent(),/Merci de reporter les éléments de vos CRI/);
  await page.locator('#entryHours0').fill('7:30');await page.locator('#saveEntries').click();assert.match(await page.locator('#userNotice').textContent(),/heures décimales valides/);
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.name==='pointage_save_entries').length),0);
  await page.locator('#entryHours0').fill('7,50');await page.locator('#saveEntries').click();await page.waitForFunction(()=>document.querySelector('#userNotice').textContent.includes('Tes données sont enregistrées'));
  assert.equal(await page.evaluate(()=>window.testDb.entries.find(e=>e.month_key==='2026-10').duration_seconds),27000);
  await page.evaluate(()=>localStorage.setItem('pointage-time-format:'+window.testDb.profiles[0].id,'clock'));
  await page.reload();await page.locator('#entryHours0').waitFor();assert.equal(await page.locator('#entryHours0').inputValue(),'7,5');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);assert.deepEqual(errors,[]);
  await page.screenshot({path:'/tmp/time-formats-'+width+'.png',fullPage:true});await context.close();
 }
 await browser.close();console.log('PASS: decimal-only entry and CRI reminder on mobile/desktop, clock input rejected, save works.');
})().catch(e=>{console.error(e);process.exit(1)});
