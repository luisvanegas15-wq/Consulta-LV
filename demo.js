/* =========================================================
   CONSULTA LV · MODO DEMO
   Base de datos simulada en memoria con datos 100 % ficticios.
   No se conecta al servidor: nada se guarda y todo se borra al cerrar la pestaña.
   ========================================================= */
(function () {
  'use strict';
  const DEMO_ID = '00000000-0000-4000-8000-00000000d3e0';
  const REL = { pacientes: 'paciente_id', servicios: 'servicio_id', profesionales: 'profesional_id', paquetes: 'paquete_id' };
  const DB = {};
  const T = n => (DB[n] = DB[n] || []);
  const uid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); }));
  const ahoraISO = () => new Date().toISOString();
  const copia = o => JSON.parse(JSON.stringify(o));
  const esFechaHora = v => typeof v === 'string' && /^\d{4}-\d\d-\d\dT/.test(v);
  const comparar = (a, b) => {
    if (a == null || b == null) return a == null && b == null ? 0 : NaN;
    if (esFechaHora(a) || esFechaHora(b)) { const x = Date.parse(a), y = Date.parse(b); if (!isNaN(x) && !isNaN(y)) return x - y; }
    if (typeof a === 'number' || typeof b === 'number') return (+a) - (+b);
    return String(a) < String(b) ? -1 : String(a) > String(b) ? 1 : 0;
  };
  const err = m => ({ data: null, error: { message: m } });

  /* ---------- defaults por tabla ---------- */
  function conDefaults(tabla, f) {
    const base = { id: uid(), created_at: ahoraISO(), profesional_id: DEMO_ID };
    const d = {
      citas: { estado: 'pendiente', origen: 'manual', valor: 0, pagado: false, metodo_pago: '', enlace_virtual: '', serie: null, recordatorio_at: null, token_paciente: uid(), paquete_id: null },
      servicios: { activo: true, modalidad: 'presencial', descripcion: '' },
      paquetes: { activo: true, fecha: new Date(Date.now() - 5 * 3600000).toISOString().slice(0, 10), pagado: false, metodo_pago: '' },
      formularios: { token: uid(), estado: 'pendiente', expira_at: new Date(Date.now() + 14 * 864e5).toISOString() },
      lista_espera: { estado: 'esperando' },
      gastos: {}, pacientes: {}, notas_clinicas: {}, escalas: {}, plantillas: {}, documentos: {}, adjuntos: {}, bloqueos: {}, disponibilidad: {}, llaves: {}, resenas: {}
    }[tabla] || {};
    return Object.assign(base, d, f);
  }
  function validar(tabla, fila, ignorarId) {
    if (tabla === 'citas' && fila.estado !== 'cancelada' && fila.estado !== 'no_asistio') {
      const a = Date.parse(fila.inicio), b = Date.parse(fila.fin);
      const choque = T('citas').some(c => c.id !== ignorarId && !['cancelada', 'no_asistio'].includes(c.estado) && Date.parse(c.inicio) < b && a < Date.parse(c.fin));
      if (choque) return 'conflicting key value violates exclusion constraint "sin_cruce"';
    }
    return null;
  }

  /* ---------- constructor de consultas (imita a supabase-js) ---------- */
  function partirCols(s) {
    const out = []; let n = 0, cur = '';
    for (const ch of (s || '*')) { if (ch === '(') n++; if (ch === ')') n--; if (ch === ',' && !n) { out.push(cur.trim()); cur = ''; } else cur += ch; }
    if (cur.trim()) out.push(cur.trim()); return out;
  }
  function Q(tabla) {
    const q = { tabla, op: 'select', cols: '*', filtros: [], orden: [], lim: null, uno: null, head: false, count: null, payload: null, devolver: false };
    const api = {
      select(cols, o) { if (q.op === 'select') { q.cols = cols || '*'; if (o) { q.head = !!o.head; q.count = o.count || null; } } else { q.devolver = true; q.cols = cols || '*'; } return api; },
      insert(p) { q.op = 'insert'; q.payload = p; return api; },
      upsert(p) { q.op = 'insert'; q.payload = p; return api; },
      update(p) { q.op = 'update'; q.payload = p; return api; },
      delete() { q.op = 'delete'; return api; },
      eq(c, v) { q.filtros.push(r => comparar(r[c], v) === 0 || r[c] === v); return api; },
      neq(c, v) { q.filtros.push(r => r[c] !== v); return api; },
      gt(c, v) { q.filtros.push(r => comparar(r[c], v) > 0); return api; },
      gte(c, v) { q.filtros.push(r => comparar(r[c], v) >= 0); return api; },
      lt(c, v) { q.filtros.push(r => comparar(r[c], v) < 0); return api; },
      lte(c, v) { q.filtros.push(r => comparar(r[c], v) <= 0); return api; },
      in(c, l) { q.filtros.push(r => (l || []).includes(r[c])); return api; },
      is(c, v) { q.filtros.push(r => (v === null ? r[c] == null : r[c] === v)); return api; },
      not(c, op, v) { q.filtros.push(r => (op === 'is' && v === null ? r[c] != null : r[c] !== v)); return api; },
      match(o) { Object.entries(o).forEach(([c, v]) => api.eq(c, v)); return api; },
      ilike(c, v) { const re = new RegExp('^' + String(v).replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/%/g, '.*') + '$', 'i'); q.filtros.push(r => re.test(r[c] || '')); return api; },
      order(c, o) { q.orden.push([c, !(o && o.ascending === false)]); return api; },
      limit(n) { q.lim = n; return api; },
      range(a, b) { q.lim = b + 1; return api; },
      single() { q.uno = 'single'; return api; },
      maybeSingle() { q.uno = 'maybe'; return api; },
      then(ok, ko) { return Promise.resolve().then(() => ejecutar(q)).then(ok, ko); }
    };
    return api;
  }
  function conEmbebidos(fila, cols) {
    const r = copia(fila);
    partirCols(cols).forEach(tok => {
      const m = tok.match(/^([a-z_]+)\((.*)\)$/); if (!m) return;
      const rel = m[1], fk = REL[rel]; if (!fk) return;
      const x = T(rel).find(y => y.id === fila[fk]);
      r[rel] = x ? copia(x) : null;
    });
    return r;
  }
  function ejecutar(q) {
    const tabla = T(q.tabla);
    const pasa = r => q.filtros.every(f => f(r));
    let filas;
    if (q.op === 'insert') {
      const lista = (Array.isArray(q.payload) ? q.payload : [q.payload]).map(p => conDefaults(q.tabla, copia(p)));
      for (const f of lista) { const e = validar(q.tabla, f); if (e) return err(e); }
      if (q.tabla === 'renovaciones') return err('En la demo no se realizan pagos. Crea tu cuenta para suscribirte.');
      lista.forEach(f => tabla.push(f)); filas = lista;
    } else if (q.op === 'update') {
      const obj = tabla.filter(pasa);
      for (const f of obj) { const e = validar(q.tabla, Object.assign({}, f, q.payload), f.id); if (e) return err(e); }
      obj.forEach(f => Object.assign(f, copia(q.payload))); filas = obj;
    } else if (q.op === 'delete') {
      const obj = tabla.filter(pasa); DB[q.tabla] = tabla.filter(r => !obj.includes(r)); filas = obj;
    } else filas = tabla.filter(pasa);
    if (q.op !== 'select' && !q.devolver && !q.uno) return { data: null, error: null };
    if (q.orden.length) filas = filas.slice().sort((a, b) => { for (const [c, asc] of q.orden) { const v = comparar(a[c], b[c]); if (v) return asc ? v : -v; } return 0; });
    if (q.lim != null) filas = filas.slice(0, q.lim);
    if (q.head) return { data: null, count: filas.length, error: null };
    const datos = filas.map(f => conEmbebidos(f, q.cols));
    if (q.uno === 'single') return datos.length === 1 ? { data: datos[0], error: null } : err(datos.length ? 'Más de una fila' : 'No se encontró el registro');
    if (q.uno === 'maybe') return { data: datos[0] || null, error: null };
    return { data: datos, error: null, count: q.count ? datos.length : null };
  }

  /* ---------- RPC, archivos y sesión simulados ---------- */
  const SIN_DEMO = 'Esta función no está disponible en la demo. Crea tu cuenta gratis para usarla.';
  async function rpc(nombre) {
    if (nombre === 'es_admin') return { data: false, error: null };
    if (nombre === 'registrar_acceso') return { data: null, error: null };
    if (/^(enviar_formulario_correo|invitar_resena)$/.test(nombre)) return err('En la demo no se envían correos. Usa el botón de WhatsApp o copia el enlace.');
    return err(SIN_DEMO);
  }
  const storage = { from: () => ({
    upload: async () => err('En la demo no se suben archivos. Crea tu cuenta para adjuntar documentos.'),
    download: async () => err(SIN_DEMO), remove: async () => ({ data: [], error: null }),
    createSignedUrl: async () => err(SIN_DEMO), getPublicUrl: () => ({ data: { publicUrl: '' } }) }) };
  const user = { id: DEMO_ID, email: 'demo@consultalv.co' };
  const auth = {
    getSession: async () => ({ data: { session: { user } } }), getUser: async () => ({ data: { user } }),
    signOut: async () => ({ error: null }), onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
    signInWithPassword: async () => err(SIN_DEMO), signUp: async () => err(SIN_DEMO), resetPasswordForEmail: async () => err(SIN_DEMO), updateUser: async () => err(SIN_DEMO),
    mfa: { getAuthenticatorAssuranceLevel: async () => ({ data: { currentLevel: 'aal1', nextLevel: 'aal1' } }), listFactors: async () => ({ data: { totp: [] } }),
      enroll: async () => err(SIN_DEMO), challengeAndVerify: async () => err(SIN_DEMO), unenroll: async () => err(SIN_DEMO) }
  };
  window.crearDemoSB = () => ({ from: Q, rpc, storage, auth, channel: () => ({ on() { return this; }, subscribe() { return this; } }), removeChannel() {} });

  /* ---------- DATOS FICTICIOS ---------- */
  let semilla = 20261124;
  const rnd = () => { semilla = (semilla * 1103515245 + 12345) % 2147483648; return semilla / 2147483648; };
  const elige = l => l[Math.floor(rnd() * l.length)];
  const ymdBog = d => new Date(d.getTime() - 5 * 3600000).toISOString().slice(0, 10);
  const sumar = (ymd, n) => { const d = new Date(ymd + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  const enBog = (ymd, h, m) => new Date(`${ymd}T${String(h).padStart(2, '0')}:${String(m || 0).padStart(2, '0')}:00-05:00`).toISOString();

  window.sembrarDemo = async function (cifrar, terminosV) {
    Object.keys(DB).forEach(k => delete DB[k]);
    const hoy = ymdBog(new Date());
    T('profesionales').push({
      id: DEMO_ID, email: user.email, nombre: 'Valentina Ríos Gómez', titulo: 'Psicóloga clínica · Mg. en Psicología', tarjeta_profesional: '000000 (demo)',
      ciudad: 'Cali', whatsapp: '3000000000', slug: 'demo-valentina', direccion: 'Consultorio 302 (dirección de ejemplo)', bio: 'Perfil de demostración con datos ficticios.',
      enfoque: 'Cognitivo-conductual', experiencia_anios: 8, idiomas: 'Español', poblacion: 'Adolescentes y adultos', especialidades: 'Ansiedad, depresión, duelo, terapia de pareja',
      formacion: 'Psicóloga · Magíster en Psicología Clínica', foto_url: '', activo_hasta: sumar(hoy, 30), created_at: new Date(Date.now() - 200 * 864e5).toISOString(),
      terminos_at: ahoraISO(), terminos_version: terminosV, bienvenida_vista: true, contrato_encargado_at: ahoraISO(), meta_mensual: 10000000,
      horario_auto: false, horas_cancelacion: 12, recordatorios_email: true, en_directorio: false, nequi: '3000000000', datos_pago: '', enlace_pago: '',
      medios_pago: { nequi: { on: true, num: '3000000000' }, efectivo: { on: true } }, color_marca: '#0e7490'
    });
    T('llaves').push({ profesional_id: DEMO_ID, sal: 'demo', llave_por_clave: 'demo', iv_clave: 'demo' });
    [1, 2, 3, 4, 5].forEach(d => { T('disponibilidad').push({ id: uid(), profesional_id: DEMO_ID, dia: d, hora_inicio: '08:00', hora_fin: '12:00' }); T('disponibilidad').push({ id: uid(), profesional_id: DEMO_ID, dia: d, hora_inicio: '14:00', hora_fin: '18:00' }); });
    T('disponibilidad').push({ id: uid(), profesional_id: DEMO_ID, dia: 6, hora_inicio: '08:00', hora_fin: '12:00' });

    const S = [['Psicoterapia individual', 50, 120000, 'presencial'], ['Psicoterapia virtual', 50, 110000, 'virtual'], ['Terapia de pareja', 80, 180000, 'presencial'], ['Evaluación psicológica', 90, 250000, 'presencial']]
      .map(([nombre, duracion_min, precio, modalidad], i) => conDefaults('servicios', { nombre, duracion_min, precio, modalidad, created_at: new Date(Date.now() - (300 - i) * 864e5).toISOString() }));
    S.forEach(s => T('servicios').push(s));

    const NOM = ['Camila Andrea Torres', 'Juan Sebastián Mejía', 'Laura Daniela Ospina', 'Andrés Felipe Cárdenas', 'María José Restrepo', 'Santiago Valencia Ruiz',
      'Daniela Muñoz Arango', 'Carlos Eduardo Patiño', 'Valeria Henao López', 'Mateo Giraldo Castro', 'Isabella Quintero', 'Felipe Rojas Mora',
      'Natalia Zapata Gil', 'Julián Ramírez Duque', 'Sara Lucía Vélez', 'Diego Alejandro Ríos', 'Paula Andrea Salazar', 'Tomás Herrera Lozano'];
    const pacs = NOM.map((n, i) => {
      const dias = Math.round(175 - i * 9.5 + rnd() * 6);
      const creado = new Date(Date.now() - Math.max(2, dias) * 864e5).toISOString();
      return conDefaults('pacientes', { nombres: n, documento: String(1000000000 + Math.floor(rnd() * 99999999)), telefono: '300' + String(1000000 + Math.floor(rnd() * 8999999)),
        email: n.split(' ')[0].toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '') + '.demo@ejemplo.co', fecha_nacimiento: `${1975 + Math.floor(rnd() * 32)}-0${1 + Math.floor(rnd() * 9)}-1${Math.floor(rnd() * 9)}`,
        contacto_emergencia: 'Familiar · 3100000000', autorizacion_datos_at: creado, consentimiento_at: creado, created_at: creado });
    });
    pacs.forEach(p => T('pacientes').push(p));

    // Citas: desde hace ~6 meses hasta 3 semanas adelante, con crecimiento mes a mes
    const ini = sumar(hoy, -178), fin = sumar(hoy, 21), HORAS = [8, 9, 10, 11, 14, 15, 16, 17];
    const metodos = ['nequi', 'nequi', 'efectivo', 'bancolombia', 'daviplata', 'transferencia'];
    for (let d = ini; d <= fin; d = sumar(d, 1)) {
      const dow = new Date(d + 'T12:00:00Z').getUTCDay(); if (dow === 0) continue;
      const avance = (Date.parse(d) - Date.parse(ini)) / (Date.parse(hoy) - Date.parse(ini));
      const activos = pacs.filter(p => ymdBog(new Date(p.created_at)) <= d);
      if (!activos.length) continue;
      let n = dow === 6 ? 1 + Math.floor(rnd() * 2) : Math.round(0.6 + Math.pow(Math.min(1.1, Math.max(0, avance)), 2) * 2.6 + rnd() * 1.2 + (d.slice(0, 7) === hoy.slice(0, 7) ? 1.8 : 0));
      if (d === hoy) n = Math.max(n, 4);
      const horas = HORAS.slice().sort(() => rnd() - 0.5).slice(0, Math.min(n, dow === 6 ? 3 : 8)).sort((a, b) => a - b);
      horas.filter(h => dow !== 6 || h < 12).forEach(h => {
        const p = elige(activos), sv = rnd() < 0.12 ? S[2] : rnd() < 0.08 ? S[3] : rnd() < 0.3 ? S[1] : S[0];
        const inicio = enBog(d, h), finC = new Date(Date.parse(inicio) + sv.duracion_min * 60000).toISOString();
        const pasado = Date.parse(finC) < Date.now(); const r = rnd();
        let estado = pasado ? (r < 0.84 ? 'asistio' : r < 0.93 ? 'no_asistio' : 'cancelada') : (r < 0.72 ? 'confirmada' : 'pendiente');
        if (d === hoy && !pasado) estado = r < 0.8 ? 'confirmada' : 'pendiente';
        const pagado = estado === 'asistio' && (Date.now() - Date.parse(inicio) > 10 * 864e5 ? rnd() < 0.97 : rnd() < 0.7);
        T('citas').push(conDefaults('citas', { paciente_id: p.id, servicio_id: sv.id, inicio, fin: finC, estado, origen: rnd() < 0.35 ? 'online' : 'manual', valor: sv.precio, pagado,
          metodo_pago: pagado ? elige(metodos) : '', enlace_virtual: sv.modalidad === 'virtual' ? 'https://meet.jit.si/ConsultaLV-demo' : '',
          recordatorio_at: !pasado && rnd() < 0.5 ? ahoraISO() : null, created_at: new Date(Date.parse(inicio) - 7 * 864e5).toISOString() }));
      });
    }
    // Paquete de sesiones
    const pq = conDefaults('paquetes', { paciente_id: pacs[3].id, nombre: 'Paquete 8 sesiones', sesiones: 8, valor: 880000, pagado: true, metodo_pago: 'bancolombia', fecha: sumar(hoy, -20) });
    T('paquetes').push(pq);
    T('citas').filter(c => c.paciente_id === pacs[3].id && c.inicio > enBog(sumar(hoy, -20), 0)).slice(0, 4).forEach(c => Object.assign(c, { paquete_id: pq.id, valor: 0, pagado: true, metodo_pago: 'paquete' }));

    // Gastos mensuales
    for (let i = 5; i >= 0; i--) {
      const m = new Date(Date.parse(hoy + 'T12:00:00Z')); m.setUTCDate(1); m.setUTCMonth(m.getUTCMonth() - i); const ym = m.toISOString().slice(0, 7);
      const g = [['arriendo', 'Arriendo consultorio', 900000, '01'], ['software', 'Consulta LV y herramientas', 60000, '03'], ['publicidad', 'Pauta en Instagram', 150000 + Math.round(rnd() * 15) * 10000, '10'], ['servicios', 'Internet y teléfono', 95000, '15']];
      if (i === 2) g.push(['formacion', 'Diplomado en terapia breve', 450000, '20']);
      g.forEach(([categoria, concepto, valor, dd]) => { const f = `${ym}-${dd}`; if (f <= hoy) T('gastos').push(conDefaults('gastos', { categoria, concepto, valor, fecha: f })); });
    }

    // Lista de espera y reseñas
    [['Mariana Lozano', '3001112233', 'Martes o jueves en la tarde'], ['Jorge Iván Peña', '3004445566', 'Sábados en la mañana']]
      .forEach(([nombres, telefono, preferencia]) => T('lista_espera').push(conDefaults('lista_espera', { nombres, telefono, email: '', preferencia, autorizacion_datos_at: ahoraISO() })));
    [[5, 'Me sentí escuchada desde la primera sesión. Muy profesional.', 'Camila T.', 'Gracias por tu confianza, Camila.'], [5, 'Puntual y explica todo con claridad.', 'Andrés C.', ''],
      [4, 'Muy buena terapia de pareja, nos ayudó bastante.', 'M. y S.', ''], [5, 'Recomendada 100 %.', 'Laura O.', '']]
      .forEach(([estrellas, comentario, alias, respuesta], i) => T('resenas').push(conDefaults('resenas', { estrellas, comentario, alias, respuesta, publicada_at: new Date(Date.now() - (10 + i * 17) * 864e5).toISOString() })));

    // Historias, notas y escalas (cifradas con la clave temporal de la demo)
    const HCX = [
      { motivo: 'Refiere preocupación constante, tensión muscular y dificultad para dormir desde hace 4 meses.', problema: 'Inicio asociado a cambio de trabajo. Ha intentado ejercicio sin mejoría sostenida.', ant_psico: 'Sin tratamientos previos.', familia: 'Vive con su pareja; buena red de apoyo.', em_afecto: 'Ansioso, congruente.', dx: 'F41.1 Trastorno de ansiedad generalizada (impresión diagnóstica)', objetivos: 'Reducir preocupación y mejorar higiene del sueño; reestructuración cognitiva.' },
      { motivo: 'Tristeza, desmotivación y aislamiento tras ruptura de pareja.', problema: 'Síntomas de 2 meses, con disminución del rendimiento laboral.', ant_psico: 'Un proceso breve de orientación en la universidad.', familia: 'Relación cercana con la madre.', em_afecto: 'Hipotímico, llanto fácil.', dx: 'F32.0 Episodio depresivo leve (impresión diagnóstica)', objetivos: 'Activación conductual, reestructurar creencias de minusvalía, fortalecer red social.' },
      { motivo: 'Duelo por fallecimiento del padre hace 6 meses.', problema: 'Dificultad para retomar rutinas; pensamientos recurrentes sobre la pérdida.', ant_psico: 'Ninguno.', familia: 'Hermanos con poco contacto.', em_afecto: 'Triste, modulado.', dx: 'Z63.4 Duelo (impresión diagnóstica)', objetivos: 'Elaboración del duelo y reorganización de la vida cotidiana.' }];
    const SEG = [['Revisión de registros de pensamiento; identifica preocupaciones anticipatorias.', 'Colaborador, menor tensión que en la sesión previa.', 'Reestructuración cognitiva y respiración diafragmática.', 'Registro diario de preocupaciones y práctica de respiración 2 veces al día.'],
      ['Reporta mejoría en el sueño.', 'Afecto más eutímico.', 'Psicoeducación en higiene del sueño; técnica de exposición gradual.', 'Mantener horarios de sueño y caminar 3 veces por semana.'],
      ['Comenta situación laboral estresante.', 'Ansiedad moderada, discurso coherente.', 'Solución de problemas y asertividad.', 'Practicar una conversación asertiva con su jefe.']];
    for (let k = 0; k < 3; k++) {
      const p = pacs[k], fechaHC = ymdBog(new Date(p.created_at));
      T('notas_clinicas').push(conDefaults('notas_clinicas', Object.assign({ paciente_id: p.id, fecha: fechaHC, firmada_at: new Date(Date.parse(fechaHC) + 864e5 / 2).toISOString() },
        await cifrar({ tipo: 'historia', hc: HCX[k], riesgo: 'ninguno', acciones_riesgo: '', borrador: false }))));
      const asist = T('citas').filter(c => c.paciente_id === p.id && c.estado === 'asistio').slice(1, 4);
      for (let j = 0; j < asist.length; j++) {
        const s = SEG[(j + k) % SEG.length], f = ymdBog(new Date(asist[j].inicio));
        T('notas_clinicas').push(conDefaults('notas_clinicas', Object.assign({ paciente_id: p.id, fecha: f, cita_id: asist[j].id, firmada_at: asist[j].fin },
          await cifrar({ tipo: 'seguimiento', riesgo: 'ninguno', acciones_riesgo: '', motivo: s[0], observaciones: s[1], intervencion: s[2], plan: s[3] }))));
      }
    }
    const nivelPHQ = t => t <= 4 ? ['Mínimo', 'b-ok'] : t <= 9 ? ['Leve', 'b-conf'] : t <= 14 ? ['Moderado', 'b-pend'] : ['Moderadamente severo', 'b-bad'];
    const nivelGAD = t => t <= 4 ? ['Mínima', 'b-ok'] : t <= 9 ? ['Leve', 'b-conf'] : t <= 14 ? ['Moderada', 'b-pend'] : ['Severa', 'b-bad'];
    const serie = async (p, tipo, totales, n, nivel) => {
      for (let i = 0; i < totales.length; i++) {
        const t = totales[i], resp = Array.from({ length: n }, (_, j) => Math.min(3, Math.floor(t / n) + (j < t % n ? 1 : 0)));
        if (tipo === 'PHQ-9') resp[8] = 0;
        const tot = resp.reduce((a, b) => a + b, 0), f = sumar(ymdBog(new Date(p.created_at)), i * 21 + 1); if (f > hoy) break;
        T('escalas').push(conDefaults('escalas', Object.assign({ paciente_id: p.id, tipo, fecha: f }, await cifrar({ respuestas: resp, total: tot, nivel: nivel(tot)[0], clase: nivel(tot)[1] }))));
      }
    };
    await serie(pacs[0], 'GAD-7', [16, 13, 10, 7, 5], 7, nivelGAD);
    await serie(pacs[1], 'PHQ-9', [14, 12, 9, 7, 4], 9, nivelPHQ);
    await serie(pacs[2], 'PHQ-9', [11, 10, 8, 6], 9, nivelPHQ);
    return DB;
  };
})();
