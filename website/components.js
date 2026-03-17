/* ── Shared components ── Light DOM custom elements ── */
/* Renders into this.innerHTML so existing style.css / script.js selectors work unchanged. */
/* Note: All markup is hardcoded (no user input), so innerHTML is safe here — no XSS risk. */
/*
 * IMPORTANT: Custom elements default to display:inline, which breaks block
 * layout for <nav> and <footer> children (margin collapse, flow, grid).
 * The fix lives in style.css:
 *     site-nav, site-footer { display: contents; }
 * Do NOT remove that rule. Without it the footer spacing breaks silently.
 */

class SiteNav extends HTMLElement {
    connectedCallback() {
        this.innerHTML = `
    <nav class="nav">
        <div class="nav-inner">
            <a href="/" class="nav-logo">
                <img src="/logo.png" alt="Chau7" class="logo-icon">
                <span class="logo-text">Chau7</span><span class="logo-beta">Beta</span>
            </a>
            <button class="nav-hamburger" aria-label="Toggle menu">
                <span></span><span></span><span></span>
            </button>
            <div class="nav-links">
                <a href="/features">Features</a>
                <a href="/mcp">MCP</a>
                <a href="/remote">Remote</a>
                <a href="/the-tech">The Tech</a>
                <a href="/compare">Compare</a>
                <a href="/pronunciation">How to say it</a>
                <a href="https://github.com/nicmusic/chau7" class="nav-cta-download" target="_blank" rel="noopener">Download</a>
            </div>
        </div>
    </nav>`;
    }
}

class SiteFooter extends HTMLElement {
    connectedCallback() {
        this.innerHTML = `
    <footer class="footer">
        <div class="section-inner">
            <div class="footer-grid">
                <div class="footer-brand-col">
                    <div class="footer-brand">
                        <img src="/logo.png" alt="Chau7" class="logo-icon">
                        <span class="logo-text">Chau7</span>
                    </div>
                    <p class="footer-tagline">The AI-native terminal for macOS.</p>
                </div>
                <div class="footer-nav-col">
                    <h4>Product</h4>
                    <a href="/features">Features</a>
                    <a href="/mcp">MCP Tools</a>
                    <a href="/remote">Remote</a>
                    <a href="/the-tech">The Tech</a>
                    <a href="/compare">Compare</a>
                </div>
                <div class="footer-nav-col">
                    <h4>Resources</h4>
                    <a href="https://github.com/nicmusic/chau7" target="_blank" rel="noopener">GitHub</a>
                    <a href="https://github.com/nicmusic/chau7/releases" target="_blank" rel="noopener">Releases</a>
                    <a href="/llms.txt">llms.txt</a>
                </div>
                <div class="footer-nav-col">
                    <h4>Colophon</h4>
                    <a href="/golden-ratio">The Golden Ratio</a>
                    <a href="/typography">Typography</a>
                    <a href="/pronunciation">How to Say It</a>
                </div>
                <div class="footer-nav-col">
                    <h4>Legal</h4>
                    <a href="/legal">Legal Notice</a>
                    <a href="/mentions-legales">Mentions L&eacute;gales</a>
                    <a href="/privacy">Privacy Policy</a>
                    <a href="/politique-de-confidentialite">Confidentialit&eacute;</a>
                </div>
            </div>
            <div class="footer-bottom">
                <span>253 Swift files &middot; Rust backend &middot; Metal GPU &middot; 1537 tests</span>
            </div>
        </div>
    </footer>`;
    }
}

customElements.define('site-nav', SiteNav);
customElements.define('site-footer', SiteFooter);
