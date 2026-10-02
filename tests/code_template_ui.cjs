const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{chromium}=require('playwright');
let stub=fs.readFileSync(path.join(__dirname,'catalogue_ui.cjs'),'utf8').match(/const stub = `([\s\S]*?)`;/)[1].replace('MODE','true');
stub=stub.replace('window.calls.push({name,args});',`window.calls.push({name,args});if(name==='pointage_get_code_template')return {data:structuredClone(window.templateSnapshot),error:null};if(name==='pointage_save_code_template'){if(args.p_revision!==window.templateSnapshot.revision)return {data:null,error:{message:'La liste type a été modifiée ailleurs. Recharge-la avant de recommencer.'}};window.templateSnapshot={revision:args.p_revision+1,codes:args.p_codes.map((c,i)=>({...c,catalogue_id:c.catalogue_id||'newtype-'+i}))};return {data:structuredClone(window.templateSnapshot),error:null};}`);
stub+=`
window.templateSnapshot={revision:1,codes:structuredClone(db.pointage_code_versions.filter(c=>c.unit_id==='ulm'))};
Query.prototype.insert=function(value){const unit={id:'newunit-'+db.units.length,name:value.name,active:true};db.units.push(unit);for(const c of window.templateSnapshot.codes)db.pointage_code_versions.push({...c,id:db.pointage_code_versions.length+1,unit_id:unit.id,effective_month:'1900-01'});this.filters.push(r=>r.id===unit.id);return this;};
`;
(async()=>{
 const options={headless:true};if(process.env.CHROMIUM_EXECUTABLE)options.executablePath=process.env.CHROMIUM_EXECUTABLE;if(process.env.CHROMIUM_ARGS)options.args=JSON.parse(process.env.CHROMIUM_ARGS);
 const browser=await chromium.launch(options);
 for(const width of [390,1440]){
  const context=await browser.newContext({viewport:{width,height:1000}}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(10000);
  await page.clock.install({time:new Date('2026-10-02T08:00:00Z')});
  await page.route('**/supabase-js@2',r=>r.fulfill({contentType:'application/javascript',body:stub}));
  await page.route('https://pointage.test/**',r=>{const f=path.resolve('app',new URL(r.request().url()).pathname.slice(1)||'index.html');return fs.existsSync(f)?r.fulfill({path:f}):r.fulfill({status:404,body:''});});
  await page.goto('https://pointage.test/');await page.locator('[data-admin-tab="codes"]').click();await page.locator('[data-tlabel="0"]').waitFor();
  assert.equal(await page.locator('#codeTemplateCard').isVisible(),true);assert.match(await page.locator('#codeTemplateCard .notice').textContent(),/création d’une nouvelle unité/);assert.match(await page.locator('#codeTemplateCard .notice').textContent(),/ne changent pas les catalogues/);
  await page.locator('[data-tlabel="0"]').fill('DS modèle modifié');
  await page.locator('#adminUnit').selectOption('ulm');await page.locator('#confirmCancel').click();await page.waitForFunction(()=>document.querySelector('#adminUnit').value==='adminunit');assert.equal(await page.locator('#adminUnit').inputValue(),'adminunit');assert.equal(await page.locator('[data-tlabel="0"]').inputValue(),'DS modèle modifié');
  await page.locator('[data-tcode="1"]').fill('D4');await page.locator('#saveCodeTemplate').click();assert.match(await page.locator('#templateMessage').textContent(),/Deux codes identiques/);await page.locator('[data-tcode="1"]').fill('52');
  await page.locator('#addTemplateCode').click();await page.locator('[data-tcode="2"]').fill('N1');await page.locator('[data-tlabel="2"]').fill('Nouveau code type');await page.locator('[data-tdocument="2"]').fill('Document nouveau');await page.locator('[data-tactive="1"]').uncheck();
  await page.locator('#saveCodeTemplate').click();await page.getByText(/Liste type enregistrée/).waitFor();
  assert.equal(await page.evaluate(()=>window.templateSnapshot.revision),2);assert.equal(await page.evaluate(()=>window.testDb.pointage_code_versions.find(c=>c.unit_id==='ulm'&&c.code==='D4').label),'HEURE DS');
  await page.locator('[data-admin-tab="units"]').click();await page.locator('#newUnitName').fill('Nouvelle unité test');await page.locator('#createUnit').click();await page.waitForFunction(()=>document.querySelector('#adminUnit').selectedOptions[0].textContent==='Nouvelle unité test');
  await page.locator('[data-admin-tab="codes"]').click();await page.locator('[data-clabel="0"]').waitFor();assert.equal(await page.locator('#codeTemplateCard').isVisible(),false);assert.equal(await page.locator('#unitCatalogueHelp').isVisible(),true);assert.equal(await page.locator('#catalogueSourceField').isVisible(),false);assert.equal(await page.locator('#catalogueTargetFields').isVisible(),false);assert.equal(await page.locator('#catalogueSourceUnit option').count(),1);assert.match(await page.locator('#unitCatalogueHelp').textContent(),/nouveaux inscrits/);
  assert.equal(await page.locator('[data-clabel="0"]').inputValue(),'DS modèle modifié');assert.equal(await page.locator('[data-cactive="1"]').isChecked(),false);assert.equal(await page.locator('[data-ccode="2"]').inputValue(),'N1');
  await page.locator('[data-clabel="0"]').fill('DS personnalisé unité');await page.locator('#saveAdminCodes').click();await page.locator('#confirmAccept').click();await page.getByText(/Modifications enregistrées pour/).waitFor();
  assert.equal(await page.evaluate(()=>window.templateSnapshot.codes[0].label),'DS modèle modifié');
  const unitSave=await page.evaluate(()=>window.calls.filter(c=>c.name==='pointage_save_catalogue').at(-1));assert.equal(unitSave.args.p_units.length,1);assert.match(unitSave.args.p_units[0],/^newunit-/);
  await page.locator('#adminUnit').selectOption('adminunit');await page.locator('[data-tlabel="0"]').waitFor();assert.equal(await page.locator('#catalogueSourceField').isVisible(),true);assert.equal(await page.locator('#catalogueTargetFields').isVisible(),true);assert.equal(await page.locator('#adminCatalogueHelp').isVisible(),true);assert.equal(await page.locator('[data-tlabel="0"]').inputValue(),'DS modèle modifié');
  await page.evaluate(()=>{window.templateSnapshot.revision++;});await page.locator('[data-tlabel="0"]').fill('Conflit');await page.locator('#saveCodeTemplate').click();await page.getByText(/modifiée ailleurs/).waitFor();assert.equal(await page.locator('[data-tlabel="0"]').inputValue(),'Conflit');
  await page.locator('#reloadCodeTemplate').click();await page.locator('#confirmAccept').click();await page.waitForFunction(()=>document.querySelector('[data-tlabel="0"]').value==='DS modèle modifié');
  await page.screenshot({path:'/tmp/code-template-'+width+'.png',fullPage:true});assert.deepEqual(errors,[]);
  await context.close();
 }
 await browser.close();console.log('PASS: ADMIN-only template, clear help, unsaved guard, duplicate validation, editable fields/add/deactivate/save, new unit copies template, local independence, concurrent edit protection, reload, mobile/desktop.');
})().catch(e=>{console.error(e);process.exit(1)});
