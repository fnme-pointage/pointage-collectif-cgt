const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'..');
const stub=fs.readFileSync(path.join(__dirname,'catalogue_ui.cjs'),'utf8')
 .match(/const stub = `([\s\S]*?)`;/)[1].replace('MODE','false')
 .replace('db[this.t].filter','(db[this.t]||[]).filter');
(async()=>{
 const browser=await chromium.launch({headless:true});
 try{
  for(const width of [390,768,1440]){
   const context=await browser.newContext({viewport:{width,height:1000}});
   const page=await context.newPage();
   await page.clock.install({time:new Date('2026-10-01T10:00:00Z')});
   await page.route('**/supabase-js@2',r=>r.fulfill({contentType:'application/javascript',body:stub}));
   await page.route('https://pointage.test/**',r=>{
    const file=path.join(root,new URL(r.request().url()).pathname.slice(1)||'index.html');
    return fs.existsSync(file)?r.fulfill({path:file}):r.fulfill({status:404,body:''});
   });
   await page.goto('https://pointage.test/');
   await page.locator('#entryHours0').waitFor();
   await page.locator('#entryHours0').fill('8,25');
   await page.locator('#entryCode0').click();
   const picker=page.locator('[data-picker="0"]');
   assert.equal(await picker.getAttribute('open'),'');
   // The menu must extend outside its 48px field and remain reachable by pointer.
   assert.equal(await picker.evaluate(el=>getComputedStyle(el).overflow),'visible');
   await picker.locator('[data-pick-code]').filter({hasText:'52'}).click({timeout:3000});
   assert.match(await page.locator('#entryCode0').textContent(),/52/);
   assert.equal(await page.locator('#entryHours0').inputValue(),'8,25');
   assert.equal(await page.locator('[data-picker="0"]').getAttribute('open'),null);
   await page.locator('#addEntry').click();
   await page.locator('#entryCode1').click();
   await page.locator('#entryCode0').click();
   await page.waitForFunction(()=>!document.querySelector('[data-picker="1"]').open);
   assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
   await context.close();
   console.log('PASS code picker: '+width+'px, open, select, preserve hours, close other menu');
  }
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
