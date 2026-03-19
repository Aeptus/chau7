/* ── Chau7 Website — Interactions ─────────────────── */

(function () {
    'use strict';

    /* ── Scroll-reveal observer ──────────────────── */
    const revealTargets = [
        '.dual-card',
        '.mcp-block',
        '.mcp-demo',
        '.mcp-autoregister',
        '.ai-feature',
        '.feature-card',
        '.agent-card',
        '.section-header',
        '.hero-screenshot',
        '.pillar-card',
        '.step-card',
        '.problem-box',
        '.carousel',
        '.number-card',
        '.safety-item',
        '.arch-diagram',
        '.ai-relevance',
        '.competitor-sections',
        '.compare-table-wrap',
        '.question-item',
        '.related-features-grid .catalog-card',
        '.persona-card',
        '.persona-features .catalog-card',
        '.agent-proof',
        '.proof-content',
        '.footer-cta-content',
    ];

    function addRevealClass() {
        document.querySelectorAll(revealTargets.join(',')).forEach(el => {
            if (!el.classList.contains('reveal')) el.classList.add('reveal');
        });
    }

    const io = new IntersectionObserver(
        (entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    entry.target.classList.add('visible');
                    io.unobserve(entry.target);
                }
            });
        },
        { threshold: 0.12, rootMargin: '0px 0px -40px 0px' }
    );

    function observeAll() {
        document.querySelectorAll('.reveal').forEach(el => io.observe(el));
    }

    /* ── Stagger-children observer ───────────────── */
    const staggerIO = new IntersectionObserver(
        (entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    const children = entry.target.querySelectorAll('.reveal');
                    children.forEach((child, i) => {
                        setTimeout(() => child.classList.add('visible'), i * 100);
                    });
                    staggerIO.unobserve(entry.target);
                }
            });
        },
        { threshold: 0.1, rootMargin: '0px 0px -40px 0px' }
    );

    function observeStagger() {
        document.querySelectorAll('.stagger-children').forEach(el => {
            // Add reveal to direct children that don't have it yet
            el.querySelectorAll(':scope > *:not(.reveal)').forEach(child => {
                child.classList.add('reveal');
            });
            staggerIO.observe(el);
        });
    }

    /* ── Performance stack stagger ───────────────── */
    const perfIO = new IntersectionObserver(
        (entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    const layers = entry.target.querySelectorAll('.perf-layer');
                    layers.forEach((layer, i) => {
                        setTimeout(() => layer.classList.add('visible'), i * 120);
                    });
                    perfIO.unobserve(entry.target);
                }
            });
        },
        { threshold: 0.2 }
    );

    /* ── Stat counter animation ──────────────────── */
    function animateCounters() {
        document.querySelectorAll('.stat-number').forEach(el => {
            const raw = el.textContent.trim();
            const num = parseInt(raw, 10);
            if (isNaN(num) || raw !== num.toString()) return;

            const duration = 1200;
            const start = performance.now();

            function tick(now) {
                const elapsed = now - start;
                const progress = Math.min(elapsed / duration, 1);
                const ease = 1 - Math.pow(1 - progress, 3);
                el.textContent = Math.round(num * ease).toString();
                if (progress < 1) requestAnimationFrame(tick);
            }
            requestAnimationFrame(tick);
        });
    }

    const heroIO = new IntersectionObserver(
        (entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    animateCounters();
                    heroIO.unobserve(entry.target);
                }
            });
        },
        { threshold: 0.3 }
    );

    /* ── Navbar shrink on scroll ─────────────────── */
    function initNavScroll() {
        const nav = document.querySelector('.nav');
        if (!nav) return;
        let ticking = false;
        window.addEventListener('scroll', () => {
            if (ticking) return;
            ticking = true;
            requestAnimationFrame(() => {
                nav.style.borderBottomColor =
                    window.scrollY > 40 ? 'var(--border)' : 'transparent';
                ticking = false;
            });
        }, { passive: true });
    }

    /* ── Smooth scroll for anchor links ──────────── */
    function initSmoothLinks() {
        document.querySelectorAll('a[href^="#"]').forEach(link => {
            // Pillar nav cards handle their own scroll via initPillarCarousel
            if (link.classList.contains('pillar-nav-card')) return;
            link.addEventListener('click', e => {
                const target = document.querySelector(link.getAttribute('href'));
                if (!target) return;
                e.preventDefault();
                target.scrollIntoView({ behavior: 'smooth', block: 'start' });
            });
        });
    }

    /* ── Active nav link ─────────────────────────── */
    function initActiveNav() {
        let p = window.location.pathname
            .replace(/\/index\.html$/, '')
            .replace(/\.html$/, '')
            .replace(/\/$/, '') || '/';

        document.querySelectorAll('.nav-links a').forEach(link => {
            const href = link.getAttribute('href');
            if (!href || href.startsWith('http')) return;
            if (href === p) link.classList.add('active');
        });

        // Highlight "Features" for sub-pages under /features/
        if (p.startsWith('/features/')) {
            document.querySelectorAll('.nav-links a[href="/features"]').forEach(link => {
                link.classList.add('active');
            });
        }
    }

    /* ── Mobile hamburger toggle ─────────────────── */
    function initMobileNav() {
        const hamburger = document.querySelector('.nav-hamburger');
        const navLinks = document.querySelector('.nav-links');
        if (!hamburger || !navLinks) return;

        hamburger.addEventListener('click', () => {
            hamburger.classList.toggle('open');
            navLinks.classList.toggle('open');
        });

        // Close menu when a link is clicked
        navLinks.querySelectorAll('a').forEach(link => {
            link.addEventListener('click', () => {
                hamburger.classList.remove('open');
                navLinks.classList.remove('open');
            });
        });
    }

    /* ── Feature filtering (features.html) ──────── */
    function initFeatureFilter() {
        const filterBar = document.querySelector('.filter-bar');
        if (!filterBar) return;

        const featureSection = filterBar.closest('.features-section') || document;
        const searchInput = filterBar.querySelector('.filter-search');
        const pills = filterBar.querySelectorAll('.filter-pill');
        const randomButton = featureSection.querySelector('.filter-random-btn');
        const grid = document.getElementById('feature-grid');
        const cards = grid.querySelectorAll('.catalog-card');
        const headers = grid.querySelectorAll('.catalog-category-header');
        const noResults = document.getElementById('no-results');

        let activeCategory = 'all';

        function filterCards() {
            const query = searchInput.value.toLowerCase().trim();
            let visibleCount = 0;
            const visibleCategories = new Set();

            cards.forEach(card => {
                const category = card.dataset.category;
                const text = card.textContent.toLowerCase();
                const matchesCategory = activeCategory === 'all' || category === activeCategory;
                const matchesSearch = !query || text.includes(query);
                const visible = matchesCategory && matchesSearch;

                card.style.display = visible ? '' : 'none';
                if (visible) {
                    visibleCount++;
                    visibleCategories.add(category);
                }
            });

            // Show/hide category headers
            headers.forEach(header => {
                const cat = header.dataset.category;
                header.style.display = visibleCategories.has(cat) ? '' : 'none';
            });

            // No results message
            if (noResults) {
                noResults.style.display = visibleCount === 0 ? 'block' : 'none';
            }

            if (randomButton) {
                randomButton.disabled = visibleCount === 0;
            }
        }

        pills.forEach(pill => {
            pill.addEventListener('click', () => {
                pills.forEach(p => p.classList.remove('active'));
                pill.classList.add('active');
                activeCategory = pill.dataset.category;
                filterCards();
            });
        });

        if (searchInput) {
            searchInput.addEventListener('input', filterCards);
        }

        if (randomButton) {
            randomButton.addEventListener('click', () => {
                const visibleCards = Array.from(cards).filter(card => card.style.display !== 'none');
                if (visibleCards.length === 0) return;

                const randomCard = visibleCards[Math.floor(Math.random() * visibleCards.length)];
                const href = randomCard.getAttribute('href');
                if (href) {
                    window.location.href = href;
                }
            });
        }

        filterCards();
    }

    /* ── Random feature jump (feature pages) ─────── */
    function initFeaturePageRandom() {
        const buttons = document.querySelectorAll('.feature-random-btn');
        if (buttons.length === 0) return;

        const featurePages = Array.isArray(window.CHAU7_FEATURE_PAGES)
            ? window.CHAU7_FEATURE_PAGES
            : [];

        function normalizeFeaturePath(path) {
            return String(path || '')
                .replace(/index\.html$/, '')
                .replace(/\.html$/, '')
                .replace(/\/+$/, '');
        }

        const currentPath = normalizeFeaturePath(window.location.pathname);
        const candidates = featurePages.filter(path => normalizeFeaturePath(path) !== currentPath);

        buttons.forEach(button => {
            button.disabled = candidates.length === 0;
            button.addEventListener('click', () => {
                if (candidates.length === 0) return;
                const next = candidates[Math.floor(Math.random() * candidates.length)];
                window.location.href = next;
            });
        });
    }

    /* ── Comparison table scroll hint ────────────── */
    function initTableScrollHint() {
        const wrap = document.querySelector('.compare-table-wrap');
        if (!wrap) return;

        const hint = wrap.querySelector('.scroll-hint');
        if (!hint) return;

        function checkScroll() {
            const atEnd = wrap.scrollLeft + wrap.clientWidth >= wrap.scrollWidth - 10;
            hint.style.opacity = atEnd ? '0' : '1';
        }

        wrap.addEventListener('scroll', checkScroll, { passive: true });
        // Initial check after layout
        requestAnimationFrame(checkScroll);
    }

    /* ── Hero typewriter rotator ─────────────────── */
    function initHeroRotator() {
        const el = document.querySelector('.hero-rotator');
        if (!el) return;

        const phrases = [
            'notices your AI.',
            'optimizes your token usage.',
            'renames tabs for you.',
            'lets your AI drive the terminal.',
            'lets you drive it from your phone.',
            'guards against dangerous commands.',
            'records your sessions.',
            'runs at GPU speed.',
            'restores your tabs on relaunch.',
            'is named after a sock.',
        ];

        let phraseIndex = 0;
        let charIndex = 0;
        let deleting = false;
        let pauseTimer = null;

        // Start with the first phrase already typed
        el.textContent = phrases[0];
        charIndex = phrases[0].length;

        function tick() {
            const current = phrases[phraseIndex];

            if (!deleting) {
                // Typing
                charIndex++;
                el.textContent = current.slice(0, charIndex);
                if (charIndex >= current.length) {
                    // Pause at end of phrase, then start deleting
                    pauseTimer = setTimeout(() => { deleting = true; tick(); }, 2400);
                    return;
                }
                setTimeout(tick, 60 + Math.random() * 40);
            } else {
                // Deleting
                charIndex--;
                el.textContent = current.slice(0, charIndex);
                if (charIndex <= 0) {
                    deleting = false;
                    phraseIndex = (phraseIndex + 1) % phrases.length;
                    // Brief pause before typing next
                    setTimeout(tick, 400);
                    return;
                }
                setTimeout(tick, 30 + Math.random() * 20);
            }
        }

        // Start the cycle after initial display pause
        setTimeout(() => { deleting = true; tick(); }, 3000);
    }

    /* ── Parchment carousel ──────────────────────── */
    function initCarousel() {
        const carousel = document.querySelector('.carousel');
        if (!carousel) return;

        const sheets = carousel.querySelectorAll('.carousel-sheet');
        const dots = carousel.querySelectorAll('.carousel-dots .dot');
        if (sheets.length === 0) return;

        let current = 0;
        let timer = null;
        const INTERVAL = 5000;
        const TRANSITION = 700;

        function goToSlide(index) {
            if (index === current) return;

            // Enable keyframe arc animations after first interaction
            carousel.classList.add('animated');

            const prev = sheets[current];
            const next = sheets[index];

            // Exit current sheet to the left
            prev.classList.remove('active');
            prev.classList.add('exiting');

            // Enter new sheet from the right
            next.classList.add('active');

            // Update dots
            dots[current]?.classList.remove('active');
            dots[index]?.classList.add('active');

            current = index;

            // Clean up exiting class after animation ends
            setTimeout(() => {
                prev.classList.remove('exiting');
            }, TRANSITION);
        }

        function advance() {
            goToSlide((current + 1) % sheets.length);
        }

        function resetTimer() {
            clearInterval(timer);
            timer = setInterval(advance, INTERVAL);
        }

        // Dot click handlers
        dots.forEach(dot => {
            dot.addEventListener('click', () => {
                const index = parseInt(dot.dataset.slide, 10);
                if (!isNaN(index)) {
                    goToSlide(index);
                    resetTimer();
                }
            });
        });

        // Pause on hover, resume on leave
        carousel.addEventListener('mouseenter', () => clearInterval(timer));
        carousel.addEventListener('mouseleave', resetTimer);

        // Start auto-advance
        resetTimer();
    }

    /* ── Pillar carousel ──────────────────────────── */
    function initPillarCarousel() {
        const carousel = document.querySelector('.pillar-carousel');
        if (!carousel) return;

        const panels = carousel.querySelectorAll('.pillar-panel');
        const navCards = document.querySelectorAll('.pillar-nav-card[data-panel]');
        if (panels.length === 0) return;

        // Click nav cards → scroll carousel horizontally (not the page)
        navCards.forEach(card => {
            card.addEventListener('click', (e) => {
                e.preventDefault();
                const idx = parseInt(card.dataset.panel, 10);
                if (isNaN(idx) || !panels[idx]) return;

                const panel = panels[idx];
                const scrollLeft = panel.offsetLeft - (carousel.offsetWidth - panel.offsetWidth) / 2;
                carousel.scrollTo({ left: scrollLeft, behavior: 'smooth' });
            });
        });

        // IntersectionObserver: track which panel is most visible
        const io = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                const panel = entry.target;
                if (entry.isIntersecting && entry.intersectionRatio > 0.5) {
                    // This panel is centered — activate it
                    panels.forEach(p => p.classList.remove('active'));
                    panel.classList.add('active');

                    // Sync nav cards
                    const idx = [...panels].indexOf(panel);
                    navCards.forEach(c => c.classList.remove('active'));
                    if (navCards[idx]) navCards[idx].classList.add('active');
                }
            });
        }, {
            root: carousel,
            threshold: 0.5
        });

        panels.forEach(p => io.observe(p));
    }

    /* ── Question list → section links ────────────── */
    function initQuestionLinks() {
        var items = document.querySelectorAll('.question-item');
        if (!items.length) return;

        var sections = document.querySelectorAll('.feature-content');
        items.forEach(function(item, i) {
            if (i >= sections.length) return;
            var section = sections[i];
            // Add id to section if missing
            if (!section.id) {
                section.id = section.getAttribute('data-ui') || ('q-section-' + i);
            }
            // Wrap text in a link
            var link = document.createElement('a');
            link.href = '#' + section.id;
            link.textContent = item.textContent;
            link.style.cssText = 'color: inherit; text-decoration: none; border-bottom: 1px dotted var(--border);';
            item.textContent = '';
            item.appendChild(link);
            link.addEventListener('click', function(e) {
                e.preventDefault();
                section.scrollIntoView({ behavior: 'smooth', block: 'start' });
            });
        });
    }

    /* ── Ask AI footnotes ─────────────────────────── */
    /* Note: All markup below is hardcoded (no user input), so DOM construction is safe. */
    function initAskAI() {
        var triggers = document.querySelectorAll('.ask-ai-trigger');
        if (!triggers.length) return;

        var providers = [
            { name: 'Claude', url: 'https://claude.ai/new?q=', color: '#cc7832' },
            { name: 'ChatGPT', url: 'https://chatgpt.com/?q=', color: '#10a37f' },
            { name: 'Gemini', url: 'https://gemini.google.com/app?q=', color: '#4285f4' },
            { name: 'Le Chat', url: 'https://chat.mistral.ai/chat?q=', color: '#ff7000' }
        ];

        triggers.forEach(function(trigger) {
            var term = trigger.getAttribute('data-term');
            if (!term) return;

            var parent = trigger.closest('.ask-ai');
            var definition = parent ? parent.getAttribute('data-definition') : '';
            var prompt = 'On Chau7.sh I read about "' + term + '".'
                + (definition ? ' The site defines it as: "' + definition + '".' : '')
                + ' Explain what it is, what it means, and what it brings to an AI-optimized terminal like Chau7.';
            var encoded = encodeURIComponent(prompt);

            // Build popup using safe DOM methods
            var popup = document.createElement('div');
            popup.className = 'ask-ai-popup';

            var label = document.createElement('span');
            label.className = 'ask-ai-popup-label';
            label.textContent = 'Ask an AI about this';
            popup.appendChild(label);

            providers.forEach(function(p) {
                var link = document.createElement('a');
                link.href = p.url + encoded;
                link.target = '_blank';
                link.rel = 'noopener';

                var dot = document.createElement('span');
                dot.style.cssText = 'width:10px;height:10px;border-radius:50%;background:' + p.color + ';flex-shrink:0;';
                link.appendChild(dot);

                var nameSpan = document.createElement('span');
                nameSpan.textContent = p.name;
                link.appendChild(nameSpan);

                popup.appendChild(link);
            });

            trigger.parentNode.style.position = 'relative';
            trigger.parentNode.appendChild(popup);

            trigger.addEventListener('click', function(e) {
                e.stopPropagation();
                var isOpen = popup.classList.contains('open');
                document.querySelectorAll('.ask-ai-popup.open').forEach(function(p) {
                    p.classList.remove('open');
                });
                if (!isOpen) popup.classList.add('open');
            });
        });

        document.addEventListener('click', function() {
            document.querySelectorAll('.ask-ai-popup.open').forEach(function(p) {
                p.classList.remove('open');
            });
        });
    }

    /* ── Init ────────────────────────────────────── */
    document.addEventListener('DOMContentLoaded', () => {
        addRevealClass();
        observeStagger();
        observeAll();

        const perfStack = document.querySelector('.perf-stack');
        if (perfStack) perfIO.observe(perfStack);

        const heroStats = document.querySelector('.hero-stats');
        if (heroStats) heroIO.observe(heroStats);

        initNavScroll();
        initSmoothLinks();
        initActiveNav();
        initMobileNav();
    initFeatureFilter();
    initFeaturePageRandom();
    initTableScrollHint();
        initHeroRotator();
        initCarousel();
        initPillarCarousel();
        initAskAI();
        initQuestionLinks();
    });
})();
