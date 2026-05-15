// ──────────────────────────────────────────────────────────────
// Copy-to-clipboard buttons (install command, hero + bottom CTA)
// ──────────────────────────────────────────────────────────────
document.querySelectorAll('.copy-btn').forEach((btn) => {
    btn.addEventListener('click', async () => {
        const targetId = btn.dataset.clipboardTarget;
        const code = targetId ? document.getElementById(targetId)?.textContent : btn.dataset.clipboard;
        if (!code) return;
        try {
            await navigator.clipboard.writeText(code.trim());
            const original = btn.textContent;
            btn.textContent = 'Copied';
            btn.classList.add('copied');
            setTimeout(() => {
                btn.textContent = original;
                btn.classList.remove('copied');
            }, 1800);
        } catch (e) {
            // Older browser / non-secure context — surface a fallback so
            // the page doesn't fail silently.
            window.prompt('Copy:', code);
        }
    });
});

// ──────────────────────────────────────────────────────────────
// Scroll-driven mascot state switcher
// ──────────────────────────────────────────────────────────────
// Each text panel in the dark section has data-state matching one of the
// SVGs. As the panel passes through the middle of the viewport, the SVG
// with that data-state becomes the active (visible) one. The transition
// happens via the .active class on each SVG; opacity fades are CSS-driven.
const mascotSvgs = document.querySelectorAll('.mascot-svg');
const panels = document.querySelectorAll('.mascot-section .panel');

if ('IntersectionObserver' in window && mascotSvgs.length && panels.length) {
    const setActive = (state) => {
        mascotSvgs.forEach((svg) => {
            svg.classList.toggle('active', svg.dataset.state === state);
        });
    };

    const observer = new IntersectionObserver(
        (entries) => {
            // Multiple panels can intersect at once near boundaries; pick the
            // one closest to the viewport center for stable switching.
            const viewportCenter = window.innerHeight / 2;
            let best = null;
            let bestDist = Infinity;
            entries.forEach((entry) => {
                if (!entry.isIntersecting) return;
                const rect = entry.target.getBoundingClientRect();
                const center = rect.top + rect.height / 2;
                const dist = Math.abs(center - viewportCenter);
                if (dist < bestDist) {
                    bestDist = dist;
                    best = entry.target;
                }
            });
            if (best) setActive(best.dataset.state);
        },
        {
            // Trigger when a panel occupies the middle band of the viewport.
            rootMargin: '-35% 0px -35% 0px',
            threshold: 0,
        }
    );
    panels.forEach((panel) => observer.observe(panel));
}
