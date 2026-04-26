// QR Party — GA4 custom event wiring.
// Attaches handlers based on URL so each page only needs to load this file.
// Safe by design: every gtag call is wrapped, so a missing/blocked tag never
// throws into page code. To verify: open DevTools console and run
//   gtag('event','test')
// On any page with this file loaded you should see the request fire in the
// Network tab (filter: "collect").
(function () {
  'use strict';

  function track(name, params) {
    try {
      if (typeof window.gtag === 'function') {
        window.gtag('event', name, params || {});
      }
    } catch (e) { /* never let analytics break the page */ }
  }

  // Once-per-session dedupe via sessionStorage (per tab, cleared on close).
  function trackOnce(key, name, params) {
    try {
      if (sessionStorage.getItem('qrt_' + key)) return;
      sessionStorage.setItem('qrt_' + key, '1');
    } catch (e) { /* private mode etc — fall through and fire anyway */ }
    track(name, params);
  }

  window.qrTrack = track;
  window.qrTrackOnce = trackOnce;

  // ── Page kind detection ────────────────────────────────────────
  function pageKind() {
    var p = location.pathname;
    if (p === '/' || p === '/index.html') return 'home';
    if (p === '/business' || p === '/business.html') return 'business';
    if (p.indexOf('/event/') === 0 || p === '/event.html') return 'event';
    if (p.indexOf('/org/') === 0   || p === '/org.html')   return 'org';
    return null;
  }

  function urlSegmentAfter(prefix) {
    var p = location.pathname;
    if (p.indexOf(prefix) !== 0) return null;
    var rest = p.slice(prefix.length).replace(/\/$/, '').split('?')[0];
    return rest || null;
  }

  function storeFromHref(href) {
    if (!href) return null;
    if (/play\.google\.com/i.test(href))  return 'google_play';
    if (/apps\.apple\.com/i.test(href))   return 'app_store';
    return null;
  }

  // ── Main wiring ────────────────────────────────────────────────
  function init() {
    var kind = pageKind();

    // App-store / Play-store CTA — page-aware event name per spec.
    // - home     → download_clicked
    // - business → business_trial_clicked
    // - event    → app_download_from_event
    // Uses delegation so dynamically-rendered links (e.g. event.html claim
    // buttons, RSVP modal links) are covered too.
    document.addEventListener('click', function (e) {
      var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
      if (!a) return;
      var store = storeFromHref(a.getAttribute('href'));
      if (!store) return;
      if (kind === 'event') {
        track('app_download_from_event', { store: store });
      } else if (kind === 'business') {
        // The trial CTAs are the only Play Store links on this page.
        track('business_trial_clicked', { store: store });
      } else if (kind === 'home') {
        track('download_clicked', { store: store });
      }
    });

    // ── HOME ─────────────────────────────────────────────────────
    if (kind === 'home') {
      // Demo event link clicks (Taco Tuesday / PGMS PTA / future demos).
      document.addEventListener('click', function (e) {
        var a = e.target && e.target.closest ? e.target.closest('a[href*="/event/"]') : null;
        if (!a) return;
        var m = (a.getAttribute('href') || '').match(/\/event\/([^\/?#]+)/);
        if (!m) return;
        var id = decodeURIComponent(m[1]);
        if (/demo|pta/i.test(id)) {
          track('demo_event_clicked', { event_id: id });
        }
      });

      // Business-teaser CTA. No fire site exists in index.html today; this
      // catches it whenever you add a button. Recognised selectors:
      //   <a href="/business">…</a>
      //   <a class="biz-teaser-btn">…</a>
      //   <button data-track="biz-teaser">…</button>
      document.addEventListener('click', function (e) {
        var t = e.target && e.target.closest
          ? e.target.closest('a[href="/business"], a[href="/business.html"], .biz-teaser-btn, [data-track="biz-teaser"]')
          : null;
        if (!t) return;
        track('business_teaser_clicked');
      });

      // Scroll past 75%, once per session per tab.
      var fired = false;
      function checkScroll() {
        if (fired) return;
        var scrolled = window.scrollY + window.innerHeight;
        var total = document.documentElement.scrollHeight;
        if (total > 0 && scrolled / total >= 0.75) {
          fired = true;
          trackOnce('home_scroll_75', 'scroll_75');
          window.removeEventListener('scroll', checkScroll);
        }
      }
      window.addEventListener('scroll', checkScroll, { passive: true });
      checkScroll(); // in case the page already loaded scrolled (back nav)
    }

    // ── BUSINESS ─────────────────────────────────────────────────
    if (kind === 'business') {
      track('business_plan_viewed');

      // 2-second dwell on a tier card. Mouse + touch covered.
      document.querySelectorAll('.plan-card').forEach(function (el) {
        var tier = el.classList.contains('plus') ? 'business_plus' : 'business';
        var timer = null, sent = false;
        function start() {
          if (sent) return;
          clearTimeout(timer);
          timer = setTimeout(function () {
            sent = true;
            track('business_tier_hovered', { tier: tier });
          }, 2000);
        }
        function cancel() { clearTimeout(timer); }
        el.addEventListener('mouseenter', start);
        el.addEventListener('mouseleave', cancel);
        el.addEventListener('touchstart', start, { passive: true });
        el.addEventListener('touchend',   cancel);
        el.addEventListener('touchcancel', cancel);
      });
    }

    // ── EVENT ────────────────────────────────────────────────────
    if (kind === 'event') {
      var eventId = urlSegmentAfter('/event/') || '';
      track('event_page_loaded', { event_id: eventId });

      // RSVP buttons keep their existing onclick="showRsvpModal()"; this
      // listener fires alongside it.
      document.querySelectorAll('.rsvp-btn').forEach(function (btn) {
        btn.addEventListener('click', function () {
          var status = btn.classList.contains('yes')
            ? 'yes'
            : btn.classList.contains('maybe')
              ? 'maybe'
              : btn.classList.contains('no')
                ? 'no'
                : 'unknown';
          track('rsvp_button_clicked', { rsvp_status: status, event_id: eventId });
        });
      });

      var calBtn = document.getElementById('calendar-btn');
      if (calBtn) {
        calBtn.addEventListener('click', function () {
          if (calBtn.disabled) return;
          track('add_to_calendar_clicked', { event_id: eventId });
        });
      }
    }

    // ── ORG ──────────────────────────────────────────────────────
    if (kind === 'org') {
      var orgId = urlSegmentAfter('/org/') || '';
      track('org_page_loaded', { org_id: orgId });

      // Event cards in #events-list are rendered after the org doc loads,
      // so delegate from document.
      document.addEventListener('click', function (e) {
        var a = e.target && e.target.closest
          ? e.target.closest('a.event-card[href*="/event/"]')
          : null;
        if (!a) return;
        var m = (a.getAttribute('href') || '').match(/\/event\/([^\/?#]+)/);
        var id = m ? decodeURIComponent(m[1]) : '';
        track('org_event_clicked', { event_id: id, org_id: orgId });
      });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
