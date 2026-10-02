const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict');
const html=fs.readFileSync('app/index.html','utf8');
const helpers=html.slice(html.indexOf('  // Duration helpers:'),html.indexOf('  // End duration helpers.'));
const functions=[['  function annualReport(','  function renderAnnualSummary(){'],['  function individualCsvRows(','  async function exportIndividual('],['  function globalSummaryRows(','  $(\'exportGlobalSummary\')']].map(([a,b])=>html.slice(html.indexOf(a),html.indexOf(b,html.indexOf(a)))).join('\n');
const ctx={timeInputMode:'decimal',fmt:x=>String(x),units:[{id:'ulm',name:'ULM'}],selectedUnit:'ulm',allProfiles:[{id:'u',unit_id:'ulm',active:true}],annualCodes:[{id:1,code:'D4'},{id:2,code:'N7'}],annualEntries:[{user_id:'u',code_id:1,hours:1.5},{user_id:'u',code_id:2,hours:0.02,duration_seconds:60,saved_code:'N7'}]};
vm.createContext(ctx);vm.runInContext(helpers+functions,ctx);
assert.equal(ctx.parseDuration('1,50'),5400);assert.equal(ctx.parseDuration('1:30','clock'),5400);
assert.equal(ctx.parseDuration('7,30'),26280);assert.equal(ctx.parseDuration('7:30','clock'),27000);
assert.equal(ctx.parseDuration('0:01','clock'),60);assert.equal(ctx.parseDuration('0,016667'),60);
for(const bad of ['7:60','7:30:60','7:30:00','7:30:15','-1:30','7,30','7h30','Infinity'])assert.equal(ctx.parseDuration(bad,'clock'),null);
for(const bad of ['NaN','7:30','7abc','-1','1,1234567'])assert.equal(ctx.parseDuration(bad),null);
assert.equal(ctx.parseDuration('0'),0);assert.equal(ctx.entryDurationSeconds({hours:8.33}),29988);assert.equal(ctx.inputDuration(29988,'clock'),'8:20');
for(let secs=0;secs<100000;secs+=37){assert.equal(ctx.parseDuration(ctx.inputDuration(secs,'decimal'),'decimal'),secs);assert.equal(ctx.parseDuration(ctx.inputDuration(secs,'clock'),'clock'),Math.round(secs/60)*60);}
const report=ctx.annualReport();assert.equal(report.codeTotals.get('D4'),5400);assert.equal(report.codeTotals.get('N7'),60);
const many=Array.from({length:60},()=>({user_id:'u',code_id:2,hours:0.02,duration_seconds:60}));
const person={id:'u',full_name:'Test',unit_id:'ulm'};
const individual=ctx.individualCsvRows(person,'2026',ctx.annualCodes,many);let col=individual[0].indexOf('Total heures');assert.equal(individual[1][col],'1');assert.equal(individual[1][individual[0].indexOf('Total secondes')],3600);assert.equal(individual[1].at(-1),'1:00:00');assert.equal(individual[0].length,individual[1].length);
const global=ctx.globalSummaryRows('2026',[person],ctx.annualCodes,[...many,{user_id:'u',code_id:1,hours:1.5}]);col=global[0].indexOf('Total heures');assert.equal(global[1][col],'2,5');assert.equal(global.at(-1)[global[0].indexOf('Total secondes')],9000);for(const row of global)assert.equal(row.length,global[0].length);
console.log('PASS: decimal/clock equivalence, strict validation, legacy values, reversible conversions, mixed codes, 60 one-minute entries total exactly 1 hour, exact export columns.');

ctx.timeInputMode='clock';assert.equal(ctx.rowDuration({hours:'8:20',duration_seconds:29988}),29988);assert.equal(ctx.rowDuration({hours:'8:21',duration_seconds:29988}),30060);
