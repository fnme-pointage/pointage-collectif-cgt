const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{chromium}=require('playwright');
let stub=fs.readFileSync(path.join(__dirname,'catalogue_ui.cjs'),'utf8').match(/const stub = `([\s\S]*?)`;/)[1].replace('MODE','true');
stub+=`
ensure('ulm',2025);ensure('ufpi',2026);
db.profiles.push({id:'user',unit_id:'ulm',full_name:'Militant ULM',email:'ulm@example.invalid',active:true,is_admin:false},{id:'user2',unit_id:'ufpi',full_name:'Militant UFPI',email:'ufpi@example.invalid',active:true,is_admin:false});
db.entries.push({id:2,user_id:'user',unit_id:'ulm',month_key:'2026-09',code_id:101,hours:99,saved_code:'D4'}, {id:3,user_id:'user',unit_id:'ulm',month_key:'2026-10',code_id:999,hours:.5,duration_seconds:1800,saved_code:'NOUVEAU',saved_label:'Nouveau code'}, {id:4,user_id:'user',unit_id:'ulm',month_key:'2025-10',code_id:998,hours:2,saved_code:'D4'}, {id:5,user_id:'user2',unit_id:'ufpi',month_key:'2026-10',code_id:997,hours:4,saved_code:'UF'}, {id:6,user_id:'admin',unit_id:'ulm',month_key:'2026-10',code_id:996,hours:100,saved_code:'ADMIN'});
`;
(async()=>{
const options={headless:true};if(process.env.CHROMIUM_EXECUTABLE)options.executablePath=process.env.CHROMIUM_EXECUTABLE;if(process.env.CHROMIUM_ARGS)options.args=JSON.parse(process.env.CHROMIUM_ARGS);
const browser=await chromium.launch(options);
for(const width of [390,1440]){
 const context=await browser.newContext({viewport:{width,height:1000},acceptDownloads:true}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(10000);
 await page.clock.install({time:new Date('2026-10-02T08:00:00Z')});
 await page.route('**/supabase-js@2',r=>r.fulfill({contentType:'application/javascript',body:stub}));
 await page.route('https://pointage.test/**',r=>{const f=path.resolve('app',new URL(r.request().url()).pathname.slice(1)||'index.html');return fs.existsSync(f)?r.fulfill({path:f}):r.fulfill({status:404,body:''});});
 await page.goto('https://pointage.test/');await page.locator('#adminUnit').waitFor();assert.equal(await page.locator('#monthlyFollowup').isVisible(),false);
 await page.locator('#adminUnit').selectOption('ulm');await page.waitForFunction(()=>!document.querySelector('#exportMonthlySummary').disabled,{},{timeout:10000});
 assert.equal(await page.locator('#monthlyFollowup').isVisible(),true);assert.equal(await page.locator('#monthlyYear').inputValue(),'2026');assert.equal(await page.locator('#monthlyMonth').inputValue(),'10');assert.equal(await page.locator('#monthlyMonth option').count(),12);
 const text=await page.locator('#monthlySummaryTable').textContent();assert.match(text,/NOUVEAU/);assert.match(text,/8/);assert.doesNotMatch(text,/ADMIN|99/);
 async function download(id){const [d]=await Promise.all([page.waitForEvent('download'),page.locator(id).click()]);return {name:d.suggestedFilename(),text:fs.readFileSync(await d.path(),'utf8')};}
 const recap=await download('#exportMonthlySummary');assert.match(recap.name,/mensuel-ULM-2026-10/);assert.match(recap.text,/"2026-10"/);assert.match(recap.text,/"8"/);assert.match(recap.text,/"28800"/);assert.doesNotMatch(recap.text,/2026-09|UFPI|"ADMIN"/);
 const detail=await download('#exportMonthlyRaw');assert.match(detail.text,/Nouveau code/);assert.doesNotMatch(detail.text,/2026-09|2025-10|"99"|"ADMIN"/);
 await page.locator('#monthlyMonth').selectOption('09');await page.waitForFunction(()=>document.querySelector('#monthlyStats').textContent.includes('septembre'));assert.match(await page.locator('#monthlySummaryTable').textContent(),/99/);assert.equal(await page.locator('#annualYear').inputValue(),'2026');
 await page.locator('#monthlyYear').selectOption('2025');await page.locator('#monthlyMonth').selectOption('10');await page.waitForFunction(()=>document.querySelector('#monthlyStats').textContent.includes('octobre 2025'));assert.match(await page.locator('#monthlySummaryTable').textContent(),/2/);
 await page.locator('#monthlyMonth').selectOption('11');await page.waitForFunction(()=>document.querySelector('#monthlyStats').textContent.includes('0 saisies'));assert.equal(await page.locator('#exportMonthlySummary').isEnabled(),true);
 await page.locator('#adminUnit').selectOption('ufpi');await page.waitForFunction(()=>document.querySelector('#monthlyStats').textContent.includes('UFPI'));assert.match(await page.locator('#monthlySummaryTable').textContent(),/UF/);assert.doesNotMatch(await page.locator('#monthlySummaryTable').textContent(),/Militant ULM/);
 await page.screenshot({path:'/tmp/monthly-followup-'+width+'.png',fullPage:true});
 await page.locator('#adminUnit').selectOption('adminunit');await page.waitForFunction(()=>document.querySelector('#monthlyFollowup').classList.contains('hidden'));assert.deepEqual(errors,[]);
 await context.close();
}
await browser.close();console.log('PASS: monthly panel outside ADMIN, year/month filters, independent annual selection, historical codes, exact CSV totals, admin exclusion, unit isolation, empty month, mobile/desktop.');
})().catch(e=>{console.error(e);process.exit(1)});
