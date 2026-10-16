const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
function source(name){
 const start=html.search(new RegExp('  (?:async )?function '+name+'\\('));
 assert.ok(start>=0,name);
 const end=html.indexOf('\n  }',start);
 return html.slice(start,end+4);
}
const units=[{id:'u1',name:'Unité 1'},{id:'u2',name:'Unité 2'},{id:'u3',name:'Autre division'}];
const people=[
 {id:'a',full_name:'Alice',unit_id:'u1',active:true},
 {id:'b',full_name:'Bruno muté',unit_id:'u3',active:true},
 {id:'c',full_name:'Sans saisie',unit_id:'u2',active:true},
 {id:'admin',full_name:'Admin',unit_id:'u1',active:true,is_admin:true}
];
const codes=units.flatMap((u,i)=>['2026-09','2026-10','2026-12'].flatMap(month=>[
 {id:i*100+Number(month.slice(5))*2,unit_id:u.id,month_key:month,code:'D4',label:'DS'},
 {id:i*100+Number(month.slice(5))*2+1,unit_id:u.id,month_key:month,code:'ZERO',label:'Non utilisé'}
]));
const entries=[
 {user_id:'a',unit_id:'u1',month_key:'2026-09',code_id:18,hours:1.25},
 {user_id:'a',unit_id:'u1',month_key:'2026-10',code_id:20,hours:99,duration_seconds:27001},
 {user_id:'b',unit_id:'u1',month_key:'2026-10',code_id:999,saved_code:'ANCIEN',saved_label:'Historique',duration_seconds:1800},
 {user_id:'b',unit_id:'u2',month_key:'2026-10',code_id:120,duration_seconds:3600},
 {user_id:'b',unit_id:'u3',month_key:'2026-10',code_id:220,duration_seconds:7200},
 {user_id:'a',unit_id:'u1',month_key:'2026-12',code_id:24,duration_seconds:60},
 {user_id:'a',unit_id:'u1',month_key:'2025-10',code_id:20,hours:888},
 {user_id:'admin',unit_id:'u1',month_key:'2026-10',code_id:20,hours:100}
];
const db={profiles:people,month_codes:codes,entries};
class Query{
 constructor(table){this.table=table;this.filters=[];}
 select(){return this;}order(){return this;}
 in(k,values){this.filters.push(r=>values.includes(r[k]));return this;}
 gte(k,v){this.filters.push(r=>r[k]>=v);return this;}
 lt(k,v){this.filters.push(r=>r[k]<v);return this;}
 then(resolve,reject){return Promise.resolve({data:db[this.table].filter(r=>this.filters.every(f=>f(r))),error:null}).then(resolve,reject);}
}
const downloads=[],alerts=[];
const ctx=vm.createContext({units,allProfiles:people,annualCodes:codes,annualEntries:entries,
 selectedUnit:'u1',divisionSpace:false,profile:{active:true,is_division_manager:true},divisionOverview:{division:'DPN'},
 divisionUnitIds:()=>['u1','u2'],divisionManagedUnits:()=>units.slice(0,2),divisionCanManageUnit:id=>['u1','u2'].includes(id),
 sb:{from:t=>new Query(t)},fetchAll:async factory=>(await factory()).data,
 csvDownload:(filename,rows)=>downloads.push({filename,rows}),alert:message=>alerts.push(message)});
for(const name of ['entryDurationSeconds','decimalHours','decimalCsv','individualCsvRows','globalSummaryRows','annualReport','exportDivisionPeriod'])vm.runInContext(source(name),ctx);
const seconds=value=>Math.round(Number(String(value).replace(',','.'))*3600);
function total(rows){return seconds(rows.at(-1).at(-1));}
const inPeriod=(list,period)=>list.filter(e=>e.month_key.startsWith(period));
function checkColumns(rows){
 const header=rows[0],zero=header.indexOf('ZERO');assert.ok(zero>=0,'unused catalogue column retained');
 for(const row of rows.slice(1))assert.equal(seconds(row[zero]),0);
 assert.ok(header.includes('ANCIEN'),'historical code retained');
 for(let col=4;col<header.length;col++)assert.equal(rows.slice(1,-1).reduce((s,r)=>s+seconds(r[col]),0),seconds(rows.at(-1)[col]),'column reconciles');
 for(const row of rows.slice(1))assert.equal(row.slice(4,-1).reduce((s,v)=>s+seconds(v),0),seconds(row.at(-1)),'row reconciles');
}
(async()=>{
 for(const period of ['2026','2026-10']){
  const c=inPeriod(codes,period),e=inPeriod(entries,period);
  const expected=e.filter(r=>r.user_id!=='admin').reduce((sum,r)=>sum+ctx.entryDurationSeconds(r),0);
  const global=ctx.globalSummaryRows(period,people,c,e);
  checkColumns(global);assert.equal(total(global),expected);
  const scoped=ctx.globalSummaryRows(period,people,c.filter(r=>r.unit_id!=='u3'),e,new Set(['u1','u2']));
  const expectedDivision=e.filter(r=>r.user_id!=='admin'&&r.unit_id!=='u3').reduce((sum,r)=>sum+ctx.entryDurationSeconds(r),0);
  assert.equal(total(scoped),expectedDivision);checkColumns(scoped);
  assert.ok(scoped.some(r=>r[1]==='Sans saisie'&&seconds(r.at(-1))===0));
  assert.equal(scoped.filter(r=>r[1]==='Bruno muté').length,2,'mutated user keeps both historical units');
  for(const person of people.filter(p=>!p.is_admin)){
   const rows=ctx.individualCsvRows(person,period,c,e.filter(r=>r.user_id===person.id));
   assert.equal(rows.slice(1).reduce((s,r)=>s+seconds(r.at(-1)),0),global.filter(r=>r[1]===person.full_name).reduce((s,r)=>s+seconds(r.at(-1)),0),'individual/global agreement');
  }
  for(const unit of units){
   ctx.selectedUnit=unit.id;ctx.divisionSpace=false;
   const report=ctx.annualReport(c.filter(r=>r.unit_id===unit.id),e.filter(r=>r.unit_id===unit.id&&r.user_id!=='admin'));
   assert.equal([...report.codeTotals.values()].reduce((a,b)=>a+b,0),global.filter(r=>r[3]===unit.name).reduce((sum,r)=>sum+seconds(r.at(-1)),0),'unit/global agreement');
  }
  ctx.divisionSpace=true;
  const button={disabled:false,textContent:'Exporter'};
  await ctx.exportDivisionPeriod(period,false,button);
  const recap=downloads.at(-1).rows;
  assert.equal(total(recap),expectedDivision);checkColumns(recap);
  assert.equal(button.disabled,false);assert.equal(button.textContent,'Exporter');
  await ctx.exportDivisionPeriod(period,true,button);
  const detail=downloads.at(-1).rows;
  assert.equal(detail.slice(1).reduce((sum,r)=>sum+seconds(r[6]),0),total(recap),'division detail/recap agreement');
  assert.ok(detail.slice(1).every(r=>!['Admin','Autre division'].includes(r[1])&&r[3]!=='Autre division'));
  console.log('PASS '+period+': individual, unit, division, global, historical transfers, zero codes, row/column totals, exact seconds');
 }
 // December must not include January of the following year, including empty periods.
 await ctx.exportDivisionPeriod('2026-12',false,{textContent:'Exporter'});assert.equal(total(downloads.at(-1).rows),60);
 await ctx.exportDivisionPeriod('2027-01',false,{textContent:'Exporter'});assert.equal(total(downloads.at(-1).rows),0);
 assert.deepEqual(alerts,[]);
 const previous=require('node:child_process').execFileSync('git',['show','7bf976f:index.html'],{cwd:path.join(__dirname,'..'),encoding:'utf8'});
 assert.equal(html.match(/<script>[\s\S]*?<\/script>/g).join(''),previous.match(/<script>[\s\S]*?<\/script>/g).join(''),'application JavaScript unchanged by display fix');
 console.log('PASS December/January boundary, empty period, export JavaScript unchanged');
})().catch(error=>{console.error(error);process.exitCode=1;});
