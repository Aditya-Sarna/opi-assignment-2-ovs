/* OVS Lab Console — app.js */

(function () {
  'use strict';

  /* ── State ─────────────────────────────────────── */
  const state = {
    tab: 'topology',
    evidenceTab: 'openflow',
    selectedNode: null,
  };

  /* ── Helpers ────────────────────────────────────── */
  function el(tag, attrs, ...children) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (k === 'cls') {
          node.className = v;
        } else if (k === 'html') {
          node.innerHTML = v;
        } else if (k.startsWith('on')) {
          node.addEventListener(k.slice(2), v);
        } else {
          node.setAttribute(k, v);
        }
      }
    }
    for (const child of children) {
      if (child == null) continue;
      node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child);
    }
    return node;
  }

  function svgEl(tag, attrs) {
    const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
    }
    return node;
  }

  function badge(text, type) {
    return el('span', { cls: `badge badge-${type}` }, text);
  }

  function fmtNum(n) {
    return n != null ? String(n) : '—';
  }

  /* ── Data helpers ───────────────────────────────── */
  const D = window.APP_DATA;

  function classifierFlows() {
    return D.flows.filter(f => (f.match || '').includes('nw_src'));
  }

  function activeMegaflows() {
    return D.datapathFlows.filter(f => f.packets > 0);
  }

  function maxMegaflowPackets() {
    return D.datapathFlows.reduce((m, f) => Math.max(m, f.packets || 0), 0);
  }

  function vlanFdb() {
    return D.fdb.filter(e => e.vlan === 100);
  }

  function hasVlanTag() {
    return D.datapathFlows.some(f => (f.actions || '').includes('push_vlan'));
  }

  function megaflowsForMac(mac) {
    const m = mac.toLowerCase();
    return D.datapathFlows.filter(f => {
      const o = (f.orig || '').toLowerCase();
      return o.includes(`src=${m}`) || o.includes(`dst=${m}`);
    });
  }

  function fdbForMac(mac) {
    return D.fdb.find(e => e.mac && e.mac.toLowerCase() === mac.toLowerCase());
  }

  function nodeById(id) {
    return D.topology.nodes.find(n => n.id === id);
  }

  /* ── Proof cards ────────────────────────────────── */
  function renderProofCards() {
    const cf = classifierFlows();
    const minNPkts = cf.length ? Math.min(...cf.map(f => f.n_packets || 0)) : 0;
    const fdbV = vlanFdb();
    const active = activeMegaflows();

    const cards = [
      {
        label: 'Ping Proof',
        value: `${D.pingBlocks}/4`,
        desc: 'zero-loss blocks (2 pod-VM + 2 VM-VM console)',
        status: 'PASS',
      },
      {
        label: 'Classifier Rules',
        value: cf.length,
        desc: `nw_src= rules, min n_packets = ${minNPkts}`,
        status: `${cf.length} rules hit`,
      },
      {
        label: 'Megaflow Cache',
        value: active.length,
        desc: `active datapath entries, max ${maxMegaflowPackets()} packets`,
        status: `${D.datapathFlows.length} total captured`,
      },
      {
        label: 'VLAN + FDB',
        value: fdbV.length,
        desc: `FDB entries on VLAN 100${hasVlanTag() ? ', push_vlan confirmed' : ''}`,
        status: 'VLAN 100 tag/strip',
      },
    ];

    const grid = el('div', { cls: 'proof-grid' });
    for (const c of cards) {
      grid.appendChild(
        el('div', { cls: 'proof-card' },
          el('div', { cls: 'proof-card-label' }, c.label),
          el('div', { cls: 'proof-card-value' }, String(c.value)),
          el('div', { cls: 'proof-card-desc' }, c.desc),
          el('div', { cls: 'proof-card-status' }, c.status),
        )
      );
    }
    return grid;
  }

  /* ── Header ─────────────────────────────────────── */
  function renderHeader() {
    const m = D.meta || {};
    const ts = (m.timestamp_utc || '').slice(0, 10);
    const header = el('header', { cls: 'site-header' },
      el('h1', null, 'OVS Lab Console'),
      el('div', { cls: 'header-meta' },
        el('span', { cls: 'header-chip' }, `bridge: ${m.bridge || 'br1'}`),
        el('span', { cls: 'header-chip' }, m.node || ''),
        el('span', { cls: 'header-chip' }, (m.ovs_version || '').replace('ovs-vsctl ', '')),
        el('span', { cls: 'header-chip' }, `captured ${ts}`),
        el('a', {
          cls: 'ci-badge',
          href: 'https://github.com/Aditya-Sarna/opi-assignment-2-ovs/actions/runs/28821392090',
          target: '_blank',
          rel: 'noopener',
        },
          el('span', { cls: 'ci-dot' }),
          'CI passing',
        ),
      ),
    );
    return header;
  }

  /* ── Main nav ───────────────────────────────────── */
  function renderNav() {
    const tabs = [
      { id: 'topology', label: 'Topology' },
      { id: 'evidence', label: 'Evidence' },
      { id: 'journey',  label: 'Journey' },
    ];
    const nav = el('nav', { cls: 'main-nav' });
    for (const t of tabs) {
      const btn = el('button', {
        cls: `nav-tab${state.tab === t.id ? ' active' : ''}`,
        onclick: () => switchTab(t.id),
      }, t.label);
      nav.appendChild(btn);
    }
    return nav;
  }

  /* ── Topology ───────────────────────────────────── */
  function renderTopology() {
    const layout = el('div', { cls: 'topology-layout' });

    /* SVG canvas */
    const W = 900, H = 380;
    const svg = svgEl('svg', { viewBox: `0 0 ${W} ${H}` });

    /* Node positions */
    const pos = {
      'vm-a':         { x: 155, y: 105 },
      'vm-b':         { x: 745, y: 105 },
      'ovs-ping-pod': { x: 450, y: 310 },
      'br1':          { x: 450, y: 192 },
    };

    const brX = pos.br1.x, brY = pos.br1.y;

    /* Connection lines */
    for (const e of D.topology.edges) {
      const from = pos[e.from];
      const to   = pos['br1'];
      if (!from || !to) continue;
      const line = svgEl('line', {
        x1: from.x, y1: from.y,
        x2: brX,    y2: brY,
        'class': 'topo-line',
      });
      svg.appendChild(line);
    }

    /* Bridge */
    const brG = svgEl('g', { 'class': 'topo-node', 'data-id': 'br1' });
    brG.appendChild(svgEl('rect', {
      x: brX - 70, y: brY - 28,
      width: 140,  height: 56,
      rx: 6,
      fill: '#21262d',
      stroke: '#30363d',
      'stroke-width': 1.5,
    }));
    const brT = svgEl('text', { 'class': 'topo-label', x: brX, y: brY - 7, fill: '#e6edf3', 'font-size': 14 });
    brT.textContent = 'br1';
    const brS = svgEl('text', { 'class': 'topo-sublabel', x: brX, y: brY + 12, fill: '#8b949e', 'font-size': 11 });
    brS.textContent = 'VLAN 100  OVS';
    brG.appendChild(brT);
    brG.appendChild(brS);
    svg.appendChild(brG);

    /* Endpoint nodes */
    for (const node of D.topology.nodes) {
      const p = pos[node.id];
      if (!p) continue;
      const isSelected = state.selectedNode === node.id;
      const color = node.type === 'vm' ? '#2f81f7' : '#3fb950';
      const g = svgEl('g', {
        'class': `topo-node${isSelected ? ' selected' : ''}`,
        'data-id': node.id,
        style: 'cursor:pointer',
      });
      g.addEventListener('click', () => selectNode(node.id));

      g.appendChild(svgEl('circle', {
        cx: p.x, cy: p.y, r: 46,
        fill: `${color}18`,
        stroke: isSelected ? '#2f81f7' : color,
        'stroke-width': isSelected ? 2.5 : 1.5,
      }));

      const lb = svgEl('text', {
        'class': 'topo-label',
        x: p.x, y: p.y - 8,
        fill: '#e6edf3',
        'font-size': 13,
      });
      lb.textContent = node.id;

      const ip = svgEl('text', {
        'class': 'topo-sublabel',
        x: p.x, y: p.y + 10,
        fill: '#8b949e',
        'font-size': 11,
      });
      ip.textContent = node.ip;

      g.appendChild(lb);
      g.appendChild(ip);
      svg.appendChild(g);
    }

    const canvas = el('div', { cls: 'topology-canvas' });
    canvas.appendChild(svg);

    /* Side panel */
    const panel = el('div', { cls: 'node-panel', id: 'node-panel' });
    renderNodePanel(panel, state.selectedNode);

    layout.appendChild(canvas);
    layout.appendChild(panel);
    return layout;
  }

  function renderNodePanel(panel, nodeId) {
    panel.innerHTML = '';
    if (!nodeId) {
      panel.appendChild(el('div', { cls: 'node-panel-empty' }, 'Click a node to inspect'));
      return;
    }

    const node = nodeById(nodeId);
    if (!node) return;

    const fdbEntry = fdbForMac(node.mac);
    const flows    = megaflowsForMac(node.mac).sort((a, b) => (b.packets || 0) - (a.packets || 0));

    panel.appendChild(el('div', { cls: 'node-panel-title' }, node.id));
    panel.appendChild(el('span', { cls: `node-type-badge ${node.type}` }, node.type.toUpperCase()));

    const rows = [
      ['IP',      node.ip],
      ['MAC',     node.mac],
      ['Type',    node.type],
    ];
    if (fdbEntry) {
      rows.push(['OVS Port',  String(fdbEntry.port)]);
      rows.push(['FDB VLAN',  String(fdbEntry.vlan)]);
      rows.push(['FDB Age',   fdbEntry.age_s + 's']);
    }

    for (const [k, v] of rows) {
      panel.appendChild(
        el('div', { cls: 'detail-row' },
          el('span', { cls: 'detail-key' }, k),
          el('span', { cls: 'detail-value' }, v),
        )
      );
    }

    /* Megaflows */
    if (flows.length) {
      const sec = el('div', { cls: 'panel-section' });
      sec.appendChild(el('div', { cls: 'panel-section-title' }, `Megaflows (${flows.length})`));
      const shown = flows.slice(0, 6);
      for (const f of shown) {
        const orig = (f.orig || '').replace('recirc_id(0),', '');
        const short = orig.length > 48 ? orig.slice(0, 48) + '…' : orig;
        sec.appendChild(
          el('div', { cls: 'megaflow-row' },
            el('span', null, short),
            el('span', { cls: 'megaflow-pkts' }, `${f.packets}p`),
          )
        );
      }
      if (flows.length > 6) {
        sec.appendChild(el('div', { cls: 'detail-value', style: 'text-align:center;padding:4px 0;color:#8b949e' },
          `+ ${flows.length - 6} more`));
      }
      panel.appendChild(sec);
    }
  }

  function selectNode(id) {
    state.selectedNode = state.selectedNode === id ? null : id;
    const panel = document.getElementById('node-panel');
    if (panel) renderNodePanel(panel, state.selectedNode);
    /* update selected class */
    document.querySelectorAll('.topo-node').forEach(g => {
      const isSelected = g.dataset.id === state.selectedNode;
      g.classList.toggle('selected', isSelected);
      const circle = g.querySelector('circle');
      if (circle) {
        if (isSelected) {
          circle.setAttribute('stroke', '#2f81f7');
          circle.setAttribute('stroke-width', '2.5');
        } else {
          const n = nodeById(g.dataset.id);
          const color = n && n.type === 'pod' ? '#3fb950' : '#2f81f7';
          circle.setAttribute('stroke', color);
          circle.setAttribute('stroke-width', '1.5');
        }
      }
    });
  }

  /* ── Evidence ───────────────────────────────────── */
  function renderEvidence() {
    const layout = el('div', { cls: 'evidence-layout' });
    const sidebar = el('div', { cls: 'evidence-sidebar' });
    const content = el('div', { cls: 'evidence-content', id: 'evidence-content' });

    const tabs = [
      { id: 'openflow',  label: 'OpenFlow' },
      { id: 'datapath',  label: 'Datapath' },
      { id: 'fdb',       label: 'FDB' },
      { id: 'ports',     label: 'Ports' },
      { id: 'raw',       label: 'Raw JSON' },
    ];

    for (const t of tabs) {
      const btn = el('button', {
        cls: `evidence-tab${state.evidenceTab === t.id ? ' active' : ''}`,
        onclick: () => switchEvidenceTab(t.id),
      }, t.label);
      sidebar.appendChild(btn);
    }

    renderEvidenceContent(content, state.evidenceTab);
    layout.appendChild(sidebar);
    layout.appendChild(content);
    return layout;
  }

  function renderEvidenceContent(container, tabId) {
    container.innerHTML = '';
    const m = D.meta || {};
    const meta = el('div', { cls: 'evidence-meta' },
      `${m.bridge || 'br1'}  |  ${m.node || ''}  |  ${m.ovs_version || ''}  |  ${m.timestamp_utc || ''}`
    );
    container.appendChild(meta);

    if (tabId === 'openflow')  container.appendChild(renderOpenflowTable());
    if (tabId === 'datapath')  container.appendChild(renderDatapathTable());
    if (tabId === 'fdb')       container.appendChild(renderFdbTable());
    if (tabId === 'ports')     container.appendChild(renderPortsTable());
    if (tabId === 'raw')       container.appendChild(renderRawJson());
  }

  function renderOpenflowTable() {
    const rows = D.flows.slice().sort((a, b) => (b.priority || 0) - (a.priority || 0));
    const table = el('table', { cls: 'data-table' });
    table.appendChild(el('thead', null, el('tr', null,
      el('th', null, 'Priority'),
      el('th', null, 'Match'),
      el('th', null, 'n_packets'),
      el('th', null, 'n_bytes'),
      el('th', null, 'Actions'),
    )));
    const tbody = el('tbody');
    for (const f of rows) {
      const isClassifier = (f.match || '').includes('nw_src');
      const tr = el('tr', { cls: isClassifier ? 'highlight' : '' });
      tr.appendChild(el('td', null, fmtNum(f.priority)));
      tr.appendChild(el('td', null,
        f.match || '*',
        isClassifier ? badge('classifier', 'blue') : null,
      ));
      const pktsEl = el('td', null);
      pktsEl.appendChild(el('span', { cls: f.n_packets > 0 ? 'num-positive' : '' }, fmtNum(f.n_packets)));
      tr.appendChild(pktsEl);
      tr.appendChild(el('td', null, fmtNum(f.n_bytes)));
      tr.appendChild(el('td', null, f.actions || ''));
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    return table;
  }

  function renderDatapathTable() {
    const rows = D.datapathFlows
      .slice()
      .sort((a, b) => (b.packets || 0) - (a.packets || 0));
    const table = el('table', { cls: 'data-table' });
    table.appendChild(el('thead', null, el('tr', null,
      el('th', null, 'Packets'),
      el('th', null, 'Bytes'),
      el('th', null, 'Used (s)'),
      el('th', null, 'Actions'),
      el('th', null, 'Flags'),
    )));
    const tbody = el('tbody');
    for (const f of rows) {
      const hasVlan = (f.actions || '').includes('push_vlan');
      const tr = el('tr');
      const pktsEl = el('td', null);
      pktsEl.appendChild(el('span', { cls: f.packets > 0 ? 'num-positive' : '' }, fmtNum(f.packets)));
      tr.appendChild(pktsEl);
      tr.appendChild(el('td', null, fmtNum(f.bytes)));
      tr.appendChild(el('td', null, f.used_s != null ? String(f.used_s) : '—'));
      tr.appendChild(el('td', null, (f.actions || '').slice(0, 40) + ((f.actions || '').length > 40 ? '…' : '')));
      const flagsTd = el('td');
      if (hasVlan) flagsTd.appendChild(badge('push_vlan', 'yellow'));
      tr.appendChild(flagsTd);
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    return table;
  }

  function renderFdbTable() {
    const table = el('table', { cls: 'data-table' });
    table.appendChild(el('thead', null, el('tr', null,
      el('th', null, 'Port'),
      el('th', null, 'VLAN'),
      el('th', null, 'MAC'),
      el('th', null, 'Age (s)'),
      el('th', null, 'Mapped to'),
    )));
    const tbody = el('tbody');
    /* build mac→node map */
    const macNode = {};
    for (const n of D.topology.nodes) macNode[n.mac.toLowerCase()] = n.id;

    for (const e of D.fdb) {
      const nodeId = macNode[(e.mac || '').toLowerCase()] || '—';
      const tr = el('tr');
      tr.appendChild(el('td', null, fmtNum(e.port)));
      tr.appendChild(el('td', null, el('span', { cls: e.vlan === 100 ? 'num-positive' : '' }, fmtNum(e.vlan))));
      tr.appendChild(el('td', null, e.mac || ''));
      tr.appendChild(el('td', null, e.age_s || ''));
      tr.appendChild(el('td', null, nodeId));
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    return table;
  }

  function renderPortsTable() {
    const table = el('table', { cls: 'data-table' });
    table.appendChild(el('thead', null, el('tr', null,
      el('th', null, 'OFPort'),
      el('th', null, 'Name'),
      el('th', null, 'MAC'),
    )));
    const tbody = el('tbody');
    for (const p of D.ports) {
      const tr = el('tr');
      tr.appendChild(el('td', null, p.ofport || ''));
      tr.appendChild(el('td', null, p.name || ''));
      tr.appendChild(el('td', null, p.mac || ''));
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    return table;
  }

  function renderRawJson() {
    const { meta, flows, datapathFlows, fdb, ports } = D;
    const summary = { _meta: meta, bridge: D.bridge, flows, datapath_flows: datapathFlows, fdb, ports };
    const pre = el('pre', { cls: 'raw-pre' });
    pre.textContent = JSON.stringify(summary, null, 2);
    return pre;
  }

  /* ── Journey ────────────────────────────────────── */
  function renderJourney() {
    const list = el('div', { cls: 'journey-list' });
    for (const item of D.journey) {
      const dot  = el('div', { cls: 'journey-dot' });
      const card = el('div', { cls: 'journey-card' });
      card.appendChild(el('div', { cls: 'journey-title' }, item.title));
      if (item.problem) {
        card.appendChild(el('div', { cls: 'journey-problem' }, 'Problem: ' + item.problem));
      }
      if (item.fix) {
        card.appendChild(el('div', { cls: 'journey-fix' }, 'Fix: ' + item.fix));
      }
      if (item.detail) {
        card.appendChild(el('div', { cls: 'journey-detail' }, item.detail));
      }
      if (item.proof) {
        card.appendChild(el('div', { cls: 'journey-proof' }, item.proof));
      }
      const wrapper = el('div', { cls: 'journey-item' });
      wrapper.appendChild(dot);
      wrapper.appendChild(card);
      list.appendChild(wrapper);
    }
    return list;
  }

  /* ── Tab switching ──────────────────────────────── */
  function switchTab(id) {
    state.tab = id;
    /* update nav */
    document.querySelectorAll('.nav-tab').forEach(b => {
      b.classList.toggle('active', b.textContent.trim().toLowerCase() === id);
    });
    /* re-render content only */
    const content = document.getElementById('main-content');
    if (content) renderContent(content);
  }

  function switchEvidenceTab(id) {
    state.evidenceTab = id;
    /* update sidebar tabs */
    document.querySelectorAll('.evidence-tab').forEach(b => {
      const tId = b.textContent.trim().toLowerCase().replace(' ', '');
      const map = { 'openflow': 'openflow', 'datapath': 'datapath', 'fdb': 'fdb',
                    'ports': 'ports', 'rawjson': 'raw' };
      b.classList.toggle('active', map[tId] === id || tId === id);
    });
    const content = document.getElementById('evidence-content');
    if (content) renderEvidenceContent(content, id);
  }

  function renderContent(container) {
    container.innerHTML = '';
    if (state.tab === 'topology') container.appendChild(renderTopology());
    if (state.tab === 'evidence') container.appendChild(renderEvidence());
    if (state.tab === 'journey')  container.appendChild(renderJourney());
  }

  /* ── Init ───────────────────────────────────────── */
  function init() {
    if (!window.APP_DATA) {
      document.getElementById('app').textContent = 'Error: data.js not loaded.';
      return;
    }
    const app = document.getElementById('app');
    app.innerHTML = '';

    app.appendChild(renderHeader());
    app.appendChild(renderProofCards());
    app.appendChild(renderNav());

    const content = el('div', { cls: 'tab-content', id: 'main-content' });
    renderContent(content);
    app.appendChild(content);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
