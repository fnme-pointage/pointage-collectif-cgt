/* Disponibilites annuelles par code et unite - module additif.
   Aucun changement des saisies ni des exports mensuels. */
(function(){
  'use strict';
  const bridge = window.PointageAvailabilityBridge;
  if (!bridge) return;
  const sb = bridge.sb;
  const $ = id => document.getElementById(id);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const key = (unitId, catalogueId) => unitId + '|' + catalogueId;
  const oneYear = y => /^[1-9][0-9]{3}$/.test(String(y));
  const hours = seconds => Number((Number(seconds || 0) / 3600).toFixed(6)).toLocaleString('fr-FR',{maximumFractionDigits:6});
  const hoursCsv = seconds => bridge.decimalCsv(Number(seconds || 0));
  const pct = (p,a) => Number(a)>0 ? (100*Number(p)/Number(a)).toLocaleString('fr-FR',{maximumFractionDigits:2})+' %' : '—';
  let model = null;
  let draftDirty = false;
  let requestCounter = 0;
  let currentIdentity = '';
  let lastMainUnit = '';

  function scope() {
    const c = bridge.context();
    if (!c.profile?.active) return {units:[], permitted:false, ctx:c};
    const units = c.units.filter(u=>u.active && u.name !== 'ADMIN' && (
      c.profile.is_admin
      || (c.profile.is_division_manager && c.divisionSpace && u.division_id===c.profile.managed_division_id)
      || (c.profile.is_unit_manager && c.managerSpace && u.id===c.profile.unit_id)
    ));
    return {units, permitted:units.length>0, ctx:c};
  }

  function parseHourInput(raw) {
    const value=String(raw||'').trim().replace(/\s/g,'');
    if(!value)return null;
    let seconds;
    if (/^\d{1,6}:\d{2}$/.test(value)) {
      const [h,m]=value.split(':').map(Number);
      if(m>59)throw new Error('Les minutes doivent être comprises entre 00 et 59.');
      seconds=h*3600+m*60;
    } else if (/^\d+(?:[.,]\d{1,6})?$/.test(value)) {
      seconds=Math.round(Number(value.replace(',','.'))*3600);
    } else {
      throw new Error('Saisis un nombre d’heures positif (ex. 120,5) ou HH:MM.');
    }
    if(!Number.isSafeInteger(seconds) || seconds<0 || seconds>3600000000)throw new Error('Volume hors limites.');
    return seconds;
  }

  async function loadYear(year, ids){
    if(!oneYear(year)||!ids.length)return {year,ids,rows:[], codeNames:[],unknownCodes:new Set(),avail:[]};
    const start=year+'-01', end=(Number(year)+1)+'-01';
    const [codes,entries,avail,versions]=await Promise.all([
      bridge.fetchAll(()=>sb.from('month_codes').select('id,unit_id,month_key,code,label,catalogue_id').in('unit_id',ids).gte('month_key',start).lt('month_key',end).order('id')),
      bridge.fetchAll(()=>sb.from('entries').select('id,user_id,unit_id,code_id,month_key,duration_seconds,hours,saved_code,saved_label').in('unit_id',ids).gte('month_key',start).lt('month_key',end).order('id')),
      bridge.fetchAll(()=>sb.from('pointage_annual_code_availability').select('unit_id,year,catalogue_id,available_seconds,revision,updated_at').in('unit_id',ids).eq('year',Number(year))),
      bridge.fetchAll(()=>sb.from('pointage_code_versions').select('unit_id,catalogue_id,code,label,active,effective_month').in('unit_id',ids).lte('effective_month',year+'-12').order('effective_month',{ascending:false}))
    ]);
    const adminIds=new Set();
    const idsForUsers=[...new Set(entries.map(e=>e.user_id))];
    for(let i=0;i<idsForUsers.length;i+=100){
      const batch=idsForUsers.slice(i,i+100);
      const {data,error}=await sb.from('profiles').select('id,is_admin').in('id',batch);
      if(error)throw error;
      for(const p of data||[])if(p.is_admin)adminIds.add(p.id);
    }
    const versionsMap=new Map();
    for(const v of versions){
      const k=key(v.unit_id,v.catalogue_id);
      if(!versionsMap.has(k))versionsMap.set(k,v);
    }
    const codeById=new Map(), rowMap=new Map(), codeMap=new Map(), historicalNames=new Map(), unknownCodes=new Set();
    const availMap=new Map(avail.map(a=>[key(a.unit_id,a.catalogue_id),a]));
    const unitsWithYearCodes=new Set(codes.map(c=>c.unit_id));
    for(const v of versionsMap.values()){
      const k=key(v.unit_id,v.catalogue_id);
      if(!rowMap.has(k) && v.active){
        const a=availMap.get(k);
        rowMap.set(k,{unitId:v.unit_id,catalogueId:v.catalogue_id,code:v.code||'',label:v.label||'',availableSeconds:a?.available_seconds??null,revision:a?.revision??null,pointedSeconds:0, ambiguous:false, activeInYear:!unitsWithYearCodes.has(v.unit_id)});
      }
    }
    for(const c of codes){
      const k=key(c.unit_id,c.catalogue_id);
      codeById.set(Number(c.id),c);
      if(!historicalNames.has(k))historicalNames.set(k,new Set());
      historicalNames.get(k).add(String(c.code||''));
      const existing=rowMap.get(k),a=availMap.get(k);
      if(!existing)rowMap.set(k,{unitId:c.unit_id,catalogueId:c.catalogue_id,code:c.code||'',label:c.label||'',availableSeconds:a?.available_seconds??null,revision:a?.revision??null,pointedSeconds:0,ambiguous:false,activeInYear:true});
      else {existing.code=c.code||existing.code;existing.label=c.label||existing.label;existing.activeInYear=true;}
      const groupKey=c.unit_id+'|'+String(c.code||'').toUpperCase();
      if(!codeMap.has(groupKey))codeMap.set(groupKey,new Set());
      codeMap.get(groupKey).add(k);
    }
    for(const [historicalKey, names] of historicalNames){
      if(names.size>1){
        for(const code of names)unknownCodes.add(code);
        if(rowMap.has(historicalKey))rowMap.get(historicalKey).ambiguous=true;
      }
    }
    for(const a of avail){
      const k=key(a.unit_id,a.catalogue_id);
      if(!rowMap.has(k)){
        const version=versionsMap.get(k);
        rowMap.set(k,{unitId:a.unit_id,catalogueId:a.catalogue_id,code:version?.code||'Code historique',label:version?.label||'',availableSeconds:a.available_seconds,revision:a.revision,pointedSeconds:0,ambiguous:!version,activeInYear:false});
      }
    }
    for(const e of entries){
      if(adminIds.has(e.user_id))continue;
      const c=codeById.get(Number(e.code_id));
      const code=e.saved_code||c?.code||'';
      if(c && e.saved_code && String(e.saved_code).toUpperCase() !== String(c.code).toUpperCase()){
        unknownCodes.add(String(e.saved_code));
        unknownCodes.add(String(c.code));
      }
      let k=c?.catalogue_id?key(e.unit_id,c.catalogue_id):null;
      if(!k){
        const candidates=codeMap.get(e.unit_id+'|'+String(code).toUpperCase());
        if(candidates?.size===1)k=[...candidates][0];
      }
      if(!k||!rowMap.has(k)){
        if(code)unknownCodes.add(code);
        continue;
      }
      const row=rowMap.get(k);
      const seconds=e.duration_seconds==null?Math.round(Number(e.hours||0)*3600):Number(e.duration_seconds);
      if(!Number.isSafeInteger(seconds)||seconds<0){unknownCodes.add(code||row.code);continue;}
      row.pointedSeconds+=seconds;
    }
    const rows=[...rowMap.values()].sort((a,b)=>a.unitId.localeCompare(b.unitId)||a.code.localeCompare(b.code,'fr',{numeric:true}));
    for(const row of rows){
      const g=codeMap.get(row.unitId+'|'+String(row.code||'').toUpperCase());
      if(g?.size>1)row.ambiguous=true;
    }
    return {year,ids,rows,codes,entries,avail,unknownCodes};
  }

  function summarizeCode(data, code, chosenUnitIds) {
    if(data.unknownCodes.has(code))return {status:'A vérifier'};
    const rows=data.rows.filter(r=>chosenUnitIds.includes(r.unitId)&&r.code===code&&r.activeInYear);
    if(!rows.length){
      // Dotation possible sans mois ouvert : utiliser la dotation explicite.
      const aRows=data.rows.filter(r=>chosenUnitIds.includes(r.unitId)&&r.code===code&&r.availableSeconds!==null);
      if(!aRows.length)return {status:'Non renseigné'};
      if(aRows.some(r=>r.ambiguous))return {status:'A vérifier'};
      return {status:'ok',available:aRows.reduce((s,r)=>s+Number(r.availableSeconds),0)};
    }
    if(rows.some(r=>r.ambiguous))return {status:'A vérifier'};
    if(rows.some(r=>r.availableSeconds===null))return {status:'Non renseigné'};
    return {status:'ok',available:rows.reduce((s,r)=>s+Number(r.availableSeconds),0)};
  }

  function appendSummaryRows(rows, year, scopeIds, data){
    if(!oneYear(year) || !rows.length)return rows;
    const headings=rows[0];
    const totalIndex=headings.indexOf('Total heures');
    const offset=rows[0].includes('Unité')?4:3;
    if(totalIndex < 0 || totalIndex<=offset)return rows;
    const names=headings.slice(offset,totalIndex);
    const pointedRow=rows.find((r,i)=>i>0 && r[1]==='Total par code')||rows[rows.length-1];
    const summary=names.map((code,index)=>{
      const result=summarizeCode(data,code,scopeIds);
      const raw=Number(String(pointedRow[offset+index]||'0').replace(',','.'));
      const pointed=Number.isFinite(raw)?Math.round(raw*3600):0;
      if(result.status!=='ok')return {available:result.status,left:result.status,percent:'—'};
      return {available:hoursCsv(result.available),left:hoursCsv(result.available-pointed),percent:pct(pointed,result.available)};
    });
    const validTotals=summary.every(s=>typeof s.available==='number'||(/^[\d,.-]+$/.test(String(s.available))));
    const totalAvailability=validTotals?summary.reduce((s,r)=>s+Number(String(r.available).replace(',','.')),0):null;
    const totalPointed=Number(String(pointedRow[totalIndex]||'0').replace(',','.'));
    const totals=totalAvailability===null?['Non renseigné','Non renseigné','—']:[
      bridge.decimalCsv(Math.round(totalAvailability*3600)),
      bridge.decimalCsv(Math.round((totalAvailability-totalPointed)*3600)),
      totalAvailability>0?(100*totalPointed/totalAvailability).toLocaleString('fr-FR',{maximumFractionDigits:2})+' %':'—'
    ];
    const prefix=Array(offset).fill('');prefix[0]=year;
    function insertRow(label, values, total) {
      const out=prefix.slice();out[1]=label;
      for(const x of values)out.push(x);
      out.push(total);
      rows.push(out);
    }
    insertRow('Heures disponibles',summary.map(s=>s.available),totals[0]);
    insertRow('Heures restantes',summary.map(s=>s.left),totals[1]);
    insertRow('Taux de consommation',summary.map(s=>s.percent),totals[2]);
    return rows;
  }

  async function augment({rows,year,unitIds,codes,entries}) {
    // Signature conservee pour pouvoir comparer avec les sources de l'export existant.
    if(!oneYear(year)||!unitIds?.length)return rows;
    const data=await loadYear(year,unitIds);
    return appendSummaryRows(rows,year,unitIds,data);
  }

  function useUnitScope(){
    const ctx=scope();
    const choice=$('availabilityUnit');
    const chosen=choice?.value;
    return { ...ctx, year:String(ctx.ctx.annualYear||''), chosen:chosen==='ALL'?ctx.units.map(u=>u.id):ctx.units.some(u=>u.id===chosen)?[chosen]:ctx.units.slice(0,1).map(u=>u.id)};
  }

  function renderRows() {
    const table=$('availabilityTable'),note=$('availabilityNote'),btn=$('availabilitySave');
    if(!model){table.innerHTML='';note.textContent='';btn.disabled=true;return;}
    const {year,chosen,units}=useUnitScope();
    const editable=chosen.length===1;
    btn.disabled=!editable;
    let rows=model.rows.filter(r=>chosen.includes(r.unitId));
    rows=rows.filter(r=>r.activeInYear||r.availableSeconds!==null);
    if(!rows.length){table.innerHTML='<p class="muted small">Aucun code disponible pour cette année. Vérifie le catalogue de cette unité.</p>';btn.disabled=true;return;}
    const names=new Map(units.map(u=>[u.id,u.name]));
    let html='<div class="tablewrap"><table class="availability-table"><thead><tr><th>Unité / code</th><th>Heures disponibles</th><th>Pointées</th><th>Restantes</th><th>Consommation</th></tr></thead><tbody>';
    for(const r of rows){
      const remaining=r.availableSeconds===null?'—':hours(r.availableSeconds-r.pointedSeconds);
      const status=r.ambiguous?'À vérifier':r.availableSeconds===null?'Non renseigné':r.availableSeconds<r.pointedSeconds?'Dépassement':'';
      html+='<tr><td><strong>'+esc(r.code)+'</strong><br><span class="muted small">'+esc(r.label)+'</span><br><span class="muted small">'+esc(names.get(r.unitId)||r.unitId)+'</span></td>';
      html+='<td>'+(editable?'<input data-avail-catalog="'+esc(r.catalogueId)+'" data-avail-unit="'+esc(r.unitId)+'" inputmode="decimal" aria-label="Heures disponibles '+esc(r.code)+'" placeholder="Non renseigné" value="'+esc(r.availableSeconds===null?'':String(Number((Number(r.availableSeconds)/3600).toFixed(6))).replace('.',','))+'" '+(r.ambiguous?'disabled title="Code historique à vérifier"':'')+'>':r.availableSeconds===null?'Non renseigné':hours(r.availableSeconds))+'</td>';
      html+='<td class="num">'+esc(hours(r.pointedSeconds))+'</td><td class="num">'+esc(remaining)+'</td><td class="num">'+esc(r.availableSeconds===null?'—':pct(r.pointedSeconds,r.availableSeconds))+(status?'<br><small class="'+(status==='Dépassement'?'availability-over':'muted')+'">'+esc(status)+'</small>':'')+'</td></tr>';
    }
    html+='</tbody></table></div>';
    table.innerHTML=html;
    table.querySelectorAll('input[data-avail-catalog]').forEach(el=>el.addEventListener('input',()=>{draftDirty=true;$('availabilityNote').textContent='Modifications non enregistrées.';}));
    note.textContent=editable?'Case vide : non renseigné. La valeur 0 signifie zéro heure disponible.':'Vue consolidée en lecture seule : choisir une unité pour modifier.';
  }

  async function refresh(){
    const {permitted,chosen,year}=useUnitScope(), note=$('availabilityNote'),table=$('availabilityTable');
    if(!permitted||!oneYear(year)||!chosen.length){model=null;table.innerHTML='';note.textContent='Choisis une année et une unité.';return;}
    const seq=++requestCounter;
    note.textContent='Chargement des disponibilités…';
    $('availabilitySave').disabled=true;
    try{
      const data=await loadYear(year,chosen);
      if(seq!==requestCounter)return;
      model=data;draftDirty=false;renderRows();
      if(data.unknownCodes.size)$('availabilityNote').textContent+=' Certains pointages historiques nécessitent une vérification de code.';
    }catch(error){if(seq!==requestCounter)return;model=null;table.innerHTML='';note.textContent='Chargement impossible : '+error.message;}
  }

  function sync() {
    const {permitted,ctx,units}=scope(), section=$('availabilitySection');
    if(!section)return;
    section.classList.toggle('hidden',!permitted);
    if(!permitted)return;
    const {year}=useUnitScope();
    const identity=(ctx.profile?.id||'')+'|'+ctx.selectedUnit+'|'+ctx.annualYear+'|'+ctx.divisionSpace+'|'+ctx.managerSpace;
    const select=$('availabilityUnit'),prev=select.value;
    const withAll=units.length>1;
    const opts=(withAll?'<option value="ALL">Synthèse de toutes les unités autorisées</option>':'')+units.map(u=>'<option value="'+esc(u.id)+'">'+esc(u.name)+'</option>').join('');
    if(select.innerHTML!==opts){
      select.innerHTML=opts;
      if(units.some(u=>u.id===prev))select.value=prev;
      else if(ctx.profile?.is_admin && ctx.selectedUnit!=='ADMIN' && units.some(u=>u.id===ctx.selectedUnit))select.value=ctx.selectedUnit;
      else select.value=withAll?'ALL':units[0]?.id||'';
    }
    if(ctx.selectedUnit!==lastMainUnit){
      lastMainUnit=ctx.selectedUnit;
      if(units.some(u=>u.id===ctx.selectedUnit))select.value=ctx.selectedUnit;
      else if(ctx.profile?.is_admin && withAll)select.value='ALL';
    }
    $('availabilityYear').textContent=year||'—';
    if(identity!==currentIdentity){
      currentIdentity=identity;
      if(section.open)refresh();
    }
  }

  async function save() {
    const {chosen,year,permitted}=useUnitScope();
    if(!permitted||chosen.length!==1||!model)return;
    const unit=chosen[0],inputs=[...$('availabilityTable').querySelectorAll('input[data-avail-catalog]')],changes=[];
    try{
      for(const input of inputs){
        const r=model.rows.find(x=>x.unitId===unit&&x.catalogueId===input.dataset.availCatalog);
        if(!r)continue;
        const next=parseHourInput(input.value);
        if(next===r.availableSeconds)continue;
        if(r.ambiguous)throw new Error('Le code '+r.code+' doit être vérifié avant modification.');
        changes.push({catalogue_id:r.catalogueId,revision:r.revision,available_seconds:next});
      }
    }catch(error){$('availabilityNote').textContent=error.message;return;}
    if(!changes.length){draftDirty=false;$('availabilityNote').textContent='Aucun changement à enregistrer.';return;}
    const button=$('availabilitySave');button.disabled=true;
    $('availabilityNote').textContent='Enregistrement…';
    try{
      const {error}=await sb.rpc('pointage_save_annual_code_availability',{p_unit_id:unit,p_year:Number(year),p_changes:changes});
      if(error)throw error;
      await refresh();
      $('availabilityNote').textContent=changes.length+' disponibilité(s) enregistrée(s).';
    }catch(error){
      button.disabled=false;
      $('availabilityNote').textContent='Enregistrement impossible : '+error.message+'. Si un autre responsable a modifié la valeur, actualise avant de recommencer.';
    }
  }

  function makeSpecialRows(data,units,year){
    const names=new Map(units.map(u=>[u.id,u.name]));
    const divisionNames=new Map((bridge.context().divisions||[]).map(d=>[d.id,d.name]));
    const headings=['Année','Division','Unité','Code','Libellé','Heures disponibles','Heures pointées','Heures restantes','Taux de consommation','État'];
    const body=[headings],groups=new Map();
    const output=(name,div,unit,code,label,available,pointed,ambig)=>{
      const state=ambig?'À vérifier':available===null?'Non renseigné':available<pointed?'Dépassement':'Disponible';
      const value=ambig?'À vérifier':available===null?'Non renseigné':hoursCsv(available);
      const remaining=ambig?'À vérifier':available===null?'Non renseigné':hoursCsv(available-pointed);
      return [year,div,unit,code,label,value,hoursCsv(pointed),remaining,ambig||available===null?'—':pct(pointed,available),state];
    };
    for(const row of data.rows){
      if(!data.ids.includes(row.unitId)||(!row.activeInYear&&row.availableSeconds===null))continue;
      const u=units.find(u=>u.id===row.unitId),div=divisionNames.get(u?.division_id)||'Sans division';
      body.push(output('unité',div,names.get(row.unitId)||'',row.code,row.label,row.availableSeconds,row.pointedSeconds,row.ambiguous||data.unknownCodes.has(row.code)));
      const group=div+'|'+row.code;
      if(!groups.has(group))groups.set(group,{division:div,code:row.code,label:row.label,rows:[]});
      groups.get(group).rows.push(row);
    }
    if(units.length>1){
      const national=new Map();
      for(const g of groups.values()){
        const valid=g.rows.every(r=>r.availableSeconds!==null&&!r.ambiguous&&!data.unknownCodes.has(r.code));
        const pointed=g.rows.reduce((s,r)=>s+r.pointedSeconds,0);
        const available=valid?g.rows.reduce((s,r)=>s+Number(r.availableSeconds),0):null;
        body.push(output('division',g.division,'TOTAL DIVISION',g.code,g.label,available,pointed,!valid && g.rows.some(r=>r.ambiguous||data.unknownCodes.has(r.code))));
        if(!national.has(g.code))national.set(g.code,{label:g.label,rows:[]});
        national.get(g.code).rows.push(...g.rows);
      }
      if(new Set([...groups.values()].map(g=>g.division)).size>1){
        for(const [code,g] of national){
          const valid=g.rows.every(r=>r.availableSeconds!==null&&!r.ambiguous&&!data.unknownCodes.has(r.code));
          const pointed=g.rows.reduce((s,r)=>s+r.pointedSeconds,0);
          const available=valid?g.rows.reduce((s,r)=>s+Number(r.availableSeconds),0):null;
          body.push(output('national','TOTAL','TOTAL UNITÉS',code,g.label,available,pointed,!valid && g.rows.some(r=>r.ambiguous||data.unknownCodes.has(r.code))));
        }
      }
    }
    return body;
  }

  async function exportSpecial(){
    const {units,chosen,year}=useUnitScope();
    if(!chosen.length||!oneYear(year))return;
    const button=$('availabilityExport');button.disabled=true;
    const note=$('availabilityNote');note.textContent='Préparation de l’export annuel…';
    try{
      const data=await loadYear(year,chosen);
      const chosenUnits=units.filter(u=>chosen.includes(u.id));
      const result=makeSpecialRows(data,chosenUnits,year);
      const slug=chosen.length===1?(chosenUnits[0]?.name||'unite').toLowerCase().replace(/[^a-z0-9_-]/g,'-'):'perimetre';
      bridge.csvDownload('pointage-disponibilites-'+slug+'-'+year+'.csv',result);
      note.textContent='Export terminé : '+(result.length-1)+' ligne(s) de bilan.';
    }catch(error){note.textContent='Export impossible : '+error.message;}
    finally{button.disabled=false;}
  }

  function init(){
    const section=$('availabilitySection');
    if(!section)return;
    let previousUnitChoice='';
    $('availabilityUnit').addEventListener('focus',()=>{previousUnitChoice=$('availabilityUnit').value;});
    $('availabilityUnit').addEventListener('change',()=>{
      if(draftDirty&&!confirm('Les modifications non enregistrées seront perdues. Continuer ?')){
        $('availabilityUnit').value=previousUnitChoice;
        return;
      }
      previousUnitChoice=$('availabilityUnit').value;
      refresh();
    });
    section.addEventListener('toggle',()=>{if(section.open){sync();refresh();}});
    $('availabilitySave').addEventListener('click',save);
    $('availabilityRefresh').addEventListener('click',()=>{
      if(!draftDirty||confirm('Abandonner les modifications non enregistrées ?'))refresh();
    });
    $('availabilityExport').addEventListener('click',exportSpecial);
    $('annualYear')?.addEventListener('change',event=>{
      if(draftDirty&&!confirm('Les modifications non enregistrées seront perdues. Continuer ?')){
        event.stopImmediatePropagation();
        $('annualYear').value=String(bridge.context().annualYear||'');
      }
    },true);
    $('adminUnit')?.addEventListener('change',event=>{
      if(draftDirty&&!confirm('Les modifications non enregistrées seront perdues. Continuer ?')){
        event.stopImmediatePropagation();
        $('adminUnit').value=bridge.context().selectedUnit;
      }
    },true);
    $('annualYear')?.addEventListener('change',()=>{setTimeout(sync,0);});
    $('adminUnit')?.addEventListener('change',()=>{setTimeout(sync,0);});
    const open=()=>{
      sync();
      const {permitted}=scope();
      if(!permitted)return;
      section.open=true;
      if(model && !draftDirty)renderRows();
      section.scrollIntoView({block:'start',behavior:'smooth'});
    };
    window.PointageAvailability = {sync,augment,open};
    // L'administration est chargee apres l'initialisation du module.
    // Observer son apparition garantit la synchronisation des droits
    // lorsque le chargement du profil ou la navigation se termine plus tard.
    const adminArea=$('adminArea');
    if(adminArea && typeof MutationObserver!=='undefined'){
      new MutationObserver(()=>sync()).observe(adminArea,{attributes:true,attributeFilter:['class']});
    }
    // Revalider aussi a l'ouverture apres un changement de compte ou de perimetre.
    section.addEventListener('click',()=>sync());
    sync();
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init,{once:true});
  else init();
})();
