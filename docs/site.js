const english = document.documentElement.lang === 'en';
const floorToggle = document.querySelector('[data-floor-toggle]');
if (floorToggle) {
  floorToggle.addEventListener('click', () => {
    const enabled = floorToggle.getAttribute('aria-pressed') !== 'true';
    floorToggle.setAttribute('aria-pressed', String(enabled));
    floorToggle.closest('.floor-demo').classList.toggle('is-on', enabled);
    document.querySelector('[data-light-state]').textContent = enabled ? (english ? 'On' : 'An') : (english ? 'Off' : 'Aus');
  });
}
const motionToggle = document.querySelector('[data-motion-toggle]');
if (motionToggle) {
  motionToggle.addEventListener('click', () => {
    const enabled = motionToggle.getAttribute('aria-pressed') !== 'true';
    motionToggle.setAttribute('aria-pressed', String(enabled));
    motionToggle.closest('.st-demo').classList.toggle('is-on', enabled);
    document.querySelector('[data-motion-value]').textContent = enabled ? 'TRUE' : 'FALSE';
  });
}
const selector = document.querySelector('[data-download-selector]');
if (selector) {
  const releases = JSON.parse(document.querySelector('#release-options').textContent);
  const game = document.querySelector('#game');
  const loader = document.querySelector('#loader');
  function updateDownload() {
    const chosen = releases.find(item => item.game === game.value && item.loader === loader.value);
    if (!chosen) return;
    document.querySelector('[data-selected-download]').href = chosen.url;
    document.querySelector('[data-requirements]').textContent = `Java ${chosen.java}` + (chosen.loader === 'Fabric' ? ' · Fabric API' : ' · NeoForge');
  }
  game.addEventListener('change', updateDownload);
  loader.addEventListener('change', updateDownload);
  updateDownload();
  selector.hidden = false;
}
