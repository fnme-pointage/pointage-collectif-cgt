const fs=require('node:fs'),assert=require('node:assert/strict'),path=require('node:path');
const {chromium}=require('playwright');
let stub=fs.readFileSync(path.join(__dirname,'catalogue_ui.cjs'),'utf8').match(/const stub = `([\s\S]*?)`;/)[1].replace('MODE','false');
stub=stub.replace('getSession:async()=>({data:{session:{user:{id:p.id}}}})','getSession:async()=>({data:{session:null}})');
stub=stub.replace('onAuthStateChange:','signUp:async(args)=>{window.signupCalls=(window.signupCalls||0)+1;window.signupUnit=args.options.data.unit_id;return {data:{session:null},error:null};},onAuthStateChange:');
(async()=>{
 const options={headless:true};if(process.env.CHROMIUM_EXECUTABLE)options.executablePath=process.env.CHROMIUM_EXECUTABLE;if(process.env.CHROMIUM_ARGS)options.args=JSON.parse(process.env.CHROMIUM_ARGS);
 const browser=await chromium.launch(options);
 for(const width of [390,1440]){
  const context=await browser.newContext({viewport:{width,height:1000}}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/supabase-js@2',r=>r.fulfill({contentType:'application/javascript',body:stub}));
  await page.route('https://pointage.test/**',r=>{const f=path.resolve('app',new URL(r.request().url()).pathname.slice(1)||'index.html');return fs.existsSync(f)?r.fulfill({path:f}):r.fulfill({status:404,body:''});});
  await page.goto('https://pointage.test/');await page.locator('#authView').waitFor({state:'visible'});await page.locator('#signupTab').click();
  assert.equal(await page.locator('#signupPasswordConfirm').getAttribute('type'),'password');
  await page.locator('#signupName').fill('Utilisateur test');await page.locator('#signupEmail').fill('test@example.invalid');await page.locator('#signupUnit').selectOption('ulm');await page.locator('#signupPassword').fill('Test password 123!');
  await page.locator('#signupBtn').click();assert.match(await page.locator('#authMsg').textContent(),/Confirme ton mot de passe/);assert.equal(await page.evaluate(()=>window.signupCalls||0),0);
  await page.locator('#signupPasswordConfirm').fill('Different password 123!');await page.locator('#signupBtn').click();assert.match(await page.locator('#authMsg').textContent(),/ne correspondent pas/);assert.equal(await page.evaluate(()=>window.signupCalls||0),0);
  await page.locator('#signupPasswordConfirm').fill('Test password 123!');await page.locator('#signupBtn').click();await page.locator('#signupVerificationForm').waitFor({state:'visible'});
  assert.equal(await page.evaluate(()=>window.signupCalls),1);assert.equal(await page.evaluate(()=>window.signupUnit),'ulm');assert.equal(await page.locator('#signupPassword').inputValue(),'');assert.equal(await page.locator('#signupPasswordConfirm').inputValue(),'');assert.deepEqual(errors,[]);
  await context.close();
 }
 await browser.close();console.log('PASS: mobile/desktop confirmation required, mismatch blocks signup, matching passwords register once, both fields cleared.');
})().catch(e=>{console.error(e);process.exit(1)});
