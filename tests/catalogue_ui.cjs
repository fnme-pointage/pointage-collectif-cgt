const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const stub = `
window.calls=[];
const adminMode=MODE;
const unitList=[{id:'adminunit',name:'ADMIN',active:true},{id:'ulm',name:'ULM',active:true},{id:'ufpi',name:'UFPI',active:true}];
const p={id:adminMode?'admin':'user',unit_id:adminMode?'adminunit':'ulm',full_name:adminMode?'Administrateur test':'Utilisateur test',email:'test@example.invalid',is_admin:adminMode,active:true};
const db={profiles:[p],units:unitList,months:[],month_codes:[],entries:[],pointage_maintenance:[{id:true,locked:false}],pointage_documents:[],pointage_code_versions:[{id:1,catalogue_id:'ds',unit_id:'ulm',effective_month:'1900-01',code:'D4',label:'HEURE DS',document:'Accord DS',active:true},{id:2,catalogue_id:'greve',unit_id:'ulm',effective_month:'1900-01',code:'52',label:'GREVE',document:'Référence grève',active:true}]};
window.testDb=db;
function ensure(unit,year){if(unit==='adminunit')return;for(let n=1;n<=12;n++){const key=year+'-'+String(n).padStart(2,'0');if(db.months.some(m=>m.unit_id===unit&&m.month_key===key))continue;db.months.push({unit_id:unit,month_key:key,is_open:true});for(const c of db.pointage_code_versions.filter(c=>c.unit_id===unit))db.month_codes.push({...c,id:db.month_codes.length+100,month_key:key});}}
ensure('ulm',2026);const ownCode=db.month_codes.find(c=>c.month_key==='2026-10'&&c.code==='D4');db.entries.push({id:1,user_id:'user',unit_id:'ulm',month_key:'2026-10',code_id:ownCode.id,hours:7.5,saved_code:'D4',saved_label:'HEURE DS historique',saved_document:'Accord historique'});
class Query{constructor(t){this.t=t;this.filters=[];this.orders=[];this.one=false;this.start=0;this.end=Infinity;}select(){return this;}eq(k,v){this.filters.push(r=>r[k]===v);return this;}gte(k,v){this.filters.push(r=>r[k]>=v);return this;}lt(k,v){this.filters.push(r=>r[k]<v);return this;}lte(k,v){this.filters.push(r=>r[k]<=v);return this;}order(k,o={}){this.orders.push([k,o.ascending!==false]);return this;}range(a,b){this.start=a;this.end=b;return this;}single(){this.one=true;return this;}then(resolve,reject){let rows=db[this.t].filter(r=>this.filters.every(f=>f(r)));for(const[k,asc]of this.orders.toReversed())rows.sort((a,b)=>String(a[k]).localeCompare(String(b[k]))*(asc?1:-1));rows=rows.slice(this.start,this.end+1);return Promise.resolve({data:structuredClone(this.one?rows[0]:rows),error:null}).then(resolve,reject);}}
window.supabase={createClient:()=>({from:t=>new Query(t),auth:{getSession:async()=>({data:{session:{user:{id:p.id}}}}),onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),signOut:async()=>({error:null})},rpc:async(name,args)=>{window.calls.push({name,args});if(name==='pointage_set_maintenance')db.pointage_maintenance[0].locked=args.p_locked;if(name==='pointage_save_entries'&&window.failNextSave){window.failNextSave=false;db.pointage_maintenance[0].locked=true;return {data:null,error:{message:'Saisies bloquées pour maintenance'}};}if(name==='pointage_ensure_year')ensure(args.p_unit_id,args.p_year);if(name==='pointage_save_catalogue'){for(const u of args.p_units)for(const c of args.p_changes){db.pointage_code_versions.push({...c,id:db.pointage_code_versions.length+1,unit_id:u,effective_month:args.p_effective});for(const m of db.month_codes.filter(m=>m.unit_id===u&&m.catalogue_id===c.catalogue_id&&m.month_key>=args.p_effective))Object.assign(m,c);}}return {data:null,error:null};}})};
`;
(async()=>{
 const options={headless:true};
 if(process.env.CHROMIUM_EXECUTABLE)options.executablePath=process.env.CHROMIUM_EXECUTABLE;
 if(process.env.CHROMIUM_ARGS)options.args=JSON.parse(process.env.CHROMIUM_ARGS);
 const browser=await chromium.launch(options);
 for(const mode of ['user','admin']){
  const context=await browser.newContext({viewport:mode==='user'?{width:390,height:844}:{width:1440,height:1000}});
  const page=await context.newPage(); const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.clock.install({time:new Date('2026-10-01T08:00:00Z')});
  await page.route('**/supabase-js@2',r=>r.fulfill({contentType:'application/javascript',body:stub.replace('MODE',mode==='admin'?'true':'false')}));
  await page.goto('http://127.0.0.1:8765/');await page.locator('#mainView').waitFor({state:'visible'});
  if(mode==='user'){
   await page.waitForFunction(()=>document.querySelectorAll('[data-space-month]').length===12);
   assert.equal(await page.locator('#spaceYear').inputValue(),'2026');
   await page.waitForFunction(()=>document.querySelector('.entry-reference')?.textContent.includes('Accord historique'));
   await page.screenshot({path:'/workspace/scratch/668e553454fa/user-mobile.png',fullPage:true});
   assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'mobile overflow');
   await page.locator('#entryHours0').fill('8,25');
   await page.evaluate(()=>{window.testDb.pointage_maintenance[0].locked=true;document.dispatchEvent(new Event('visibilitychange'));});
   await page.waitForFunction(()=>document.querySelector('#saveEntries').disabled && document.querySelector('#maintenanceBanner').textContent.includes('Maintenance en cours'));
   assert.equal(await page.locator('#entryHours0').inputValue(),'8,25');
   await page.evaluate(()=>{window.testDb.pointage_maintenance[0].locked=false;document.dispatchEvent(new Event('visibilitychange'));});
   await page.waitForFunction(()=>!document.querySelector('#saveEntries').disabled);
   assert.equal(await page.locator('#entryHours0').inputValue(),'8,25');
   await page.evaluate(()=>{window.failNextSave=true;});await page.locator('#saveEntries').click();
   await page.waitForFunction(()=>document.querySelector('#userNotice').textContent.includes('Enregistrement impossible'));
   assert.equal(await page.locator('#entryHours0').inputValue(),'8,25');
   await page.screenshot({path:'/workspace/scratch/668e553454fa/maintenance-mobile.png',fullPage:true});
   await page.evaluate(()=>{window.testDb.pointage_maintenance[0].locked=false;document.dispatchEvent(new Event('visibilitychange'));});
   await page.waitForFunction(()=>!document.querySelector('#saveEntries').disabled);
   assert.equal(await page.locator('#entryHours0').inputValue(),'8,25');
   await page.locator('#spaceYear').fill('2027');await page.locator('#spaceYear').press('Tab');
   await page.locator('#confirmCancel').click();await page.waitForFunction(()=>document.querySelector('#spaceYear').value==='2026');assert.equal(await page.locator('#spaceYear').inputValue(),'2026');assert.equal(await page.locator('#entryHours0').inputValue(),'8,25');
   await page.locator('#spaceYear').fill('2027');await page.locator('#spaceYear').press('Tab');await page.locator('#confirmAccept').click();
   await page.waitForFunction(()=>document.querySelector('#monthSelect').value==='2027-01');assert.equal(await page.locator('[data-space-month]').count(),12);
   await page.locator('[data-space-month="2027-12"]').click();await page.waitForFunction(()=>document.querySelector('#monthSelect').value==='2027-12');
  }else{
   assert.equal(await page.locator('[data-admin-tab="months"]').count(),0);
   await page.locator('#toggleMaintenance').click();await page.locator('#confirmAccept').click();
   await page.waitForFunction(()=>document.querySelector('#maintenanceState').textContent==='Saisies bloquées');
   await page.screenshot({path:'/workspace/scratch/668e553454fa/maintenance-admin.png',fullPage:true});
   await page.locator('[data-admin-tab="codes"]').click();await page.locator('#catalogueSourceUnit').selectOption('ulm');await page.locator('[data-clabel="0"]').waitFor();
   await page.locator('[data-clabel="0"]').fill('HEURE DS MODIFIÉE');await page.locator('[data-cdocument="0"]').fill('Nouvelle référence DS');
   await page.locator('#catalogueAllUnits').check();await page.locator('#saveAdminCodes').click();await page.locator('#confirmAccept').click();
   await page.locator('#codeAdminMessage').getByText(/Modifications enregistrées/).waitFor();
   const call=await page.evaluate(()=>window.calls.find(c=>c.name==='pointage_save_catalogue'));
   assert.deepEqual(call.args.p_units.sort(),['ufpi','ulm']);assert.equal(call.args.p_changes.length,1);assert.equal(call.args.p_changes[0].document,'Nouvelle référence DS');
   await page.locator('#adminUnit').selectOption('ulm');await page.waitForFunction(()=>document.querySelectorAll('[data-space-month]').length===12);
   await page.locator('[data-admin-tab="codes"]').click();await page.screenshot({path:'/workspace/scratch/668e553454fa/admin-desktop.png',fullPage:true});
   await page.locator('#catalogueEffective').fill('2027-01');await page.locator('#catalogueEffective').press('Tab');await page.locator('[data-clabel="0"]').fill('DS 2027');await page.locator('#saveAdminCodes').click();await page.locator('#confirmAccept').click();
   await page.locator('#codeAdminMessage').getByText(/janvier 2027/).waitFor();
   await page.locator('#toggleMaintenance').click();await page.locator('#confirmAccept').click();
   await page.waitForFunction(()=>document.querySelector('#maintenanceState').textContent==='Saisies autorisées');
   assert.equal(await page.locator('[data-admin-tab="months"]').count(),0);
  }
  assert.deepEqual(errors,[],mode+' JS errors');console.log('PASS '+mode+' UI');await page.goto('about:blank').catch(()=>{});await context.close();
 }
 await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
