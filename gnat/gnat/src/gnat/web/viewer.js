    let stopped = false;
    let dragging = false;
    let lastPointer = null;
    let cameraSendTimer = null;
    const camera = { azimuth: 45, elevation: -31, distance: 20 };
    const viewerToken = '__GNAT_TOKEN__';
    const mainFrame = document.querySelector('#main-frame');
    const brainCanvas = document.querySelector('#brain-view');
    const brainContext = brainCanvas.getContext('2d');

    function withToken(path) {
      const separator = path.includes('?') ? '&' : '?';
      return `${path}${separator}token=${encodeURIComponent(viewerToken)}`;
    }

    async function command(path) {
      try {
        const response = await fetch(withToken(path), {
          method: 'POST',
          headers: { 'X-Gnat-Token': '__GNAT_TOKEN__' },
        });
        const data = await response.json();
        document.querySelector('#status').textContent = data.status;
        if (path === '/quit') stopped = true;
      } catch (error) {
        document.querySelector('#status').textContent = '接続エラー';
      }
    }
    function clamp(value, min, max) {
      return Math.max(min, Math.min(max, value));
    }
    function sendCamera() {
      const query = new URLSearchParams({
        azimuth: camera.azimuth.toFixed(2),
        elevation: camera.elevation.toFixed(2),
        distance: camera.distance.toFixed(2),
      });
      fetch(withToken('/camera?' + query.toString()), {
        method: 'POST',
        headers: { 'X-Gnat-Token': '__GNAT_TOKEN__' },
      }).catch(() => {});
    }
    function queueCamera() {
      if (cameraSendTimer !== null) return;
      cameraSendTimer = setTimeout(() => {
        cameraSendTimer = null;
        sendCamera();
      }, 16);
    }
    function resetCamera() {
      camera.azimuth = 45;
      camera.elevation = -31;
      camera.distance = 20;
      sendCamera();
    }
    mainFrame.addEventListener('pointerdown', (event) => {
      dragging = true;
      lastPointer = { x: event.clientX, y: event.clientY };
      mainFrame.classList.add('dragging');
      mainFrame.setPointerCapture(event.pointerId);
    });
    mainFrame.addEventListener('pointermove', (event) => {
      if (!dragging || lastPointer === null) return;
      const dx = event.clientX - lastPointer.x;
      const dy = event.clientY - lastPointer.y;
      lastPointer = { x: event.clientX, y: event.clientY };
      camera.azimuth = (camera.azimuth - dx * 0.35 + 360) % 360;
      camera.elevation = clamp(camera.elevation + dy * 0.25, -80, -5);
      queueCamera();
    });
    mainFrame.addEventListener('pointerup', () => {
      dragging = false;
      lastPointer = null;
      mainFrame.classList.remove('dragging');
    });
    mainFrame.addEventListener('pointercancel', () => {
      dragging = false;
      lastPointer = null;
      mainFrame.classList.remove('dragging');
    });
    mainFrame.addEventListener('wheel', (event) => {
      event.preventDefault();
      camera.distance = clamp(camera.distance * Math.exp(event.deltaY * 0.001), 20, 180);
      queueCamera();
    }, { passive: false });
    window.addEventListener('keydown', (event) => {
      if (event.code === 'Space' && event.target === document.body) {
        event.preventDefault();
        command('/fire');
      }
    });
    const frameRequests = new Map();
    async function refresh(id, path) {
      if (stopped || frameRequests.get(id)) return;
      frameRequests.set(id, true);
      const image = document.querySelector(id);
      let objectUrl = null;
      try {
        const response = await fetch(withToken(path + '?t=' + Date.now()), {
          cache: 'no-store',
          headers: { 'X-Gnat-Token': '__GNAT_TOKEN__' },
        });
        if (!response.ok) throw new Error(`frame request failed: ${response.status}`);
        const blob = await response.blob();
        objectUrl = URL.createObjectURL(blob);
        await new Promise((resolve, reject) => {
          const cleanup = () => {
            image.removeEventListener('load', loaded);
            image.removeEventListener('error', failed);
          };
          const loaded = () => { cleanup(); resolve(); };
          const failed = () => { cleanup(); reject(new Error('image decode failed')); };
          image.addEventListener('load', loaded, { once: true });
          image.addEventListener('error', failed, { once: true });
          image.src = objectUrl;
        });
      } catch (error) {
        // Keep the last good frame on screen while the next frame is produced.
      } finally {
        if (objectUrl !== null) URL.revokeObjectURL(objectUrl);
        frameRequests.delete(id);
      }
    }
    async function refreshFrames() {
      if (stopped) return;
      await Promise.all([
        refresh('#main-view', '/frame/main.jpg'),
        refresh('#left-eye', '/frame/left.jpg'),
        refresh('#right-eye', '/frame/right.jpg'),
      ]);
      if (!stopped) setTimeout(refreshFrames, 33);
    }
    let brainRequestActive = false;
    let healthRequestActive = false;
    let lastHealthFrame = null;
    let staleHealthPolls = 0;
    async function refreshBrain() {
      if (stopped || brainRequestActive) return;
      brainRequestActive = true;
      try {
        const response = await fetch(withToken('/brain/state?t=' + Date.now()), {
          cache: 'no-store',
          headers: { 'X-Gnat-Token': '__GNAT_TOKEN__' },
        });
        if (!response.ok) throw new Error(`brain request failed: ${response.status}`);
        drawBrain(await response.json());
      } catch (error) {
        // Keep the last neural snapshot visible during a transient request error.
      } finally {
        brainRequestActive = false;
        if (!stopped) setTimeout(refreshBrain, 100);
      }
    }
    function drawBrain(state) {
      const width = brainCanvas.width;
      const height = brainCanvas.height;
      brainContext.clearRect(0, 0, width, height);
      brainContext.fillStyle = '#000000';
      brainContext.fillRect(0, 0, width, height);
      const layers = [
        { key: 'retina', label: 'LEFT / RIGHT EYE', color: '#ffffff', x: 120 },
        { key: 'optic_lobe', label: 'OPTIC LOBE', color: '#d6d6d6', x: 390 },
        { key: 'central_complex', label: 'CENTRAL CIRCUIT', color: '#aaaaaa', x: 680 },
        { key: 'motor', label: 'MOTOR', color: '#ffffff', x: 960 },
      ];
      const nodeCount = 8;
      const yFor = (index) => 64 + index * 34;
      const activityFor = (layer) => {
        const values = state[layer.key] || [];
        if (!values.length) return Array(nodeCount).fill(0);
        return Array.from({ length: nodeCount }, (_, index) => {
          const start = Math.floor(index * values.length / nodeCount);
          const end = Math.max(start + 1, Math.floor((index + 1) * values.length / nodeCount));
          const slice = values.slice(start, end);
          return Math.min(1, Math.max(0, slice.reduce((sum, value) => sum + Math.abs(value), 0) / slice.length));
        });
      };
      const layerActivities = layers.map((layer) => activityFor(layer));
      for (let layerIndex = 0; layerIndex < layers.length - 1; layerIndex += 1) {
        const left = layers[layerIndex];
        const right = layers[layerIndex + 1];
        const pulse = (Number(state.time_ms || 0) / 90 + layerIndex * 0.27) % 1;
        const signal = Number((state.transmission || [])[layerIndex] || 0);
        for (let node = 0; node < nodeCount; node += 1) {
          const fromY = yFor(node);
          const toY = yFor(node);
          brainContext.strokeStyle = `rgba(255, 255, 255, ${0.08 + signal * 0.18})`;
          brainContext.lineWidth = 1;
          brainContext.beginPath();
          brainContext.moveTo(left.x + 12, fromY);
          brainContext.lineTo(right.x - 12, toY);
          brainContext.stroke();
        }
        const pulseX = left.x + 12 + pulse * (right.x - left.x - 24);
        brainContext.fillStyle = left.color;
        brainContext.shadowColor = left.color;
        brainContext.shadowBlur = 14 + signal * 16;
        brainContext.beginPath();
        brainContext.arc(pulseX, yFor(3), 3 + signal * 5, 0, Math.PI * 2);
        brainContext.fill();
        brainContext.shadowBlur = 0;
      }
      layers.forEach((layer, layerIndex) => {
        const values = layerActivities[layerIndex];
        brainContext.fillStyle = '#ffffff';
        brainContext.font = '700 16px ui-monospace, monospace';
        brainContext.textAlign = 'center';
        brainContext.fillText(layer.label, layer.x, 30);
        values.forEach((activity, node) => {
          const y = yFor(node);
          brainContext.fillStyle = layer.color;
          brainContext.globalAlpha = 0.18 + activity * 0.82;
          brainContext.shadowColor = layer.color;
          brainContext.shadowBlur = 5 + activity * 18;
          brainContext.beginPath();
          brainContext.arc(layer.x, y, 7 + activity * 6, 0, Math.PI * 2);
          brainContext.fill();
          brainContext.globalAlpha = 1;
          brainContext.shadowBlur = 0;
        });
        brainContext.fillStyle = '#888888';
        brainContext.font = '12px ui-monospace, monospace';
        brainContext.fillText(`${Math.round(values.reduce((a, b) => a + b, 0) / values.length * 100)}%`, layer.x, 348);
      });
      const latency = (state.latency_ms || []).map((value) => `${Number(value).toFixed(1)} ms`).join('  →  ');
      brainContext.textAlign = 'left';
      brainContext.fillStyle = '#888888';
      brainContext.font = '12px ui-monospace, monospace';
      brainContext.fillText(`LATENCY ${latency}   SPIKES ${state.total_spikes || 0}   T=${Number(state.time_ms || 0).toFixed(1)} MS`, 18, 324);
    }
    async function refreshHealth() {
      if (stopped || healthRequestActive) return;
      healthRequestActive = true;
      try {
        const response = await fetch('/health?t=' + Date.now(), { cache: 'no-store' });
        if (!response.ok) throw new Error(`health request failed: ${response.status}`);
        const health = await response.json();
        if (!health.frame_ready) {
          document.querySelector('#status').textContent = 'FRAME WAITING';
        } else if (lastHealthFrame === health.frame_sequence) {
          staleHealthPolls += 1;
          if (staleHealthPolls >= 2) document.querySelector('#status').textContent = 'FRAME STALE';
        } else {
          staleHealthPolls = 0;
          if (document.querySelector('#status').textContent === 'FRAME STALE') {
            document.querySelector('#status').textContent = 'LIVE / DEMO';
          }
        }
        lastHealthFrame = health.frame_sequence;
        const backend = health.connectome_loaded ? 'CONNECTOME BACKEND' : 'DEMO NUMPY / NO CONNECTOME';
        document.querySelector('#backend-status').textContent = backend;
        document.querySelector('#signal-status').textContent = health.connectome_loaded ? 'MALECNS CONNECTOME' : 'DEMO NUMPY CIRCUIT';
        const motorCount = Number(health.motor_actuators || 0);
        const motorStatus = health.motor_status === 'connected'
          ? `MOTOR LINK: CONNECTED / ${motorCount} ACTUATORS`
          : `MOTOR LINK: DISCONNECTED / ${motorCount} ACTUATORS`;
        document.querySelector('#motor-status').textContent = motorStatus;
      } catch (error) {
        document.querySelector('#backend-status').textContent = 'VIEWER HEALTH UNKNOWN';
      } finally {
        healthRequestActive = false;
        if (!stopped) setTimeout(refreshHealth, 500);
      }
    }
    refreshFrames();
    refreshBrain();
    refreshHealth();
